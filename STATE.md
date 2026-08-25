# State of the program — 2026-08-25

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
| *slack-answer* | `slack-answer` | **service identity, not an agent** | read-only record clone; holds the LLM key, never the bridge |
| *deploy-svc* | `deploy-svc` | **service identity, not an agent** | Eric's bounded deploy runs as this; allowlist + approval-token gated |
| **Todd** *(runtime)* | `todd` | **the operator runtime** — WR-011 | no sudo; escalates every prod-touching step. **Cannot execute (see THE BLOCKER)** |

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
| WR-001 | `done` | — | HA config mirror live and pushed. QA-verified, all 10 criteria |
| WR-005 | `done` | — | Slack bridge transport. QA-verified |
| WR-004 | `accepted` | — | Proxmox POC. **Closed as-is by Steve — NOT verified.** Never cite as a QA pass |
| WR-010 | `cancelled` | — | Recorder boot race. Reviewed and deliberately not done |
| WR-002 | `hold` | — | LVM thin-pool guard |
| WR-003 | `hold` | — | ha-triage retarget |
| WR-007 | `hold` | — | record↔code link; misfiled migraine spec in ha-ops |
| WR-006 | `blocked` | Steve | intake + status COMPLETE. Question half: Q1 passed, **no leg runnable unattended** |
| WR-009 | `blocked` | Steve | ADR-0009 fix merged, syntax-clean. **Fix-stage 2 un-runnable.** Cutover held |
| WR-011 | `blocked` | Steve | Todd runtime provisioned and working. **Stage 1 NOT RUN a 4th time** |
| WR-012 | `blocked` | Steve | Eric's deploy grant **provisioned and gates verified live**. Stage 2 un-runnable |
| WR-013 | `design-ready` | Randal | **Conversational Todd in Slack** — Steve's current priority |

## Open decisions for Steve

1. **None outstanding.** Step 9 was ruled 2026-08-21 (*"eric can deploy to prod"*), the LLM egress
   accepted 2026-08-20, WR-013's scope settled 2026-08-25. The four `blocked/steve` items above are
   **not decisions** — they are the execution wall below, mis-routed to Steve because `blocked`
   means "needs Steve" and no other state fits "no agent can run this".

## THE BLOCKER — no dispatched agent can execute anything

**This is the one thing to fix.** Every `blocked/steve` item above reduces to it.

A dispatched `claude -p` session cannot run commands. Verified 2026-08-25 by asking a dispatched
Todd to run `bash -n`:

```
The command was not approved, so I could not run it.
BLOCKED
```

Eric hit it, Randal hit it, and **Todd — the operator runtime built to be the answer — hits it too.**
Eric's framing is exact: *"execution-capability block, not the request."*

**The operator's own misdiagnosis, recorded because it cost a day.** Todd's `bash -n` was tested via
`sudo -u todd bash -lc …` and reported as working. That is **not the path a dispatch uses**. Running
as a user and running inside that user's dispatched session are different things, and only the
second one matters. The same lesson as the ten in the closing section, committed while writing about
them.

**Consequence:** the pipeline produces specs, ADRs, code and inspection verdicts, but **nothing can
be executed, so nothing reaches `done`** without Steve or the interactive operator session running
it by hand. It also undermines WR-013 directly — a conversational Todd who cannot run anything is a
router with extra steps.

## What is genuinely not built

- **Agent execution capability** — the blocker above.
- **Conversational Todd** — WR-013, `design-ready`, Steve's stated priority: *"until we get the
  Slack pipeline working properly, I'm not using it for anything."*
- **Andrea (UAT)** — still unprovisioned. The human eye has now caught **four** defects every
  mechanical check passed: `.cache/brands` (WR-001), the malformed-id answer, the incomplete status
  list, and the backticked-command failure.
- **Question-half verification** — Q1 passed live; Q2/Q3 never ran.

## Credential model — an unattended Todd does not survive a weekend

All seven agent tokens **expired together** over a three-day quiet period (2026-08-22 → 25). Tokens
last ~8 hours and refresh **on use**; every item was correctly `blocked/steve`, so nothing
dispatched, so nothing refreshed. Recovery took seven interactive logins.

The `doctor.sh` expiry check (added 2026-08-21 after Randal's token died the same way) made it
**loud instead of silent** — it previously reported "authenticated" because it only checked that the
file existed. This is carried as a WR-013 dependency: a Todd Steve talks to weekly does not survive
between conversations.

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


## 2026-08-21 → 25 — what changed

**Shipped:** Todd's runtime provisioned (brief, user, clones, boundaries verified — cannot read ops
keys, no sudo, secret gate). Eric's bounded prod-deploy grant live, with **all three gates verified
by running them**: off-allowlist refused, substrate refused, no-approval-token refused. ADR-0009
fixed the dispatch-record trap with a bounded suppression window (`RECORD_STALE=900`) — better than
the operator's three candidate sketches, because it **self-heals** instead of requiring detection to
be correct. ADR-0007's answering path deployed; `answerlib` now discovers items by front-matter `id:`
rather than filename.

**Three latent bugs found while provisioning Todd, all one shape — a hardcoded list beside an unread
roster:** `agent_list` greps `[a-z]+` while `AGENTS.md` capitalises, so it matched **zero rows since
the file was written** and the fallback was silently the real list — Todd would have been dispatched
but **never audited**. `publish-substrate.sh` carried a second hardcoded list that excluded him. And
`doctor` labelled the operator-tree checks `todd`, which meant two different things once a real Todd
existed.

**The intent classifier is being replaced, not repaired.** Measured 2026-08-25: `give me a status`,
`tell me about WR-009`, `I need a dashboard`, `reject WR-011-3-abc` and a bare `no` all do nothing;
`what are you working on?` goes to an LLM instead of the record. WR-013 supersedes that work — a
four-verb taxonomy is the wrong shape for a conversation.

**Known-wrong `doctor` assertions, deliberately not loosened** (they guard a privilege grant, so
Randal fixes them): the `eric sudo grant is NOT exactly the one deploy line` false positive (Eric
legitimately holds `notify` like every agent), and the allowlist check reading
`/usr/local/lib/deploy/` when `deploy` reads the substrate git record.
