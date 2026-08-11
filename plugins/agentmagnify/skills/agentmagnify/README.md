# agentmagnify

The skill package a user installs so their coding agents report into
AgentMagnify. There is no CLI to install, no daemon and no background service:
this package is the whole integration.

```
Install the skill  ->  set the project token  ->  run the agent  ->  watch the panel
```

## Install

```bash
npx agentmagnify install
```

That detects which agent environments are on the machine, writes this package
where each of them reads from, runs the self-test **in the installed copy**, and
prints what it did and where. If an installed copy does not pass its own
self-test the command says so and exits non-zero — an install that only looks
successful is the failure worth spending a check on.

To update, run the same thing; `npx` fetches the current package each time:

```bash
npx agentmagnify@latest install
```

Claude Code users can have native versioning and `/plugin update` instead:

```
/plugin marketplace add remanatech/agentmagnify-skill
/plugin install agentmagnify@agentmagnify
```

Same files either way. Then pair the machine:

```bash
bash ~/.claude/skills/agentmagnify/scripts/pair.sh --api-url https://api.your-monitor.example
```

It prints an eight-character code and waits. Open the panel, sign in, type the
code, check that the screen names this machine and the workspace you meant, and
approve. The token arrives here on its own.

No token is ever shown for you to copy — not in the panel, not in this
terminal. A credential pasted between the two ends up in shell history, in
scrollback and in screenshots, and this path has no step where that can happen.

That is the whole setup, once per machine. The token is written to
`~/.agentmagnify/credentials.json` with mode 0600 — not into your repository,
not into a shell profile — and every project on the machine reuses it.

The other direction works too, and is the right one for a cloud agent session
— no terminal anybody watches, no filesystem that outlives the session. On the
panel's Pair screen choose "Issue a pair code", configure what the agent may
do, and paste the twelve-character code it gives you into the session:

```
/agentmagnify BCDF-GHJK-MNPQ
```

or anywhere: `bash scripts/pair.sh --code BCDF-GHJK-MNPQ`. The code is not the
token — it lasts ten minutes, works once, and grants only what was configured
when it was issued.

Somewhere with no browser and nobody to approve — CI, a container, an image
build? Nothing changed there: set `AGENTMAGNIFY_TOKEN`, or store a token from
the panel's Tokens screen once.

```bash
bash scripts/login.sh wsi_live_xxxxxxxx --api-url https://api.your-monitor.example
```

A project is identified by its git remote name, falling back to the directory
name, so a fresh repository needs no configuration at all. To pin the name the
panel shows, commit a secret-free `.agentmagnify.json`:

```json
{ "projectName": "N8N Clone", "projectSlug": "n8n-clone" }
```

That file is meant to be shared, so the scripts refuse to run if a token
appears in it.

Verify the package with no network access:

```bash
bash scripts/self-test.sh
```

## Supported environments

Support here is a gradient, not a yes, so the table says which rung each
environment is on. Three claims are worth keeping apart:

1. **The path.** The vendor's own documentation says that directory is scanned
   for skills of this exact shape — a directory named after the skill with a
   `SKILL.md` in it.
2. **The install.** `npx agentmagnify install` wrote there and the installed
   copy passed its own self-test, on a real machine.
3. **The loading.** The agent picked the skill up and followed it, and the
   reporting mode from [`SKILL.md` §4](./SKILL.md) was observed rather than
   assumed.

Everything below has 1 and 2. Only Claude Code has 3.

| Environment | Where the installer writes | Reporting mode | Status |
| --- | --- | --- | --- |
| **Claude Code** | `~/.claude/skills/agentmagnify`; `<project>/.claude/skills/agentmagnify` with `--project` | `full` | **Verified.** The environment this skill is developed and tested in. Sub-agents, hooks and background tasks all exist, which is what `full` means. |
| **OpenAI Codex CLI** | `~/.agents/skills/agentmagnify` and `~/.codex/skills/agentmagnify`; `.agents/skills/agentmagnify` with `--project` | **unverified** | Path documented by OpenAI; the installer runs and the installed copy self-tests. **Not verified that Codex loads the skill**, and nobody has established which reporting mode it can reach. Two directories because the documented root and the one `codex-cli 0.144.4` actually populates are different. |
| **Cursor** | `~/.cursor/skills/agentmagnify` and `~/.agents/skills/agentmagnify`; the same two under the project with `--project` | **unverified** | Path documented by Cursor; the installer runs and the installed copy self-tests. **Not verified that Cursor loads the skill.** Additionally: `~/.cursor/skills` did not exist on the machine this was built on — what was there was `~/.cursor/skills-cursor`, a name that appears in no Cursor documentation. If that is the directory Cursor actually reads, this adapter is a no-op. `~/.agents/skills` is written for the same environment and did exist. |
| Windsurf | nothing | — | **No adapter.** It reads prose in files it shares with the user's own rules, not a skill directory. See below. |
| Aider | nothing | — | **No adapter.** Aider is told what to read; installing would mean editing `~/.aider.conf.yml`. See below. |
| GitHub Copilot | nothing | — | **No adapter.** Repository instructions are one shared Markdown file, and the VS Code user-level locations are off by default. See below. |
| AGENTS.md convention | nothing | — | **No adapter.** One file could serve Codex, Cursor, Windsurf and Copilot at once, but it is the project's own file. See below. |

`npx agentmagnify list` prints the same thing from the machine you are on,
including a sentence per unimplemented environment saying what is missing.

**Why four environments get nothing.** Not because the path is unknown — all
four are named above and in `lib/environments.mjs` in the npm package. Because
they read *prose*, in a file that already belongs to somebody, rather than a
directory of skills with runnable scripts beside it. That needs two decisions
nobody has made: what an entry point should say when it has to point at an
installed copy of the scripts rather than carry them, and how to merge into a
file the project already wrote. Appending a paragraph on install that can never
be cleanly removed is a worse default than doing nothing.

An adapter that writes into a directory nothing reads is worse than no adapter
at all: the install reports success, the panel stays empty, and there is nothing
to debug because everything worked.

## Use

The agent reads `SKILL.md` and follows it. From a shell, the flow is:

```bash
scripts/start-session.sh                       # prints the panel URL
scripts/report-event.sh --type task.started ...
scripts/report-event.sh --type task.completed ...
scripts/complete-session.sh --summary "..."
```

`scripts/report-event.sh --help` documents every flag.

## What is in here

```
SKILL.md                       the operating procedure the agent follows
agents/project-observer.md     the independent Project Observer sub-agent
scripts/
  lib.sh                       shared helpers: ids, timestamps, HTTP, secret filter
  pair.sh                      get a token by approving a code in the panel,
                               or claim one issued there (--code)
  login.sh                     store a token directly, for CI and containers
  fetch-schema.sh              protocol bundle download, cache and fallback
  start-session.sh             handshake and session creation
  report-event.sh              send one event (the main entry point)
  send-snapshot.sh             send a project snapshot
  send-heartbeat.sh            keep the session alive
  flush-pending-events.sh      drain the offline queue; --replay-dead-letters
                               also re-sends what a refused credential held back
  complete-session.sh          close the session
  upload-artifact.sh           upload a screenshot or report and record it
                               as an artifact
  self-test.sh                 offline verification of this package
references/
  fallback-schema.json         offline copy of the protocol bundle
  event-types.md               every event type, who may emit it, required fields
  reporting-rules.md           the "when do I report" decision table
state/                         local session state; git-ignored
```

## Requirements

- `bash`
- `curl`
- `jq` **or** `python3`

Everything else is in this package.

## How it behaves

- **Development never stops for monitoring.** If the API is unreachable, events go
  to `state/pending-events.jsonl` and every script still exits 0.
  `flush-pending-events.sh` drains the queue later, in order, letting the API
  deduplicate.
- **The protocol is fetched, not hard-coded.** Each session performs a handshake,
  caches the JSON Schema, the reporting policy and the agent instructions, and pins
  the protocol version for the life of the session. If the API has never been
  reachable, `references/fallback-schema.json` keeps validation working and the
  session is marked `unverified protocol`.
- **Nothing that looks like a secret leaves the machine.** A local filter mirroring
  the server's redaction rules runs over every payload: API keys, bearer tokens,
  connection strings, `KEY=value` credential assignments, private key blocks and
  fenced code blocks. The token itself is passed to `curl` through a 0600 config
  file so it never appears in the process list or a log line.
- **Events are validated before they are sent.** Required fields per event type,
  progress bounds, summary length, payload size and the observer-only type gate are
  all checked locally. A permanent API rejection goes to `state/dead-letter.jsonl`
  rather than into a retry loop.
- **A refused credential is held, not lost.** A 401 or 403 means the event was fine
  and the token was not, so it is dead-lettered as `deadLetterKind: credential` and
  replayed by the next successful handshake — at most 200 per handshake, at most
  once every five minutes, and never once it is older than the queue's maximum age.
  Everything the API refused on its own merits is marked `payload` and is never
  sent again, because it would fail in exactly the same way.

## State

Everything under `state/` is local, per-machine and git-ignored:

| File | Contents |
| --- | --- |
| `session.json` | Session id, project id, protocol version, reporting policy, panel URL, reporting mode. |
| `schema.json` | The cached protocol bundle, with `schema.etag` and `schema.fetched-at`. |
| `pending-events.jsonl` | Events waiting for the API. |
| `dead-letter.jsonl` | Events that were not accepted, each carrying a `deadLetterKind`: `credential` (held, and replayed once a working token is back), `payload`, `expired` or `local` (never sent again). |
| `dead-letter.replayed-at` | When the held events were last replayed, so a loop of handshakes cannot become a loop of replays. |
| `sequence` | The per-session monotonic event counter. |
| `config.env` | Optional; sourced if present, for people who prefer not to export the token in every shell. |

Delete the directory's contents to start clean; the scripts recreate what they
need.

## Environment reference

| Variable | Default | Meaning |
| --- | --- | --- |
| `AGENTMAGNIFY_TOKEN` | - | Required to report. Never printed. |
| `AGENTMAGNIFY_API_URL` | `https://api.agentmagnify.com` | API base URL. Set it for a self-hosted installation. |
| `AGENTMAGNIFY_PROJECT_NAME` | - | Project name, workspace ingestion tokens only. |
| `AGENTMAGNIFY_AGENT_ID` | `main-agent` | Default reporter id. |
| `AGENTMAGNIFY_AGENT_ROLE` | - | Default reporter role. |
| `AGENTMAGNIFY_AGENT_KIND` | `logical` | Default reporter kind. |
| `AGENTMAGNIFY_EXECUTOR` | detected | `claude-code`, `codex`, `cursor`, `aider`, `custom`, or any other name. An unrecognised value reports as `custom` and becomes the label, so the panel still shows what ran. Undetectable reports as `custom` rather than guessing. |
| `AGENTMAGNIFY_EXECUTOR_LABEL` | inferred | Free text shown beside the type; overrides the inferred one. |
| `AGENTMAGNIFY_CAPABILITIES` | all | Space-separated capability list for the handshake. |
| `AGENTMAGNIFY_STATE_DIR` | `state/` | Where local state lives. |
| `AGENTMAGNIFY_TIMEOUT_SECONDS` | `10` | Per-request timeout. |
| `AGENTMAGNIFY_MAX_RETRIES` | `2` | Retries after the first attempt, with backoff. |
| `AGENTMAGNIFY_QUEUE_MAX_AGE_HOURS` | `72` | Queued events older than this are dead-lettered, and held events older than this are retired instead of replayed. |
| `AGENTMAGNIFY_REPLAY_MAX_EVENTS` | `200` | How many held events one replay may requeue. |
| `AGENTMAGNIFY_REPLAY_MIN_INTERVAL_SECONDS` | `300` | Shortest gap between two replays, however often a session is opened. |
| `AGENTMAGNIFY_DEBUG` | `0` | `1` for verbose logging on stderr. |

## Tests

```bash
pnpm --filter @agentmagnify/skill test    # runs scripts/self-test.sh
```

The self-test needs no network. It checks id generation, timestamp format, the
sequence counter, per-event-type validation, the secret filter against real
credential shapes, the offline queue round trip, and that the token is never
written to disk.
