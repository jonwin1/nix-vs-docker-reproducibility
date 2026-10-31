nix path-info \
  --recursive \
  --json \
  "$(readlink -f build/<composition-name>::docker)" \
  > nix-closure.json

nix store diff-closures OLD_PATH NEW_PATH
