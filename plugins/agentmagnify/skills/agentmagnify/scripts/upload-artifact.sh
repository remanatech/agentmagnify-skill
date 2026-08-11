#!/usr/bin/env bash
#
# upload-artifact.sh - put a file (a screenshot, a test report, a log) behind
# the panel, and report the artifact that points at it.
#
# Three requests, none of which move bytes through the monitoring API:
#
#   1. ask the API for an upload -- quota and type are checked here, before
#      anything is transferred
#   2. PUT the file straight at the object store, on the presigned URL the
#      API answered with
#   3. complete the upload, so the API confirms what actually arrived
#
# Then (unless --no-event) an artifact.created event is reported with the
# durable URL, exactly as if the artifact were an external link -- because to
# the event record, it is one. Evidence for a claim wants the artifact id:
#
#   bash upload-artifact.sh shot.png --kind screenshot --artifact-id shot-1
#   bash report-event.sh --type task.completed ... --evidence-artifact-id shot-1
#
# Failure here is NOT queued, unlike events: bytes cannot sit in a jsonl file
# waiting for the network, and evidence delivered tomorrow proves nothing
# about today. On any failure this prints one line and exits 1 -- report the
# artifact without a URL, or move on. Never block real work on an upload.
#
# A run's visual story: pass --test-run-id (and optionally --step and
# --step-status) to attach the file to a test run as one step of its flow.
# The tests screen renders a run's attached screenshots as an ordered,
# pass/fail-badged strip -- one screenshot per meaningful step.
#
# Usage: upload-artifact.sh FILE [--name NAME] [--kind KIND]
#          [--content-type TYPE] [--artifact-id ID] [--agent-id ID]
#          [--test-run-id ID] [--step N] [--step-status passed|failed]
#          [--summary TEXT] [--no-event]

set -euo pipefail

# shellcheck source=./lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'USAGE'
Usage: upload-artifact.sh FILE [options]

  --name NAME          display name in the panel (default: the file's name)
  --kind KIND          screenshot | report | log | file (default: guessed
                       from the content type)
  --content-type TYPE  explicit MIME type; otherwise inferred from the
                       extension. Only evidence types are accepted:
                       png/jpeg/webp/gif/svg images, text, csv, json, xml,
                       pdf, zip, gzip. Never HTML, never executables.
  --artifact-id ID     external id for the artifact.created event, so a later
                       event can cite it as --evidence-artifact-id
  --test-run-id ID     attach this file to a test run (the --test-id you
                       reported) as one step of its visual flow
  --step N             position in that flow; without it, arrival order
  --step-status passed|failed
                       what this step showed
  --agent-id ID        who is reporting (default: resolved as report-event.sh)
  --summary TEXT       event summary (default: "Uploaded NAME")
  --no-event           upload only; report nothing

Uploads count against the workspace plan's storage allowance and are capped
at 25 MiB per file. Anything larger belongs in a registry or a release page,
reported with --artifact-url as an external link.
USAGE
}

FILE=""
NAME=""
KIND=""
CONTENT_TYPE=""
ARTIFACT_ID=""
AGENT_ID=""
SUMMARY=""
TEST_RUN_ID=""
STEP=""
STEP_STATUS=""
SEND_EVENT=1

while [ "$#" -gt 0 ]; do
  case "$1" in
    --name) [ "$#" -ge 2 ] || at_die "--name requires a value"; NAME="$2"; shift 2 ;;
    --kind) [ "$#" -ge 2 ] || at_die "--kind requires a value"; KIND="$2"; shift 2 ;;
    --content-type) [ "$#" -ge 2 ] || at_die "--content-type requires a value"; CONTENT_TYPE="$2"; shift 2 ;;
    --artifact-id) [ "$#" -ge 2 ] || at_die "--artifact-id requires a value"; ARTIFACT_ID="$2"; shift 2 ;;
    --test-run-id) [ "$#" -ge 2 ] || at_die "--test-run-id requires a value"; TEST_RUN_ID="$2"; shift 2 ;;
    --step) [ "$#" -ge 2 ] || at_die "--step requires a value"; STEP="$2"; shift 2 ;;
    --step-status) [ "$#" -ge 2 ] || at_die "--step-status requires a value"; STEP_STATUS="$2"; shift 2 ;;
    --agent-id) [ "$#" -ge 2 ] || at_die "--agent-id requires a value"; AGENT_ID="$2"; shift 2 ;;
    --summary) [ "$#" -ge 2 ] || at_die "--summary requires a value"; SUMMARY="$2"; shift 2 ;;
    --no-event) SEND_EVENT=0; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) at_die "unknown option: $1" ;;
    *) [ -z "$FILE" ] || at_die "only one file per upload"; FILE="$1"; shift ;;
  esac
done

[ -n "$FILE" ] || { usage; exit 1; }
[ -f "$FILE" ] || at_die "no such file: $FILE"

if [ -n "$STEP" ]; then
  case "$STEP" in
    *[!0-9]*) at_die "--step takes a whole number" ;;
  esac
fi
if [ -n "$STEP_STATUS" ] && [ "$STEP_STATUS" != "passed" ] && [ "$STEP_STATUS" != "failed" ]; then
  at_die "--step-status is passed or failed"
fi

at_load_config || exit 1
at_require_deps || exit 1

# The extension decides only when the caller did not. The server holds the
# real allowlist; this map exists so the ordinary case needs no flag.
if [ -z "$CONTENT_TYPE" ]; then
  case "$(printf '%s' "$FILE" | tr '[:upper:]' '[:lower:]')" in
    *.png) CONTENT_TYPE="image/png" ;;
    *.jpg|*.jpeg) CONTENT_TYPE="image/jpeg" ;;
    *.webp) CONTENT_TYPE="image/webp" ;;
    *.gif) CONTENT_TYPE="image/gif" ;;
    *.svg) CONTENT_TYPE="image/svg+xml" ;;
    *.txt|*.log) CONTENT_TYPE="text/plain" ;;
    *.csv) CONTENT_TYPE="text/csv" ;;
    *.json) CONTENT_TYPE="application/json" ;;
    *.xml) CONTENT_TYPE="application/xml" ;;
    *.pdf) CONTENT_TYPE="application/pdf" ;;
    *.zip) CONTENT_TYPE="application/zip" ;;
    *.gz|*.tgz) CONTENT_TYPE="application/gzip" ;;
    *) at_die "cannot infer a content type for '$FILE'; pass --content-type" ;;
  esac
fi

SIZE_BYTES="$(wc -c < "$FILE" | tr -d '[:space:]')"
[ "$SIZE_BYTES" -gt 0 ] 2>/dev/null || at_die "refusing to upload an empty file"

BASENAME="$(basename "$FILE")"
[ -n "$NAME" ] || NAME="$BASENAME"

if [ -z "$KIND" ]; then
  case "$CONTENT_TYPE" in
    image/*) KIND="screenshot" ;;
    text/plain) KIND="log" ;;
    application/json|application/xml|text/xml|text/csv) KIND="report" ;;
    *) KIND="file" ;;
  esac
fi

# The project, from the session when there is one. A project token needs
# nothing; a workspace token needs the id the handshake resolved.
PROJECT_ID=""
if at_load_session 2>/dev/null; then
  PROJECT_ID="$(at_json_get "$AT_SESSION_FILE" 'projectId')"
fi

request_file="$(at_mktemp)"
response_file="$(at_mktemp)"

{
  printf '{'
  [ -n "$PROJECT_ID" ] && printf '"projectId":%s,' "$(at_json_quote "$PROJECT_ID")"
  printf '"fileName":%s,' "$(at_json_quote "$BASENAME")"
  printf '"contentType":%s,' "$(at_json_quote "$CONTENT_TYPE")"
  printf '"kind":%s,' "$(at_json_quote "$KIND")"
  printf '"sizeBytes":%s' "$SIZE_BYTES"
  printf '}'
} > "$request_file"

status="$(at_http_request POST "/v1/artifacts/uploads" "$request_file" "$response_file")"

if ! at_status_is_success "$status"; then
  case "$status" in
    000) at_error "could not reach the monitoring API; the file was not uploaded" ;;
    402) at_error "upload refused: $(at_error_message "$response_file")" ;;
    501) at_error "this deployment has no object storage; report the artifact as a URL instead" ;;
    *) at_error "could not start the upload ($status): $(at_error_message "$response_file")" ;;
  esac
  exit 1
fi

UPLOAD_ID="$(at_json_get "$response_file" 'uploadId')"
PUT_URL="$(at_json_get "$response_file" 'url')"
ARTIFACT_URL="$(at_json_get "$response_file" 'artifactUrl')"
[ -n "$UPLOAD_ID" ] && [ -n "$PUT_URL" ] || at_die "the API did not return an upload"

# The bytes, straight at the store. The URL is presigned for exactly this
# content type and length; curl reads the file from disk rather than argv, so
# nothing about it lands in a process listing.
put_status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --max-time "${AGENTMAGNIFY_TIMEOUT_SECONDS:-30}" \
  --upload-file "$FILE" \
  --header "Content-Type: $CONTENT_TYPE" \
  --request PUT "$PUT_URL" 2>/dev/null || printf '000')"

if ! at_status_is_success "$put_status"; then
  at_error "the object store refused the file ($put_status); nothing was recorded"
  exit 1
fi

complete_file="$(at_mktemp)"
empty_body="$(at_mktemp)"
printf '{}' > "$empty_body"

status="$(at_http_request POST "/v1/artifacts/uploads/$UPLOAD_ID/complete" "$empty_body" "$complete_file")"

if ! at_status_is_success "$status"; then
  at_error "could not confirm the upload ($status): $(at_error_message "$complete_file")"
  exit 1
fi

at_info "uploaded $NAME ($SIZE_BYTES bytes) -> $ARTIFACT_URL"

if [ "$SEND_EVENT" = "1" ]; then
  [ -n "$ARTIFACT_ID" ] || ARTIFACT_ID="upload-$UPLOAD_ID"
  [ -n "$SUMMARY" ] || SUMMARY="Uploaded $NAME"

  set -- --type artifact.created \
    --summary "$SUMMARY" \
    --artifact-id "$ARTIFACT_ID" \
    --artifact-name "$NAME" \
    --artifact-kind "$KIND" \
    --artifact-url "$ARTIFACT_URL" \
    --artifact-size-bytes "$SIZE_BYTES"
  [ -n "$AGENT_ID" ] && set -- "$@" --agent-id "$AGENT_ID"
  [ -n "$TEST_RUN_ID" ] && set -- "$@" --evidence-test-run-id "$TEST_RUN_ID"
  [ -n "$STEP" ] && set -- "$@" --metadata "step=$STEP"
  [ -n "$STEP_STATUS" ] && set -- "$@" --metadata "stepStatus=$STEP_STATUS"

  # The event goes through the ordinary path, queue and all: the bytes are
  # safe in the store, so the record of them may arrive late like any event.
  bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/report-event.sh" "$@" || true
fi
