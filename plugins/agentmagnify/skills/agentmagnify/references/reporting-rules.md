# Reporting rules

The question this file answers is always the same: **did something meaningful
change in the project?** If yes, report it once, from whoever it happened to. If
no, stay silent.

## Main agent

You own structure and orchestration. You never report a sub-agent's work.

| Trigger | Event | Notes |
| --- | --- | --- |
| The roadmap exists for the first time | `roadmap.created` | Send the whole roadmap: phases, tasks, weights. Once. |
| A phase or task is added, removed, re-scoped or re-weighted | `roadmap.updated` | Not for a task changing status - that is `task.*`. |
| A phase actually begins | `phase.started` | |
| All tasks in a phase are done | `phase.completed` | After the last task is complete, not when you plan to finish. |
| A phase cannot proceed | `phase.blocked` | |
| A task is added to the roadmap | `task.created` | |
| A task is handed to an agent | `task.assigned` | Include `--task-assignee`. |
| You create a sub-agent | `agent.created` | Use the same `agentId` the sub-agent will report under. |
| You shut a sub-agent down | `agent.stopped` | |
| You need a human answer to continue | `decision.required` | Include the question, the options and a severity. |
| The user answers | `decision.resolved` | |
| The project pauses, resumes, finishes or fails | `project.*` | Lifecycle only. |
| You want to comment on a sub-agent's event | `task.reviewed` | With `--parent-event-id`. Never a re-send. |

Identity: `--agent-id main-agent --role orchestrator --kind main`.

## Sub-agent

You own your own work, and only your own work.

| Trigger | Event | Notes |
| --- | --- | --- |
| You begin a task | `task.started` | Once per task. |
| You hit a real milestone inside the task | `task.progress` | With `--progress N` derived from the task's own sub-structure. Not on a timer. |
| The work is done and verification finished | `task.completed` | With verification, or an explicit `--verification-method none`. |
| You cannot deliver it | `task.failed` | Say why in one sentence. |
| Something outside your control stops you | `task.blocked` | Include a blocker id, title and severity. |
| The blocker clears | `blocker.resolved` | |
| You start a test run | `test.started` | Optional; useful for long suites. |
| A test run finishes | `test.passed` / `test.failed` | Counts and up to a few failing test names. Never the output. |
| A build runs | `build.started` / `build.completed` / `build.failed` | Duration and a one-line error summary. |
| You produced something the user can look at | `artifact.created` | Endpoint, page, package, migration, report. |
| You deployed | `deployment.*` | Environment, status, URL. |

Identity: a stable `--agent-id`, your `--role`, and `--kind logical`. Use the same
agent id all session long: change it and the panel sees two agents.

**Report to both targets.** The main agent gets your natural prose report; the API
gets the structured event, sent by you. The main agent is not your courier.

## Observer

You never report what happened. You report what the evidence says about what was
reported.

| Trigger | Event | Notes |
| --- | --- | --- |
| A routine check produced a full picture | `snapshot.created` (via `send-snapshot.sh`) | On the snapshot interval, after a roadmap change, after a correction, at session close. |
| Your weighted recomputation differs from the reported number | `progress.recalculated` | Send roadmap, reported and verified progress together. |
| A completion claim is backed by evidence you checked | `completion.verified` | Name the evidence: passing tests, commit, artifact. |
| A completion claim is contradicted by evidence | `completion.disputed` | `assessment.reason` is mandatory. |
| An agent has not reported inside the stale window with an open task | `agent.stale` | |
| Nobody has reported anything inside the stale window | `project.stale` | |
| Something is heading for failure | `risk.detected` | Repeated test failures, an aging blocker, scope drifting off the roadmap. |
| A recorded status is wrong | `status.corrected` | State the correct one and why. |
| Nothing happened at all | `send-heartbeat.sh` | A heartbeat, not an invented event. |

Identity: `--agent-id project-observer --role observer --kind observer`. The API
rejects observer event types from any other kind.

## What NOT to report - from anyone

| Never | Why | Instead |
| --- | --- | --- |
| Time-based percentages ("40% because 40 minutes passed") | Progress that is not derived from work done is a fiction the panel will present as fact. | Derive progress from roadmap task weights. |
| Per-file chatter ("edited auth.ts", "renamed a variable") | The panel is a project view, not a file watcher. It drowns. | One `task.progress` at a real milestone, with a changed-file count as evidence. |
| Terminal output, logs, stack traces | Noise, and a common way secrets escape. | Counts, exit status, a one-line error summary. |
| Source code, diffs, file contents | The platform deliberately never stores source. The filter strips fenced blocks. | `--evidence-changed-files`, `--evidence-commit`, `--evidence-branch`. |
| Secrets, tokens, env values, connection strings, private keys | Obvious, and the local filter is a safety net rather than a permit. | Nothing. Do not mention them at all. |
| Prompts, internal reasoning, tool call traces | Not project state. | The outcome, in one sentence. |
| The same event twice | The API deduplicates by `eventId`, but two ids for one real event become two records. | One event, one id. Comment with `task.reviewed` and `parentEventId`. |
| Another agent's event | The main agent is not a reporting bottleneck and must not relay. | Let the sub-agent report; comment separately. |
| A completion before verification finished | It is the single most damaging false signal the panel can carry. | Run the verification first, then report with its result. |
| Unchanged state on a schedule | `reportOnlyMeaningfulChanges` is true by default. | A heartbeat, or silence. |

## Cadence

| Policy field | Default | Meaning |
| --- | --- | --- |
| `observerIntervalSeconds` | 120 | How often the observer checks. |
| `snapshotIntervalSeconds` | 300 | How often a full snapshot goes out regardless of change. |
| `heartbeatIntervalSeconds` | 300 | How often to prove liveness when nothing is happening. |
| `reportOnlyMeaningfulChanges` | true | Silence is a valid report. |
| `runObserverOnEvents` | see policy | Events that wake the observer immediately. |

The panel derives liveness from these, so under-reporting has a visible cost:
no meaningful event within 300 seconds reads as `quiet`, and nothing at all within
900 seconds reads as `stale`.

## When in doubt

Ask: *if the user opened the panel right now, would this line change what they
understand about the project?*

- Yes -> report it once, from the agent it happened to, with evidence if you have
  any.
- No -> do not send it.
