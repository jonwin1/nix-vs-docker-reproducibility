.PHONY: test-docker test-docker-down

## Run tests in Docker
test-docker:
	@mkdir -p logs/scenarios
	docker compose --profile test run --build --rm test-runner

## Stop the cluster and remove containers
test-docker-down:
	docker compose down
