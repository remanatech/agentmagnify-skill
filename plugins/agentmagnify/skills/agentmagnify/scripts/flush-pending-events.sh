#!/usr/bin/env bash
#
# flush-pending-events.sh - drain state/pending-events.jsonl into the API.
#
# Follows doc 15:
#   1. queued events are sent in order, in batches of at most maxBatchSize
#   2. the API applies idempotency, so a replayed event is a duplicate, not a
#      second record
#   3. accepted and duplicate entries are removed from the queue
#   4. permanently rejected entries are moved to state/dead-letter.jsonl
#   5. anything that failed for a transient reason stays queued for next time
#
# Events queued before the API was ever reachable carry a local placeholder
# session id; those are rewritten to the real session id before sending.
#
# --replay-dead-letters additionally recovers the events that were refused
# because the credential was refused. See replay_dead_letters() below for what
# it will and will not put back, and why this is a flag on this script rather
# than a script of its own.
#
# Usage: flush-pending-events.sh [--dry-run] [--replay-dead-letters]

set -euo pipefail

# shellcheck source=./lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

DRY_RUN=0
REPLAY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --replay-dead-letters) REPLAY=1; shift ;;
    -h|--help)
      printf 'Usage: flush-pending-events.sh [--dry-run] [--replay-dead-letters]\n'
      exit 0
      ;;
    *) at_die "unknown option '$1'" ;;
  esac
done

at_load_config
at_require_deps || exit 1

if [ ! -s "$AT_PENDING_FILE" ] && { [ "$REPLAY" != "1" ] || [ ! -s "$AT_DEAD_LETTER_FILE" ]; }; then
  at_debug "nothing queued"
  exit 0
fi

QUEUE_MAX_AGE_HOURS="${AGENTMAGNIFY_QUEUE_MAX_AGE_HOURS:-72}"
OLDEST_ALLOWED="$(at_rfc3339_from_epoch "$(( $(at_epoch_seconds) - (QUEUE_MAX_AGE_HOURS * 3600) ))")"

# At most this many recovered events go back into the queue per run. The rest
# stay dead-lettered and are picked up by the next handshake, so a machine that
# was disconnected for days drains over several sessions instead of opening with
# a burst of requests at an API that has just started accepting it again.
REPLAY_MAX_EVENTS="${AGENTMAGNIFY_REPLAY_MAX_EVENTS:-200}"

# And no faster than this, however often a session is opened. Recovery runs on
# a successful handshake, and nothing stops a script from opening sessions in a
# loop; without this that loop is a replay loop.
REPLAY_MIN_INTERVAL_SECONDS="${AGENTMAGNIFY_REPLAY_MIN_INTERVAL_SECONDS:-300}"

if ! at_have_token; then
  at_warn "AGENTMAGNIFY_TOKEN is not set; $(at_pending_count) event(s) stay queued"
  exit 0
fi

# A session queued offline has no server-side counterpart. Upgrade it first, so
# the queued events land in the right project.
if ! at_load_session || [ "${AT_SESSION_ONLINE:-}" != "true" ]; then
  if [ "${AT_SKIP_SESSION_UPGRADE:-0}" = "1" ]; then
    at_debug "session upgrade skipped (already inside start-session.sh)"
  else
    at_info "no live session; opening one before flushing the queue"
    AT_SKIP_QUEUE_FLUSH=1 "$AT_LIB_DIR/start-session.sh" --quiet >/dev/null 2>&1 || true
  fi
  at_load_session || true
fi

if [ "${AT_SESSION_ONLINE:-}" != "true" ]; then
  at_warn "still offline; $(at_pending_count) event(s) stay queued"
  exit 0
fi

if [ "$DRY_RUN" = "1" ]; then
  printf 'pending=%s dead=%s sessionId=%s\n' \
    "$(at_pending_count)" "$(at_dead_letter_count)" "$AT_SESSION_ID"
  exit 0
fi

# ---------------------------------------------------------------------------
# Recovery
# ---------------------------------------------------------------------------

# Moves the recoverable half of the dead-letter file back into the pending
# queue, and then does nothing else: the queue drain below is the only sender,
# so replayed events get the same batching, the same idempotency keys, the same
# session-id rewriting and the same age ceiling as everything else. A second
# sending path would be a second place for all of that to drift.
#
# What counts as recoverable, and why, is at_partition_dead_letters in lib.sh.
# This function owns the parts that need the machine's state rather than the
# rule: the interval, the lock, and putting each half back where it belongs.
#
# It runs only after the session upgrade above succeeded, which is the point:
# that handshake is the evidence that a credential is being accepted again.
# Replaying before it would send every held event straight back into the same
# 401 that put it here.
replay_dead_letters() {
  [ -s "$AT_DEAD_LETTER_FILE" ] || return 0

  local last_run elapsed
  if [ -f "$AT_REPLAY_STAMP_FILE" ]; then
    last_run="$(cat "$AT_REPLAY_STAMP_FILE" 2>/dev/null || printf '0')"
    case "$last_run" in
      ''|*[!0-9]*) last_run=0 ;;
    esac
    elapsed=$(( $(at_epoch_seconds) - last_run ))
    if [ "$elapsed" -lt "$REPLAY_MIN_INTERVAL_SECONDS" ]; then
      at_debug "dead-letter replay ran ${elapsed}s ago; waiting for the ${REPLAY_MIN_INTERVAL_SECONDS}s interval"
      return 0
    fi
  fi

  local work keep requeue counts recovered aged_out
  work="$(at_mktemp)"
  keep="$(at_mktemp)"
  requeue="$(at_mktemp)"

  at_lock || true
  cp "$AT_DEAD_LETTER_FILE" "$work"
  : > "$AT_DEAD_LETTER_FILE"
  at_unlock

  counts="$(at_partition_dead_letters "$work" "$requeue" "$keep" \
    "$REPLAY_MAX_EVENTS" "$OLDEST_ALLOWED" "$QUEUE_MAX_AGE_HOURS")"
  recovered="${counts#recovered=}"
  recovered="${recovered%% *}"
  aged_out="${counts##*aged=}"
  # Whatever went wrong in there, this function must not be the thing that ends
  # the flush: the queue drain below is the part that matters.
  case "$recovered" in ''|*[!0-9]*) recovered=0 ;; esac
  case "$aged_out" in ''|*[!0-9]*) aged_out=0 ;; esac

  # Recovered events are older than anything currently queued, so they go in
  # front of it and the timeline stays in order.
  if [ -s "$requeue" ]; then
    at_lock || true
    if [ -s "$AT_PENDING_FILE" ]; then
      cat "$AT_PENDING_FILE" >> "$requeue"
    fi
    cp "$requeue" "$AT_PENDING_FILE"
    at_unlock
  fi

  if [ -s "$keep" ]; then
    at_lock || true
    if [ -s "$AT_DEAD_LETTER_FILE" ]; then
      cat "$AT_DEAD_LETTER_FILE" >> "$keep"
    fi
    cp "$keep" "$AT_DEAD_LETTER_FILE"
    at_unlock
  fi

  printf '%s\n' "$(at_epoch_seconds)" > "$AT_REPLAY_STAMP_FILE"

  if [ "$recovered" -gt 0 ] || [ "$aged_out" -gt 0 ]; then
    at_info "dead-letter replay: $recovered event(s) requeued, $aged_out too old to replay, $(at_dead_letter_count) still held"
  else
    at_debug "dead-letter replay: nothing recoverable"
  fi
}

if [ "$REPLAY" = "1" ]; then
  replay_dead_letters
fi

if [ ! -s "$AT_PENDING_FILE" ]; then
  at_debug "nothing queued"
  exit 0
fi

MAX_BATCH="$(at_max_batch_size)"

# Take ownership of the current queue. Events reported while this runs append to
# a fresh file and are picked up by the next flush.
WORK_FILE="$(at_mktemp)"
at_lock || true
cp "$AT_PENDING_FILE" "$WORK_FILE"
: > "$AT_PENDING_FILE"
at_unlock

KEEP_FILE="$(at_mktemp)"
: > "$KEEP_FILE"

TOTAL_ACCEPTED=0
TOTAL_DUPLICATE=0
TOTAL_DEAD=0
TOTAL_KEPT=0
STOP_FLUSHING=0

batch_results() {
  local file="$1"
  local tool
  tool="$(at_json_tool)" || return 1
  if [ "$tool" = "jq" ]; then
    jq -r '.results[]? | [.eventId, (.accepted | tostring), ((.duplicate // false) | tostring), (.error.code // "")] | @tsv' "$file" 2>/dev/null || true
  else
    python3 - "$file" <<'PYEOF' 2>/dev/null || true
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for row in data.get('results', []):
    print("\t".join([
        str(row.get('eventId', '')),
        'true' if row.get('accepted') else 'false',
        'true' if row.get('duplicate') else 'false',
        (row.get('error') or {}).get('code', '') or '',
    ]))
PYEOF
  fi
}

is_permanent_error_code() {
  case "$1" in
    RATE_LIMITED|INTERNAL_ERROR|'') return 1 ;;
    *) return 0 ;;
  esac
}

TOTAL_LINES="$(wc -l < "$WORK_FILE" | tr -d ' ')"
LINE_CURSOR=0

while [ "$LINE_CURSOR" -lt "$TOTAL_LINES" ]; do
  CHUNK_FILE="$(at_mktemp)"
  CHUNK_IDS="$(at_mktemp)"
  REQUEST_FILE="$(at_mktemp)"
  : > "$CHUNK_FILE"
  : > "$CHUNK_IDS"

  CHUNK_COUNT=0
  START_LINE=$(( LINE_CURSOR + 1 ))
  END_LINE=$(( LINE_CURSOR + MAX_BATCH ))
  if [ "$END_LINE" -gt "$TOTAL_LINES" ]; then
    END_LINE="$TOTAL_LINES"
  fi

  EVENT_TMP="$(at_mktemp)"
  LINE_NUMBER=0
  while IFS= read -r LINE; do
    LINE_NUMBER=$(( LINE_NUMBER + 1 ))
    [ "$LINE_NUMBER" -ge "$START_LINE" ] || continue
    [ "$LINE_NUMBER" -le "$END_LINE" ] || break
    [ -n "$LINE" ] || continue

    printf '%s\n' "$LINE" > "$EVENT_TMP"
    if ! at_json_valid "$EVENT_TMP"; then
      at_warn "dropping a queue line that is not valid JSON"
      printf '%s\n' "$LINE" >> "$AT_DEAD_LETTER_FILE"
      TOTAL_DEAD=$(( TOTAL_DEAD + 1 ))
      continue
    fi

    EVENT_ID="$(at_json_get "$EVENT_TMP" 'eventId')"
    EVENT_SESSION="$(at_json_get "$EVENT_TMP" 'sessionId')"
    EVENT_TIMESTAMP="$(at_json_get "$EVENT_TMP" 'timestamp')"

    if [ -n "$OLDEST_ALLOWED" ] && [ -n "$EVENT_TIMESTAMP" ] && [ "$EVENT_TIMESTAMP" \< "$OLDEST_ALLOWED" ]; then
      at_warn "event $EVENT_ID has been queued for more than $QUEUE_MAX_AGE_HOURS hours; moving it to the dead-letter file"
      at_dead_letter_event "$EVENT_TMP" "queued longer than $QUEUE_MAX_AGE_HOURS hours" expired
      TOTAL_DEAD=$(( TOTAL_DEAD + 1 ))
      continue
    fi

    case "$EVENT_SESSION" in
      ses_local_*|'')
        at_json_set "$EVENT_TMP" str sessionId "$AT_SESSION_ID"
        if [ -n "$AT_PROJECT_ID" ]; then
          at_json_set "$EVENT_TMP" str projectId "$AT_PROJECT_ID"
        fi
        ;;
    esac

    at_json_compact "$EVENT_TMP" >> "$CHUNK_FILE"
    printf '%s\n' "$EVENT_ID" >> "$CHUNK_IDS"
    CHUNK_COUNT=$(( CHUNK_COUNT + 1 ))
  done < "$WORK_FILE"

  LINE_CURSOR="$END_LINE"

  if [ "$CHUNK_COUNT" -eq 0 ]; then
    continue
  fi

  {
    printf '{"sessionId":'
    at_json_quote "$AT_SESSION_ID"
    printf ',"events":['
    FIRST=1
    while IFS= read -r EVENT_LINE; do
      [ -n "$EVENT_LINE" ] || continue
      if [ "$FIRST" = "1" ]; then
        FIRST=0
      else
        printf ','
      fi
      printf '%s' "$EVENT_LINE"
    done < "$CHUNK_FILE"
    printf ']}'
  } > "$REQUEST_FILE"

  if ! at_json_valid "$REQUEST_FILE"; then
    at_error "built an invalid batch request; keeping the events queued"
    cat "$CHUNK_FILE" >> "$KEEP_FILE"
    TOTAL_KEPT=$(( TOTAL_KEPT + CHUNK_COUNT ))
    STOP_FLUSHING=1
    break
  fi

  RESPONSE_FILE="$(at_mktemp)"
  STATUS="$(at_http_request POST /v1/events/batch "$REQUEST_FILE" "$RESPONSE_FILE")"

  if ! at_status_is_success "$STATUS"; then
    if at_status_is_permanent_failure "$STATUS"; then
      BATCH_KIND="$(at_dead_letter_kind_for_status "$STATUS")"
      if [ "$BATCH_KIND" = "credential" ]; then
        at_error "the monitoring credential was not accepted (HTTP $STATUS); $CHUNK_COUNT event(s) are being held, not discarded"
        at_error "run: bash scripts/pair.sh   (the next session sends them automatically)"
      else
        at_error "batch rejected: HTTP $STATUS $(at_error_message "$RESPONSE_FILE")"
      fi
      while IFS= read -r EVENT_LINE; do
        [ -n "$EVENT_LINE" ] || continue
        printf '%s\n' "$EVENT_LINE" > "$EVENT_TMP"
        at_dead_letter_event "$EVENT_TMP" "batch rejected with HTTP $STATUS" "$BATCH_KIND"
        TOTAL_DEAD=$(( TOTAL_DEAD + 1 ))
      done < "$CHUNK_FILE"
    else
      at_warn "batch could not be delivered (HTTP $STATUS); keeping $CHUNK_COUNT event(s) queued"
      cat "$CHUNK_FILE" >> "$KEEP_FILE"
      TOTAL_KEPT=$(( TOTAL_KEPT + CHUNK_COUNT ))
      STOP_FLUSHING=1
    fi
    break
  fi

  RESULTS_FILE="$(at_mktemp)"
  batch_results "$RESPONSE_FILE" > "$RESULTS_FILE"

  if [ ! -s "$RESULTS_FILE" ]; then
    # A 2xx without a per-event breakdown means the whole batch was taken.
    ACCEPTED_IN_BATCH="$(at_json_get "$RESPONSE_FILE" 'accepted')"
    at_info "batch of $CHUNK_COUNT event(s) accepted (${ACCEPTED_IN_BATCH:-$CHUNK_COUNT} recorded)"
    TOTAL_ACCEPTED=$(( TOTAL_ACCEPTED + CHUNK_COUNT ))
    continue
  fi

  # Walk the chunk and the per-event results together.
  RESULT_INDEX=0
  while IFS= read -r EVENT_LINE; do
    [ -n "$EVENT_LINE" ] || continue
    RESULT_INDEX=$(( RESULT_INDEX + 1 ))
    RESULT_ROW="$(sed -n "${RESULT_INDEX}p" "$RESULTS_FILE")"
    RESULT_ACCEPTED="$(printf '%s' "$RESULT_ROW" | cut -f2)"
    RESULT_DUPLICATE="$(printf '%s' "$RESULT_ROW" | cut -f3)"
    RESULT_ERROR="$(printf '%s' "$RESULT_ROW" | cut -f4)"

    if [ "$RESULT_ACCEPTED" = "true" ]; then
      if [ "$RESULT_DUPLICATE" = "true" ]; then
        TOTAL_DUPLICATE=$(( TOTAL_DUPLICATE + 1 ))
      else
        TOTAL_ACCEPTED=$(( TOTAL_ACCEPTED + 1 ))
      fi
      continue
    fi

    if [ "$RESULT_DUPLICATE" = "true" ]; then
      TOTAL_DUPLICATE=$(( TOTAL_DUPLICATE + 1 ))
      continue
    fi

    printf '%s\n' "$EVENT_LINE" > "$EVENT_TMP"
    if is_permanent_error_code "$RESULT_ERROR"; then
      at_error "event rejected permanently (${RESULT_ERROR:-unknown}); moved to the dead-letter file"
      # Always `payload`, whatever the code says. The batch itself was accepted,
      # so the credential was accepted; a per-event UNAUTHORIZED or FORBIDDEN in
      # here is about what this event claimed, not about who sent it.
      at_dead_letter_event "$EVENT_TMP" "${RESULT_ERROR:-REJECTED}" payload
      TOTAL_DEAD=$(( TOTAL_DEAD + 1 ))
    else
      printf '%s\n' "$EVENT_LINE" >> "$KEEP_FILE"
      TOTAL_KEPT=$(( TOTAL_KEPT + 1 ))
    fi
  done < "$CHUNK_FILE"
done

# Whatever the loop never reached - because a batch failed - is still owed.
if [ "$LINE_CURSOR" -lt "$TOTAL_LINES" ]; then
  sed -n "$(( LINE_CURSOR + 1 )),\$p" "$WORK_FILE" >> "$KEEP_FILE"
  TOTAL_KEPT=$(( TOTAL_KEPT + (TOTAL_LINES - LINE_CURSOR) ))
fi

# Anything still owed goes back to the front of the queue, before whatever was
# reported while this flush was running.
if [ -s "$KEEP_FILE" ]; then
  at_lock || true
  if [ -s "$AT_PENDING_FILE" ]; then
    cat "$AT_PENDING_FILE" >> "$KEEP_FILE"
  fi
  cp "$KEEP_FILE" "$AT_PENDING_FILE"
  at_unlock
fi

at_info "flush finished: $TOTAL_ACCEPTED accepted, $TOTAL_DUPLICATE duplicate, $TOTAL_DEAD dead-lettered, $TOTAL_KEPT still queued"
printf 'accepted=%s duplicate=%s dead=%s queued=%s\n' \
  "$TOTAL_ACCEPTED" "$TOTAL_DUPLICATE" "$TOTAL_DEAD" "$TOTAL_KEPT"

if [ "$STOP_FLUSHING" = "1" ]; then
  exit 0
fi
exit 0
