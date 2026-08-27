# State of the program — 2026-08-27

Current-state handoff. `ROLLOUT.md` describes the original Phase A–D plan and is now historical;
**this file is what is true.** Written so a fresh session can pick up from the repos rather than
from a conversation.

## START HERE — a fresh session in ten lines

1. **The board is entirely human-gated right now.** Every open item is `blocked`/`steve` or
   `needs-exec`/`steve`, which is why nothing ran overnight. Nothing is stuck; it is waiting on Steve.
2. **Agents can execute.** The old "nothing can run" blocker is gone. Dispatch works, the watcher is
   real, the approve path is live, and the conversational surface answers.
3. **Read `## THE RECURRING FAILURE CLASSES` before diagnosing anything.** Four shapes explain nearly
   every defect here, and three of them are still open.
4. **Verify the thing that runs, and read the thing that decides.** Do not trust a component's own
   success message — several lie. `git push --dry-run` lies about write access. A published fix may not
   be *loaded*; an installed file may not be *committed*.
5. **When a builder's `agent-os` commit exists but QA "cannot read it", it is the publish gap.** Merge
   it and run `publish-substrate.sh`. Seven instances so far.
6. **Do not pipe `publish-substrate.sh` to `head`** — SIGPIPE kills it mid-loop and silently leaves the
   alphabetically-later agents stale. That was an operator-manufactured bug.
7. **Token "expired" is usually not a problem** — an expired token renews on use. `doctor`'s advice to
   re-login is wrong.
8. **Ask Steve only for decisions and things only he can do** (Slack posts from his identity, credential
   minting, prod approvals). See `## FOLLOW-UP` for why he is currently over-involved.

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

## Running services — all `active` as of 2026-08-27 13:20

- `slack-bridge` — Socket Mode, unprivileged, holds no Slack credential. Running slack-bridge `00647d5`.
- `maegley-dispatch-watch` — **real since the 2026-08-26 cutover** (`DISPATCH_SHADOW=0`). §6.11 health
  gate proven firing on both Slack edges. **Dispatched agents run inside this unit's cgroup**, so any
  watchdog trip or cgroup-wide signal kills every in-flight agent (`KillMode=process` protects them
  from a normal restart, not from that).
- `slack-bridge-conversation-runner.path` — **conversational Todd, live.** Every non-approval Slack
  message from Steve is a full `claude -p --resume` turn, keyed by a thread→session map.
  **While `CONVERSE_CMD` is set the question path is unreachable**, so WR-006's criteria 6/7 are not
  re-testable without temporarily unsetting it.
- `slack-bridge-approve-runner.path` — **ADR-0008 approve path, enabled 2026-08-26.** `slack-approve`
  identity with its own GitHub deploy key (write-verified). Exercised live: release, negated-refusal,
  non-Steve refusal, and anti-replay all proven.
- `slack-bridge-relay.path` — posts as **Maegley Bridge**. **Deletes each reply after posting; no
  `sent/` archive**, and it discards `notify`'s output — so a successful delivery is unauditable after
  the fact and only a `.failed` file marks a failure.
- `maegley-token-keepalive.timer` — **daily, all seven identities.** Renewal is **expiry-driven, not
  use-driven** (measured). Tokens therefore sit expired between fires — that is expected and harmless,
  because **an expired token renews on use**. `doctor`'s *"dispatches will 401; needs interactive
  re-login"* is **wrong on both halves** and cost six unnecessary logins on 2026-08-25.
- `maegley-board` — :8088. Proxmox dashboard — VMID 900 @ 10.0.1.117:8080.

## Work in flight

*2026-08-27 13:20. **Nothing is dispatchable right now** — every open item is `blocked`/`steve` or
`needs-exec`/`steve`. The board is entirely human-gated, which is why nothing ran overnight.*

| Item | State | Owner | Where it actually stands |
|---|---|---|---|
| WR-007 | `hold` | — | record↔code link; misfiled migraine spec in ha-ops |
| **WR-009** | `blocked` | **Steve** | Stage-3 Part A + B1 + A5′ all PASS as steve. **B2's premise was falsified** — a wedged watcher cannot reach the 120s heartbeat branch because `WatchdogSec=1min` + `Restart=always` repairs it in ~56s. §6.11's value is its unit-state branch. Eric owes a verdict on the banked evidence |
| **WR-011** | `blocked` | **Steve** | Stage 1 green. Scenario A: crit 1/2/4/5/6/7 PASS, crit 3 re-run PASS both halves. **Owed:** criteria 9 + 13 (kill/restart with Steve live) |
| **WR-012** | `blocked` | **Steve** | 5/6. Defect 1 fixed and confirmed (`units: none`). **Defect 2 re-fix `4a8f1ff` published + installed 2026-08-27** — event filename now carries the consumed token and is written *after* the reset. **Needs: a fresh Part-B token + one no-op run**, then Eric rules crit 1 & 6 |
| **WR-013** | `needs-exec` | **Steve** | **Part C COMPLETE, 6 of 6 PASS.** Both ADR-0010 ship gates green. Owed: Eric's per-criterion verdict; crit 8's *multi-day* case still unproven |
| WR-016 | `hold` | — | **agent session continuity.** Held deliberately — raised so the analysis is not lost. The single highest-leverage cost change available |
| **WR-017** | `needs-exec` | **Steve** | Raised by Todd from Slack: restart photo-album. **Deliberately not executed** — prod tree is dirty (4 uncommitted files on `7dd7a72`) |
| **WR-018** | `blocked` | **Steve** | HA dashboard for the ESPHome `speaker-switcher`. Todd raised it, Theresa spec'd it. Ken dependency flagged — device not in the record |
| WR-901 / WR-902 | `accepted` | Steve | Canaries, QA-verified. **Teardown owed** (delete `projects/sandbox/`, truncate `/var/lib/agent-os-canary/canary.log`) |
| WR-015 | `accepted` | Steve | conversational credit-hold gate, all ACs met on the host |

**Archived** (`projects/<p>/archive/`, out of the dispatcher and board read path, still readable by
`approve` and the status/question answer path): WR-004, WR-005, **WR-006**, **WR-014**.

## Open decisions for Steve

1. **WR-012 (c):** mint a fresh Part-B approval and run the one no-op deploy. Everything else is
   provisioned. This is the last gap to 6/6.
2. **WR-011 criteria 9 + 13:** a live session (kill/restart the dispatcher with Steve present).
3. **WR-017:** whether to restart photo-album at all, given its dirty prod tree — or fix the tree first.
4. **WR-018:** Theresa's spec awaits Steve; Ken is needed for the device side.
5. **WR-016:** release from `hold` when the current items close.
6. **Canary teardown** for WR-901/WR-902.

## THE RECURRING FAILURE CLASSES — read this before diagnosing anything

Four shapes account for nearly every defect this program has produced. When something is wrong, check
these first; the odds strongly favour one of them.

### 1. A component reports an act it did not perform

The signature failure. Confirmed instances, all 2026-08-25/26:

- `token-keepalive.sh` logs `refreshed '<agent>'` on exit 0 **whether or not anything renewed** — Probe
  A shows it claiming a refresh that provably did not happen. **Still open.**
- `deploy` reported **11 units restarted** when zero were (`UNITS` populated outside the changed
  branch). *Fixed — `7b3dffa`, confirmed `units: none`.*
- `doctor` reported *"quiet-period expiry mitigated"* about a mechanism then measured failing; and
  reports *"dispatches will 401; needs interactive re-login"*, **wrong on both halves**. **Still open.**
- Todd logged *"Ask escalated to `#ops-command`"* with **zero notify calls made**. *Fixed — brief now
  requires confirming delivery; proven live.*
- `git push --dry-run` reports "Everything up-to-date" against a key with **no write access**. Never
  trust it: prove write with a throwaway ref. Bit the operator twice.
- **The relay discards `notify`'s output**, so a successful delivery leaves no log line at all.
  **Still open** — on the one surface whose purpose is breaking silence.

### 2. Running ≠ committed ≠ loaded

- Prod ran **four commits behind** on `50c3613` with a live security defect while doctor was all-green,
  because `deployed-artifacts.tsv` covered the *installers* and not the `slackbridge/` package.
- The watcher ran **3-day-old code** through the WR-009 cutover, then **pre-WR-014 code** while 44 real
  credit exhaustions produced no hold — the fix was published 31 minutes after the process started.
  *Fixed — `publish-substrate.sh` now restarts it; `doctor` asserts loaded-process freshness.*
- Two published fixes sat **installed nowhere** until B3 caught them.
- **`/opt/photo-project` prod tree is dirty — 4 uncommitted files on `7dd7a72`.** Found by Todd,
  unprompted. **Still open, and it is Steve's infrastructure, not the agent org.**

### 3. The publish gap — SEVEN instances, every one costing a cycle

`WR-012 22a3a39` · `WR-013 f4c4521` · `WR-014 7e9dcc0` · `WR-015 f19f986` · `WR-012 7b3dffa` ·
`WR-011 edc3535` · `WR-012 4a8f1ff`.

**Builders can commit to `agent-os` but cannot publish**; `/opt/agent-os.git` is steve-owned. So every
agent-os build stalls until an operator merges and runs `publish-substrate.sh`, and QA cannot even read
it in the meantime. It bounces `design-ready → qa-ready → blocked → qa-ready` each time. On 2026-08-26
it blocked a **one-line doc fix**, live on the conversational surface, in front of Steve.

### 4. Stale reads — an agent acts on a snapshot the record has moved past

Three on 2026-08-26 alone: Eric re-issued a B2 scenario already run 3 minutes earlier; Todd escalated a
WR-006 redeploy already completed; Eric wrote *"no new execution evidence exists"* minutes before the
run produced it, forcing a merge conflict. **This is WR-016's cold-start problem** — a dispatch reads
at start and the record moves under it.

---

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

- **Agent session continuity** — WR-016, on `hold`. Every dispatch is a cold start: no `--resume`, and
  the prompt says *"Read the item in full"*. `eric` has 115 discarded session transcripts, `todd` 31.
  Eric re-read WR-011 (1,394 lines) five times. **The mechanism already exists** —
  `conversation-runner` maps thread→session and resumes; dispatch just does not use it.
- **Andrea (UAT)** — provisioned and authenticated but never dispatched; nothing routes to her.
- **A `sent/` archive on the relay** — no host-side record of what the bridge said to Steve.
- **`deployed-artifacts.tsv` coverage of the `slackbridge/` package** — still installers only.
- **Anti-starvation in the dispatcher** — priority-ordered with a per-tick cap and **no aging**, so a
  low-priority item behind churning high-priority ones waits indefinitely. WR-901 sat 2h+ until its
  priority was raised by hand. Churn is rewarded with dispatch slots.
- **A fix for the secret-scanner false positives** — it flags *sudoers paths* (`/usr/local/bin/deploy`,
  `notify`) as credentials, 5–9 hits per WR-012 commit. **It becomes blocking in Wave 1**, at which
  point the item documenting the sudo grant becomes unpushable.

## 2026-08-25 → 27 — what changed

**The blocker that defined this program is gone, and the org now runs itself.** *"No dispatched agent
can execute anything"* was never a capability wall — it was a two-entry `Bash` allowlist in each
agent's `settings.json`. Four items sat `blocked/steve` on a missing config line. General local `Bash`
was granted to all seven; `Bash(sudo *)` still denies. Since then Todd, Eric, Theresa, John and Randal
have all dispatched, worked, committed, pushed and routed with no human — including raising **WR-014**
and **WR-015** end-to-end overnight.

**Shipped and verified:** the WR-009 cutover (watcher dispatching for real, as a *swap* — the reconcile
timer was disabled so real dispatchers stay at two, not three); §6.11 proven firing with both Slack
edges; ADR-0008's approve path enabled and exercised live end-to-end (release, negated refusal,
non-Steve refusal, anti-replay); WR-013's conversational surface with **Part C 6/6**; WR-014's
credit-exhaustion hold, **accepted**; WR-015's conversational credit gate, **accepted**; closed items
archived out of the read path.

**Todd was unable to escalate at all, and nobody noticed for four days.** He held **no `notify` sudoers
grant** *and* `notify` had no `todd)` case — it mapped "Todd" to `steve|root` from when Todd was Steve's
operator persona rather than a Unix user. Third instance of *a hardcoded list beside a roster nobody
re-read*. Both fixed and verified by posting.

**Criterion 8 was answered by measurement, and two of the operator's own readings were wrong.** Probe A
(healthy token, 7.9h left) → **no renewal**. Probe B (expired 7 min) → **renewed +8.1h**. Renewal is
**expiry-driven, not use-driven**, so every 2026-08-25 measurement was taken against a healthy token
and could not have shown anything. *"Tokens do not refresh on use"* was wrong, and *"daily cannot
preserve an 8h token so it is not the mechanism"* was wrong — hourly aging self-heals; what killed all
seven over the 08-22→25 weekend was **multi-day silence** killing the refresh credential. Steve's daily
instinct was right.

**The credit incident, and what it cost.** 47% of a MAX block in one hour. Cause: **44 dispatches**
between 13:00 and 14:00 that started, paid a full cold read, hit the session limit, died, and retried —
because ADR-0009 clears a failed run's record so it can be retried, and exhaustion *looks* like a
transient failure. WR-014 fixes it and **was already published but not loaded**: the watcher had
started 31 minutes before the fix landed. Restarted; hold now armed and verified in all four Block-D
surfaces.

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
