#!/usr/bin/env bash
# Small, repeatable observations of Raftly state under network faults.
# Request failures and stale reads are recorded, not treated as test failures.
set -uo pipefail

# Fixed settings: change values here, not in Make or Compose.
CONTROL_URL="http://node1:8001"
CLIENT_NODE="node1"
NODES=(node1 node2 node3)
WRITE_COUNT=3
BURST_COUNT=6
DELAY_MS=250
LOSS_RATE=0.30
FAULT_OBSERVE_SECONDS=3
LEADER_WATCH_SECONDS=8
CONVERGENCE_WAIT_SECONDS=12
REQUEST_TIMEOUT_SECONDS=5
RESULTS_DIR="${RESULTS_DIR:-/results}"
SCENARIOS=(baseline burst delay packet-loss follower-isolation leader-isolation)
SCENARIO="${1:-baseline}"

valid=false
for name in "${SCENARIOS[@]}"; do [[ "$SCENARIO" == "$name" ]] && valid=true; done
if [[ "$valid" != true ]]; then echo "Usage: $0 {${SCENARIOS[*]}}" >&2; exit 2; fi

mkdir -p "$RESULTS_DIR" || exit 1
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM}"
LOG_FILE="${LOG_FILE:-$RESULTS_DIR/${SCENARIO}-${RUN_ID}.log}"
START_EPOCH="$(date +%s)"
BASE_INDEXES='{}'
BASE_TERMS='{}'
BASE_TERM=0
HEAL_NEEDED=0
WRITTEN_KEYS=()
WRITTEN_VALUES=()
exec > >(tee -a "$LOG_FILE") 2>&1

log() { printf '[%ss] %s\n' "$(( $(date +%s) - START_EPOCH ))" "$*"; }
node_url() { case "$1" in node1) echo http://node1:8001;; node2) echo http://node2:8002;; node3) echo http://node3:8003;; *) return 1;; esac; }
cluster() { curl -fsS --connect-timeout 2 --max-time "$REQUEST_TIMEOUT_SECONDS" "$CONTROL_URL/api/cluster"; }

control() {
    local action="$1" payload="$2" response rc code body errors
    response="$(curl -sS --connect-timeout 2 --max-time 8 \
        -X POST -H 'Content-Type: application/json' -d "$payload" \
        -w $'\n%{http_code}' "$CONTROL_URL/api/cluster/chaos/$action" 2>/dev/null)"
    rc=$?; code="${response##*$'\n'}"; body="${response%$'\n'*}"
    if [[ "$rc" -ne 0 || ! "$code" == 2?? ]]; then
        log "CONTROL_ERROR action=$action http=${code:-000}"; return 1
    fi
    errors="$(jq -r '[.results[]? | .error? | select(. != null and . != "")] | join("; ")' <<< "$body" 2>/dev/null || true)"
    if [[ -n "$errors" ]]; then log "CONTROL_ERROR action=$action details=$errors"; return 1; fi
    if [[ "$action" == heal ]] && jq -e 'type=="object" and has("healed")' <<< "$body" >/dev/null 2>&1; then
        if ! jq -e 'if (.healed|type)=="object" or (.healed|type)=="array" then all(.healed[]; .=="ok") else true end' <<< "$body" >/dev/null 2>&1; then
            log "CONTROL_ERROR action=heal response reported incomplete healing"; return 1
        fi
    fi
    log "CONTROL action=$action http=$code"; return 0
}

heal() { if control heal '{}'; then HEAL_NEEDED=0; return 0; else return 1; fi; }
fatal() { log "SETUP_ERROR: $*"; exit 1; }
cleanup() {
    local rc=$?; trap - EXIT
    if [[ "$HEAL_NEEDED" -eq 1 ]]; then
        log "Cleanup: trying to heal network"
        if ! heal; then log "WARNING: healing failed"; rc=1; fi
    fi
    log "Log: $LOG_FILE"; log "Exit code: $rc"
    exit "$rc"
}
trap cleanup EXIT

wait_ready() {
    local i s
    log "Waiting for three reachable nodes and one leader"
    for ((i=0; i<45; i++)); do
        s="$(cluster 2>/dev/null || true)"
        if [[ -n "$s" ]] && jq -e '(.nodes|length)==3 and ([.nodes[]|select(.state=="Leader")]|length)==1 and all(.nodes[];.reachable==true)' <<< "$s" >/dev/null 2>&1; then
            log "Cluster is ready"; return 0
        fi
        sleep 1
    done
    return 1
}

record_state() {
    local phase="$1" s row summary
    s="$(cluster)" || { log "OBSERVATION_ERROR phase=$phase cluster API unavailable"; return 1; }
    if [[ "$phase" == initial ]]; then
        BASE_INDEXES="$(jq -c '[.nodes[]? | {key:.id,value:(.commit_index//0)}]|from_entries' <<< "$s")" || return 1
        BASE_TERMS="$(jq -c '[.nodes[]? | {key:.id,value:(.term//0)}]|from_entries' <<< "$s")" || return 1
        BASE_TERM="$(jq -r '.term//0' <<< "$s")"
    fi
    row="$(jq -cS --arg run "$RUN_ID" --arg scenario "$SCENARIO" --arg phase "$phase" \
        --argjson elapsed "$(( $(date +%s) - START_EPOCH ))" \
        --argjson base_indexes "$BASE_INDEXES" --argjson base_terms "$BASE_TERMS" --argjson base_term "$BASE_TERM" '
        {run_id:$run,scenario:$scenario,phase:$phase,elapsed_s:$elapsed,
         leader_id:((.leader_id|select(.!=null and .!=""))//([.nodes[]?|select(.state=="Leader")|.id][0]//"")),
         term:(.term//0),term_delta:((.term//0)-$base_term),
         nodes:[.nodes[]? | {id:.id,state:(.state//"?"),term:(.term//0),term_delta:((.term//0)-($base_terms[.id]//0)),
           reachable:(.reachable//false),commit_index:(.commit_index//null),last_applied:(.last_applied//null),
           commit_delta:(if .commit_index==null then null else .commit_index-($base_indexes[.id]//.commit_index) end),
           applied_delta:(if .last_applied==null then null else .last_applied-($base_indexes[.id]//.last_applied) end)}]}' <<< "$s")" || return 1
    summary="$(jq -r '"leader="+(.leader_id//"-")+" term="+(.term|tostring)+" term_delta="+(.term_delta|tostring)+" nodes="+([.nodes[]|.id+":"+.state+"/t="+(.term|tostring)+"/dt="+(.term_delta|tostring)+"/c="+(.commit_index|tostring)+"/dc="+(.commit_delta|tostring)+"/a="+(.last_applied|tostring)+"/da="+(.applied_delta|tostring)+"/up="+(.reachable|tostring)]|join(" "))' <<< "$row")"
    log "STATE phase=$phase $summary"
}

wait_converged() {
    local i s
    log "Observing convergence for up to ${CONVERGENCE_WAIT_SECONDS}s"
    for ((i=0; i<CONVERGENCE_WAIT_SECONDS; i++)); do
        s="$(cluster 2>/dev/null || true)"
        if [[ -n "$s" ]] && jq -e '(.nodes|length)==3 and all(.nodes[];.reachable==true) and all(.nodes[];.commit_index==.last_applied) and ([.nodes[].commit_index]|unique|length)==1' <<< "$s" >/dev/null 2>&1; then
            log "OBSERVATION cluster converged"; return 0
        fi
        sleep 1
    done
    log "OBSERVATION cluster did not converge in time"; return 1
}

leader_of() { jq -r '((.leader_id|select(.!=null and .!=""))//([.nodes[]?|select(.state=="Leader")|.id][0]//""))' <<< "$1"; }
follower_of() {
    jq -r --arg leader "$2" '([.nodes[]?|select(.id!=$leader and .id!="node1")][0].id//[.nodes[]?|select(.id!=$leader)][0].id//"")' <<< "$1"
}

put_one() {
    local phase="$1" node="$2" key="$3" value="$4" url code
    url="$(node_url "$node")" || { log "PUT_ERROR unknown node=$node"; return; }
    code="$(curl -sS --connect-timeout 2 --max-time "$REQUEST_TIMEOUT_SECONDS" -o /dev/null -w '%{http_code}' \
        -X PUT -H 'Content-Type: application/json' -d "{\"value\":\"$value\"}" "$url/keys/$key" 2>/dev/null)" || code=000
    log "PUT phase=$phase node=$node key=$key http=${code:-000}"
}
write_batch() {
    local phase="$1" node="$2" count="$3" parallel="${4:-no}" i key value pid
    local -a pids=()
    log "Writing $count key(s): phase=$phase node=$node parallel=$parallel"
    for ((i=1; i<=count; i++)); do
        key="${RUN_ID}-${phase}-${i}"; value="${SCENARIO}-${phase}-${i}"
        WRITTEN_KEYS+=("$key"); WRITTEN_VALUES+=("$value")
        if [[ "$parallel" == yes ]]; then
            put_one "$phase" "$node" "$key" "$value" & pids+=("$!")
        else
            put_one "$phase" "$node" "$key" "$value"
        fi
    done
    if [[ "$parallel" == yes ]]; then for pid in "${pids[@]}"; do wait "$pid" || true; done; fi
}

observe_reads() {
    local node url response code body value expected i result
    log "Reading written keys from all nodes"
    for node in "${NODES[@]}"; do
        url="$(node_url "$node")"
        for i in "${!WRITTEN_KEYS[@]}"; do
            response="$(curl -sS --connect-timeout 2 --max-time "$REQUEST_TIMEOUT_SECONDS" -w $'\n%{http_code}' "$url/keys/${WRITTEN_KEYS[$i]}" 2>/dev/null || true)"
            code="${response##*$'\n'}"; body="${response%$'\n'*}"
            value="$(jq -r '.value//empty' <<< "$body" 2>/dev/null || true)"; expected="${WRITTEN_VALUES[$i]}"
            if [[ "$value" == "$expected" ]]; then result=match
            elif [[ "$code" == 404 ]]; then result=missing
            else result=different-or-unavailable; fi
            log "GET node=$node key=${WRITTEN_KEYS[$i]} http=$code result=$result value=${value:-<empty>} expected=$expected"
        done
    done
}

fault_scenario() {
    local kind="$1" payload="$2" target="$3"
    log "Applying $kind fault to $target"
    HEAL_NEEDED=1
    control "$kind" "$payload" || fatal "could not enable $kind fault on $target"
    sleep "$FAULT_OBSERVE_SECONDS"
    record_state fault-active || log "WARNING: could not record fault-active state"
    write_batch fault-write "$CLIENT_NODE" "$WRITE_COUNT"
    record_state after-fault-writes || log "WARNING: could not record after-fault-writes state"
    observe_reads
    if heal; then
        wait_converged || true
        record_state after-heal || log "WARNING: could not record after-heal state"
    else
        log "WARNING: could not confirm healing; cleanup will retry"
        record_state after-heal-unconfirmed || log "WARNING: could not record after-heal state"
    fi
    observe_reads
}

log "========================================"
log "Scenario: $SCENARIO"
log "========================================"
log "Run ID: $RUN_ID"
log "Started at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
log "Settings: writes=$WRITE_COUNT burst_writes=$BURST_COUNT delay_ms=$DELAY_MS loss_rate=$LOSS_RATE"
heal || fatal "cannot reach the cluster chaos API"
wait_ready || fatal "cluster did not become ready; check Compose networking and node logs"
record_state initial || fatal "could not record initial cluster state"

case "$SCENARIO" in
    baseline|burst)
        if [[ "$SCENARIO" == burst ]]; then write_batch burst "$CLIENT_NODE" "$BURST_COUNT" yes
        else write_batch baseline "$CLIENT_NODE" "$WRITE_COUNT"; fi
        record_state after-writes || log "WARNING: could not record after-writes state"
        wait_converged || true
        record_state settled || log "WARNING: could not record settled state"
        observe_reads
        ;;
    delay|packet-loss|follower-isolation)
        snapshot="$(cluster)" || fatal "cannot read cluster state"
        leader="$(leader_of "$snapshot")"; target="$(follower_of "$snapshot" "$leader")"
        [[ -n "$target" ]] || fatal "could not choose a follower"
        log "Fault target=$target current_leader=$leader"
        case "$SCENARIO" in
            delay) fault_scenario delay "{\"node\":\"$target\",\"delay_ms\":$DELAY_MS,\"jitter_ms\":0}" "$target" ;;
            packet-loss) fault_scenario loss "{\"node\":\"$target\",\"loss_rate\":$LOSS_RATE}" "$target" ;;
            follower-isolation) fault_scenario isolate "{\"node\":\"$target\"}" "$target" ;;
        esac
        ;;
    leader-isolation)
        snapshot="$(cluster)" || fatal "cannot read cluster state"
        old_leader="$(leader_of "$snapshot")"; [[ -n "$old_leader" ]] || fatal "could not find current leader"
        log "Isolating current leader=$old_leader"
        HEAL_NEEDED=1; control isolate "{\"node\":\"$old_leader\"}" || fatal "could not isolate leader"
        sleep 1; record_state leader-isolated || log "WARNING: could not record leader-isolated state"
        write_batch old-leader-write "$old_leader" 1
        new_leader=""
        for ((i=1; i<=LEADER_WATCH_SECONDS; i++)); do
            sleep 1; record_state "leader-watch-$i" || log "WARNING: could not record leader-watch-$i"
            snapshot="$(cluster 2>/dev/null || true)"
            if [[ -n "$snapshot" ]]; then
                new_leader="$(jq -r --arg old "$old_leader" '([.nodes[]?|select(.id!=$old and .state=="Leader")|.id][0] // "")' <<< "$snapshot")"
            fi
            if [[ -n "$new_leader" && "$new_leader" != "$old_leader" ]]; then
                log "OBSERVATION replacement_leader=$new_leader observed_after_about_${i}s"; break
            fi
            new_leader=""
        done
        if [[ -n "$new_leader" ]]; then
            write_batch new-leader-write "$new_leader" "$WRITE_COUNT"
            record_state after-new-leader-writes || log "WARNING: could not record new-leader writes"
        else log "OBSERVATION no replacement leader seen within ${LEADER_WATCH_SECONDS}s"; fi
        observe_reads
        if heal; then
            wait_converged || true
            record_state after-heal || log "WARNING: could not record after-heal state"
        else
            log "WARNING: could not confirm healing; cleanup will retry"
            record_state after-heal-unconfirmed || log "WARNING: could not record after-heal state"
        fi
        observe_reads
        ;;
esac

log "Finished at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
log "Request failures and stale reads are observations, not automatic test failures."
