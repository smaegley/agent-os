# How work moves — Steve's flow, verbatim

Written 2026-08-17 after Steve stated the intended flow directly. This is the target the
tooling is built toward; the gap table below is the honest delta. His words define the steps.

| # | Step | Who | Status today |
|---|------|-----|--------------|
| 1 | Steve states what he wants built | Steve | ✅ works (to Claude; Slack intake is step 2's gap) |
| 2 | Request lands with Theresa via Slack; she elicits requirements, writes the spec | Theresa | ⚠️ Theresa works, but intake is via Todd — **no inbound Slack path yet** |
| 3 | John reviews, asks questions, records the architecture | John | ✅ works (ADR-0001/2/4) |
| 4 | Ken builds the test env and the prod env | Ken | ❌ Ken has a runtime but no env-building capability; envs are built by Todd |
| 5 | Randal develops it | Randal | ✅ works |
| 6 | Eric tests it | Eric | ✅ works — and **Todd, never Steve, executes** anything QA cannot |
| 7 | Andrea tests it (UAT) | Andrea | ❌ not provisioned — first user-facing item will trigger it |
| 8 | Steve gets ONE Slack message: review, test, approve | Steve | ⚠️ escalations exist; the single consolidated ask needs building |
| 9 | Deploy to prod | **Eric** | ✅ **RULED 2026-08-21: "eric can deploy to prod."** Flagged six times; Steve's flow stands. Not yet implemented — Eric has no prod write path today (`Bash(sudo *)` denied), so this needs an ADR before it is real. See below. |

Along the way: every agent posts to #program when it **starts** and when it **finishes**, and
questions between agents surface there too. (Start posts: live as of today. Question relay:
carried by the blocked→escalation path.)

## Step 9 — Steve's ruling, and what it costs

**2026-08-21, Steve: _"eric can deploy to prod."_** The question was raised six times and is now
answered. Steve's original flow — the one this document exists to implement — always said Eric
deploys. Todd's repeated recommendation was the opposite, and Todd was overruled. That is recorded
here so nobody re-litigates it a seventh time.

**The tradeoff, stated once and then dropped.** Eric is the only role that may mark work complete.
With step 9 he also ships it, so the role that certifies and the role that deploys are the same —
which is what "QA independence" meant. Steve owns that risk knowingly; the deploy gate (his own
yes/no) still sits in front of every prod write, so nothing reaches production unreviewed either way.

**This is not implemented, and must not be faked.** Today Eric has:
`Bash(sudo *)` **denied**, no prod SSH key, and read-only reach via `qa-verify.sh`. Every real
deploy in this lab is `sudo install` / `systemctl restart` / `sudo cp`. So step 9 currently cannot
happen at all — the ruling changes the target, not the capability.

**What it needs before it is true — John's ADR, not an operator patch:**

1. **Which verbs.** "Deploy" is not one action. Installing a file, restarting a unit, pushing a
   repo, and editing sudoers are different powers. The grant should enumerate them, in the shape
   already used twice: a single-purpose wrapper (`notify`, `intake`) rather than general `sudo`.
2. **Which targets.** Eric deploying `slack-bridge` is not Eric deploying the HA config mirror or a
   hypervisor. `infra: true` items may warrant a different answer.
3. **Whether the deploy identity is Eric's own.** The lab's credential rule is *root holds the
   secret, a wrapper mediates, the agent never sees it* — applied seven times. A `deploy` service
   identity Eric invokes preserves that; handing Eric prod keys does not.
4. **What Todd still does.** If Eric deploys, the operator's remaining role in step 9 needs saying,
   or it will be discovered by two roles both assuming the other did it.

Until that ADR lands, deploys remain Todd's on Steve's approval — **not because the ruling is in
doubt, but because the capability does not exist yet.**

## Standing rules extracted from the same conversation

1. **Steve is never handed raw shell commands.** Todd executes; Steve receives a plain-language
   ask — what runs, why, risk, expected outcome, rollback — and answers yes or no.
2. **Process shakedown happens on inconsequential targets.** A new process or agent proves
   itself on greenfield work whose total loss costs nothing — never on the HA config mirror,
   never on a production hypervisor.
3. Chat is the doorbell AND the visibility layer; git remains the record.

## The coordinator, named

The state machine routes; it does not judge. Three things are coordination and belong to
**Todd**, explicitly — not to a PM agent re-deriving context per wake, and never to Steve:

1. **Interpreting blocks** — reading why an item stopped and routing it accordingly.
2. **Filling world-gaps** — a blocked item that needs something built (a repo, a credential, an
   environment) gets the thing built, then unblocked.
3. **Sequencing** — via `priority:` in item front matter (1 = most urgent, unset = 5).
   Alphabetical accident is not a prioritization policy.

Revisit a dedicated coordinator only if the backlog makes prioritization a daily judgment task.
