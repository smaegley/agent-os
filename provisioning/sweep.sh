#!/usr/bin/env bash
# sweep.sh — the daily program sweep.
#
# Facts come from git; the model only writes the prose. Everything the sweep
# needs to KNOW is deterministic (commits, blocked sections, unassigned work,
# file age), so nothing here depends on a model reading markdown correctly.
# The model's whole job is turning a fact block into three readable lines.
#
# THE LOAD-BEARING PROPERTY: when nothing changed, this posts nothing and
# spends no tokens. A digest that arrives on schedule regardless of content
# becomes wallpaper within a week, and then it generates work instead of
# removing it. If you find yourself skimming past it, it has started reporting
# state instead of exceptions — cut what it reports, don't add filters.
#
# Runs as Todd (ops) from cron. Posts under Todd deliberately: the sweep is
# tooling Ops owns, not a colleague. It is not given a name — see CLAUDE.md §6.

set -uo pipefail

# Same reason as dispatch.sh: cron here is UTC and ignores CRON_TZ. The digest
# must land in Steve's morning, not at 00:30 his time.
if [ "${IGNORE_HOURS:-0}" != "1" ]; then
  [ "$(TZ="${WORK_TZ:-America/Denver}" date +%-H%M)" -ge 630 ] || exit 0
  [ "$(TZ="${WORK_TZ:-America/Denver}" date +%-H)" -le 7 ] || exit 0
fi

REPO="${PROGRAM_REPO:-/home/steve/maegley-lab/program}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/maegley"
STATE="$STATE_DIR/sweep-last-sha"
BLOCKED_ESCALATE_DAYS=3
UNASSIGNED_STALE_DAYS=7
DRY_RUN="${DRY_RUN:-0}"

mkdir -p "$STATE_DIR"
cd "$REPO" || { echo "sweep: no repo at $REPO" >&2; exit 1; }

git fetch -q origin 2>/dev/null
git merge -q --ff-only origin/main 2>/dev/null || true

LAST="$(cat "$STATE" 2>/dev/null || true)"
HEAD_SHA="$(git rev-parse HEAD)"
age_days() { echo $(( ( $(date +%s) - $(git log -1 --format=%ct -- "$1") ) / 86400 )); }

FACTS=""; ESCALATIONS=""

# --- 1. what moved since the last sweep -------------------------------------
if [ -n "$LAST" ] && git cat-file -e "$LAST^{commit}" 2>/dev/null; then
  NEW="$(git log --reverse --format='%h|%an|%s' "$LAST..HEAD" 2>/dev/null)"
else
  # First run (or the recorded SHA was rewritten): look back one day rather
  # than replaying the repo's whole history into the first digest.
  NEW="$(git log --reverse --since=1.day --format='%h|%an|%s' 2>/dev/null)"
fi
if [ -n "$NEW" ]; then
  FACTS+=$'COMMITS SINCE LAST SWEEP (oldest first — later entries supersede earlier ones):\n'
  while IFS='|' read -r sha who subj; do
    [ -n "$sha" ] && FACTS+="  $sha  $who — $subj"$'\n'
  done <<< "$NEW"
fi

# --- 2. blocked work, and whether it has been sitting ------------------------
for f in projects/*/status.md; do
  [ -e "$f" ] || continue
  proj="$(basename "$(dirname "$f")")"
  blocked="$(sed -n '/^## Blocked/,/^## /p' "$f" | grep -E '^- ' | grep -v '(none)')"
  [ -n "$blocked" ] || continue
  d="$(age_days "$f")"
  FACTS+="BLOCKED [$proj] (status unchanged ${d}d):"$'\n'
  FACTS+="$(sed 's/^/    /' <<< "$blocked")"$'\n'
  if [ "$d" -ge "$BLOCKED_ESCALATE_DAYS" ]; then
    ESCALATIONS+="  [$proj] blocked and untouched for ${d} days:"$'\n'
    ESCALATIONS+="$(sed 's/^/      /' <<< "$blocked")"$'\n'
  fi
done

# --- 3. work requests nobody has picked up -----------------------------------
for f in $(grep -rl "unassigned" projects/ --include="*.md" 2>/dev/null | grep -v status.md); do
  d="$(age_days "$f")"
  [ "$d" -ge "$UNASSIGNED_STALE_DAYS" ] && \
    FACTS+="UNASSIGNED ${d}d: $f"$'\n'
done

# --- 4. the box the agents run on --------------------------------------------
# Added 2026-08-16 after LXC 301 hit 100% and wedged every agent, the Slack
# wrapper, and this sweep. A platform that cannot notice its own filesystem
# filling is missing something basic. Deterministic — df, not judgement.
DISK_WARN=80; DISK_ESCALATE=90
while read -r pct mnt; do
  [ "$pct" -ge "$DISK_WARN" ] || continue
  FACTS+="DISK ${pct}% used on ${mnt} (codex-ops)"$'\n'
  [ "$pct" -ge "$DISK_ESCALATE" ] && \
    ESCALATIONS+="  codex-ops ${mnt} is ${pct}% full — agents, Slack and this sweep all fail at 100%"$'\n'
done < <(df -P / /home 2>/dev/null | awk 'NR>1 {gsub(/%/,"",$5); print $5, $6}' | sort -u)

# --- 5. the org's own invariants ---------------------------------------------
# Every protection built here was correct and, six separate times, was not
# reaching where the work happened. Each was found by accident. Asserting them
# daily is the difference between a boundary that holds and one that is merely
# believed to hold.
if ! DOC="$("$(dirname "$0")/doctor.sh" 2>&1)"; then
  FACTS+="DOCTOR: invariant failures"$'\n'
  ESCALATIONS+="$(printf '%s' "$DOC" | sed -n '/^FAILURES:/,$p' | tail -n +2)"$'\n'
fi

# --- nothing to say → say nothing -------------------------------------------
if [ -z "$FACTS" ] && [ -z "$ESCALATIONS" ]; then
  echo "$HEAD_SHA" > "$STATE"
  echo "$(date -Iseconds) sweep: quiet, nothing posted" >> "$REPO/log/sweep.log"
  exit 0
fi

# --- digest: model writes prose only, from the facts above -------------------
DIGEST="$(cd "$REPO" && timeout 120 claude -p --model haiku \
"Write a Slack digest of at most 4 short lines from the facts below. Report only what
changed or needs attention — no preamble, no headers, no restating the facts verbatim,
no invented detail. Reference commits by short hash.
Commits are listed oldest-first. Describe the NET EFFECT of the sequence, not individual
commits: if a later commit supersedes an earlier one, report only the later state. Never
describe a superseded state as current, and never call something halted or blocked because a
commit message says so — blocked status comes ONLY from lines beginning "BLOCKED".
If a BLOCKED line exists, lead with it; otherwise lead with the most consequential change.

FACTS:
$FACTS" < /dev/null 2>/dev/null | head -12)"

[ -n "$DIGEST" ] || DIGEST="Sweep ran but the digest step failed. Raw facts:"$'\n'"$FACTS"

if [ "$DRY_RUN" = "1" ]; then
  echo "=== would post to #program ==="; echo "Daily sweep — $DIGEST"
  [ -n "$ESCALATIONS" ] && { echo "=== would post to #ops-prod ==="; echo "$ESCALATIONS"; }
  exit 0
fi

sudo -n /usr/local/bin/notify '#program' "Daily sweep — $DIGEST" >/dev/null

# Escalations go to #ops-prod and name Steve; everything else is FYI.
if [ -n "$ESCALATIONS" ]; then
  sudo -n /usr/local/bin/notify '#ops-prod' \
    "Steve — blocked over ${BLOCKED_ESCALATE_DAYS} days, needs a decision:"$'\n'"$ESCALATIONS" >/dev/null
fi

echo "$HEAD_SHA" > "$STATE"
echo "$(date -Iseconds) sweep: posted (escalations: $([ -n "$ESCALATIONS" ] && echo yes || echo no))" \
  >> "$REPO/log/sweep.log"
