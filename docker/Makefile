.PHONY: docker-build docker-up docker-down docker-logs \
		scenarios-docker cluster-test cluster-test-all

SCENARIO ?= baseline
RAFTLY_REF ?= 235a033c44c88a3de0ddd290ab0c522b9770ed41

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

cluster-test:
	@set -eu; \
	mkdir -p logs/tests; \
	run_id="$(SCENARIO)-$$(date -u +%Y%m%dt%H%M%Sz)"; \
	node_log="logs/tests/nodes-$$run_id.log"; \
	cleanup() { \
		RAFTLY_REF="$(RAFTLY_REF)" docker compose -p "$$run_id" --profile cluster-tests logs --no-color node1 node2 node3 > "$$node_log" 2>&1 || true; \
		RAFTLY_REF="$(RAFTLY_REF)" docker compose -p "$$run_id" --profile cluster-tests down -v --remove-orphans >/dev/null 2>&1 || true; \
	}; \
	trap cleanup EXIT; \
	RAFTLY_REF="$(RAFTLY_REF)" docker compose -p "$$run_id" --profile cluster-tests build node1 node2 node3 test-runner; \
	RAFTLY_REF="$(RAFTLY_REF)" docker compose -p "$$run_id" --profile cluster-tests run --rm test-runner "$(SCENARIO)"

cluster-test-all:
	@set -eu; for scenario in baseline burst delay packet-loss follower-isolation leader-isolation; do \
		echo "===== $$scenario ====="; \
		$(MAKE) cluster-test SCENARIO=$$scenario RAFTLY_REF=$(RAFTLY_REF); \
	done

scenarios-docker:
	@mkdir -p logs/scenarios
	RAFTLY_REF="$(RAFTLY_REF)" docker compose --profile scenarios run --build --rm scenario-runner
