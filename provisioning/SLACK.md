# Slack transport

Agents post to Slack through `notify`, a root-owned wrapper that holds the bot token.
No agent ever holds it.

## Design

```
agent ──sudo──▶ /usr/local/bin/notify ──reads──▶ /etc/maegley/slack-token (root 0600)
                        │                                  agent cannot read this
                        └─ identity from $SUDO_USER, not from an argument
```

Three properties, each verified rather than assumed (2026-08-16):

| Property | How it is enforced | Verified by |
|---|---|---|
| Agent cannot read the token | root-owned `0600` in a `0700` directory | `sudo -u eric ls /etc/maegley` → denied |
| Agent can run nothing else as root | sudoers grants exactly one binary | `sudo -u eric sudo -l` lists only `notify`; `sudo cat <token>` → password required |
| Agent cannot post as another agent | poster name derived from `$SUDO_USER` | `env SUDO_USER=steve sudo notify …` still posted as **Eric** — sudo re-sets the variable |

That last one is why this runs through sudo rather than handing each agent the token: sudo
is what makes the identity unforgeable. An argument-supplied name would be a claim; this is
an attestation.

The wrapper also enforces a **channel allowlist** (`#program`, `#ops-prod`, `#proj-*`) so an
agent cannot invent channels or message the workspace at large.

## Setup

1. Slack workspace, then api.slack.com/apps → **Create New App** → From scratch.
2. **OAuth & Permissions** → Bot Token Scopes: `chat:write`, `chat:write.customize`
   (the second is what allows per-agent display names from a single bot).
   Add `channels:read` too if you want the wrapper able to self-diagnose membership.
3. Install to workspace; copy the `xoxb-…` token.
4. Install the token **without pasting it into a transcript**:
   ```bash
   sudo install -d -m 700 /etc/maegley
   sudo sh -c 'umask 077; cat > /etc/maegley/slack-token'   # paste, then Ctrl-D
   sudo chmod 600 /etc/maegley/slack-token
   ```
5. `sudo install -o root -g root -m 755 provisioning/notify /usr/local/bin/notify`
6. Add each agent to `/etc/sudoers.d/maegley-notify` (mode `0440`, validate with
   `visudo -c -f`).

## The gotcha that costs the most time

**A bot with a valid token and correct scopes still cannot post to a channel until a human
adds it to that channel — per channel, manually.** There is no API path around it with these
scopes, and it is not obvious from the error.

Worse, `/invite @botname` frequently does nothing if you type the name and press enter: the
app has to be **selected from the autocomplete dropdown**. The reliable path is
channel name → **Integrations** → **Add an App**.

Budget one manual invite for every channel you create.

## Error ladder

Slack's errors name the next missing piece precisely. Read them in this order:

| Error | Meaning |
|---|---|
| `not_authed` | Token missing or empty at `/etc/maegley/slack-token` |
| `invalid_auth` | Token present but wrong or revoked |
| `channel_not_found` | Channel does not exist (or the bot cannot see it at all) |
| `not_in_channel` | Channel exists; **bot is not a member** — invite it |
| `missing_scope` | The call needs a scope the app was not granted |

`notify` checks Slack's `ok` field rather than trusting curl's exit status, so these surface
as failures instead of silent no-ops. A notifier that exits 0 having posted nothing is the
same failure class as a QA tool reporting healthy when it cannot see — see
`skills/definition-of-done`.

## Changing scopes issues a new token

Adding a scope requires reinstalling the app, which **invalidates the current token**. Plan
scope changes as a single batch and re-drop `/etc/maegley/slack-token` afterwards.

## Protocol

Chat is the doorbell; git is the record. Post a pointer to the artifact, never the artifact.
See `CLAUDE.md` §4.
