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

`crontab -l` on codex-ops. **cron here runs in UTC and ignores `CRON_TZ`** (a cronie feature) — so the
scripts own their own hours in `America/Denver`, DST-aware:

- `dispatch.sh` every 15 min, `MAX_DISPATCH=2`, acts 07:00–20:00 local
- `sweep.sh` every 10 min, acts ~06:30 local — **note it runs `claude -p --model haiku` for its digest**
- `mirror-record.sh` every 2 min — keeps `/srv/git/program.git` current **from GitHub** (it is a
  read-only mirror; never push to it — see WR-012 Defect 2)
- `board.sh` every 2 min, always

**Changed 2026-08-26:** `maegley-dispatch-reconcile.timer` **disabled**, and
`maegley-token-keepalive.timer` **stopped and set to daily** (Steve's cost ruling). Real dispatchers
are cron + the watcher — deliberately two, not three; three is what retried into an exhausted credit
block and spent 5% of the next one 60s after reset (WR-014).

Live board: **http://10.0.1.128:8088/maegley-lab-board.html**

## Running services

- `slack-bridge` — Socket Mode, unprivileged, fully hardened, holds no Slack credential.
  **Cannot `sudo` to anything.** Running slack-bridge `00647d5`.
- `maegley-dispatch-watch` — **CUT OVER 2026-08-26 02:08:56: `DISPATCH_SHADOW=0`, dispatching for
  real.** §6.11 health gate proven firing on both edges with Slack alerts.
- `slack-bridge-relay.path` — root side of the reply split; posts as **Maegley Bridge** (ADR-0005).
  **Deletes each reply after posting; there is no `sent/` archive** — this is why reply evidence needs
  a human paste.
- `slack-bridge-intake-runner.path` — intake split (ADR-0006)
- `slack-bridge-status-runner.path` / `-question-runner.path` — answering (ADR-0007)
- `slack-bridge-conversation-runner.path` — **conversational Todd, LIVE since 2026-08-25 19:25.**
  Every non-approval Slack message from Steve is a full `claude -p --resume` turn. **While this is
  enabled the question path is unreachable, so WR-006 criteria 6/7 are untestable** without
  temporarily unsetting `CONVERSE_CMD`.
- `slack-bridge-approve-runner.path` — **ADR-0008 approve path, ENABLED 2026-08-26.** `slack-approve`
  identity, own GitHub deploy key (write-verified), remote is **GitHub not the local mirror**.
  **No approval has been released through it yet.**
- `maegley-board` — serves the board on :8088
- Proxmox dashboard — VMID 900 `test-pvedash` @ **10.0.1.117:8080**

## Work in flight

*As of 2026-08-26 02:30. The pipeline ran unattended through the night of 25→26 for the first time —
Todd, Eric, Theresa, John and Randal all dispatched, ran, committed and routed without a human.*

| Item | State | Owner | Note |
|---|---|---|---|
| WR-001 | `done` | — | HA config mirror. QA-verified, all 10 criteria |
| WR-005 | `done` | — | Slack bridge transport. QA-verified |
| WR-006 | `blocked` | Steve | **VERIFIED-COMPLETE — awaiting Steve's accept/close.** Eric passed all 14 criteria from committed evidence. Accepting delivered work is the raiser's call |
| WR-004 | `accepted` | — | Proxmox POC. **Closed as-is by Steve — NOT verified.** Never cite as a QA pass |
| WR-010 | `cancelled` | — | Recorder boot race. Reviewed and deliberately not done |
| WR-002 | `hold` | — | LVM thin-pool guard |
| WR-003 | `hold` | — | ha-triage retarget |
| WR-007 | `hold` | — | record↔code link; misfiled migraine spec in ha-ops |
| WR-009 | `qa-ready` | Eric | Fix-stage 2 PASS (all 4 scenarios, run as steve). **Cut over 02:08:56 — watcher dispatching for real.** §6.11 proven firing, both Slack edges. Stage-3 criteria still owed to QA |
| WR-011 | `qa-ready` | Eric | Stage 1 green at `00647d5`, every named test verified individually. Approve path now enabled. Eric writes stage 2 |
| WR-012 | `qa-ready` | Eric | **6/6 criteria evidenced**, two defects recorded (units-restarted misreport; deploy-event push cannot succeed) |
| WR-013 | `blocked` | Steve | 2b LIVE, 2c COMPLETE. **Both ADR-0010 ship gates green.** Waiting on criterion-8 Probe B (10:05 UTC) and Eric's stage 2 |
| WR-014 | `design-ready` | Randal | Credit-aware dispatch — raised, spec'd and ADR'd overnight by Theresa and John |

## Open decisions for Steve

1. **Accept and close WR-006.** Verified-complete by Eric against bars fixed before the evidence
   existed. The only thing waiting on a human right now.
2. **Criterion 8 / keep-alive cadence** — after Probe B lands (10:05 UTC). Probe A already showed no
   renewal on a healthy token; Probe B tests an expired one. Note daily cadence cannot preserve an ~8h
   token, so a "yes" from Probe B reopens the cadence question.
3. **Not decisions, carried openly:** the WR-009 cutover shipped with **no stage-3 QA request** — the
   operator raised it, Steve ruled to proceed, and §6.2/6.6/6.7/6.8/6.9/6.10/6.12 remain owed to Eric
   against the running system.

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

## FOLLOW-UP — why Steve is the integration layer, and what would change it

**Raised 2026-08-26 from Steve's own question, after a session in which the pipeline finally worked
end to end and he was still hands-on throughout.** Recorded here rather than as a work request because
nothing new is being started; this is the analysis to design against when the current work closes.

**What one session actually cost him:** ran privileged commands by hand **4 times**, pasted output back
**6 times**, posted Slack messages **twice**, re-authed **6 agents** through browser flows, registered
a deploy key **twice** (2FA timed out), answered **3** design questions — and **noticed the credit
burn himself**, because the system spent 5% of a fresh block and reported nothing. Only the 3 design
questions were the kind he wants to be asked.

**1. Every boundary was designed to exclude agents; nobody designed the complement.** The credential
rule — root holds the secret, a wrapper mediates, the agent never sees it — is applied seven times and
is genuinely good. But it exists only as a **wall**. There is no sanctioned path for privileged work to
*happen* without Steve's hands, so a boundary does not protect a workflow, it terminates one. Todd is
the sharpest case: described as "the unattended operator runtime", his defining behaviour is *escalate
everything prod-touching and stop*. That is a well-documented tripwire, not an operator. On 2026-08-26
he escalated a redeploy that had already happened, because he cannot read the bridge config that would
have told him.

**2. There is no such thing as a standing approval.** Steve ruled *"eric can deploy to prod"* on
2026-08-21. Five days later deploying still required him to approve one SHA with one single-use token.
The policy decision bought nothing — it moved where the per-instance yes/no is asked. Nothing in the
system expresses *"this class of action, on these targets, is pre-authorised"*, so approvals never
batch and their volume grows with throughput instead of shrinking as trust accumulates.

**3. The QA discipline is excellent and the tooling under it cannot support it.** Pre-declared bars,
verbatim evidence, no substituting inspection for execution — that discipline is why 2026-08-25/26
surfaced six real defects. But it runs on infrastructure where agents could not execute at all until
that morning, evidence cannot be captured automatically (the relay deletes every reply it sends —
that is *why* criterion 6 needed a human paste), and the record spans three git remotes with a
read-only mirror in the middle. Every verification degrades into a human relay: run, copy, paste.

**4. Nothing is trusted, because too much reports success it has not verified.** The keep-alive logged
`refreshed 'andrea'` while renewing nothing. The deploy reported 11 units restarted when zero were.
`doctor` said *"quiet-period expiry mitigated"* about a mechanism measured failing. `git push
--dry-run` said *"Everything up-to-date"* about a key with no access. When self-reports cannot be
trusted, everything is re-verified by hand — and the hand is Steve's.

**Also the operator's own share, recorded because it is fixable and was the most repetitive part:** the
interactive session's classifier refuses nested `sudo -u X sudo …`, `useradd` and `ssh-keygen`. Steve
was handed those commands **three separate times** instead of the operator asking once for a rule
covering that shape. The operator also asked where it should have decided (the WR-009 cutover was put
as a three-option question after Steve had already said "cutover WR-009") and held 2b/2c after they
were approved, costing a round trip.

**What would change it, roughly in value order:**
- An **operator-privilege broker** — one wrapper covering the command shapes that keep bouncing off the
  sandbox, so privileged *verification* stops routing through Steve's keyboard.
- **Per-agent API keys instead of OAuth.** `AGENT-RUNTIME.md` names this tradeoff and rejects it on
  billing; it costs six browser logins per outage and is why a quiet weekend kills the org.
- **An append-only `sent/` archive on the relay.** One write before the delete and criterion-6-style
  evidence stops needing a human clipboard, permanently.
- **Standing approvals by class**, so Steve's rulings compound instead of resetting.
- **A properly scoped `gh` token.** The current one 404s on `smaegley/program` — that is why deploy-key
  registration is manual and why it took two attempts.

**The through-line:** this program has built excellent *judgment* — the specs, ADRs and pre-declared
bars are genuinely good — and almost no *reach*. Steve is currently the integration layer between the
two.

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
