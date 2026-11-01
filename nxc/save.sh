cp -a \
  "$(docker volume inspect docker_nxc-shared --format '{{ .Mountpoint }}')/raftly-results" \
  ./results-nxc
