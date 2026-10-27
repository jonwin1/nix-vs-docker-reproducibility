#!/usr/bin/env bash

set -uo pipefail

SCENARIO="${1:-baseline}"
RESULTS_DIR="${RESULTS_DIR:-/results}"
CONTROL_URL="${CONTROL_URL:-http://node1:8001}"
CLIENT_NODE="${CLIENT_NODE:-node1}"
NODE_IDS=(node1 node2 node3)

WRITE_COUNT=30
BURST_CONCURRENCY=6
DELAY_MS=250
JITTER_MS=0
LOSS_RATE=0.30

case "$SCENARIO" in
  baseline|burst|delay|packet-loss|follower-isolation|leader-isolation) ;;
  *)
    echo "Usage: $0 {baseline|burst|delay|packet-loss|follower-isolation|leader-isolation}" >&2
    exit 2
    ;;
esac

mkdir -p "$RESULTS_DIR"
RUN_ID="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
LOG_FILE="$RESULTS_DIR/${SCENARIO}-${RUN_ID}.log"
JSONL_FILE="$RESULTS_DIR/${SCENARIO}-${RUN_ID}.jsonl"
CSV_FILE="$RESULTS_DIR/${SCENARIO}-${RUN_ID}-writes.csv"
TMP_DIR="$(mktemp -d "/tmp/raftly-experiment-${RUN_ID}-XXXXXX")"
START_EPOCH_MS="$(date +%s%3N)"
FAULT_ACTIVE=0
CONTROL_SEQ=0

# Human-readable log. Structured observations are written to JSONL_FILE.
exec > >(tee -a "$LOG_FILE") 2>&1

say() {
  local now elapsed
  now="$(date +%s%3N)"
  elapsed=$((now - START_EPOCH_MS))
  printf '[%7sms] %s\n' "$elapsed" "$*"
}

event() {
  local name="$1"
  local data="${2:-{}}"
  local now elapsed row
  now="$(date +%s%3N)"
  elapsed=$((now - START_EPOCH_MS))
  row="$(jq -cn \
    --arg run_id "$RUN_ID" \
    --arg scenario "$SCENARIO" \
    --arg timestamp_utc "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" \
    --arg event "$name" \
    --argjson elapsed_ms "$elapsed" \
    --argjson data "$data" \
    '{run_id:$run_id,scenario:$scenario,timestamp_utc:$timestamp_utc,elapsed_ms:$elapsed_ms,event:$event,data:$data}')" || return 1
  printf '%s\n' "$row" >> "$JSONL_FILE"
  case "$name" in
    write_result)
      say "WRITE phase=$(jq -r '.phase // "?"' <<< "$data") key=$(jq -r '.key // "?"' <<< "$data") http=$(jq -r '.http_status // "?"' <<< "$data") latency_ms=$(jq -r '.latency_ms // "?"' <<< "$data") curl_exit=$(jq -r '.curl_exit // "?"' <<< "$data")"
      ;;
    cluster_snapshot)
      say "SNAPSHOT phase=$(jq -r '.phase // "?"' <<< "$data") leader=$(jq -r '.leader_id // "?"' <<< "$data") term=$(jq -r '.term // "?"' <<< "$data") nodes=$(jq -r '[.nodes[] | "\(.id):\(.state):commit=\(.commit_index):applied=\(.last_applied)"] | join(" ")' <<< "$data")"
      ;;
    convergence_observed)
      say "CONVERGED phase=$(jq -r '.phase // "?"' <<< "$data") elapsed_ms=$(jq -r '.elapsed_since_wait_ms // "?"' <<< "$data")"
      ;;
    convergence_timeout)
      say "CONVERGENCE TIMEOUT phase=$(jq -r '.phase // "?"' <<< "$data") timeout_seconds=$(jq -r '.timeout_seconds // "?"' <<< "$data")"
      ;;
    leader_change_observed)
      say "LEADER CHANGE old=$(jq -r '.old_leader' <<< "$data") new=$(jq -r '.new_leader' <<< "$data") elapsed_ms=$(jq -r '.elapsed_ms' <<< "$data")"
      ;;
    *)
      say "EVENT: $name"
      ;;
  esac
}

node_url() {
  printf 'http://%s:8001' "$1"
}

get_cluster() {
  curl -fsS --connect-timeout 1 --max-time 4 "$CONTROL_URL/api/cluster" 2>/dev/null
}

record_snapshot_data() {
  local phase="$1" snap="$2" data
  data="$(jq -cn --arg phase "$phase" --argjson snapshot "$snap" '{phase:$phase,cluster_timestamp_ms:$snapshot.timestamp,leader_id:$snapshot.leader_id,term:$snapshot.term,nodes:[$snapshot.nodes[]|{id,state,term,leader_id,commit_index,last_applied,reachable}]}')" || return 1
  event "cluster_snapshot" "$data"
}

record_snapshot() {
  local phase="$1" snap
  if snap="$(get_cluster)"; then
    record_snapshot_data "$phase" "$snap"
  else
    event "snapshot_error" "$(jq -nc --arg phase "$phase" '{phase:$phase,error:"cluster endpoint unavailable"}')"
    return 1
  fi
}

is_ready_snapshot() {
  jq -e '
    (.nodes | length) == 3
    and (.nodes | all(.[]; .reachable == true))
    and ([.nodes[] | select(.state == "Leader")] | length) == 1
  ' >/dev/null 2>&1
}

wait_for_ready() {
  local i snap
  say "Waiting for all three nodes and one leader"
  for ((i=1; i<=90; i++)); do
    if snap="$(get_cluster)" && printf '%s' "$snap" | is_ready_snapshot; then
      record_snapshot_data "initial" "$snap"
      event "cluster_ready" "$(jq -nc --argjson snapshot "$snap" '{leader_id:$snapshot.leader_id,term:$snapshot.term,node_count:($snapshot.nodes|length)}')"
      return 0
    fi
    sleep 0.5
  done
  event "setup_error" '{"reason":"cluster_not_ready","timeout_seconds":45}'
  return 1
}

wait_for_http_nodes() {
  local node i all_up url
  say "Waiting for all node HTTP APIs"
  for ((i=1; i<=90; i++)); do
    all_up=1
    for node in "${NODE_IDS[@]}"; do
      url="$(node_url "$node")/status"
      if ! curl -fsS --connect-timeout 1 --max-time 2 "$url" >/dev/null 2>&1; then
        all_up=0
        break
      fi
    done
    if [[ "$all_up" -eq 1 ]]; then
      event "node_http_ready" '{"nodes":["node1","node2","node3"]}'
      return 0
    fi
    sleep 0.5
  done
  event "setup_error" '{"reason":"node_http_apis_not_ready","timeout_seconds":45}'
  return 1
}

post_control() {
  local label="$1" path="$2" payload="$3"
  local response_file="$TMP_DIR/control-response-$((CONTROL_SEQ+=1)).json"
  local error_file="$TMP_DIR/control-error-$CONTROL_SEQ.txt"
  local meta="" rc=0 status="000" seconds="0" response=""

  if meta="$(curl -sS --connect-timeout 2 --max-time 8 \
      -o "$response_file" -w '%{http_code} %{time_total}' \
      -H 'Content-Type: application/json' -X POST \
      --data "$payload" "$CONTROL_URL$path" 2>"$error_file")"; then
    rc=0
  else
    rc=$?
  fi
  status="$(awk '{print $1}' <<< "$meta")"
  seconds="$(awk '{print $2}' <<< "$meta")"
  [[ -n "$status" ]] || status="000"
  [[ "$seconds" =~ ^[0-9]+([.][0-9]+)?$ ]] || seconds="0"
  response="$(cat "$response_file" 2>/dev/null || true)"

  event "control_request" "$(jq -cn \
    --arg label "$label" --arg path "$path" --arg request "$payload" \
    --arg http_status "$status" --arg curl_error "$(cat "$error_file" 2>/dev/null || true)" \
    --arg response "$response" --argjson curl_exit "$rc" \
    --argjson latency_ms "$(awk -v x="$seconds" 'BEGIN{printf "%.3f", x*1000}')" \
    '{label:$label,path:$path,request:($request|fromjson),http_status:$http_status,curl_exit:$curl_exit,latency_ms:$latency_ms,response_text:$response,curl_error:$curl_error}')"

  [[ "$rc" -eq 0 && "$status" =~ ^2[0-9][0-9]$ ]]
}

heal_cluster() {
  local reason="${1:-heal}"
  if post_control "$reason" "/api/cluster/chaos/heal" '{}'; then
    FAULT_ACTIVE=0
    event "chaos_healed" "$(jq -nc --arg reason "$reason" '{reason:$reason}')"
    return 0
  fi
  event "chaos_heal_error" "$(jq -nc --arg reason "$reason" '{reason:$reason}')"
  return 1
}

fatal() {
  event "setup_error" "$(jq -nc --arg message "$*" '{message:$message}')"
  exit 2
}

record_node_metrics() {
  local node="$1" phase="$2" text
  if text="$(curl -fsS --connect-timeout 1 --max-time 4 "$(node_url "$node")/metrics" 2>/dev/null | grep -E '^raftly_(current_term|state|committed_index|applied_index|log_entries_total|elections_total|leader_changes_total|wal_fsync_duration_ms)' || true)"; then
    event "node_metrics" "$(jq -nc --arg node "$node" --arg phase "$phase" --arg metrics "$text" '{node:$node,phase:$phase,prometheus_text:$metrics}')"
  else
    event "metrics_error" "$(jq -nc --arg node "$node" --arg phase "$phase" '{node:$node,phase:$phase}')"
  fi
}

record_cluster_log() {
  local phase="$1" raw
  if raw="$(curl -fsS --connect-timeout 1 --max-time 5 "$CONTROL_URL/api/cluster/log?limit=50" 2>/dev/null)"; then
    event "cluster_log" "$(jq -cn --arg phase "$phase" --argjson log "$raw" '{phase:$phase,log:$log}')"
  else
    event "cluster_log_error" "$(jq -nc --arg phase "$phase" '{phase:$phase}')"
  fi
}

request_put() {
  local client="$1" key="$2" value="$3" phase="$4" timeout="${5:-8}"
  local url response_file error_file meta="" rc=0 status="000" seconds="0" response=""
  local started ended latency_ms
  response_file="$TMP_DIR/put-response-$RANDOM-$RANDOM.json"
  error_file="$TMP_DIR/put-error-$RANDOM-$RANDOM.txt"
  url="$(node_url "$client")"
  started="$(date +%s%3N)"
  if meta="$(curl -sS --connect-timeout 1 --max-time "$timeout" \
      -o "$response_file" -w '%{http_code} %{time_total}' \
      -H 'Content-Type: application/json' -X PUT \
      --data "$(jq -nc --arg value "$value" '{value:$value}')" \
      "$url/keys/$key" 2>"$error_file")"; then
    rc=0
  else
    rc=$?
  fi
  ended="$(date +%s%3N)"
  status="$(awk '{print $1}' <<< "$meta")"
  seconds="$(awk '{print $2}' <<< "$meta")"
  [[ -n "$status" ]] || status="000"
  [[ "$seconds" =~ ^[0-9]+([.][0-9]+)?$ ]] || seconds="0"
  latency_ms="$(awk -v x="$seconds" 'BEGIN{printf "%.3f", x*1000}')"
  response="$(head -c 300 "$response_file" 2>/dev/null || true)"
  event "write_result" "$(jq -nc \
    --arg phase "$phase" --arg client_node "$client" --arg key "$key" \
    --arg http_status "$status" --arg curl_error "$(cat "$error_file" 2>/dev/null || true)" \
    --arg response "$response" --argjson curl_exit "$rc" \
    --argjson latency_ms "$latency_ms" --argjson started_epoch_ms "$started" \
    --argjson completed_epoch_ms "$ended" \
    '{phase:$phase,operation:"put",client_node:$client_node,key:$key,http_status:$http_status,curl_exit:$curl_exit,latency_ms:$latency_ms,started_epoch_ms:$started_epoch_ms,completed_epoch_ms:$completed_epoch_ms,response_text:$response,curl_error:$curl_error}')"
}

run_sequential() {
  local phase="$1" count="$2" interval_ms="$3" client="${4:-$CLIENT_NODE}"
  local i key
  say "Sequential workload: phase=$phase writes=$count client=$client interval_ms=$interval_ms"
  for ((i=1; i<=count; i++)); do
    key="${RUN_ID}-${phase}-${i}"
    request_put "$client" "$key" "value-${i}" "$phase" 8
    if (( i % 5 == 0 )); then
      record_snapshot "${phase}-after-${i}"
    fi
    if (( interval_ms > 0 )); then
      sleep "$(awk -v n="$interval_ms" 'BEGIN{printf "%.3f",n/1000}')"
    fi
  done
}

run_burst() {
  local phase="$1" count="$2" concurrency="$3" dir="$TMP_DIR/burst"
  local i key
  mkdir -p "$dir"
  say "Concurrent workload: phase=$phase writes=$count concurrency=$concurrency client=$CLIENT_NODE"

  for ((i=1; i<=count; i++)); do
    key="${RUN_ID}-${phase}-${i}"
    (
      local_start="$(date +%s%3N)"
      local_meta=""
      local_rc=0
      if local_meta="$(curl -sS --connect-timeout 1 --max-time 8 \
          -o /dev/null -w '%{http_code} %{time_total}' \
          -H 'Content-Type: application/json' -X PUT \
          --data "$(jq -nc --arg value "value-${i}" '{value:$value}')" \
          "$(node_url "$CLIENT_NODE")/keys/$key" 2>"$dir/error-$i.txt")"; then
        local_rc=0
      else
        local_rc=$?
      fi
      local_end="$(date +%s%3N)"
      local_status="$(awk '{print $1}' <<< "$local_meta")"
      local_seconds="$(awk '{print $2}' <<< "$local_meta")"
      [[ -n "$local_status" ]] || local_status="000"
      [[ "$local_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]] || local_seconds="0"
      local_latency="$(awk -v x="$local_seconds" 'BEGIN{printf "%.3f", x*1000}')"
      jq -cn \
        --arg phase "$phase" --arg client_node "$CLIENT_NODE" --arg key "$key" \
        --arg http_status "$local_status" --arg curl_error "$(cat "$dir/error-$i.txt" 2>/dev/null || true)" \
        --argjson curl_exit "$local_rc" --argjson latency_ms "$local_latency" \
        --argjson started_epoch_ms "$local_start" --argjson completed_epoch_ms "$local_end" \
        '{phase:$phase,operation:"put",client_node:$client_node,key:$key,http_status:$http_status,curl_exit:$curl_exit,latency_ms:$latency_ms,started_epoch_ms:$started_epoch_ms,completed_epoch_ms:$completed_epoch_ms,curl_error:$curl_error}' \
        > "$dir/result-$i.json"
    ) &
    if (( i % concurrency == 0 )); then
      wait
    fi
  done
  wait

  for ((i=1; i<=count; i++)); do
    if [[ -s "$dir/result-$i.json" ]]; then
      event "write_result" "$(cat "$dir/result-$i.json")"
    else
      event "write_result_missing" "$(jq -nc --arg phase "$phase" --arg key "${RUN_ID}-${phase}-${i}" '{phase:$phase,key:$key}')"
    fi
  done
  record_snapshot "${phase}-complete"
}

wait_for_convergence() {
  local phase="$1" timeout_seconds="${2:-20}" began now snap poll=0
  began="$(date +%s%3N)"
  say "Observing convergence: phase=$phase timeout=${timeout_seconds}s"
  while true; do
    now="$(date +%s%3N)"
    if (( now - began >= timeout_seconds * 1000 )); then
      event "convergence_timeout" "$(jq -nc --arg phase "$phase" --argjson timeout_seconds "$timeout_seconds" '{phase:$phase,timeout_seconds:$timeout_seconds}')"
      return 1
    fi
    if snap="$(get_cluster)"; then
      poll=$((poll + 1))
      # Save one sample every 500ms and always save the first sample.
      if (( poll == 1 || poll % 2 == 0 )); then
        record_snapshot_data "$phase" "$snap"
      fi
      if printf '%s' "$snap" | jq -e '
        (.nodes | length) == 3
        and (.nodes | all(.[]; .reachable == true and .commit_index == .last_applied))
        and ([.nodes[].commit_index] | unique | length) == 1
      ' >/dev/null 2>&1; then
        now="$(date +%s%3N)"
        event "convergence_observed" "$(jq -nc --arg phase "$phase" --argjson elapsed_since_wait_ms "$((now-began))" --argjson snapshot "$snap" '{phase:$phase,elapsed_since_wait_ms:$elapsed_since_wait_ms,commit_indexes:[$snapshot.nodes[]|{id,commit_index,last_applied}]}')"
        return 0
      fi
    fi
    sleep 0.25
  done
}

pick_single_leader() {
  jq -r '[.nodes[] | select(.state == "Leader") | .id] | if length == 1 then .[0] else "" end'
}

pick_follower() {
  jq -r '[.nodes[] | select(.state != "Leader") | .id] | sort | .[0] // ""'
}

install_fault() {
  local label="$1" path="$2" payload="$3"
  if post_control "$label" "$path" "$payload"; then
    FAULT_ACTIVE=1
    event "fault_injection_started" "$(jq -nc --arg label "$label" --arg path "$path" --argjson request "$payload" '{label:$label,path:$path,request:$request}')"
    return 0
  fi
  event "fault_injection_error" "$(jq -nc --arg label "$label" --arg path "$path" '{label:$label,path:$path}')"
  return 1
}

record_final_observations() {
  local node
  record_snapshot "final" || true
  record_cluster_log "final"
  for node in "${NODE_IDS[@]}"; do
    record_node_metrics "$node" "final"
  done
}

cleanup() {
  local exit_status=$?
  trap - EXIT
  if [[ "$FAULT_ACTIVE" -eq 1 ]]; then
    say "Safety cleanup: healing network rules"
    heal_cluster "exit-cleanup" || true
  fi
  event "run_end" "$(jq -nc --argjson exit_code "$exit_status" --arg log_file "$LOG_FILE" --arg jsonl_file "$JSONL_FILE" --arg csv_file "$CSV_FILE" '{exit_code:$exit_code,log_file:$log_file,jsonl_file:$jsonl_file,writes_csv_file:$csv_file}')"
  {
    echo 'run_id,scenario,phase,client_node,key,http_status,curl_exit,latency_ms,started_epoch_ms,completed_epoch_ms'
    jq -r 'select(.event == "write_result") | [ .run_id, .scenario, (.data.phase // ""), (.data.client_node // ""), (.data.key // ""), (.data.http_status // ""), (.data.curl_exit // ""), (.data.latency_ms // ""), (.data.started_epoch_ms // ""), (.data.completed_epoch_ms // "") ] | @csv' "$JSONL_FILE"
  } > "$CSV_FILE"
  say "Write measurements CSV: $CSV_FILE"
  rm -rf "$TMP_DIR"
  exit "$exit_status"
}
trap cleanup EXIT

say "Starting experiment: $SCENARIO"
say "Human log: $LOG_FILE"
say "Structured data: $JSONL_FILE"
event "run_start" "$(jq -nc \
  --arg run_id "$RUN_ID" --arg client_node "$CLIENT_NODE" \
  --arg raftly_ref "${RAFTLY_REF:-unspecified}" \
  --argjson write_count "$WRITE_COUNT" --argjson concurrency "$BURST_CONCURRENCY" \
  --argjson delay_ms "$DELAY_MS" --argjson jitter_ms "$JITTER_MS" \
  --argjson loss_rate "$LOSS_RATE" \
  '{run_id:$run_id,client_node:$client_node,raftly_ref:$raftly_ref,write_count:$write_count,burst_concurrency:$concurrency,delay_ms:$delay_ms,jitter_ms:$jitter_ms,loss_rate:$loss_rate}')"

wait_for_http_nodes || fatal "node HTTP APIs did not become ready; see the run log"
# Clear leftovers from a run that was interrupted before waiting for leader election.
heal_cluster "pre-run-reset" || fatal "could not clear pre-existing network faults"
wait_for_ready || fatal "cluster did not become ready; see the run log"
for node in "${NODE_IDS[@]}"; do
  record_node_metrics "$node" "before"
done

case "$SCENARIO" in
  baseline)
    run_sequential "baseline" "$WRITE_COUNT" 0 "$CLIENT_NODE"
    wait_for_convergence "baseline-after-workload" 10 || true
    ;;

  burst)
    run_burst "burst" "$WRITE_COUNT" "$BURST_CONCURRENCY"
    wait_for_convergence "burst-after-workload" 15 || true
    ;;

  delay)
    snap="$(get_cluster)" || fatal "cannot read cluster state"
    follower="$(pick_follower <<< "$snap")"
    [[ -n "$follower" ]] || fatal "could not select a follower"
    event "fault_target_selected" "$(jq -nc --arg node "$follower" --arg leader "$(pick_single_leader <<< "$snap")" '{fault:"delay",node:$node,leader:$leader}')"
    install_fault "delay-${follower}" "/api/cluster/chaos/delay" "$(jq -nc --arg node "$follower" --argjson delay_ms "$DELAY_MS" --argjson jitter_ms "$JITTER_MS" '{node:$node,delay_ms:$delay_ms,jitter_ms:$jitter_ms}')" || fatal "could not install delay"
    record_snapshot "delay-active"
    run_sequential "delay-active" "$WRITE_COUNT" 100 "$CLIENT_NODE"
    wait_for_convergence "delay-active-convergence" 20 || true
    heal_cluster "delay-complete" || true
    wait_for_convergence "after-delay-heal" 20 || true
    ;;

  packet-loss)
    snap="$(get_cluster)" || fatal "cannot read cluster state"
    follower="$(pick_follower <<< "$snap")"
    [[ -n "$follower" ]] || fatal "could not select a follower"
    event "fault_target_selected" "$(jq -nc --arg node "$follower" --arg leader "$(pick_single_leader <<< "$snap")" '{fault:"packet-loss",node:$node,leader:$leader}')"
    install_fault "loss-${follower}" "/api/cluster/chaos/loss" "$(jq -nc --arg node "$follower" --argjson loss_rate "$LOSS_RATE" '{node:$node,loss_rate:$loss_rate}')" || fatal "could not install packet loss"
    record_snapshot "packet-loss-active"
    run_sequential "packet-loss-active" "$WRITE_COUNT" 100 "$CLIENT_NODE"
    wait_for_convergence "packet-loss-active-convergence" 20 || true
    heal_cluster "packet-loss-complete" || true
    wait_for_convergence "after-loss-heal" 20 || true
    ;;

  follower-isolation)
    snap="$(get_cluster)" || fatal "cannot read cluster state"
    leader="$(pick_single_leader <<< "$snap")"
    follower="$(pick_follower <<< "$snap")"
    [[ -n "$leader" && -n "$follower" ]] || fatal "could not select leader and follower"
    event "fault_target_selected" "$(jq -nc --arg node "$follower" --arg leader "$leader" '{fault:"follower-isolation",node:$node,leader:$leader}')"
    install_fault "isolate-${follower}" "/api/cluster/chaos/isolate" "$(jq -nc --arg node "$follower" '{node:$node}')" || fatal "could not isolate follower"
    record_snapshot "follower-isolated"
    run_sequential "follower-isolated" 15 150 "$CLIENT_NODE"
    record_snapshot "follower-isolated-after-workload"
    heal_cluster "follower-isolation-complete" || true
    wait_for_convergence "follower-catch-up" 25 || true
    ;;

  leader-isolation)
    snap="$(get_cluster)" || fatal "cannot read cluster state"
    old_leader="$(pick_single_leader <<< "$snap")"
    [[ -n "$old_leader" ]] || fatal "could not identify current leader"
    event "fault_target_selected" "$(jq -nc --arg node "$old_leader" '{fault:"leader-isolation",node:$node}')"
    install_fault "isolate-leader-${old_leader}" "/api/cluster/chaos/isolate" "$(jq -nc --arg node "$old_leader" '{node:$node}')" || fatal "could not isolate leader"
    election_started="$(date +%s%3N)"
    new_leader=""
    say "Observing leader changes after isolating $old_leader"
    for ((i=1; i<=80; i++)); do
      if snap="$(get_cluster)"; then
        if (( i == 1 || i % 2 == 0 )); then
          record_snapshot_data "leader-isolated" "$snap"
        fi
        # During an isolated-leader experiment, the old leader can still report
        # Leader because it cannot hear the higher term. Look only for a leader
        # among the other two nodes in the majority partition.
        candidate="$(jq -r --arg old "$old_leader" '[.nodes[] | select(.id != $old and .state == "Leader") | .id] | sort | .[0] // ""' <<< "$snap")"
        if [[ -n "$candidate" ]]; then
          new_leader="$candidate"
          break
        fi
      fi
      sleep 0.25
    done
    observed_at="$(date +%s%3N)"
    if [[ -n "$new_leader" ]]; then
      event "leader_change_observed" "$(jq -nc --arg old_leader "$old_leader" --arg new_leader "$new_leader" --argjson elapsed_ms "$((observed_at-election_started))" '{old_leader:$old_leader,new_leader:$new_leader,elapsed_ms:$elapsed_ms}')"
      # Send the post-election workload to a node in the majority partition.
      run_sequential "after-leader-election" 12 100 "$new_leader"
    else
      event "leader_change_not_observed" "$(jq -nc --arg old_leader "$old_leader" --argjson observation_window_ms "$((observed_at-election_started))" '{old_leader:$old_leader,observation_window_ms:$observation_window_ms}')"
    fi
    heal_cluster "leader-isolation-complete" || true
    wait_for_convergence "after-leader-heal" 25 || true
    ;;
esac

record_final_observations
say "Experiment completed. Outcomes are in the logs; no behavior was classified as pass/fail."
