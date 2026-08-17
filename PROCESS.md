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
| 9 | Deploy to prod | Eric per Steve's flow | ⚠️ today deploys are Todd's, gated on Steve's approval — giving QA deploy keys contradicts QA independence; **flagged for Steve's ruling** |

Along the way: every agent posts to #program when it **starts** and when it **finishes**, and
questions between agents surface there too. (Start posts: live as of today. Question relay:
carried by the blocked→escalation path.)

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
