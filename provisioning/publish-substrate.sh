#!/usr/bin/env bash
# publish-substrate.sh — push agent-os to the local mirror agents pull from.
#
# Run after any change to skills, agent briefs, or the constitution. Without it
# agents keep running the substrate they were provisioned with: before this
# existed they were 4 to 12 commits behind, each stale by a different amount,
# and nobody could tell from the outside.
set -euo pipefail
SRC="${AGENT_OS:-/home/steve/maegley-lab/agent-os}"
git -C "$SRC" push -q --mirror /opt/agent-os.git
chmod -R a+rX /opt/agent-os.git
echo "→ substrate published: $(git -C /opt/agent-os.git rev-parse --short HEAD)"
for a in eric john theresa ken randal andrea; do
  id "$a" >/dev/null 2>&1 || continue
  sudo -n test -d "/home/$a/work/agent-os" || continue
  sudo -u "$a" bash -c "cd /home/$a/work/agent-os && git fetch -q origin && git reset -q --hard origin/main"
  printf '   %-8s %s\n' "$a" "$(sudo -u "$a" bash -c "cd /home/$a/work/agent-os && git rev-parse --short HEAD")"
done
