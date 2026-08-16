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

1. `useradd -m -s /bin/bash <agent>`; `chmod 750 /home/<agent>`
2. Install the prod-read key from `~steve/.config/ops/agent-keys/<agent>` as
   `~<agent>/.ssh/id_ed25519`
3. Generate a **separate** GitHub key, `~<agent>/.ssh/github_<agent>`, and pin it in
   `~<agent>/.ssh/config`. One key per trust domain — the prod key and the repo key must
   never be the same key.
4. Provide `work/agent-os` and `work/program`. Ultimately clones from GitHub via the agent's
   deploy key; a local clone from Todd works to bootstrap.
5. `claude plugin marketplace add ~<agent>/work/agent-os` then
   `claude plugin install maegley-core@maegley-lab --scope user`
6. `claude login` **as that user** — see below.
7. Set `git config user.name/user.email` in the work repos so commits are attributable.

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

## Gotchas hit while doing this

- **Agents cannot read Todd's home** (correct), so `claude plugin marketplace add
  /home/steve/maegley-lab/agent-os` fails with EACCES. The substrate has to be somewhere the
  agent can actually read — its own clone, or a shared world-readable path.
- **`git` refuses root-owned repos as another user** ("dubious ownership"), which silently
  blanks git-based checks rather than erroring visibly. Set `safe.directory` per agent.
- `/usr/bin/claude` is the npm-global install and is readable by all users;
  `~steve/.local/bin/claude` is not. Agents get the former, which may lag in version.
