# State of the program — 2026-08-25 (updated: THE BLOCKER resolved)

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
| WR-006 | `needs-exec` | Todd | Routed 2026-08-25. Offline half runnable; six probes still need **Steve's Slack ID** (ADR-0002) and the redeploy is prod-touching — Todd escalates those |
| WR-009 | `needs-exec` | Todd | Routed 2026-08-25. S1/S2 runnable; S0 liveness `stat`s `/home/steve/...` which agents cannot read **by design** — NOT RUN, not worked around. Cutover held at shadow |
| WR-011 | `needs-exec` | Todd | Routed 2026-08-25. Steps 2+3 RUN and PASS via dispatch (operator spot-check); Step 1's suite at `1321ce2` still unrun — that is the substance |
| WR-012 | `blocked` | Steve | **Deliberately not routed.** Stage 2 verifies a **sudo grant**; a no-sudo agent must not run it. Part A is operator-runnable now and settles criteria 2/3/4/5; Part B needs Steve's yes. **Request defect:** §A2/A4/A5/A6 are marked "Todd, unattended" but contain `sudo` |
| WR-013 | `blocked` | Steve | **Conversational Todd in Slack** — Steve's priority. Row previously read `design-ready`/Randal; the item says `blocked`/`steve`. Seam is BUILT. Its offline unit tests were walled by the same allowlist and are **now runnable**; remaining gates are real — WR-011 approve path enabled, WR-009 §6.11 live, and Steve's yes on the operator deploy |

## Open decisions for Steve

1. **None outstanding.** Step 9 was ruled 2026-08-21 (*"eric can deploy to prod"*), the LLM egress
   accepted 2026-08-20, WR-013's scope settled 2026-08-25, the Bash grant 2026-08-25.
2. **Pending action, not a decision:** WR-006/009/011 are still sitting at `blocked/steve` even
   though the reason is gone. They need re-routing to their real states — WR-011 to
   `needs-exec/todd` per Eric's run-request-4. Flipping them fires live dispatches, so it is held
   for Steve's go.
3. **`blocked` is still overloaded.** It means "needs Steve", and it absorbed "no agent can run
   this" for four days without anyone noticing the difference. Worth a distinct state.

## THE BLOCKER — RESOLVED 2026-08-25. It was a two-entry allowlist, not a wall.

**The diagnosis this file carried was wrong, and the correction made the fix small.**

"No dispatched agent can execute anything" was inferred from `bash -n` being refused. Measured
2026-08-25 in a dispatch-shaped session as Todd, the result is not what was recorded:

```
echo hello-from-todd                 RAN     rc=0
bash -n .../lib-dispatch.sh          DENIED
```

A dispatched `claude -p` session executes commands perfectly well. What it could not do was execute
anything outside the **two** Bash patterns in the agent's `settings.json` — `Bash(git *)` and
`Bash(~/bin/prod *)` — plus the CLI's own auto-approved safe set. Eric could not syntax-check,
Randal could not run a suite, and Todd hit the same two entries. **Four items sat `blocked/steve` on
a missing line in a config file.**

**This was already in the docs.** `AGENT-RUNTIME.md` gap 1 — *"a credential the agent is not
permitted to invoke is not a credential"* — written about `ssh`, true verbatim of `bash`. Fourth
instance of the class. And the doctrine that resolves it sits two paragraphs below it in the same
file: *"client-side permissions are ergonomics; credentials are security. Do not confuse the two."*

**The fix** (Steve's ruling 2026-08-25): general local `Bash` in the allow list for all seven agents
from the roster, `Bash(sudo *)` deny unchanged. Narrow verb patterns were rejected — they break on
flag drift (gap 2), and QA run requests legitimately need `bash -c '<multi-line>'`, a general escape
hatch whatever pattern wraps it.

**Verified through the dispatch path, not a `sudo -u` shell** — the distinction this file paid a day
to learn:

```
bash -n .../lib-dispatch.sh          RAN     rc=0
python3 -c "print(1+1)"              RAN     rc=0  -> 2
sudo -n true                         DENIED  by the permission layer (deny still beats allow)
```

Out of band: home 0750, agents cannot read ops keys, prod reachable only via the forced-command
wrapper, and **`/opt/agent-os.git` is steve-owned and not writable by any agent** — so an agent's
local edit to `plugins/` or the constitution reaches no one, and `publish-substrate.sh` holds an
agent that is ahead for human merge. The substrate `Write/Edit` denies are now a second layer over a
filesystem boundary that already holds, which is the intended order.

**WR-011 stage 1 Steps 2 and 3 have now been run by Todd through a real dispatch**, and both pass on
their pre-declared conditions — including Step 3, the one Eric flagged as possibly not runnable in
isolation:

```
needs-exec-todd=[todd]   needs-exec-steve=[]   needs-exec-empty=[]   design-ready-todd=[randal]
```

**One caveat, and it is not this blocker.** WR-012 stage 2 verifies a *sudo grant* — it needs
`sudo -u eric sudo -n -u deploy-svc ...`. A no-sudo agent cannot run that **by design**, and should
not. That item stays with Steve or the interactive operator for correct reasons, not for this one.

**The lesson, again, and it is the same one.** The blocker was diagnosed by observing a refusal and
inferring a capability wall, without reading the config that produces refusals. One `cat` of
`settings.json` would have ended it on day one. *Verify the thing that runs* has a twin: **read the
thing that decides.**

## What is genuinely not built

- ~~**Agent execution capability**~~ — RESOLVED 2026-08-25, see above. Agents run local
  bash; only genuinely privileged steps (WR-012 stage 2's sudo checks) still need Steve.
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
