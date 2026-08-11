# Worked examples

Copy-paste shapes for every reporting situation. The rules live in SKILL.md;
this file only shows what obeying them looks like. Read it when you are unsure
of a flag, not routinely.

## Quick start: a whole session

```bash
export AGENTMAGNIFY_TOKEN=prj_live_xxxxxxxxxxxx
export AGENTMAGNIFY_API_URL=https://api.your-monitor.example

# Open the session. Prints the panel URL.
scripts/start-session.sh

# Main agent: publish the roadmap.
scripts/report-event.sh --type roadmap.created --roadmap-json roadmap.json \
  --agent-id main-agent --role orchestrator --kind main \
  --summary "Roadmap created: 4 phases, 18 tasks."

# Sub-agent (or you, working alone): start, then finish with evidence.
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

## Main-agent events

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

# Needing a human: goes to the user's attention queue.
scripts/report-event.sh --type decision.required --decision-id queue-choice \
  --decision-question "Redis or an in-memory queue for the workflow engine?" \
  --decision-option "Redis" --decision-option "In-memory" \
  --severity high --agent-id main-agent --role orchestrator --kind main

# A call you made yourself: ONE decision.resolved, never decision.required
# first. It lands in the history marked "answered by the agent" and never
# asks for anybody's attention.
scripts/report-event.sh --type decision.resolved --decision-id retry-strategy \
  --decision-question "Retry failed webhook deliveries with backoff, or drop after one attempt?" \
  --decision-option "Exponential backoff, 5 attempts" --decision-option "Drop after one attempt" \
  --decision-answer "Exponential backoff, 5 attempts" \
  --agent-id main-agent --role orchestrator --kind main \
  --summary "Chose backoff with 5 attempts: webhook consumers are flaky and deliveries are idempotent."
```

## Doer events

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

## Artifacts with URLs (published pages, Claude Artifacts, previews)

```bash
scripts/report-event.sh --type artifact.created \
  --artifact-id sprint-report --artifact-name "Sprint report" --artifact-kind page \
  --artifact-url "https://claude.ai/artifacts/..." \
  --agent-id main-agent --role orchestrator --kind main \
  --summary "Published the sprint report as a Claude Artifact."
```

## Uploaded evidence (screenshots, reports)

```bash
# Upload + confirmation + artifact.created, one call. Then cite it.
scripts/upload-artifact.sh screenshot.png --kind screenshot --artifact-id login-page-shot \
  --summary "Login page rendering after the fix."

scripts/report-event.sh --type task.completed --task-id login-page \
  --verification-method test --verification-result passed \
  --evidence-artifact-id login-page-shot \
  --agent-id frontend-developer --role frontend --kind logical \
  --summary "Login page fixed; screenshot attached as evidence."
```

## Test-run visual flow (e2e / browser suites)

Report the run first (so its `--test-id` exists), then attach one screenshot
per meaningful step. The panel renders them as an ordered, pass/fail-badged
strip under the run.

```bash
scripts/report-event.sh --type test.failed --test-id e2e-checkout-7 --test-suite e2e-checkout \
  --test-passed 5 --test-failed 3 \
  --agent-id qa-engineer --role qa --kind logical \
  --summary "3 of 8 checkout e2e tests fail at the payment step."

scripts/upload-artifact.sh step1-login.png    --test-run-id e2e-checkout-7 --step 1 --step-status passed \
  --name "Login accepts the test account"  --summary "Captured after submitting credentials."
scripts/upload-artifact.sh step2-cart.png     --test-run-id e2e-checkout-7 --step 2 --step-status passed \
  --name "Cart shows the two items"        --summary "Captured on /cart with both fixtures added."
scripts/upload-artifact.sh step3-payment.png  --test-run-id e2e-checkout-7 --step 3 --step-status failed \
  --name "Payment step returns 500"        --summary "Captured after submit; the API answered 500."
```

## Commenting on a sub-agent's report (never relaying it)

```bash
scripts/report-event.sh --type task.reviewed --task-id auth-api \
  --parent-event-id evt_01K... \
  --agent-id main-agent --role orchestrator --kind main \
  --summary "Accepted for QA verification."

# Capturing an event id for later reference:
EVENT_ID="$(scripts/report-event.sh --type task.completed ... | cut -d' ' -f1)"
```

## Chaining consecutive reports

Several reports that belong to the same moment go out in ONE shell invocation:

```bash
scripts/report-event.sh --type phase.completed --phase-id foundation \
  --agent-id main-agent --role orchestrator --kind main \
  --summary "Foundation phase complete: schema, cart API and auth all verified." && \
scripts/report-event.sh --type phase.started --phase-id storefront \
  --agent-id main-agent --role orchestrator --kind main \
  --summary "Storefront phase started."
```
