#!/usr/bin/env bash
#
# send-heartbeat.sh - tell the API the session is still alive (doc 20).
#
# The panel derives active / quiet / stale from the last event and the last
# heartbeat, so a long-running task must keep this ticking even when it has
# nothing meaningful to report.
#
# Heartbeats are deliberately NOT queued: a heartbeat delivered hours late says
# nothing true about liveness, and the panel is right to call that session
# stale. A failed heartbeat therefore only logs and exits 0.
#
# Usage: send-heartbeat.sh [--status active|working|idle] [--note TEXT]

set -euo pipefail

# shellcheck source=./lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

STATUS_LABEL="active"
NOTE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --status) [ "$#" -ge 2 ] || at_die "--status requires a value"; STATUS_LABEL="$2"; shift 2 ;;
    --note) [ "$#" -ge 2 ] || at_die "--note requires a value"; NOTE="$2"; shift 2 ;;
    -h|--help) printf 'Usage: send-heartbeat.sh [--status active|working|idle] [--note TEXT]\n'; exit 0 ;;
    *) at_die "unknown option '$1'" ;;
  esac
done

at_load_config
at_require_deps || exit 1

if ! at_load_session; then
  at_debug "no session on disk; nothing to keep alive"
  exit 0
fi

if [ "${AT_SESSION_ONLINE:-}" != "true" ]; then
  at_debug "session is offline; skipping heartbeat"
  exit 0
fi

if ! at_have_token; then
  at_debug "no token; skipping heartbeat"
  exit 0
fi

REQUEST_FILE="$(at_mktemp)"
printf '{}\n' > "$REQUEST_FILE"

RESPONSE_FILE="$(at_mktemp)"
HTTP_STATUS="$(at_http_request POST "/v1/agent/sessions/$AT_SESSION_ID/heartbeat" "$REQUEST_FILE" "$RESPONSE_FILE")"

if at_status_is_success "$HTTP_STATUS"; then
  printf '%s\n' "$(at_now)" > "$AT_STATE_DIR/last-heartbeat"
  at_debug "heartbeat accepted"
  printf 'heartbeat ok\n'
  exit 0
fi

# Some deployments expose liveness only through the event stream. Fall back to a
# heartbeat event so the panel still sees the session as alive.
case "$HTTP_STATUS" in
  404|405)
    at_debug "heartbeat endpoint not available; sending a heartbeat event instead"
    ARGS=( --type heartbeat --agent-id "${AGENTMAGNIFY_AGENT_ID:-project-observer}" --kind observer --role observer )
    if [ -n "$NOTE" ]; then
      ARGS=( "${ARGS[@]}" --summary "$NOTE" )
    fi
    ARGS=( "${ARGS[@]}" --metadata "status=$STATUS_LABEL" )
    "$AT_LIB_DIR/report-event.sh" "${ARGS[@]}" >/dev/null || true
    printf '%s\n' "$(at_now)" > "$AT_STATE_DIR/last-heartbeat"
    printf 'heartbeat ok (event fallback)\n'
    exit 0
    ;;
esac

at_warn "heartbeat could not be delivered (HTTP $HTTP_STATUS); not queueing it"
printf 'heartbeat failed\n'
exit 0
