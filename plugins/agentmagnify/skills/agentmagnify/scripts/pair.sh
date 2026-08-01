#!/usr/bin/env bash
#
# pair.sh - get a monitoring token without anybody copying a secret.
#
# Asks the API to start a pairing, prints a short code and a URL, and waits.
# Somebody signed in to the panel types that code, sees what is being paired and
# what it will be able to do, and approves it. The token then arrives here, over
# the connection this script already has open, and is written to the same
# credentials file login.sh writes.
#
# Nothing is ever displayed for you to copy. That is the whole point: a secret
# read off a screen and pasted into a terminal is a secret in shell history, in
# scrollback, and in every screenshot of that window afterwards.
#
# The two halves of the pairing are not worth the same thing:
#
#   The CODE ON SCREEN is eight characters, because a person types it. Somebody
#   who overhears it can bring your pending pairing up on the approval screen
#   and refuse it, which costs you running this command again. They cannot
#   collect the token with it.
#
#   The DEVICE CODE is 256 bits, is never printed, never touches the disk, and
#   exists only in this process's memory until it is exchanged. It is the half
#   that is worth something, and no human ever handles it.
#
# Usage: pair.sh [--api-url URL] [--project] [--timeout SECONDS]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'USAGE'
Usage: pair.sh [--api-url URL] [--project] [--timeout SECONDS]

  --api-url URL      monitoring API base URL (default: http://localhost:4000)
  --project          store the token for THIS project only, in
                     .agentmagnify.local.json, instead of once per machine
  --timeout SECONDS  give up waiting for approval (default: 600)

Run this, read out the code it prints, and have somebody approve it in the
panel. No token is shown here or there.

No browser and nobody to approve -- a CI runner, a container? Use a token from
the panel's Tokens screen instead, through AGENTMAGNIFY_TOKEN or login.sh.
That path is unchanged and is still the right one there.
USAGE
}

API_URL=""
SCOPE="user"
TIMEOUT_SECONDS=600

while [ "$#" -gt 0 ]; do
  case "$1" in
    --api-url) [ "$#" -ge 2 ] || at_die "--api-url requires a value"; API_URL="$2"; shift 2 ;;
    --project) SCOPE="project"; shift ;;
    --timeout) [ "$#" -ge 2 ] || at_die "--timeout requires a value"; TIMEOUT_SECONDS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) at_die "unknown option: $1" ;;
  esac
done

case "$TIMEOUT_SECONDS" in
  ''|*[!0-9]*) at_die "--timeout takes a whole number of seconds" ;;
esac

at_require_deps

API_URL="${API_URL:-${AGENTMAGNIFY_API_URL:-http://localhost:4000}}"
API_URL="${API_URL%/}"

# Loaded with the token deliberately cleared. A machine that already has a
# credential can still pair -- somebody replacing a rotated token, say -- and
# the requests below must go out unauthenticated either way, because the
# pairing endpoints are the ones that exist precisely for a caller with nothing.
AGENTMAGNIFY_TOKEN=""
AGENTMAGNIFY_API_URL="$API_URL"
export AGENTMAGNIFY_TOKEN AGENTMAGNIFY_API_URL
at_load_config || exit 1
AGENTMAGNIFY_TOKEN=""
export AGENTMAGNIFY_TOKEN

# What the approval screen will show. None of it is trusted by the server -- it
# is shown so that a person who did not just run this command has something
# concrete to disagree with, which is the only defence against somebody being
# talked into approving a stranger's pairing.
DEVICE_LABEL="${AGENTMAGNIFY_DEVICE_LABEL:-}"
if [ -z "$DEVICE_LABEL" ]; then
  DEVICE_LABEL="$(id -un 2>/dev/null || printf 'unknown')@$(hostname 2>/dev/null || printf 'unknown-host')"
fi

request_file="$(at_mktemp)"
response_file="$(at_mktemp)"

{
  printf '{'
  printf '"deviceLabel":%s,' "$(at_json_quote "$DEVICE_LABEL")"
  printf '"clientName":%s,' "$(at_json_quote "$AT_CLIENT_NAME")"
  printf '"clientVersion":%s,' "$(at_json_quote "$AT_CLIENT_VERSION")"
  printf '"projectHint":%s' "$(at_json_quote "$AT_PROJECT_NAME")"
  printf '}'
} > "$request_file"

status="$(at_http_request POST "/v1/pairings" "$request_file" "$response_file")"

if ! at_status_is_success "$status"; then
  if [ "$status" = "000" ]; then
    at_error "could not reach the monitoring API at $API_URL"
  else
    at_error "could not start pairing ($status): $(at_error_message "$response_file")"
  fi
  exit 1
fi

DEVICE_CODE="$(at_json_get "$response_file" 'deviceCode')"
USER_CODE="$(at_json_get "$response_file" 'userCode')"
VERIFY_URL="$(at_json_get "$response_file" 'verificationUri')"
INTERVAL="$(at_json_get "$response_file" 'intervalSeconds')"
case "$INTERVAL" in
  ''|*[!0-9]*) INTERVAL=5 ;;
esac

# The device code must not survive this process. The response file is a
# temporary that at_cleanup_temp removes on exit, but it holds the one secret
# worth holding, so it is truncated the moment it has been read rather than
# left lying around for however long this script waits.
: > "$response_file"

if [ -z "$DEVICE_CODE" ] || [ -z "$USER_CODE" ]; then
  at_die "the API did not return a pairing; check that $API_URL is the monitoring API"
fi

printf '\n'
printf 'Pair this machine\n'
printf '  1. Open   %s\n' "$VERIFY_URL"
printf '  2. Sign in, then enter this code:\n'
printf '\n'
printf '        %s\n' "$USER_CODE"
printf '\n'
printf '  3. Check that the screen names this machine (%s) and the workspace\n' "$DEVICE_LABEL"
printf '     you meant, then approve.\n'
printf '\n'
printf 'This code alone cannot grant anything. Waiting for approval'
printf ' (up to %s seconds)...\n' "$TIMEOUT_SECONDS"

poll_file="$(at_mktemp)"
poll_body="$(at_mktemp)"
printf '{"deviceCode":%s}' "$(at_json_quote "$DEVICE_CODE")" > "$poll_body"
chmod 600 "$poll_body" 2>/dev/null || true

DEADLINE=$(( $(at_epoch_seconds) + TIMEOUT_SECONDS ))
TOKEN=""

while : ; do
  if [ "$(at_epoch_seconds)" -ge "$DEADLINE" ]; then
    at_error "gave up waiting for approval"
    at_error "the pairing has expired; run this again when somebody is at the panel"
    exit 1
  fi

  sleep "$INTERVAL"

  poll_status="$(at_http_request POST "/v1/pairings/token" "$poll_body" "$poll_file")"

  # A 429 here is the server pacing us, not a failure. at_http_request has
  # already retried with backoff; waiting another interval is the whole handling.
  if [ "$poll_status" = "429" ]; then
    continue
  fi

  if ! at_status_is_success "$poll_status"; then
    if [ "$poll_status" = "000" ]; then
      at_debug "API unreachable while polling; will try again"
      continue
    fi
    at_error "pairing failed ($poll_status): $(at_error_message "$poll_file")"
    exit 1
  fi

  pair_status="$(at_json_get "$poll_file" 'status')"
  case "$pair_status" in
    pending)
      continue
      ;;
    denied)
      # Deliberately a different message from the timeout one. Somebody looked
      # at this and said no; running the command again is not the answer.
      at_error "the pairing was refused in the panel"
      at_error "no token was issued. Ask whoever refused it what they saw."
      exit 1
      ;;
    expired)
      at_error "the pairing expired before it was approved"
      at_error "run this again and have somebody ready at the panel"
      exit 1
      ;;
    approved)
      TOKEN="$(at_json_get "$poll_file" 'token.token')"
      WORKSPACE_NAME="$(at_json_get "$poll_file" 'workspaceName')"
      TOKEN_KIND="$(at_json_get "$poll_file" 'token.kind')"
      TOKEN_NAME="$(at_json_get "$poll_file" 'token.name')"
      : > "$poll_file"
      break
      ;;
    *)
      at_error "the API answered with an unrecognised pairing status '$pair_status'"
      exit 1
      ;;
  esac
done

[ -n "$TOKEN" ] || at_die "the pairing was approved but no token came back; try again"

write_json() {
  local target="$1"
  umask 077
  cat > "$target" <<JSON
{
  "apiUrl": "$API_URL",
  "token": "$TOKEN"
}
JSON
  chmod 600 "$target"
}

if [ "$SCOPE" = "project" ]; then
  write_json "$AT_PROJECT_SECRET_NAME"
  at_info "stored for this project in $AT_PROJECT_SECRET_NAME"

  # A project-local secret that is not ignored is one commit away from a leak.
  if [ -d .git ] && ! git check-ignore -q "$AT_PROJECT_SECRET_NAME" 2>/dev/null; then
    printf '%s\n' "$AT_PROJECT_SECRET_NAME" >> .gitignore
    at_info "added $AT_PROJECT_SECRET_NAME to .gitignore"
  fi
else
  mkdir -p "$(dirname "$AT_CREDENTIALS_FILE")"
  chmod 700 "$(dirname "$AT_CREDENTIALS_FILE")" 2>/dev/null || true
  write_json "$AT_CREDENTIALS_FILE"
  at_info "stored for every project on this machine in $AT_CREDENTIALS_FILE"
fi

# The token is not printed, here or anywhere. Its kind and where it points are
# what a person needs in order to know the pairing did what they approved.
printf '\n'
printf 'Paired.\n'
printf 'Workspace    : %s\n' "${WORKSPACE_NAME:-unknown}"
printf 'Token        : %s (%s)\n' "${TOKEN_NAME:-unnamed}" "${TOKEN_KIND:-unknown}"
printf 'Project name : %s\n' "$AT_PROJECT_NAME"
printf '\n'
printf 'Revoke it from the panel any time; the Tokens screen lists it by that name.\n'

# Once, at the end of the one command a person runs by hand. Not in the
# reporting scripts: those run dozens of times a session, and a tool that thanks
# you on every event is a tool whose output people stop reading -- including the
# lines that say something went wrong.
printf '\n'
printf 'Thank you for using AgentMagnify.\n'
