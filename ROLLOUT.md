# Agent Organization — Rollout Plan (v0.1, 2026-08-15)

**Author:** Ops (LXC 301)
**Status:** DRAFT — awaiting Steve's confirmation before any infra action
**Decisions locked:** GitHub private repos · all active projects at once · Slack from day one

---

## 0. Principles

These are the load-bearing rules. Everything below is an implementation of them.

1. **Git is the record; chat is the doorbell.** Specs, statuses, decisions, and QA results are
   files in `program/`. Slack carries *pointers and notifications only*. If an agent must scroll
   chat to reconstruct context, the design has failed.
2. **Identity is enforced by credentials, not by prompt.** A role's real identity is what it can
   reach. Personas are documentation; keys and forced commands are enforcement.
3. **Prod credentials live only with Ops.** No other role holds a credential that reaches production.
4. **Self-attestation is not evidence.** A "done" claim is verified by a role with *different*
   tool access than the claimant.
5. **Everything ships as a plugin.** Uninstalling the plugin fully reverts the org. No
   project-local edits that can't be backed out.
6. **Gates warn before they block.** See §4.

---

## 1. Project inventory — CONFIRM BEFORE PROCEEDING

Rollout targets "all active projects." That requires an explicit list. Proposed from prior
context — Steve to correct:

| Project | Where it runs | Dev agent home | Blast radius | Blocking-gate wave |
|---|---|---|---|---|
| Photo album | LXC 209 | VM 201 | Low (family-facing, additive) | Wave 1 |
| Solar tracker | LXC 207 | VM 201 | Low | Wave 1 |
| Migraine tracker | LXC (per creds ref) | VM 201 | Low | Wave 1 |
| bi-lab | CT 211 | CT 211 | Low (dev/test box) | Wave 2 |
| Voice assistant | HA + pending LXC | — | Medium (touches live HA) | Wave 2 |
| HA / Proxmox ops | LXC 301 (this box) | — | **High** (prod infra) | Wave 3 |
| HomeSplit | LXC 202 | VM 201 | **High** (Plaid production, real money) | Wave 3 |

**bi-lab — RESOLVED 2026-08-15.** The "first dev environment, where HomeSplit dev happened" is
**VM 201 (`ai-sandbox-ubuntu`)**, not bi-lab. bi-lab CT 211 is what the records say: the **Tableau
Migration Analyzer** dev/test box, built 2026-07-19, sensitive corpus. Steve intends to pick that
project back up — so it is a *dormant project to be resumed*, not a migration candidate. No move to
LXC 301. Substrate-only, no Slack channel until it's active.

---

## 2. Repos

### 2a. `agent-os` — the substrate (small, stable)

Private GitHub repo. Changes rarely. This is the thing every project installs.

```
agent-os/
  .claude-plugin/marketplace.json      # makes the repo an installable marketplace
  plugins/maegley-core/
    .claude-plugin/plugin.json
    agents/
      architect.md                     # name + model + tool scope in frontmatter
      ba.md
      qa.md
      uat.md
    skills/
      spec-template/SKILL.md           # what a spec must contain
      definition-of-done/SKILL.md      # what "done" requires as evidence
      lxc-deploy/SKILL.md              # the rsync/venv/systemd pattern
      handoff-format/SKILL.md          # extracted from existing OPS-*.md docs
      slack-protocol/SKILL.md          # how/what/where to post
    hooks/
      spec-required.sh                 # no implementation without an accepted spec
      pre-deploy-gate.sh               # no prod touch without approval
      artifact-contract.sh             # emitted files match their schema
    commands/
      handoff.md  status.md  accept.md
  CLAUDE.md                            # the constitution
  AGENTS.md                            # registry: who exists, model, tool scope, host
  ROLLOUT.md                           # this document
```

### 2b. `program` — the state (large, churns constantly)

```
program/
  projects/<name>/
    spec/          # BA output, versioned
    decisions/     # ADR-####.md, append-only
    qa/            # test plans + evidence
    status.md      # single source of truth for "where is this"
  decisions/       # cross-project ADRs
  log/             # append-only: who, what, when, cost
```

### 2c. Access

- Ops (LXC 301): write to both repos.
- DEV (VM 201): write to `program/projects/*`, **read-only** on `agent-os`.
- Deploy keys per host, not a shared account.

---

## 3. Agent roster

Names are consistent across projects. Model tier is set in each agent's frontmatter.

| Name | Role | Model tier | Reads | Writes | Prod access |
|---|---|---|---|---|---|
| **Todd** | **Ops** (existing, LXC 301) | Opus | everything | prod, both repos | **Full — sole holder of prod keys** |
| **John** | **Architect** | Opus | repos, prod *read-only* via forced cmd | `program/decisions/`, env specs | Read-only |
| **Theresa** | **BA** | Sonnet | repos, Slack | `program/projects/*/spec/` | **None** |
| **Randal** | **DEV** (existing, VM 201) | Opus | repos, dev env | code repos, `program/projects/*` | **None** — `devread` forced command only |
| **Eric** | **QA** | Opus | repos, prod *read-only* via forced cmd | `program/projects/*/qa/` | Read-only, **different key than DEV** |
| **Andrea** | **UAT** | Sonnet | staging/prod UI, repos | `program/projects/*/qa/uat-*` | UI-level only |
| **Ken** | **Hardware/Firmware** | Opus | ESPHome/PlatformIO, device serial, repos | device configs, `program/projects/*` | Flash access to devices only |
| — | **Sweep** (scheduled job, *deliberately not a persona*) | Haiku | `program/` | Slack digest only | None |

**Naming rules.** Names identify *individuals*, not roles. A second BA gets her own name, never
`theresa-2` — the whole point is that identity is stable and traceable across projects. Ops and
DEV are existing persistent identities and need names for the same reason.

**Sweep stays unnamed on purpose.** It is a cron job that collates files. Giving it a human name
invites treating its digest as a colleague's judgment rather than a query result.

**Why QA and DEV get different keys:** QA verifying DEV's work through DEV's own access path is
not verification. This directly addresses the prior incident where DEV made claims about prod it
had no ability to check.

**No PM role at launch.** Coordination state lives in `status.md` + the scheduled sweep. If the
sweep demonstrably fails to keep things moving, add one then — with evidence of what it must fix.

---

## 4. Enforcement staging — the key adaptation to "all projects at once"

Installing everywhere on day one is fine. Turning on *blocking* hooks everywhere on day one is
not: a single bad hook halts every workstream simultaneously, and you'd be debugging it across
seven projects at once.

| Stage | Duration | Hook behavior | Exit criterion |
|---|---|---|---|
| **Install** | Day 1 | Hooks log to `program/log/`, never block | Plugin resolves in every project folder |
| **Warn** | ~1 week | Hooks warn loudly, still never block | Warning rate stops falling — remaining hits are real violations, not false positives |
| **Block, Wave 1** | Week 2 | Blocking on photo album, solar, migraine | 1 week clean |
| **Block, Wave 2** | Week 3 | + bi-lab, voice assistant | 1 week clean |
| **Block, Wave 3** | Week 4 | + HA/Proxmox ops, HomeSplit | — |

HomeSplit is last on purpose: Plaid is in `production` env against real accounts.

**Backout at any stage:** uninstall the plugin. That property must be preserved — no hook may
write state outside `program/log/` that something else then depends on.

---

## 5. Slack

### Workspace & channels

Workspace: `maegley-lab` (free tier).

| Channel | Purpose | Who posts |
|---|---|---|
| `#program` | Cross-project digest, escalations, blocked items | Sweep, Ops |
| `#proj-photo-album`, `#proj-homesplit`, `#proj-solar`, `#proj-migraine`, `#proj-voice` | Per-project coordination | All roles on that project |
| `#ops-prod` | Deploy events, infra changes, approval requests | **Ops only** |

Telegram is untouched — it stays the infra alerting path (~11 live HA automations). No mirroring;
two systems with one job each.

### Identity

**One bot token**, held by Ops. Per-agent identity via `username` + `icon_emoji` overrides on
`chat.postMessage`. Avoids managing seven tokens and keeps the credential in one place.

### Posting protocol (becomes `slack-protocol` skill)

- Every message is prefixed `[project][role]`.
- Every message about an artifact **links the artifact in git**. Never paste the artifact.
- One thread per artifact. Discussion stays in-thread.
- Approval requests go to `#ops-prod` and name what will change, on what host, and how to revert.
- Free tier's 90-day history is a non-issue because chat holds no state (Principle 1).

### Trigger model — stated plainly

Agents are invoked, not resident. Nothing "listens" to Slack in real time. Movement comes from:

1. A session finishing work → posts a pointer to Slack.
2. A **scheduled sweep** (2×/day) → reads `program/`, finds stale/blocked items, posts a digest to
   `#program`, pings the blocked party.
3. Steve → approves prod actions in `#ops-prod`.

Steve stays the **approver**, not the **router**. That is the intended outcome, not a limitation.

---

## 6. Execution steps

Each step is independently useful. Nothing here runs without Steve's go-ahead.

### Phase A — foundation (APPROVED 2026-08-15; partially complete)
1. ~~`git init` `/home/codex/ha` with an **allowlist** `.gitignore`~~ — **DONE**, commit `aa475ae`,
   17 files, scanned clean. Allowlist rather than denylist because this directory mirrors live HA
   config; a denylist leaks on the first new file.
2. ~~Install `gh` from GitHub's official apt repo~~ — **DONE**, 2.97.0. (Ubuntu repo ships 2.4.0,
   too old for current auth flows.)
3. ~~Create private repos `agent-os` and `program` under `github.com/smaegley`~~ — **DONE
   2026-08-16.** Both private, verified by unauthenticated request (HTTP 404 to an anonymous
   caller is the only proof that doesn't depend on our own token).

**Phase A lessons:**
- `gh auth login` offered to upload `~/.ssh/proxmox_lxc.pub` — the **root key to the Proxmox
  nodes and every LXC**. The upload failed on a 403, which was luck. One keypair must never span
  source control and root-on-infrastructure: revoking GitHub would otherwise mean re-keying every
  host. Dedicated key `~/.ssh/github_todd` created and pinned in `~/.ssh/config` with
  `IdentitiesOnly yes`.
- **Fine-grained PATs cannot create repositories** (`gh repo create` → 403) and only see the
  repos explicitly selected for them. Repos had to be created in the web UI.
- `program` was created **public** by default and pushed before anyone noticed. No credentials
  were exposed — the gate was live and found none — but the README disclosed LXC topology for
  ~10 minutes. **Check visibility before the first push, not after.**

### Phase A.5 — secret scrub (NEW — discovered during Phase A)

The git init survey found live production credentials in cleartext in the ops workspace. These
were quarantined from the first commit and remain untracked, but **they are still on disk and were
readable by anything with access to this box**:

| File | Exposure | Action |
|---|---|---|
| `flip-ha.sh:16` | HA long-lived bearer token, hardcoded | Move to `~/.config/ops/secrets.env`, read via env |
| `notes/migration-log.md:19` | Proxmox API token `root@pam!claude-read` | Redact to a pointer; **rotate the token** |
| `notes/migration-log.md:24` | Pi-hole admin password | Redact; rotate |
| `notes/migration-log.md:97` | A root password | Redact; rotate |
| `b2-app.txt` | Backblaze B2 keyID + application key | Move to secrets store; rotate |
| `.claude/settings.local.json` | Proxmox API token inside an allow rule | Rewrite the rule to not embed the secret |

**Rotation is the real fix; redaction alone is not.** These values have sat in plaintext files of
unknown exposure. Recommend rotating all six regardless of whether they ever reached GitHub.

Also add a **pre-commit secret scan hook** to `agent-os` so this class of mistake is caught by
machine rather than by survey. This is the first hook worth writing.

### Phase B — substrate (COMPLETE 2026-08-16, commit `fcb2e55`)
4. ~~Write `CLAUDE.md` (constitution)~~ — **DONE**. Six principles + prod rules + artifact
   ownership + Slack protocol + escalation.
5. Extract `handoff-format` and `lxc-deploy` skills from existing practice. — **DEFERRED.**
   Both are transcription of working practice with no open questions; they cost time without
   teaching anything. Write them when a project actually needs them.
6. ~~Write `spec-template` and `definition-of-done` skills~~ — **DONE**. As predicted, the
   highest-value artifacts here.
7. ~~Author the agent definitions~~ — **DONE**, five not four: John, Theresa, Eric, Andrea, and
   **Ken** (Hardware/Firmware), added because the original roster had no owner for the
   ESPHome/PlatformIO workstream Steve named in his first description of the org.
8. ~~Package as plugin, publish marketplace, verify pickup~~ — **DONE**. Marketplace validates;
   `maegley-core` installs at `--scope local` and reports enabled.

**Also delivered:** `hooks/secret-scan.sh`, pulled forward from Phase D because Phase A proved
it was needed. Verified in both directions — it catches all eight real credentials in the ops
workspace (two more than the manual survey found) and produces zero false positives against
clean docs. It also caught a bug in its own first version, which printed a password unredacted;
a scanner that echoes the secret to the terminal and the log has made the problem worse.

### Phase C — credentials (needs approval; touches prod)
9. Generate per-role SSH keys. Extend the `devread` forced-command pattern to a QA key with a
   distinct command set.
10. Provision the Slack workspace, bot, and channels. Store the token with prod secrets on Ops.

### Phase D — rollout
11. Install the plugin across all projects in §1, hooks in **Install** mode.
12. Stand up the scheduled sweep.
13. Walk the enforcement stages in §4.

---

## 7. Risks

| Risk | Mitigation |
|---|---|
| Bureaucracy: agents generate documents for each other, Steve reads more not less | No PM role; sweep digests instead of per-agent status reports; kill any artifact nobody reads |
| All-at-once rollout breaks everything simultaneously | Staged enforcement (§4); plugin uninstall as one-step backout |
| Token spend climbs quietly | Model tier fixed per role; cost logged per project in `program/log/` |
| Two agents edit one spec | Git makes conflicts visible; one-writer-per-artifact convention |
| Approval gate gets skipped as agent count grows | It's a hook (blocks), not a memory (persuades) |
| Slack becomes the state store | Protocol forbids pasting artifacts; enforced by review, and the 90-day limit makes violations self-punishing |
| Chat bus stood up before the pilot proves what's needed | Accepted by Steve. Start with the minimum channel set above; add only on demonstrated need |

---

## 8. Needed from Steve

1. **Confirm the project list** in §1 — especially whether bi-lab is in scope.
2. **GitHub account/org** the private repos should live under.
3. **Slack workspace** — create new `maegley-lab`, or use an existing one?
4. **Agent names** — the roster uses role labels. If you want persistent proper names
   (consistent across projects, as you described), supply them and they go in `AGENTS.md`.
5. **Go-ahead for Phase A**, which is the only part that touches this box.
