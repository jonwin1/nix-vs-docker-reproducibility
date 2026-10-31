.PHONY: all scenarios cluster-tests build clean-all

all: scenarios cluster-tests

scenarios:
	@mkdir -p logs/scenarios
	export SOURCE_DATE_EPOCH=0
	docker compose --profile scenarios build scenario-runner --no-cache --pull
	docker compose --profile scenarios run --rm scenario-runner --no-cache --pull

cluster-tests:
	@mkdir -p logs/cluster-tests
	export SOURCE_DATE_EPOCH=0
	docker compose --profile cluster-tests build node1 node2 node3 test-runner --no-cache --pull
	@failed=0; \
	for scenario in baseline burst delay packet-loss follower-isolation leader-isolation; do \
		echo; echo "########## $$scenario ##########"; \
		if docker compose --profile cluster-tests run --rm test-runner "$$scenario" --no-cache --pull; then \
			echo "SCENARIO RESULT: PASS ($$scenario)"; \
		else \
			echo "SCENARIO RESULT: FAIL ($$scenario)"; failed=1; \
		fi; \
	done; \
	if [ $$failed -eq 0 ]; then echo "ALL SCENARIOS FINISHED"; else echo "ONE OR MORE SCENARIOS FAILED"; fi; \
	exit $$failed

build:
	./scripts/build.sh

clean-all:
	docker system prune --all --force
