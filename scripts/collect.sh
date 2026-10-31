#!/usr/bin/env bash
# Build one Raftly environment and collect reproducibility data.
# Usage: scripts/collect.sh docker|nxc
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage: collect.sh docker|nxc

Environment overrides:
  PROJECT_ROOT         Project root (default: detected from Git)
  RESULT_ROOT          Result directory (default: PROJECT_ROOT/repro-results)
  RUN_ID               Run identifier (default: UTC timestamp + method)
  NXC_COMPOSE_PROJECT  NXC Docker Compose project name (default: docker)
  NXC_NIX_FLAGS        Flags passed to nxc build (default: --rebuild)
USAGE
}

METHOD="${1:-}"
if [[ "$METHOD" != "docker" && "$METHOD" != "nxc" ]]; then
  usage >&2
  exit 2
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -n "${PROJECT_ROOT:-}" ]]; then
  ROOT="$PROJECT_ROOT"
else
  ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$ROOT" ]] || ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
fi
ROOT="$(cd -- "$ROOT" && pwd -P)"
DOCKER_COMPOSE_FILE="$ROOT/docker/docker-compose.yml"
NXC_DIR="$ROOT/nxc"
NXC_BUILD_LINK="$NXC_DIR/build/composition::docker"
RESULT_ROOT="${RESULT_ROOT:-$ROOT/repro-results}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dt%H%M%sz)-$METHOD-$$}"
NXC_COMPOSE_PROJECT="${NXC_COMPOSE_PROJECT:-docker}"
NXC_NIX_FLAGS="${NXC_NIX_FLAGS:---rebuild}"

if [[ ! "$RUN_ID" =~ ^[a-z0-9][a-z0-9-]*$ ]] || (( ${#RUN_ID} > 45 )); then
  echo "RUN_ID must be at most 45 characters and contain only lowercase letters, numbers, and hyphens." >&2
  exit 2
fi

OUT="$RESULT_ROOT/$RUN_ID"
RAFTLY_SERVICES=(node1 node2 node3)
DOCKER_BINARY_PATH="/bin/raftly-server"
NXC_STARTED=0
DOCKER_COMPOSE_ACTIVE=0
START_EPOCH="$(date +%s)"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command not found: $1" >&2
    exit 1
  }
}

need git
need python3
need docker
need sha256sum
need sort

docker compose version >/dev/null
[[ -f "$DOCKER_COMPOSE_FILE" ]] || { echo "Missing $DOCKER_COMPOSE_FILE" >&2; exit 1; }
[[ -f "$NXC_DIR/composition.nix" ]] || { echo "Missing $NXC_DIR/composition.nix" >&2; exit 1; }
[[ -d "$ROOT/raftly/.git" || -f "$ROOT/raftly/.git" ]] || {
  echo "The raftly Git submodule was not found at $ROOT/raftly" >&2
  exit 1
}
[[ ! -e "$OUT" ]] || { echo "Run directory already exists: $OUT" >&2; exit 1; }

if [[ "$METHOD" == "nxc" ]]; then
  need nix
  need nxc
fi

# Docker builds from the Raftly submodule directory. Reject local changes so
# that the recorded submodule commit identifies the Docker build context.
RAFTLY_STATUS="$(git -C "$ROOT/raftly" status --porcelain=v1 --untracked-files=all)"
if [[ -n "$RAFTLY_STATUS" ]]; then
  echo "The raftly submodule has local or untracked changes:" >&2
  printf '%s\n' "$RAFTLY_STATUS" >&2
  echo "Commit or remove these changes before collecting a run." >&2
  exit 1
fi

RAFTLY_COMMIT="$(git -C "$ROOT/raftly" rev-parse HEAD)"
ROOT_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
ROOT_STATUS="$(git -C "$ROOT" status --porcelain=v1 --untracked-files=all)"
ROOT_DIRTY=false
[[ -z "$ROOT_STATUS" ]] || ROOT_DIRTY=true

# nxc/raftly.nix fetches Raftly from GitHub independently of the submodule.
# Record both revisions so cross-method comparisons can detect a mismatch.
NIX_RAFTLY_REV="$(python3 - "$NXC_DIR/raftly.nix" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
match = re.search(r'rev\s*=\s*"([0-9a-f]{40})"', text)
print(match.group(1) if match else "")
PY
)"

mkdir -p "$OUT/nodes"

# Record provenance without copying the source files into every run.
{
  printf 'experiment_repository_commit=%s\n' "$ROOT_COMMIT"
  printf 'experiment_repository_dirty=%s\n' "$ROOT_DIRTY"
  printf 'raftly_submodule_commit=%s\n' "$RAFTLY_COMMIT"
  printf 'raftly_submodule_dirty=false\n'
  printf 'nix_raftly_source_revision=%s\n' "${NIX_RAFTLY_REV:-unknown}"
  printf 'nix_source_matches_submodule=%s\n' "$([[ -n "$NIX_RAFTLY_REV" && "$NIX_RAFTLY_REV" == "$RAFTLY_COMMIT" ]] && echo true || echo false)"
} > "$OUT/source.txt"
printf '%s\n' "$ROOT_STATUS" > "$OUT/experiment-repository-status.txt"
git -C "$ROOT/raftly" ls-files --others --ignored --exclude-standard \
  > "$OUT/raftly-ignored-files.txt"

# Hash the build definitions and dependency locks. These hashes are sufficient
# to detect changed inputs when the repository and submodule commits are fixed.
INPUT_FILES=(
  docker/docker-compose.yml
  .gitmodules
  flake.lock
  nxc/nxc.json
  nxc/flake.nix
  nxc/flake.lock
  nxc/composition.nix
  nxc/raftly.nix
  raftly/docker/docker-compose.yml
  raftly/docker/Dockerfile
  raftly/.dockerignore
  raftly/go.mod
  raftly/go.sum
  raftly/ui/package.json
  raftly/ui/package-lock.json
)
: > "$OUT/input-hashes.txt"
for rel in "${INPUT_FILES[@]}"; do
  if [[ -f "$ROOT/$rel" ]]; then
    (cd "$ROOT" && sha256sum "$rel") >> "$OUT/input-hashes.txt"
  fi
done

awk 'toupper($1) == "FROM" { for (i=2; i<=NF; i++) if ($i !~ /^--/) { print $i; break } }' \
  "$ROOT/raftly/docker/Dockerfile" | sort -u > "$OUT/docker-base-image-refs.txt"

python3 - "$OUT/metadata.json" "$METHOD" "$RUN_ID" "$ROOT" "$ROOT_COMMIT" "$ROOT_DIRTY" "$RAFTLY_COMMIT" "$NIX_RAFTLY_REV" <<'PY'
import json, platform, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path
out, method, run_id, root, root_commit, root_dirty, raftly_commit, nix_rev = sys.argv[1:]
root_path = Path(root)

def command(*args):
    try:
        return subprocess.check_output(args, stderr=subprocess.STDOUT, text=True).strip()
    except Exception:
        return None

locked_inputs = {}
try:
    lock = json.loads((root_path / "nxc" / "flake.lock").read_text(encoding="utf-8"))
    for name in ("nixpkgs", "nxc"):
        node = lock.get("nodes", {}).get(name, {}).get("locked", {})
        locked_inputs[name] = {
            key: node[key]
            for key in ("rev", "ref", "narHash", "type")
            if key in node
        }
except (OSError, json.JSONDecodeError):
    pass

metadata = {
    "run_id": run_id,
    "method": method,
    "started_at": datetime.now(timezone.utc).isoformat(),
    "host": platform.node(),
    "architecture": platform.machine(),
    "platform": platform.platform(),
    "experiment_repository_commit": root_commit,
    "experiment_repository_dirty": root_dirty == "true",
    "raftly_submodule_commit": raftly_commit,
    "nix_raftly_source_revision": nix_rev or None,
    "nix_source_matches_submodule": bool(nix_rev and nix_rev == raftly_commit),
    "nxc_locked_inputs": locked_inputs,
    "tools": {
        "docker": command("docker", "--version"),
        "docker_client_server": command("docker", "version", "--format", "{{.Client.Version}} / {{.Server.Version}}"),
        "docker_compose": command("docker", "compose", "version", "--short"),
        "buildx": command("docker", "buildx", "version"),
        "nix": command("nix", "--version"),
        "nxc": command("nxc", "--version"),
        "go": command("go", "version"),
    },
}
Path(out).write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
PY

if [[ "$ROOT_DIRTY" == true ]]; then
  log "WARNING: experiment repository is dirty; see experiment-repository-status.txt."
fi
if [[ -z "$NIX_RAFTLY_REV" || "$NIX_RAFTLY_REV" != "$RAFTLY_COMMIT" ]]; then
  log "WARNING: the Raftly revision in nxc/raftly.nix does not match the submodule commit."
fi

# Cleanup is limited to this run's Compose project and node services.
cleanup() {
  local status=$?
  trap - EXIT
  set +e

  if [[ "$METHOD" == "docker" && "$DOCKER_COMPOSE_ACTIVE" -eq 1 ]]; then
    docker compose -f "$DOCKER_COMPOSE_FILE" -p "raftly-repro-$RUN_ID" \
      down --volumes --remove-orphans >/dev/null 2>&1
  elif [[ "$METHOD" == "nxc" && "$NXC_STARTED" -eq 1 ]]; then
    (cd "$NXC_DIR" && nxc stop -f docker) >/dev/null 2>&1
    for node in "${RAFTLY_SERVICES[@]}"; do
      mapfile -t ids < <(docker ps -aq \
        --filter "label=com.docker.compose.project=$NXC_COMPOSE_PROJECT" \
        --filter "label=com.docker.compose.service=$node")
      if [[ ${#ids[@]} -gt 0 ]]; then
        docker rm -f "${ids[@]}" >/dev/null 2>&1
      fi
    done
  fi

  python3 - "$OUT/result.json" "$status" "$START_EPOCH" <<'PY'
import json, sys
from datetime import datetime, timezone
path, status, start = sys.argv[1:]
now = datetime.now(timezone.utc)
result = {
    "status": "success" if int(status) == 0 else "failed",
    "exit_code": int(status),
    "finished_at": now.isoformat(),
    "duration_seconds": int(now.timestamp()) - int(start),
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(result, handle, indent=2)
    handle.write("\n")
PY

  if [[ $status -eq 0 ]]; then
    log "Collection complete: $OUT"
  else
    log "Collection failed (exit $status). Results and logs are in: $OUT"
  fi
  exit "$status"
}
trap cleanup EXIT

collect_node() {
  local node="$1" cid="$2" image_id="$3" binary_path="$4"
  local node_dir="$OUT/nodes/$node"
  mkdir -p "$node_dir"

  log "Collecting $node image $image_id."
  docker image inspect "$image_id" > "$node_dir/image-inspect.json"
  docker inspect "$cid" > "$node_dir/container-inspect.json"

  # Copy from the actual node container. This works for running and stopped
  # containers, so no temporary container or dummy command is needed.
  docker cp "$cid:$binary_path" "$node_dir/raftly-server"
  sha256sum "$node_dir/raftly-server" > "$node_dir/raftly-server.sha256"
  if command -v go >/dev/null 2>&1; then
    go version -m "$node_dir/raftly-server" \
      > "$node_dir/raftly-server.go-version.txt" 2>&1 || true
  fi

  # Docker's runtime image is Alpine. NXC's software inventory is the Nix
  # closure collected at composition level below.
  if [[ "$METHOD" == "docker" ]]; then
    docker run --rm --network none --entrypoint /sbin/apk "$image_id" info -v --no-network \
      | sort > "$node_dir/apk-packages.txt"
  fi
}

if [[ "$METHOD" == "docker" ]]; then
  COMPOSE=(docker compose -f "$DOCKER_COMPOSE_FILE" -p "raftly-repro-$RUN_ID")
  log "Building node1, node2 and node3 without the Docker build cache."
  BUILD_START="$(date +%s)"
  "${COMPOSE[@]}" --progress plain build --no-cache "${RAFTLY_SERVICES[@]}" \
    2>&1 | tee "$OUT/build.log"
  printf '%s\n' "$(( $(date +%s) - BUILD_START ))" > "$OUT/build-duration-seconds.txt"

  : > "$OUT/docker-base-image-identities.txt"
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    printf '%s\t' "$ref" >> "$OUT/docker-base-image-identities.txt"
    if docker image inspect "$ref" >/dev/null 2>&1; then
      docker image inspect "$ref" \
        --format '{{.Id}} {{json .RepoDigests}} {{.Architecture}}' \
        >> "$OUT/docker-base-image-identities.txt"
    else
      printf 'NOT_FOUND_AFTER_BUILD\n' >> "$OUT/docker-base-image-identities.txt"
    fi
  done < "$OUT/docker-base-image-refs.txt"

  log "Creating the three Raftly node containers."
  DOCKER_COMPOSE_ACTIVE=1
  "${COMPOSE[@]}" create --no-build "${RAFTLY_SERVICES[@]}" \
    2>&1 | tee "$OUT/create.log"

  for node in "${RAFTLY_SERVICES[@]}"; do
    mapfile -t ids < <("${COMPOSE[@]}" ps -aq "$node")
    if [[ ${#ids[@]} -ne 1 ]]; then
      echo "Expected one container for $node, found ${#ids[@]}." >&2
      exit 1
    fi
    cid="${ids[0]}"
    image_id="$(docker inspect --format '{{.Image}}' "$cid")"
    collect_node "$node" "$cid" "$image_id" "$DOCKER_BINARY_PATH"
  done

else
  # NXC 25.05 uses project name 'docker' in the observed deployment. Refuse
  # to touch an existing deployment with the same project and service labels.
  for node in "${RAFTLY_SERVICES[@]}"; do
    mapfile -t existing < <(docker ps -aq \
      --filter "label=com.docker.compose.project=$NXC_COMPOSE_PROJECT" \
      --filter "label=com.docker.compose.service=$node")
    if [[ ${#existing[@]} -gt 0 ]]; then
      echo "Found an existing NXC container for $node in Compose project '$NXC_COMPOSE_PROJECT'." >&2
      echo "Stop that deployment or set NXC_COMPOSE_PROJECT to the correct project name." >&2
      exit 1
    fi
  done

  log "Building NixOS Compose from $NXC_DIR."
  BUILD_START="$(date +%s)"
  (cd "$NXC_DIR" && nxc build -f docker --nix-flags="$NXC_NIX_FLAGS") \
    2>&1 | tee "$OUT/build.log"
  printf '%s\n' "$(( $(date +%s) - BUILD_START ))" > "$OUT/build-duration-seconds.txt"

  [[ -e "$NXC_BUILD_LINK" ]] || {
    echo "Expected NixOS Compose build result at $NXC_BUILD_LINK" >&2
    exit 1
  }
  BUILD_REF="$(readlink -f "$NXC_BUILD_LINK")"
  printf '%s\n' "$BUILD_REF" > "$OUT/nix-build-ref.txt"
  nix path-info --recursive --json "$BUILD_REF" > "$OUT/nix-closure.json"

  # Turn Nix's closure output into a package/store inventory and find the
  # Raftly executable path used by the node system configurations.
  python3 - "$OUT/nix-closure.json" "$OUT/nix-store-inventory.json" "$OUT/nix-raftly-binary-path.txt" <<'PY'
import json, os, sys
source, inventory_path, binary_path_file = sys.argv[1:]
data = json.load(open(source, encoding="utf-8"))
if isinstance(data, dict):
    rows = []
    for path, value in data.items():
        row = dict(value)
        row.setdefault("path", path)
        rows.append(row)
else:
    rows = data
inventory = []
binaries = []
for row in sorted(rows, key=lambda item: item.get("path", "")):
    path = row.get("path", "")
    inventory.append({
        "store_path": path,
        "store_name": os.path.basename(path).split("-", 1)[-1],
        "nar_hash": row.get("narHash"),
        "nar_size": row.get("narSize"),
        "references": row.get("references", []),
    })
    store_name = os.path.basename(path).split("-", 1)[-1]
    binary = os.path.join(path, "bin", "raftly-server")
    if store_name.startswith("raftly-server-") and os.path.isfile(binary):
        binaries.append(binary)
with open(inventory_path, "w", encoding="utf-8") as handle:
    json.dump(inventory, handle, indent=2)
    handle.write("\n")
if len(binaries) != 1:
    print(f"Expected one raftly-server binary in the Nix closure, found {len(binaries)}.", file=sys.stderr)
    sys.exit(1)
with open(binary_path_file, "w", encoding="utf-8") as handle:
    handle.write(binaries[0] + "\n")
PY
  NXC_BINARY_PATH="$(cat "$OUT/nix-raftly-binary-path.txt")"

  log "Starting the NixOS Compose Docker deployment."
  NXC_STARTED=1
  (cd "$NXC_DIR" && nxc start -f docker) 2>&1 | tee "$OUT/start.log"

  for node in "${RAFTLY_SERVICES[@]}"; do
    mapfile -t ids < <(docker ps -q \
      --filter "label=com.docker.compose.project=$NXC_COMPOSE_PROJECT" \
      --filter "label=com.docker.compose.service=$node")
    if [[ ${#ids[@]} -ne 1 ]]; then
      echo "Expected one running NXC container for $node in Compose project '$NXC_COMPOSE_PROJECT'; found ${#ids[@]}." >&2
      echo "Check NXC_COMPOSE_PROJECT and $OUT/start.log." >&2
      exit 1
    fi
    cid="${ids[0]}"
    image_id="$(docker inspect --format '{{.Image}}' "$cid")"
    collect_node "$node" "$cid" "$image_id" "$NXC_BINARY_PATH"
  done
fi
