.PHONY: docker-build docker-up docker-down docker-logs scenarios-docker

## Build the Docker image
docker-build:
	docker compose build

## Start the 3-node cluster + Prometheus + Grafana
docker-up:
	docker compose up -d
	@echo "Cluster up — HTTP: :8001/:8002/:8003  Metrics: :9090  Grafana: :3000"

## Stop and remove containers (data volumes are kept)
docker-down:
	docker compose down

## Tail logs from all containers
docker-logs:
	docker compose logs -f

## Run tests in Docker
test-docker:
	@mkdir -p logs/scenarios
	docker compose --profile test run --build --rm test-runner

## Stop the cluster and remove containers
test-docker-down:
	docker compose down

scenarios-docker:
	@mkdir -p logs/scenarios
	docker compose --profile scenarios run --build --rm scenario-runner
