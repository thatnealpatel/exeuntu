default: build-exeuntu

build-exeuntu: ## Build the exeuntu Docker image locally
	@echo "Building exeuntu Docker image..."
	docker build -t thatnealpatel/exeuntu:latest \
		--build-context go-src=$(HOME)/w/go \
		--build-context go-bootstrap=$(HOME)/sdk/go1.25.6 \
		--build-context tools=$(HOME)/go/bin \
		.
	@echo "✓ built thatnealpatel/exeuntu:latest"

build: build-exeuntu

publish: build-exeuntu
	docker push thatnealpatel/exeuntu:latest
	@echo "✓ published thatnealpatel/exeuntu:latest"

run: build-exeuntu
	docker run -it \
	  --cap-add=ALL \
	  --security-opt seccomp=unconfined \
	  --security-opt apparmor=unconfined \
	  --cgroupns private \
	  --tmpfs /run \
	  --tmpfs /run/lock \
	  --tmpfs /tmp \
	  --tmpfs /sys/fs/cgroup:rw \
	  thatnealpatel/exeuntu:latest

run-bash: build-exeuntu
	docker run -it \
	  --cap-add=ALL \
	  --security-opt seccomp=unconfined \
	  --security-opt apparmor=unconfined \
	  --cgroupns private \
	  --tmpfs /run \
	  --tmpfs /run/lock \
	  --tmpfs /tmp \
	  --tmpfs /sys/fs/cgroup:rw \
	  thatnealpatel/exeuntu:latest bash
