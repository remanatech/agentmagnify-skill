#!/usr/bin/env bash
#
# fetch-schema.sh - download the protocol bundle (JSON Schema + reporting
# policy + agent instructions) and cache it in state/schema.json.
#
# Cache and fallback behaviour follows doc 13.7:
#
#   API reachable                 -> fetch, store body and ETag
#   API answers 304 Not Modified  -> keep the cached bundle
#   API unreachable, cache valid  -> use the cache, keep reporting
#   API unreachable, cache stale  -> use the cache anyway, mark the session
#                                    "unverified protocol"
#   API unreachable, no cache     -> copy references/fallback-schema.json and
#                                    mark the session "unverified protocol"
#
# Development is never blocked by this script; it always exits 0 unless its own
# dependencies are missing.
#
# Usage: fetch-schema.sh [--version 2026-07-31.1] [--force]

set -euo pipefail

# shellcheck source=./lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

PROTOCOL_VERSION="latest"
FORCE=0
CACHE_MAX_AGE_SECONDS="${AGENTMAGNIFY_SCHEMA_MAX_AGE:-604800}"   # 7 days

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      [ "$#" -ge 2 ] || at_die "--version requires a value"
      PROTOCOL_VERSION="$2"
      shift 2
      ;;
    --force) FORCE=1; shift ;;
    -h|--help)
      printf 'Usage: fetch-schema.sh [--version VERSION|latest] [--force]\n'
      exit 0
      ;;
    *) at_die "unknown option '$1'" ;;
  esac
done

at_load_config
at_require_deps || exit 1

mark_unverified() {
  local reason="$1"
  at_warn "protocol could not be verified against the API: $reason"
  if [ -f "$AT_SESSION_FILE" ]; then
    at_set_session_field bool protocolVerified false || true
    at_set_session_field str protocolStatus "unverified protocol" || true
  fi
  printf 'unverified\n' > "$AT_STATE_DIR/protocol-status"
}

mark_verified() {
  if [ -f "$AT_SESSION_FILE" ]; then
    at_set_session_field bool protocolVerified true || true
    at_set_session_field str protocolStatus "verified" || true
  fi
  printf 'verified\n' > "$AT_STATE_DIR/protocol-status"
}

install_fallback() {
  if [ ! -f "$AT_FALLBACK_SCHEMA" ]; then
    at_error "references/fallback-schema.json is missing; cannot continue"
    return 1
  fi
  cp "$AT_FALLBACK_SCHEMA" "$AT_SCHEMA_FILE"
  : > "$AT_SCHEMA_ETAG_FILE"
  printf '0\n' > "$AT_SCHEMA_FETCHED_FILE"
  at_warn "using the bundled fallback schema; live reporting rules may be out of date"
  mark_unverified "no cached bundle and the API is unreachable"
  at_json_get "$AT_SCHEMA_FILE" 'protocolVersion'
  return 0
}

cache_age_seconds() {
  if [ ! -f "$AT_SCHEMA_FETCHED_FILE" ]; then
    printf '999999999'
    return 0
  fi
  local fetched
  fetched="$(cat "$AT_SCHEMA_FETCHED_FILE" 2>/dev/null || printf '0')"
  case "$fetched" in
    ''|*[!0-9]*) fetched=0 ;;
  esac
  printf '%s' "$(( $(at_epoch_seconds) - fetched ))"
}

use_cache_or_fallback() {
  local reason="$1"
  if [ -f "$AT_SCHEMA_FILE" ]; then
    local age
    age="$(cache_age_seconds)"
    if [ "$age" -le "$CACHE_MAX_AGE_SECONDS" ]; then
      at_info "API unreachable ($reason); using the cached protocol bundle"
      at_json_get "$AT_SCHEMA_FILE" 'protocolVersion'
      return 0
    fi
    at_warn "cached protocol bundle is older than $CACHE_MAX_AGE_SECONDS seconds"
    mark_unverified "$reason, cache expired"
    at_json_get "$AT_SCHEMA_FILE" 'protocolVersion'
    return 0
  fi
  install_fallback
}

if [ "$FORCE" = "0" ] && [ -f "$AT_SCHEMA_FILE" ] && [ "$PROTOCOL_VERSION" != "latest" ]; then
  CACHED_VERSION="$(at_json_get "$AT_SCHEMA_FILE" 'protocolVersion')"
  if [ "$CACHED_VERSION" = "$PROTOCOL_VERSION" ] && [ "$(cache_age_seconds)" -le "$CACHE_MAX_AGE_SECONDS" ]; then
    at_debug "protocol bundle $PROTOCOL_VERSION already cached"
    printf '%s\n' "$CACHED_VERSION"
    exit 0
  fi
fi

if ! at_have_token; then
  at_warn "AGENTMAGNIFY_TOKEN is not set; cannot fetch the protocol bundle"
  use_cache_or_fallback "no token"
  exit 0
fi

if [ "$PROTOCOL_VERSION" = "latest" ]; then
  REQUEST_PATH="/v1/protocols/latest"
else
  REQUEST_PATH="/v1/protocols/$PROTOCOL_VERSION"
fi

EXTRA_HEADER=""
if [ "$FORCE" = "0" ] && [ -s "$AT_SCHEMA_ETAG_FILE" ] && [ -f "$AT_SCHEMA_FILE" ]; then
  EXTRA_HEADER="If-None-Match: $(cat "$AT_SCHEMA_ETAG_FILE")"
fi

BODY_FILE="$(at_mktemp)"
HEADER_FILE="$(at_mktemp)"
STATUS="$(at_http_request GET "$REQUEST_PATH" "" "$BODY_FILE" "" "$EXTRA_HEADER" "$HEADER_FILE")"

if [ "$STATUS" = "304" ]; then
  at_info "protocol bundle unchanged (304); keeping the cached copy"
  printf '%s\n' "$(at_epoch_seconds)" > "$AT_SCHEMA_FETCHED_FILE"
  mark_verified
  at_json_get "$AT_SCHEMA_FILE" 'protocolVersion'
  exit 0
fi

if ! at_status_is_success "$STATUS"; then
  if at_status_is_permanent_failure "$STATUS"; then
    at_error "protocol request failed: HTTP $STATUS $(at_error_message "$BODY_FILE")"
  fi
  use_cache_or_fallback "HTTP $STATUS"
  exit 0
fi

if ! at_json_valid "$BODY_FILE"; then
  at_error "protocol endpoint returned something that is not JSON"
  use_cache_or_fallback "invalid response body"
  exit 0
fi

VERSION="$(at_json_get "$BODY_FILE" 'protocolVersion')"
if [ -z "$VERSION" ]; then
  at_error "protocol bundle has no protocolVersion field"
  use_cache_or_fallback "malformed bundle"
  exit 0
fi

cp "$BODY_FILE" "$AT_SCHEMA_FILE"
printf '%s\n' "$(at_epoch_seconds)" > "$AT_SCHEMA_FETCHED_FILE"

ETAG="$(grep -i '^etag:' "$HEADER_FILE" 2>/dev/null | tail -n 1 | sed -E 's/^[Ee][Tt][Aa][Gg]:[[:space:]]*//' | tr -d '\r' || true)"
if [ -n "$ETAG" ]; then
  printf '%s' "$ETAG" > "$AT_SCHEMA_ETAG_FILE"
else
  : > "$AT_SCHEMA_ETAG_FILE"
fi

mark_verified
at_info "cached protocol bundle $VERSION"
printf '%s\n' "$VERSION"
exit 0
