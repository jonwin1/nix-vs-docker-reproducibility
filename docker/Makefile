.PHONY: scenarios cluster-tests

scenarios:
	@mkdir -p logs/scenarios
	docker compose --profile scenarios build scenario-runner
	docker compose --profile scenarios run --rm scenario-runner

cluster-tests:
	@mkdir -p logs/cluster-tests
	docker compose --profile cluster-tests build node1 node2 node3 test-runner
	@failed=0; \
	for scenario in baseline burst delay packet-loss follower-isolation leader-isolation; do \
		echo; echo "########## $$scenario ##########"; \
		if docker compose --profile cluster-tests run --rm test-runner "$$scenario"; then \
			echo "SCENARIO RESULT: PASS ($$scenario)"; \
		else \
			echo "SCENARIO RESULT: FAIL ($$scenario)"; failed=1; \
		fi; \
	done; \
	if [ $$failed -eq 0 ]; then echo "ALL SCENARIOS FINISHED"; else echo "ONE OR MORE SCENARIOS FAILED"; fi; \
	exit $$failed
