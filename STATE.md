# State of the program — 2026-08-21

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
| WR-001 | `done` | — | HA config mirror live and pushed. **QA verified, all 10 criteria** |
| WR-005 | `done` | — | Slack bridge transport. **QA verified** |
| WR-004 | `accepted` | — | Proxmox POC. **Closed as-is by Steve — NOT verified.** Never cite as a QA pass |
| WR-002 | `hold` | — | LVM thin-pool guard |
| WR-003 | `hold` | — | ha-triage retarget |
| WR-007 | `hold` | — | record↔code link; misfiled migraine spec in ha-ops |
| WR-010 | `hold` | — | **HA recorder dies silently when its DB host boots second.** Live hazard, `needs_adr` |
| WR-006 | `needs-exec` | Todd | intake COMPLETE. Status half: answerlib fixed (`e5fce2c`), **re-run pre-declared**. Questions live but unverified |
| WR-009 | `needs-exec` | Todd | watcher live **in shadow**; B6 shadow parity next. Cron still dispatches |
| WR-011 | `design-ready` | Randal | **running now** — Todd runtime + Slack Q&A. ADR-0008 |

## Open decisions for Steve

1. **PROCESS.md step 9** — "Eric deploys to prod". Flagged six times, unanswered.
   Recommendation: Eric certifies, ops deploys.
2. **WR-010** — activate it, or leave held. It is the only open item describing a live hazard that
   will silently recur on the next power event.
3. **Prod SSH under the harness** — the classifier blocks the operator from privileged steps
   (`usermod`, sudoers, permission config). Every one this week was handed to Steve. **A headless
   Todd (WR-011) has nobody to hand them to.**

## What is genuinely not built

- **Question answering is deployed but unverified.** The key is installed, the path works end to
  end, Q1–Q3 never ran.
- **Andrea (UAT) is still not provisioned** — and the human eye has now caught three defects every
  mechanical check passed: `.cache/brands` (WR-001), the malformed-id answer, and the incomplete
  status list.
- **Todd has no runtime.** WR-011.

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


## 2026-08-19 → 21 — what changed, and the expensive lesson

**Shipped:** ADR-0005/0006/0007/0008. Intake creates real pushed `WR-xxx` items from Slack. Status
answering live. Question answering live behind an LLM key (`/etc/maegley/llm.env`, root:slack-answer
`0640`; the bridge is verified unable to read it). Event-driven watcher running **in shadow** beside
cron. `mirror-record.sh` keeps `/srv/git/program.git` current for the answer path.

**`doctor.sh` gained three checks, each after something got through it:**
`deployed-artifacts.tsv` (running bytes == committed bytes, 13 components) · record-mirror freshness
(a stale mirror yields confidently wrong status answers) · **token validity, not just presence** —
Randal's token expired while doctor reported "authenticated".

**The 2026-08-20 outage, recorded because it is the pattern:** Todd shipped an `--add-dir` fix with
the flag *after* `-p`, where `claude` expects the prompt. Every dispatch died instantly for ten
hours. The agent exits in under a second, the marker is cleaned up normally, the dispatch record
marks the transition done, and **nothing anywhere reports an error**. It then cascaded: no dispatch
meant no token refresh, so Randal's credential expired; and the dispatch record suppressed all
retries, so it could not self-correct.

Fixed three ways — flag order; **a failed agent run now clears its dispatch record** so transient
failures are retryable; and doctor checks token expiry.

**The lesson, stated plainly:** the fix was verified by checking that the argument list was built
correctly, not that the resulting command ran. That is the same class this file has catalogued from
the start, committed by the operator inside a fix for another instance of it. **Verify the thing
that runs, not the thing you changed.**
