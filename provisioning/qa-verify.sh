#!/bin/bash
# Read-only production verification for Eric (QA).
#
# Invoked as a FORCED COMMAND from ~eric/.ssh/authorized_keys, so Eric never gets a
# shell — only the verbs allowlisted below.
#
# WHY THIS IS NOT devread: Randal (DEV) already has read-only prod access via
# prod-readonly.sh. Eric deliberately gets a SEPARATE key and a SEPARATE command set,
# because verification that runs through the claimant's own access path verifies
# nothing. Eric's verbs answer "is what was claimed actually true in production?" —
# what is deployed, is it running, did it actually do something, and when.
#
# Config per host: /etc/maegley-qa.conf  (QA_REPO=..., QA_UNITS="a.service b.timer",
#                                         QA_URL=..., QA_PATHS="/var/lib/foo")
set -uo pipefail

CONF=/etc/maegley-qa.conf
[ -r "$CONF" ] && . "$CONF"
QA_REPO="${QA_REPO:-}"; QA_UNITS="${QA_UNITS:-}"; QA_URL="${QA_URL:-}"; QA_PATHS="${QA_PATHS:-}"

REQ="${SSH_ORIGINAL_COMMAND:-help}"
set -- $REQ
CMD="${1:-help}"; ARG="${2:-}"

# Clamp numeric input — never interpolate raw argument into a command.
num() { local n="${1:-}" d="$2" m="$3"; [[ "$n" =~ ^[0-9]+$ ]] || n="$d";
        (( n > m )) && n="$m"; (( n < 1 )) && n="$d"; echo "$n"; }

# Log output is the one place content can escape. Redact anything credential-shaped
# before it leaves the host — same patterns as the secret-scan gate.
redact() {
  sed -E -e 's/eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/<JWT-REDACTED>/g' \
         -e 's/(PVEAPIToken=)[^ ]+/\1<REDACTED>/g' \
         -e 's/(gh[pousr]_|github_pat_)[A-Za-z0-9_]+/<TOKEN-REDACTED>/g' \
         -e 's/([Pp]assword|PASSWORD|[Ss]ecret|[Tt]oken|api[_-]?key)([":= ]+)[^ ",;]{8,}/\1\2<REDACTED>/g' \
         -e 's/AKIA[0-9A-Z]{16}/<AWS-KEY-REDACTED>/g'
}

case "$CMD" in
  deployed)
    echo "host            : $(hostname)"
    if [ -n "$QA_REPO" ]; then
      # NEVER report "clean" from a failed check. Swallowing git's exit status here
      # made a permissions error render as a clean working tree — a QA tool that
      # reports healthy when it cannot see anything is worse than no tool at all.
      if ! err=$(git -C "$QA_REPO" rev-parse --git-dir 2>&1 >/dev/null); then
        echo "deployed commit : UNKNOWN"
        echo "working tree    : UNKNOWN — git failed: ${err%%$'\n'*}"
        exit 1
      fi
      echo "deployed commit : $(git -C "$QA_REPO" log -1 --format='%h %s')"
      echo "committed at    : $(git -C "$QA_REPO" log -1 --format='%ci')"
      if ! st=$(git -C "$QA_REPO" status --porcelain 2>&1); then
        echo "working tree    : UNKNOWN — status failed: ${st%%$'\n'*}"
      elif [ -z "$st" ]; then
        echo "working tree    : clean"
      else
        echo "working tree    : DIRTY — prod differs from any commit ($(echo "$st" | wc -l) files)"
      fi
    fi
    ;;
  health)
    for u in $QA_UNITS; do
      f=$(systemctl is-failed "$u" 2>&1); [ "$f" = failed ] || f=no
      printf '%-30s active=%-10s failed=%-4s since=%s\n' "$u" \
        "$(systemctl is-active "$u" 2>&1)" "$f" \
        "$(systemctl show "$u" -p ActiveEnterTimestamp --value 2>/dev/null)"
    done
    ;;
  evidence)
    # Did it actually DO something, or merely exit 0? Content is redacted on the way out.
    u="${ARG:-}"; case " $QA_UNITS " in *" $u "*) ;; *) echo "unit not allowlisted: $u"; exit 1;; esac
    journalctl -u "$u" -n "$(num "${3:-}" 40 200)" --no-pager 2>&1 | redact
    ;;
  freshness)
    # Guards against silent success — a job that runs clean having processed nothing,
    # or a value frozen at something plausible. Timestamps, never contents.
    for p in $QA_PATHS; do
      if [ -e "$p" ]; then
        printf '%-46s mtime=%s age=%sh\n' "$p" "$(date -r "$p" '+%Y-%m-%d %H:%M')" \
          "$(( ( $(date +%s) - $(date -r "$p" +%s) ) / 3600 ))"
      else
        printf '%-46s MISSING\n' "$p"
      fi
    done
    ;;
  endpoint)
    [ -n "$QA_URL" ] || { echo "no QA_URL configured"; exit 1; }
    curl -s -o /dev/null -w "%{http_code} in %{time_total}s\n" --max-time 10 "$QA_URL"
    ;;
  capacity)
    df -h / "$QA_REPO" 2>/dev/null | awk 'NR==1 || NF>3'
    ;;
  help|*)
    cat <<'EOF'
Eric (QA) — read-only production verification. Verbs:
  deployed          what commit is actually live, and whether the tree is dirty
  health            allowlisted units: active / failed / running since when
  evidence <unit> [n]   recent journal lines, credential-redacted (default 40, max 200)
  freshness         mtime + age of key artifacts — catches jobs that "succeed" doing nothing
  endpoint          HTTP status and latency of the app's health URL
  capacity          disk headroom
No shell. No file contents. Nothing here can modify prod.
EOF
    ;;
esac
