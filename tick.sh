#!/usr/bin/env bash
# Heartbeat tick — runs every 30min via cron, decides whether to start a new cycle.
#
# State: $HEARTBEAT_HOME/next_cycle holds the unix timestamp of the next eligible cycle.
# If not yet reached, exit. If the optional usage check says we're burning too fast,
# skip and reschedule 1h out. Otherwise: run heartbeat, run reviewer, schedule next
# cycle.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${1:-$SCRIPT_DIR/config.env}"
set -a
source "$CONFIG"
set +a

SCRIPTS_DIR="${SCRIPTS_DIR:-$SCRIPT_DIR}"
STATE_DIR="${STATE_DIR:-$HEARTBEAT_HOME}"
# Resolve the claude binary from PATH (override with CLAUDE_BIN in config.env).
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude || echo /usr/local/bin/claude)}"
STATE_FILE="$STATE_DIR/next_cycle"
LOCK_FILE="$STATE_DIR/.heartbeat.lock"
LOG="$STATE_DIR/heartbeat.log"
LOG_DIR="$STATE_DIR/logs"
mkdir -p "$LOG_DIR"

CYCLE_TS=$(date '+%Y-%m-%dT%H:%M')

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# Run a claude agent in interactive mode (keeps usage on the subscription
# plan, not the Agent SDK credit). Args: <name> <prompt-file>
# Launches claude in a tmux session with the expanded prompt as a system-prompt
# appendix. An interactive session never exits on its own, so the agent is told
# (in its prompt) to `touch $HEARTBEAT_HOME/.agent_done` as its very last
# action; we poll for that marker file and then send /exit. We use a FILE, not
# an on-screen sentinel: the TUI rewrites text with layout escapes (it can split
# a string mid-line), so scraping the session log/pane is unreliable.
# AGENT_TIMEOUT is the hard backstop if the marker never appears.
AGENT_TIMEOUT="${AGENT_TIMEOUT:-5400}"   # 90 min hard cap per agent

run_agent() {
    local name="$1" prompt_file="$2"
    local session_log="$LOG_DIR/${CYCLE_TS}-${name}.log"
    local prompt
    prompt="$(envsubst "$VARS" < "$prompt_file")"
    local tmux_sess="hb-${name}-$$"
    local prompt_tmp="$STATE_DIR/.prompt-${name}-$$"
    local done_marker="$STATE_DIR/.done-${name}-$$"
    local ready_marker="$HEARTBEAT_HOME/.agent_done"   # agent touches this when finished

    log "$name: starting (interactive/tmux)"

    printf '%s' "$prompt" > "$prompt_tmp"
    rm -f "$done_marker" "$ready_marker"

    # Launch claude interactively inside tmux.
    # script(1) records raw terminal output; done_marker signals process exit.
    # Export config vars into the tmux session so they're available to
    # commands the agent runs (e.g. get-github-app-token reads HEARTBEAT_HOME).
    local env_setup=""
    local var
    for var in HEARTBEAT_HOME SCRIPTS_DIR WORKSPACE GITHUB_ORG STATE_DIR \
               BOT_NAME BOT_EMAIL NOTIFY_TO NOTIFY_FROM OWNER_NAME \
               CLAUDE_MODEL CLAUDE_EFFORT PATH HOME; do
        env_setup+="export ${var}='${!var}'; "
    done

    # Record the session with a pty via script(1). BSD script (macOS) takes the
    # command as positional args; util-linux (Linux) needs `-c "CMD"`.
    local claude_cmd="$CLAUDE_BIN --dangerously-skip-permissions --model $CLAUDE_MODEL --effort $CLAUDE_EFFORT --append-system-prompt-file '$prompt_tmp' 'Begin.'"
    local rec
    case "$(uname)" in
        Darwin) rec="script -qF '$session_log' $claude_cmd" ;;
        *)      rec="script -qfc \"$claude_cmd\" '$session_log'" ;;
    esac

    tmux new-session -d -s "$tmux_sess" -x 200 -y 50 -c "$HEARTBEAT_HOME" \
        "${env_setup} ${rec} ; touch '$done_marker'"

    log "$name: tmux session $tmux_sess"

    # Poll for the agent's done marker; send /exit when it appears. Backstop:
    # AGENT_TIMEOUT. The agent process exiting (done_marker) also ends the loop,
    # in case it exits without us sending /exit.
    local elapsed=0
    while [ "$elapsed" -lt "$AGENT_TIMEOUT" ] && [ ! -f "$done_marker" ]; do
        sleep 10
        elapsed=$((elapsed + 10))

        if [ -f "$ready_marker" ]; then
            log "$name: done marker after ${elapsed}s, sending /exit"
            tmux send-keys -t "$tmux_sess" Escape
            sleep 0.2
            tmux send-keys -t "$tmux_sess" "/exit" Enter 2>/dev/null || true
            local ew=0
            while [ "$ew" -lt 20 ] && [ ! -f "$done_marker" ]; do
                sleep 1; ew=$((ew + 1))
            done
            break
        fi
    done

    if [ "$elapsed" -ge "$AGENT_TIMEOUT" ] && [ ! -f "$done_marker" ]; then
        log "$name: timeout after ${AGENT_TIMEOUT}s, killing"
    fi

    tmux kill-session -t "$tmux_sess" 2>/dev/null || true
    rm -f "$prompt_tmp" "$done_marker" "$ready_marker"

    log "$name: finished (${elapsed}s, $(wc -l < "$session_log" 2>/dev/null || echo 0) lines)"
    return 0
}

# Only one instance at a time. Portable mkdir lock with a PID liveness check
# (no flock on macOS; this also self-heals a stale lock left by a killed run).
if ! mkdir "$LOCK_FILE" 2>/dev/null; then
    OLDPID=$(cat "$LOCK_FILE/pid" 2>/dev/null || echo "")
    if [ -n "$OLDPID" ] && kill -0 "$OLDPID" 2>/dev/null; then
        exit 0   # a live tick already holds the lock
    fi
    rm -rf "$LOCK_FILE"                       # stale lock from a dead run
    mkdir "$LOCK_FILE" 2>/dev/null || exit 0
fi
echo $$ > "$LOCK_FILE/pid"
trap 'rm -rf "$LOCK_FILE"' EXIT

NOW=$(date +%s)
NEXT=$(cat "$STATE_FILE" 2>/dev/null || echo 0)

if [ "$NOW" -lt "$NEXT" ]; then
    exit 0
fi

if [ -n "${USAGE_CHECK_CMD:-}" ]; then
    DELTA=$($USAGE_CHECK_CMD 2>/dev/null || true)
    if [ -n "${DELTA:-}" ] && printf '%f' "$DELTA" >/dev/null 2>&1 && python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) > float(sys.argv[2]) else 1)" "$DELTA" "$PACE_THRESHOLD" 2>/dev/null; then
        log "tick: pace hot (delta=$DELTA), reschedule 1h"
        echo $((NOW + 3600)) > "$STATE_FILE"
        exit 0
    fi
fi

log "tick: starting cycle (delta=${DELTA:-n/a})"

LANG_GUIDE_FILE="$SCRIPTS_DIR/lang-guide-${GITHUB_ORG}.md"
if [ -f "$LANG_GUIDE_FILE" ]; then
    LANG_GUIDE="$(cat "$LANG_GUIDE_FILE")"
else
    LANG_GUIDE=""
fi
export LANG_GUIDE

VARS='$GITHUB_ORG $WORKSPACE $HEARTBEAT_HOME $SCRIPTS_DIR $LANG_GUIDE $BOT_NAME $BOT_EMAIL $NOTIFY_TO $NOTIFY_FROM $OWNER_NAME'

run_agent heartbeat "$SCRIPTS_DIR/heartbeat_prompt.md"
run_agent reviewer "$SCRIPTS_DIR/reviewer_prompt.md"

# Release check on interval.
RELEASE_STATE="$STATE_DIR/last_release_check"
LAST_RELEASE=$(cat "$RELEASE_STATE" 2>/dev/null || echo 0)
if [ $(($(date +%s) - LAST_RELEASE)) -ge "$RELEASE_CHECK_INTERVAL" ]; then
    run_agent release-check "$SCRIPTS_DIR/release_check_prompt.md"
    date +%s > "$RELEASE_STATE"
fi

# Schedule next cycle.
OFFSET=$((CYCLE_MIN_SECONDS + RANDOM % CYCLE_JITTER_SECONDS))
echo $(($(date +%s) + OFFSET)) > "$STATE_DIR/next_cycle"
log "tick: cycle done, next in $((OFFSET/60))min"
