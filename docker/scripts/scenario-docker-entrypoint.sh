#!/usr/bin/env bash

set -euo pipefail

RESULTS_DIR="${RESULTS_DIR:-./results}"
mkdir -p "$RESULTS_DIR"

RUN_ID="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
LOG_FILE="${RESULTS_DIR}/scenarios-${RUN_ID}.log"

SCENARIOS=(
    split-brain-2011
    leader-isolation-write-loss
    wal-torn-write
    stale-log-elected-leader
)

{
    echo "Raftly failure scenarios"
    echo "Started at: $RUN_ID"
    echo

    FAILED=0

    for SCENARIO in "${SCENARIOS[@]}"; do
        echo "========================================"
        echo "Scenario: $SCENARIO"
        echo "========================================"

        if bash /src/raftly/scripts/scenario.sh "$SCENARIO"; then
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
