# Standing up an agent runtime

How a named identity from `AGENTS.md` becomes something that actually runs. Eric was the
first; this is what it took.

## The shape

One **Unix user per agent**, on a host Todd can reach. That is where the boundary is real:
filesystem permissions, not the `tools:` field in an agent definition.

```
/home/<agent>/
  .ssh/id_ed25519      prod-read identity (forced command on the target host)
  .ssh/github_<agent>  repo write identity — deliberately a different key
  .ssh/config          pins github.com to the agent's own key, IdentitiesOnly yes
  work/agent-os/       the substrate (marketplace source)
  work/program/        the state repo the agent commits into
```

No sudo. Home mode 750. The agent must not be able to read Todd's `/home/steve/.ssh`.

## Verify the boundary — do not assume it

These are the checks that matter, run as the agent:

```bash
sudo -u <agent> ls /home/steve/.ssh/     # must be: Permission denied
sudo -u <agent> sudo -n true             # must be: a password is required
sudo -u <agent> ssh <agent>@<prod> deployed          # allowlisted verb works
sudo -u <agent> ssh <agent>@<prod> "cat /path/.env"  # must NOT execute
```

## Steps

Both halves are scripted. Run them in this order:

```bash
# 1. Target host — user, forced command, key (run from Todd)
agent-os/provisioning/install-agent-key.sh <agent> root@<prod-host> \
    agent-os/provisioning/qa-verify.sh

# 2. Runtime host — user, keys, wrapper, workspace, plugin, PERMISSIONS
agent-os/provisioning/provision-agent-runtime.sh <agent> <prod-host-ip>
```

Then the two manual steps the scripts print at the end: `claude auth login` as that user,
and adding the printed deploy key to the `program` repo with **write** access.

## The two gaps that cost the most time

Both were hit provisioning Eric, and both are now handled by
`provision-agent-runtime.sh` — but understand them, because they recur anywhere an agent
is given a credential.

**1. A credential the agent is not permitted to invoke is not a credential.** Eric had a
working key and a working forced command, and every call still failed as *"requires
approval"* — nothing indicated the permission layer, rather than the credential, was the
problem. The agent's own `settings.json` must allow the calls. Provisioning is not done
when the key works; it is done when the agent can use the key.

**2. Permission patterns break on flag drift.** `Bash(ssh <agent>@<host> *)` matches only
commands beginning with exactly that string. The moment the model adds `-o
StrictHostKeyChecking=no`, the rule stops matching and the call is blocked — intermittently,
depending on how the model happens to phrase it that run.

The fix for (2) is the **wrapper**: `~<agent>/bin/prod` hard-codes the host and the ssh
flags, so the invoked string is stable and a narrow rule matches it exactly. It grants
nothing extra — the host-side forced command remains the real boundary. This generalizes:
any outbound capability an agent needs should be a fixed-argument wrapper, not a raw
command the model composes freshly each time.

The wrapper has a second benefit worth naming. Because the *host* enforces the restriction,
the client-side permission rule does not have to be clever — which means a narrow,
auditable rule is sufficient. Client-side permissions are ergonomics; credentials are
security. Do not confuse the two.

## The authentication constraint — read this before scaling

Claude Code authenticates **per Unix user**, via OAuth stored in
`~/.claude/.credentials.json`. There is no way to provision it non-interactively: someone must
run `claude login` as each agent and complete a browser flow.

Two consequences worth being honest about:

- **Adding an agent is not fully automatable.** Every new identity costs one manual login.
- **These are not separate Anthropic identities.** All agents authenticate as Steve's account.
  The separation that is real — and that this design actually delivers — is at the OS and
  credential layer: what each agent can reach, not who the model thinks it is. Do not describe
  the roster as providing account-level isolation, because it does not.

The alternative is `ANTHROPIC_API_KEY` per agent, which is scriptable and gives genuinely
separate API identities, but bills separately from the subscription. Not currently used.

## Describe tools by pointing at them, not by listing them

Eric's first pass reported that none of its verbs could observe a dirty working tree — an
inference from the verb names in its prompt. Once told to run `prod help` first, it read the
actual interface, found that `deployed` does report tree state, and corrected itself.

Give an agent the entry point and let it read `help`. A verb list in a prompt is a copy that
drifts from the tool the moment the tool changes.

## Gotchas hit while doing this

- **Agents cannot read Todd's home** (correct), so `claude plugin marketplace add
  /home/steve/maegley-lab/agent-os` fails with EACCES. The substrate has to be somewhere the
  agent can actually read — its own clone, or a shared world-readable path.
- **`git` refuses root-owned repos as another user** ("dubious ownership"), which silently
  blanks git-based checks rather than erroring visibly. Set `safe.directory` per agent.
- `/usr/bin/claude` is the npm-global install and is readable by all users;
  `~steve/.local/bin/claude` is not. Agents get the former, which may lag in version.
