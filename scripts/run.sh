#!/usr/bin/env bash

echo "Cleaning all caches"
./scripts/clean.sh

echo "Building environments"
mkdir -p results/build
./scripts/collect.sh docker
./scripts/collect.sh nxc

echo "Running docker scenarios"
cd docker || (echo "cd docker: failed" && exit)
make scenarios
make cluster-tests
docker compose down
cd ..
mkdir -p results/docker
mv docker/logs/* results/docker/

echo "Running nxc scenarios"
cd nxc || (echo "cd nxc: failed" && exit)
nxc build
nxc start -t
cp -a "$(docker volume inspect docker_nxc-shared --format '{{ .Mountpoint }}')/raftly-results" ./results
cd ..
mkdir -p results/nxc
mv nxc/results/* results/nxc/

mv results results-"$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "All experiments completed"
