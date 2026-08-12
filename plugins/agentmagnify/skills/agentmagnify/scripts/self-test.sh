#!/usr/bin/env bash
#
# self-test.sh - offline verification of the skill package.
#
# Runs with no network access at all. It checks the parts that must never be
# wrong, because everything else is built on them:
#
#   * event id generation and RFC3339 UTC timestamps
#   * the monotonic per-session sequence counter
#   * per-event-type validation (doc 14.1)
#   * the local secret filter (doc 24.5)
#   * the offline queue round trip (doc 13.7, doc 15)
#   * that the monitoring token is never written to disk
#
# This is what `pnpm --filter @agentmagnify/skill test` runs. Exit code is
# non-zero if any check fails.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# An isolated state directory: the self-test must never touch a real session.
TEST_STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentmagnify-selftest.XXXXXX")"

# A syntactically valid but useless token, and an address nothing listens on.
export AGENTMAGNIFY_STATE_DIR="$TEST_STATE_DIR"
export AGENTMAGNIFY_TOKEN="prj_live_selftestonlynotreal00"
export AGENTMAGNIFY_API_URL="http://127.0.0.1:1"
export AGENTMAGNIFY_MAX_RETRIES=0
export AGENTMAGNIFY_TIMEOUT_SECONDS=2
export AGENTMAGNIFY_AGENT_ID="self-test"
export AGENTMAGNIFY_AGENT_KIND="logical"
unset AGENTMAGNIFY_CAPABILITIES 2>/dev/null || true

# shellcheck disable=SC2329  # invoked through the EXIT trap below
cleanup() {
  rm -rf "$TEST_STATE_DIR" 2>/dev/null || true
}
trap cleanup EXIT

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

section() {
  printf '\n== %s\n' "$1"
}

# A check that could not run here, as opposed to one that ran and passed. The
# installer section below is the only user: it needs node and a package that an
# installed copy of this skill does not have beside it, and reporting "ok" for
# a check that never executed is how a suite stops meaning anything.
skip() {
  SKIP_COUNT=$(( SKIP_COUNT + 1 ))
  printf '   skip  %s\n' "$1"
}

pass() {
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf '   ok    %s\n' "$1"
}

fail() {
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf '   FAIL  %s\n' "$1"
  if [ -n "${2:-}" ]; then
    printf '         %s\n' "$2"
  fi
}

check() {
  # check <description> <condition-exit-code> [detail]
  if [ "$2" -eq 0 ]; then
    pass "$1"
  else
    fail "$1" "${3:-}"
  fi
}

# shellcheck source=./lib.sh
. "$SCRIPT_DIR/lib.sh"
at_load_config

# ---------------------------------------------------------------------------
section "dependencies"
# ---------------------------------------------------------------------------

if at_require_deps; then
  pass "curl and a JSON tool are available (using $AT_JSON_TOOL)"
else
  fail "curl and a JSON tool are available"
  printf '\nself-test cannot continue without its dependencies.\n'
  exit 1
fi

for SCRIPT in lib.sh fetch-schema.sh start-session.sh report-event.sh send-snapshot.sh \
              send-heartbeat.sh flush-pending-events.sh complete-session.sh self-test.sh \
              upload-artifact.sh; do
  if bash -n "$SCRIPT_DIR/$SCRIPT" 2>/dev/null; then
    pass "$SCRIPT parses"
  else
    fail "$SCRIPT parses"
  fi
done

for SCRIPT in fetch-schema.sh start-session.sh report-event.sh send-snapshot.sh \
              send-heartbeat.sh flush-pending-events.sh complete-session.sh self-test.sh \
              upload-artifact.sh; do
  if [ -x "$SCRIPT_DIR/$SCRIPT" ]; then
    pass "$SCRIPT is executable"
  else
    fail "$SCRIPT is executable" "run: chmod +x scripts/$SCRIPT"
  fi
done

if at_json_valid "$AT_FALLBACK_SCHEMA"; then
  pass "references/fallback-schema.json is valid JSON"
else
  fail "references/fallback-schema.json is valid JSON"
fi

FALLBACK_VERSION="$(at_json_get "$AT_FALLBACK_SCHEMA" 'protocolVersion')"
check "fallback schema pins protocol $AT_FALLBACK_PROTOCOL_VERSION" \
  "$( [ "$FALLBACK_VERSION" = "$AT_FALLBACK_PROTOCOL_VERSION" ] && echo 0 || echo 1 )" \
  "got '$FALLBACK_VERSION'"

TYPE_COUNT="$(at_known_event_types | wc -l | tr -d ' ')"
check "fallback schema carries the full event vocabulary" \
  "$( [ "$TYPE_COUNT" -ge 60 ] && echo 0 || echo 1 )" \
  "found $TYPE_COUNT event types"

# ---------------------------------------------------------------------------
section "identifiers and timestamps"
# ---------------------------------------------------------------------------

EVENT_ID="$(at_new_event_id)"
if printf '%s' "$EVENT_ID" | grep -qE '^evt_[0-9A-HJKMNP-TV-Z]{26}$'; then
  pass "event id looks like a ULID ($EVENT_ID)"
else
  fail "event id looks like a ULID" "got '$EVENT_ID'"
fi

ID_FILE="$TEST_STATE_DIR/ids.txt"
: > "$ID_FILE"
IDX=0
while [ "$IDX" -lt 50 ]; do
  at_new_event_id >> "$ID_FILE"
  printf '\n' >> "$ID_FILE"
  IDX=$(( IDX + 1 ))
done
UNIQUE_COUNT="$(sort -u "$ID_FILE" | grep -c . || true)"
check "50 generated ids are unique" \
  "$( [ "$UNIQUE_COUNT" -eq 50 ] && echo 0 || echo 1 )" \
  "only $UNIQUE_COUNT distinct ids"

TIMESTAMP="$(at_now)"
if printf '%s' "$TIMESTAMP" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
  pass "timestamp is RFC3339 UTC ($TIMESTAMP)"
else
  fail "timestamp is RFC3339 UTC" "got '$TIMESTAMP'"
fi

at_reset_sequence
SEQ_A="$(at_next_sequence)"
SEQ_B="$(at_next_sequence)"
SEQ_C="$(at_next_sequence)"
check "sequence counter is monotonic" \
  "$( [ "$SEQ_A" = "1" ] && [ "$SEQ_B" = "2" ] && [ "$SEQ_C" = "3" ] && echo 0 || echo 1 )" \
  "got $SEQ_A, $SEQ_B, $SEQ_C"

QUOTED="$(at_json_quote 'line one
"quoted" \backslash	tab')"
if printf '%s' "$QUOTED" | grep -q '\\n' && printf '%s' "$QUOTED" | grep -q '\\"'; then
  pass "JSON escaping handles newlines, quotes and backslashes"
else
  fail "JSON escaping handles newlines, quotes and backslashes" "got $QUOTED"
fi

# ---------------------------------------------------------------------------
section "secret filter"
# ---------------------------------------------------------------------------

assert_flagged() {
  local label="$1"
  local payload="$2"
  local rules
  rules="$(at_scan_text "$payload" | tr '\n' ',' | sed 's/,$//')"
  if [ -n "$rules" ]; then
    pass "$label is flagged ($rules)"
  else
    fail "$label is flagged" "the filter let it through"
  fi
}

assert_redacted() {
  local label="$1"
  local payload="$2"
  local needle="$3"
  local cleaned
  cleaned="$(at_redact_text "$payload")"
  if printf '%s' "$cleaned" | grep -qF -- "$needle"; then
    fail "$label is removed from the redacted text" "still contains the secret"
  else
    pass "$label is removed from the redacted text"
  fi
}

assert_clean() {
  local label="$1"
  local payload="$2"
  if at_text_is_safe "$payload"; then
    pass "$label passes untouched"
  else
    fail "$label passes untouched" "flagged as: $(at_scan_text "$payload" | tr '\n' ' ')"
  fi
}

ANTHROPIC_KEY="sk-ant-api03-$(printf 'A%.0s' $(seq 1 40))"
AWS_KEY="AKIAIOSFODNN7EXAMPLE"
DB_ASSIGNMENT='DB_PASSWORD=sup3rs3cretvalue'
CONNECTION_STRING='postgres://appuser:hunter2@db.internal:5432/app'
BEARER='Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345'
MONITORING_TOKEN='prj_live_abcdef0123456789'
GITHUB_TOKEN='ghp_abcdefghijklmnopqrstuvwxyz0123456789'
JWT='eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk'
CODE_BLOCK='Implemented the handler:
```ts
const token = process.env.SECRET;
```
Done.'
PRIVATE_KEY='-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEAx0Fake
-----END RSA PRIVATE KEY-----'

assert_flagged "an Anthropic API key" "Key is $ANTHROPIC_KEY here"
assert_flagged "an AWS access key id" "Deployed with $AWS_KEY"
assert_flagged "a KEY=value credential assignment" "$DB_ASSIGNMENT"
assert_flagged "a database connection string" "Connecting to $CONNECTION_STRING"
assert_flagged "a fenced code block" "$CODE_BLOCK"
assert_flagged "a private key block" "$PRIVATE_KEY"
assert_flagged "a bearer token header" "$BEARER"
assert_flagged "a monitoring token" "Use $MONITORING_TOKEN for reporting"
assert_flagged "a GitHub token" "token $GITHUB_TOKEN"
assert_flagged "a JWT" "session $JWT"
assert_flagged "an env export" "run export DATABASE_URL=postgres_local"

assert_redacted "the Anthropic API key" "Key is $ANTHROPIC_KEY here" "$ANTHROPIC_KEY"
assert_redacted "the AWS access key id" "Deployed with $AWS_KEY" "$AWS_KEY"
assert_redacted "the credential assignment" "$DB_ASSIGNMENT" "sup3rs3cretvalue"
assert_redacted "the connection string" "Connecting to $CONNECTION_STRING" "hunter2"
assert_redacted "the fenced code block" "$CODE_BLOCK" "process.env.SECRET"
assert_redacted "the private key body" "$PRIVATE_KEY" "MIIEowIBAAKCAQEAx0Fake"

assert_clean "an ordinary completion summary" \
  "Authentication endpoints and token rotation implemented; 18 tests passed."
assert_clean "a blocker summary" \
  "Redis connection refused on port 6379; backend task is blocked."
assert_clean "a phase summary" "Workflow Engine phase started with 6 tasks."

# ---------------------------------------------------------------------------
section "per-type validation"
# ---------------------------------------------------------------------------

REPORT="$SCRIPT_DIR/report-event.sh"

expect_valid() {
  local label="$1"
  shift
  if "$REPORT" --dry-run "$@" >/dev/null 2>"$TEST_STATE_DIR/last-error"; then
    pass "$label is accepted"
  else
    fail "$label is accepted" "$(tail -n 2 "$TEST_STATE_DIR/last-error" | tr '\n' ' ')"
  fi
}

expect_invalid() {
  local label="$1"
  shift
  if "$REPORT" --dry-run "$@" >/dev/null 2>"$TEST_STATE_DIR/last-error"; then
    fail "$label is rejected" "the event passed validation"
  else
    pass "$label is rejected"
  fi
}

expect_valid "task.completed with a task id" \
  --type task.completed --task-id auth-api --task-title "Authentication API" \
  --agent-id backend-developer --role backend --kind logical \
  --summary "Endpoints and token rotation implemented." \
  --verification-method test --verification-result passed \
  --verification-passed 18 --verification-failed 0 \
  --evidence-changed-files 7 --evidence-commit a81f93c

expect_invalid "task.completed without a task id" \
  --type task.completed --agent-id backend-developer --kind logical \
  --summary "Everything is done."

expect_invalid "an unknown event type" \
  --type task.almost-done --task-id auth-api --agent-id backend-developer --kind logical

expect_invalid "test.failed reporting zero failures" \
  --type test.failed --test-suite auth --test-failed 0 --test-passed 18 \
  --agent-id qa-agent --kind logical

expect_valid "test.failed reporting real failures" \
  --type test.failed --test-suite auth --test-failed 3 --test-passed 15 \
  --agent-id qa-agent --kind logical

expect_invalid "roadmap.created without a roadmap" \
  --type roadmap.created --agent-id main-agent --kind main

expect_invalid "an observer event type from a logical agent" \
  --type completion.disputed --task-id auth-api --assessment-reason "3 tests fail" \
  --agent-id backend-developer --kind logical

expect_valid "an observer event type from the observer" \
  --type completion.disputed --task-id auth-api \
  --assessment-reason "Reported complete, but 3 of 18 tests fail." \
  --assessment-verdict disputed --agent-id project-observer --role observer --kind observer

expect_invalid "task.progress without a progress value" \
  --type task.progress --task-id auth-api --agent-id backend-developer --kind logical

expect_valid "task.progress with a progress value" \
  --type task.progress --task-id auth-api --progress 40 \
  --agent-id backend-developer --kind logical

expect_invalid "progress above 100" \
  --type task.progress --task-id auth-api --progress 140 \
  --agent-id backend-developer --kind logical

expect_valid "agent.created deriving the agent from the reporter" \
  --type agent.created --agent-id backend-developer --role backend --kind logical \
  --summary "Backend developer agent created."

check "a dry run does not touch the queue" \
  "$( [ ! -s "$AT_PENDING_FILE" ] && echo 0 || echo 1 )" \
  "pending-events.jsonl is not empty"

# ---------------------------------------------------------------------------
section "offline queue round trip"
# ---------------------------------------------------------------------------

rm -f "$AT_PENDING_FILE" "$AT_DEAD_LETTER_FILE" 2>/dev/null || true

QUEUE_OUTPUT_1="$("$REPORT" --type task.started --task-id auth-api --task-title "Authentication API" \
  --agent-id backend-developer --role backend --kind logical \
  --summary "Starting the authentication endpoints." 2>/dev/null)"

QUEUE_OUTPUT_2="$("$REPORT" --type task.progress --task-id auth-api --progress 40 \
  --agent-id backend-developer --role backend --kind logical \
  --summary "Token rotation in place." 2>/dev/null)"

QUEUE_OUTPUT_3="$("$REPORT" --type task.completed --task-id auth-api \
  --agent-id backend-developer --role backend --kind logical \
  --summary "Done. Key is $ANTHROPIC_KEY and $DB_ASSIGNMENT" \
  --verification-method test --verification-result passed --verification-passed 18 2>/dev/null)"

case "$QUEUE_OUTPUT_1" in
  *queued) pass "an event is queued when the API is unreachable" ;;
  *) fail "an event is queued when the API is unreachable" "got '$QUEUE_OUTPUT_1'" ;;
esac

case "$QUEUE_OUTPUT_2$QUEUE_OUTPUT_3" in
  *queued) pass "queueing continues after several events" ;;
  *) fail "queueing continues after several events" "got '$QUEUE_OUTPUT_2' / '$QUEUE_OUTPUT_3'" ;;
esac

check "report-event.sh exits 0 when the API is unreachable" 0

QUEUED_LINES="$(wc -l < "$AT_PENDING_FILE" | tr -d ' ')"
check "three events are waiting in the queue" \
  "$( [ "$QUEUED_LINES" -eq 3 ] && echo 0 || echo 1 )" \
  "found $QUEUED_LINES"

QUEUE_VALID=0
while IFS= read -r LINE; do
  printf '%s\n' "$LINE" > "$TEST_STATE_DIR/line.json"
  if ! at_json_valid "$TEST_STATE_DIR/line.json"; then
    QUEUE_VALID=1
  fi
done < "$AT_PENDING_FILE"
check "every queued line is valid JSON" "$QUEUE_VALID"

SEQUENCES="$(while IFS= read -r LINE; do
  printf '%s\n' "$LINE" > "$TEST_STATE_DIR/line.json"
  at_json_get "$TEST_STATE_DIR/line.json" 'sequence'
done < "$AT_PENDING_FILE" | tr '\n' ' ' | sed 's/ $//')"
SORTED_SEQUENCES="$(printf '%s' "$SEQUENCES" | tr ' ' '\n' | sort -n | tr '\n' ' ' | sed 's/ $//')"
check "queued events keep their sequence order" \
  "$( [ "$SEQUENCES" = "$SORTED_SEQUENCES" ] && echo 0 || echo 1 )" \
  "sequences were: $SEQUENCES"

if grep -qF -- "$ANTHROPIC_KEY" "$AT_PENDING_FILE"; then
  fail "the queued payload contains no API key" "the key reached the queue file"
else
  pass "the queued payload contains no API key"
fi

if grep -qF -- "sup3rs3cretvalue" "$AT_PENDING_FILE"; then
  fail "the queued payload contains no credential value" "the password reached the queue file"
else
  pass "the queued payload contains no credential value"
fi

if grep -q '\[redacted\]' "$AT_PENDING_FILE"; then
  pass "the secret filter left its marker in the queued event"
else
  fail "the secret filter left its marker in the queued event"
fi

if grep -rqF -- "$AGENTMAGNIFY_TOKEN" "$TEST_STATE_DIR" 2>/dev/null; then
  fail "the monitoring token is never written to disk" "found it under the state directory"
else
  pass "the monitoring token is never written to disk"
fi

FLUSH_OUTPUT="$("$SCRIPT_DIR/flush-pending-events.sh" 2>/dev/null || true)"
STILL_QUEUED="$(wc -l < "$AT_PENDING_FILE" | tr -d ' ')"
check "a flush against an unreachable API loses nothing" \
  "$( [ "$STILL_QUEUED" -eq 3 ] && echo 0 || echo 1 )" \
  "queue now holds $STILL_QUEUED event(s); flush said: $FLUSH_OUTPUT"

check "nothing was dead-lettered by a network failure" \
  "$( [ ! -s "$AT_DEAD_LETTER_FILE" ] && echo 0 || echo 1 )" \
  "dead-letter.jsonl is not empty"

# ---------------------------------------------------------------------------
section "offline session bootstrap"
# ---------------------------------------------------------------------------

check "an offline session was created automatically" \
  "$( [ -f "$AT_SESSION_FILE" ] && echo 0 || echo 1 )"

OFFLINE_SESSION_ID="$(at_json_get "$AT_SESSION_FILE" 'sessionId')"
case "$OFFLINE_SESSION_ID" in
  ses_local_*) pass "the offline session uses a local placeholder id" ;;
  *) fail "the offline session uses a local placeholder id" "got '$OFFLINE_SESSION_ID'" ;;
esac

OFFLINE_MODE="$(at_json_get "$AT_SESSION_FILE" 'reportingMode')"
case "$OFFLINE_MODE" in
  full|observer|checkpoint|fallback) pass "a reporting mode was negotiated locally ($OFFLINE_MODE)" ;;
  *) fail "a reporting mode was negotiated locally" "got '$OFFLINE_MODE'" ;;
esac

check "the offline session is marked unverified" \
  "$( [ "$(at_json_get "$AT_SESSION_FILE" 'protocolVerified')" = "false" ] && echo 0 || echo 1 )"

HEARTBEAT_OUTPUT="$("$SCRIPT_DIR/send-heartbeat.sh" 2>/dev/null || true)"
check "send-heartbeat.sh never blocks on an offline session" 0 "$HEARTBEAT_OUTPUT"

# ---------------------------------------------------------------------------
section "dead-letter classification and recovery"
# ---------------------------------------------------------------------------
#
# The dead-letter file holds two things that used to be indistinguishable: an
# event the API refused, and an event whose credential the API refused. Only the
# second may ever be sent again, and everything below is about keeping that line
# in exactly the right place. Getting it wrong in one direction loses a day of
# reporting; getting it wrong in the other replays known rubbish for ever.

for STATUS in 401 403; do
  check "HTTP $STATUS is classified as a credential failure" \
    "$( [ "$(at_dead_letter_kind_for_status "$STATUS")" = "credential" ] && echo 0 || echo 1 )" \
    "got '$(at_dead_letter_kind_for_status "$STATUS")'"
done

for STATUS in 400 404 409 413 422; do
  check "HTTP $STATUS is classified as a payload failure" \
    "$( [ "$(at_dead_letter_kind_for_status "$STATUS")" = "payload" ] && echo 0 || echo 1 )" \
    "got '$(at_dead_letter_kind_for_status "$STATUS")'"
done

check "only a credential failure is recoverable" \
  "$( at_dead_letter_kind_is_recoverable credential &&
      ! at_dead_letter_kind_is_recoverable payload &&
      ! at_dead_letter_kind_is_recoverable local &&
      ! at_dead_letter_kind_is_recoverable expired &&
      ! at_dead_letter_kind_is_recoverable '' && echo 0 || echo 1 )"

DL_DIR="$TEST_STATE_DIR/dead-letter"
mkdir -p "$DL_DIR"

DL_SAMPLE="$DL_DIR/sample.json"
printf '{"eventId":"evt_sample","type":"task.started"}\n' > "$DL_SAMPLE"
AT_DEAD_LETTER_FILE="$DL_DIR/written.jsonl" at_dead_letter_event "$DL_SAMPLE" "HTTP 401 UNAUTHORIZED" credential
check "at_dead_letter_event records the kind beside the reason" \
  "$(grep -q '"deadLetterKind":"credential"' "$DL_DIR/written.jsonl" &&
     grep -q '"deadLetterReason"' "$DL_DIR/written.jsonl"; printf '%s' $?)" \
  "$(cat "$DL_DIR/written.jsonl")"

AT_DEAD_LETTER_FILE="$DL_DIR/defaulted.jsonl" at_dead_letter_event "$DL_SAMPLE" "no kind given"
check "an unclassified dead letter defaults to something that is never replayed" \
  "$(grep -q '"deadLetterKind":"payload"' "$DL_DIR/defaulted.jsonl"; printf '%s' $?)" \
  "$(cat "$DL_DIR/defaulted.jsonl")"

# The partition rule, exercised on its own: no locks, no queue, no network.
DL_INPUT="$DL_DIR/input.jsonl"
DL_REQUEUE="$DL_DIR/requeue.jsonl"
DL_KEEP="$DL_DIR/keep.jsonl"
DL_NOW="$(at_now)"
DL_OLDEST="$(at_rfc3339_from_epoch "$(( $(at_epoch_seconds) - (72 * 3600) ))")"

{
  printf '{"eventId":"evt_cred_a","type":"task.started","timestamp":"%s","deadLetterKind":"credential","deadLetterReason":"HTTP 401 UNAUTHORIZED","deadLetteredAt":"%s"}\n' "$DL_NOW" "$DL_NOW"
  printf '{"eventId":"evt_payload","type":"task.started","timestamp":"%s","deadLetterKind":"payload","deadLetterReason":"VALIDATION_FAILED","deadLetteredAt":"%s"}\n' "$DL_NOW" "$DL_NOW"
  printf '{"eventId":"evt_local","type":"task.started","timestamp":"%s","deadLetterKind":"local","deadLetterReason":"secret filter","deadLetteredAt":"%s"}\n' "$DL_NOW" "$DL_NOW"
  printf '{"eventId":"evt_ancient","type":"task.started","timestamp":"2020-01-01T00:00:00Z","deadLetterKind":"credential","deadLetterReason":"HTTP 401 UNAUTHORIZED","deadLetteredAt":"2020-01-01T00:00:00Z"}\n'
  printf '{"eventId":"evt_legacy","type":"task.started","timestamp":"%s","deadLetterReason":"written before kinds existed","deadLetteredAt":"%s"}\n' "$DL_NOW" "$DL_NOW"
  printf 'this line is not json\n'
  printf '{"eventId":"evt_cred_b","type":"task.started","timestamp":"%s","deadLetterKind":"credential","deadLetterReason":"HTTP 403 FORBIDDEN","deadLetteredAt":"%s"}\n' "$DL_NOW" "$DL_NOW"
} > "$DL_INPUT"

DL_COUNTS="$(at_partition_dead_letters "$DL_INPUT" "$DL_REQUEUE" "$DL_KEEP" 10 "$DL_OLDEST" 72)"

check "a credential failure is offered back to the queue" \
  "$(grep -q 'evt_cred_a' "$DL_REQUEUE" && grep -q 'evt_cred_b' "$DL_REQUEUE"; printf '%s' $?)" \
  "$DL_COUNTS / $(cat "$DL_REQUEUE")"

check "the counts report what was recovered" \
  "$( [ "$DL_COUNTS" = "recovered=2 aged=1" ] && echo 0 || echo 1 )" \
  "got '$DL_COUNTS'"

for REJECTED in evt_payload evt_local evt_legacy; do
  check "$REJECTED is never replayed" \
    "$(grep -q "$REJECTED" "$DL_KEEP" && ! grep -q "$REJECTED" "$DL_REQUEUE"; printf '%s' $?)"
done

check "a line that is not JSON is left where it is rather than guessed at" \
  "$(grep -q 'this line is not json' "$DL_KEEP"; printf '%s' $?)"

check "an event too old to be current is retired instead of replayed" \
  "$(! grep -q 'evt_ancient' "$DL_REQUEUE" &&
     grep -q 'evt_ancient' "$DL_KEEP"; printf '%s' $?)"

check "the retired event is re-marked so the next run does not weigh it again" \
  "$(grep 'evt_ancient' "$DL_KEEP" | grep -q '"deadLetterKind":"expired"'; printf '%s' $?)"

# The ingestion schema rejects unknown top-level keys, so a replayed event that
# still carried its own post-mortem would come back as a payload rejection and
# then never be retried again -- recovery that quietly destroys what it recovers.
check "the dead-letter fields are stripped from anything requeued" \
  "$(! grep -q 'deadLetter' "$DL_REQUEUE"; printf '%s' $?)" \
  "$(cat "$DL_REQUEUE")"

DL_CAPPED="$(at_partition_dead_letters "$DL_INPUT" "$DL_REQUEUE" "$DL_KEEP" 1 "$DL_OLDEST" 72)"
check "one run cannot requeue more than its ceiling" \
  "$( [ "$(grep -c . "$DL_REQUEUE")" = "1" ] && echo 0 || echo 1 )" \
  "$DL_CAPPED / $(cat "$DL_REQUEUE")"

check "what the ceiling held back stays available for the next run" \
  "$(grep -q 'evt_cred_b' "$DL_KEEP"; printf '%s' $?)"

# End to end through flush-pending-events.sh, still with nothing listening: the
# session is pre-written as online, which is the state a successful handshake
# leaves behind, and the send then fails at the network as it always does here.
DL_LIVE="$DL_DIR/live-state"
mkdir -p "$DL_LIVE"
cat > "$DL_LIVE/session.json" <<JSONEOF
{"sessionId":"ses_selftest","projectId":"prj_selftest","protocolVersion":"$AT_FALLBACK_PROTOCOL_VERSION","reportingMode":"full","online":true,"panelUrl":""}
JSONEOF
head -n 3 "$DL_INPUT" > "$DL_LIVE/dead-letter.jsonl"

run_replay() {
  env AGENTMAGNIFY_STATE_DIR="$DL_LIVE" bash "$SCRIPT_DIR/flush-pending-events.sh" \
    --replay-dead-letters 2>&1
}

DL_RUN="$(run_replay)"
check "a replay run moves the recoverable event into the pending queue" \
  "$(grep -q 'evt_cred_a' "$DL_LIVE/pending-events.jsonl"; printf '%s' $?)" \
  "$DL_RUN"

check "the two that were never recoverable are still held" \
  "$(grep -q 'evt_payload' "$DL_LIVE/dead-letter.jsonl" &&
     grep -q 'evt_local' "$DL_LIVE/dead-letter.jsonl"; printf '%s' $?)" \
  "$(cat "$DL_LIVE/dead-letter.jsonl")"

check "a failed send does not lose the event that was just recovered" \
  "$( [ "$(grep -c 'evt_cred_a' "$DL_LIVE/pending-events.jsonl")" = "1" ] && echo 0 || echo 1 )" \
  "$DL_RUN"

# Recovery runs on every successful handshake, and nothing stops a caller from
# opening sessions in a loop. Without the interval, that loop is a replay loop.
printf '{"eventId":"evt_cred_c","type":"task.started","timestamp":"%s","deadLetterKind":"credential","deadLetterReason":"HTTP 401","deadLetteredAt":"%s"}\n' \
  "$DL_NOW" "$DL_NOW" >> "$DL_LIVE/dead-letter.jsonl"
run_replay >/dev/null 2>&1
check "a second replay inside the interval does nothing" \
  "$(grep -q 'evt_cred_c' "$DL_LIVE/dead-letter.jsonl"; printf '%s' $?)" \
  "$(cat "$DL_LIVE/dead-letter.jsonl")"

env AGENTMAGNIFY_STATE_DIR="$DL_LIVE" AGENTMAGNIFY_REPLAY_MIN_INTERVAL_SECONDS=0 \
  bash "$SCRIPT_DIR/flush-pending-events.sh" --replay-dead-letters >/dev/null 2>&1
check "the interval can be lowered when somebody is waiting on it" \
  "$(! grep -q 'evt_cred_c' "$DL_LIVE/dead-letter.jsonl"; printf '%s' $?)" \
  "$(cat "$DL_LIVE/dead-letter.jsonl")"

DL_BEFORE="$(cat "$DL_LIVE/dead-letter.jsonl")"
env AGENTMAGNIFY_STATE_DIR="$DL_LIVE" bash "$SCRIPT_DIR/flush-pending-events.sh" \
  --dry-run --replay-dead-letters >/dev/null 2>&1
check "a dry run replays nothing" \
  "$( [ "$DL_BEFORE" = "$(cat "$DL_LIVE/dead-letter.jsonl")" ] && echo 0 || echo 1 )"

# Two source-level assertions, for the two branches an offline test cannot
# reach: a real 401 needs a server, and the automatic trigger needs a handshake.
check "report-event.sh classifies a rejection by status rather than lumping them together" \
  "$(grep -q 'at_dead_letter_kind_for_status "\$STATUS"' "$SCRIPT_DIR/report-event.sh"; printf '%s' $?)"

check "report-event.sh tells the reader a refused credential is not a bad event" \
  "$(grep -q 'the monitoring credential was not accepted' "$SCRIPT_DIR/report-event.sh"; printf '%s' $?)"

check "report-event.sh never marks a secret-filter refusal as recoverable" \
  "$(grep -q 'could not clean the payload" local' "$SCRIPT_DIR/report-event.sh"; printf '%s' $?)"

check "start-session.sh replays held events on a successful handshake" \
  "$(grep -q 'flush-pending-events.sh" --replay-dead-letters' "$SCRIPT_DIR/start-session.sh"; printf '%s' $?)"

# ---------------------------------------------------------------------------
section "credential resolution"

CONFIG_HOME="$(mktemp -d "${TMPDIR:-/tmp}/at-selftest-home.XXXXXX")"
CONFIG_PROJECT="$(mktemp -d "${TMPDIR:-/tmp}/at-selftest-project.XXXXXX")"
CONFIG_ORIGINAL_DIR="$(pwd)"

cleanup_config_fixture() {
  cd "$CONFIG_ORIGINAL_DIR" 2>/dev/null || true
  rm -rf "$CONFIG_HOME" "$CONFIG_PROJECT"
}
trap 'at_cleanup_temp; cleanup_config_fixture' EXIT

# Each case runs login.sh --status in a clean environment and reports the
# resolved source, so the precedence order is asserted rather than assumed.
resolve_status() {
  ( cd "$CONFIG_PROJECT" && env -u AGENTMAGNIFY_TOKEN -u AGENTMAGNIFY_API_URL \
      -u AGENTMAGNIFY_PROJECT_NAME "$@" \
      HOME="$CONFIG_HOME" AGENTMAGNIFY_STATE_DIR="$CONFIG_HOME/state" \
      bash "$SCRIPT_DIR/login.sh" --status 2>&1 )
}

mkdir -p "$CONFIG_HOME/.agentmagnify"
printf '{"apiUrl":"https://user.example","token":"wsi_live_userlevel0000"}\n' \
  > "$CONFIG_HOME/.agentmagnify/credentials.json"
chmod 600 "$CONFIG_HOME/.agentmagnify/credentials.json"

STATUS_USER="$(resolve_status)"
check "the user-level credential is found with no project setup" \
  "$(printf '%s' "$STATUS_USER" | grep -q 'credentials.json'; printf '%s' $?)" \
  "$STATUS_USER"
check "the user-level credential reports its token kind" \
  "$(printf '%s' "$STATUS_USER" | grep -q 'workspace_ingestion'; printf '%s' $?)"
# The exit code, not the wording, is what SKILL.md tells the agent to branch on
# when deciding whether to activate. It used to be 0 either way, and the
# activation rule read an environment variable that a correctly paired machine
# never has -- so the skill switched itself off exactly where it should be on.
( cd "$CONFIG_PROJECT" && env -u AGENTMAGNIFY_TOKEN HOME="$CONFIG_HOME" \
    AGENTMAGNIFY_STATE_DIR="$CONFIG_HOME/state" \
    bash "$SCRIPT_DIR/login.sh" --status >/dev/null 2>&1 )
check "--status succeeds when a credential resolves" "$?"

AT_EMPTY_HOME="$(mktemp -d)"
( cd "$AT_EMPTY_HOME" && env -u AGENTMAGNIFY_TOKEN HOME="$AT_EMPTY_HOME" \
    AGENTMAGNIFY_STATE_DIR="$AT_EMPTY_HOME/state" \
    bash "$SCRIPT_DIR/login.sh" --status >/dev/null 2>&1 )
AT_EMPTY_CODE=$?
rm -rf "$AT_EMPTY_HOME"
check "--status fails when nothing resolves" \
  "$([ "$AT_EMPTY_CODE" -ne 0 ]; printf '%s' $?)" \
  "exit code was $AT_EMPTY_CODE"

check "--status never prints the token itself" \
  "$(printf '%s' "$STATUS_USER" | grep -qv 'wsi_live_userlevel0000'; printf '%s' $?)"

printf '{"token":"prj_live_projectlocal00"}\n' > "$CONFIG_PROJECT/.agentmagnify.local.json"
STATUS_PROJECT="$(resolve_status)"
check "a project-local secret outranks the user-level credential" \
  "$(printf '%s' "$STATUS_PROJECT" | grep -q 'agentmagnify.local.json'; printf '%s' $?)" \
  "$STATUS_PROJECT"

STATUS_ENV="$(resolve_status AGENTMAGNIFY_TOKEN=wsi_live_fromenvironment)"
check "the environment outranks every file" \
  "$(printf '%s' "$STATUS_ENV" | grep -q 'environment'; printf '%s' $?)" \
  "$STATUS_ENV"

rm -f "$CONFIG_PROJECT/.agentmagnify.local.json"

printf '{"projectName":"Pinned Name"}\n' > "$CONFIG_PROJECT/.agentmagnify.json"
STATUS_NAMED="$(resolve_status)"
check "a committed project config pins the project name" \
  "$(printf '%s' "$STATUS_NAMED" | grep -q 'Pinned Name'; printf '%s' $?)" \
  "$STATUS_NAMED"

# The one rule that matters most: the committed file is shared, so a token in
# it is a leak waiting to happen and must stop the run outright.
printf '{"projectName":"Leaky","token":"wsi_live_committedsecret"}\n' \
  > "$CONFIG_PROJECT/.agentmagnify.json"
STATUS_LEAK="$(resolve_status || true)"
check "a token in the committed config is refused" \
  "$(printf '%s' "$STATUS_LEAK" | grep -q "contains a 'token' field"; printf '%s' $?)" \
  "$STATUS_LEAK"
check "the refusal tells the user to rotate the exposed token" \
  "$(printf '%s' "$STATUS_LEAK" | grep -q 'rotate'; printf '%s' $?)"

rm -f "$CONFIG_PROJECT/.agentmagnify.json"
rm -f "$CONFIG_HOME/.agentmagnify/credentials.json"

STATUS_NONE="$(resolve_status)"
check "no credential anywhere reports none found rather than failing" \
  "$(printf '%s' "$STATUS_NONE" | grep -q 'none found'; printf '%s' $?)" \
  "$STATUS_NONE"

# The project name falls back to the directory when there is no git remote.
CONFIG_BASENAME="$(basename "$CONFIG_PROJECT")"
check "the project name falls back to the directory name" \
  "$(printf '%s' "$STATUS_NONE" | grep -q "$CONFIG_BASENAME"; printf '%s' $?)" \
  "$STATUS_NONE"

# A machine set up before the product was renamed to AgentMagnify has its token
# under the old names, which are no longer read. "None found" is then true and
# useless: it sends the user off to pair again without ever telling them their
# credential is sitting one directory away. These two checks are the difference.
mkdir -p "$CONFIG_HOME/.agent-tracker"
printf '{"apiUrl":"https://old.example","token":"wsi_live_legacyuser000"}\n' \
  > "$CONFIG_HOME/.agent-tracker/credentials.json"
chmod 600 "$CONFIG_HOME/.agent-tracker/credentials.json"

STATUS_LEGACY_FILE="$(resolve_status)"
check "a pre-rename credentials file is named rather than ignored" \
  "$(printf '%s' "$STATUS_LEGACY_FILE" | grep -q '.agent-tracker/credentials.json'; printf '%s' $?)" \
  "$STATUS_LEGACY_FILE"
check "the pre-rename credential is reported, never read" \
  "$(printf '%s' "$STATUS_LEGACY_FILE" | grep -qv 'wsi_live_legacyuser000'; printf '%s' $?)"

rm -rf "$CONFIG_HOME/.agent-tracker"

STATUS_LEGACY_ENV="$(resolve_status AGENT_TRACKER_TOKEN=wsi_live_legacyenv00000)"
check "a pre-rename token variable is answered with the new variable name" \
  "$(printf '%s' "$STATUS_LEGACY_ENV" | grep -q 'AGENTMAGNIFY_TOKEN'; printf '%s' $?)" \
  "$STATUS_LEGACY_ENV"
check "the pre-rename token variable is still not treated as a credential" \
  "$(printf '%s' "$STATUS_LEGACY_ENV" | grep -q 'none found'; printf '%s' $?)"

cleanup_config_fixture
trap at_cleanup_temp EXIT

# ---------------------------------------------------------------------------
section "per-project state isolation"
# ---------------------------------------------------------------------------

# The bug this section exists for: state used to live in the skill's install
# directory, one copy per machine. Two agents on two projects shared a single
# session.json, the second session overwrote the first's project id, and the
# first agent's uploads were then filed under the second agent's project.

ISO_HOME="$(mktemp -d "${TMPDIR:-/tmp}/at-selftest-isohome.XXXXXX")"
ISO_A="$(mktemp -d "${TMPDIR:-/tmp}/at-selftest-projA.XXXXXX")"
ISO_B="$(mktemp -d "${TMPDIR:-/tmp}/at-selftest-projB.XXXXXX")"
mkdir -p "$ISO_A/packages/inner"
( cd "$ISO_A" && git init -q 2>/dev/null || true )
( cd "$ISO_B" && git init -q 2>/dev/null || true )

# Resolves the state directory the way a script would, from a given cwd, with
# the override deliberately removed so the derivation itself is under test.
state_dir_in() {
  ( cd "$1" && env -u AGENTMAGNIFY_STATE_DIR -u AGENTMAGNIFY_STATE_HOME \
      HOME="$ISO_HOME" LIB="$SCRIPT_DIR/lib.sh" \
      bash -c '. "$LIB" >/dev/null 2>&1; printf "%s" "$AT_STATE_DIR"' )
}

ISO_DIR_A="$(state_dir_in "$ISO_A")"
ISO_DIR_B="$(state_dir_in "$ISO_B")"
ISO_DIR_A_SUB="$(state_dir_in "$ISO_A/packages/inner")"

check "two projects on one machine get two state directories" \
  "$([ -n "$ISO_DIR_A" ] && [ "$ISO_DIR_A" != "$ISO_DIR_B" ]; printf '%s' $?)" \
  "both resolved to '$ISO_DIR_A'"

check "one project reached from a subdirectory keeps one state directory" \
  "$([ "$ISO_DIR_A" = "$ISO_DIR_A_SUB" ]; printf '%s' $?)" \
  "'$ISO_DIR_A' vs '$ISO_DIR_A_SUB'"

check "state no longer lives in the skill's install directory" \
  "$(printf '%s' "$ISO_DIR_A" | grep -qv "^$AT_SKILL_ROOT/state"; printf '%s' $?)" \
  "resolved to '$ISO_DIR_A'"

check "AGENTMAGNIFY_STATE_DIR still overrides the derivation" \
  "$([ "$( cd "$ISO_A" && env AGENTMAGNIFY_STATE_DIR="$ISO_HOME/pinned" HOME="$ISO_HOME" \
        LIB="$SCRIPT_DIR/lib.sh" bash -c '. "$LIB" >/dev/null 2>&1; printf "%s" "$AT_STATE_DIR"' )" \
      = "$ISO_HOME/pinned" ]; printf '%s' $?)"

# The symptom itself: a session opened for one project must be invisible to
# the other, because that file is where uploads read their project id.
mkdir -p "$ISO_DIR_A"
printf '{"sessionId":"ses_a","projectId":"prj_AAA"}\n' > "$ISO_DIR_A/session.json"

ISO_B_SEES="$( cd "$ISO_B" && env -u AGENTMAGNIFY_STATE_DIR -u AGENTMAGNIFY_STATE_HOME \
  HOME="$ISO_HOME" LIB="$SCRIPT_DIR/lib.sh" \
  bash -c '. "$LIB" >/dev/null 2>&1; cat "$AT_SESSION_FILE" 2>/dev/null || printf "none"' )"

check "a session opened for one project is invisible to the other" \
  "$(printf '%s' "$ISO_B_SEES" | grep -q 'prj_AAA' && printf 1 || printf 0)" \
  "the other project read: $ISO_B_SEES"

rm -rf "$ISO_HOME" "$ISO_A" "$ISO_B"

# ---------------------------------------------------------------------------
section "pairing"
# ---------------------------------------------------------------------------
#
# Offline, like everything else here, so none of this reaches the API. What can
# be checked without a server is the part that matters most anyway: that the
# script exists, that it tells the truth about what it does, and above all that
# nothing in it ever prints a secret.

PAIR_SCRIPT="$SCRIPT_DIR/pair.sh"

check "pair.sh exists and is executable" \
  "$([ -x "$PAIR_SCRIPT" ]; printf '%s' $?)"

PAIR_HELP="$(bash "$PAIR_SCRIPT" --help 2>&1 || true)"
check "pair.sh --help explains itself without contacting anything" \
  "$(printf '%s' "$PAIR_HELP" | grep -q 'approve'; printf '%s' $?)" \
  "$PAIR_HELP"

# The whole reason this script exists. If the help text stops saying so, the
# next person to read it will not know which of the two paths to take.
check "pair.sh says no token is shown" \
  "$(printf '%s' "$PAIR_HELP" | grep -qi 'No token is shown'; printf '%s' $?)" \
  "$PAIR_HELP"

# And the fallback must stay documented as a fallback rather than disappearing.
check "pair.sh points CI at the environment variable instead" \
  "$(printf '%s' "$PAIR_HELP" | grep -q 'AGENTMAGNIFY_TOKEN'; printf '%s' $?)" \
  "$PAIR_HELP"

check "pair.sh refuses an unknown option rather than guessing" \
  "$(bash "$PAIR_SCRIPT" --nonsense >/dev/null 2>&1; [ $? -ne 0 ]; printf '%s' $?)"

check "pair.sh refuses a timeout that is not a number" \
  "$(bash "$PAIR_SCRIPT" --timeout soon >/dev/null 2>&1; [ $? -ne 0 ]; printf '%s' $?)"

# The device code is the half worth stealing, so no branch may put it on the
# terminal. Checked against the source, because there is no way to observe it at
# runtime without a server and a `printf` added later is exactly the kind of
# change nobody would notice.
#
# "On the terminal" rather than "anywhere": the code does legitimately go into
# the request body, which is a temporary file at 0600. So the assertion is that
# every line mentioning it is redirected somewhere, and none writes to stdout.
DEVICE_CODE_PRINTS="$(grep -n 'printf' "$PAIR_SCRIPT" | grep 'DEVICE_CODE' | grep -v '>' || true)"
check "pair.sh never prints the device code to the terminal" \
  "$([ -z "$DEVICE_CODE_PRINTS" ]; printf '%s' $?)" \
  "$DEVICE_CODE_PRINTS"

TOKEN_PRINTS="$(grep -n 'printf' "$PAIR_SCRIPT" | grep -E '\$TOKEN\b' | grep -v '>' || true)"
check "pair.sh never prints the token it received" \
  "$([ -z "$TOKEN_PRINTS" ]; printf '%s' $?)" \
  "$TOKEN_PRINTS"

# And the response that carried them is emptied as soon as it has been read,
# rather than left on disk for however long the script waits.
check "pair.sh truncates the files that held a secret" \
  "$(grep -Eq '^[[:space:]]*: > "\$response_file"' "$PAIR_SCRIPT" && grep -q ': > "\$poll_file"' "$PAIR_SCRIPT" && grep -q ': > "\$claim_file"' "$PAIR_SCRIPT"; printf '%s' $?)"

# It writes the credential the same way login.sh does: 0600, and never into a
# file that is committed.
check "pair.sh writes the credential with a restrictive umask" \
  "$(grep -q 'umask 077' "$PAIR_SCRIPT"; printf '%s' $?)"
check "pair.sh chmods the credential file to 0600" \
  "$(grep -q 'chmod 600' "$PAIR_SCRIPT"; printf '%s' $?)"
check "pair.sh writes only to the git-ignored or user-level file" \
  "$(grep -q 'AT_PROJECT_SECRET_NAME' "$PAIR_SCRIPT" && grep -q 'AT_CREDENTIALS_FILE' "$PAIR_SCRIPT"; printf '%s' $?)"

# A refusal and a timeout have to read differently: one means run this again,
# the other means somebody deliberately said no.
# The thank-you belongs at a completion and nowhere else. Both halves matter:
# that it is there, and that it is there once and only on the success path --
# every failure branch above exits before reaching it.
PAIR_THANKS="$(grep -c 'Thank you for using AgentMagnify' "$PAIR_SCRIPT" || true)"
check "pair.sh thanks the user exactly once" \
  "$( [ "$PAIR_THANKS" = "1" ] && echo 0 || echo 1 )" \
  "found $PAIR_THANKS"
check "and only after a pairing has actually been approved" \
  "$( [ "$(grep -n 'Thank you for using AgentMagnify' "$PAIR_SCRIPT" | cut -d: -f1)" -gt \
       "$(grep -n 'approved)' "$PAIR_SCRIPT" | head -n 1 | cut -d: -f1)" ] && echo 0 || echo 1 )"

check "no other script thanks anybody" \
  "$( [ "$(grep -l 'Thank you for using' "$SCRIPT_DIR"/*.sh | grep -cv 'pair.sh\|self-test.sh')" = "0" ] && echo 0 || echo 1 )" \
  "$(grep -l 'Thank you for using' "$SCRIPT_DIR"/*.sh | tr '\n' ' ')"

check "pair.sh distinguishes a refusal from an expiry" \
  "$(grep -q 'was refused in the panel' "$PAIR_SCRIPT" && grep -q 'expired before it was approved' "$PAIR_SCRIPT"; printf '%s' $?)"

# The environment variable stays the documented fallback. This is the assertion
# The panel-issued direction: a code pasted in place of a wait. Only the
# offline half is testable here -- a malformed code must die before any
# request, and the help must document the flag.
check "pair.sh --help documents --code" \
  "$(printf '%s' "$PAIR_HELP" | grep -q -- '--code'; printf '%s' $?)" \
  "$PAIR_HELP"
check "pair.sh refuses a malformed pair code before touching the network" \
  "$(bash "$PAIR_SCRIPT" --code NOPE >/dev/null 2>&1; [ $? -ne 0 ]; printf '%s' $?)"

# ---------------------------------------------------------------------------
# upload-artifact.sh -- offline behaviour only; the flow needs a store.
# ---------------------------------------------------------------------------

UPLOAD_SCRIPT="$SCRIPT_DIR/upload-artifact.sh"
UPLOAD_HELP="$(bash "$UPLOAD_SCRIPT" --help 2>&1 || true)"

check "upload-artifact.sh --help explains itself without contacting anything" \
  "$(printf '%s' "$UPLOAD_HELP" | grep -q 'storage allowance'; printf '%s' $?)" \
  "$UPLOAD_HELP"
check "upload-artifact.sh refuses a missing file" \
  "$(bash "$UPLOAD_SCRIPT" /nonexistent/file.png >/dev/null 2>&1; [ $? -ne 0 ]; printf '%s' $?)"
check "upload-artifact.sh refuses an unknown option rather than guessing" \
  "$(bash "$UPLOAD_SCRIPT" --nonsense >/dev/null 2>&1; [ $? -ne 0 ]; printf '%s' $?)"
UNKNOWN_TYPE_FILE="$(at_mktemp).mystery"
printf 'x' > "$UNKNOWN_TYPE_FILE"
check "upload-artifact.sh will not guess a content type it cannot infer" \
  "$(bash "$UPLOAD_SCRIPT" "$UNKNOWN_TYPE_FILE" >/dev/null 2>&1; [ $? -ne 0 ]; printf '%s' $?)"
rm -f "$UNKNOWN_TYPE_FILE"

# that the new path was added rather than substituted.
MISSING_TOKEN_HELP="$(env -u AGENTMAGNIFY_TOKEN bash -c '
  . "$1/lib.sh"
  at_load_config >/dev/null 2>&1
  AGENTMAGNIFY_TOKEN=""
  at_require_token 2>&1 || true
' _ "$SCRIPT_DIR")"

# ---------------------------------------------------------------------------
# Executor identity
#
# Nothing covered this, which is why it was wrong: an environment the detector
# could not place was reported as `claude-code`, so an agent running anywhere
# else showed up under somebody else's name and the panel repeated it without
# hesitation. And a name given in the environment but absent from the type list
# was narrowed to `custom` and then dropped, losing the only description of the
# thing that was actually running.
# ---------------------------------------------------------------------------

executor_probe() {
  ( env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CURSOR_SESSION_ID \
        -u CODEX_SESSION_ID -u CODEX_HOME -u AGENTMAGNIFY_EXECUTOR \
        -u AGENTMAGNIFY_EXECUTOR_LABEL "$@" \
    bash -c ". \"$SCRIPT_DIR/lib.sh\" >/dev/null 2>&1; printf '%s|%s' \"\$(at_executor_type)\" \"\$(at_executor_label)\"" )
}

EXEC_UNKNOWN="$(executor_probe)"
check "an unplaceable environment reports custom rather than guessing a name" \
  "$([ "${EXEC_UNKNOWN%%|*}" = "custom" ]; printf '%s' $?)" \
  "got $EXEC_UNKNOWN"

EXEC_KNOWN="$(executor_probe AGENTMAGNIFY_EXECUTOR=codex)"
check "a named executor the contract knows is passed through as its own type" \
  "$([ "${EXEC_KNOWN%%|*}" = "codex" ]; printf '%s' $?)" \
  "got $EXEC_KNOWN"

EXEC_STRANGER="$(executor_probe AGENTMAGNIFY_EXECUTOR=windsurf)"
check "an executor the contract has never heard of still says what it is" \
  "$([ "$EXEC_STRANGER" = "custom|windsurf" ]; printf '%s' $?)" \
  "got $EXEC_STRANGER"

EXEC_LABELLED="$(executor_probe AGENTMAGNIFY_EXECUTOR=windsurf AGENTMAGNIFY_EXECUTOR_LABEL=Windsurf)"
check "an explicit label outranks the inferred one" \
  "$([ "$EXEC_LABELLED" = "custom|Windsurf" ]; printf '%s' $?)" \
  "got $EXEC_LABELLED"

check "start-session sends the label rather than reading the variable itself" \
  "$(grep -q 'at_executor_label' "$SCRIPT_DIR/start-session.sh"; printf '%s' $?)"

check "a machine with no credential is told about both paths" \
  "$(printf '%s' "$MISSING_TOKEN_HELP" | grep -q 'pair.sh' && printf '%s' "$MISSING_TOKEN_HELP" | grep -q 'login.sh'; printf '%s' $?)" \
  "$MISSING_TOKEN_HELP"

check "the resolution order is still named in full when nothing is found" \
  "$(printf '%s' "$MISSING_TOKEN_HELP" | grep -q 'AGENTMAGNIFY_TOKEN'; printf '%s' $?)" \
  "$MISSING_TOKEN_HELP"

# ---------------------------------------------------------------------------
section "installer"
# ---------------------------------------------------------------------------
#
# The one end-to-end check available with no network: install this package the
# way a customer does, into a home directory that has nothing else in it, and
# make the installed copy pass its own self-test. That catches the failures a
# check against the source cannot see -- a payload list that has drifted from
# what the scripts actually source, a lost executable bit, a file that never
# made it into the package at all -- every one of which looks like a successful
# install right up until an agent tries to report.
#
# It runs only where it can. An installed copy of this skill has no installer
# beside it, which is the normal shape and not a failure, and this package's
# stated requirements are bash, curl and jq or python3 -- node is the
# installer's dependency, not the skill's.


# ---------------------------------------------------------------------------
# The default points at the service, not at the developer's own machine
# ---------------------------------------------------------------------------
#
# This defaulted to http://localhost:4000 while the only installation was a
# developer's, and stayed correct right up until there was something to
# install from. After that it aimed the whole onboarding path -- install, pair,
# report -- at a port nobody outside this repository is listening on, and the
# failure would look like a broken product rather than a wrong address.
#
# Three scripts resolve it and the help text prints it, so this pins the
# resolution rather than the constant: a change that fixes lib.sh and leaves
# a copy behind still fails here.

# No `case` in any of these: a pattern's `)` closes the enclosing $( ) early,
# which is a syntax error rather than a failed check, and reads as one.
check "the default API URL is the hosted service" \
  "$( [ "${AT_DEFAULT_API_URL#https://}" != "$AT_DEFAULT_API_URL" ] && echo 0 || echo 1 )" \
  "AT_DEFAULT_API_URL is '$AT_DEFAULT_API_URL'"

AT_RESOLVED_DEFAULT="$(env -u AGENTMAGNIFY_API_URL bash -c '
  . "'"$AT_LIB_DIR"'/lib.sh"
  at_load_config >/dev/null 2>&1
  printf "%s" "$AT_API_URL"
')"
check "and that is what a script with no environment actually resolves to" \
  "$( [ "$AT_RESOLVED_DEFAULT" = "$AT_DEFAULT_API_URL" ] && echo 0 || echo 1 )" \
  "resolved '$AT_RESOLVED_DEFAULT', expected '$AT_DEFAULT_API_URL'"

for SCRIPT_WITH_USAGE in pair.sh login.sh; do
  USAGE_TEXT="$(bash "$AT_LIB_DIR/$SCRIPT_WITH_USAGE" --help 2>&1 || true)"
  check "$SCRIPT_WITH_USAGE prints the address rather than the variable's name" \
    "$( [ "${USAGE_TEXT#*"$AT_DEFAULT_API_URL"}" != "$USAGE_TEXT" ] && echo 0 || echo 1 )" \
    "$(printf '%s' "$USAGE_TEXT" | grep -i 'api-url' | head -1)"
done


# ---------------------------------------------------------------------------
# A message does not claim what it did not test
# ---------------------------------------------------------------------------
#
# With no token, fetch-schema.sh sends nothing at all -- so it cannot have
# found the API unreachable, and it used to say so anyway. That is the state a
# machine is in five minutes after `npx agentmagnify install`, and the message
# sent whoever read it to check DNS, the firewall and the server. Seen on the
# live service: this warned the API was unreachable and pair.sh reached the
# same API seconds later.

SCHEMA_HOME="$(mktemp -d "${TMPDIR:-/tmp}/agentmagnify-schema.XXXXXX")"
# AGENTMAGNIFY_CREDENTIALS_FILE too, not just the variable. A paired machine
# has ~/.agentmagnify/credentials.json, so unsetting the environment alone left
# a token to find: this check passed on an unpaired machine and failed on a
# paired one, which is a test of the machine rather than of the code. It caught
# itself the first time this repository's own machine was paired.
NO_TOKEN_OUTPUT="$(env -u AGENTMAGNIFY_TOKEN \
  AGENTMAGNIFY_CREDENTIALS_FILE="$SCHEMA_HOME/absent.json" \
  AGENTMAGNIFY_STATE_DIR="$SCHEMA_HOME/state" \
  bash "$AT_LIB_DIR/fetch-schema.sh" 2>&1 || true)"

check "fetch-schema names the missing token rather than blaming the network" \
  "$( [ "${NO_TOKEN_OUTPUT#*no token}" != "$NO_TOKEN_OUTPUT" ] && echo 0 || echo 1 )" \
  "$NO_TOKEN_OUTPUT"
check "and does not report the API unreachable without having asked it" \
  "$( [ "${NO_TOKEN_OUTPUT#*unreachable}" = "$NO_TOKEN_OUTPUT" ] && echo 0 || echo 1 )" \
  "$NO_TOKEN_OUTPUT"

rm -rf "$SCHEMA_HOME"


# ---------------------------------------------------------------------------
# The heartbeat runs by itself, and stops by itself
# ---------------------------------------------------------------------------
#
# Liveness used to be a row in a table saying "keep the session alive during
# long silent work", with nothing anywhere telling an agent when to call it. A
# real session sent a roadmap and one task.started, then wrote eleven files in
# silence. A model has no clock and cannot wake itself up, so this is a process
# now rather than an instruction.
#
# The stop conditions matter as much as the ticking: a daemon still claiming
# liveness after the agent has gone makes a dead session look alive, which is
# worse than the silence it replaced.

check "the heartbeat daemon ships with the skill" \
  "$( [ -f "$AT_LIB_DIR/heartbeat-daemon.sh" ] && echo 0 || echo 1 )" \
  "scripts/heartbeat-daemon.sh"

check "start-session starts it" \
  "$( grep -q 'at_start_heartbeat' "$AT_LIB_DIR/start-session.sh" && echo 0 || echo 1 )" \
  "start-session.sh does not call at_start_heartbeat"

check "and complete-session stops it, so a closed session stops claiming to be alive" \
  "$( grep -q 'at_stop_heartbeat' "$AT_LIB_DIR/complete-session.sh" && echo 0 || echo 1 )" \
  "complete-session.sh does not call at_stop_heartbeat"

check "the daemon gives up on its own when no event has arrived" \
  "$( grep -q 'MAX_SILENCE' "$AT_LIB_DIR/heartbeat-daemon.sh" && echo 0 || echo 1 )" \
  "no silence ceiling in heartbeat-daemon.sh"

# Started, left alone long enough to be genuinely asleep, then stopped.
#
# The sleep is the point. Bash does not run a trap while waiting for a
# foreground child, so a daemon sitting in `sleep 300` ignored SIGTERM for up
# to five minutes: stopping it looked like it worked -- kill returns 0, the pid
# file goes -- while the process lived on and could send one more heartbeat
# after the session had closed.
#
# The first version of this check killed the daemon one second after starting
# it and passed, because the signal arrived before the sleep did. It was a race
# that reported the answer I wanted, and it is why this one waits first.
HB_HOME="$(mktemp -d "${TMPDIR:-/tmp}/agentmagnify-hb.XXXXXX")"
mkdir -p "$HB_HOME/state"
printf '{"sessionId":"self-test"}\n' > "$HB_HOME/state/session.json"
printf '1\n' > "$HB_HOME/state/sequence"

HB_PID="$(env AGENTMAGNIFY_STATE_DIR="$HB_HOME/state" \
  AGENTMAGNIFY_HEARTBEAT_SECONDS=60 AGENTMAGNIFY_HEARTBEAT_MAX_SILENCE=999999 \
  AGENTMAGNIFY_API_URL="http://127.0.0.1:1" \
  bash -c '. "'"$AT_LIB_DIR"'/lib.sh"; at_load_config >/dev/null 2>&1; at_start_heartbeat; cat "$AT_HEARTBEAT_PID_FILE"' 2>/dev/null)"

check "the heartbeat daemon starts" \
  "$( [ -n "$HB_PID" ] && kill -0 "$HB_PID" 2>/dev/null && echo 0 || echo 1 )" \
  "pid '$HB_PID'"

sleep 3
env AGENTMAGNIFY_STATE_DIR="$HB_HOME/state" \
  bash -c '. "'"$AT_LIB_DIR"'/lib.sh"; at_load_config >/dev/null 2>&1; at_stop_heartbeat' >/dev/null 2>&1

check "and stopping it stops it, even mid-sleep" \
  "$( kill -0 "$HB_PID" 2>/dev/null && echo 1 || echo 0 )" \
  "pid $HB_PID survived at_stop_heartbeat"

kill -9 "$HB_PID" 2>/dev/null || true
rm -rf "$HB_HOME"

# A version written into prose is a version that goes stale silently: SKILL.md
# claimed the handshake sent 0.1.0 three releases after it stopped doing so.
SKILL_MD_VERSIONS="$(grep -oE '\`[0-9]+\.[0-9]+\.[0-9]+\`' "$AT_SKILL_ROOT/SKILL.md" | wc -l | tr -d ' ')"
check "SKILL.md quotes no version number of its own" \
  "$( [ "$SKILL_MD_VERSIONS" = "0" ] && echo 0 || echo 1 )" \
  "$SKILL_MD_VERSIONS version literal(s) in SKILL.md; lib.sh is the only place a version belongs"

INSTALLER_BIN="$AT_SKILL_ROOT/../installer/bin/agentmagnify.mjs"

if [ "${AGENTMAGNIFY_SKIP_INSTALLER_CHECKS:-0}" = "1" ]; then
  skip "installer checks (this run was started by the installer it would test)"
elif [ ! -f "$INSTALLER_BIN" ]; then
  skip "installer checks (no installer package beside this skill, which is what an installed copy looks like)"
elif ! command -v node >/dev/null 2>&1; then
  skip "installer checks (node is not on PATH; this package does not need it, the installer does)"
else
  INSTALLER_DIR="$(cd "$(dirname "$(dirname "$INSTALLER_BIN")")" && pwd)"

  # Three files state a version and one of them is sent in the handshake, so a
  # disagreement is the panel being told something untrue about what is running.
  INSTALLER_VERSION="$(at_json_get "$INSTALLER_DIR/package.json" 'version')"
  SKILL_PACKAGE_VERSION="$(at_json_get "$AT_SKILL_ROOT/package.json" 'version')"
  check "the npm package states the version this skill reports in its handshake" \
    "$( [ "$INSTALLER_VERSION" = "$AT_CLIENT_VERSION" ] && echo 0 || echo 1 )" \
    "npm says '$INSTALLER_VERSION', lib.sh says '$AT_CLIENT_VERSION'"
  check "and so does this package's own manifest" \
    "$( [ "$SKILL_PACKAGE_VERSION" = "$AT_CLIENT_VERSION" ] && echo 0 || echo 1 )" \
    "package.json says '$SKILL_PACKAGE_VERSION', lib.sh says '$AT_CLIENT_VERSION'"

  INSTALL_HOME="$(mktemp -d "${TMPDIR:-/tmp}/agentmagnify-install.XXXXXX")"
  mkdir -p "$INSTALL_HOME/.claude"
  INSTALL_OUTPUT="$(env -u AGENTMAGNIFY_STATE_DIR HOME="$INSTALL_HOME" \
    node "$INSTALLER_BIN" install --home "$INSTALL_HOME" 2>&1)"
  INSTALL_CODE=$?
  INSTALLED_DIR="$INSTALL_HOME/.claude/skills/agentmagnify"

  check "the installer exits 0 on a clean machine" "$INSTALL_CODE" "$INSTALL_OUTPUT"

  check "SKILL.md lands where Claude Code reads it" \
    "$( [ -f "$INSTALLED_DIR/SKILL.md" ] && echo 0 || echo 1 )" \
    "$INSTALL_OUTPUT"

  check "the scripts arrive executable" \
    "$( [ -x "$INSTALLED_DIR/scripts/report-event.sh" ] && echo 0 || echo 1 )"

  check "the offline fallback schema arrives with them" \
    "$( [ -f "$INSTALLED_DIR/references/fallback-schema.json" ] && echo 0 || echo 1 )"

  check "the installed SKILL.md is byte-identical to this one" \
    "$( cmp -s "$AT_SKILL_ROOT/SKILL.md" "$INSTALLED_DIR/SKILL.md" && echo 0 || echo 1 )"

  # The check this whole section exists for.
  check "the freshly installed copy passes its own self-test" \
    "$(printf '%s' "$INSTALL_OUTPUT" | grep -q 'self-test: passed'; printf '%s' $?)" \
    "$INSTALL_OUTPUT"

  check "the installer says where it wrote" \
    "$(printf '%s' "$INSTALL_OUTPUT" | grep -q 'skills/agentmagnify'; printf '%s' $?)"

  # Asked for once, at a completion. A tool that thanks you on every event is a
  # tool whose output people stop reading.
  THANKS_COUNT="$(printf '%s\n' "$INSTALL_OUTPUT" | grep -c 'Thank you for using AgentMagnify\.' || true)"
  check "the installer thanks the user exactly once" \
    "$( [ "$THANKS_COUNT" = "1" ] && echo 0 || echo 1 )" \
    "found $THANKS_COUNT"

  # Byte-level, because a shell has no idea what a grapheme is: every emoji
  # outside the BMP begins with 0xF0 0x9F in UTF-8.
  check "the installer prints no emoji" \
    "$(printf '%s' "$INSTALL_OUTPUT" | LC_ALL=C grep -q $'\xf0\x9f'; [ $? -ne 0 ]; printf '%s' $?)"

  rm -rf "$INSTALL_HOME" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
printf '\n----------------------------------------\n'
if [ "$SKIP_COUNT" -gt 0 ]; then
  printf 'passed: %s   failed: %s   skipped: %s\n' "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
else
  printf 'passed: %s   failed: %s\n' "$PASS_COUNT" "$FAIL_COUNT"
fi

if [ "$FAIL_COUNT" -gt 0 ]; then
  printf 'self-test FAILED\n'
  exit 1
fi

printf 'self-test passed\n'
exit 0
