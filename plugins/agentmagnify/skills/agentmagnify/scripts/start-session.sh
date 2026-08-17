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

# Nothing happens in a directory nobody connected. Not an error, not a queue,
# not a project created in somebody's panel because an agent was started in a
# folder: one line saying how to connect, and the session ends.
if ! at_project_is_connected; then
  at_info "this project is not connected to AgentMagnify, so nothing will be reported."
  at_info "connect it with: npx agentmagnify connect"
  printf 'not-connected\n'
  exit 4
fi

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
  # What this directory resolved to last time. The server prefers it over the
  # name, so renaming the folder -- or gaining a git remote, which changes the
  # inferred name outright -- keeps reporting into the same project instead of
  # opening a second one beside it. An id the workspace no longer has is
  # ignored there and the name resolves as before.
  [ -n "${AT_PROJECT_ID:-}" ] && at_json_set "$REQUEST_FILE" str project.id "$AT_PROJECT_ID"
fi

if [ -n "$RESUME_SESSION_ID" ]; then
  at_json_set "$REQUEST_FILE" str resumeSessionId "$RESUME_SESSION_ID"
fi

at_redact_json_file "$REQUEST_FILE"

RESPONSE_FILE="$(at_mktemp)"
STATUS="$(at_http_request POST /v1/agent/sessions "$REQUEST_FILE" "$RESPONSE_FILE")"

if ! at_status_is_success "$STATUS"; then
  if at_status_is_permanent_failure "$STATUS"; then
    #
    # A refusal is not an outage, and treating it as one is how somebody ends
    # up with a queue that will never drain and no idea why nothing appears in
    # the panel. This is the exact report we had from the field: a project that
    # could not be created because the plan had no room for it, reported as
    # "continuing in offline mode" — which reads as a network hiccup, so the
    # agent worked for an hour and filed everything into a queue for a project
    # that does not exist.
    #
    # So a 4xx says what the server said, in the server's own words, names the
    # one thing that fixes it, and stops. Nothing is queued: there is nothing
    # for the queue to be delivered to.
    #
    CODE="$(at_error_code "$RESPONSE_FILE")"
    MESSAGE="$(at_error_message "$RESPONSE_FILE")"

    at_error ""
    at_error "AgentMagnify is not reporting for this project."
    [ -n "$MESSAGE" ] && at_error "  $MESSAGE"

    case "${CODE:-}$STATUS" in
      PLAN_LIMIT_REACHED*|*402)
        at_error ""
        at_error "  This is a plan ceiling, not a fault. Either:"
        at_error "    - archive a project you no longer watch, in the panel, or"
        at_error "    - move to a plan with room: ${AGENTMAGNIFY_PANEL_URL:-$AT_DEFAULT_PANEL_URL}/settings/plans"
        ;;
      *401|*403)
        at_error ""
        at_error "  The key was refused. Pair this machine again:"
        at_error "    npx agentmagnify pair"
        ;;
      CLIENT_VERSION_TOO_OLD*)
        at_error ""
        at_error "  This client is older than the server accepts. Update it:"
        at_error "    npx agentmagnify@latest install"
        ;;
      *)
        at_error ""
        at_error "  Nothing was queued, because a refusal is not an outage."
        ;;
    esac
    at_error ""
    at_error "Development continues; only the reporting stopped."

    printf 'refused\n'
    exit 3
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

# Remember what this directory is, for every session after this one.
at_record_project_identity "$PROJECT_ID" "${PROJECT_LABEL:-$PROJECT_NAME}" "${AT_PROJECT_SLUG:-}"

# One line, once per session, when the server is running a newer client than
# this one. Not a check against npm: the server already knows, this request was
# going to happen anyway, and a tool that phones a third party from a
# developer's machine to ask about itself is a tool with something to explain.
LATEST_CLIENT="$(at_json_get "$AT_SESSION_FILE" 'protocol.latestClientVersion')"
if [ -n "$LATEST_CLIENT" ] && [ "$LATEST_CLIENT" != "$AT_CLIENT_VERSION" ] && at_version_lt "$AT_CLIENT_VERSION" "$LATEST_CLIENT"; then
  at_info "AgentMagnify $AT_CLIENT_VERSION is installed; $LATEST_CLIENT is available -- npx agentmagnify@latest install"
fi

if [ "$QUIET" = "0" ]; then
  at_info "session $SESSION_ID opened for project ${PROJECT_LABEL:-$PROJECT_ID}"

  # Liveness stops being something anybody has to remember from here on.
  at_start_heartbeat
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
