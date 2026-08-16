#!/usr/bin/env bash
# install-agent-key.sh <agent> <root@host> <forced-command-script>
#
# Provisions one agent identity on one host: a dedicated unprivileged user, the
# forced-command wrapper, and the agent's public key locked to it.
#
# Idempotent. Run from Todd (LXC 301), which holds the private halves.
#
# The restrictions below are the ones that make the identity real. `restrict`
# disables forwarding, pty, and everything else by default; the command= means the
# key cannot run anything but the wrapper regardless of what is requested.

set -euo pipefail

AGENT="${1:?usage: install-agent-key.sh <agent> <root@host> <script>}"
HOST="${2:?}"
SCRIPT="${3:?}"
KEYDIR="${AGENT_KEYDIR:-/home/steve/.config/ops/agent-keys}"
PUB="$KEYDIR/$AGENT.pub"
REMOTE_SCRIPT="/usr/local/sbin/$(basename "$SCRIPT")"

[ -r "$PUB" ]    || { echo "no public key: $PUB" >&2; exit 1; }
[ -r "$SCRIPT" ] || { echo "no script: $SCRIPT" >&2; exit 1; }

echo "→ $AGENT @ $HOST"

scp -q -i ~/.ssh/proxmox_lxc -o StrictHostKeyChecking=no "$SCRIPT" "$HOST:$REMOTE_SCRIPT"

ssh -i ~/.ssh/proxmox_lxc -o StrictHostKeyChecking=no "$HOST" \
    "AGENT='$AGENT' REMOTE_SCRIPT='$REMOTE_SCRIPT' PUBKEY='$(cat "$PUB")' bash -s" <<'REMOTE'
set -euo pipefail
chmod 755 "$REMOTE_SCRIPT"; chown root:root "$REMOTE_SCRIPT"

id "$AGENT" >/dev/null 2>&1 || useradd -m -s /bin/bash "$AGENT"
install -d -m 700 -o "$AGENT" -g "$AGENT" "/home/$AGENT/.ssh"

AK="/home/$AGENT/.ssh/authorized_keys"
LINE="command=\"$REMOTE_SCRIPT\",no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-pty,restrict $PUBKEY"

touch "$AK"
KEYBODY=$(echo "$PUBKEY" | awk '{print $2}')
grep -qF "$KEYBODY" "$AK" && sed -i "\|$KEYBODY|d" "$AK"   # replace, never duplicate
echo "$LINE" >> "$AK"
chmod 600 "$AK"; chown "$AGENT:$AGENT" "$AK"

# git refuses to operate on a root-owned repo as another user ("dubious ownership"),
# which silently blanks every git-based check. Mark the inspected repo safe for this
# agent — read-only; it grants no filesystem access the user did not already have.
if [ -r /etc/maegley-qa.conf ]; then
  . /etc/maegley-qa.conf
  [ -n "${QA_REPO:-}" ] && su -s /bin/bash "$AGENT" -c \
    "git config --global --replace-all safe.directory '$QA_REPO'" 2>/dev/null || true
fi

echo "   user=$(id -un "$AGENT") uid=$(id -u "$AGENT") script=$REMOTE_SCRIPT keys=$(wc -l < "$AK")"
REMOTE

echo "   ok"
