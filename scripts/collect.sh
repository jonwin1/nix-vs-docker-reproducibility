#!/usr/bin/env bash
# Build one Raftly environment and collect reproducibility data.
# Usage: scripts/collect.sh docker|nxc
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage: collect.sh docker|nxc

Environment overrides:
  PROJECT_ROOT       Project root (default: detected from Git)
  RESULT_ROOT        Result directory (default: PROJECT_ROOT/repro-results)
  RUN_ID             Run identifier (default: UTC timestamp + method)
  TRIVY              Set to 0 to skip the optional Trivy SBOM
  NXC_NIX_FLAGS      Nix flags passed by nxc build (default: --rebuild)
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
NXC_COMPOSITION="$NXC_DIR/composition.nix"
NXC_BUILD_LINK="$NXC_DIR/build/composition::docker"
RESULT_ROOT="${RESULT_ROOT:-$ROOT/repro-results}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dt%H%M%sz)-$METHOD}"

if [[ ! "$RUN_ID" =~ ^[a-z0-9][a-z0-9-]*$ ]] || (( ${#RUN_ID} > 45 )); then
  echo "RUN_ID must be at most 45 characters and contain only lowercase letters, numbers, and hyphens." >&2
  exit 2
fi

OUT="$RESULT_ROOT/$RUN_ID"
RAFTLY_SERVICES=(node1 node2 node3)
RAFTLY_BINARY_PATH="/bin/raftly-server"
TRIVY="${TRIVY:-1}"
NXC_NIX_FLAGS="${NXC_NIX_FLAGS:---rebuild}"
NXC_STARTED=0
NXC_CONTAINER_IDS=()
START_EPOCH="$(date +%s)"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command not found: $1" >&2
    exit 1
  }
}

[[ -d "$ROOT/raftly/.git" || -f "$ROOT/raftly/.git" ]] || {
  echo "The raftly Git submodule was not found at $ROOT/raftly" >&2
  exit 1
}
[[ -f "$DOCKER_COMPOSE_FILE" ]] || { echo "Missing $DOCKER_COMPOSE_FILE" >&2; exit 1; }
[[ -f "$NXC_COMPOSITION" ]] || { echo "Missing $NXC_COMPOSITION" >&2; exit 1; }
[[ ! -e "$OUT" ]] || { echo "Run directory already exists: $OUT" >&2; exit 1; }

need git
need python3
need docker
need sha256sum

docker compose version >/dev/null

if [[ "$METHOD" == "nxc" ]]; then
  need nix
  need nxc
fi

mkdir -p "$OUT/inputs" "$OUT/nodes"

# Record ignored files separately. Docker may still send them as build context
# unless .dockerignore excludes them.
git -C "$ROOT/raftly" ls-files --others --ignored --exclude-standard \
  > "$OUT/inputs/raftly-ignored-files.txt"

# The Docker build context is the Raftly submodule. Require it to be clean so
# that its recorded commit and archived source are the exact tracked build context.
RAFTLY_STATUS="$(git -C "$ROOT/raftly" status --porcelain=v1 --untracked-files=all)"
if [[ -n "$RAFTLY_STATUS" ]]; then
  printf '%s\n' "$RAFTLY_STATUS" > "$OUT/inputs/raftly-git-status.txt"
  echo "The raftly submodule has local changes or untracked files." >&2
  echo "Commit or remove them before collecting a reproducibility run." >&2
  exit 1
fi

# Preserve the exact checked-out application source. This helps later
# reconstruction without depending only on the availability of the submodule URL.
RAFTLY_COMMIT="$(git -C "$ROOT/raftly" rev-parse HEAD)"
git -C "$ROOT/raftly" archive --format=tar --prefix=raftly/ HEAD \
  > "$OUT/inputs/raftly-source.tar"
printf '%s\n' "$RAFTLY_COMMIT" > "$OUT/inputs/raftly-commit.txt"
git -C "$ROOT/raftly" remote get-url origin > "$OUT/inputs/raftly-origin.txt" 2>/dev/null || true

# Copy the experiment definitions and all direct build manifests.
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
: > "$OUT/inputs/files.sha256"
for rel in "${INPUT_FILES[@]}"; do
  src="$ROOT/$rel"
  if [[ -f "$src" ]]; then
    mkdir -p "$OUT/inputs/source-files/$(dirname "$rel")"
    cp -p "$src" "$OUT/inputs/source-files/$rel"
    (cd "$ROOT" && sha256sum "$rel") >> "$OUT/inputs/files.sha256"
  fi
done
sha256sum "$OUT/inputs/raftly-source.tar" > "$OUT/inputs/raftly-source.tar.sha256"

# Capture parent repository and submodule provenance.
git -C "$ROOT" rev-parse HEAD > "$OUT/inputs/experiment-repository-commit.txt" 2>/dev/null || true
git -C "$ROOT" status --porcelain=v1 --untracked-files=all > "$OUT/inputs/experiment-repository-status.txt" 2>/dev/null || true
git -C "$ROOT" submodule status -- raftly > "$OUT/inputs/submodules.txt" 2>&1 || true

# The Nix build downloads Raftly at the revision in raftly.nix. Record whether
# that revision equals the submodule revision used by the Docker build.
NIX_RAFTLY_REV="$(python3 - "$NXC_DIR/raftly.nix" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'rev\s*=\s*"([0-9a-f]{40})"', text)
print(m.group(1) if m else "")
PY
)"

python3 - "$OUT/metadata.json" "$METHOD" "$RUN_ID" "$ROOT" "$RAFTLY_COMMIT" "$NIX_RAFTLY_REV" <<'PY'
import json, platform, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path
out, method, run_id, root, raftly_commit, nix_rev = sys.argv[1:]
root_path = Path(root)


def command(*args):
    try:
        return subprocess.check_output(args, stderr=subprocess.STDOUT, text=True).strip()
    except Exception:
        return None

locked = {}
try:
    lock = json.loads((root_path / "nxc" / "flake.lock").read_text(encoding="utf-8"))
    for name in ("nixpkgs", "nxc"):
        node = lock.get("nodes", {}).get(name, {}).get("locked", {})
        locked[name] = {key: node.get(key) for key in ("rev", "ref", "narHash", "type") if node.get(key) is not None}
except Exception:
    pass

meta = {
    "run_id": run_id,
    "method": method,
    "started_at": datetime.now(timezone.utc).isoformat(),
    "project_root": root,
    "host": platform.node(),
    "architecture": platform.machine(),
    "platform": platform.platform(),
    "raftly_submodule_commit": raftly_commit,
    "nix_raftly_source_revision": nix_rev or None,
    "raftly_source_revision_matches": bool(nix_rev and nix_rev == raftly_commit),
    "nxc_locked_inputs": locked,
    "tools": {
        "docker": command("docker", "--version"),
        "docker_client_server": command("docker", "version", "--format", "{{.Client.Version}} / {{.Server.Version}}"),
        "docker_compose": command("docker", "compose", "version", "--short"),
        "buildx": command("docker", "buildx", "version"),
        "nix": command("nix", "--version"),
        "nxc": command("nxc", "--version"),
        "trivy": command("trivy", "--version"),
        "go": command("go", "version"),
    },
}
Path(out).write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
PY

# Cleanup only resources belonging to this invocation.
cleanup() {
  local status=$?
  set +e
  if [[ "$METHOD" == "docker" ]]; then
    docker compose -f "$DOCKER_COMPOSE_FILE" -p "raftly-repro-$RUN_ID" \
      down --volumes --remove-orphans >/dev/null 2>&1
  elif [[ "$METHOD" == "nxc" && "$NXC_STARTED" -eq 1 ]]; then
    (cd "$NXC_DIR" && nxc stop -f docker) >/dev/null 2>&1

    # nxc stop stops the containers but may leave them behind. Remove only
    # this run's node containers; keep images and named volumes intact.
    for cid in "${NXC_CONTAINER_IDS[@]}"; do
      docker rm -f "$cid" >/dev/null 2>&1
    done
    if [[ -f "$OUT/docker-containers-before.txt" ]]; then
      while IFS= read -r cid; do
        [[ -n "$cid" ]] || continue
        service="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
        workdir="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$cid" 2>/dev/null || true)"
        config_files="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$cid" 2>/dev/null || true)"
        case "$service" in
          node1|node2|node3)
            if { [[ "$workdir" == "$NXC_DIR" || "$workdir" == "$NXC_DIR/"* || "$config_files" == *"$NXC_DIR"* ]] \
                 || ! grep -qxF "$cid" "$OUT/docker-containers-before.txt"; }; then
              docker rm -f "$cid" >/dev/null 2>&1
            fi
            ;;
        esac
      done < <(docker ps -aq 2>/dev/null)
    fi
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
with open(path, "w", encoding="utf-8") as f:
    json.dump(result, f, indent=2)
    f.write("\n")
PY
  if [[ $status -eq 0 ]]; then
    log "Collection complete: $OUT"
  else
    log "Collection failed (exit $status). Results and logs are in: $OUT"
  fi
  exit "$status"
}
trap cleanup EXIT

collect_image() {
  local node="$1" cid="$2" image_id="$3"
  local node_dir="$OUT/nodes/$node"
  mkdir -p "$node_dir"

  printf '%s\n' "$cid" > "$node_dir/container-id.txt"
  printf '%s\n' "$image_id" > "$node_dir/image-id.txt"
  docker image inspect "$image_id" > "$node_dir/image-inspect.json"
  docker inspect "$cid" > "$node_dir/container-inspect.json"

  # Copy the final application binary from the image without starting it.
  local temp_cid
  temp_cid="$(docker create "$image_id")"
  if docker cp "$temp_cid:$RAFTLY_BINARY_PATH" "$node_dir/raftly-server" >/dev/null 2>&1; then
    sha256sum "$node_dir/raftly-server" > "$node_dir/raftly-server.sha256"
    if command -v go >/dev/null 2>&1; then
      go version -m "$node_dir/raftly-server" > "$node_dir/raftly-server.go-version.txt" 2>&1 || true
    fi
  else
    echo "Could not copy $RAFTLY_BINARY_PATH from $image_id" > "$node_dir/binary-not-collected.txt"
  fi
  docker rm "$temp_cid" >/dev/null

  # The current Docker runtime image is Alpine. This records installed runtime
  # packages without relying on a scanner database or network access.
  if docker run --rm --network none --entrypoint /sbin/apk "$image_id" info -v \
      > "$node_dir/apk-packages.txt" 2> "$node_dir/apk-packages.err"; then
    :
  else
    echo "apk inventory not available for this image; see apk-packages.err" \
      > "$node_dir/apk-packages-warning.txt"
  fi

  # Optional CycloneDX SBOM. The apk list above remains the primary runtime
  # package inventory and is available even when Trivy is not installed.
  if [[ "$TRIVY" == "1" ]] && command -v trivy >/dev/null 2>&1; then
    trivy image --format cyclonedx --output "$node_dir/sbom.cdx.json" "$image_id" \
      > "$node_dir/trivy.log" 2>&1 || echo "Trivy failed; see trivy.log" \
      > "$node_dir/trivy-warning.txt"
  fi
}

if [[ "$METHOD" == "docker" ]]; then
  command -v trivy >/dev/null 2>&1 || [[ "$TRIVY" == "0" ]] || \
    log "Trivy not found; package data will still be collected with apk info -v."

  COMPOSE=(docker compose -f "$DOCKER_COMPOSE_FILE" -p "raftly-repro-$RUN_ID")
  log "Saving resolved Docker Compose configuration."
  "${COMPOSE[@]}" config --format json > "$OUT/inputs/compose-resolved.json"

  # Record base-image references before the build, then save the resolved local
  # image IDs after the build. Do not use --pull: repeat runs reuse the same
  # locally cached base tags unless the user deliberately changes them.
  awk 'toupper($1) == "FROM" { for (i=2; i<=NF; i++) if ($i !~ /^--/) { print $i; break } }' \
    "$ROOT/raftly/docker/Dockerfile" | sort -u > "$OUT/inputs/docker-base-image-refs.txt"

  log "Building only node1, node2 and node3 without the layer cache."
  BUILD_START="$(date +%s)"
  "${COMPOSE[@]}" --progress plain build --no-cache "${RAFTLY_SERVICES[@]}" \
    2>&1 | tee "$OUT/build.log"
  printf '%s\n' "$(( $(date +%s) - BUILD_START ))" > "$OUT/build-duration-seconds.txt"

  : > "$OUT/inputs/docker-base-image-identities.txt"
  index=0
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    index=$((index + 1))
    safe="$(printf '%02d' "$index")"
    if docker image inspect "$ref" > "$OUT/inputs/base-image-$safe.json" 2>/dev/null; then
      printf '%s\t' "$ref" >> "$OUT/inputs/docker-base-image-identities.txt"
      docker image inspect "$ref" --format '{{.Id}} {{json .RepoDigests}} {{.Architecture}}' \
        >> "$OUT/inputs/docker-base-image-identities.txt"
    else
      printf '%s\tNOT_FOUND_AFTER_BUILD\n' "$ref" >> "$OUT/inputs/docker-base-image-identities.txt"
    fi
  done < "$OUT/inputs/docker-base-image-refs.txt"

  log "Creating (but not starting) the three Raftly containers."
  "${COMPOSE[@]}" create --no-build "${RAFTLY_SERVICES[@]}" \
    2>&1 | tee "$OUT/create.log"

  for node in "${RAFTLY_SERVICES[@]}"; do
    mapfile -t cids < <("${COMPOSE[@]}" ps -aq "$node")
    if [[ ${#cids[@]} -ne 1 ]]; then
      echo "Expected one container for $node, found ${#cids[@]}." >&2
      exit 1
    fi
    cid="${cids[0]}"
    image_id="$(docker inspect --format '{{.Image}}' "$cid")"
    log "Collecting $node image $image_id."
    collect_image "$node" "$cid" "$image_id"
  done

else
  log "Building NixOS Compose from $NXC_DIR."
  BUILD_START="$(date +%s)"
  (
    cd "$NXC_DIR"
    nxc build -f docker --nix-flags="$NXC_NIX_FLAGS"
  ) 2>&1 | tee "$OUT/build.log"
  printf '%s\n' "$(( $(date +%s) - BUILD_START ))" > "$OUT/build-duration-seconds.txt"

  [[ -e "$NXC_BUILD_LINK" ]] || {
    echo "Expected NixOS Compose build result at $NXC_BUILD_LINK" >&2
    exit 1
  }
  BUILD_REF="$(readlink -f "$NXC_BUILD_LINK")"
  printf '%s\n' "$NXC_BUILD_LINK" > "$OUT/nix-build-link.txt"
  printf '%s\n' "$BUILD_REF" > "$OUT/nix-build-ref.txt"

  nix path-info --recursive --json "$BUILD_REF" > "$OUT/nix-closure.json"
  python3 - "$OUT/nix-closure.json" "$OUT/nix-store-inventory.json" <<'PY'
import json, os, sys
src, dst = sys.argv[1:]
data = json.load(open(src, encoding="utf-8"))
if isinstance(data, dict):
    rows = []
    for path, value in data.items():
        row = dict(value)
        row.setdefault("path", path)
        rows.append(row)
else:
    rows = data
result = []
for row in sorted(rows, key=lambda x: x.get("path", "")):
    path = row.get("path", "")
    result.append({
        "store_path": path,
        "store_name": os.path.basename(path).split("-", 1)[-1],
        "nar_hash": row.get("narHash"),
        "nar_size": row.get("narSize"),
        "references": row.get("references", []),
    })
with open(dst, "w", encoding="utf-8") as f:
    json.dump(result, f, indent=2)
    f.write("\n")
PY

  # Find the application executable in the closure. Later, copy it from each
  # deployed container image so the hash measures what the image actually contains.
  python3 - "$OUT/nix-closure.json" "$OUT/nodes" <<'PY'
import json, os, sys
src, nodes_dir = sys.argv[1:]
data = json.load(open(src, encoding="utf-8"))
if isinstance(data, dict):
    rows = []
    for path, value in data.items():
        row = dict(value)
        row.setdefault("path", path)
        rows.append(row)
else:
    rows = data
matches = []
for row in rows:
    path = row.get("path", "")
    binary = os.path.join(path, "bin", "raftly-server")
    if os.path.isfile(binary):
        matches.append(binary)
if not matches:
    print("Could not find bin/raftly-server in the Nix closure.", file=sys.stderr)
    sys.exit(1)
with open(os.path.join(nodes_dir, "nix-raftly-binary-path.txt"), "w", encoding="utf-8") as f:
    f.write(sorted(matches)[0] + "\n")
PY
  RAFTLY_BINARY_PATH="$(cat "$OUT/nodes/nix-raftly-binary-path.txt")"

  # Avoid stopping or reusing an existing deployment of this composition.
  # Compose records these labels on containers it creates.
  for cid in $(docker ps -aq); do
    service="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
    workdir="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$cid" 2>/dev/null || true)"
    config_files="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$cid" 2>/dev/null || true)"
    case "$service" in
      node1|node2|node3)
        if [[ "$workdir" == "$NXC_DIR" || "$workdir" == "$NXC_DIR/"* || "$config_files" == *"$NXC_DIR"* ]]; then
          echo "An existing NixOS Compose Raftly container is present ($cid, $service)." >&2
          echo "Stop/remove that deployment before running this collector." >&2
          exit 1
        fi
        ;;
    esac
  done

  docker ps -aq | sort -u > "$OUT/docker-containers-before.txt"
  log "Starting the NixOS Compose Docker deployment to inspect the generated node images."
  NXC_STARTED=1
  (cd "$NXC_DIR" && nxc start -f docker) 2>&1 | tee "$OUT/start.log"

  for node in "${RAFTLY_SERVICES[@]}"; do
    mapfile -t candidates < <(docker ps -q --filter "label=com.docker.compose.service=$node")
    matches=()
    for cid in "${candidates[@]}"; do
      workdir="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$cid" 2>/dev/null || true)"
      config_files="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$cid" 2>/dev/null || true)"
      if [[ "$workdir" == "$NXC_DIR" || "$workdir" == "$NXC_DIR/"* || "$config_files" == *"$NXC_DIR"* ]]; then
        matches+=("$cid")
      elif ! grep -qxF "$cid" "$OUT/docker-containers-before.txt"; then
        # Some Compose versions do not set working_dir/config_files labels.
        matches+=("$cid")
      fi
    done
    if [[ ${#matches[@]} -ne 1 ]]; then
      echo "Expected one new NixOS Compose container for $node, found ${#matches[@]}." >&2
      echo "See $OUT/start.log and check for other Compose deployments with these service names." >&2
      exit 1
    fi
    cid="${matches[0]}"
    NXC_CONTAINER_IDS+=("$cid")
    image_id="$(docker inspect --format '{{.Image}}' "$cid")"
    log "Collecting $node image $image_id."
    collect_image "$node" "$cid" "$image_id"
    if [[ ! -f "$OUT/nodes/$node/raftly-server.sha256" ]]; then
      echo "Could not extract the Raftly executable from the NXC image for $node." >&2
      exit 1
    fi
  done
fi
