# Stage 1: Get Chrome/Chromium from chromedp/headless-shell
FROM docker.io/chromedp/headless-shell:stable AS chrome

# Build the guest-facing exeuntu helper.
FROM docker.io/library/golang:1.26.4 AS exeuntu-cli
ARG EXEUNTU_GIT_VERSION=unknown
WORKDIR /src/exeuntu-cli
COPY cli/ ./
RUN CGO_ENABLED=0 GOOS=linux go build -mod=mod -tags osusergo,netgo \
        -ldflags "-X main.gitVersion=${EXEUNTU_GIT_VERSION} -extldflags=-static -s -w" \
        -o /out/exeuntu .

FROM ubuntu:24.04

# Switch from dash to bash by default.
SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]


# Remove minimization restrictions and install packages with documentation
# We aim for a usable non-minimal system.
RUN sed -i 's|http://archive.ubuntu.com/ubuntu/|http://mirror://mirrors.ubuntu.com/mirrors.txt|' /etc/apt/sources.list && \
        rm -f /etc/dpkg/dpkg.cfg.d/excludes /etc/dpkg/dpkg.cfg.d/01_nodoc && \
	apt-get update && \
	# Pull in all available security/bugfix updates for packages already
	# in the base ubuntu:24.04 image. Without this we ship whatever was
	# current when Canonical last rebuilt the base layer, which can be
	# months behind (e.g. nginx Rift, CVE-2026-42945). The weekly cron
	# rebuild + no-cache will keep this fresh going forward.
	DEBIAN_FRONTEND=noninteractive apt-get -y \
		-o Dpkg::Options::=--force-confold \
		-o Dpkg::Options::=--force-confdef \
		dist-upgrade && \
	# Pre-configure debconf to avoid interactive prompts
	echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections && \
	# Pre-configure pbuilder to avoid mirror prompt
	echo 'pbuilder pbuilder/mirrorsite string http://archive.ubuntu.com/ubuntu' | debconf-set-selections && \
	# Run unminimize with single 'y' response to restore documentation
	echo 'y' | DEBIAN_FRONTEND=noninteractive unminimize && \
	# Install man-db and reinstall all base packages to get their man pages back
	DEBIAN_FRONTEND=noninteractive apt-get install -y man-db && \
	DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall $(dpkg-query -f '${binary:Package} ' -W) && \
	mandb -c && \
	DEBIAN_FRONTEND=noninteractive apt-get install -y \
		ca-certificates wget ripgrep \
		locales locales-all \
		git jq sqlite3 curl vim neovim lsof iproute2 less nginx \
		make python3-pip python-is-python3 tree net-tools file build-essential \
		pipx psmisc bsdmainutils sudo socat \
		openssh-server openssh-client \
		libcap2-bin unzip util-linux rsync \
		iputils-ping socat netcat-openbsd \
		ubuntu-server ubuntu-dev-tools ubuntu-standard \
		man-db manpages manpages-dev \
		mitmproxy \
		systemd systemd-sysv \
		atop btop iotop ncdu \
		git \
		libglib2.0-0 libnss3 libx11-6 libxcomposite1 libxdamage1 \
		libxext6 libxi6 libxrandr2 libgbm1 libgtk-3-0 \
		fonts-noto-color-emoji fonts-symbola \
		docker.io docker-buildx docker-compose-v2 \
		imagemagick ffmpeg \
		bubblewrap \
		gh \
		dbus-user-session \
		&& apt-get remove -y pollinate ubuntu-fan && \
		# openssh-server generates host keys during package configuration.
		# Do not bake those per-image private keys into exeuntu.
		rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub && \
		# Allow non-root users to use ping without sudo by granting CAP_NET_RAW
		setcap cap_net_raw=+ep /usr/bin/ping && \
	fc-cache -f -v && \
	# Remove policy-rc.d so services can start normally (the base image includes this
	# to prevent services from starting during build, but we run systemd at runtime)
	rm -f /usr/sbin/policy-rc.d

# Install Tailscale (keyring method, per https://tailscale.com/install.sh)
# This must run after ca-certificates and curl are installed.
RUN curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg -o /usr/share/keyrings/tailscale-archive-keyring.gpg && \
    curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list -o /etc/apt/sources.list.d/tailscale.list && \
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y tailscale

# Modify existing ubuntu user (UID 1000) to become exedev user.
# Must run before any COPY into /home/exedev so mv sees a non-existent target.
RUN usermod -l exedev -c "exe.dev user" ubuntu && \
	groupmod -n exedev ubuntu && \
	mv /home/ubuntu /home/exedev && \
	usermod -d /home/exedev exedev && \
	usermod -aG sudo exedev && \
	usermod -aG docker exedev && \
	sed -i 's/^ubuntu:/exedev:/' /etc/subuid /etc/subgid && \
	echo 'exedev ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers && \
	echo 'Defaults:exedev verifypw=any' >> /etc/sudoers && \
	mkdir -p /var/lib/systemd/linger && \
	touch /var/lib/systemd/linger/exedev

# The devel Go source tree from the host via a named build context
# (--build-context go-src=$HOME/w/go). Lives at ~/src/go;
# /usr/local/go symlinks into it so system PATH assumptions hold.
COPY --from=go-src --chown=1000:1000 . /home/exedev/src/go/
RUN ln -s /home/exedev/src/go /usr/local/go && \
    ln -s /usr/local/go/bin/go /usr/local/bin/go && \
    ln -s /usr/local/go/bin/gofmt /usr/local/bin/gofmt

# Bootstrap Go SDK for rebuilding the devel toolchain after source
# updates via make.bash. GOROOT_BOOTSTRAP=~/sdk/go1.25.6
# (--build-context go-bootstrap=$HOME/sdk/go1.25.6)
COPY --from=go-bootstrap --chown=1000:1000 . /home/exedev/sdk/go/

COPY --from=exeuntu-cli /out/exeuntu /usr/local/bin/exeuntu

# Install uv to /usr/local/bin
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# Configure systemd
RUN rm /etc/systemd/system/multi-user.target.wants/console-setup.service \
		/etc/systemd/system/multi-user.target.wants/ModemManager.service \
		/etc/systemd/system/multi-user.target.wants/snapd.* \
		/etc/systemd/system/multi-user.target.wants/unattended-upgrades.* \
		/etc/systemd/system/multi-user.target.wants/ubuntu-advantage.service && \
	systemctl mask -- getty.target \
		fwupd.service \
		fwupd-refresh.service \
		fwupd-refresh.timer \
		systemd-random-seed.service \
		iscsid.socket \
		dm-event.socket \
		man-db.timer \
		update-notifier-download.timer \
		update-notifier-motd.timer \
		atop-rotate.timer \
		dpkg-db-backup.timer \
		e2scrub_all.timer \
		etc-resolv.conf.mount \
		etc-hosts.mount \
		etc-hostname.mount \
		-.mount \
		systemd-resolved.service \
		systemd-remount-fs.service \
		systemd-sysusers.service \
		systemd-update-done.service \
		systemd-update-utmp.service \
		systemd-journal-catalog-update.service \
		modprobe@.service \
		systemd-modules-load.service \
		systemd-udevd.service \
		systemd-udevd-control.service \
		systemd-udevd-kernel.service \
		systemd-udev-trigger.service \
		systemd-udev-settle.service \
		systemd-hwdb-update.service \
		ubuntu-fan.service \
		ldconfig.service \
		unattended-upgrades.service \
		lxd-installer.socket \
	        console-getty.service \
		keyboard-setup.service \
		systemd-ask-password-console.path \
		systemd-ask-password-wall.path \
		ssh.socket \
		ssh.service \
		plymouth.service \
		plymouth-start.service \
		plymouth-quit.service \
		plymouth-quit-wait.service \
		plymouth-read-write.service \
		plymouth-switch-root.service \
		plymouth-switch-root-initramfs.service \
		plymouth-halt.service \
		plymouth-reboot.service \
		plymouth-poweroff.service \
		plymouth-kexec.service \
		apt-daily-upgrade.timer \
		apt-daily.timer \
		plymouth-log.service && \
	# systemd-logind is disabled but not masked. It's involved in populating the XDG runtime dir sockets... somehow
	systemctl disable docker.service containerd.service getty.target systemd-logind.service tailscaled.service \
		nginx.service \
                   console-getty.service \
		   atop.service \
                   getty@.service \
                   snapd.socket \
		   motd-news.timer motd-news.service \
		    apport.service apport-autoreport.timer apport-autoreport.path apport-forward.socket \
		    snapd.snap-repair.timer snapd.snap-repair.service \
		    udisks2.service \
		   ufw.service \
		   lvm2-lvmpolld.socket \
                   systemd-ask-password-wall.service \
                   systemd-ask-password-console.service \
                   systemd-machine-id-commit.service \
                   systemd-modules-load.service \
                   systemd-sysctl.service \
                   systemd-firstboot.service \
                   systemd-udevd.service \
                   systemd-udev-trigger.service \
                   systemd-udev-settle.service \
		   e2scrub_reap.service \
		   systemd-update-utmp.service \
		   atopacct.service \
		   sysstat.service \
                   systemd-hwdb-update.service \
		   multipathd.service && \
	mkdir -p /etc/systemd/system.conf.d && \
    		echo '[Manager]' > /etc/systemd/system.conf.d/container-overrides.conf && \
    		echo 'LogLevel=info' >> /etc/systemd/system.conf.d/container-overrides.conf && \
    		echo 'LogTarget=console' >> /etc/systemd/system.conf.d/container-overrides.conf && \
    		echo 'SystemCallArchitectures=native' >> /etc/systemd/system.conf.d/container-overrides.conf && \
    		echo 'DefaultOOMPolicy=continue' >> /etc/systemd/system.conf.d/container-overrides.conf && \
	mkdir -p /etc/systemd/journald.conf.d && \
		echo '[Journal]' > /etc/systemd/journald.conf.d/persistent.conf && \
		echo 'Storage=persistent' >> /etc/systemd/journald.conf.d/persistent.conf && \
	systemctl set-default multi-user.target

# Bake /etc/fstab so systemd-growfs@-.service resizes the root filesystem on
# first boot after the disk is grown.
RUN echo '/dev/vda / ext4 defaults,x-systemd.growfs 0 1' > /etc/fstab

ENV EXEUNTU=1

# https://github.com/trfore/docker-ubuntu2404-systemd/blob/main/Dockerfile suggests the following
# might be useful?
# STOPSIGNAL SIGRTMIN+3


# Copy the self-contained Chrome bundle from chromedp/headless-shell
COPY --from=chrome /headless-shell /headless-shell
ENV PATH="/usr/local/bin:/headless-shell:${PATH}"

RUN mkdir -p /home/exedev /home/exedev/.config/shelley \
    chown exedev:exedev /home/exedev /home/exedev/.config \
          /home/exedev/.config/shelley 


USER exedev

WORKDIR /home/exedev

# Update PATH in .bashrc to include .local/bin and set XDG_RUNTIME_DIR for systemd user services
# XDG paths are not autopopulated despite the presense of libpam-systemd. Manually add them here.
RUN echo 'export PATH="$HOME/.local/bin:$PATH"' >> /home/exedev/.bashrc && \
    echo 'export XDG_RUNTIME_DIR="/run/user/$(id -u)"' >> /home/exedev/.bashrc && \
    echo 'export XDG_RUNTIME_DIR="/run/user/$(id -u)"' >> /home/exedev/.profile && \
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> /home/exedev/.profile


# Configure git.
RUN git config --global init.defaultBranch main
RUN git config --global user.name "Not Neal Patel"
RUN git config --global user.email "bots@patel.codes"


# Configure preferences.
RUN echo 'export EDITOR=vim' >> /home/exedev/.profile
RUN mkdir -p /home/exedev/.yah/logs
RUN chown exedev:exedev /home/exedev/src /home/exedev/.yah /home/exedev/.yah/logs


# Switch back to root to install systemd service
USER root

# Disable Ubuntu's default MOTD (the sudo hint, etc.)
RUN rm -rf /etc/update-motd.d/* /etc/motd && touch /home/exedev/.hushlogin && chown exedev:exedev /home/exedev/.hushlogin

# Add custom MOTD to exedev's .bashrc (ignores .hushlogin - we handle that ourselves)
COPY motd-snippet.bash /tmp/motd-snippet.bash
RUN cat /tmp/motd-snippet.bash >> /home/exedev/.bashrc && rm /tmp/motd-snippet.bash

# Create systemd socket and service for Shelley (socket activation).
# The shelley binary itself is installed at vm creation.
COPY shelley.socket /etc/systemd/system/shelley.socket
COPY shelley.service /etc/systemd/system/shelley.service
RUN chmod 644 /etc/systemd/system/shelley.socket /etc/systemd/system/shelley.service && \
    systemctl enable shelley.socket

# Create systemd oneshot service for /exe.dev/setup script
COPY exe-setup.service /etc/systemd/system/exe-setup.service
RUN chmod 644 /etc/systemd/system/exe-setup.service && \
    systemctl enable exe-setup.service

# TODO(crawshaw/philip): This is called init so that exetini decides
# this wrapper script is an init, and exec's it rather than forking it.
# It would be better if you could indicate that via an env variable or something.
COPY init-wrapper.sh /usr/local/bin/init

# Shelley uses ~/.config/shelley/ (XDG convention, directory already created above)
COPY AGENTS.md /home/exedev/.config/shelley/AGENTS.md
RUN chown exedev:exedev /home/exedev/.config/shelley/AGENTS.md 

# Custom nginx config and index page (nginx is installed but disabled by default)
COPY nginx.conf /etc/nginx/sites-available/default
COPY index.html /var/www/html/index.html
RUN chmod 644 /var/www/html/index.html

# Install xterm-ghostty terminfo for Ghostty terminal support
COPY xterm-ghostty.terminfo /tmp/xterm-ghostty.terminfo
RUN tic -x - < /tmp/xterm-ghostty.terminfo && rm /tmp/xterm-ghostty.terminfo


# Expose the web server ports
EXPOSE 8000 9999

LABEL "exe.dev/login-user"="exedev"
LABEL "exe.dev/install-shelley"="true"
CMD ["/usr/local/bin/init"]
