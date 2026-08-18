# State of the program — 2026-08-18

Current-state handoff. `ROLLOUT.md` describes the original Phase A–D plan and is now historical;
**this file is what is true.** Written so a fresh session can pick up from the repos rather than
from a conversation.

## What exists and runs

| Thing | Where | State |
|---|---|---|
| **agent-os** | `github.com/smaegley/agent-os` (private) | substrate: constitution, roster, skills, hooks, provisioning |
| **program** | `github.com/smaegley/program` (private) | the record: work items, specs, ADRs, QA evidence |
| **ha-ops** | `github.com/smaegley/ha-ops` (private) | ops scripts and the HA config mirror's tooling |
| **proxmox-dashboard** | `/srv/git/proxmox-dashboard.git` (local bare) | greenfield app, disposable by design |
| **slack-bridge** | `/srv/git/slack-bridge.git` (local bare) | inbound Slack command bridge |

Local bare repos are deliberate: those projects are disposable, so no deploy keys to manage.
Promote to GitHub if they graduate.

## The team

Seven identities, each a Unix user on codex-ops (LXC 301) with its own credentials and boundary.

| Name | User | Role | Prod reach |
|---|---|---|---|
| Todd | `steve`/`root` | Ops + coordinator | full — sole holder of `proxmox_lxc` |
| Theresa | `theresa` | BA | none, by design |
| John | `john` | Architect | read-only |
| Ken | `ken` | Hardware / environments | sandbox LXCs 900–949 via `provision-env`; no Proxmox key |
| Randal | `randal` | Developer | read-only via `dev-readonly.sh` |
| Eric | `eric` | QA | read-only via `qa-verify.sh` — a **different** key from Randal's |
| Andrea | `andrea` | UAT | none, by design |
| *Evan* | `slack-bridge` | **service identity, not an agent** | `notify` only |

**Credential rule, applied five times:** root holds the secret, a wrapper mediates, the agent
never sees it. Slack bot token, Proxmox API token, prod SSH keys, the authorized Slack identity,
and the bridge's reply path all follow it.

## Scheduled

`crontab -l` on codex-ops. **cron here runs in UTC and ignores `CRON_TZ`** (a cronie feature) —
so the scripts own their own hours in `America/Denver`, DST-aware:

- `dispatch.sh` every 15 min, acts 07:00–20:00 local, silent outside
- `sweep.sh` every 10 min, acts ~06:30 local
- `board.sh` every 2 min, always

Live board: **http://10.0.1.128:8088/maegley-lab-board.html**

## Running services

- `slack-bridge` — Socket Mode, unprivileged, fully hardened, holds no Slack credential
- `slack-bridge-relay.path` — root side of the privilege split; posts replies as Evan
- `maegley-board` — serves the board on :8088
- Proxmox dashboard — VMID 900 `test-pvedash` @ **10.0.1.117:8080** (test env, disposable)

## Work in flight

| Item | State | Owner | Note |
|---|---|---|---|
| WR-001 | `needs-exec` | Todd | config-sync apply; Randal's rsync fix in, retry not run |
| WR-002 | `needs-exec` | Todd | LVM thin-pool guard; Steve approved applying it |
| WR-003 | `needs-exec` | Todd | ha-triage verification; Steve approved finishing it |
| WR-004 | with Eric | Eric | dashboard; backup limit accepted by Steve as-is |
| WR-005 | open: R6, R8 | Eric | bridge live and working; R6 unproven |
| WR-006 | `new` | — | status answers, question answers, real pipeline intake |

## Open decisions for Steve

1. **PROCESS.md step 9** — "Eric deploys to prod". Flagged four times, still unanswered. Giving
   QA deploy keys undercuts the independence that makes his verdicts worth having. Recommendation:
   Eric certifies, ops deploys.
2. **WR-005 R6** — needs a second Slack account. "Only Steve can command it" is currently proven
   positively and against content attacks, never negatively.

## What is genuinely not built

- **Inbound intake that creates work items.** The bridge records to a spool and replies; it does
  not create `WR-xxx` items. That is WR-006.
- **Status and question answering.** Same.
- A check that the dispatcher itself is healthy. It failed silently for hours twice (a syntax
  error, then a timezone window) and both times the only symptom was nothing happening.

## The recurring bug, for whoever comes next

Roughly ten times in three days, the failure was not that a mechanism was wrong — it was that the
mechanism was **not where the work happened**, and nothing errored:

a key installed but not permitted · a permission pattern that missed the command shape · a secret
gate absent from agent clones · QA verbs aimed at a dead port · a substrate no agent could pull ·
`git -C` unmatched by `git add *` patterns · tracked logs silently aborting every pull ·
`CRON_TZ` silently ignored · a stale test env passing as current · a reply path tested through a
shell that was not the caller.

Two guards exist: `doctor.sh` asserts the invariants daily, and `lib-agent.sh` removes the
`0750`-false-negative class by construction. Neither would have caught most of the above. **The
habit that does: verify through the path the thing actually uses, against the world it describes
— not through an adjacent path that is easier to run.**
