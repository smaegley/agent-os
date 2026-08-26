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
# Use the roster, not a second hardcoded list. Todd was provisioned 2026-08-21
# and this line would have quietly excluded him from every substrate publish --
# he would run whatever skills existed the day he was created, forever, while
# doctor reported him "substrate current" only because it never checked him
# either (the roster parser was broken the same way). Two hardcoded lists, one
# roster, and the roster was the thing nobody read.
. "$(dirname "$0")/lib-agent.sh"
for a in $(agent_list); do
  id "$a" >/dev/null 2>&1 || continue
  sudo -n test -d "/home/$a/work/agent-os" || continue
  sudo -u "$a" bash -c "cd /home/$a/work/agent-os && git fetch -q origin"
  # NEVER reset over an agent's own commits. Until 2026-08-19 agents were denied
  # all writes to agent-os, so `reset --hard` here could not destroy anything.
  # The boundary was then narrowed to let them build the org's tooling — and this
  # line silently orphaned Randal's WR-009 dispatcher commit within the hour. The
  # object survived only because git had not gc'd it yet.
  ahead="$(sudo -u "$a" bash -c "cd /home/$a/work/agent-os && git rev-list --count origin/main..HEAD 2>/dev/null" || echo 0)"
  if [ "${ahead:-0}" -gt 0 ]; then
    printf '   %-8s %s  ⚠ HELD — %s local commit(s) not on origin; NOT reset. Merge them first.\n' \
      "$a" "$(sudo -u "$a" bash -c "cd /home/$a/work/agent-os && git rev-parse --short HEAD")" "$ahead"
    continue
  fi
  sudo -u "$a" bash -c "cd /home/$a/work/agent-os && git reset -q --hard origin/main"
  printf '   %-8s %s\n' "$a" "$(sudo -u "$a" bash -c "cd /home/$a/work/agent-os && git rev-parse --short HEAD")"
done

# ---------------------------------------------------------------------------
# Restart the long-running dispatcher if the code it LOADED has since moved.
#
# WHY THIS EXISTS: publishing updated every agent's clone and the mirror, and
# restarted nothing -- so the one long-running consumer of this code kept running
# whatever it loaded at start. It bit twice on 2026-08-26: the watcher ran
# 3-day-old code through the WR-009 cutover, then ran pre-WR-014 code while 44
# real credit exhaustions produced no hold, because the fix for exactly that was
# published 31 minutes after the process started. A published fix that no running
# process has loaded is indistinguishable from no fix at all.
#
# Scope is deliberately ONE unit. Every other consumer is a oneshot/.path runner
# that re-execs per trigger and cannot go stale; slack-bridge is its own repo and
# `deploy` already restarts units whose artifacts changed.
WATCH_UNIT=maegley-dispatch-watch.service
if systemctl is-active --quiet "$WATCH_UNIT" 2>/dev/null; then
  started="$(date -d "$(systemctl show "$WATCH_UNIT" -p ActiveEnterTimestamp --value)" +%s 2>/dev/null || echo 0)"
  newest=0
  for f in "$SRC/provisioning/watch-dispatch.sh" "$SRC/provisioning/lib-dispatch.sh"; do
    [ -f "$f" ] || continue
    m="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
    [ "$m" -gt "$newest" ] && newest="$m"
  done
  if [ "$newest" -gt "$started" ]; then
    if sudo -n systemctl restart "$WATCH_UNIT" 2>/dev/null; then
      echo "   watcher  RESTARTED — it was running code older than this publish"
    else
      echo "   watcher  ! STALE and could not be restarted — it is running code older than this publish" >&2
    fi
  else
    echo "   watcher  current"
  fi
fi
