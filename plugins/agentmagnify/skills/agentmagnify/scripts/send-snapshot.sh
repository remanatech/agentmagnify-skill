#!/usr/bin/env bash
#
# send-snapshot.sh - POST a project snapshot to /v1/snapshots (doc 16).
#
# Events build the history; the snapshot is what lets the panel open the current
# state instantly. The Project Observer owns this script: it sends a periodic
# snapshot on the policy interval, one after a roadmap change or a correction,
# and one when the session closes.
#
# Usage:
#   send-snapshot.sh --kind periodic \
#     --summary "Authentication done. Workflow engine in progress." \
#     --roadmap-progress 58 --reported-progress 72 --verified-progress 44 \
#     --confidence 0.71 --current-phase "Workflow Engine"
#
# Kinds: periodic | session_close | roadmap_change | observer_correction | manual

set -euo pipefail

# shellcheck source=./lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

KIND="periodic"
SUMMARY=""
CURRENT_PHASE=""
ROADMAP_PROGRESS=""
REPORTED_PROGRESS=""
VERIFIED_PROGRESS=""
CONFIDENCE=""
REPORTER_AGENT_ID="${AGENTMAGNIFY_AGENT_ID:-project-observer}"
REPORTER_KIND="${AGENTMAGNIFY_AGENT_KIND:-observer}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --kind) [ "$#" -ge 2 ] || at_die "--kind requires a value"; KIND="$2"; shift 2 ;;
    --summary) [ "$#" -ge 2 ] || at_die "--summary requires a value"; SUMMARY="$2"; shift 2 ;;
    --current-phase) [ "$#" -ge 2 ] || at_die "--current-phase requires a value"; CURRENT_PHASE="$2"; shift 2 ;;
    --roadmap-progress) [ "$#" -ge 2 ] || at_die "--roadmap-progress requires a value"; ROADMAP_PROGRESS="$2"; shift 2 ;;
    --reported-progress) [ "$#" -ge 2 ] || at_die "--reported-progress requires a value"; REPORTED_PROGRESS="$2"; shift 2 ;;
    --verified-progress) [ "$#" -ge 2 ] || at_die "--verified-progress requires a value"; VERIFIED_PROGRESS="$2"; shift 2 ;;
    --confidence) [ "$#" -ge 2 ] || at_die "--confidence requires a value"; CONFIDENCE="$2"; shift 2 ;;
    --agent-id) [ "$#" -ge 2 ] || at_die "--agent-id requires a value"; REPORTER_AGENT_ID="$2"; shift 2 ;;
    --kind-of-reporter) [ "$#" -ge 2 ] || at_die "--kind-of-reporter requires a value"; REPORTER_KIND="$2"; shift 2 ;;
    -h|--help)
      printf 'Usage: send-snapshot.sh [--kind KIND] [--summary TEXT] [--current-phase TEXT]\n'
      printf '                        [--roadmap-progress N] [--reported-progress N]\n'
      printf '                        [--verified-progress N] [--confidence 0..1]\n'
      exit 0
      ;;
    *) at_die "unknown option '$1'" ;;
  esac
done

case "$KIND" in
  periodic|session_close|roadmap_change|observer_correction|manual) ;;
  *) at_die "unknown snapshot kind '$KIND'" ;;
esac

at_load_config
at_require_deps || exit 1
at_ensure_session

check_percentage() {
  local label="$1"
  local value="$2"
  [ -n "$value" ] || return 0
  if ! at_is_number "$value"; then
    at_die "$label must be a number, got '$value'"
  fi
  if [ "${value%%.*}" -lt 0 ] || [ "${value%%.*}" -gt 100 ]; then
    at_die "$label must be between 0 and 100"
  fi
}

check_percentage --roadmap-progress "$ROADMAP_PROGRESS"
check_percentage --reported-progress "$REPORTED_PROGRESS"
check_percentage --verified-progress "$VERIFIED_PROGRESS"
if [ -n "$CONFIDENCE" ] && ! at_is_number "$CONFIDENCE"; then
  at_die "--confidence must be a number between 0 and 1"
fi

REQUEST_FILE="$(at_mktemp)"
printf '{}\n' > "$REQUEST_FILE"

at_json_set "$REQUEST_FILE" str sessionId "$AT_SESSION_ID"
at_json_set "$REQUEST_FILE" str kind "$KIND"
if [ -n "$SUMMARY" ]; then at_json_set "$REQUEST_FILE" str summary "$SUMMARY"; fi
if [ -n "$CURRENT_PHASE" ]; then at_json_set "$REQUEST_FILE" str currentPhase "$CURRENT_PHASE"; fi
if [ -n "$ROADMAP_PROGRESS" ]; then at_json_set "$REQUEST_FILE" num progress.roadmap "$ROADMAP_PROGRESS"; fi
if [ -n "$REPORTED_PROGRESS" ]; then at_json_set "$REQUEST_FILE" num progress.reported "$REPORTED_PROGRESS"; fi
if [ -n "$VERIFIED_PROGRESS" ]; then at_json_set "$REQUEST_FILE" num progress.verified "$VERIFIED_PROGRESS"; fi
if [ -n "$CONFIDENCE" ]; then at_json_set "$REQUEST_FILE" num progress.confidence "$CONFIDENCE"; fi

at_redact_json_file "$REQUEST_FILE"
if ! at_json_is_safe "$REQUEST_FILE"; then
  at_die "snapshot still trips the secret filter after redaction; refusing to send"
fi

queue_as_event() {
  local reason="$1"
  if [ "$REPORTER_KIND" != "observer" ]; then
    at_warn "snapshot not delivered ($reason); it is not queued because only the observer may emit snapshot.created"
    return 0
  fi
  at_warn "snapshot not delivered ($reason); queueing a snapshot.created event instead"
  local args
  args=( --type snapshot.created --agent-id "$REPORTER_AGENT_ID" --role observer --kind observer )
  if [ -n "$SUMMARY" ]; then args=( "${args[@]}" --summary "$SUMMARY" ); fi
  if [ -n "$ROADMAP_PROGRESS" ]; then args=( "${args[@]}" --progress-roadmap "$ROADMAP_PROGRESS" ); fi
  if [ -n "$REPORTED_PROGRESS" ]; then args=( "${args[@]}" --progress-reported "$REPORTED_PROGRESS" ); fi
  if [ -n "$VERIFIED_PROGRESS" ]; then args=( "${args[@]}" --progress-verified "$VERIFIED_PROGRESS" ); fi
  if [ -n "$CONFIDENCE" ]; then args=( "${args[@]}" --progress-confidence "$CONFIDENCE" ); fi
  args=( "${args[@]}" --metadata "snapshotKind=$KIND" )
  "$AT_LIB_DIR/report-event.sh" "${args[@]}" >/dev/null || true
}

if ! at_have_token; then
  queue_as_event "no token"
  exit 0
fi

RESPONSE_FILE="$(at_mktemp)"
STATUS="$(at_http_request POST /v1/snapshots "$REQUEST_FILE" "$RESPONSE_FILE")"

if at_status_is_success "$STATUS"; then
  at_info "snapshot ($KIND) recorded"
  printf 'snapshot %s recorded\n' "$KIND"
  exit 0
fi

if at_status_is_permanent_failure "$STATUS"; then
  at_error "snapshot rejected: HTTP $STATUS $(at_error_message "$RESPONSE_FILE")"
  exit 0
fi

queue_as_event "HTTP $STATUS"
exit 0
