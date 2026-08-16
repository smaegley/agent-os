# agent-os

The shared substrate for the Maegley lab agent organization: identities, standards, and gates
that every project inherits.

This repo is small and changes rarely. Project state lives in the sibling `program` repo.

## Install

```bash
claude plugin marketplace add smaegley/agent-os
claude plugin install maegley-core@maegley-lab
```

Install the git-level secret gate in any repo agents commit to:

```bash
plugins/maegley-core/hooks/install-git-hooks.sh /path/to/repo
```

## What's here

| Path | What |
|---|---|
| `CLAUDE.md` | The constitution — loaded automatically wherever the plugin is installed |
| `AGENTS.md` | Registry: who exists, what model, what they may touch |
| `ROLLOUT.md` | The rollout plan and its current status |
| `plugins/maegley-core/agents/` | John, Theresa, Eric, Andrea, Ken |
| `plugins/maegley-core/skills/` | `spec-template`, `definition-of-done` |
| `plugins/maegley-core/hooks/` | `secret-scan.sh` and its installer |

## Enforcement mode

`secret-scan.sh` reads `MAEGLEY_SECRET_SCAN_MODE`: `log`, `warn` (default), or `block`.
It ships in `warn` deliberately — see the staged enforcement table in `ROLLOUT.md`. A gate
that blocks seven projects on day one gets debugged in seven places at once.

## The two rules that matter most

1. **Git is the record; chat is the doorbell.** Slack carries pointers to artifacts, never
   artifacts.
2. **Identity is enforced by credentials, not by prompt.** The `tools:` field in an agent
   definition is documentation. Real isolation is per-role SSH keys and forced commands.
