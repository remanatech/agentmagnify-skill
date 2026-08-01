#!/usr/bin/env bash
#
# start-session.sh - open a monitoring session and cache everything the other
# scripts need for the rest of the run.
#
# POSTs /v1/agent/sessions with the client identity, the executor and the
# detected capabilities, then writes state/session.json with the session id,
# project id, protocol version, reporting policy, reporting mode and panel URL,
# and finally prints the panel URL on stdout.
#
# When the API cannot be reached the script still succeeds: it writes a local
# offline session so that events are queued instead of lost (doc 13.7), and
# flush-pending-events.sh upgrades that session later.
#
# Usage: start-session.sh [--project-name NAME] [--executor TYPE]
#                         [--capability NAME]... [--resume SESSION_ID] [--quiet]

set -euo pipefail

# shellcheck source=./lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

PROJECT_NAME="${AGENTMAGNIFY_PROJECT_NAME:-}"
EXECUTOR_OVERRIDE=""
RESUME_SESSION_ID=""
QUIET=0
CAPABILITY_OVERRIDES=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project-name) [ "$#" -ge 2 ] || at_die "--project-name requires a value"; PROJECT_NAME="$2"; shift 2 ;;
    --executor) [ "$#" -ge 2 ] || at_die "--executor requires a value"; EXECUTOR_OVERRIDE="$2"; shift 2 ;;
    --resume) [ "$#" -ge 2 ] || at_die "--resume requires a value"; RESUME_SESSION_ID="$2"; shift 2 ;;
    --capability)
      [ "$#" -ge 2 ] || at_die "--capability requires a value"
      CAPABILITY_OVERRIDES="$CAPABILITY_OVERRIDES $2"
      shift 2
      ;;
    --quiet) QUIET=1; shift ;;
    -h|--help)
      printf 'Usage: start-session.sh [--project-name NAME] [--executor TYPE] [--capability NAME]... [--resume ID] [--quiet]\n'
      exit 0
      ;;
    *) at_die "unknown option '$1'" ;;
  esac
done

at_load_config
at_require_deps || exit 1

if [ -n "$CAPABILITY_OVERRIDES" ]; then
  AGENTMAGNIFY_CAPABILITIES="$CAPABILITY_OVERRIDES"
  export AGENTMAGNIFY_CAPABILITIES
fi

if [ -n "$EXECUTOR_OVERRIDE" ]; then
  AGENTMAGNIFY_EXECUTOR="$EXECUTOR_OVERRIDE"
  export AGENTMAGNIFY_EXECUTOR
fi

EXECUTOR_TYPE="$(at_executor_type)"
CAPABILITIES="$(at_capabilities)"

report_offline() {
  local reason="$1"
  at_warn "session could not be opened ($reason); continuing in offline mode"
  at_write_local_session
  at_info "reporting mode: $(at_local_reporting_mode) (offline, protocol unverified)"
  at_info "events will be queued in state/pending-events.jsonl and flushed later"
  printf 'offline\n'
}

if ! at_have_token; then
  at_error "AGENTMAGNIFY_TOKEN is not set"
  at_error "export a project token (prj_live_...) or a workspace ingestion token (wsi_live_...) and run this script again"
  report_offline "no token"
  exit 0
fi

at_info "opening a monitoring session with a $(at_token_hint) against $AT_API_URL"

# ---------------------------------------------------------------------------
# Build the handshake request (doc 13.2)
# ---------------------------------------------------------------------------

REQUEST_FILE="$(at_mktemp)"
printf '{}\n' > "$REQUEST_FILE"

at_json_set "$REQUEST_FILE" str client.name "$AT_CLIENT_NAME"
at_json_set "$REQUEST_FILE" str client.version "$AT_CLIENT_VERSION"
at_json_set "$REQUEST_FILE" str executor.type "$EXECUTOR_TYPE"
if [ -n "${AGENTMAGNIFY_EXECUTOR_VERSION:-}" ]; then
  at_json_set "$REQUEST_FILE" str executor.version "$AGENTMAGNIFY_EXECUTOR_VERSION"
fi
EXECUTOR_LABEL="$(at_executor_label)"
if [ -n "$EXECUTOR_LABEL" ]; then
  at_json_set "$REQUEST_FILE" str executor.label "$EXECUTOR_LABEL"
fi

at_json_set "$REQUEST_FILE" json capabilities '[]'
CAPABILITY_INDEX=0
for CAPABILITY in $CAPABILITIES; do
  at_json_set "$REQUEST_FILE" str "capabilities.$CAPABILITY_INDEX" "$CAPABILITY"
  CAPABILITY_INDEX=$(( CAPABILITY_INDEX + 1 ))
done

# A project token is already bound to one project. Only a workspace ingestion
# token may name a project, and only then may it be created on the fly.
#
# The flag is parsed before at_load_config runs, so an unset --project-name has
# to fall back to the resolved identity here rather than at parse time; that
# fallback is what lets a fresh repository need no configuration at all.
[ -z "$PROJECT_NAME" ] && PROJECT_NAME="${AT_PROJECT_NAME:-}"

if [ "$(at_token_kind)" = "workspace_ingestion" ] && [ -n "$PROJECT_NAME" ]; then
  at_json_set "$REQUEST_FILE" str project.name "$PROJECT_NAME"
  [ -n "${AT_PROJECT_SLUG:-}" ] && at_json_set "$REQUEST_FILE" str project.slug "$AT_PROJECT_SLUG"
fi

if [ -n "$RESUME_SESSION_ID" ]; then
  at_json_set "$REQUEST_FILE" str resumeSessionId "$RESUME_SESSION_ID"
fi

at_redact_json_file "$REQUEST_FILE"

RESPONSE_FILE="$(at_mktemp)"
STATUS="$(at_http_request POST /v1/agent/sessions "$REQUEST_FILE" "$RESPONSE_FILE")"

if ! at_status_is_success "$STATUS"; then
  if at_status_is_permanent_failure "$STATUS"; then
    at_error "the API refused the session: HTTP $STATUS $(at_error_message "$RESPONSE_FILE")"
    case "$STATUS" in
      401|403) at_error "check AGENTMAGNIFY_TOKEN: it may be revoked, expired, or scoped to another project" ;;
    esac
  fi
  report_offline "HTTP $STATUS"
  exit 0
fi

if ! at_json_valid "$RESPONSE_FILE"; then
  report_offline "the API returned something that is not JSON"
  exit 0
fi

SESSION_ID="$(at_json_get "$RESPONSE_FILE" 'sessionId')"
if [ -z "$SESSION_ID" ]; then
  report_offline "the API response contained no sessionId"
  exit 0
fi

# ---------------------------------------------------------------------------
# Persist the session
# ---------------------------------------------------------------------------

at_ensure_state_dir
cp "$RESPONSE_FILE" "$AT_SESSION_FILE"

PROTOCOL_VERSION="$(at_json_get "$AT_SESSION_FILE" 'protocol.version')"
if [ -z "$PROTOCOL_VERSION" ]; then
  PROTOCOL_VERSION="$AT_FALLBACK_PROTOCOL_VERSION"
fi

at_json_set "$AT_SESSION_FILE" str protocolVersion "$PROTOCOL_VERSION"
at_json_set "$AT_SESSION_FILE" bool online true
at_json_set "$AT_SESSION_FILE" str startedAt "$(at_now)"
at_json_set "$AT_SESSION_FILE" str apiUrl "$AT_API_URL"
at_json_set "$AT_SESSION_FILE" str executorType "$EXECUTOR_TYPE"

at_reset_sequence

# The protocol bundle carries the JSON Schema, the reporting policy and the
# agent instructions. Fetch it for the exact version this session is pinned to.
"$AT_LIB_DIR/fetch-schema.sh" --version "$PROTOCOL_VERSION" >/dev/null || true

PROJECT_ID="$(at_json_get "$AT_SESSION_FILE" 'projectId')"
PROJECT_LABEL="$(at_json_get "$AT_SESSION_FILE" 'projectName')"
PANEL_URL="$(at_json_get "$AT_SESSION_FILE" 'panelUrl')"
REPORTING_MODE="$(at_json_get "$AT_SESSION_FILE" 'reportingMode')"
PROTOCOL_STATUS="$(at_json_get "$AT_SESSION_FILE" 'protocolStatus')"

if [ "$QUIET" = "0" ]; then
  at_info "session $SESSION_ID opened for project ${PROJECT_LABEL:-$PROJECT_ID}"
  at_info "protocol $PROTOCOL_VERSION (${PROTOCOL_STATUS:-verified}), reporting mode ${REPORTING_MODE:-unknown}"
fi

# Anything held by an earlier run belongs in this project's history.
#
# Two queues, drained by one call. `pending-events.jsonl` is what could not be
# delivered because the API was unreachable. `dead-letter.jsonl` additionally
# holds the events that were refused because the credential was refused, and
# this handshake is the proof that a credential is being accepted again - which
# is exactly the moment those become sendable, and the only moment the skill
# gets one for free. flush-pending-events.sh decides what is recoverable and
# rate-limits itself; see replay_dead_letters() there.
#
# Skipped when flush-pending-events.sh is the caller: it is already draining.
if [ "${AT_SKIP_QUEUE_FLUSH:-0}" != "1" ] &&
   { [ -s "$AT_PENDING_FILE" ] || [ -s "$AT_DEAD_LETTER_FILE" ]; }; then
  if [ -s "$AT_PENDING_FILE" ]; then
    at_info "flushing $(at_pending_count) event(s) queued while the API was unreachable"
  fi
  AT_SKIP_SESSION_UPGRADE=1 "$AT_LIB_DIR/flush-pending-events.sh" --replay-dead-letters \
    >/dev/null || true
fi

if [ -n "$PANEL_URL" ]; then
  printf '%s\n' "$PANEL_URL"
else
  printf 'session %s started (no panel URL returned)\n' "$SESSION_ID"
fi
exit 0
