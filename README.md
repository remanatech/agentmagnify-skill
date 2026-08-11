# agentmagnify-skill

The AgentMagnify reporting skill, and the Claude Code plugin marketplace that
distributes it.

This repository is generated. It is staged out of the AgentMagnify monorepo,
where the skill is developed and tested next to the API it talks to — so that
the offline fallback schema, the event vocabulary and the server that validates
them are compared by a test suite rather than by memory. Send changes there;
anything edited here is overwritten on the next publish.

## Install

Either mechanism installs the same files. Pick whichever matches how you work.

**npm — any agent environment.**

```bash
npx agentmagnify install
```

It detects which agent environments are on the machine, writes the skill where
each of them reads from, runs the skill's own self-test in the installed copy,
and prints what it did and where. Re-run it to update:

```bash
npx agentmagnify@latest install
```

**Claude Code plugin — native install, versioning and updates.**

```
/plugin marketplace add remanatech/agentmagnify-skill
/plugin install agentmagnify@agentmagnify
```

and later:

```
/plugin update agentmagnify
```

## Then pair the machine, once

```bash
bash ~/.claude/skills/agentmagnify/scripts/pair.sh --api-url https://your-agentmagnify-api
```

It prints an eight-character code and waits. Open the panel, sign in, type the
code, check that the screen names this machine and the workspace you meant, and
approve. No token is displayed for anybody to copy, in either direction.

The other direction exists too, and is the right one for a cloud or otherwise
ephemeral agent session, where nobody is at the machine's browser: in the
panel's Pair screen choose **Issue a pair code**, configure what the agent may
do, and paste the twelve-character code it gives you into the session —

```
/agentmagnify BCDF-GHJK-MNPQ
```

in Claude Code, or `bash scripts/pair.sh --code BCDF-GHJK-MNPQ` anywhere else.
The code is not the token: it is single-use, expires in ten minutes, and the
token it redeems for is written straight to a `0600` file without ever being
shown.

Once paired, agents report as they work — tasks, tests, builds, blockers,
decisions — and upload evidence with `upload-artifact.sh`: screenshots and
reports land in the panel's storage, and a browser test's screenshots render
as a numbered, pass/fail-badged step flow under its run.

## What is in here

```
.claude-plugin/marketplace.json          the marketplace manifest
plugins/agentmagnify/
  .claude-plugin/plugin.json             the plugin manifest
  skills/agentmagnify/                   the skill itself
    SKILL.md                             the operating procedure the agent follows
    README.md                            requirements, behaviour, the supported-environment matrix
    scripts/                             the helper scripts, and self-test.sh
    references/                          event types, reporting rules, offline schema
    agents/project-observer.md           the independent Project Observer
```

`plugins/agentmagnify/skills/agentmagnify/README.md` is the real documentation,
including which environments are supported and which are not.

Requirements: `bash`, `curl`, and `jq` or `python3`. Nothing else.
