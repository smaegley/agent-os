#!/usr/bin/env bash
# doctor.sh — assert every invariant the agent org depends on, for every agent.
#
# WHY: six times in one day a protection was correct but was not reaching where
# the work happened — a key installed but not permitted; a permission pattern
# that did not match the command; a secret gate absent from every agent's clone;
# QA verbs pointed at a port nothing listens on; git patterns that missed
# `git -C`; and a substrate no agent could pull, leaving each frozen 4 to 12
# commits behind. Every one was found by accident, and each looked healthy from
# outside until someone happened to look.
#
# None of those were subtle once checked. They were simply never checked. That
# is what this fixes: the invariants are asserted on a schedule instead of being
# rediscovered when something breaks.
#
# Exits non-zero if any check fails, so the sweep can escalate.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib-agent.sh"

MIRROR=/opt/agent-os.git
FAIL=0; REPORT=""
ok()   { printf '  ✓ %-8s %s\n' "$1" "$2"; }
bad()  { printf '  ✗ %-8s %s\n' "$1" "$2"; REPORT+="  $1: $2"$'\n'; FAIL=1; }

echo "agent org doctor — $(date '+%Y-%m-%d %H:%M')"

SUBSTRATE_HEAD="$(git -C "$MIRROR" rev-parse HEAD 2>/dev/null || echo unknown)"
[ "$SUBSTRATE_HEAD" = unknown ] && bad "mirror" "no substrate mirror at $MIRROR"

for a in $(agent_list); do
  # --- identity ------------------------------------------------------------
  sudo -n test -f "/home/$a/.claude/.credentials.json" \
    && ok "$a" "authenticated" || bad "$a" "not authenticated — cannot be dispatched"

  # --- the boundary itself, re-asserted rather than assumed ----------------
  sudo -n -u "$a" ls /home/steve/.ssh/ >/dev/null 2>&1 \
    && bad "$a" "CAN READ OPS KEYS — boundary broken" || ok "$a" "cannot read ops keys"
  sudo -n -u "$a" sudo -n true >/dev/null 2>&1 \
    && bad "$a" "HAS SUDO — boundary broken" || ok "$a" "no sudo"

  # --- protections must be where the work happens, not merely to exist -----
  for r in program ha-ops; do
    sudo -n test -d "/home/$a/work/$r/.git" || continue
    sudo -n test -f "/home/$a/work/$r/.git/hooks/pre-commit" \
      && ok "$a" "secret gate in $r" || bad "$a" "NO secret gate in $r — commits unscanned"
  done

  # --- substrate currency: stale rules are followed just as confidently ----
  if sudo -n test -d "/home/$a/work/agent-os/.git"; then
    h="$(agent_git "$a" agent-os rev-parse HEAD 2>/dev/null)"
    if [ "$h" = "$SUBSTRATE_HEAD" ]; then ok "$a" "substrate current"
    else
      n="$(git -C "$MIRROR" rev-list --count "$h"..HEAD 2>/dev/null || echo '?')"
      bad "$a" "substrate $n commits stale — running outdated skills"
    fi
  else
    bad "$a" "no agent-os clone — has no skills at all"
  fi

  # --- unpushed work is invisible work -------------------------------------
  for r in program ha-ops agent-os; do
    sudo -n test -d "/home/$a/work/$r/.git" || continue
    dirty="$(agent_git "$a" "$r" status --porcelain 2>/dev/null | wc -l)"
    ahead="$(agent_git "$a" "$r" status -sb 2>/dev/null | grep -o 'ahead [0-9]*' || true)"
    [ "$dirty" != 0 ] && bad "$a" "$r has $dirty uncommitted file(s)"
    [ -n "$ahead" ]   && bad "$a" "$r is $ahead — work nobody else can see"
  done
done

echo
if [ "$FAIL" = 0 ]; then
  echo "all invariants hold"
else
  echo "FAILURES:"; printf '%s' "$REPORT"
fi
exit "$FAIL"
