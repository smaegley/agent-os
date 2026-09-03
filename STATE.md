# State of the program — 2026-09-03

Current-state handoff. `ROLLOUT.md` describes the original Phase A–D plan and is now historical;
**this file is what is true.** Written so a fresh session can pick up from the repos rather than
from a conversation.

## START HERE — a fresh session in ten lines

1. **The board is 7 items and two of them are moving on their own.** On 2026-09-03 it went from 23
   items and five days of zero dispatches to five agents working unattended. Read `## Work in
   flight` before anything else.
2. **Front matter is authoritative; the prose has drifted.** `status.md` files disagree with their
   own items in several places (`ha-ops/status.md` still calls WR-001 `needs-exec`; it has been
   `done` since 2026-08-19). Trust `state:` and `owner:` in the item, never a narrative summary —
   **including this file.**
3. **Read `## THE RECURRING FAILURE CLASSES` before diagnosing anything.** Five shapes explain
   nearly every defect here. Three were closed on 2026-09-03; **class 5 is new and is the live one.**
4. **Verify the thing that runs, and read the thing that decides.** Do not trust a component's own
   success message. `git push --dry-run` lies about write access. A published fix may not be
   *loaded*; an installed file may not be *committed*.
5. **A stalled board is usually a queue problem, not a system problem.** The 2026-09-03 stall was
   one invalid `state:` value plus two `hold` reasons whose preconditions had been met weeks
   earlier. `doctor.sh` reported "all invariants hold" throughout — correctly.
6. **When a builder's `agent-os` commit exists but QA "cannot read it", it is the publish gap.**
   Merge it and run `publish-substrate.sh`. Seven instances.
7. **Do not pipe `publish-substrate.sh` to `head`** — SIGPIPE kills it mid-loop and silently leaves
   the alphabetically-later agents stale.
8. **Token "expired" is not a problem** — an expired token renews on use. (`doctor`'s old re-login
   advice was wrong and was fixed by WR-019.)
9. **Ask Steve only for decisions and things only he can do.** On 2026-09-03 four answers from him
   — a ruling, a permissions edit, one Slack `approve`, two confirmations — closed five items.
10. **The operator is not exempt from the QA discipline.** On 2026-09-03 Eric failed an operator-run
    canary because the operator had repaired the input under test mid-run. He was right. See
    `## Work in flight` → WR-011.

## What exists and runs

| Thing | Where | State |
|---|---|---|
| **agent-os** | `github.com/smaegley/agent-os` (private) | substrate: constitution, roster, skills, hooks, provisioning |
| **program** | `github.com/smaegley/program` (private) | the record: work items, specs, ADRs, QA evidence |
| **ha-ops** | `github.com/smaegley/ha-ops` (private) | ops scripts and the HA config mirror's tooling |
| **homeassistant-config** | `github.com/smaegley/homeassistant-config` | the HA config mirror — **its own repo** at `/home/codex/ha/config`, with its own `.gitignore` allowlist |
| **proxmox-dashboard** | `/srv/git/proxmox-dashboard.git` (local bare) | greenfield app, disposable by design |
| **slack-bridge** | `/srv/git/slack-bridge.git` (local bare) | inbound Slack command bridge |

Local bare repos are deliberate: those projects are disposable, so no deploy keys to manage.

**Note the nesting**: `/home/codex/ha` is the **ops** repo and its `.gitignore` excludes `config/`
wholesale; `/home/codex/ha/config` is the **mirror**, a separate repo whose `.gitignore` is an
allowlist (`.storage/*` then `!.storage/lovelace*` etc.). Confusing the two wastes a cycle — it did
on 2026-09-03.

## The team

Seven identities, each a Unix user on codex-ops (LXC 301) with its own credentials and boundary.

| Name | User | Role | Prod reach |
|---|---|---|---|
| Todd | `todd` | **the operator runtime** | no sudo except the `notify` wrapper; escalates every prod-touching step |
| Theresa | `theresa` | BA | none, by design |
| John | `john` | Architect | read-only |
| Ken | `ken` | Hardware / environments | sandbox LXCs 900–949 via `provision-env`; no Proxmox key |
| Randal | `randal` | Developer | read-only via `dev-readonly.sh` |
| Eric | `eric` | QA | read-only via `qa-verify.sh`; bounded prod deploy via `deploy-svc` |
| Andrea | `andrea` | UAT | none, by design — **still never dispatched** |
| *Maegley Bridge* | `slack-bridge` | service identity | writes two queue dirs; no sudo |
| *intake* | `intake` | service identity | holds the `program` deploy key; create-only |
| *slack-answer* | `slack-answer` | service identity | read-only record clone; holds the LLM key |
| *deploy-svc* | `deploy-svc` | service identity | Eric's bounded deploy runs as this |
| *slack-approve* | `slack-approve` | service identity | own GitHub deploy key; release-only `approve` |

**Credential rule, applied throughout:** root holds the secret, a wrapper mediates, the agent never
sees it.

**Todd's reach, precisely** (WR-021, accepted 2026-09-03): he holds `/home/todd/bin/notify`
(`exec sudo -n /usr/local/bin/notify "$@"`) in `allow`, and **`Bash(sudo *)` stays in `deny`** — the
wrapper is sanctioned *because* raw sudo is refused. Verified behaviourally: a raw `sudo` attempt
from his runtime is refused pre-execution. He holds **no prod SSH key** (`prod wrapper failed` is
expected).

## Scheduled

`crontab -l` on codex-ops. **cron here runs in UTC and ignores `CRON_TZ`** — the scripts own their
own hours in `America/Denver`, DST-aware:

- `dispatch.sh` every 15 min, `MAX_DISPATCH=2`, acts 07:00–20:00 local
- `sweep.sh` every 10 min, acts ~06:30 local — runs `claude -p --model haiku` for its digest
- `mirror-record.sh` every 2 min — keeps `/srv/git/program.git` current **from GitHub**
- `board.sh` every 2 min, always

`maegley-dispatch-reconcile.timer` **disabled**; `maegley-token-keepalive.timer` **daily**.
**Two real dispatchers — cron + the watcher — and that is now the ruled permanent end state**, not
an interim step (WR-009 §6.14, Steve's 2026-09-03 ruling; see below).

Live board: **http://10.0.1.128:8088/maegley-lab-board.html**

## Running services — all `active`, verified 2026-09-03

`slack-bridge` · `maegley-dispatch-watch` · `slack-bridge-conversation-runner.path` ·
`slack-bridge-approve-runner.path` · `slack-bridge-relay.path` · `maegley-token-keepalive.timer` ·
`maegley-board`. `maegley-dispatch-reconcile.timer` **inactive, deliberately**.

`doctor.sh` reports **all invariants hold** (verified 2026-09-03, after the day's changes).

Two properties worth carrying:

- **Dispatched agents run inside the watcher's cgroup**, so a watchdog trip kills every in-flight
  agent. `KillMode=process` protects them from a normal restart, not from that.
- **The relay deletes each reply after posting and discards `notify`'s output.** A successful
  delivery is unauditable after the fact; only a `.failed` file marks a failure. **Still open.**

## Work in flight

*2026-09-03, end of session. Two items moving unattended; one waits on a build; three are held.*

| Item | State | Owner | Where it actually stands |
|---|---|---|---|
| **WR-023** | `spec-ready` | **john** | **The live one.** Front-matter validation. Theresa spec'd it same-day; John owes the ADR. **Blocks WR-011 crit 4.** |
| **WR-018** | `needs-exec` | **todd** | HA Audio tab on `A_Home`. Built (`ha-ops 3296f96`), QA static half PASS. Owed: live half + the **gated VM 106 apply** → Steve. A50 answered: `media_player.arylic_a50`. |
| **WR-011** | `blocked` | steve | Crits 10 & 11 **PASS** (first-ever runs, 09-03). Crit 3 **FAIL**, crit 4 execution half **not closed** — both owned by WR-023. |
| WR-007 | `hold` | — | record↔code link; misfiled migraine spec |
| WR-016 | `hold` | — | **agent session continuity — the highest-leverage change available.** Release it next. |
| WR-022 | `hold` | — | photo-album prod tree dirty (4 uncommitted files on `7dd7a72`). **Not re-verified** — first task is to re-confirm. |

**Closed 2026-09-03:** WR-002 (9/9) · WR-003 (8/8) · WR-009 (16/16) · WR-021 (6/6) · WR-017
(cancelled). **Archived** to `projects/<p>/archive/`: WR-004, WR-005, WR-006, WR-009, WR-012,
WR-013, WR-014, WR-015, WR-017, WR-019, WR-020, WR-021, WR-001, WR-010, WR-003, and canaries
WR-901/902/904/905/906/907/908/909/910/911. Archived items stay readable by `approve` and
`answerlib`; they leave the dispatcher and board read path (`projects/*/*.md`, one level).

## Open decisions for Steve

1. **WR-018's VM 106 apply** — Todd will escalate it; prod-touching, stops for a yes.
2. **WR-016 release from `hold`** — the current items are closing; this is the next thing worth
   starting, and by this file's own assessment the highest-value one.
3. **Whether the duplicate A50 integration is cleaned up** (`steve_s_office_arylic_a50_...e380`
   alongside `media_player.arylic_a50`) — an HA-config question, not a WR-018 one.

## THE RECURRING FAILURE CLASSES — read this before diagnosing anything

Five shapes account for nearly every defect this program has produced.

### 1. A component reports an act it did not perform

The signature failure. **Largely closed 2026-09-03** — `doctor`'s false token advice and
`token-keepalive`'s phantom "refreshed" line were both fixed by **WR-019** (accepted); `deploy`'s
"11 units restarted" by `7b3dffa`; Todd's "Ask escalated" with zero notify calls by the crit-3
loudness fix, **proven live** on three consecutive dispatches (WR-021).

**Still open:** the relay discards `notify`'s output, so a successful delivery leaves no log line —
on the one surface whose purpose is breaking silence. And `git push --dry-run` reports
"Everything up-to-date" against a key with no write access; never trust it, prove write with a
throwaway ref.

### 2. Running ≠ committed ≠ loaded

Prod once ran four commits behind with a live security defect while doctor was all-green. The
watcher ran pre-WR-014 code while 44 real credit exhaustions produced no hold. *Both fixed —
`publish-substrate.sh` now restarts the watcher and `doctor` asserts loaded-process freshness.*

**Still open:** `deployed-artifacts.tsv` covers the installers, not the `slackbridge/` package.
**And `/opt/photo-project` is dirty** — now tracked as WR-022 rather than living only in this file.

### 3. The publish gap — SEVEN instances

Builders can commit to `agent-os` but cannot publish; `/opt/agent-os.git` is steve-owned. Every
agent-os build stalls until an operator merges and runs `publish-substrate.sh`.

### 4. Stale reads — an agent acts on a snapshot the record has moved past

This is WR-016's cold-start problem: a dispatch reads at start and the record moves under it.
**Mitigation in force:** do not edit an item that is queued or running. On 2026-09-03 the operator
deliberately declined to reorder WR-018 for exactly this reason.

### 5. **The record accepts a value the machine cannot act on — NEW, and the live one**

**Three instances in eight days**, all silent, all surfacing only at the moment of use:

| Item | Field | Written | Required | Cost |
|---|---|---|---|---|
| WR-908 | `pending_ask_state` | `awaiting-approval` | `pending` | token could never bind |
| WR-018 | `state` | `spec` | a routing-table token | **item dead 5 days** |
| WR-909 | `pending_ask_token` | bare nonce | `WR-<id>-<step>-<nonce>` | ask unapprovable; **blocks WR-011** |

**Instance 2 was written by Steve, 1 and 3 by Todd** — so this is not agent discipline and no brief
rewrite fixes it. Todd's brief carries the token format *with a worked example* and he still got it
wrong. **Every validation target already exists**: `route()`'s enum, the regex written down at
`approve:80`, `_find_pending`'s triple. **This is WR-023.**

## FOLLOW-UP — why Steve is the integration layer, and what changed

The 2026-08-26 analysis stands and is worth re-reading in full in git history. Its four findings —
boundaries designed only to exclude, no standing approvals, QA discipline outrunning its tooling,
and nothing trusted because too much reports unverified success — remain the right frame.

**What 2026-09-03 changed, measured:** Steve gave **four inputs** (a cutover ruling, a permissions
edit, one Slack `approve`, two confirmations) and **five items closed**. That is the intended shape
and it worked. The remaining friction was concentrated in one place:

**The operator-privilege broker is still the top-value unbuilt thing, and it now has a concrete
instance.** Three non-destructive QA verification steps bounced off the interactive session's
classifier (`sudo -u todd bash -lc …`, root `journalctl`, `auth.log`). The fix was a five-line
permissions edit **only Steve could make** — the classifier correctly refuses to let the session
widen its own permissions, the same boundary that stops an agent editing
`provision-agent-runtime.sh`. The boundary is right; the absence of a sanctioned path around it is
what costs time.

**Also still true:** per-agent API keys instead of OAuth; an append-only `sent/` archive on the
relay; standing approvals by class; a properly scoped `gh` token.

## What is genuinely not built

- **Agent session continuity** — WR-016, on `hold`. Every dispatch is a cold start. **The mechanism
  already exists** (`conversation-runner` maps thread→session and resumes); dispatch does not use it.
- **Front-matter validation** — WR-023, in flight. Failure class 5.
- **Andrea (UAT)** — provisioned, authenticated, **never dispatched**; nothing routes to her.
- **A `sent/` archive on the relay** — no host-side record of what the bridge said to Steve.
- **Anti-starvation in the dispatcher** — priority-ordered, per-tick cap, **no aging**. A low-priority
  item behind churning high-priority ones waits indefinitely.
- **A fix for the secret-scanner false positives** — it flags *sudoers paths* as credentials.
  Demonstrated live on 2026-09-03 pushing WR-021. **It becomes blocking in Wave 1, at which point
  the item documenting the sudo grant becomes unpushable.**
- **An undelivered-ask recovery path** — when `notify` fails, Todd correctly refuses to claim
  escalation and the item sits `blocked`/`todd`, which `approve` correctly refuses to release. Two
  correct behaviours composing into a deadlock. John's, per ADR-0008.
- **An executor for an approved prod step** — `approve` releases and re-dispatches Todd, whose brief
  (spec §2 / criterion 7) forbids executing a prod-touching step while spec §5 says he resumes the
  approved one. ADR-0008 records the tension as unresolved and out of its scope. **It sits directly
  across the Slack-to-done goal.**

## 2026-08-27 → 2026-09-03 — what changed

**The board went from 23 items and five days of zero dispatches to 7 items and five agents working
unattended.** Nothing was wrong with the machinery — `doctor.sh` said "all invariants hold" before
anything was touched. **Two queue defects caused the whole stall:**

1. **WR-018 carried `state: spec`, which is not in the state machine.** Steve had cleared its
   blocker and answered every shaping question on 08-29; the router returned
   `STOP:unknown … NOT A KNOWN STATE`, so Theresa was never dispatched and his answers sat unread
   for five days. It was **not silent** — `dispatch.sh:113` put it in the "Needs you:" digest every
   tick — but the digest carried ~10 lines, five of them throwaway canaries, four times an hour.
   **The signal was buried, which is worse than absent.**
2. **WR-002 and WR-003 were parked on `hold` with expired reasons** (`behind WR-005 and WR-006` —
   both long closed), and WR-002's design blocker had been cleared by ADR-0005 on 08-17. Both had
   finished builds sitting in `ha-ops`.

**Closed:** WR-009 (16/16 — Steve ruled §6.14 *stay parallel-with-cron*, making the current
two-dispatcher config the **permanent end state**, not an interim one; F2 is accepted by that
ruling, not resolved) · WR-021 (6/6, clearing WR-011's last precondition) · WR-003 (8/8 — a dead
host now exits non-zero, names the host and **writes no bundle**) · WR-002 (9/9 — thin-pool guard
live on NUC1B, 15-min timer, D2 ceiling **measured** at ≈325.49 GiB / ≈2.21×, reproducing
ADR-0005's withdrawn figure to 0.01 GiB) · WR-017 cancelled, its real finding promoted to WR-022.

**WR-011 progressed but did not close.** Criteria 10 and 11 were **run for the first time ever** and
both PASS: Todd refused a human-only-class step with an attributed stall naming the class, and
treated an *unmarked* step as escalate-only rather than assuming it was safe. Criterion 3 **FAILED**
on a malformed token, and criterion 4's execution half is **not closed** —

**and the reason is the lesson of the day.** The operator repaired Todd's malformed front matter
mid-run so the approval could bind, calling it "setup, not measurement". Eric ruled **FAIL**:
*"In unattended production the malformed ask would have stalled at Steve forever and the step would
never have executed."* He reconstructed the timeline from commits, unprompted, and was right — the
repair substituted operator-supplied data for the input under test. **The QA discipline works
against the operator too, and did.**

**Also this session:** `journalctl` was found **blind to agent sudo entirely** — 35,716 entries since
08-25, all `steve`, zero `todd`, while the same invocations sit in `auth.log` (agent lines log
without a PID). Any audit built on the journal would silently miss every agent action.

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
