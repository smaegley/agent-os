# State of the program — 2026-08-18 (end of day)

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
| *Maegley Bridge* | `slack-bridge` | **service identity, not an agent** | writes two queue dirs; no sudo |
| *intake* | `intake` | **service identity, not an agent** | holds the `program` deploy key; create-only |

**Credential rule, applied seven times:** root holds the secret, a wrapper mediates, the agent
never sees it. Slack bot token, Proxmox API token, prod SSH keys, the authorized Slack identity,
the bridge's reply path, and the `program` deploy key all follow it. The bridge can read none of
them.

## Scheduled

`crontab -l` on codex-ops. **cron here runs in UTC and ignores `CRON_TZ`** (a cronie feature) —
so the scripts own their own hours in `America/Denver`, DST-aware:

- `dispatch.sh` every 15 min, acts 07:00–20:00 local, silent outside
- `sweep.sh` every 10 min, acts ~06:30 local
- `board.sh` every 2 min, always

Live board: **http://10.0.1.128:8088/maegley-lab-board.html**

## Running services

- `slack-bridge` — Socket Mode, unprivileged, fully hardened, holds no Slack credential.
  **Cannot `sudo` to anything** — `NoNewPrivileges` plus seven settings that each imply it. Two
  ADRs were written assuming otherwise before this was designed around.
- `slack-bridge-relay.path` — root side of the reply split; posts as **Maegley Bridge** (ADR-0005)
- `slack-bridge-intake-runner.path` — root side of the intake split; drains the intake-inbox and
  runs `intake` via `runuser`, never `sudo` (ADR-0006)
- `maegley-board` — serves the board on :8088
- Proxmox dashboard — VMID 900 `test-pvedash` @ **10.0.1.117:8080** (test env, disposable)

## Work in flight

| Item | State | Owner | Note |
|---|---|---|---|
| WR-001 | `hold` | — | config-sync apply. Parked by Steve behind 005/006 |
| WR-002 | `hold` | — | LVM thin-pool guard. Parked |
| WR-003 | `hold` | — | ha-triage verification. Parked |
| WR-004 | `hold` | — | dashboard POC. Parked, verification deferred not waived |
| WR-005 | `qa-ready` | Eric | reply path PASS; **R6 ran and passed** — awaiting Eric's re-verdict |
| WR-006 | `qa-ready` | Eric | **intake works** — created and pushed a real WR-008 |
| WR-007 | `hold` | — | record↔code link; misfiled migraine spec in ha-ops |
| WR-008 | `new` | Theresa | **first item ever raised from Slack.** Awaiting elicitation |
| WR-009 | `new` | — | event-driven dispatch; replaces 15-min batching |

## Open decisions for Steve

1. **PROCESS.md step 9** — "Eric deploys to prod". Flagged five times, still unanswered.
   Recommendation: Eric certifies, ops deploys.
2. **WR-005 gate 2** — accept WR-005 as transport-only, or hold it open until the capability
   lands. **The capability landed tonight**, so this is now a live decision rather than
   hypothetical.
3. **Prod SSH under the harness.** PROCESS.md rule 1 says Steve is never handed raw shell
   commands, but the auto-mode classifier blocks the operator from executing the prod half, so
   every `needs-exec` item hands Steve a paste buffer. This is a harness-config decision, not a
   credential one. Matters again the moment the ha-ops hold lifts — WR-001's T-6 is the first real
   `--apply` against the config mirror.

## What is genuinely not built

- **Status and question answering** over Slack (WR-006 criteria 3–9). Intake works; these are a
  separate increment and were never in the dispatched scope.
- **A check that the dispatcher itself is healthy.** It failed silently for hours twice. Still
  unbuilt, and **WR-009 must not ship without it** — an event-driven dispatcher that dies looks
  exactly like an idle queue.
- **A spec/ADR ↔ code link.** `deployed-artifacts.tsv` asserts running bytes == committed bytes for
  binaries. Nothing asserts which repo a `projects/<n>/` record governs — that is WR-007.

## What changed on 2026-08-18 (the day the bridge went end to end)

**The state machine gained three things, each because a real item could not move and nothing
errored:**

- `hold` — Steve parks an item. Distinct from `needs-exec`, which is a request *of* Steve. Before
  this, four parked items rendered as 127 outstanding commands he owed.
- `needs_adr:` front-matter flag — `infra` was doing double duty as "needs an architect". WR-006 is
  `infra:false` but introduced a new authority; the machine called Theresa's correct `owner: john`
  a contradiction and refused to dispatch. It sat untouched for hours.
- `adr-needed` state — built, running, and its design record is wrong. Eric had only `blocked` to
  reach for, and `blocked` means "needs Steve" and **ignores owner**, so his `owner: john` was
  inert. Used twice; both times John was dispatched and fixed the ADR.

**`doctor.sh` gained the check that would have caught the day's worst finding:**

- A **deployed-artifact inventory** (`provisioning/deployed-artifacts.tsv`) comparing running bytes
  to committed bytes for 13 host components. A dirty-tree check structurally cannot catch code that
  lives outside every working tree.
- It now checks **the operator too**. Every prior loop iterated agent identities; Todd was never
  examined — and it was the operator who left production uncommitted.
- It caught, on separate runs: four unrecorded relay components, a `NoNewPrivileges` divergence
  nobody found by hand, a stale substrate mirror, and host-ahead-of-repo drift.

**Provisioning gained project code repos.** `provision-agent-runtime.sh` had only ever cloned
`agent-os` and `program`. Eric was dispatched to verify `slack-bridge` and had no clone of it;
Randal and Ken had one only via `proxdash` group membership. Now every local bare repo is cloned,
with write access still governed by group membership — so QA gets a working read-only clone.

**The Slack bridge became real.** Replies post as **Maegley Bridge** through the ADR-0005
outbox→relay split; intake creates a real pushed `WR-xxx` through the ADR-0006 inbox→runner split.
Neither path uses `sudo` — the service cannot elevate at all, which was disproved twice the hard
way before it was designed around. **`WR-008` is the first work item ever created by Steve talking
to Slack.**

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
