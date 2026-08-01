---
name: agentmagnify
description: Report live project state to AgentMagnify. Use at the start of any coding session that builds or changes a project, and whenever a task, phase, test, build, blocker or decision changes state. Covers session startup, main-agent and sub-agent reporting rules, the Project Observer, and the offline event queue.
---

# AgentMagnify

This skill turns what your agents are already doing into a live project record the
user can watch from a panel: roadmap, phases, tasks, which agent is on what, test
and build evidence, blockers, decisions, and an independent verification of every
completion claim.

You report; you do not stop working to report. Every helper script in this package
exits 0 on a network failure and queues the event locally instead.

## 1. When this skill is active

Activate it when all of the following are true:

- the session is doing project work (building, refactoring, testing, shipping) and
  not answering a one-off question
- `scripts/login.sh --status` succeeds, meaning a credential resolves from
  somewhere

Check the credential with that command, not by looking for an environment
variable. The recommended setup is `pair.sh`, which stores the token in
`~/.agentmagnify/credentials.json` and exports nothing — so a machine that is
correctly paired has no `AGENTMAGNIFY_TOKEN`, and treating that variable as
the test would switch this skill off exactly where it is meant to be on.

If no credential resolves, say so once, in one line, and continue working
normally. Do not ask for it repeatedly and do not block on it.

### Configuration

Nothing has to be exported. The user runs one command per machine and every
project reuses it:

```bash
bash scripts/pair.sh
```

That prints a short code and waits. The user opens the panel, signs in, types
the code, sees which machine is asking and what it will be able to do, and
approves. The token then arrives over the connection the script already has
open. Nothing is displayed for anybody to copy, which is the point: a secret
read off a screen and pasted into a terminal is a secret in shell history and
in every screenshot of that window afterwards.

Where there is no person and no browser — CI, a container, an image build — the
old path is unchanged and is the right one:

```bash
bash scripts/login.sh wsi_live_xxxxxxxx    # or set AGENTMAGNIFY_TOKEN
```

The scripts resolve the credential themselves, first hit wins:

1. `AGENTMAGNIFY_TOKEN` in the environment — CI and one-off overrides
2. `.agentmagnify.local.json` in the project (git-ignored) — a project that
   needs its own scoped token
3. `~/.agentmagnify/credentials.json` — written by `pair.sh` or `login.sh`,
   mode 0600

And the project identity, also first hit wins:

1. `AGENTMAGNIFY_PROJECT_NAME`
2. `.agentmagnify.json` in the project — **committed, and never holds a
   token**. The scripts refuse to run if a token appears in it, because that
   file is meant to be shared.
3. The git remote's repository name, else the directory name

With a workspace ingestion token that means a new repository needs no setup at
all: the project is created on first contact under its own name.

If reporting is not configured, say so once and carry on with the real work.

| Variable | Required | Meaning |
| --- | --- | --- |
| `AGENTMAGNIFY_TOKEN` | no | Overrides the stored credential. Never print it, never echo it, never write it into a file you create. |
| `AGENTMAGNIFY_API_URL` | no | API base URL. Defaults to `https://api.agentmagnify.com`. Set it for a self-hosted installation. |
| `AGENTMAGNIFY_PROJECT_NAME` | no | Overrides the inferred project name. Only meaningful with a `wsi_live_` token; a `prj_live_` token is already bound to one project. |

Optional, rarely needed: `AGENTMAGNIFY_AGENT_ID`, `AGENTMAGNIFY_AGENT_ROLE`,
`AGENTMAGNIFY_AGENT_KIND` (per-agent reporting identity defaults),
`AGENTMAGNIFY_EXECUTOR` (`claude-code`, `codex`, `cursor`, `aider`, `custom`, or
any other name -- an unrecognised one reports as `custom` and is carried through
as the label, so an environment this list has never heard of still says what it
is), `AGENTMAGNIFY_EXECUTOR_LABEL` (overrides that label outright),
`AGENTMAGNIFY_CAPABILITIES` (space-separated capability override),
`AGENTMAGNIFY_DEBUG=1` (verbose logging to stderr).

## 2. Startup sequence

Run this once, at the beginning of the session, before creating any sub-agent.

```bash
# 1. Verify a credential can be resolved. Never prints the token itself.
scripts/login.sh --status

# 2+3+4. Handshake, cache the protocol bundle, create the session.
scripts/start-session.sh
```

`start-session.sh` does the whole handshake in one step:

1. **Verify the token.** A missing or rejected token degrades to offline mode; it
   never aborts the session.
2. **Handshake.** `POST /v1/agent/sessions` with the client name
   `agentmagnify-skill` version `0.1.0`, the detected executor, and the
   capabilities from section 4.
3. **Cache the schema and policy.** It then calls `fetch-schema.sh` for the exact
   protocol version the server pinned this session to, and stores the JSON Schema,
   the reporting policy and the agent instructions in `state/schema.json`.
   The protocol version does not change for the life of the session.
4. **Create the session.** `state/session.json` holds the session id, project id,
   protocol version, reporting policy, panel URL and reporting mode.
5. It prints the **panel URL** on stdout. Show that URL to the user once.

Then you do the remaining three steps yourself:

6. **Inject the reporting rules into the main agent** - that is you. Section 5 is
   the rule set. Keep it in working memory for the rest of the session.
7. **Inject the reporting rules into every sub-agent you create.** Every sub-agent
   prompt must carry: its `--agent-id`, its `--role`, `--kind logical`, the
   sub-agent rules from section 6, and the dual-report rule from section 7. A
   sub-agent that was not told to report will not report, and the panel will show
   a silent agent.
8. **Start the Project Observer** (`agents/project-observer.md`) as a background
   sub-agent, and **enable the routine check**: the observer runs every
   `reporting.observerIntervalSeconds` (default 120s) and after any event listed in
   `reporting.runObserverOnEvents`. If your platform cannot run background tasks,
   see section 4.

At the end of the session:

```bash
scripts/complete-session.sh --summary "One or two sentences on what was delivered and what is still open."
```

This drains the offline queue, sends the closing snapshot, and closes the session.
A session that is never completed shows up in the panel as `interrupted`, which is
the honest reading - so run it, and do not run it early.

## 3. The scripts

All of them live in `scripts/` and are safe to call at any time.

| Script | Use |
| --- | --- |
| `start-session.sh` | Open the session. Prints the panel URL. |
| `report-event.sh` | Send one event. The main entry point. |
| `send-snapshot.sh` | Send a project snapshot. Observer only, plus session close. |
| `send-heartbeat.sh` | Keep the session alive during long silent work. |
| `flush-pending-events.sh` | Drain the offline queue. `--replay-dead-letters` also re-sends what a refused credential held back. Safe to call repeatedly. |
| `complete-session.sh` | Close the session. |
| `fetch-schema.sh` | Refresh the cached protocol bundle. Called by `start-session.sh`. |
| `self-test.sh` | Offline verification of this package. |

`report-event.sh --help` lists every flag. The shape is always the same:

```bash
scripts/report-event.sh \
  --type task.completed \
  --task-id auth-api --task-title "Authentication API" \
  --agent-id backend-developer --role backend --kind logical \
  --summary "Authentication endpoints and token rotation implemented." \
  --verification-method test --verification-result passed \
  --verification-passed 18 --verification-failed 0 \
  --evidence-changed-files 7 --evidence-commit a81f93c
```

It fills in `eventId`, `sessionId`, `projectId`, `protocolVersion`, `sequence` and
`timestamp` for you. You supply the meaning.

## 4. Capability detection and reporting modes

Not every agent platform supports background sub-agents, hooks or periodic tasks.
Decide the mode once, at startup, before creating the observer.

**Decision procedure.** Answer three questions about the platform you are running
on right now:

1. Can you run a **sub-agent** that keeps working while you continue? -> `observer`
2. Can you run **hooks or lifecycle callbacks** on task and tool events? -> `hooks`
3. Can you run a **periodic or background task** on a timer? -> `background_tasks`

Then:

| Answers | Mode | What you do |
| --- | --- | --- |
| all three yes | **full** | Observer runs on its interval and on trigger events. Hooks report task transitions automatically. |
| observer yes, hooks or background tasks no | **observer** | Observer runs, but you invoke it manually at meaningful transitions instead of on a timer. |
| no observer, but you have a task list or roadmap | **checkpoint** | No observer. You and your sub-agents report at meaningful task transitions only. Send a snapshot at each phase boundary. |
| none of the above | **fallback** | Self-reporting only: main agent and sub-agents send their own events. No derived events, no snapshots. |

Pass what you detected to the handshake so the server records the same mode:

```bash
scripts/start-session.sh \
  --capability roadmap --capability tasks --capability subagents \
  --capability observer --capability hooks --capability tests \
  --capability builds --capability artifacts --capability background_tasks
```

Valid capabilities: `roadmap`, `tasks`, `subagents`, `observer`, `hooks`, `tests`,
`builds`, `artifacts`, `deployments`, `background_tasks`.

The server negotiates the final mode and writes it to `state/session.json` as
`reportingMode`. Read it back if you need to branch on it. When the API is
unreachable, the skill negotiates the same mode locally from the same rules.

Do not claim a capability you do not have. A `full` mode session with no observer
produces a panel that looks alive and reports nothing.

## 5. Reporting rules for the MAIN agent

You own the project level: structure and orchestration.

**Whoever does the work reports it.** If you delegate a task, the sub-agent
reports it and you do not (§7). **If you do the task yourself, §6's table is
yours** - `task.started`, `task.completed`, `test.*`, `build.*`,
`artifact.created`, all of it, under your own `--agent-id main-agent`.

This is not a footnote. Working alone is the ordinary case: nothing in this
skill asks you to create sub-agents, and most sessions have none. §6 exists so
that a sub-agent reports its own work instead of you relaying it. It does not
exist to excuse anybody from reporting work that nobody else did.

**Every task you declared ends.** A task in the roadmap you sent finishes in
exactly one of `task.completed`, `task.failed` or `task.blocked`, or leaves the
roadmap through `roadmap.updated`. Before `complete-session.sh`, go through the
roadmap and check: any task with no terminal event is a task the panel still
believes is unfinished.

The panel's progress figure is arithmetic on what you sent, not an opinion. A
roadmap declaring thirteen tasks against which one completion arrived reads as
eight per cent, and it reads that way whether or not the work was finished -
which is exactly what happened the first time this skill was used on a real
project.

| Event | When |
| --- | --- |
| `roadmap.created` | Once, as soon as the roadmap exists. Send the whole roadmap: phases, tasks, weights. |
| `roadmap.updated` | The roadmap changes shape: a phase or task is added, removed, re-scoped or re-weighted. |
| `phase.started` / `phase.completed` | A phase actually begins or all of its tasks are done. |
| `task.created` | A task is added to the roadmap. |
| `task.assigned` | A task is handed to a specific agent. Include `--task-assignee`. |
| `agent.created` / `agent.stopped` | You spin up or shut down a sub-agent. |
| `decision.required` | You need a human answer to continue. Include the question and the options. |
| `project.paused` / `project.resumed` / `project.completed` / `project.failed` | The project's lifecycle changes. |

```bash
# The roadmap, once.
scripts/report-event.sh --type roadmap.created --agent-id main-agent --role orchestrator --kind main \
  --summary "Roadmap created: 4 phases, 18 tasks." \
  --roadmap-json roadmap.json

# Creating a sub-agent.
scripts/report-event.sh --type agent.created --agent-id backend-developer --role backend --kind logical \
  --summary "Backend developer agent created for the authentication phase."

# Handing over a task.
scripts/report-event.sh --type task.assigned --task-id auth-api --task-title "Authentication API" \
  --task-assignee backend-developer --agent-id main-agent --role orchestrator --kind main

# Needing a human.
scripts/report-event.sh --type decision.required --decision-id queue-choice \
  --decision-question "Redis or an in-memory queue for the workflow engine?" \
  --decision-option "Redis" --decision-option "In-memory" \
  --severity high --agent-id main-agent --role orchestrator --kind main
```

Your reporter identity is `--agent-id main-agent --role orchestrator --kind main`.

## 6. Reporting rules for the agent DOING THE WORK

If you delegated the task, put these in the sub-agent's prompt with its own id
and role. **If you are doing the task yourself, they are yours** - same events,
same timing, reported as `main-agent`.

| Event | When |
| --- | --- |
| `task.started` | You begin work on a task. |
| `task.progress` | A meaningful milestone inside the task. Include `--progress N`. Not on a timer, not per file. |
| `task.completed` | The work is done **and** verification has finished. |
| `task.failed` | You cannot deliver the task. |
| `task.blocked` | Something outside your control stops you. Include a blocker. |
| `test.started` / `test.passed` / `test.failed` | You ran tests. Report counts, not output. |
| `build.started` / `build.completed` / `build.failed` | You ran a build. |
| `artifact.created` | You produced something the user can look at: an endpoint, a page, a package, a migration. |

```bash
scripts/report-event.sh --type task.started --task-id auth-api --task-title "Authentication API" \
  --agent-id backend-developer --role backend --kind logical \
  --summary "Starting the authentication endpoints."

scripts/report-event.sh --type test.failed --test-suite auth --test-command "npm test -- auth" \
  --test-passed 15 --test-failed 3 --test-failing "rotates refresh tokens" \
  --agent-id backend-developer --role backend --kind logical \
  --summary "3 of 18 authentication tests fail on token rotation."

scripts/report-event.sh --type task.blocked --task-id workflow-queue \
  --blocker-id redis-down --blocker-title "Redis connection refused on port 6379" \
  --blocker-severity high \
  --agent-id backend-developer --role backend --kind logical \
  --summary "Cannot continue the queue implementation without Redis."
```

Every agent uses a stable `--agent-id` for the whole session. The panel groups
by it: change it mid-session and one agent becomes two.

Working alone, all of this is still owed. The commonest way to leave a project
looking abandoned is to send the roadmap, start a phase, and then go quiet for
an hour of real work - the panel has no way to tell that apart from an agent
that stopped.

## 7. The dual-report rule

Only relevant when you delegated the work. Alone, there is nobody to report to
but the API, and §5 and §6 already say what you owe it.

A sub-agent reports the same development **twice, in two formats, to two targets**:

1. to the main agent, as a natural work report, in prose;
2. to the Monitoring API, as a structured event, by calling `report-event.sh`
   itself.

**The main agent never relays a sub-agent's event.** Not a summary of it, not a
re-send of it, not a "reporting on behalf of". The main agent is not a reporting
bottleneck, and a relayed event is a second, false record of one real thing.

If the main agent wants to comment on a sub-agent's report, it emits a **separate**
event that points at the original:

```bash
scripts/report-event.sh --type task.reviewed --task-id auth-api \
  --parent-event-id evt_01K...            # the sub-agent's task.completed event id \
  --agent-id main-agent --role orchestrator --kind main \
  --summary "Accepted for QA verification."
```

`report-event.sh` prints the event id it sent on stdout, so capture it when you
need to reference it later:

```bash
EVENT_ID="$(scripts/report-event.sh --type task.completed ... | cut -d' ' -f1)"
```

## 8. The four rules that decide what you send

**Completion rule.** Never report `task.completed` before the required
verification has finished. If tests exist, run them first, then report with
`--verification-method test --verification-result passed|failed`. If no
verification is possible, report completion with `--verification-method none` and
let the observer assess it. A completion claim with no evidence is a claim, and the
panel will show it as unverified.

**Privacy rule.** Never send secrets, environment variable values, credentials,
private keys, tokens, source code blocks or full terminal output. Report metadata
only: task name, status, short summary, counts, commit hash, changed-file count,
agent id. The skill runs a local secret filter over every payload before it leaves
the machine and the API filters again on arrival - but the filter is a safety net,
not a licence to paste logs into a summary.

**Progress rule.** Progress is derived from roadmap task weights, never from
elapsed time. "40% because we are 40 minutes into an hour" is not progress.
"40% because 2 of 5 weighted tasks in this phase are done" is. Only report
`task.progress` at a real milestone.

**Duplication rule.** One real event, one `eventId`. The API deduplicates by
`eventId`, so a retry is safe and a duplicate is recorded as a duplicate, not as a
second event. Never re-send someone else's event under a new id.

## 9. What NOT to report

- per-file edits, per-command output, or anything you would call a log line
- time-based percentages
- your own internal reasoning or prompts
- source code, diffs, file contents, stack traces
- anything you already reported and that has not changed

See `references/reporting-rules.md` for the full decision table.

## 10. When the API is unreachable

**Development never stops.** That is the rule, and the scripts are built to enforce
it rather than trust you to remember it:

- `report-event.sh` appends the event to `state/pending-events.jsonl` and exits 0.
- `start-session.sh` writes a local offline session so reporting can begin anyway,
  and marks the protocol `unverified`.
- `fetch-schema.sh` falls back to the cached bundle, and then to
  `references/fallback-schema.json`.
- `send-heartbeat.sh` gives up silently: a late heartbeat is a lie about liveness.
- Nothing waits, nothing retries forever, nothing aborts your work.

Drain the queue when the API is back:

```bash
scripts/flush-pending-events.sh
```

It sends in order, in batches of at most 100, lets the API deduplicate, removes
what was accepted, and moves permanently rejected events to
`state/dead-letter.jsonl` rather than retrying them forever.
`start-session.sh` and `complete-session.sh` call it for you. If the queued events
were recorded before any session existed, the flush opens a real session first and
rewrites their session id.

Tell the user once, plainly: "The monitoring API is unreachable; events are being
queued locally and will be sent when it is back." Then keep working.

## 10.1 When the credential is refused

A 401 or 403 is not the same failure as an unreachable API, and it is the one you
have to say out loud. The API is answering; it is refusing the token. Nothing you
report will arrive until somebody issues a new one, and the panel will show the
project going quiet without saying why.

The scripts still exit 0 — monitoring never stops development — but they do two
things differently:

- the event goes to `state/dead-letter.jsonl` marked `deadLetterKind: credential`,
  which means *held*, not discarded. Anything the API refused on its own merits is
  marked `payload` and is never sent again.
- the next successful `start-session.sh` replays the held events automatically, at
  most 200 per handshake and at most once every five minutes. Events older than
  `AGENTMAGNIFY_QUEUE_MAX_AGE_HOURS` (72 by default) are retired instead of
  replayed: reporting a two-day-old "task started" onto a live timeline would say
  something that is no longer true.

So the fix is a credential, and nothing else:

```bash
scripts/pair.sh          # approve it in the panel; nothing to copy
scripts/start-session.sh # the held events go out on their own
```

Tell the user once, and do not bury it: "The monitoring token was refused — it is
expired, revoked, or scoped to another project. Reporting is paused and the events
are being held on this machine. Run `scripts/pair.sh` and they will be sent." Then
keep working.

To send them without opening a session, or to see what is held:

```bash
scripts/flush-pending-events.sh --dry-run --replay-dead-letters
scripts/flush-pending-events.sh --replay-dead-letters
```

## 11. Quick start

```bash
export AGENTMAGNIFY_TOKEN=prj_live_xxxxxxxxxxxx
export AGENTMAGNIFY_API_URL=https://api.your-monitor.example

# Open the session. Prints the panel URL.
scripts/start-session.sh

# Main agent: publish the roadmap.
scripts/report-event.sh --type roadmap.created --roadmap-json roadmap.json \
  --agent-id main-agent --role orchestrator --kind main \
  --summary "Roadmap created: 4 phases, 18 tasks."

# Sub-agent: start, then finish with evidence.
scripts/report-event.sh --type task.started --task-id auth-api --task-title "Authentication API" \
  --agent-id backend-developer --role backend --kind logical \
  --summary "Starting the authentication endpoints."

scripts/report-event.sh --type task.completed --task-id auth-api \
  --agent-id backend-developer --role backend --kind logical \
  --summary "Authentication endpoints and token rotation implemented." \
  --verification-method test --verification-result passed \
  --verification-passed 18 --verification-failed 0 \
  --evidence-changed-files 7 --evidence-commit a81f93c

# Close the session.
scripts/complete-session.sh --summary "Authentication delivered; workflow engine still open."
```

## 12. Reference

- `references/event-types.md` - every event type, who may emit it, required fields.
- `references/reporting-rules.md` - the "when do I report" decision table.
- `references/fallback-schema.json` - the offline copy of the protocol bundle.
- `agents/project-observer.md` - the Project Observer sub-agent definition.

Verify the package at any time, with no network:

```bash
bash scripts/self-test.sh
```
