#!/usr/bin/env bash
#
# lib.sh - shared helpers for the agentmagnify skill scripts.
#
# This file is sourced by every other script in this directory; it is not meant
# to be executed on its own. It provides:
#
#   * configuration loading and dependency checks
#   * ULID-ish event id generation and RFC3339 UTC timestamps
#   * a monotonic, lock-protected per-session sequence counter
#   * JSON reading/writing helpers (jq or python3, whichever is present)
#   * curl with timeout, bounded retry and exponential backoff
#   * structured logging to stderr
#   * a local secret filter mirroring packages/contract/src/redaction.ts
#
# Design rules:
#   * the monitoring token is never printed and never passed on a command line
#   * nothing that the redactor would flag may leave this machine
#   * no helper here ever aborts the caller's real work because of a network
#     problem; failures degrade to the local queue

if [ -n "${AT_LIB_SOURCED:-}" ]; then
  return 0
fi
AT_LIB_SOURCED=1

# ---------------------------------------------------------------------------
# Where the service is
# ---------------------------------------------------------------------------

# The hosted API, and the default for every script here.
#
# It used to be http://localhost:4000, written out separately in lib.sh,
# login.sh and pair.sh. That was right while the only installation was the one
# on the developer's own machine and wrong the moment the service went live:
# somebody who runs `npx agentmagnify install` and then `pair.sh` has no
# monitoring API on their laptop, so the default pointed the entire onboarding
# path at a port nobody was listening on.
#
# Defined once because three copies of an address is three chances to move two
# of them. Self-hosted installations set AGENTMAGNIFY_API_URL, and local
# development passes --api-url http://localhost:4000, which is what the
# repository's own instructions have always done.
AT_DEFAULT_API_URL="https://api.agentmagnify.com"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

AT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AT_SKILL_ROOT="$(cd "$AT_LIB_DIR/.." && pwd)"
AT_REFERENCE_DIR="$AT_SKILL_ROOT/references"
AT_STATE_DIR="${AGENTMAGNIFY_STATE_DIR:-$AT_SKILL_ROOT/state}"

AT_SESSION_FILE="$AT_STATE_DIR/session.json"
AT_SCHEMA_FILE="$AT_STATE_DIR/schema.json"
# shellcheck disable=SC2034  # read by fetch-schema.sh
AT_SCHEMA_ETAG_FILE="$AT_STATE_DIR/schema.etag"
# shellcheck disable=SC2034  # read by fetch-schema.sh
AT_SCHEMA_FETCHED_FILE="$AT_STATE_DIR/schema.fetched-at"
AT_PENDING_FILE="$AT_STATE_DIR/pending-events.jsonl"
AT_DEAD_LETTER_FILE="$AT_STATE_DIR/dead-letter.jsonl"
# When the dead-letter file was last replayed. Read by flush-pending-events.sh
# to keep a loop of handshakes from replaying the same queue over and over.
# shellcheck disable=SC2034
AT_REPLAY_STAMP_FILE="$AT_STATE_DIR/dead-letter.replayed-at"
AT_SEQUENCE_FILE="$AT_STATE_DIR/sequence"
# The heartbeat daemon's pid, so start-session.sh does not start a second one
# and complete-session.sh can stop the first.
# shellcheck disable=SC2034  # read by heartbeat-daemon.sh and its callers
AT_HEARTBEAT_PID_FILE="$AT_STATE_DIR/heartbeat.pid"

# Starts the heartbeat daemon, unless one is already running.
#
# Detached on purpose: it has to outlive the shell that starts it, because the
# shell is one tool call and the work is an hour. Verified that a nohup'd
# process keeps ticking across separate tool calls before this was written.
at_start_heartbeat() {
  [ "${AGENTMAGNIFY_HEARTBEAT:-1}" = "0" ] && return 0

  if [ -f "$AT_HEARTBEAT_PID_FILE" ]; then
    local running
    running="$(cat "$AT_HEARTBEAT_PID_FILE" 2>/dev/null || printf '')"
    if [ -n "$running" ] && kill -0 "$running" 2>/dev/null; then
      at_debug "heartbeat daemon already running (pid $running)"
      return 0
    fi
  fi

  nohup bash "$AT_LIB_DIR/heartbeat-daemon.sh" >/dev/null 2>&1 &
  local pid=$!
  disown "$pid" 2>/dev/null || true
  printf '%s\n' "$pid" > "$AT_HEARTBEAT_PID_FILE"
  at_debug "heartbeat daemon started (pid $pid)"
}

# Stops it. Called when a session ends, so that a finished session stops
# claiming to be alive -- which is the whole reason the daemon has an owner.
at_stop_heartbeat() {
  [ -f "$AT_HEARTBEAT_PID_FILE" ] || return 0
  local pid
  pid="$(cat "$AT_HEARTBEAT_PID_FILE" 2>/dev/null || printf '')"
  rm -f "$AT_HEARTBEAT_PID_FILE"
  [ -n "$pid" ] || return 0

  kill "$pid" 2>/dev/null

  # Checked, not assumed. `kill` returning 0 says the signal was delivered, not
  # that anything acted on it -- and a heartbeat daemon that outlives the
  # session it belongs to goes on claiming somebody is working. Waiting a
  # moment and escalating is the difference between stopping it and asking.
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    [ "$waited" -ge 3 ] && { kill -9 "$pid" 2>/dev/null; break; }
    sleep 1
    waited=$(( waited + 1 ))
  done

  at_debug "heartbeat daemon stopped"
}
AT_LOCK_DIR="$AT_STATE_DIR/.lock"
AT_FALLBACK_SCHEMA="$AT_REFERENCE_DIR/fallback-schema.json"

AT_CLIENT_NAME="agentmagnify-skill"
AT_CLIENT_VERSION="0.2.1"
AT_FALLBACK_PROTOCOL_VERSION="2026-07-31.1"

# ---------------------------------------------------------------------------
# Logging (always stderr, so stdout stays machine readable)
# ---------------------------------------------------------------------------

at_log() {
  local level="$1"
  shift
  printf '%s [%s] agentmagnify: %s\n' "$(at_now)" "$level" "$*" >&2
}

at_debug() {
  if [ "${AGENTMAGNIFY_DEBUG:-0}" = "1" ]; then
    at_log DEBUG "$@"
  fi
}

at_info() { at_log INFO "$@"; }
at_warn() { at_log WARN "$@"; }
at_error() { at_log ERROR "$@"; }

at_die() {
  at_error "$@"
  exit 1
}

# ---------------------------------------------------------------------------
# Time and identifiers
# ---------------------------------------------------------------------------

# RFC3339 instant in UTC, e.g. 2026-07-31T01:12:34Z
at_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

at_epoch_seconds() {
  date -u +%s
}

# Crockford base32 encode: at_base32 <number> <length>
at_base32() {
  local n="$1"
  local len="$2"
  local alphabet="0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  local out=""
  local i
  for (( i = 0; i < len; i++ )); do
    out="${alphabet:$(( n % 32 )):1}$out"
    n=$(( n / 32 ))
  done
  printf '%s' "$out"
}

at_random_number() {
  local value=""
  if [ -r /dev/urandom ]; then
    value="$(od -An -N4 -tu4 < /dev/urandom 2>/dev/null | tr -d ' \n' || true)"
  fi
  case "$value" in
    ''|*[!0-9]*) value=$(( (RANDOM * 32768) + RANDOM )) ;;
  esac
  printf '%s' "$value"
}

# ULID-ish identifier: <prefix>_<10 chars of time><16 chars of randomness>.
# Lexicographically sortable by creation time, and safe for the API's id regex
# (letters, digits, dot, underscore, colon, dash).
at_new_id() {
  local prefix="$1"
  local millis=$(( $(at_epoch_seconds) * 1000 ))
  printf '%s_%s%s%s' \
    "$prefix" \
    "$(at_base32 "$millis" 10)" \
    "$(at_base32 "$(at_random_number)" 8)" \
    "$(at_base32 "$(at_random_number)" 8)"
}

at_new_event_id() { at_new_id evt; }

# ---------------------------------------------------------------------------
# State directory, locking, sequence counter
# ---------------------------------------------------------------------------

at_ensure_state_dir() {
  mkdir -p "$AT_STATE_DIR"
}

at_lock() {
  at_ensure_state_dir
  local attempts=0
  while ! mkdir "$AT_LOCK_DIR" 2>/dev/null; do
    attempts=$(( attempts + 1 ))
    if [ "$attempts" -gt 100 ]; then
      # A previous run died holding the lock. Break it rather than hang.
      at_warn "breaking a stale state lock"
      rm -rf "$AT_LOCK_DIR" 2>/dev/null || true
      mkdir "$AT_LOCK_DIR" 2>/dev/null && return 0
      return 1
    fi
    sleep 0.05 2>/dev/null || sleep 1
  done
  return 0
}

at_unlock() {
  rm -rf "$AT_LOCK_DIR" 2>/dev/null || true
}

at_reset_sequence() {
  at_ensure_state_dir
  printf '0\n' > "$AT_SEQUENCE_FILE"
}

# Monotonic, per-session. Reset by start-session.sh when a session is created.
at_next_sequence() {
  at_ensure_state_dir
  at_lock || true
  local current=0
  if [ -f "$AT_SEQUENCE_FILE" ]; then
    current="$(cat "$AT_SEQUENCE_FILE" 2>/dev/null || printf '0')"
  fi
  case "$current" in
    ''|*[!0-9]*) current=0 ;;
  esac
  local next=$(( current + 1 ))
  printf '%s\n' "$next" > "$AT_SEQUENCE_FILE"
  at_unlock
  printf '%s' "$next"
}

# ---------------------------------------------------------------------------
# Temporary files
# ---------------------------------------------------------------------------

AT_TEMP_FILES=""

at_mktemp() {
  local file
  file="$(mktemp "${TMPDIR:-/tmp}/agentmagnify.XXXXXX")"
  AT_TEMP_FILES="$AT_TEMP_FILES $file"
  printf '%s' "$file"
}

at_cleanup_temp() {
  local file
  for file in $AT_TEMP_FILES; do
    [ -n "$file" ] && rm -f "$file" 2>/dev/null || true
  done
  AT_TEMP_FILES=""
}

trap at_cleanup_temp EXIT

# ---------------------------------------------------------------------------
# Dependencies and configuration
# ---------------------------------------------------------------------------

AT_JSON_TOOL=""

at_require_deps() {
  if ! command -v curl >/dev/null 2>&1; then
    at_error "curl is required but was not found on PATH"
    return 1
  fi
  if command -v jq >/dev/null 2>&1; then
    AT_JSON_TOOL="jq"
  elif command -v python3 >/dev/null 2>&1; then
    AT_JSON_TOOL="python3"
  else
    at_error "either jq or python3 is required but neither was found on PATH"
    return 1
  fi
  at_debug "dependencies ok (json tool: $AT_JSON_TOOL)"
  return 0
}

AT_API_URL=""
AT_TIMEOUT=""
AT_MAX_RETRIES=""

# Where the user-level credential lives. One login per machine, reused by every
# project, the way gh/aws/npm do it.
AT_CREDENTIALS_FILE="${AGENTMAGNIFY_CREDENTIALS_FILE:-$HOME/.agentmagnify/credentials.json}"

# Committed, secret-free, per project. Names the project; never holds a token.
AT_PROJECT_CONFIG_NAME=".agentmagnify.json"
# Git-ignored, per project. For a project that needs its own scoped token.
AT_PROJECT_SECRET_NAME=".agentmagnify.local.json"

# The names this package used before the product was renamed to AgentMagnify.
#
# Nothing below ever reads them for a value. They exist so that a machine set up
# under the old names gets told what happened instead of being told there is no
# credential -- the two situations are indistinguishable to a user, and the
# second one sends them off to re-pair without ever learning why. Reading the
# old names for real was the alternative and was rejected: a silent fallback
# means both spellings stay alive indefinitely and every future reader has to
# check which one won, for the benefit of installations that a single `mv`
# fixes and that no paying customer has yet.
AT_LEGACY_CREDENTIALS_FILE="$HOME/.agent-tracker/credentials.json"
AT_LEGACY_PROJECT_CONFIG_NAME=".agent-tracker.json"
AT_LEGACY_PROJECT_SECRET_NAME=".agent-tracker.local.json"

AT_PROJECT_NAME=""
AT_PROJECT_SLUG=""
AT_CONFIG_SOURCE=""

# Walks up from the working directory looking for a file, stopping at the
# filesystem root. A monorepo package should still find the config at the repo
# root rather than needing one per package.
at_find_upwards() {
  local name="$1" dir
  dir="$(pwd)"
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -f "$dir/$name" ]; then
      printf '%s\n' "$dir/$name"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  [ -f "/$name" ] && printf '%s\n' "/$name" && return 0
  return 1
}

# Project identity from the repository itself, so the common case needs no
# config file at all: the git remote's repo name, else the directory name.
#
# Two working directories are refused instead of inferred, loudly, because
# each has produced a phantom project in the panel: the skill's own install
# directory (an agent that cd'd here to run a script would register a project
# named "agentmagnify", then re-register the real one after cd'ing back), and
# the home directory (a project named after the user's login is never what
# anyone meant). Inference is a convenience; a wrong project is a lie in the
# panel, so the convenience does not extend to directories that cannot be a
# project.
at_infer_project_name() {
  local remote base here skill_root
  remote="$(git config --get remote.origin.url 2>/dev/null || true)"
  if [ -n "$remote" ]; then
    base="${remote##*/}"
    base="${base%.git}"
    [ -n "$base" ] && printf '%s\n' "$base" && return 0
  fi

  here="$(pwd)"
  skill_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"

  if [ -n "$skill_root" ] && { [ "$here" = "$skill_root" ] || case "$here" in "$skill_root"/*) true ;; *) false ;; esac; }; then
    at_error "Refusing to infer a project from inside the skill's own directory ($skill_root)."
    at_error "cd into the project you are reporting on and run the script again, or set AGENTMAGNIFY_PROJECT_NAME."
    return 1
  fi

  if [ "$here" = "${HOME:-/nonexistent}" ]; then
    at_error "Refusing to infer a project from the home directory."
    at_error "cd into the project you are reporting on and run the script again, or set AGENTMAGNIFY_PROJECT_NAME."
    return 1
  fi

  base="$(basename "$here")"
  printf '%s\n' "$base"
}

at_load_config() {
  local project_config project_secret token_from_file legacy_project_config

  # 1) Committed project config. Non-secret by contract: naming the project is
  #    safe to share, handing out a token is not.
  if project_config="$(at_find_upwards "$AT_PROJECT_CONFIG_NAME")"; then
    if [ -n "$(at_json_get "$project_config" 'token')" ]; then
      at_error "$project_config contains a 'token' field. That file is meant to be committed, so the token is now in your repository history."
      at_error "Move it to $AT_PROJECT_SECRET_NAME (git-ignored) or run scripts/login.sh, then rotate the exposed token in the panel."
      return 1
    fi
    [ -z "${AGENTMAGNIFY_API_URL:-}" ] && AGENTMAGNIFY_API_URL="$(at_json_get "$project_config" 'apiUrl')"
    AT_PROJECT_NAME="$(at_json_get "$project_config" 'projectName')"
    AT_PROJECT_SLUG="$(at_json_get "$project_config" 'projectSlug')"
  elif legacy_project_config="$(at_find_upwards "$AT_LEGACY_PROJECT_CONFIG_NAME")"; then
    # Losing this file silently is the worst of the rename's failure modes: the
    # project name falls back to the repository name, events keep flowing, and
    # they land under a project nobody was watching.
    at_warn "$legacy_project_config is from before the rename and is no longer read; the file is now called $AT_PROJECT_CONFIG_NAME."
    at_warn "Until it is renamed, this project reports under its inferred name rather than the pinned one."
  fi

  # 2) Credential resolution, first hit wins: environment, project-local
  #    secret, then the user-level login.
  if [ -n "${AGENTMAGNIFY_TOKEN:-}" ]; then
    AT_CONFIG_SOURCE="environment"
  else
    if project_secret="$(at_find_upwards "$AT_PROJECT_SECRET_NAME")"; then
      token_from_file="$(at_json_get "$project_secret" 'token')"
      if [ -n "$token_from_file" ]; then
        AGENTMAGNIFY_TOKEN="$token_from_file"
        AT_CONFIG_SOURCE="$project_secret"
        [ -z "${AGENTMAGNIFY_API_URL:-}" ] && AGENTMAGNIFY_API_URL="$(at_json_get "$project_secret" 'apiUrl')"
      fi
    fi

    if [ -z "${AGENTMAGNIFY_TOKEN:-}" ] && [ -f "$AT_CREDENTIALS_FILE" ]; then
      token_from_file="$(at_json_get "$AT_CREDENTIALS_FILE" 'token')"
      if [ -n "$token_from_file" ]; then
        AGENTMAGNIFY_TOKEN="$token_from_file"
        AT_CONFIG_SOURCE="$AT_CREDENTIALS_FILE"
        [ -z "${AGENTMAGNIFY_API_URL:-}" ] && AGENTMAGNIFY_API_URL="$(at_json_get "$AT_CREDENTIALS_FILE" 'apiUrl')"
      fi
    fi
  fi

  export AGENTMAGNIFY_TOKEN

  # 3) Project name: explicit env, then committed config, then the repository.
  #    Inference can refuse (skill dir, home dir) — that refusal must stop the
  #    script rather than register a phantom project under an empty name.
  [ -n "${AGENTMAGNIFY_PROJECT_NAME:-}" ] && AT_PROJECT_NAME="$AGENTMAGNIFY_PROJECT_NAME"
  if [ -z "$AT_PROJECT_NAME" ]; then
    AT_PROJECT_NAME="$(at_infer_project_name)" || return 1
  fi
  export AGENTMAGNIFY_PROJECT_NAME="$AT_PROJECT_NAME"

  AT_API_URL="${AGENTMAGNIFY_API_URL:-$AT_DEFAULT_API_URL}"
  AT_API_URL="${AT_API_URL%/}"
  AT_TIMEOUT="${AGENTMAGNIFY_TIMEOUT_SECONDS:-10}"
  AT_MAX_RETRIES="${AGENTMAGNIFY_MAX_RETRIES:-2}"
  at_ensure_state_dir
  return 0
}

at_have_token() {
  [ -n "${AGENTMAGNIFY_TOKEN:-}" ]
}

# Names any pre-rename setup found on this machine, so that "no credential" is
# never the whole story when the credential is present under its old name.
# Prints nothing when there is nothing to say.
at_legacy_setup_hints() {
  local found=0

  if [ -n "${AGENT_TRACKER_TOKEN:-}" ]; then
    at_error "AGENT_TRACKER_TOKEN is set but is no longer read. The variable is now AGENTMAGNIFY_TOKEN."
    found=1
  fi
  if [ -n "${AGENT_TRACKER_API_URL:-}" ] && [ -z "${AGENTMAGNIFY_API_URL:-}" ]; then
    at_error "AGENT_TRACKER_API_URL is set but is no longer read. The variable is now AGENTMAGNIFY_API_URL."
    found=1
  fi
  if [ ! -f "$AT_CREDENTIALS_FILE" ] && [ -f "$AT_LEGACY_CREDENTIALS_FILE" ]; then
    at_error "A credential from before the rename is still at $AT_LEGACY_CREDENTIALS_FILE and is no longer read."
    at_error "  Keep the token: mkdir -p \"$(dirname "$AT_CREDENTIALS_FILE")\" && mv \"$AT_LEGACY_CREDENTIALS_FILE\" \"$AT_CREDENTIALS_FILE\""
    at_error "  Or start clean: bash scripts/pair.sh, then delete the old file."
    found=1
  fi
  if at_find_upwards "$AT_LEGACY_PROJECT_SECRET_NAME" >/dev/null 2>&1 &&
    ! at_find_upwards "$AT_PROJECT_SECRET_NAME" >/dev/null 2>&1; then
    at_error "This project still has $AT_LEGACY_PROJECT_SECRET_NAME; the file is now called $AT_PROJECT_SECRET_NAME."
    found=1
  fi

  return "$((1 - found))"
}

at_require_token() {
  if ! at_have_token; then
    at_error "No monitoring token found; reporting is disabled until there is one."
    at_legacy_setup_hints || true
    at_error "Run: bash scripts/pair.sh              (approve it in the panel; nothing to copy)"
    at_error "  or: bash scripts/login.sh <token>    (for CI, where nobody is at a browser)"
    at_error "Looked at: AGENTMAGNIFY_TOKEN, ./$AT_PROJECT_SECRET_NAME, $AT_CREDENTIALS_FILE"
    return 1
  fi
  return 0
}

# Prints only the token kind and a short fingerprint. Never the token.
at_token_hint() {
  local token="${AGENTMAGNIFY_TOKEN:-}"
  if [ -z "$token" ]; then
    printf 'none'
    return 0
  fi
  local kind="unknown"
  case "$token" in
    prj_live_*) kind="project" ;;
    wsi_live_*) kind="workspace-ingestion" ;;
    ro_live_*) kind="read-only" ;;
  esac
  printf '%s token (%s characters)' "$kind" "${#token}"
}

at_token_kind() {
  case "${AGENTMAGNIFY_TOKEN:-}" in
    prj_live_*) printf 'project' ;;
    wsi_live_*) printf 'workspace_ingestion' ;;
    ro_live_*) printf 'read_only' ;;
    *) printf 'unknown' ;;
  esac
}

# ---------------------------------------------------------------------------
# JSON helpers - implemented twice, once for jq and once for python3
# ---------------------------------------------------------------------------

at_json_tool() {
  if [ -z "$AT_JSON_TOOL" ]; then
    at_require_deps || return 1
  fi
  printf '%s' "$AT_JSON_TOOL"
}

# at_json_quote <text> -> a JSON string literal
at_json_quote() {
  local tool
  tool="$(at_json_tool)" || return 1
  if [ "$tool" = "jq" ]; then
    printf '%s' "$1" | jq -Rs .
  else
    printf '%s' "$1" | python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read()))'
  fi
}

# at_json_valid <file>
at_json_valid() {
  local tool
  tool="$(at_json_tool)" || return 1
  if [ "$tool" = "jq" ]; then
    jq -e . "$1" >/dev/null 2>&1
  else
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" >/dev/null 2>&1
  fi
}

# at_json_compact <file> -> single-line JSON on stdout
at_json_compact() {
  local tool
  tool="$(at_json_tool)" || return 1
  if [ "$tool" = "jq" ]; then
    jq -c . "$1"
  else
    python3 -c 'import json,sys; sys.stdout.write(json.dumps(json.load(open(sys.argv[1])),separators=(",",":"))+"\n")' "$1"
  fi
}

# at_json_get <file> <dotted.path> -> scalar, or nothing when absent
at_json_get() {
  local tool
  tool="$(at_json_tool)" || return 1
  [ -f "$1" ] || return 0
  if [ "$tool" = "jq" ]; then
    jq -r --arg p "$2" '
      getpath($p | split(".")) as $v
      | if $v == null then empty
        elif ($v | type) == "object" or ($v | type) == "array" then ($v | tojson)
        else ($v | tostring) end
    ' "$1" 2>/dev/null || true
  else
    python3 - "$1" "$2" <<'PYEOF' 2>/dev/null || true
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
node = data
for part in sys.argv[2].split('.'):
    if isinstance(node, dict) and part in node:
        node = node[part]
    else:
        sys.exit(0)
if node is None:
    sys.exit(0)
if isinstance(node, (dict, list)):
    sys.stdout.write(json.dumps(node, separators=(',', ':')) + "\n")
elif isinstance(node, bool):
    sys.stdout.write(("true" if node else "false") + "\n")
else:
    sys.stdout.write(str(node) + "\n")
PYEOF
  fi
}

# at_json_probe <file> <dotted.path>... -> one line per path, in order.
# Empty line when the path is absent, "[object]" for objects and arrays, the
# scalar otherwise. One process for any number of paths, which is what keeps
# validation cheap.
at_json_probe() {
  local file="$1"
  shift
  local tool
  tool="$(at_json_tool)" || return 1
  if [ "$tool" = "jq" ]; then
    jq -n -r --slurpfile doc "$file" --args '
      $doc[0] as $root
      | $ARGS.positional[]
      | . as $p
      | (try ($root | getpath($p | split("."))) catch null)
      | if . == null then ""
        elif (type == "object" or type == "array") then "[object]"
        else (tostring | gsub("\n"; " ")) end
    ' "$@" 2>/dev/null || true
  else
    python3 - "$file" "$@" <<'PYEOF' 2>/dev/null || true
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    for _ in sys.argv[2:]:
        print("")
    sys.exit(0)
for path in sys.argv[2:]:
    node = data
    found = True
    for part in path.split('.'):
        if isinstance(node, dict) and part in node:
            node = node[part]
        else:
            found = False
            break
    if not found or node is None:
        print("")
    elif isinstance(node, (dict, list)):
        print("[object]")
    elif isinstance(node, bool):
        print("true" if node else "false")
    else:
        print(str(node).replace("\n", " "))
PYEOF
  fi
}

# at_json_set <file> <str|num|bool|json> <dotted.path> <value>
# Numeric path components address array positions.
at_json_set() {
  local file="$1" kind="$2" path="$3" value="$4"
  local tool tmp
  tool="$(at_json_tool)" || return 1
  tmp="$(at_mktemp)"
  if [ "$tool" = "jq" ]; then
    # shellcheck disable=SC2016  # a jq program, not a shell expansion
    local pathexpr='($p | split(".") | map(if test("^[0-9]+$") then tonumber else . end))'
    case "$kind" in
      str)
        jq --arg p "$path" --arg v "$value" "setpath($pathexpr; \$v)" "$file" > "$tmp"
        ;;
      num|bool|json)
        jq --arg p "$path" --argjson v "$value" "setpath($pathexpr; \$v)" "$file" > "$tmp"
        ;;
      *)
        at_error "at_json_set: unknown value kind '$kind'"
        return 1
        ;;
    esac
  else
    python3 - "$file" "$kind" "$path" "$value" "$tmp" <<'PYEOF'
import json, sys
src, kind, path, raw, dst = sys.argv[1:6]
data = json.load(open(src))
if kind == 'str':
    value = raw
elif kind in ('num', 'bool', 'json'):
    value = json.loads(raw)
else:
    sys.stderr.write("at_json_set: unknown value kind\n")
    sys.exit(1)
parts = [int(p) if p.isdigit() else p for p in path.split('.')]
node = data
for index, part in enumerate(parts[:-1]):
    nxt = parts[index + 1]
    if isinstance(part, int):
        while len(node) <= part:
            node.append({} if not isinstance(nxt, int) else [])
        if node[part] is None:
            node[part] = [] if isinstance(nxt, int) else {}
        node = node[part]
    else:
        if part not in node or node[part] is None:
            node[part] = [] if isinstance(nxt, int) else {}
        node = node[part]
last = parts[-1]
if isinstance(last, int):
    while len(node) <= last:
        node.append(None)
    node[last] = value
else:
    node[last] = value
with open(dst, 'w') as handle:
    json.dump(data, handle)
PYEOF
  fi
  mv "$tmp" "$file"
}

# at_json_delete <file> <key>... -> removes top-level keys in place
at_json_delete() {
  local file="$1"
  shift
  local tool tmp
  tool="$(at_json_tool)" || return 1
  tmp="$(at_mktemp)"
  if [ "$tool" = "jq" ]; then
    # The input file has to be named before --args. After it, jq reads the
    # keys as positional arguments and the document from stdin instead - which
    # inside a `while read` loop means silently eating the loop's input.
    jq 'delpaths([$ARGS.positional[] | [.]])' "$file" --args "$@" > "$tmp"
  else
    python3 - "$file" "$tmp" "$@" <<'PYEOF'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
data = json.load(open(src))
for key in sys.argv[3:]:
    data.pop(key, None)
with open(dst, 'w') as handle:
    json.dump(data, handle)
PYEOF
  fi
  mv "$tmp" "$file"
}

# at_json_merge <base-file> <overlay-file> -> merged JSON on stdout (overlay wins)
at_json_merge() {
  local tool
  tool="$(at_json_tool)" || return 1
  if [ "$tool" = "jq" ]; then
    jq -s -c '.[0] * .[1]' "$1" "$2"
  else
    python3 - "$1" "$2" <<'PYEOF'
import json, sys


def merge(base, overlay):
    if isinstance(base, dict) and isinstance(overlay, dict):
        out = dict(base)
        for key, value in overlay.items():
            out[key] = merge(base.get(key), value) if key in base else value
        return out
    return overlay


base = json.load(open(sys.argv[1]))
overlay = json.load(open(sys.argv[2]))
sys.stdout.write(json.dumps(merge(base, overlay), separators=(',', ':')) + "\n")
PYEOF
  fi
}

# Number of string leaves in a JSON document (used by the secret filter).
at_json_string_count() {
  local tool
  tool="$(at_json_tool)" || return 1
  if [ "$tool" = "jq" ]; then
    jq '[paths(type == "string")] | length' "$1"
  else
    python3 - "$1" <<'PYEOF'
import json, sys


def walk(node):
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for value in node.values():
            for item in walk(value):
                yield item
    elif isinstance(node, list):
        for value in node:
            for item in walk(value):
                yield item


print(sum(1 for _ in walk(json.load(open(sys.argv[1])))))
PYEOF
  fi
}

# The n-th string leaf, in a stable pre-order.
at_json_string_at() {
  local tool
  tool="$(at_json_tool)" || return 1
  if [ "$tool" = "jq" ]; then
    jq -r --argjson i "$2" '[paths(type == "string")] as $p | getpath($p[$i])' "$1"
  else
    python3 - "$1" "$2" <<'PYEOF'
import json, sys


def walk(node):
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for value in node.values():
            for item in walk(value):
                yield item
    elif isinstance(node, list):
        for value in node:
            for item in walk(value):
                yield item


index = int(sys.argv[2])
for position, value in enumerate(walk(json.load(open(sys.argv[1])))):
    if position == index:
        sys.stdout.write(value)
        break
PYEOF
  fi
}

# Replace the n-th string leaf in place.
at_json_set_string_at() {
  local file="$1" index="$2" value="$3"
  local tool tmp
  tool="$(at_json_tool)" || return 1
  tmp="$(at_mktemp)"
  if [ "$tool" = "jq" ]; then
    jq --argjson i "$index" --arg v "$value" \
      '[paths(type == "string")] as $p | setpath($p[$i]; $v)' "$file" > "$tmp"
  else
    python3 - "$file" "$index" "$value" "$tmp" <<'PYEOF'
import json, sys
src, index, value, dst = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
data = json.load(open(src))
state = {'seen': 0}


def walk(node):
    if isinstance(node, str):
        current = state['seen']
        state['seen'] += 1
        return value if current == index else node
    if isinstance(node, dict):
        return {key: walk(item) for key, item in node.items()}
    if isinstance(node, list):
        return [walk(item) for item in node]
    return node


with open(dst, 'w') as handle:
    json.dump(walk(data), handle)
PYEOF
  fi
  mv "$tmp" "$file"
}

# ---------------------------------------------------------------------------
# Secret filter - mirrors packages/contract/src/redaction.ts
#
# The server redacts too, but an event that would be flagged must never leave
# this machine in the first place (doc 24.5). Where a POSIX ERE cannot express
# the TypeScript regex exactly, the shell version is deliberately stricter.
# ---------------------------------------------------------------------------

AT_SECRET_NAMES=()
AT_SECRET_PATTERNS=()

AT_SECRET_COMBINED=""

# Expand an ASCII word into a case-insensitive ERE, because neither BSD nor
# GNU sed can be relied on for an inline case-insensitive flag. Pure shell: this
# runs on every value that is checked, so it must not fork.
at_ci() {
  local word="$1"
  local lower="abcdefghijklmnopqrstuvwxyz"
  local upper="ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  local out=""
  local index char prefix position
  for (( index = 0; index < ${#word}; index++ )); do
    char="${word:index:1}"
    prefix="${lower%%"$char"*}"
    position="${#prefix}"
    if [ "$position" -lt 26 ]; then
      out="${out}[${char}${upper:position:1}]"
    else
      out="${out}${char}"
    fi
  done
  printf '%s' "$out"
}

at_init_secret_patterns() {
  if [ -n "$AT_SECRET_COMBINED" ]; then
    return 0
  fi

  local keyword
  keyword="$(at_ci password)|$(at_ci passwd)|$(at_ci pass)|$(at_ci secret)"
  keyword="$keyword|$(at_ci token)|$(at_ci api)[_-]?$(at_ci key)"
  keyword="$keyword|$(at_ci access)[_-]?$(at_ci key)|$(at_ci private)[_-]?$(at_ci key)"
  keyword="$keyword|$(at_ci credential)|$(at_ci auth)"

  AT_SECRET_NAMES=(
    aws_access_key
    github_token
    slack_token
    stripe_key
    anthropic_key
    openai_key
    google_api_key
    jwt
    private_key_line
    connection_string
    credential_assignment
    env_export
    bearer_header
    monitoring_token
  )

  AT_SECRET_PATTERNS=(
    '(AKIA|ASIA)[0-9A-Z]{16}'
    'gh[pousr]_[A-Za-z0-9]{16,}'
    'xox[baprs]-[A-Za-z0-9-]{10,}'
    '[sr]k_(live|test)_[A-Za-z0-9]{16,}'
    'sk-ant-[A-Za-z0-9_-]{20,}'
    'sk-[A-Za-z0-9_-]{20,}'
    'AIza[0-9A-Za-z_-]{35}'
    'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}'
    '-----BEGIN[A-Z ]*PRIVATE KEY-----'
    '[a-zA-Z][a-zA-Z0-9+.-]*://[^[:space:]:@/]+:[^[:space:]@/]+@[^[:space:]/]+'
    "[A-Za-z0-9_.-]*($keyword)[A-Za-z0-9_.-]*[\"']?[[:space:]]*[:=][[:space:]]*[\"']?[^[:space:]\"',;]{6,}"
    'export[[:space:]]+[A-Z][A-Z0-9_]{2,}[[:space:]]*=[[:space:]]*[^[:space:]]+'
    '[Bb]earer[[:space:]]+[A-Za-z0-9._~+/=-]{16,}'
    '(prj|wsi|ro)_live_[A-Za-z0-9]{8,}'
  )

  # One alternation covering every rule plus the code fence marker. Checking a
  # value costs a single grep; only a value that matches pays for the per-rule
  # loop below.
  local index
  AT_SECRET_COMBINED='(```)'
  for (( index = 0; index < ${#AT_SECRET_PATTERNS[@]}; index++ )); do
    AT_SECRET_COMBINED="$AT_SECRET_COMBINED|(${AT_SECRET_PATTERNS[$index]})"
  done
}

# The cheap question: could this text contain anything the filter cares about?
at_text_looks_risky() {
  at_init_secret_patterns
  printf '%s' "$1" | grep -qE "$AT_SECRET_COMBINED" 2>/dev/null
}

at_file_looks_risky() {
  at_init_secret_patterns
  grep -qE "$AT_SECRET_COMBINED" "$1" 2>/dev/null
}

# Drops fenced code blocks and private key blocks. Both are multi-line, so this
# needs a state machine rather than a substitution.
at_strip_blocks() {
  awk '
    BEGIN { infence = 0; inkey = 0 }
    {
      line = $0
      copy = line
      fences = gsub(/```/, "", copy)
      if (inkey) {
        if (line ~ /-----END[A-Z ]*PRIVATE KEY-----/) { inkey = 0 }
        next
      }
      if (line ~ /-----BEGIN[A-Z ]*PRIVATE KEY-----/) {
        inkey = 1
        print "[redacted]"
        next
      }
      if (infence) {
        if (fences > 0 && fences % 2 == 1) { infence = 0 }
        next
      }
      if (fences > 0) {
        if (fences % 2 == 1) { infence = 1 }
        print "[code block removed]"
        next
      }
      print line
    }
  '
}

# at_redact_text <text> -> redacted text on stdout
at_redact_text() {
  at_init_secret_patterns
  if ! at_text_looks_risky "$1"; then
    printf '%s' "$1"
    return 0
  fi
  local text
  text="$(printf '%s' "$1" | at_strip_blocks)"
  local index pattern
  for (( index = 0; index < ${#AT_SECRET_PATTERNS[@]}; index++ )); do
    pattern="${AT_SECRET_PATTERNS[$index]}"
    if printf '%s' "$text" | grep -qE "$pattern" 2>/dev/null; then
      text="$(printf '%s' "$text" | sed -E "s#$pattern#[redacted]#g")"
    fi
  done
  printf '%s' "$text"
}

# at_scan_text <text> -> names of the rules that matched, one per line
at_scan_text() {
  at_init_secret_patterns
  if ! at_text_looks_risky "$1"; then
    return 0
  fi
  local text="$1"

  if printf '%s' "$text" | grep -q '```' 2>/dev/null; then
    printf 'code_block\n'
  fi
  if printf '%s' "$text" | grep -qE -- '-----BEGIN[A-Z ]*PRIVATE KEY-----' 2>/dev/null; then
    printf 'private_key_block\n'
  fi
  text="$(printf '%s' "$text" | at_strip_blocks)"

  local index pattern
  for (( index = 0; index < ${#AT_SECRET_PATTERNS[@]}; index++ )); do
    pattern="${AT_SECRET_PATTERNS[$index]}"
    if printf '%s' "$text" | grep -qE "$pattern" 2>/dev/null; then
      printf '%s\n' "${AT_SECRET_NAMES[$index]}"
      text="$(printf '%s' "$text" | sed -E "s#$pattern#[redacted]#g")"
    fi
  done
}

# at_text_is_safe <text> -> 0 when nothing would be flagged
at_text_is_safe() {
  if ! at_text_looks_risky "$1"; then
    return 0
  fi
  local matches
  matches="$(at_scan_text "$1")"
  [ -z "$matches" ]
}

# Redacts every string leaf of a JSON document in place. Returns 0 always;
# warns on stderr when something was redacted.
#
# The whole document is checked first: if nothing in the serialised JSON can
# match a rule then no individual leaf can either, and the expensive per-leaf
# walk is skipped entirely. That keeps the common case at one grep.
at_redact_json_file() {
  local file="$1"
  if ! at_file_looks_risky "$file"; then
    return 0
  fi

  local count index value redacted rules
  local matched=""
  count="$(at_json_string_count "$file")"
  case "$count" in
    ''|*[!0-9]*) return 0 ;;
  esac
  for (( index = 0; index < count; index++ )); do
    value="$(at_json_string_at "$file" "$index")"
    [ -n "$value" ] || continue
    at_text_looks_risky "$value" || continue
    rules="$(at_scan_text "$value")"
    if [ -n "$rules" ]; then
      redacted="$(at_redact_text "$value")"
      at_json_set_string_at "$file" "$index" "$redacted"
      matched="$matched $(printf '%s' "$rules" | tr '\n' ' ')"
    fi
  done
  if [ -n "$matched" ]; then
    at_warn "secret filter redacted content before sending (rules:$matched)"
  fi
  return 0
}

# Final guard: no string leaf may still trip the filter.
at_json_is_safe() {
  local file="$1"
  if ! at_file_looks_risky "$file"; then
    return 0
  fi

  local count index value
  count="$(at_json_string_count "$file")"
  case "$count" in
    ''|*[!0-9]*) return 0 ;;
  esac
  for (( index = 0; index < count; index++ )); do
    value="$(at_json_string_at "$file" "$index")"
    [ -n "$value" ] || continue
    if ! at_text_is_safe "$value"; then
      return 1
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

# The token goes into a 0600 curl config file so that it never appears in the
# process list or in any log line.
at_curl_config() {
  local file
  file="$(at_mktemp)"
  : > "$file"
  chmod 600 "$file" 2>/dev/null || true
  printf 'header = "Authorization: Bearer %s"\n' "${AGENTMAGNIFY_TOKEN:-}" >> "$file"
  printf 'header = "User-Agent: %s/%s"\n' "$AT_CLIENT_NAME" "$AT_CLIENT_VERSION" >> "$file"
  printf '%s' "$file"
}

# at_http_request METHOD PATH BODY_FILE OUT_FILE [IDEMPOTENCY_KEY] [EXTRA_HEADER] [HEADER_OUT_FILE]
# Prints the HTTP status code (000 when the request never reached the server).
at_http_request() {
  local method="$1"
  local path="$2"
  local body_file="$3"
  local out_file="$4"
  local idempotency_key="${5:-}"
  local extra_header="${6:-}"
  local header_out="${7:-}"

  local url="$AT_API_URL$path"
  local config
  config="$(at_curl_config)"
  local attempt=0
  local status="000"
  local rc=0

  while : ; do
    attempt=$(( attempt + 1 ))
    local args
    args=( -sS -o "$out_file" -w '%{http_code}' --max-time "$AT_TIMEOUT" -K "$config" -X "$method" )
    args=( "${args[@]}" -H 'Accept: application/json' )
    if [ -n "$header_out" ]; then
      args=( "${args[@]}" -D "$header_out" )
    fi
    if [ -n "$idempotency_key" ]; then
      args=( "${args[@]}" -H "Idempotency-Key: $idempotency_key" )
    fi
    if [ -n "$extra_header" ]; then
      args=( "${args[@]}" -H "$extra_header" )
    fi
    if [ -n "$body_file" ]; then
      args=( "${args[@]}" -H 'Content-Type: application/json' --data-binary "@$body_file" )
    fi

    set +e
    status="$(curl "${args[@]}" "$url" 2>/dev/null)"
    rc=$?
    set -e

    if [ "$rc" -ne 0 ] || [ -z "$status" ]; then
      status="000"
    fi

    if [ "$status" != "000" ] && [ "$status" -lt 500 ] && [ "$status" != "429" ]; then
      break
    fi
    if [ "$attempt" -gt "$AT_MAX_RETRIES" ]; then
      break
    fi
    local backoff=$(( 1 << (attempt - 1) ))
    at_debug "request $method $path returned $status; retrying in ${backoff}s"
    sleep "$backoff"
  done

  rm -f "$config" 2>/dev/null || true
  printf '%s' "$status"
}

at_status_is_success() {
  case "$1" in
    2??) return 0 ;;
    *) return 1 ;;
  esac
}

# A 4xx that will never succeed on retry. 408 and 429 are excluded on purpose.
at_status_is_permanent_failure() {
  case "$1" in
    408|429) return 1 ;;
    4??) return 0 ;;
    *) return 1 ;;
  esac
}

at_error_message() {
  local file="$1"
  local code message path
  code="$(at_json_get "$file" 'error.code')"
  message="$(at_json_get "$file" 'error.message')"
  path="$(at_json_get "$file" 'error.path')"
  if [ -z "$code" ] && [ -z "$message" ]; then
    printf 'no error detail returned'
    return 0
  fi
  printf '%s: %s' "${code:-UNKNOWN}" "${message:-no message}"
  if [ -n "$path" ]; then
    printf ' (at %s)' "$path"
  fi
}

# ---------------------------------------------------------------------------
# Session state
# ---------------------------------------------------------------------------

AT_SESSION_ID=""
AT_PROJECT_ID=""
AT_PROTOCOL_VERSION=""
AT_REPORTING_MODE=""
AT_PANEL_URL=""
AT_SESSION_ONLINE=""

at_load_session() {
  AT_SESSION_ID=""
  AT_PROJECT_ID=""
  AT_PROTOCOL_VERSION=""
  AT_REPORTING_MODE=""
  AT_PANEL_URL=""
  AT_SESSION_ONLINE=""

  if [ ! -f "$AT_SESSION_FILE" ]; then
    return 1
  fi
  # shellcheck disable=SC2034  # these are read by the scripts that source lib.sh
  AT_SESSION_ID="$(at_json_get "$AT_SESSION_FILE" 'sessionId')"
  # shellcheck disable=SC2034
  AT_PROJECT_ID="$(at_json_get "$AT_SESSION_FILE" 'projectId')"
  # shellcheck disable=SC2034
  AT_PROTOCOL_VERSION="$(at_json_get "$AT_SESSION_FILE" 'protocolVersion')"
  # shellcheck disable=SC2034
  AT_REPORTING_MODE="$(at_json_get "$AT_SESSION_FILE" 'reportingMode')"
  # shellcheck disable=SC2034
  AT_PANEL_URL="$(at_json_get "$AT_SESSION_FILE" 'panelUrl')"
  # shellcheck disable=SC2034
  AT_SESSION_ONLINE="$(at_json_get "$AT_SESSION_FILE" 'online')"
  [ -n "$AT_SESSION_ID" ]
}

at_protocol_version() {
  local version=""
  if [ -f "$AT_SESSION_FILE" ]; then
    version="$(at_json_get "$AT_SESSION_FILE" 'protocolVersion')"
  fi
  if [ -z "$version" ] && [ -f "$AT_SCHEMA_FILE" ]; then
    version="$(at_json_get "$AT_SCHEMA_FILE" 'protocolVersion')"
  fi
  if [ -z "$version" ] && [ -f "$AT_FALLBACK_SCHEMA" ]; then
    version="$(at_json_get "$AT_FALLBACK_SCHEMA" 'protocolVersion')"
  fi
  printf '%s' "${version:-$AT_FALLBACK_PROTOCOL_VERSION}"
}

at_active_schema_file() {
  if [ -f "$AT_SCHEMA_FILE" ]; then
    printf '%s' "$AT_SCHEMA_FILE"
  else
    printf '%s' "$AT_FALLBACK_SCHEMA"
  fi
}

at_max_batch_size() {
  local size=""
  if [ -f "$AT_SESSION_FILE" ]; then
    size="$(at_json_get "$AT_SESSION_FILE" 'reporting.maxBatchSize')"
  fi
  if [ -z "$size" ]; then
    size="$(at_json_get "$(at_active_schema_file)" 'limits.maxBatchSize')"
  fi
  case "$size" in
    ''|*[!0-9]*) size=100 ;;
  esac
  if [ "$size" -gt 100 ]; then
    size=100
  fi
  printf '%s' "$size"
}

AT_MAX_PAYLOAD_CACHE=""

at_max_payload_bytes() {
  if [ -n "$AT_MAX_PAYLOAD_CACHE" ]; then
    printf '%s' "$AT_MAX_PAYLOAD_CACHE"
    return 0
  fi
  local size=""
  if [ -f "$AT_SESSION_FILE" ]; then
    size="$(at_json_get "$AT_SESSION_FILE" 'reporting.maxPayloadBytes')"
  fi
  if [ -z "$size" ]; then
    size="$(at_json_get "$(at_active_schema_file)" 'limits.maxPayloadBytes')"
  fi
  case "$size" in
    ''|*[!0-9]*) size=262144 ;;
  esac
  AT_MAX_PAYLOAD_CACHE="$size"
  printf '%s' "$size"
}

AT_MAX_SUMMARY_LENGTH_CACHE=""

at_max_summary_length() {
  if [ -z "$AT_MAX_SUMMARY_LENGTH_CACHE" ]; then
    AT_MAX_SUMMARY_LENGTH_CACHE="$(at_json_get "$(at_active_schema_file)" 'limits.maxSummaryLength')"
    case "$AT_MAX_SUMMARY_LENGTH_CACHE" in
      ''|*[!0-9]*) AT_MAX_SUMMARY_LENGTH_CACHE=2000 ;;
    esac
  fi
  printf '%s' "$AT_MAX_SUMMARY_LENGTH_CACHE"
}

# ---------------------------------------------------------------------------
# Event vocabulary and per-type validation (doc 14.1)
# ---------------------------------------------------------------------------

AT_EVENT_TYPE_CACHE=""

at_known_event_types() {
  if [ -n "$AT_EVENT_TYPE_CACHE" ]; then
    printf '%s\n' "$AT_EVENT_TYPE_CACHE"
    return 0
  fi
  local schema
  schema="$(at_active_schema_file)"
  local tool
  tool="$(at_json_tool)" || return 1
  if [ "$tool" = "jq" ]; then
    jq -r '.eventTypes[]?' "$schema" 2>/dev/null || true
  else
    python3 - "$schema" <<'PYEOF' 2>/dev/null || true
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for item in data.get('eventTypes', []):
    print(item)
PYEOF
  fi
}

at_is_known_event_type() {
  if [ -z "$AT_EVENT_TYPE_CACHE" ]; then
    AT_EVENT_TYPE_CACHE="$(at_known_event_types)"
  fi
  printf '%s\n' "$AT_EVENT_TYPE_CACHE" | grep -qx -- "$1"
}

at_is_observer_event_type() {
  case "$1" in
    snapshot.created|progress.recalculated|completion.verified|completion.disputed|\
agent.stale|project.stale|risk.detected|status.corrected)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Top-level fields an event type cannot be sent without. Mirrors
# REQUIRED_EVENT_FIELDS in packages/contract/src/event.ts.
at_required_fields_for_type() {
  case "$1" in
    roadmap.created|roadmap.updated) printf 'roadmap' ;;
    phase.*) printf 'phase' ;;
    task.*) printf 'task' ;;
    agent.*) printf 'agent' ;;
    blocker.*) printf 'blocker' ;;
    decision.*) printf 'decision' ;;
    test.*) printf 'test' ;;
    build.*) printf 'build' ;;
    artifact.*) printf 'artifact' ;;
    deployment.*) printf 'deployment' ;;
    completion.verified) printf 'task' ;;
    completion.disputed) printf 'task assessment' ;;
    progress.recalculated) printf 'progress' ;;
    risk.detected) printf 'summary' ;;
    status.corrected) printf 'assessment' ;;
    *) printf '' ;;
  esac
}

at_is_number() {
  case "$1" in
    ''|*[!0-9.-]*) return 1 ;;
  esac
  case "$1" in
    *.*.*) return 1 ;;
  esac
  return 0
}

at_is_integer() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

AT_VALIDATION_PATHS="type eventId sessionId protocolVersion sequence timestamp \
reporter.agentId reporter.kind roadmap phase task task.id agent blocker decision \
test test.failed build artifact deployment assessment assessment.reason progress \
progress.roadmap progress.reported progress.verified summary"

# at_validate_event_file <file> -> 0 when the event may be sent (doc 14.1).
# Prints one human readable problem per line on stderr.
at_validate_event_file() {
  local file="$1"
  local problems=0

  # One pass over the document; every field the checks below need.
  local probe
  # shellcheck disable=SC2086
  probe="$(at_json_probe "$file" $AT_VALIDATION_PATHS)"

  local v_type v_eventId v_sessionId v_protocol v_sequence v_timestamp
  local v_agentId v_kind v_roadmap v_phase v_task v_taskId v_agent v_blocker
  local v_decision v_test v_testFailed v_build v_artifact v_deployment
  local v_assessment v_assessmentReason v_progress v_progressRoadmap
  local v_progressReported v_progressVerified v_summary

  {
    IFS= read -r v_type || v_type=""
    IFS= read -r v_eventId || v_eventId=""
    IFS= read -r v_sessionId || v_sessionId=""
    IFS= read -r v_protocol || v_protocol=""
    IFS= read -r v_sequence || v_sequence=""
    IFS= read -r v_timestamp || v_timestamp=""
    IFS= read -r v_agentId || v_agentId=""
    IFS= read -r v_kind || v_kind=""
    IFS= read -r v_roadmap || v_roadmap=""
    IFS= read -r v_phase || v_phase=""
    IFS= read -r v_task || v_task=""
    IFS= read -r v_taskId || v_taskId=""
    IFS= read -r v_agent || v_agent=""
    IFS= read -r v_blocker || v_blocker=""
    IFS= read -r v_decision || v_decision=""
    IFS= read -r v_test || v_test=""
    IFS= read -r v_testFailed || v_testFailed=""
    IFS= read -r v_build || v_build=""
    IFS= read -r v_artifact || v_artifact=""
    IFS= read -r v_deployment || v_deployment=""
    IFS= read -r v_assessment || v_assessment=""
    IFS= read -r v_assessmentReason || v_assessmentReason=""
    IFS= read -r v_progress || v_progress=""
    IFS= read -r v_progressRoadmap || v_progressRoadmap=""
    IFS= read -r v_progressReported || v_progressReported=""
    IFS= read -r v_progressVerified || v_progressVerified=""
    IFS= read -r v_summary || v_summary=""
  } <<PROBEEOF
$probe
PROBEEOF

  if [ -z "$v_type" ]; then
    at_error "validation: type is required"
    return 1
  fi
  if ! at_is_known_event_type "$v_type"; then
    at_error "validation: unsupported event type '$v_type'"
    problems=$(( problems + 1 ))
  fi

  local field value
  for field in eventId sessionId protocolVersion sequence timestamp; do
    case "$field" in
      eventId) value="$v_eventId" ;;
      sessionId) value="$v_sessionId" ;;
      protocolVersion) value="$v_protocol" ;;
      sequence) value="$v_sequence" ;;
      timestamp) value="$v_timestamp" ;;
    esac
    if [ -z "$value" ]; then
      at_error "validation: $field is required"
      problems=$(( problems + 1 ))
    fi
  done

  if [ -z "$v_agentId" ]; then
    at_error "validation: reporter.agentId is required"
    problems=$(( problems + 1 ))
  fi

  if at_is_observer_event_type "$v_type" && [ "$v_kind" != "observer" ]; then
    at_error "validation: '$v_type' may only be emitted with reporter.kind=observer (got '${v_kind:-unset}')"
    problems=$(( problems + 1 ))
  fi

  for field in $(at_required_fields_for_type "$v_type"); do
    case "$field" in
      roadmap) value="$v_roadmap" ;;
      phase) value="$v_phase" ;;
      task) value="$v_task" ;;
      agent) value="$v_agent" ;;
      blocker) value="$v_blocker" ;;
      decision) value="$v_decision" ;;
      test) value="$v_test" ;;
      build) value="$v_build" ;;
      artifact) value="$v_artifact" ;;
      deployment) value="$v_deployment" ;;
      assessment) value="$v_assessment" ;;
      progress) value="$v_progress" ;;
      summary) value="$v_summary" ;;
      *) value="" ;;
    esac
    if [ -z "$value" ]; then
      at_error "validation: $field is required for event type $v_type"
      problems=$(( problems + 1 ))
    fi
  done

  case "$v_type" in
    task.*|completion.verified|completion.disputed)
      if [ -z "$v_taskId" ]; then
        at_error "validation: task.id is required for event type $v_type"
        problems=$(( problems + 1 ))
      fi
      ;;
  esac

  if [ "$v_type" = "task.progress" ] && [ -z "$v_progress" ]; then
    at_error "validation: task.progress requires a progress object"
    problems=$(( problems + 1 ))
  fi

  if [ "$v_type" = "completion.disputed" ] && [ -z "$v_assessmentReason" ]; then
    at_error "validation: completion.disputed requires assessment.reason"
    problems=$(( problems + 1 ))
  fi

  if [ "$v_type" = "test.failed" ] && [ "$v_testFailed" = "0" ]; then
    at_error "validation: test.failed must report at least one failing test"
    problems=$(( problems + 1 ))
  fi

  local percentage whole
  for field in roadmap reported verified; do
    case "$field" in
      roadmap) percentage="$v_progressRoadmap" ;;
      reported) percentage="$v_progressReported" ;;
      verified) percentage="$v_progressVerified" ;;
    esac
    [ -n "$percentage" ] || continue
    if ! at_is_number "$percentage"; then
      at_error "validation: progress.$field must be a number"
      problems=$(( problems + 1 ))
      continue
    fi
    whole="${percentage%%.*}"
    case "$whole" in
      ''|-) whole=0 ;;
    esac
    if [ "$whole" -lt 0 ] || [ "$whole" -gt 100 ]; then
      at_error "validation: progress.$field must be between 0 and 100"
      problems=$(( problems + 1 ))
    fi
  done

  local limit
  limit="$(at_max_summary_length)"
  if [ -n "$v_summary" ] && [ "${#v_summary}" -gt "$limit" ]; then
    at_error "validation: summary is longer than the $limit character limit"
    problems=$(( problems + 1 ))
  fi

  local bytes max_bytes
  bytes="$(wc -c < "$file" | tr -d ' ')"
  max_bytes="$(at_max_payload_bytes)"
  if [ "$bytes" -gt "$max_bytes" ]; then
    at_error "validation: payload is $bytes bytes, over the $max_bytes byte limit"
    problems=$(( problems + 1 ))
  fi

  [ "$problems" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Local queues
# ---------------------------------------------------------------------------

at_queue_event() {
  local file="$1"
  at_ensure_state_dir
  at_lock || true
  at_json_compact "$file" >> "$AT_PENDING_FILE"
  at_unlock
}

# ---------------------------------------------------------------------------
# Dead-letter classification
#
# "Dead-lettered" used to mean one thing and cover two, which is why nothing
# could ever be re-sent:
#
#   credential  the event was fine, the credential was not accepted. Re-sending
#               it once the machine is paired again will work.
#   payload     the API refused this particular event. Re-sending it a hundred
#               times fails a hundred times.
#   expired     recoverable in principle, but queued for so long that replaying
#               it would put stale history on a live timeline.
#   local       the local secret filter could not clean it, so it never left
#               this machine and never may.
#
# Recorded as its own field beside the human sentence rather than parsed back
# out of it. `deadLetterReason` is assembled from whatever the server said, and
# the server's wording is free to change; a replayer that grepped it would
# quietly start resurrecting rubbish the day somebody improved an error
# message. The kind is decided at the one moment the answer is actually known,
# and a run months later can trust it without re-deriving anything.
# ---------------------------------------------------------------------------

# at_dead_letter_kind_for_status <http-status> -> credential | payload
#
# Judged on the status of the request, never on a per-event error code inside a
# 2xx batch response. A batch that came back 200 was authenticated: an event
# inside it rejected with FORBIDDEN was refused for what it said - an observer
# verdict from a developer agent, say - and that is a payload problem wearing an
# authorisation code. Treating it as a credential failure would put it in an
# endless replay loop.
at_dead_letter_kind_for_status() {
  case "$1" in
    401|403) printf 'credential' ;;
    *) printf 'payload' ;;
  esac
}

at_dead_letter_kind_is_recoverable() {
  [ "$1" = "credential" ]
}

# at_dead_letter_event <file> <reason> [kind]
#
# The kind defaults to `payload` when the caller does not say. That is the safe
# direction: an unclassified entry is left alone for ever rather than replayed
# on a guess, so a new call site that forgets loses recovery, not correctness.
at_dead_letter_event() {
  local file="$1"
  local reason="$2"
  local kind="${3:-payload}"
  at_ensure_state_dir
  local tmp
  tmp="$(at_mktemp)"
  cp "$file" "$tmp"
  at_json_set "$tmp" str deadLetterReason "$reason" || true
  at_json_set "$tmp" str deadLetterKind "$kind" || true
  at_json_set "$tmp" str deadLetteredAt "$(at_now)" || true
  at_lock || true
  at_json_compact "$tmp" >> "$AT_DEAD_LETTER_FILE"
  at_unlock
  rm -f "$tmp" 2>/dev/null || true
}

at_dead_letter_count() {
  if [ -f "$AT_DEAD_LETTER_FILE" ]; then
    wc -l < "$AT_DEAD_LETTER_FILE" | tr -d ' '
  else
    printf '0'
  fi
}

# at_partition_dead_letters <source> <requeue-out> <keep-out> <max-events>
#                           <oldest-allowed-timestamp> <max-age-hours>
#
# Splits a dead-letter file into the events that may be sent again and the ones
# that must not be. Prints "recovered=<n> aged=<n>" and touches nothing else -
# no locks, no state, no network - so the rule can be exercised on its own.
#
# What comes back:
#
#   * `deadLetterKind` must be recoverable. A `payload` entry would fail again,
#     a `local` one must never leave this machine, an `expired` one is history,
#     and a line that is not valid JSON or carries no kind at all is not
#     classified - so it stays, because guessing is how rubbish gets resurrected.
#   * the event's own timestamp must be no older than the pending queue's
#     ceiling. Replaying a two-day-old "task started" onto a live timeline
#     reports something that is no longer true. Those are re-marked `expired` on
#     the way out so the next run recognises them without re-deriving the age.
#   * at most <max-events>, so one run cannot empty an arbitrarily large backlog
#     into the queue at once.
#
# The dead-letter fields are stripped from everything requeued: the ingestion
# schema rejects unknown top-level keys, so an event replayed with its own
# post-mortem still attached would come back as a payload rejection - and then,
# correctly, never be retried again.
at_partition_dead_letters() {
  local source="$1" requeue="$2" keep="$3"
  local max_events="$4" oldest_allowed="$5" max_age_hours="$6"

  : > "$requeue"
  : > "$keep"

  local entry line kind timestamp
  local recovered=0 aged=0
  entry="$(at_mktemp)"

  # The queue is read on descriptor 3 rather than on stdin. Every helper called
  # in the body shells out, and one of them reading stdin would swallow the rest
  # of the file and silently drop the events it ate.
  while IFS= read -r line <&3; do
    [ -n "$line" ] || continue
    printf '%s\n' "$line" > "$entry"

    if ! at_json_valid "$entry"; then
      printf '%s\n' "$line" >> "$keep"
      continue
    fi

    kind="$(at_json_get "$entry" 'deadLetterKind')"
    if ! at_dead_letter_kind_is_recoverable "$kind"; then
      printf '%s\n' "$line" >> "$keep"
      continue
    fi

    # Age before the cap, so retiring history costs nothing from this run's
    # budget: a backlog that is mostly too old would otherwise take one run per
    # batch to work through, and never reach the events worth sending.
    timestamp="$(at_json_get "$entry" 'timestamp')"
    if [ -n "$oldest_allowed" ] && [ -n "$timestamp" ] && [ "$timestamp" \< "$oldest_allowed" ]; then
      at_json_set "$entry" str deadLetterKind expired || true
      at_json_set "$entry" str deadLetterReason \
        "held longer than $max_age_hours hours; too old to replay" || true
      at_json_compact "$entry" >> "$keep"
      aged=$(( aged + 1 ))
      continue
    fi

    if [ "$recovered" -ge "$max_events" ]; then
      printf '%s\n' "$line" >> "$keep"
      continue
    fi

    at_json_delete "$entry" deadLetterKind deadLetterReason deadLetteredAt || true
    at_json_compact "$entry" >> "$requeue"
    recovered=$(( recovered + 1 ))
  done 3< "$source"

  rm -f "$entry" 2>/dev/null || true
  printf 'recovered=%s aged=%s' "$recovered" "$aged"
}

at_pending_count() {
  if [ -f "$AT_PENDING_FILE" ]; then
    wc -l < "$AT_PENDING_FILE" | tr -d ' '
  else
    printf '0'
  fi
}

# ---------------------------------------------------------------------------
# Capabilities (doc 8.3)
# ---------------------------------------------------------------------------

AT_DEFAULT_CAPABILITIES="roadmap tasks subagents observer hooks tests builds artifacts background_tasks"

at_capabilities() {
  printf '%s' "${AGENTMAGNIFY_CAPABILITIES:-$AT_DEFAULT_CAPABILITIES}"
}

at_has_capability() {
  local wanted="$1"
  local capability
  for capability in $(at_capabilities); do
    if [ "$capability" = "$wanted" ]; then
      return 0
    fi
  done
  return 1
}

# Mirrors negotiateReportingMode() in packages/contract/src/protocol.ts so the
# offline path picks the same mode the server would have picked.
at_local_reporting_mode() {
  if at_has_capability observer && at_has_capability hooks && at_has_capability background_tasks; then
    printf 'full'
  elif at_has_capability observer; then
    printf 'observer'
  elif at_has_capability tasks || at_has_capability roadmap; then
    printf 'checkpoint'
  else
    printf 'fallback'
  fi
}

# The declared executor, before it is narrowed to a known type. Kept separate
# so the name survives narrowing: an environment this list has never heard of
# still gets to say what it is.
at_executor_declared() {
  local executor="${AGENTMAGNIFY_EXECUTOR:-}"
  if [ -n "$executor" ]; then
    printf '%s' "$executor"
    return 0
  fi
  if [ -n "${CLAUDE_CODE_SESSION_ID:-}${CLAUDECODE:-}" ]; then
    printf 'claude-code'
  elif [ -n "${CURSOR_SESSION_ID:-}" ]; then
    printf 'cursor'
  elif [ -n "${CODEX_SESSION_ID:-}${CODEX_HOME:-}" ]; then
    printf 'codex'
  fi
}

at_executor_type() {
  # Unrecognised, and unknown, both answer `custom`. It used to guess
  # `claude-code` when it could not tell, so an agent running anywhere else
  # reported somebody else's name and the panel showed it without hesitation.
  # Saying "some environment" is worth more than saying the wrong one.
  case "$(at_executor_declared)" in
    claude-code|codex|cursor|aider|custom) at_executor_declared ;;
    *) printf 'custom' ;;
  esac
}

# What the panel shows beside the type. An explicit label always wins; failing
# that, an executor named in the environment but absent from the type list is
# carried through here rather than dropped -- `custom` says only that we do not
# recognise it, which is not the same as not knowing what it called itself.
at_executor_label() {
  if [ -n "${AGENTMAGNIFY_EXECUTOR_LABEL:-}" ]; then
    printf '%s' "$AGENTMAGNIFY_EXECUTOR_LABEL"
    return 0
  fi
  local declared
  declared="$(at_executor_declared)"
  case "$declared" in
    ''|claude-code|codex|cursor|aider|custom) ;;
    *) printf '%s' "$declared" ;;
  esac
}

# ---------------------------------------------------------------------------
# Offline session bootstrap
# ---------------------------------------------------------------------------

# Writes a local, offline session record so that reporting can start even when
# the API has never answered (doc 13.7). flush-pending-events.sh upgrades it to
# a real session and rewrites the queued ids as soon as the API is reachable.
at_write_local_session() {
  local session_id
  session_id="$(at_new_id ses_local)"
  at_ensure_state_dir
  cat > "$AT_SESSION_FILE" <<JSONEOF
{
  "sessionId": "$session_id",
  "protocolVersion": "$(at_protocol_version)",
  "reportingMode": "$(at_local_reporting_mode)",
  "protocolVerified": false,
  "online": false,
  "panelUrl": "",
  "startedAt": "$(at_now)",
  "reporting": {
    "maxBatchSize": 100,
    "maxPayloadBytes": 262144,
    "snapshotIntervalSeconds": 300,
    "observerIntervalSeconds": 600,
    "heartbeatIntervalSeconds": 300
  }
}
JSONEOF
  at_reset_sequence
  at_load_session
}

at_ensure_session() {
  if at_load_session; then
    return 0
  fi
  at_warn "no monitoring session on disk; starting a local offline session so reporting is not lost"
  at_write_local_session
}

at_set_session_field() {
  local kind="$1" path="$2" value="$3"
  [ -f "$AT_SESSION_FILE" ] || return 0
  at_json_set "$AT_SESSION_FILE" "$kind" "$path" "$value"
}

# ---------------------------------------------------------------------------
# Epoch to RFC3339, used to age out the offline queue
# ---------------------------------------------------------------------------

# Prints an RFC3339 UTC timestamp for the given epoch second, or nothing when
# neither the GNU nor the BSD date syntax is available.
at_rfc3339_from_epoch() {
  local epoch="$1"
  local out=""
  out="$(date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
  if [ -z "$out" ]; then
    out="$(date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
  fi
  printf '%s' "$out"
}
