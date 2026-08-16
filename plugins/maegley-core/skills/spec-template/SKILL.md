---
name: spec-template
description: Use when writing, reviewing, or accepting a specification for any Maegley lab project. Defines the required sections a spec must contain before implementation may start, and what makes each section adequate. Triggers on "write a spec", "requirements", "what should this do", or handing work to a developer.
version: 1.0.0
---

# Spec Template

A spec exists so that the person building can proceed without guessing, and so that the person
verifying knows what "correct" means. If it does not do both, it is not finished.

## Required sections

A spec missing any of these is not ready to hand over.

### 1. Problem
What is wrong today, in terms of what someone experiences. Not the proposed solution.

### 2. Outcome
What will be true when this is done. **Measurable.** "Faster" is not an outcome; "gallery
first paint under 2s on an iPhone over LAN" is.

### 3. Scope
What is included. Then, explicitly, **what is not** — the "out of scope" list prevents the
quiet expansion that turns a two-day change into a two-week one.

### 4. Constraints
What the solution must live within: existing infrastructure, the LXC deploy pattern, no new
services without an ADR, data that must not leave the box, credentials that must not move.

### 5. Behavior
The actual requirements, each independently verifiable. Include the unglamorous paths:
- What happens on error
- What happens with no data
- What happens on restart
- What happens with concurrent access

### 6. Acceptance criteria
The checklist Eric will verify against. Each line must be objectively checkable by someone who
did not build it. If a criterion can only be confirmed by asking the developer, rewrite it.

### 7. Open questions
Genuine unknowns, named. A spec with an honest open-questions section is more useful than one
that fills a gap with a confident guess.

### 8. Decisions
What was chosen and what was rejected, with the constraint that decided it. Without this the
next person relitigates settled ground.

## What makes a spec bad

- **Solution-first.** Describes an implementation and calls it a requirement.
- **Unfalsifiable acceptance criteria.** "Works reliably", "performs well", "is intuitive."
- **Silent assumptions.** Assumes a service exists, a credential is available, or capacity is
  free, without checking.
- **Happy path only.** The failures are where the work actually is.
- **Padding.** Length is not thoroughness. Cut anything that would not change what gets built.

## Before handing over

- [ ] All eight sections present
- [ ] Every acceptance criterion checkable by a third party
- [ ] Out-of-scope list is non-empty
- [ ] Open questions either answered or explicitly accepted as risks by Steve
- [ ] Capacity and credential assumptions verified against reality, not assumed
