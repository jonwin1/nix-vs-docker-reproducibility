.PHONY: test-docker test-docker-down

## Run tests in Docker
test-docker:
	@mkdir -p logs/scenarios
	docker compose --profile test run --build --rm test-runner

## Stop the cluster and remove containers
test-docker-down:
	docker compose down

# scenario-docker:
# 	@mkdir -p logs/scenarios
# 	docker compose -f docker/docker-compose.yml run --build --rm scenario-runner "$(NAME)"
#
# scenarios-docker:
# 	@mkdir -p logs/scenarios
# 	docker compose -f docker/docker-compose.yml run --build --rm scenario-runner all
#
