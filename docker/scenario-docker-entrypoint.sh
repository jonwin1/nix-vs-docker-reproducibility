#!/usr/bin/env bash

set -euo pipefail

RESULTS_DIR="${RESULTS_DIR:-/results}"
MODE="${1:-all}"

# Create a unique name for this run.
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"

mkdir -p "$RESULTS_DIR"

LOG_FILE="${RESULTS_DIR}/scenarios-${RUN_ID}.log"

# Keep the list in sync with scripts/scenario.sh.
case "$MODE" in
    all)
        SCENARIOS=(
            split-brain-2011
            leader-isolation-write-loss
            wal-torn-write
            stale-log-elected-leader
        )
        ;;
    split-brain-2011 | \
    leader-isolation-write-loss | \
    wal-torn-write | \
    stale-log-elected-leader)
        SCENARIOS=("$MODE")
        ;;
    *)
        echo "Usage: $0 {all|scenario-name}" >&2
        exit 2
        ;;
esac

{
    echo "Raftly failure scenario run"
    echo "Started at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "Selection: $MODE"
    echo

    FAILED=0

    for SCENARIO in "${SCENARIOS[@]}"; do
        echo "========================================"
        echo "Scenario: $SCENARIO"
        echo "========================================"

        if bash /src/scripts/scenario.sh "$SCENARIO"; then
            echo "RESULT: PASS ($SCENARIO)"
        else
            EXIT_CODE=$?
            echo "RESULT: FAIL ($SCENARIO, exit code $EXIT_CODE)"
            FAILED=1
        fi

        echo
    done

    echo "========================================"

    if [ "$FAILED" -eq 0 ]; then
        echo "FINAL RESULT: PASS"
    else
        echo "FINAL RESULT: FAIL"
    fi

    echo "Finished at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "Log file: $LOG_FILE"

    exit "$FAILED"

} 2>&1 | tee "$LOG_FILE"
