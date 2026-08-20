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
  for r in program ha-ops agent-os slack-bridge proxmox-dashboard; do
    sudo -n test -d "/home/$a/work/$r/.git" || continue
    dirty="$(agent_git "$a" "$r" status --porcelain 2>/dev/null | wc -l)"
    ahead="$(agent_git "$a" "$r" status -sb 2>/dev/null | grep -o 'ahead [0-9]*' || true)"
    [ "$dirty" != 0 ] && bad "$a" "$r has $dirty uncommitted file(s)"
    [ -n "$ahead" ]   && bad "$a" "$r is $ahead — work nobody else can see"
  done
done


# --- the operator is not exempt ------------------------------------------
# Every check above loops over AGENT identities. Todd's own trees were never
# looked at — and on 2026-08-18 it was the operator, not an agent, who left the
# production reply path uncommitted. A doctor that watches only the supervised
# half reports "all invariants hold" while the supervisor is the one adrift.
echo
for t in /home/steve/maegley-lab/program /home/steve/maegley-lab/agent-os \
         /home/steve/work/slack-bridge /home/codex/ha; do
  [ -d "$t/.git" ] || continue
  n="$(basename "$t")"
  dirty="$(git -C "$t" status --porcelain 2>/dev/null | wc -l)"
  ahead="$(git -C "$t" status -sb 2>/dev/null | grep -o 'ahead [0-9]*' || true)"
  [ "$dirty" != 0 ] && bad "todd" "$n has $dirty uncommitted file(s)" || true
  [ -n "$ahead" ]   && bad "todd" "$n is $ahead — work nobody else can see" || true
  { [ "$dirty" = 0 ] && [ -z "$ahead" ]; } && ok "todd" "$n clean and pushed" || true
done

# --- the record mirror must not be behind GitHub -------------------------
# The status-answer path reads /srv/git/program.git and refreshes its clone at
# answer time, but it can only detect a FETCH failure — never that its origin is
# itself stale. A mirror that quietly stops updating yields confidently wrong
# status answers with no error anywhere. Assert freshness here instead.
echo
MIRROR=/srv/git/program.git
if [ -d "$MIRROR" ]; then
  before="$(git --git-dir="$MIRROR" rev-parse main 2>/dev/null || echo none)"
  git --git-dir="$MIRROR" remote update --prune >/dev/null 2>&1
  after="$(git --git-dir="$MIRROR" rev-parse main 2>/dev/null || echo none)"
  if [ "$after" = none ]; then
    bad "mirror" "cannot read $MIRROR — the status answer path has no record"
  elif [ "$before" != "$after" ]; then
    bad "mirror" "record mirror was STALE (was ${before:0:7}, now ${after:0:7}) — status answers were wrong"
  else
    ok "mirror" "record mirror current with GitHub (${after:0:7})"
  fi
fi

# --- what RUNS must exist in the record ----------------------------------
# The check that would have caught the slack-bridge relay. A dirty-tree check
# cannot: those files live outside every working tree, so git status is clean
# and honest while production is unrecorded. Compare the running bytes against
# the committed bytes instead — the only question that actually matters.
echo
MANIFEST="$HERE/deployed-artifacts.tsv"
declare -A RECORD=( [agent-os]=/opt/agent-os.git \
                    [slack-bridge]=/srv/git/slack-bridge.git \
                    [proxmox-dashboard]=/srv/git/proxmox-dashboard.git )
if [ ! -f "$MANIFEST" ]; then
  bad "deploy" "no deployed-artifacts.tsv — nothing asserts that what runs is recorded"
else
  while IFS=$'\t' read -r hostpath key repopath; do
    case "${hostpath:-}" in ''|\#*) continue ;; esac
    [ -n "${repopath:-}" ] || { bad "deploy" "malformed manifest line: $hostpath"; continue; }
    gd="${RECORD[$key]:-}"
    [ -n "$gd" ] || { bad "deploy" "$hostpath names unknown repo key '$key'"; continue; }
    sudo -n test -e "$hostpath" 2>/dev/null || { ok "deploy" "$(basename "$hostpath") not installed here"; continue; }
    live="$(sudo -n sha256sum "$hostpath" 2>/dev/null | cut -d" " -f1)"
    rec="$(git --git-dir="$gd" show "HEAD:$repopath" 2>/dev/null | sha256sum | cut -d" " -f1)"
    if [ -z "$rec" ] || ! git --git-dir="$gd" cat-file -e "HEAD:$repopath" 2>/dev/null; then
      bad "deploy" "$hostpath RUNS BUT IS IN NO REPO ($key:$repopath missing) — nothing to inspect"
    elif [ "$live" = "$rec" ]; then
      ok "deploy" "$(basename "$hostpath") matches $key:$repopath"
    else
      bad "deploy" "$hostpath DIFFERS from $key:$repopath — host and record disagree"
    fi
  done < "$MANIFEST"
fi

echo
if [ "$FAIL" = 0 ]; then
  echo "all invariants hold"
else
  echo "FAILURES:"; printf '%s' "$REPORT"
fi
exit "$FAIL"
