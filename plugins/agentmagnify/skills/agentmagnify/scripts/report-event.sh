#!/usr/bin/env bash
#
# report-event.sh - the single entry point for sending one event to the
# AgentMagnify API.
#
# It fills in the envelope (eventId, sessionId, projectId, protocolVersion,
# sequence, timestamp), runs the local secret filter, validates the event
# against the per-type contract BEFORE sending, and then:
#
#   * POSTs it to /v1/events with an Idempotency-Key header, or
#   * appends it to state/pending-events.jsonl when the network is unavailable
#     (exit code 0, because development must never stop for monitoring), or
#   * moves it to state/dead-letter.jsonl when the API rejects it with a
#     permanent 4xx, so it is never retried forever.
#
# A dead-lettered event carries a `deadLetterKind` saying which of those it was
# (see at_dead_letter_kind_for_status in lib.sh). A 401 or 403 means the
# credential was refused and the event itself is fine: it is held rather than
# discarded, and flush-pending-events.sh --replay-dead-letters sends it once the
# machine has a working credential again. Anything else is the API refusing this
# particular payload, and is never re-sent.
#
# Usage:
#   report-event.sh --type task.completed --task-id auth-api \
#     --task-title "Authentication API" --agent-id backend-developer \
#     --role backend --kind logical \
#     --summary "Endpoints and token rotation implemented." \
#     --verification-method test --verification-result passed \
#     --verification-passed 18 --verification-failed 0 \
#     --evidence-changed-files 7 --evidence-commit a81f93c
#
#   report-event.sh --json event.json          # payload from a file
#   report-event.sh --json -                   # payload from stdin
#
# Run with --help for the full flag list.

set -euo pipefail

# shellcheck source=./lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'USAGEEOF'
report-event.sh - send one monitoring event.

Envelope:
  --type TYPE                    event type (required unless supplied in JSON)
  --summary TEXT                 one short sentence, no source, no logs
  --parent-event-id ID           the event this one comments on (task.reviewed)
  --severity low|medium|high|critical
  --json FILE|-                  base payload from a file or stdin
  --dry-run                      build, redact and validate only; print the event
  --print                        print the event JSON that was sent
  -h, --help                     this text

Reporter identity (who is speaking):
  --agent-id ID                  stable logical agent id, e.g. backend-developer
  --role ROLE                    backend, frontend, qa, orchestrator, observer
  --kind main|logical|observer   defaults to logical
  --display-name NAME
  --executor-id ID               real process/session id

Task:
  --task-id ID  --task-title TEXT  --task-status pending|assigned|in_progress|completed|failed|blocked
  --task-phase-id ID  --task-weight N  --task-assignee AGENT_ID

Phase and roadmap:
  --phase-id ID  --phase-title TEXT  --phase-status TEXT  --phase-order N
  --roadmap-json FILE|-          roadmap object for roadmap.created/updated

Agent being described (agent.* events; defaults to the reporter identity):
  --about-agent-id ID  --about-agent-name TEXT  --about-agent-role TEXT
  --about-agent-kind main|logical|observer  --about-agent-status TEXT
  --about-agent-task-id ID  --about-agent-waiting-for TEXT

Verification (evidence that a claim is true):
  --verification-method test|build|qa|commit|artifact|acceptance_criteria|manual|none
  --verification-command TEXT  --verification-result passed|failed|skipped|pending
  --verification-passed N  --verification-failed N  --verification-skipped N
  --verification-duration-ms N  --verification-details TEXT

Evidence (metadata only, never file contents):
  --evidence-changed-files N  --evidence-insertions N  --evidence-deletions N
  --evidence-commit HASH  --evidence-branch NAME  --evidence-note TEXT
  --evidence-artifact-id ID  --evidence-test-run-id ID  --evidence-build-id ID

Progress (0-100, derived from roadmap weights, never from elapsed time):
  --progress N                   same as --progress-reported
  --progress-reported N  --progress-roadmap N  --progress-verified N
  --progress-confidence 0..1

Blocker and decision:
  --blocker-id ID  --blocker-title TEXT  --blocker-severity LEVEL
  --blocker-task-id ID  --blocker-agent-id ID  --blocker-resolution TEXT
  --decision-id ID  --decision-question TEXT  --decision-context TEXT
  --decision-option TEXT (repeatable)  --decision-answer TEXT
  --decision-task-id ID  --decision-expires-at RFC3339

Test and build:
  --test-id ID  --test-suite TEXT  --test-command TEXT
  --test-status running|passed|failed
  --test-passed N  --test-failed N  --test-skipped N  --test-duration-ms N
  --test-failing TEXT (repeatable)
  --build-id ID  --build-name TEXT  --build-command TEXT
  --build-status running|succeeded|failed  --build-duration-ms N
  --build-error TEXT

Artifact and deployment:
  --artifact-id ID  --artifact-name TEXT  --artifact-kind TEXT
  --artifact-url URL  --artifact-size-bytes N
  --deployment-id ID  --deployment-environment TEXT
  --deployment-status running|succeeded|failed  --deployment-url URL

Observer assessment (observer only):
  --assessment-verdict unverified|pending|verified|disputed|failed
  --assessment-reason TEXT  --assessment-reported-status TEXT
  --assessment-verified-status TEXT  --assessment-confidence 0..1

Other:
  --metadata KEY=VALUE (repeatable)
USAGEEOF
}

SET_KINDS=()
SET_PATHS=()
SET_VALUES=()

add_set() {
  SET_KINDS+=("$1")
  SET_PATHS+=("$2")
  SET_VALUES+=("$3")
}

add_str() {
  [ -n "$2" ] || return 0
  add_set str "$1" "$2"
}

add_num() {
  [ -n "$2" ] || return 0
  if ! at_is_number "$2"; then
    at_die "value for $1 must be a number, got '$2'"
  fi
  add_set num "$1" "$2"
}

add_int() {
  [ -n "$2" ] || return 0
  if ! at_is_integer "$2"; then
    at_die "value for $1 must be a whole number, got '$2'"
  fi
  add_set num "$1" "$2"
}

need_value() {
  if [ "$2" -lt 2 ]; then
    at_die "$1 requires a value"
  fi
}

EVENT_TYPE=""
BASE_JSON_SOURCE=""
ROADMAP_JSON_SOURCE=""
DRY_RUN=0
PRINT_EVENT=0
DECISION_OPTION_INDEX=0
TEST_FAILING_INDEX=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --print) PRINT_EVENT=1; shift ;;
    --json) need_value "$1" "$#"; BASE_JSON_SOURCE="$2"; shift 2 ;;
    --roadmap-json) need_value "$1" "$#"; ROADMAP_JSON_SOURCE="$2"; shift 2 ;;

    --type) need_value "$1" "$#"; EVENT_TYPE="$2"; shift 2 ;;
    --summary) need_value "$1" "$#"; add_str summary "$2"; shift 2 ;;
    --parent-event-id) need_value "$1" "$#"; add_str parentEventId "$2"; shift 2 ;;
    --severity) need_value "$1" "$#"; add_str severity "$2"; shift 2 ;;

    --agent-id) need_value "$1" "$#"; add_str reporter.agentId "$2"; shift 2 ;;
    --role) need_value "$1" "$#"; add_str reporter.role "$2"; shift 2 ;;
    --kind) need_value "$1" "$#"; add_str reporter.kind "$2"; shift 2 ;;
    --display-name) need_value "$1" "$#"; add_str reporter.displayName "$2"; shift 2 ;;
    --executor-id) need_value "$1" "$#"; add_str reporter.executorId "$2"; shift 2 ;;

    --task-id) need_value "$1" "$#"; add_str task.id "$2"; shift 2 ;;
    --task-title) need_value "$1" "$#"; add_str task.title "$2"; shift 2 ;;
    --task-status) need_value "$1" "$#"; add_str task.status "$2"; shift 2 ;;
    --task-phase-id) need_value "$1" "$#"; add_str task.phaseId "$2"; shift 2 ;;
    --task-weight) need_value "$1" "$#"; add_int task.weight "$2"; shift 2 ;;
    --task-assignee) need_value "$1" "$#"; add_str task.assigneeAgentId "$2"; shift 2 ;;

    --phase-id) need_value "$1" "$#"; add_str phase.id "$2"; shift 2 ;;
    --phase-title) need_value "$1" "$#"; add_str phase.title "$2"; shift 2 ;;
    --phase-status) need_value "$1" "$#"; add_str phase.status "$2"; shift 2 ;;
    --phase-order) need_value "$1" "$#"; add_int phase.order "$2"; shift 2 ;;

    --about-agent-id) need_value "$1" "$#"; add_str agent.id "$2"; shift 2 ;;
    --about-agent-name) need_value "$1" "$#"; add_str agent.displayName "$2"; shift 2 ;;
    --about-agent-role) need_value "$1" "$#"; add_str agent.role "$2"; shift 2 ;;
    --about-agent-kind) need_value "$1" "$#"; add_str agent.kind "$2"; shift 2 ;;
    --about-agent-status) need_value "$1" "$#"; add_str agent.status "$2"; shift 2 ;;
    --about-agent-task-id) need_value "$1" "$#"; add_str agent.currentTaskId "$2"; shift 2 ;;
    --about-agent-waiting-for) need_value "$1" "$#"; add_str agent.waitingFor "$2"; shift 2 ;;

    --verification-method) need_value "$1" "$#"; add_str verification.method "$2"; shift 2 ;;
    --verification-command) need_value "$1" "$#"; add_str verification.command "$2"; shift 2 ;;
    --verification-result) need_value "$1" "$#"; add_str verification.result "$2"; shift 2 ;;
    --verification-passed) need_value "$1" "$#"; add_int verification.passed "$2"; shift 2 ;;
    --verification-failed) need_value "$1" "$#"; add_int verification.failed "$2"; shift 2 ;;
    --verification-skipped) need_value "$1" "$#"; add_int verification.skipped "$2"; shift 2 ;;
    --verification-duration-ms) need_value "$1" "$#"; add_int verification.durationMs "$2"; shift 2 ;;
    --verification-details) need_value "$1" "$#"; add_str verification.details "$2"; shift 2 ;;

    --evidence-changed-files) need_value "$1" "$#"; add_int evidence.changedFiles "$2"; shift 2 ;;
    --evidence-insertions) need_value "$1" "$#"; add_int evidence.insertions "$2"; shift 2 ;;
    --evidence-deletions) need_value "$1" "$#"; add_int evidence.deletions "$2"; shift 2 ;;
    --evidence-commit) need_value "$1" "$#"; add_str evidence.commit "$2"; shift 2 ;;
    --evidence-branch) need_value "$1" "$#"; add_str evidence.branch "$2"; shift 2 ;;
    --evidence-note) need_value "$1" "$#"; add_str evidence.note "$2"; shift 2 ;;
    --evidence-artifact-id) need_value "$1" "$#"; add_str evidence.artifactId "$2"; shift 2 ;;
    --evidence-test-run-id) need_value "$1" "$#"; add_str evidence.testRunId "$2"; shift 2 ;;
    --evidence-build-id) need_value "$1" "$#"; add_str evidence.buildId "$2"; shift 2 ;;

    --progress|--progress-reported) need_value "$1" "$#"; add_num progress.reported "$2"; shift 2 ;;
    --progress-roadmap) need_value "$1" "$#"; add_num progress.roadmap "$2"; shift 2 ;;
    --progress-verified) need_value "$1" "$#"; add_num progress.verified "$2"; shift 2 ;;
    --progress-confidence) need_value "$1" "$#"; add_num progress.confidence "$2"; shift 2 ;;

    --blocker-id) need_value "$1" "$#"; add_str blocker.id "$2"; shift 2 ;;
    --blocker-title) need_value "$1" "$#"; add_str blocker.title "$2"; shift 2 ;;
    --blocker-severity) need_value "$1" "$#"; add_str blocker.severity "$2"; shift 2 ;;
    --blocker-task-id) need_value "$1" "$#"; add_str blocker.taskId "$2"; shift 2 ;;
    --blocker-agent-id) need_value "$1" "$#"; add_str blocker.agentId "$2"; shift 2 ;;
    --blocker-resolution) need_value "$1" "$#"; add_str blocker.resolution "$2"; shift 2 ;;

    --decision-id) need_value "$1" "$#"; add_str decision.id "$2"; shift 2 ;;
    --decision-question) need_value "$1" "$#"; add_str decision.question "$2"; shift 2 ;;
    --decision-context) need_value "$1" "$#"; add_str decision.context "$2"; shift 2 ;;
    --decision-answer) need_value "$1" "$#"; add_str decision.answer "$2"; shift 2 ;;
    --decision-task-id) need_value "$1" "$#"; add_str decision.taskId "$2"; shift 2 ;;
    --decision-expires-at) need_value "$1" "$#"; add_str decision.expiresAt "$2"; shift 2 ;;
    --decision-option)
      need_value "$1" "$#"
      add_str "decision.options.$DECISION_OPTION_INDEX" "$2"
      DECISION_OPTION_INDEX=$(( DECISION_OPTION_INDEX + 1 ))
      shift 2
      ;;

    --test-id) need_value "$1" "$#"; add_str test.id "$2"; shift 2 ;;
    --test-suite) need_value "$1" "$#"; add_str test.suite "$2"; shift 2 ;;
    --test-command) need_value "$1" "$#"; add_str test.command "$2"; shift 2 ;;
    --test-status) need_value "$1" "$#"; add_str test.status "$2"; shift 2 ;;
    --test-passed) need_value "$1" "$#"; add_int test.passed "$2"; shift 2 ;;
    --test-failed) need_value "$1" "$#"; add_int test.failed "$2"; shift 2 ;;
    --test-skipped) need_value "$1" "$#"; add_int test.skipped "$2"; shift 2 ;;
    --test-duration-ms) need_value "$1" "$#"; add_int test.durationMs "$2"; shift 2 ;;
    --test-failing)
      need_value "$1" "$#"
      add_str "test.failingTests.$TEST_FAILING_INDEX" "$2"
      TEST_FAILING_INDEX=$(( TEST_FAILING_INDEX + 1 ))
      shift 2
      ;;

    --build-id) need_value "$1" "$#"; add_str build.id "$2"; shift 2 ;;
    --build-name) need_value "$1" "$#"; add_str build.name "$2"; shift 2 ;;
    --build-command) need_value "$1" "$#"; add_str build.command "$2"; shift 2 ;;
    --build-status) need_value "$1" "$#"; add_str build.status "$2"; shift 2 ;;
    --build-duration-ms) need_value "$1" "$#"; add_int build.durationMs "$2"; shift 2 ;;
    --build-error) need_value "$1" "$#"; add_str build.errorSummary "$2"; shift 2 ;;

    --artifact-id) need_value "$1" "$#"; add_str artifact.id "$2"; shift 2 ;;
    --artifact-name) need_value "$1" "$#"; add_str artifact.name "$2"; shift 2 ;;
    --artifact-kind) need_value "$1" "$#"; add_str artifact.kind "$2"; shift 2 ;;
    --artifact-url) need_value "$1" "$#"; add_str artifact.url "$2"; shift 2 ;;
    --artifact-size-bytes) need_value "$1" "$#"; add_int artifact.sizeBytes "$2"; shift 2 ;;

    --deployment-id) need_value "$1" "$#"; add_str deployment.id "$2"; shift 2 ;;
    --deployment-environment) need_value "$1" "$#"; add_str deployment.environment "$2"; shift 2 ;;
    --deployment-status) need_value "$1" "$#"; add_str deployment.status "$2"; shift 2 ;;
    --deployment-url) need_value "$1" "$#"; add_str deployment.url "$2"; shift 2 ;;

    --assessment-verdict) need_value "$1" "$#"; add_str assessment.verdict "$2"; shift 2 ;;
    --assessment-reason) need_value "$1" "$#"; add_str assessment.reason "$2"; shift 2 ;;
    --assessment-reported-status) need_value "$1" "$#"; add_str assessment.reportedStatus "$2"; shift 2 ;;
    --assessment-verified-status) need_value "$1" "$#"; add_str assessment.verifiedStatus "$2"; shift 2 ;;
    --assessment-confidence) need_value "$1" "$#"; add_num assessment.confidence "$2"; shift 2 ;;

    --metadata)
      need_value "$1" "$#"
      case "$2" in
        *=*)
          add_str "metadata.${2%%=*}" "${2#*=}"
          ;;
        *)
          at_die "--metadata expects KEY=VALUE"
          ;;
      esac
      shift 2
      ;;

    --) shift; break ;;
    -*) at_die "unknown option '$1' (run --help for the flag list)" ;;
    *) at_die "unexpected argument '$1'" ;;
  esac
done

at_load_config
at_require_deps || exit 1
at_ensure_session

# ---------------------------------------------------------------------------
# Build the payload
# ---------------------------------------------------------------------------

BASE_FILE="$(at_mktemp)"
printf '{}\n' > "$BASE_FILE"

read_json_source() {
  local source="$1"
  local target="$2"
  if [ "$source" = "-" ]; then
    cat > "$target"
  elif [ -r "$source" ]; then
    # -r rather than -f, so process substitution and named pipes work too.
    cat "$source" > "$target"
  else
    at_die "JSON source '$source' cannot be read"
  fi
  if [ ! -s "$target" ]; then
    printf '{}\n' > "$target"
  fi
  if ! at_json_valid "$target"; then
    at_die "JSON source '$source' is not valid JSON"
  fi
}

if [ -n "$BASE_JSON_SOURCE" ]; then
  read_json_source "$BASE_JSON_SOURCE" "$BASE_FILE"
elif [ -z "$EVENT_TYPE" ] && [ ! -t 0 ]; then
  # No flags at all: the whole payload is expected on stdin.
  read_json_source "-" "$BASE_FILE"
fi

if [ -n "$ROADMAP_JSON_SOURCE" ]; then
  ROADMAP_FILE="$(at_mktemp)"
  read_json_source "$ROADMAP_JSON_SOURCE" "$ROADMAP_FILE"
  add_set json roadmap "$(at_json_compact "$ROADMAP_FILE")"
fi

if [ -n "$EVENT_TYPE" ]; then
  add_str type "$EVENT_TYPE"
fi

EVENT_FILE="$(at_mktemp)"
cp "$BASE_FILE" "$EVENT_FILE"

INDEX=0
COUNT="${#SET_PATHS[@]}"
while [ "$INDEX" -lt "$COUNT" ]; do
  at_json_set "$EVENT_FILE" "${SET_KINDS[$INDEX]}" "${SET_PATHS[$INDEX]}" "${SET_VALUES[$INDEX]}"
  INDEX=$(( INDEX + 1 ))
done

# ---------------------------------------------------------------------------
# Envelope defaults - only filled in when the caller did not supply them
# ---------------------------------------------------------------------------

fill_default_str() {
  local path="$1"
  local value="$2"
  [ -n "$value" ] || return 0
  local current
  current="$(at_json_get "$EVENT_FILE" "$path")"
  if [ -z "$current" ]; then
    at_json_set "$EVENT_FILE" str "$path" "$value"
  fi
}

fill_default_num() {
  local path="$1"
  local value="$2"
  local current
  current="$(at_json_get "$EVENT_FILE" "$path")"
  if [ -z "$current" ]; then
    at_json_set "$EVENT_FILE" num "$path" "$value"
  fi
}

EVENT_ID="$(at_json_get "$EVENT_FILE" 'eventId')"
if [ -z "$EVENT_ID" ]; then
  EVENT_ID="$(at_new_event_id)"
  at_json_set "$EVENT_FILE" str eventId "$EVENT_ID"
fi

fill_default_str sessionId "$AT_SESSION_ID"
if [ -n "$AT_PROJECT_ID" ]; then
  fill_default_str projectId "$AT_PROJECT_ID"
fi
fill_default_str protocolVersion "$(at_protocol_version)"
fill_default_str timestamp "$(at_now)"
fill_default_num sequence "$(at_next_sequence)"

fill_default_str reporter.agentId "${AGENTMAGNIFY_AGENT_ID:-main-agent}"
fill_default_str reporter.kind "${AGENTMAGNIFY_AGENT_KIND:-logical}"
if [ -n "${AGENTMAGNIFY_AGENT_ROLE:-}" ]; then
  fill_default_str reporter.role "$AGENTMAGNIFY_AGENT_ROLE"
fi
if [ -n "${AGENTMAGNIFY_EXECUTOR_ID:-}" ]; then
  fill_default_str reporter.executorId "$AGENTMAGNIFY_EXECUTOR_ID"
fi

EVENT_TYPE="$(at_json_get "$EVENT_FILE" 'type')"

# agent.* events always need an agent object. When the reporter is talking
# about itself - the common case - derive it from the reporter identity.
case "$EVENT_TYPE" in
  agent.*)
    if [ -z "$(at_json_get "$EVENT_FILE" 'agent.id')" ]; then
      at_json_set "$EVENT_FILE" str agent.id "$(at_json_get "$EVENT_FILE" 'reporter.agentId')"
      REPORTER_ROLE="$(at_json_get "$EVENT_FILE" 'reporter.role')"
      if [ -n "$REPORTER_ROLE" ]; then
        fill_default_str agent.role "$REPORTER_ROLE"
      fi
      fill_default_str agent.kind "$(at_json_get "$EVENT_FILE" 'reporter.kind')"
    fi
    ;;
esac

# ---------------------------------------------------------------------------
# Secret filter, then validation, then send (doc 24.5, doc 14.1)
# ---------------------------------------------------------------------------

at_redact_json_file "$EVENT_FILE"

if ! at_json_is_safe "$EVENT_FILE"; then
  at_error "event still trips the secret filter after redaction; refusing to send"
  # Kind `local`: this one never left the machine and never may, whatever
  # happens to the credential later.
  at_dead_letter_event "$EVENT_FILE" "local secret filter could not clean the payload" local
  exit 1
fi

if ! at_validate_event_file "$EVENT_FILE"; then
  at_error "event failed local validation and was not sent (fix the fields and report again)"
  exit 1
fi

if [ "$DRY_RUN" = "1" ]; then
  at_json_compact "$EVENT_FILE"
  at_info "dry run: event $EVENT_ID is valid and was not sent"
  exit 0
fi

if [ "$PRINT_EVENT" = "1" ]; then
  at_json_compact "$EVENT_FILE"
fi

if ! at_have_token; then
  at_warn "AGENTMAGNIFY_TOKEN is not set; queueing event $EVENT_TYPE locally"
  at_queue_event "$EVENT_FILE"
  printf '%s queued\n' "$EVENT_ID"
  exit 0
fi

RESPONSE_FILE="$(at_mktemp)"
STATUS="$(at_http_request POST /v1/events "$EVENT_FILE" "$RESPONSE_FILE" "$EVENT_ID")"

if at_status_is_success "$STATUS"; then
  DUPLICATE="$(at_json_get "$RESPONSE_FILE" 'duplicate')"
  if [ "$DUPLICATE" = "true" ]; then
    at_debug "event $EVENT_ID was already recorded (idempotent replay)"
    printf '%s duplicate\n' "$EVENT_ID"
  else
    at_debug "event $EVENT_ID accepted ($EVENT_TYPE)"
    printf '%s accepted\n' "$EVENT_ID"
  fi
  exit 0
fi

if at_status_is_permanent_failure "$STATUS"; then
  REASON="HTTP $STATUS $(at_error_message "$RESPONSE_FILE")"
  KIND="$(at_dead_letter_kind_for_status "$STATUS")"

  # A dead credential and a bad payload both end here, and the two need
  # different sentences. "The API rejected your event" sends somebody looking
  # at the event; the event is fine, and the fix is a new token.
  if [ "$KIND" = "credential" ]; then
    at_error "the monitoring credential was not accepted (HTTP $STATUS): $REASON"
    at_error "the token is expired, revoked, or scoped to another project; reporting is off until that is fixed"
    at_error "run: bash scripts/pair.sh   (then this event and everything after it is sent automatically)"
    at_error "event $EVENT_ID is held in state/dead-letter.jsonl, not lost"
  else
    at_error "API rejected event $EVENT_ID permanently: $REASON"
  fi

  at_dead_letter_event "$EVENT_FILE" "$REASON" "$KIND"
  printf '%s dead-letter\n' "$EVENT_ID"
  exit 0
fi

at_warn "API unreachable or failing (HTTP $STATUS); event $EVENT_ID queued locally"
at_queue_event "$EVENT_FILE"
printf '%s queued\n' "$EVENT_ID"
exit 0
