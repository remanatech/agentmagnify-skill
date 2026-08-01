# Event types

Every event type the protocol defines, who may emit it, and what it must carry
beyond the envelope. Generated against protocol `2026-07-31.1`; the authoritative
list is `references/fallback-schema.json` and, when the API is reachable,
`state/schema.json`.

## The envelope

Every event, of every type, carries these fields. `report-event.sh` fills all of
them in for you.

| Field | Meaning |
| --- | --- |
| `eventId` | Client-generated, unique. Doubles as the idempotency key. |
| `projectId` | Optional on the wire: the server resolves it from the token. |
| `sessionId` | The monitoring session this event belongs to. |
| `protocolVersion` | Pinned for the life of the session. |
| `sequence` | Monotonic per session. Orders replay when events arrive late. |
| `type` | One of the types below. |
| `timestamp` | RFC3339 UTC, when it happened on the agent side. |
| `reporter` | `agentId`, and normally `role` and `kind` (`main`, `logical`, `observer`). |

Optional on any event: `summary`, `parentEventId`, `severity`, `metadata`,
`verification`, `evidence`, `progress`.

## Sizes and limits

| Limit | Value |
| --- | --- |
| Summary length | 2000 characters |
| Title length | 300 characters |
| Id length | 128 characters, `[A-Za-z0-9._:-]` |
| Payload size | 262144 bytes |
| Batch size | 100 events |

## Types

### Project

| Event | Who may emit | Required beyond the envelope |
| --- | --- | --- |
| `project.created` | Main agent | - |
| `project.started` | Main agent | - |
| `project.paused` | Main agent | - |
| `project.resumed` | Main agent | - |
| `project.completed` | Main agent | - |
| `project.failed` | Main agent | - |
| `project.archived` | Main agent | - |

### Session

| Event | Who may emit | Required beyond the envelope |
| --- | --- | --- |
| `session.started` | Skill (API records it on handshake) | - |
| `session.snapshot` | Observer | - |
| `session.completed` | Skill (`complete-session.sh`) | - |
| `session.interrupted` | Skill (`complete-session.sh`) | - |

### Roadmap and phase

| Event | Who may emit | Required beyond the envelope |
| --- | --- | --- |
| `roadmap.created` | Main agent | `roadmap` |
| `roadmap.updated` | Main agent | `roadmap` |
| `phase.created` | Main agent | `phase` |
| `phase.started` | Main agent | `phase` |
| `phase.progress` | Main agent | `phase` |
| `phase.completed` | Main agent | `phase` |
| `phase.blocked` | Main agent | `phase` |

### Task

| Event | Who may emit | Required beyond the envelope |
| --- | --- | --- |
| `task.created` | Main agent | `task` |
| `task.assigned` | Main agent | `task`, `task.assigneeAgentId` in practice |
| `task.started` | Sub-agent | `task` |
| `task.progress` | Sub-agent | `task`, `progress`, `progress` |
| `task.completed` | Sub-agent | `task` |
| `task.failed` | Sub-agent | `task` |
| `task.blocked` | Sub-agent | `task` |
| `task.reopened` | Main agent | `task` |
| `task.reviewed` | Main agent | `task` |

### Agent

| Event | Who may emit | Required beyond the envelope |
| --- | --- | --- |
| `agent.created` | Main agent | `agent` |
| `agent.started` | Sub-agent (about itself) | `agent` |
| `agent.working` | Sub-agent (about itself) | `agent` |
| `agent.idle` | Sub-agent (about itself) | `agent` |
| `agent.blocked` | Sub-agent (about itself) | `agent` |
| `agent.completed` | Sub-agent (about itself) | `agent` |
| `agent.failed` | Sub-agent (about itself) | `agent` |
| `agent.stopped` | Main agent | `agent` |

### Blocker and decision

| Event | Who may emit | Required beyond the envelope |
| --- | --- | --- |
| `blocker.created` | Sub-agent or main agent | `blocker` |
| `blocker.updated` | Sub-agent or main agent | `blocker` |
| `blocker.resolved` | Sub-agent or main agent | `blocker` |
| `decision.required` | Main agent | `decision` |
| `decision.resolved` | Main agent | `decision` |
| `decision.expired` | Main agent or observer | `decision` |

### Test and build

| Event | Who may emit | Required beyond the envelope |
| --- | --- | --- |
| `test.started` | Sub-agent | `test` |
| `test.passed` | Sub-agent | `test` |
| `test.failed` | Sub-agent | `test`, `test.failed` > 0 |
| `build.started` | Sub-agent | `build` |
| `build.completed` | Sub-agent | `build` |
| `build.failed` | Sub-agent | `build` |

### Artifact and deployment

| Event | Who may emit | Required beyond the envelope |
| --- | --- | --- |
| `artifact.created` | Sub-agent | `artifact` |
| `artifact.updated` | Sub-agent | `artifact` |
| `deployment.started` | Sub-agent | `deployment` |
| `deployment.completed` | Sub-agent | `deployment` |
| `deployment.failed` | Sub-agent | `deployment` |

### Observer and verification

Only an event whose `reporter.kind` is `observer` may carry these types. The API rejects them from anyone else.

| Event | Who may emit | Required beyond the envelope |
| --- | --- | --- |
| `agent.stale` | **Observer only** | `agent` |
| `snapshot.created` | **Observer only** | - |
| `progress.recalculated` | **Observer only** | `progress` |
| `completion.verified` | **Observer only** | `task` |
| `completion.disputed` | **Observer only** | `task`, `assessment`, `assessment.reason` |
| `project.stale` | **Observer only** | - |
| `risk.detected` | **Observer only** | `summary` |
| `status.corrected` | **Observer only** | `assessment` |
| `heartbeat` | Observer or skill (`send-heartbeat.sh`) | - |

## Notes

- **`task.*` always needs `task.id`.** A task event without an id cannot be
  attached to the roadmap, and the API rejects it.
- **`task.completed` should carry verification.** Either a real result
  (`--verification-method test --verification-result passed --verification-passed N`)
  or an explicit `--verification-method none`. The observer treats an unverified
  completion as a claim, not a fact.
- **`test.failed` must report at least one failing test.** `--test-failed 0` with
  type `test.failed` is a contradiction and is rejected locally before it is sent.
- **`task.reviewed` is how the main agent comments on a sub-agent's event.** It
  carries `--parent-event-id`. It is never a re-send of the sub-agent's event.
- **`agent.*` events need an agent object.** When a sub-agent reports about itself,
  `report-event.sh` derives it from the reporter identity; use `--about-agent-*`
  when you are describing a different agent.
- **Observer types are gated on `reporter.kind`.** `--kind observer` is not a
  formality: without it the API rejects the event.
- **Everything is append-only.** A type is never removed from this list, because
  replay of historical data depends on old types staying valid.
