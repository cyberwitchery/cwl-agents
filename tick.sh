#!/usr/bin/env bash
# Heartbeat tick — runs every 30min via cron, decides whether to start a new cycle.
#
# State: $HEARTBEAT_HOME/next_cycle holds the unix timestamp of the next eligible cycle.
# If not yet reached, exit. If the optional usage check says we're burning too fast,
# skip and reschedule 1h out. Otherwise: run heartbeat, run reviewer, schedule next
# cycle.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
set -a
source "$SCRIPT_DIR/config.env"
set +a

STATE_FILE="$HEARTBEAT_HOME/next_cycle"
LOCK_FILE="/tmp/heartbeat-${GITHUB_ORG}.lock"
LOG="$HEARTBEAT_HOME/heartbeat.log"
LOG_DIR="$HEARTBEAT_HOME/logs"
mkdir -p "$LOG_DIR"

CYCLE_TS=$(date '+%Y-%m-%dT%H:%M')

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# Run a claude agent. Args: <name> <prompt-file>
# Logs PID, exit code, and duration to the tick log.
# Full session output goes to a per-run file in $LOG_DIR.
run_agent() {
    local name="$1" prompt_file="$2"
    local session_log="$LOG_DIR/${CYCLE_TS}-${name}.log"
    local prompt
    prompt="$(envsubst "$VARS" < "$prompt_file")"

    log "$name: starting (pid will follow)"
    /usr/local/bin/claude --dangerously-skip-permissions \
        --model "$CLAUDE_MODEL" --effort "$CLAUDE_EFFORT" \
        -p "$prompt" > "$session_log" 2>&1 &
    local pid=$!
    log "$name: pid $pid"
    wait "$pid"
    local rc=$?
    log "$name: exited $rc ($(wc -l < "$session_log") lines of output)"
    return 0
}

# Only one instance at a time.
exec 200>"$LOCK_FILE"
flock -n 200 || exit 0

NOW=$(date +%s)
NEXT=$(cat "$STATE_FILE" 2>/dev/null || echo 0)

if [ "$NOW" -lt "$NEXT" ]; then
    exit 0
fi

if [ -n "${USAGE_CHECK_CMD:-}" ]; then
    DELTA=$($USAGE_CHECK_CMD 2>/dev/null || true)
    if [ -n "${DELTA:-}" ] && python3 -c "import sys; sys.exit(0 if float('$DELTA') > $PACE_THRESHOLD else 1)" 2>/dev/null; then
        log "tick: pace hot (delta=$DELTA), reschedule 1h"
        echo $((NOW + 3600)) > "$STATE_FILE"
        exit 0
    fi
fi

log "tick: starting cycle (delta=${DELTA:-n/a})"

VARS='$GITHUB_ORG $WORKSPACE $HEARTBEAT_HOME $BOT_NAME $BOT_EMAIL $NOTIFY_TO $NOTIFY_FROM $OWNER_NAME'

run_agent heartbeat "$HEARTBEAT_HOME/heartbeat_prompt.md"
run_agent reviewer "$HEARTBEAT_HOME/reviewer_prompt.md"

# Release check on interval.
RELEASE_STATE="$HEARTBEAT_HOME/last_release_check"
LAST_RELEASE=$(cat "$RELEASE_STATE" 2>/dev/null || echo 0)
if [ $(($(date +%s) - LAST_RELEASE)) -ge "$RELEASE_CHECK_INTERVAL" ]; then
    run_agent release-check "$HEARTBEAT_HOME/release_check_prompt.md"
    date +%s > "$RELEASE_STATE"
fi

# Schedule next cycle.
OFFSET=$((CYCLE_MIN_SECONDS + RANDOM % CYCLE_JITTER_SECONDS))
echo $(($(date +%s) + OFFSET)) > "$STATE_FILE"
log "tick: cycle done, next in $((OFFSET/60))min"
