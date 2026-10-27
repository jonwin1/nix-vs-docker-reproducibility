.PHONY: docker-build docker-up docker-down docker-logs \
		scenarios cluster-test cluster-test-all

SCENARIO ?= baseline
RAFTLY_REF ?= 235a033c44c88a3de0ddd290ab0c522b9770ed41

## Build the Docker image
docker-build:
	RAFTLY_REF="$(RAFTLY_REF)" docker compose build

## Start the 3-node cluster + Prometheus + Grafana
docker-up:
	RAFTLY_REF="$(RAFTLY_REF)" docker compose up -d
	@echo "Cluster up — HTTP: :8001/:8002/:8003  Metrics: :9090  Grafana: :3000"

## Stop and remove containers (data volumes are kept)
docker-down:
	RAFTLY_REF="$(RAFTLY_REF)" docker compose down

## Tail logs from all containers
docker-logs:
	RAFTLY_REF="$(RAFTLY_REF)" docker compose logs -f

scenarios:
	@mkdir -p logs/scenarios
	RAFTLY_REF="$(RAFTLY_REF)" docker compose --profile scenarios build scenario-runner
	RAFTLY_REF="$(RAFTLY_REF)" docker compose --profile scenarios run --rm scenario-runner

cluster-test:
	@mkdir -p logs/cluster-tests
	RAFTLY_REF="$(RAFTLY_REF)" docker compose --profile cluster-tests build node1 node2 node3 test-runner
	RAFTLY_REF="$(RAFTLY_REF)" docker compose --profile cluster-tests run --rm test-runner "$(SCENARIO)"

# Runs every scenario. Each scenario writes its own log file.
cluster-test-all:
	@mkdir -p logs/cluster-tests
	RAFTLY_REF="$(RAFTLY_REF)" docker compose --profile cluster-tests build node1 node2 node3 test-runner
	@failed=0; \
	for scenario in baseline burst delay packet-loss follower-isolation leader-isolation; do \
		echo; echo "########## $$scenario ##########"; \
		if RAFTLY_REF="$(RAFTLY_REF)" docker compose --profile cluster-tests run --rm test-runner "$$scenario"; then \
			echo "SCENARIO RESULT: PASS ($$scenario)"; \
		else \
			echo "SCENARIO RESULT: FAIL ($$scenario)"; failed=1; \
		fi; \
	done; \
	if [ $$failed -eq 0 ]; then echo "ALL SCENARIOS FINISHED"; else echo "ONE OR MORE SCENARIOS FAILED"; fi; \
	exit $$failed
