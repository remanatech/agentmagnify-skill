#!/usr/bin/env bash
#
# heartbeat-daemon.sh - keep the session visibly alive while work is happening.
#
# Started by start-session.sh, stopped by complete-session.sh, and not meant to
# be run by hand.
#
# WHY A PROCESS AND NOT A RULE
#
# The panel derives active / quiet / stale from the last event and the last
# heartbeat, so an agent that works silently for an hour looks abandoned. The
# skill's answer to that used to be a row in a table -- `send-heartbeat.sh`,
# "keep the session alive during long silent work" -- and nothing anywhere told
# an agent when to call it. Observed on a real session: a roadmap and one
# task.started, then eleven files written and not one further event.
#
# Liveness is the wrong thing to ask a model to remember. It is a clock
# question, and a model has no clock: it acts between tool calls and cannot
# wake itself up. So this ticks on its own and the agent is left to report the
# things only it knows about.
#
# WHY IT STOPS
#
# A heartbeat is a claim that somebody is still working. A daemon that keeps
# ticking after the agent has gone turns a dead session into a live-looking one,
# which is a worse failure than the silence it was written to fix -- the panel
# would be confidently wrong instead of honestly uncertain.
#
# So it stops when the evidence of work stops. `report-event.sh` writes the
# sequence file on every event, so its age is the age of the last real report.
# Past AGENTMAGNIFY_HEARTBEAT_MAX_SILENCE the daemon exits and lets the session
# go quiet, then stale, which is the truth at that point.
#
# It also stops if the session file disappears, which is what completing or
# resetting a session looks like from here.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
. "$SCRIPT_DIR/lib.sh"

at_load_config || exit 0

INTERVAL="${AGENTMAGNIFY_HEARTBEAT_SECONDS:-300}"
MAX_SILENCE="${AGENTMAGNIFY_HEARTBEAT_MAX_SILENCE:-1800}"

case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=300 ;; esac
case "$MAX_SILENCE" in ''|*[!0-9]*) MAX_SILENCE=1800 ;; esac

# Below a minute this stops being a liveness signal and becomes traffic.
[ "$INTERVAL" -lt 60 ] && INTERVAL=60

last_event_age_seconds() {
  [ -f "$AT_SEQUENCE_FILE" ] || { printf '999999999'; return 0; }

  local mtime
  # BSD and GNU stat disagree, and one of them is always the wrong guess.
  mtime="$(stat -f %m "$AT_SEQUENCE_FILE" 2>/dev/null || stat -c %Y "$AT_SEQUENCE_FILE" 2>/dev/null || printf '')"
  case "$mtime" in
    ''|*[!0-9]*) printf '999999999' ;;
    *) printf '%s' "$(( $(at_epoch_seconds) - mtime ))" ;;
  esac
}

cleanup() {
  rm -f "$AT_HEARTBEAT_PID_FILE"
}
trap cleanup EXIT INT TERM

while :; do
  sleep "$INTERVAL"

  [ -f "$AT_SESSION_FILE" ] || exit 0

  if [ "$(last_event_age_seconds)" -gt "$MAX_SILENCE" ]; then
    at_debug "heartbeat daemon stopping: no event for more than ${MAX_SILENCE}s"
    exit 0
  fi

  bash "$SCRIPT_DIR/send-heartbeat.sh" >/dev/null 2>&1 || true
done
