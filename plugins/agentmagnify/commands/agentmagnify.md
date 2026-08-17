---
description: Connect this project to AgentMagnify, or claim a pair code issued in the panel
argument-hint: "[pair code]"
---

Connect the current project to AgentMagnify. Everything below runs through
`npx`, which needs nothing installed and no path to guess; never look for a
script under `~/.claude` or anywhere else, and never print a key.

**If the user gave you a code** (twelve characters, like `BCDF-GHJK-MNPQ`) —
somebody issued it in the panel for exactly this session:

```bash
npx agentmagnify pair --code $ARGUMENTS
npx agentmagnify connect
```

**If they gave you nothing**, find out where this machine stands first:

```bash
npx agentmagnify status
```

Then do the one thing it says is missing:

- **Not paired.** Run `npx agentmagnify pair`. It prints an eight-character
  code and waits up to ten minutes. Show the user that code and the URL
  verbatim, tell them to approve it in the panel, and let the command finish on
  its own — it collects the key itself, over the connection it already has.
  Nothing is ever displayed for anyone to copy.
- **Paired, but this directory is not connected.** Run
  `npx agentmagnify connect`. It writes nothing to the repository.
- **Both done.** Say so, and say what the project reports as. There is nothing
  to run.

If something reports but nothing appears in the panel, `npx agentmagnify
doctor` checks every step in order and names the one that is broken. Report
what it printed rather than guessing at a fix.

Two answers you must pass on rather than work around:

- **A plan ceiling** (`PLAN_LIMIT_REACHED`). The account has no room for
  another project. Show the message; archiving a project or changing plan is
  the user's decision, not yours.
- **A refused key.** Re-pairing is the fix, and it needs the user at the
  panel. Do not invent credentials and do not edit anything under
  `~/.agentmagnify`.
