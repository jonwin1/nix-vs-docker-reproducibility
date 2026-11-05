#!/usr/bin/env bash

rm -rf ./docker/logs ./nxc/results --verbose
rm -rf ./nxc/artifact/ ./nxc/build/ ./nxc/deploy/ --verbose
docker system prune --all --volumes --force
docker volume prune --all --force
sudo nix-collect-garbage -d
