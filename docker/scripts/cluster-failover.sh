#!/usr/bin/env bash

set -Eeuo pipefail

RESULTS_DIR="${RESULTS_DIR:-/results}"
mkdir -p "$RESULTS_DIR"

RUN_ID="$(date -u +%Y-%m-%dT%H:%M:%SZ)-$$"
LOG_FILE="$RESULTS_DIR/cluster-failover-${RUN_ID}.log"

NODE_URLS=("http://node1:8001" "http://node2:8002" "http://node3:8003")

KEY_BEFORE="it-before-${RUN_ID}"
VALUE_BEFORE="before-${RUN_ID}"

KEY_DURING="it-during-${RUN_ID}"
VALUE_DURING="during-${RUN_ID}"

# Print output to the terminal and save it to a log file.
exec > >(tee -a "$LOG_FILE") 2>&1

fail() {
    echo "FAIL: $*"
    exit 1
}

cluster_snapshot() {
    curl -fsS --connect-timeout 2 --max-time 5 \
        "${NODE_URLS[0]}/api/cluster"
}

# Wait until all nodes respond to HTTP.
wait_for_nodes() {
    for node in "${NODE_URLS[@]}"; do
        echo "Waiting for $node..."

        ready=false

        for ((i = 1; i <= 60; i++)); do
            if curl -fsS --connect-timeout 2 --max-time 3 \
                "${node}/status" >/dev/null 2>&1; then
                ready=true
                break
            fi

            sleep 1
        done

        [[ "$ready" == true ]] || fail "$node did not become ready"
        echo "PASS: $node is reachable"
    done
}

# Wait for all three nodes to apply the same committed log.
wait_for_convergence() {
    echo "Waiting for cluster convergence..."

    for ((i = 1; i <= 45; i++)); do
        local snapshot

        snapshot="$(cluster_snapshot 2>/dev/null || true)"

        if [[ -n "$snapshot" ]] &&
            jq -e '
                (.nodes | length) == 3
                and (.nodes | all(.[]; .reachable == true))
                and (.nodes | all(.[]; .commit_index == .last_applied))
                and ((.nodes | map(.commit_index) | unique | length) == 1)
            ' <<< "$snapshot" >/dev/null 2>&1; then
            echo "PASS: all nodes have converged"
            return 0
        fi

        sleep 1
    done

    return 1
}

# Always try to heal the cluster before the container exits.
cleanup() {
    local status=$?

    trap - EXIT

    echo
    echo "Cleaning up network faults..."

    if curl -fsS --connect-timeout 2 --max-time 5 \
        -X POST "${NODE_URLS[0]}/api/cluster/chaos/heal" >/dev/null; then
        echo "Network healing requested"
    else
        echo "WARNING: could not request network healing"
    fi

    if [[ "$status" -eq 0 ]]; then
        echo "FINAL RESULT: PASS"
    else
        echo "FINAL RESULT: FAIL (exit code $status)"
    fi

    echo "Log file: $LOG_FILE"

    exit "$status"
}

trap cleanup EXIT

# -------------------------------------------------
# Step 1: Wait for the cluster.
# -------------------------------------------------

echo "=== Cluster failover integration test ==="
echo "Run ID: $RUN_ID"
echo

wait_for_nodes
wait_for_convergence || fail "initial cluster did not converge"

snapshot="$(cluster_snapshot)"
leader="$(jq -r '.leader_id' <<< "$snapshot")"

[[ "$leader" == node1 || "$leader" == node2 || "$leader" == node3 ]] ||
    fail "no valid leader was elected"

echo "Initial leader: $leader"

# -------------------------------------------------
# Step 2: Write a value while the network is healthy.
# -------------------------------------------------

echo
echo "=== Step 2: Baseline write ==="

curl -fsS --connect-timeout 2 --max-time 10 \
    -X PUT \
    -H 'Content-Type: application/json' \
    -d "{\"value\":\"${VALUE_BEFORE}\"}" \
    "http://${leader}:8001/keys/${KEY_BEFORE}" >/dev/null ||
    fail "baseline write failed"

wait_for_convergence || fail "baseline write did not converge"

snapshot="$(cluster_snapshot)"
baseline="$(jq '[.nodes[].commit_index] | max' <<< "$snapshot")"

echo "PASS: baseline write committed"
echo "Baseline commit index: $baseline"

# Choose one follower to isolate.
follower="$(
    jq -r --arg leader "$leader" \
        '[.nodes[] | select(.id != $leader) | .id] | .[0]' \
        <<< "$snapshot"
)"

[[ -n "$follower" && "$follower" != null ]] ||
    fail "could not find a follower to isolate"

echo "Follower to isolate: $follower"

# -------------------------------------------------
# Step 3: Isolate the follower.
# -------------------------------------------------

echo
echo "=== Step 3: Isolate $follower ==="

isolation="$(
    curl -fsS --connect-timeout 2 --max-time 10 \
        -X POST \
        -H 'Content-Type: application/json' \
        -d "{\"node\":\"${follower}\"}" \
        "${NODE_URLS[0]}/api/cluster/chaos/isolate"
)" || fail "could not isolate $follower"

echo "$isolation" | jq .

jq -e '
    (.results | length) == 3
    and (.results | all(.[]; (.error // "") == ""))
' <<< "$isolation" >/dev/null ||
    fail "one or more nodes rejected the isolation rules"

echo "PASS: isolation rules installed"

# -------------------------------------------------
# Step 4: Write with one follower isolated.
# -------------------------------------------------

echo
echo "=== Step 4: Write with a majority available ==="

curl -fsS --connect-timeout 2 --max-time 10 \
    -X PUT \
    -H 'Content-Type: application/json' \
    -d "{\"value\":\"${VALUE_DURING}\"}" \
    "http://${leader}:8001/keys/${KEY_DURING}" >/dev/null ||
    fail "write failed while one follower was isolated"

echo "Write request succeeded"

# Verify that the two connected nodes advanced their
# committed log while the isolated node did not.

advanced=false

for ((i = 1; i <= 15; i++)); do
    snapshot="$(cluster_snapshot 2>/dev/null || true)"

    if [[ -n "$snapshot" ]] &&
        jq -e \
            --arg follower "$follower" \
            --argjson baseline "$baseline" '
                (
                    [.nodes[]
                     | select(.id != $follower)
                     | .commit_index] | min
                ) >= ($baseline + 1)
                and
                (
                    [.nodes[]
                     | select(.id == $follower)
                     | .commit_index] | first
                ) <= $baseline
            ' <<< "$snapshot" >/dev/null 2>&1; then
        advanced=true
        break
    fi

    sleep 1
done

[[ "$advanced" == true ]] ||
    fail "majority did not advance while the follower was isolated"

echo "PASS: majority committed the new write"
echo "PASS: isolated follower fell behind"

# -------------------------------------------------
# Step 5: Heal the network and wait for recovery.
# -------------------------------------------------

echo
echo "=== Step 5: Heal the network ==="

healing="$(
    curl -fsS --connect-timeout 2 --max-time 10 \
        -X POST "${NODE_URLS[0]}/api/cluster/chaos/heal"
)" || fail "network healing request failed"

echo "$healing" | jq .

jq -e '
    (.healed | length) == 3
    and (.healed | all(.[]; . == "ok"))
' <<< "$healing" >/dev/null ||
    fail "one or more nodes did not accept healing"

wait_for_convergence || fail "cluster did not recover after healing"

# -------------------------------------------------
# Step 6: Check both values through every API.
# -------------------------------------------------

echo
echo "=== Step 6: Verify reads after recovery ==="

for node in "${NODE_URLS[@]}"; do
    for item in \
        "${KEY_BEFORE}|${VALUE_BEFORE}" \
        "${KEY_DURING}|${VALUE_DURING}"; do

        key="${item%%|*}"
        expected="${item#*|}"

        body="$(
            curl -fsS --connect-timeout 2 --max-time 5 \
                "${node}/keys/${key}"
        )" || fail "read failed on $node for $key"

        actual="$(jq -r '.value // empty' <<< "$body")"

        [[ "$actual" == "$expected" ]] ||
            fail "wrong value from $node for $key"

        echo "PASS: $node returned the expected value for $key"
    done
done

echo
echo "All integration checks passed."
