#!/usr/bin/env bash
#
# complete-session.sh - close the monitoring session cleanly (doc 9.4, 27.2).
#
# Order matters:
#   1. drain the offline queue, so the history is complete
#   2. send a session_close snapshot, so the panel opens on the final state
#   3. POST /v1/agent/sessions/:sessionId/complete
#
# A session that is never completed shows up in the panel as "interrupted",
# which is the correct reading - so this script never invents success: if the
# API cannot be reached, it says so and leaves the queue in place.
#
# Usage:
#   complete-session.sh --summary "Auth and workflow engine delivered; 2 tests failing."
#   complete-session.sh --status interrupted --summary "User stopped the run."

set -euo pipefail

# shellcheck source=./lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

STATUS_VALUE="completed"
SUMMARY=""
SKIP_SNAPSHOT=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --status) [ "$#" -ge 2 ] || at_die "--status requires a value"; STATUS_VALUE="$2"; shift 2 ;;
    --summary) [ "$#" -ge 2 ] || at_die "--summary requires a value"; SUMMARY="$2"; shift 2 ;;
    --no-snapshot) SKIP_SNAPSHOT=1; shift ;;
    -h|--help)
      printf 'Usage: complete-session.sh [--status completed|interrupted] [--summary TEXT] [--no-snapshot]\n'
      exit 0
      ;;
    *) at_die "unknown option '$1'" ;;
  esac
done

case "$STATUS_VALUE" in
  completed|interrupted) ;;
  *) at_die "--status must be completed or interrupted" ;;
esac

at_load_config
at_require_deps || exit 1

# Before anything else, and whatever the rest of this script decides.
#
# The daemon claims somebody is still working. From the moment a session is
# being closed that claim is false, and it stays false even if the close
# itself fails -- so this does not sit behind a successful HTTP call.
at_stop_heartbeat

if ! at_load_session; then
  at_warn "no session on disk; nothing to complete"
  exit 0
fi

# 1. History first.
if [ -s "$AT_PENDING_FILE" ]; then
  at_info "flushing $(at_pending_count) queued event(s) before closing the session"
  "$AT_LIB_DIR/flush-pending-events.sh" >/dev/null || true
  at_load_session || true
fi

# 2. Final snapshot.
if [ "$SKIP_SNAPSHOT" = "0" ]; then
  SNAPSHOT_ARGS=( --kind session_close )
  if [ -n "$SUMMARY" ]; then
    SNAPSHOT_ARGS=( "${SNAPSHOT_ARGS[@]}" --summary "$SUMMARY" )
  fi
  "$AT_LIB_DIR/send-snapshot.sh" "${SNAPSHOT_ARGS[@]}" >/dev/null || true
fi

# 3. Close the session.
if ! at_have_token || [ "${AT_SESSION_ONLINE:-}" != "true" ]; then
  at_warn "session could not be closed against the API; the panel will show it as interrupted"
  at_set_session_field str localStatus "$STATUS_VALUE" || true
  at_set_session_field str closedAt "$(at_now)" || true
  printf 'session %s closed locally (%s)\n' "$AT_SESSION_ID" "$STATUS_VALUE"
  exit 0
fi

REQUEST_FILE="$(at_mktemp)"
printf '{}\n' > "$REQUEST_FILE"
at_json_set "$REQUEST_FILE" str status "$STATUS_VALUE"
if [ -n "$SUMMARY" ]; then
  at_json_set "$REQUEST_FILE" str summary "$SUMMARY"
fi

at_redact_json_file "$REQUEST_FILE"
if ! at_json_is_safe "$REQUEST_FILE"; then
  at_die "session summary still trips the secret filter after redaction; refusing to send"
fi

RESPONSE_FILE="$(at_mktemp)"
HTTP_STATUS="$(at_http_request POST "/v1/agent/sessions/$AT_SESSION_ID/complete" "$REQUEST_FILE" "$RESPONSE_FILE")"

if at_status_is_success "$HTTP_STATUS"; then
  at_set_session_field str localStatus "$STATUS_VALUE" || true
  at_set_session_field str closedAt "$(at_now)" || true
  at_set_session_field bool online false || true
  at_info "session $AT_SESSION_ID closed as $STATUS_VALUE"
  if [ -n "$AT_PANEL_URL" ]; then
    printf '%s\n' "$AT_PANEL_URL"
  else
    printf 'session %s closed (%s)\n' "$AT_SESSION_ID" "$STATUS_VALUE"
  fi
  exit 0
fi

at_error "session could not be closed: HTTP $HTTP_STATUS $(at_error_message "$RESPONSE_FILE")"
at_warn "the panel will mark this session interrupted once its activity window expires"
printf 'session %s not closed (HTTP %s)\n' "$AT_SESSION_ID" "$HTTP_STATUS"
exit 0
