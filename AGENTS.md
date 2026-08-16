# Agent Registry

Who exists, what they run on, and what they may touch. This file is the authority on identity.

Steve is the CTO and the only human. Every agent below reports to him.

---

## Roster

| Name | Role | Model | Host | Prod access |
|---|---|---|---|---|
| **Todd** | Ops | Opus | LXC 301 (`codex-ops`, 10.0.1.128) | **Full — sole holder of prod keys** |
| **John** | Architect | Opus | — | Read-only, forced command |
| **Theresa** | Business Analyst | Sonnet | — | **None** |
| **Randal** | Developer | Opus | VM 201 (`ai-sandbox-ubuntu`) | **None** — `devread` forced command only |
| **Eric** | QA | Opus | — | Read-only, **key distinct from Randal's** |
| **Andrea** | UAT | Sonnet | — | UI level only |
| **Ken** | Hardware / Firmware | Opus | — | Device flash access only |
| — | Sweep (scheduled job) | Haiku | LXC 301 | None |

## Why Eric's key differs from Randal's

Eric verifies Randal's work. Verification that runs through the claimant's own access path is
not verification. This is a direct response to a real incident in which the dev agent made
confident claims about production it had no ability to check.

## Model tiers

Opus for work where being wrong is expensive: architecture, implementation, adjudicating
whether something is actually done, firmware that touches physical devices. Sonnet for
elicitation and UI validation. Haiku for collation.

Set the tier in the agent's frontmatter. Do not raise it to make a task feel more important.

## Credential boundaries

**Written here, enforced on the hosts.** The `tools:` field in an agent definition constrains
what that subagent can call — it is *not* a security boundary. Real isolation comes from
per-role SSH keys and forced commands, provisioned in Phase C of the rollout.

Until Phase C is complete, treat every boundary in this file as a convention that agents are
expected to honor, not a wall that stops them.

| Key | Holder | Purpose |
|---|---|---|
| `~/.ssh/proxmox_lxc` | Todd only | root to Proxmox nodes and all LXCs. **Never** used for anything else. |
| `~/.ssh/github_todd` | Todd | GitHub. Deliberately separate from the above — revoking source-control access must never mean re-keying every host. |
| `devread` forced command | Randal | Read-only prod inspection from VM 201 |
| *(Phase C)* | Eric | Read-only prod inspection, distinct command set |

## Adding an agent

1. Add the row above.
2. Write `plugins/maegley-core/agents/<name>.md` with `model:` and `tools:`.
3. Provision the credential — a role without its own credential is a label, not an identity.
4. Record why the role exists in an ADR. Roles that only reformat other agents' output are
   negative value; the bar is a distinct tool scope or a distinct model need.
