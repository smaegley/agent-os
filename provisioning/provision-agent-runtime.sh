#!/usr/bin/env bash
# provision-agent-runtime.sh <agent> <prod-host-ip>
#
# The RUNTIME half of standing up an agent (the target-host half is
# install-agent-key.sh). Creates the Unix user, installs its keys, generates a
# fixed-host access wrapper, and writes the permission settings that let the
# agent actually USE what it was given.
#
# Every step here was a gap hit by hand while provisioning Eric on 2026-08-16.
# The two that cost the most:
#
#   1. A key installed but not permitted in the agent's own settings.json is a
#      credential the agent cannot use. It fails as "requires approval" with no
#      hint that the permission layer — not the credential — is the problem.
#   2. A permission pattern matching a raw `ssh user@host *` breaks the moment
#      the model varies its ssh flags, producing intermittent false blocks.
#      Hence the wrapper: it fixes host and flags so the command string is
#      stable and the permission rule can match it exactly. The wrapper grants
#      nothing extra — the host-side forced command is still the real boundary.
#
# Run as a user with sudo, on the host where the agent's sessions will run.

set -euo pipefail

AGENT="${1:?usage: provision-agent-runtime.sh <agent> <prod-host-ip>}"
PROD_HOST="${2:?}"
KEYDIR="${AGENT_KEYDIR:-/home/steve/.config/ops/agent-keys}"
SUBSTRATE="${AGENT_OS:-/home/steve/maegley-lab/agent-os}"
STATE="${PROGRAM_REPO:-/home/steve/maegley-lab/program}"

# Theresa (BA) and Andrea (UAT) have no prod key BY DESIGN — see AGENTS.md.
# A missing key is a valid configuration for those roles, not an error.
PROD_ACCESS=1
[ -r "$KEYDIR/$AGENT" ] || { PROD_ACCESS=0; echo "   note: no prod key for $AGENT — provisioning without prod access"; }

echo "→ provisioning runtime for $AGENT"

# --- user -------------------------------------------------------------------
id "$AGENT" >/dev/null 2>&1 || sudo useradd -m -s /bin/bash "$AGENT"
sudo chmod 750 "/home/$AGENT"                 # not world-readable
sudo install -d -m 700 -o "$AGENT" -g "$AGENT" "/home/$AGENT/.ssh"

# --- keys: one per trust domain, never shared -------------------------------
if [ "$PROD_ACCESS" = 1 ]; then
  sudo install -m 600 -o "$AGENT" -g "$AGENT" "$KEYDIR/$AGENT"     "/home/$AGENT/.ssh/id_ed25519"
  sudo install -m 644 -o "$AGENT" -g "$AGENT" "$KEYDIR/$AGENT.pub" "/home/$AGENT/.ssh/id_ed25519.pub"
fi
sudo -u "$AGENT" test -f "/home/$AGENT/.ssh/github_$AGENT" || \
  sudo -u "$AGENT" ssh-keygen -t ed25519 -f "/home/$AGENT/.ssh/github_$AGENT" -N "" -q \
       -C "$AGENT@maegley-lab (repo write)"
sudo -u "$AGENT" tee "/home/$AGENT/.ssh/config" >/dev/null <<EOF
Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/github_$AGENT
    IdentitiesOnly yes
EOF
sudo -u "$AGENT" chmod 600 "/home/$AGENT/.ssh/config"

# --- fixed-host access wrapper ----------------------------------------------
sudo -u "$AGENT" install -d -m 755 "/home/$AGENT/bin"
sudo -u "$AGENT" tee "/home/$AGENT/bin/prod" >/dev/null <<EOF
#!/usr/bin/env bash
# $AGENT's read-only production access.
# Host and ssh flags are fixed so the command string stays stable — a narrow
# permission rule can then match it exactly instead of breaking on flag drift.
# Grants nothing beyond the bare ssh call: the host runs a forced command.
exec ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \\
     $AGENT@$PROD_HOST "\$@"
EOF
sudo -u "$AGENT" chmod 755 "/home/$AGENT/bin/prod"

# --- workspace --------------------------------------------------------------
sudo -u "$AGENT" install -d -m 755 "/home/$AGENT/work"
for repo in agent-os program; do
  src="$SUBSTRATE"; [ "$repo" = program ] && src="$STATE"
  if [ ! -d "/home/$AGENT/work/$repo" ]; then
    git clone -q "$src" "/tmp/_seed_$repo"
    sudo cp -rT "/tmp/_seed_$repo" "/home/$AGENT/work/$repo"
    sudo chown -R "$AGENT:$AGENT" "/home/$AGENT/work/$repo"
    rm -rf "/tmp/_seed_$repo"
    if [ "$repo" = agent-os ]; then
      # Agents pull the substrate from a local bare mirror, not GitHub. Deploy
      # keys are per-repo and agents hold one for `program`; minting a second
      # read-only key per agent just to receive skill updates is pure overhead.
      # Without this the clone is frozen at provisioning time and the agent runs
      # whatever skills existed that day — which is exactly what happened.
      sudo -u "$AGENT" git -C "/home/$AGENT/work/$repo" remote set-url origin /opt/agent-os.git
      sudo -u "$AGENT" bash -c "cd /tmp && git config --global --add safe.directory /opt/agent-os.git"
    else
      sudo -u "$AGENT" git -C "/home/$AGENT/work/$repo" \
           remote set-url origin "git@github.com:smaegley/$repo.git"
    fi
  fi
done
sudo -u "$AGENT" git -C "/home/$AGENT/work/program" config user.name  "$(tr a-z A-Z <<<"${AGENT:0:1}")${AGENT:1}"
sudo -u "$AGENT" git -C "/home/$AGENT/work/program" config user.email "$AGENT@maegley-lab.local"

# --- plugin + permissions ---------------------------------------------------
# Without this block the agent holds working credentials it is not allowed to
# invoke — the single most confusing failure mode in the whole setup.
sudo -u "$AGENT" bash -lc "cd /home/$AGENT/work/program && \
  claude plugin marketplace add /home/$AGENT/work/agent-os >/dev/null 2>&1; \
  claude plugin install maegley-core@maegley-lab --scope user >/dev/null 2>&1" || true

sudo -u "$AGENT" env AGENT="$AGENT" python3 - <<'PY'
import json, os, pathlib
agent = os.environ['AGENT']
p = pathlib.Path(f'/home/{agent}/.claude/settings.json')
s = json.loads(p.read_text()) if p.exists() else {}
s['permissions'] = {
    "allow": [
        f"Write(//home/{agent}/work/program/**)",
        f"Edit(//home/{agent}/work/program/**)",
        f"Bash(/home/{agent}/bin/prod *)",
        # Not per-subcommand: `git -C <dir> <sub>` does not match `git add *`,
        # and agents working across two repos use -C constantly. Real reach is
        # bounded by filesystem permissions and deploy keys, not by this pattern.
        "Bash(git *)",
    ],
    "deny": [
        "Bash(sudo *)",
        f"Write(//home/{agent}/work/agent-os/**)",
        f"Edit(//home/{agent}/work/agent-os/**)",
    ],
}
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text(json.dumps(s, indent=2))
PY

# --- secret gate in the agent's OWN clone ------------------------------------
# Installing it only in Todd's repos left every agent committing unscanned —
# the protection existed but not where the commits happen. Point the hook at
# the agent's own copy of the scanner; it cannot read Todd's.
sudo -u "$AGENT" bash -lc \
  "/home/$AGENT/work/agent-os/plugins/maegley-core/hooks/install-git-hooks.sh /home/$AGENT/work/program" \
  >/dev/null 2>&1 || echo "   ! secret gate install failed for $AGENT"

# --- verify the boundary, don't assume it -----------------------------------
echo "   verifying:"
sudo -u "$AGENT" ls /home/steve/.ssh/ >/dev/null 2>&1 \
  && { echo "   FAIL: $AGENT can read Todd's keys"; exit 1; } || echo "     ✓ cannot read ops keys"
sudo -u "$AGENT" sudo -n true >/dev/null 2>&1 \
  && { echo "   FAIL: $AGENT has sudo"; exit 1; } || echo "     ✓ no sudo"
sudo -u "$AGENT" test -f "/home/$AGENT/work/program/.git/hooks/pre-commit" \
  && echo "     ✓ secret gate installed" || echo "   FAIL: no secret gate — commits unscanned"
sudo -u "$AGENT" "/home/$AGENT/bin/prod" help >/dev/null 2>&1 \
  && echo "     ✓ prod wrapper reaches host" || echo "     ! prod wrapper failed (run install-agent-key.sh on $PROD_HOST first)"

cat <<EOF

   Remaining manual step — cannot be scripted:
     sudo -i -u $AGENT
     claude auth login --claudeai      # then: claude auth status  → loggedIn: true

   And add this deploy key to the program repo (write access):
$(sudo cat "/home/$AGENT/.ssh/github_$AGENT.pub" | sed 's/^/     /')
EOF
