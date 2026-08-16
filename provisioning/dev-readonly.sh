#!/bin/bash
# Read-only prod inspection for the photo-project DEV agent (on VM 201).
#
# Invoked as a FORCED COMMAND from /home/devread/.ssh/authorized_keys, so the dev
# never gets a shell here — it can only run the subcommands allowlisted below.
# Nothing in this script reads or prints file CONTENTS, so it cannot be used to
# exfiltrate .env, tokens, or the DB regardless of filesystem permissions.
#
# Why this exists: the dev agent has no view of prod and was reasoning about it by
# inference, which produced confidently wrong claims (e.g. "prod is at 4f0a06d" when
# it was 10 commits behind at 82166b3, and a git-pull conflict warning for a conflict
# that did not exist). Letting it look is cheaper than relaying.
set -uo pipefail

REPO=/opt/photo-project
REQ="${SSH_ORIGINAL_COMMAND:-help}"
set -- $REQ
CMD="${1:-help}"
ARG="${2:-}"

# Clamp any numeric argument — never interpolate raw input into a command.
num() {
  local n="${1:-}" def="$2" max="$3"
  [[ "$n" =~ ^[0-9]+$ ]] || n="$def"
  (( n > max )) && n="$max"
  (( n < 1 )) && n="$def"
  echo "$n"
}

case "$CMD" in
  state)
    echo "prod HEAD       : $(git -C $REPO log -1 --format='%h %s')"
    echo "origin/main     : $(git -C $REPO log -1 --format='%h %s' origin/main)"
    echo "ahead of origin : $(git -C $REPO rev-list --count origin/main..HEAD)"
    echo "behind origin   : $(git -C $REPO rev-list --count HEAD..origin/main)"
    if [ -f "$REPO/.git/FETCH_HEAD" ]; then
      echo "origin refs as of: $(date -r "$REPO/.git/FETCH_HEAD" '+%Y-%m-%d %H:%M:%S %Z')"
      echo "  (this box cannot fetch — the deploy key is root-only. Ask ops to refresh"
      echo "   if that timestamp is stale before trusting the ahead/behind counts.)"
    fi
    ;;
  status)
    echo "=== git status --short (empty = clean) ==="
    git -C $REPO status --short
    ;;
  log)
    git -C $REPO log --oneline -"$(num "$ARG" 10 100)"
    ;;
  diff-stat)
    echo "=== uncommitted changes to tracked files (empty = none) ==="
    git -C $REPO diff --stat
    ;;
  units)
    for u in photo-backup.timer photo-backup.service; do
      # is-failed echoes the ACTIVE state when a unit is healthy, which reads as
      # "failed=active". Normalise to yes/no so the output can't be misread.
      f=$(systemctl is-failed "$u" 2>&1); [ "$f" = failed ] || f=no
      printf '%-28s active=%-10s failed=%s\n' "$u" "$(systemctl is-active "$u" 2>&1)" "$f"
    done
    echo
    systemctl list-timers photo-backup.timer --no-pager 2>/dev/null | head -3
    ;;
  journal)
    journalctl -u photo-backup.service -n "$(num "$ARG" 30 200)" --no-pager -o short-iso
    ;;
  snapshots)
    echo "=== local snapshots (newest last) ==="
    ls -la $REPO/snapshots/ 2>/dev/null | tail -20
    echo
    echo "Off-site copies live in B2 (maegley-apps-offsite/photo-album/db, 90d)."
    echo "Listing them needs the bucket credentials, which are root-only — ask ops."
    ;;
  help|*)
    cat <<'EOF'
Read-only prod inspection (LXC 209, photo-album). Usage:

  ssh devread@10.0.1.178 <command>

  state          HEAD, origin/main, ahead/behind counts, origin-refs freshness
  status         git status --short
  log [N]        git log --oneline -N        (default 10, max 100)
  diff-stat      uncommitted changes to tracked files
  units          photo-backup timer/service active + failed state, next run
  journal [N]    last N journal lines for photo-backup.service (default 30, max 200)
  snapshots      local snapshot inventory
  help           this text

Read-only by construction: no shell, no file contents, no writes. If you need
something outside this list, ask the ops agent rather than inferring it.
EOF
    ;;
esac
