---
name: definition-of-done
description: Use before claiming any work is complete, and whenever accepting or rejecting a deliverable. Defines what evidence a "done" claim requires and who may make it. Triggers on "is this done", "mark complete", "ready to deploy", "accept this", or any handoff back to Steve.
version: 1.0.0
---

# Definition of Done

**Only Eric (QA) marks work complete.** Everyone else reports work as *ready for verification*.

## The rule this exists to enforce

Self-attestation is not evidence. "I ran it and it worked" is a claim, not a verification —
and a claim made through the same access path used to build the thing proves nothing about
production. Verification is performed by someone with *different* tool access than the builder.

This is not bureaucracy. It exists because a dev agent here once made confident claims about
production state it had no ability to observe.

## Done requires all of these

### 1. Meets the spec
Every acceptance criterion in the spec, checked individually. Not "broadly satisfied" —
enumerated, each with its result.

### 2. Evidence, not assertion
For each criterion, what was actually observed: command output, a screenshot, a query result,
a log line. Evidence must be reproducible by a third party from what is written down.

### 3. Verified where it runs
Working in dev is not working. Confirm behavior in the environment the user will actually
touch, or state explicitly that you could not and why.

### 4. Failure paths tested
Error handling, empty state, restart behavior, and whatever happens when a dependency is
unavailable. Untested failure paths are the ones that page you later.

### 5. No silent success
Confirm the thing actually happened, not that it returned zero. A job can exit clean having
processed nothing. A sensor can hold a plausible value while being dead for weeks. Check
effects and timestamps, not status codes.

### 6. Reversible
How to undo it is written down and has been thought through. For prod changes this is
mandatory, not optional.

### 7. Documented where it belongs
Status updated in `program/projects/<p>/status.md`. Decisions recorded as ADRs. Nothing
important living only in a chat thread.

### 8. No secrets committed
Confirmed by the secret-scan hook, not by eyeballing the diff.

## Rejecting

Be specific. Name the criterion, state what you observed, and give the reproduction. "Doesn't
meet spec" wastes a round trip.

Do not soften a verdict because the work was hard, because it is late, or because most of it
is fine. Partial completion is reported as partial — say exactly what is done and what is not.

## What is explicitly *not* required

Perfection, or every possible improvement. Done means "meets the spec, verified." Improvements
beyond scope go in the backlog, not into a widening deliverable.

## When verification requires running something QA cannot run

Some acceptance criteria can only be checked by executing against production — and QA is
read-only on purpose. Do not resolve that by widening QA's access, and never resolve it by
reading the source and inferring what a run would do. Inspection and execution are different
kinds of evidence and must not be substituted for one another.

Instead, **QA directs and the operator executes** — and the operator is **Todd**, never Steve.
Steve is never handed raw commands. If a run request contains anything destructive or
prod-touching, Todd first sends Steve a plain-language approval ask: what will run, why, the
risk, the expected outcome, and the rollback. Steve answers yes or no. That is the entirety of
his involvement in execution.

1. Verify by inspection everything that inspection can settle, and record those verdicts.
2. For the rest, write a run request to `projects/<project>/qa/<date>-<item>-run-request.md`:
   the **exact commands**, the working directory, and — stated in advance — what output would
   constitute a pass and what would constitute a fail.
3. Set the item's state to `needs-exec`. It escalates to Steve; no agent is dispatched.
4. Todd runs the commands verbatim and commits the **raw, unedited** output alongside as
   `<date>-<item>-run-output.md`.
5. QA reads that output and issues the verdict, then returns the item to `qa-ready` → verdict.

QA's independence is preserved: it did not build the thing and did not guess. The operator's
role is mechanical — run exactly what was asked and publish exactly what came back. An operator
who edits, summarises, or omits output has destroyed the evidence.

Deciding the pass/fail condition **before** seeing the output is the point. It is what stops a
disappointing result from being reinterpreted as a pass after the fact.

## Verify the data, not just the behaviour

Added 2026-08-17 after Steve looked at a finished, fully-green dashboard and said *"I question
the data in the Backup column."* He was right: the app could not see 161 backup files that
existed, and rendered their absence as blank. The offline suite was 29/29 green and QA's
inspection passed. **Neither was wrong, and neither could have caught it.**

Testing that code does what it was written to do is a different question from testing that its
output matches the world it describes. Both QA and UAT must do the second one.

**What this requires in practice:**

1. **Sample the real output and check it against reality.** Not "does the endpoint return 200",
   but "are these numbers true?" Pick values a human would notice — a count, a timestamp, a
   status — and confirm them against the source system.
2. **Use an access path the application does not use.** Verifying through the app's own
   credential reproduces the app's own blind spots: had QA queried Proxmox with the dashboard's
   token, it would have seen the same empty backup list and concluded the app was correct. This
   is the same rule that gives QA a separate key from the implementer, applied to data.
3. **Treat empty as suspicious.** An API returning `{"data":[]}` is *success with nothing in
   it*, indistinguishable from "there is nothing" — and that is exactly how this defect hid. If
   a result is empty, prove it should be empty.
4. **Never let unavailable data render as a confident value.** Blank, `0`, and `null` all read
   as fact. If the value could not be obtained, the output must say so.

A green test suite means the code is self-consistent. It says nothing about whether the code is
telling the truth.
