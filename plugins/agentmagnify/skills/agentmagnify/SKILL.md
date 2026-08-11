---
name: agentmagnify
description: Report live project state to AgentMagnify. Use at the start of any coding session that builds or changes a project, and whenever a task, phase, test, build, blocker or decision changes state. Covers session startup, main-agent and sub-agent reporting rules, the Project Observer, and the offline event queue.
---

# AgentMagnify

This skill turns what your agents are already doing into a live project record
the user watches from a panel: roadmap, tasks, test and build evidence,
blockers, decisions, and an independent verification of every completion claim.

You report; you do not stop working to report. Every helper script exits 0 on a
network failure and queues the event locally instead. When a flag or shape is
unclear, read `references/examples.md` — worked examples for every situation —
rather than guessing; do not read it routinely.

## 1. When this skill is active

Activate when both are true:

- the session is project work (building, refactoring, testing, shipping), not a
  one-off question;
- `scripts/login.sh --status` succeeds. Use that command, never an env-var
  check: `pair.sh` stores the token in a file and exports nothing, so a
  correctly paired machine has no `AGENTMAGNIFY_TOKEN`.

If no credential resolves, say so once, in one line, and continue working
normally. Never block on it, never ask repeatedly.

**Invoked with a pair code** (`/agentmagnify BCDF-GHJK-MNPQ` — twelve
characters, three groups): pairing is the task. Run
`bash scripts/pair.sh --code BCDF-GHJK-MNPQ` before anything else. The code
works once and lasts ten minutes; if it fails as expired or used, ask the user
for a fresh one from the panel's Pair screen. After a successful claim,
continue with the startup sequence.

**Cloud / ephemeral sessions** (Claude Code on the web, CI sandboxes): same
skill, two right credential paths — a pasted pair code, or
`AGENTMAGNIFY_TOKEN` provisioned in the environment. Capabilities are whatever
the platform really has (a cloud Claude Code session still has sub-agents,
hooks and background tasks — declare `full`). Set `AGENTMAGNIFY_DEVICE_LABEL`
or `AGENTMAGNIFY_EXECUTOR_LABEL` to something like `claude-cloud` so the panel
says where the work happened.

### Configuration

Setup is one command per machine: `bash scripts/pair.sh` (a person approves in
the panel; no secret is ever displayed). Headless environments use
`bash scripts/login.sh wsi_live_…` or `AGENTMAGNIFY_TOKEN`.

Credential resolution, first hit wins: `AGENTMAGNIFY_TOKEN` env →
`.agentmagnify.local.json` (git-ignored, project-scoped) →
`~/.agentmagnify/credentials.json` (0600). Project identity, first hit wins:
`AGENTMAGNIFY_PROJECT_NAME` → committed `.agentmagnify.json` (never holds a
token; scripts refuse if one appears) → git remote name → directory name. With
a workspace ingestion token a fresh repository needs no setup at all.

| Variable | Meaning |
| --- | --- |
| `AGENTMAGNIFY_TOKEN` | Overrides the stored credential. Never print or echo it. |
| `AGENTMAGNIFY_API_URL` | API base URL; set for self-hosted installs. |
| `AGENTMAGNIFY_PROJECT_NAME` | Overrides the inferred name (wsi tokens only). |

Rarely needed: `AGENTMAGNIFY_AGENT_ID/_ROLE/_KIND` (reporter defaults),
`AGENTMAGNIFY_EXECUTOR` / `_EXECUTOR_LABEL` (environment identity; unknown
names report as `custom` with the name as label), `AGENTMAGNIFY_CAPABILITIES`,
`AGENTMAGNIFY_DEBUG=1`. Heartbeat: `AGENTMAGNIFY_HEARTBEAT=0` off,
`_SECONDS` interval (default 300, floor 60), `_MAX_SILENCE` (default 1800).

## 2. Startup sequence

Once, at the beginning, before creating any sub-agent. **Run from the
project's own directory** — the project's identity is inferred from the
working directory, and the scripts refuse to run from the skill's install
directory or from `$HOME` for exactly that reason. Never `cd` into the skill
to run them; call them by absolute path with the project as your cwd:

```bash
# cwd = the project you are reporting on
bash ~/.claude/skills/agentmagnify/scripts/login.sh --status     # 1. a credential resolves; never prints it
bash ~/.claude/skills/agentmagnify/scripts/start-session.sh      # 2. handshake + schema cache + session + panel URL
```

`start-session.sh` verifies the token (a rejected one degrades to offline, it
never aborts), performs the handshake with the detected executor and
capabilities, caches the protocol bundle and reporting policy in
`state/schema.json`, writes `state/session.json` (session id, project id,
reporting mode, panel URL), starts the background heartbeat, and prints the
panel URL — show it to the user once.

Then you owe three things:

1. **Keep §5's rules in working memory** — you are the main agent.
2. **Inject the rules into every sub-agent prompt**: its `--agent-id`, its
   `--role`, `--kind logical`, §6's table, and §7's dual-report rule. An
   untold sub-agent reports nothing and shows as silent.
3. **Start the Project Observer** (`agents/project-observer.md`) as a
   background sub-agent when the mode supports it (§4).

At the end — and not early:

```bash
scripts/complete-session.sh --summary "One or two sentences: delivered, and still open."
```

It drains the queue, sends the closing snapshot, closes the session. A session
never completed shows as `interrupted`, which is the honest reading.

## 3. The scripts

All in `scripts/`, all safe to call at any time.

| Script | Use |
| --- | --- |
| `start-session.sh` | Open the session. Prints the panel URL. |
| `report-event.sh` | Send one event. The main entry point. `--help` lists every flag. |
| `upload-artifact.sh` | Upload a file (screenshot, report, log) and report it as an artifact in one call. |
| `send-snapshot.sh` | Project snapshot. Observer only, plus session close. |
| `send-heartbeat.sh` / `heartbeat-daemon.sh` | Liveness. Started and stopped for you; not run by hand. |
| `flush-pending-events.sh` | Drain the offline queue. `--replay-dead-letters` re-sends what a refused credential held. |
| `complete-session.sh` | Close the session. |
| `pair.sh` / `login.sh` | Get or store a credential. |
| `fetch-schema.sh` | Refresh the cached protocol bundle (called for you). |
| `self-test.sh` | Offline verification of this package. |

`report-event.sh` fills in `eventId`, `sessionId`, `projectId`,
`protocolVersion`, `sequence` and `timestamp`; you supply the meaning.
**Chain consecutive reports with `&&` in one shell invocation** when several
belong to the same moment (a phase closing and the next opening) — fewer round
trips, same events.

## 4. Capability detection and reporting modes

Decide once, at startup, before creating the observer.

**On Claude Code the answer is known: sub-agents, hooks and background tasks
all exist — start in `full` mode.** Do not talk yourself down to `checkpoint`
out of caution; declare less only if the user restricted the session or a
capability has actually been refused. `start-session.sh` with no flags
declares the full set, so the plain call is the right call there.

Everywhere else, three questions: can you run a sub-agent that keeps working
while you continue (`observer`)? hooks or lifecycle callbacks (`hooks`)? a
periodic background task (`background_tasks`)? Then:

| Answers | Mode | What you do |
| --- | --- | --- |
| all three | **full** | Observer runs at transitions and on trigger events; hooks report task transitions. |
| observer only | **observer** | You invoke the observer manually at meaningful transitions. |
| neither, but a roadmap exists | **checkpoint** | Report at task transitions; snapshot at each phase boundary. |
| none | **fallback** | Self-reporting only; no derived events, no snapshots. |

Pass detected capabilities as repeated `--capability` flags (valid: `roadmap`,
`tasks`, `subagents`, `observer`, `hooks`, `tests`, `builds`, `artifacts`,
`deployments`, `background_tasks`). The server negotiates the final mode into
`state/session.json` as `reportingMode`; offline, the skill negotiates the
same rules locally. Do not claim a capability you do not have — a `full`
session with no observer looks alive and reports nothing.

**The observer is event-driven, not a metronome.** Run it at phase
boundaries, after any completion claiming verification, and on the trigger
events the policy lists; the interval (`reporting.observerIntervalSeconds`,
default 600s) is the fallback for long silent stretches, not a schedule to
fill. Every observer run is a whole agent invocation — spend it where a claim
needs checking.

## 5. Rules for the MAIN agent

You own structure and orchestration. **Whoever does the work reports it**: if
you delegate, the sub-agent reports (§7); **if you do the task yourself, §6's
table is yours** under `--agent-id main-agent`. Working alone is the ordinary
case and excuses nothing.

**Every task you declared ends** in exactly one of `task.completed`,
`task.failed`, `task.blocked`, or leaves via `roadmap.updated`. Before
completing the session, sweep the roadmap: a task with no terminal event reads
as unfinished forever, and progress is arithmetic on what you sent — thirteen
declared tasks with one completion reads as 8%, finished or not.

| Event | When |
| --- | --- |
| `roadmap.created` | Once, as soon as it exists: phases, tasks, weights, whole. |
| `roadmap.updated` | The roadmap changes shape. |
| `phase.started` / `phase.completed` | A phase actually begins / all its tasks are done. |
| `task.created` / `task.assigned` | Added to the roadmap / handed to an agent (`--task-assignee`). |
| `agent.created` / `agent.stopped` | You spin up or shut down a sub-agent. |
| `decision.required` | **A HUMAN answer is needed.** Question + options. |
| `decision.resolved` | The answer arrived — or you made the call yourself. |
| `project.*` | Lifecycle changes (paused/resumed/completed/failed). |

**Decisions route by who must answer.** `decision.required` puts the question
in the user's attention queue — right when only they can answer, wrong when a
sub-agent asked *you*. A call you make yourself is ONE `decision.resolved`
(question + options + answer together): it lands in the history marked
"answered by the agent" and never demands attention. If you sent
`decision.required` and then answered it yourself, send `decision.resolved`
immediately.

Your identity: `--agent-id main-agent --role orchestrator --kind main`.

## 6. Rules for the agent DOING THE WORK

Same events whether it is a sub-agent (put these in its prompt with its own
id/role) or you working alone.

| Event | When |
| --- | --- |
| `task.started` | You begin a task. |
| `task.progress` | A real milestone (`--progress N`). Not a timer, not per file. |
| `task.completed` | Done **and** verification finished. |
| `task.failed` / `task.blocked` | You cannot deliver / something external stops you (include a blocker). |
| `test.*` / `build.*` | You ran tests or builds. Counts, never output. |
| `artifact.created` | You produced something the user can look at. |

**Artifacts carry URLs when one exists** — a deployed preview, a published
page, a Claude Artifact you just published: put the address in
`--artifact-url` the moment you have it. An artifact without a URL is a name
nobody can open.

**Evidence is uploaded, not described.** A screenshot of the working page, a
failing test's report: `upload-artifact.sh FILE --kind screenshot
--artifact-id X` does upload + confirmation + `artifact.created` in one call;
cite it from the claim with `--evidence-artifact-id X`. For e2e/browser runs,
report the run first, then attach one screenshot per *meaningful* step with
`--test-run-id RUN --step N --step-status passed|failed` — the panel renders
them as the run's visual flow. The failing step always, context steps
sparingly, never a frame-by-frame recording. Only evidence types are accepted
(images, text, csv, json, xml, pdf, zip — never HTML) and uploads count
against the plan's storage allowance. If an upload fails, say so in one line,
report the artifact without a URL if still worth it, and keep working.

Use one stable `--agent-id` all session — the panel groups by it. Liveness is
not your job (the heartbeat daemon has it); **what changed is**. Report at
boundaries in the work — a module working, a command passing — not on a clock
you do not have. A task taking a dozen edits gets `task.progress` on the way
through; eleven files written in silence is an invisible task, and that is
exactly what the panel showed the first time this skill met a real project.
`--summary` is the one sentence somebody reads instead of asking you.

## 7. The dual-report rule

Only when you delegated. A sub-agent reports the same development **twice**:
to the main agent as prose, and to the API by calling `report-event.sh`
itself. **The main agent never relays a sub-agent's event** — not a summary,
not a re-send, not "on behalf of". To comment on one, emit a separate
`task.reviewed` with `--parent-event-id` pointing at the original
(`report-event.sh` prints each event id on stdout; capture it if needed).

## 8. The four rules that decide what you send

- **Completion:** never `task.completed` before verification finishes. Tests
  exist → run them, report `--verification-method test --verification-result
  passed|failed`. Nothing verifiable → `--verification-method none` and the
  observer assesses. An unevidenced completion shows as an unverified claim.
- **Privacy:** metadata only — never secrets, env values, credentials, source
  code, diffs, or terminal output. The local secret filter is a safety net,
  not a licence.
- **Progress:** derived from roadmap task weights, never elapsed time.
- **Duplication:** one real event, one `eventId`. Retries are safe (the API
  dedupes); never re-send someone else's event under a new id.

**Never report:** per-file edits, per-command output, log lines, time-based
percentages, your own reasoning or prompts, code or stack traces, or anything
already reported and unchanged. Full decision table:
`references/reporting-rules.md`.

## 9. When the API is unreachable

**Development never stops** — the scripts enforce it: `report-event.sh`
queues to `state/pending-events.jsonl` and exits 0; `start-session.sh` writes
an offline session so reporting begins anyway; `fetch-schema.sh` falls back to
the cached bundle then `references/fallback-schema.json`; heartbeats give up
silently (a late heartbeat is a lie). Drain with
`scripts/flush-pending-events.sh` — in order, batches of ≤100, API dedupes,
permanent rejections go to `state/dead-letter.jsonl`. Session open/close call
it for you. Tell the user once: "The monitoring API is unreachable; events are
queued locally and will be sent when it is back." Keep working.

**A 401/403 is different and must be said out loud**: the API is refusing the
token. Events are *held* (`deadLetterKind: credential` — never discarded, only
`payload` rejections are), and the next successful `start-session.sh` replays
them (≤200 per handshake, ≤once per 5 min; events older than 72h are retired
rather than replayed onto a live timeline). The fix is a credential and
nothing else: `scripts/pair.sh`, then `scripts/start-session.sh`. Tell the
user once, plainly: "The monitoring token was refused — expired, revoked, or
scoped elsewhere. Events are held on this machine; run `scripts/pair.sh` and
they will be sent." Inspect or force a replay with
`flush-pending-events.sh [--dry-run] --replay-dead-letters`.

## 10. Reference

- `references/examples.md` — worked examples for every situation above.
- `references/event-types.md` — every event type, who may emit it, required fields.
- `references/reporting-rules.md` — the "when do I report" decision table.
- `references/fallback-schema.json` — offline protocol bundle (scripts use it; you never need to read it).
- `agents/project-observer.md` — the Project Observer sub-agent definition.

Verify the package any time, offline: `bash scripts/self-test.sh`.
