#!/usr/bin/env bash
# Stores a monitoring token once, for every project on this machine.
#
# The token never goes into the repository: it is written to the user-level
# credentials file with 0600 permissions, the same shape gh/aws/npm use. A
# project only ever commits its name, never its secret.
#
# This takes a token you already hold, which means somebody copied it out of a
# browser. `pair.sh` is the path that avoids that step entirely and is the one
# to reach for where there is a person and a browser. This one stays for where
# there is not: CI, containers, and anywhere the credential arrives from a
# secret store rather than from a screen.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'USAGE'
Usage: login.sh <token> [--api-url URL] [--project] [--status] [--logout]

  <token>            prj_live_… , wsi_live_… or ro_live_… from the panel
  --api-url URL      monitoring API base URL (default: http://localhost:4000)
  --project          store it for THIS project only, in .agentmagnify.local.json
  --status           show where a token would be read from, without printing it
  --logout           remove the stored credential

With no --project flag the token is stored once per machine and every project
reuses it. A workspace ingestion token (wsi_live_…) is the one to use there:
projects are created on first contact, so a new repository needs no setup at
all. Use a project token (prj_live_…) with --project, or in CI, when the
credential should only ever reach one project.

If you are about to copy a token out of the panel to paste here, run
`pair.sh` instead: it gets the same token without one ever being shown.
USAGE
}

TOKEN=""
API_URL=""
SCOPE="user"
MODE="login"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --api-url) [ "$#" -ge 2 ] || at_die "--api-url requires a value"; API_URL="$2"; shift 2 ;;
    --project) SCOPE="project"; shift ;;
    --status) MODE="status"; shift ;;
    --logout) MODE="logout"; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) at_die "unknown option: $1" ;;
    *) [ -n "$TOKEN" ] && at_die "unexpected argument: $1"; TOKEN="$1"; shift ;;
  esac
done

at_require_deps

if [ "$MODE" = "status" ]; then
  at_load_config || exit 1
  found=1
  if at_have_token; then
    found=0
    printf 'Token source : %s\n' "${AT_CONFIG_SOURCE:-unknown}"
    printf 'Token kind   : %s\n' "$(at_token_kind)"
  else
    printf 'Token source : none found\n'
    # "none found" and "found, under the name this package used before the
    # rename" look identical from here, and only one of them is fixed by
    # pairing again. Say which it is.
    at_legacy_setup_hints || true
  fi
  printf 'API URL      : %s\n' "$AT_API_URL"
  printf 'Project name : %s\n' "$AT_PROJECT_NAME"
  # Exits non-zero when nothing resolved, so a caller can branch on the result
  # instead of matching on the wording of a line meant for a person to read.
  # SKILL.md tells the agent to decide whether to activate on exactly this.
  exit "$found"
fi

if [ "$MODE" = "logout" ]; then
  removed=0
  if [ "$SCOPE" = "project" ]; then
    if [ -f "$AT_PROJECT_SECRET_NAME" ]; then rm -f "$AT_PROJECT_SECRET_NAME"; removed=1; fi
  elif [ -f "$AT_CREDENTIALS_FILE" ]; then
    rm -f "$AT_CREDENTIALS_FILE"; removed=1
  fi
  [ "$removed" -eq 1 ] && at_info "credential removed" || at_info "no stored credential to remove"
  exit 0
fi

[ -n "$TOKEN" ] || { usage; exit 1; }

case "$TOKEN" in
  prj_live_*|wsi_live_*|ro_live_*) ;;
  *) at_die "that does not look like a monitoring token (expected prj_live_…, wsi_live_… or ro_live_…)" ;;
esac

API_URL="${API_URL:-${AGENTMAGNIFY_API_URL:-http://localhost:4000}}"
API_URL="${API_URL%/}"

# Prove the token works before storing it. Writing a dead credential and only
# finding out during a real session is a bad first experience.
AGENTMAGNIFY_TOKEN="$TOKEN"
AGENTMAGNIFY_API_URL="$API_URL"
export AGENTMAGNIFY_TOKEN AGENTMAGNIFY_API_URL
at_load_config || exit 1

probe="$(at_mktemp)"
if at_http_request GET "/v1/protocols/latest" "" "$probe" >/dev/null 2>&1; then
  at_debug "API reachable at $API_URL"
else
  at_error "could not reach the monitoring API at $API_URL"
  at_error "the token will still be stored; run --status once the API is up"
fi

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

printf 'Token kind   : %s\n' "$(at_token_kind)"
printf 'API URL      : %s\n' "$API_URL"
printf 'Project name : %s\n' "$AT_PROJECT_NAME"

case "$(at_token_kind)" in
  workspace_ingestion)
    printf '\nNothing else to set up. Every project reports under its own name;\n'
    printf 'a project that does not exist yet is created on first contact.\n'
    ;;
  project)
    printf '\nThis token is bound to one project. Commit a %s naming it\n' "$AT_PROJECT_CONFIG_NAME"
    printf 'if the inferred name "%s" is not what the panel calls it.\n' "$AT_PROJECT_NAME"
    ;;
  read_only)
    printf '\nThis is a read-only token; it cannot report events.\n'
    ;;
esac
