docker image inspect IMAGE_NAME > image-inspect.json
docker buildx build -f ../raftly/docker/Dockerfile ../raftly/ --no-cache --pull
