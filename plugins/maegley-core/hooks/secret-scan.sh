#!/usr/bin/env bash
# secret-scan.sh — block credentials from entering git.
#
# Install into a repo:   agent-os/plugins/maegley-core/hooks/install-git-hooks.sh <repo>
# Run manually:          secret-scan.sh --staged | --files <path>...
#
# Modes (MAEGLEY_SECRET_SCAN_MODE, default "warn"):
#   log    record findings, always exit 0
#   warn   print findings loudly, exit 0        <- rollout "Install"/"Warn" stage
#   block  print findings, exit 1               <- rollout "Block" waves
#
# Written after the 2026-08-15 survey of /home/codex/ha found an HA bearer token,
# a Proxmox root API token, a Pi-hole password, a root password, and a B2 key
# sitting in cleartext, all one `git add -A` away from a public push.

set -uo pipefail

MODE="${MAEGLEY_SECRET_SCAN_MODE:-warn}"
LOGDIR="${MAEGLEY_PROGRAM_LOG:-$HOME/maegley-lab/program/log}"

# name|regex — deliberately narrow. A scanner that cries wolf gets disabled.
PATTERNS=(
  'private key|-----BEGIN [A-Z ]*PRIVATE KEY-----'
  'JWT / HA long-lived token|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}'
  # A JWT concatenated across source lines is invisible to a line-based scan. Its first
  # fragment still begins `eyJ`, so match a quoted fragment on its own. Found two hardcoded
  # HA tokens in bin/*.py that the header.payload pattern above walked straight past.
  'JWT fragment (split literal)|["'"'"']eyJ[A-Za-z0-9_-]{16,}'
  'Proxmox API token|PVEAPIToken=[^ ]+![^ ]+=[0-9a-f-]{16,}'
  'GitHub token|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,}'
  'AWS access key|AKIA[0-9A-Z]{16}'
  'Slack token|xox[baprs]-[A-Za-z0-9-]{10,}'
  'Backblaze B2 key|applicationKey["'"'"']?\s*[:=]\s*[A-Za-z0-9+/]{25,}'
  # Between the label and the value there may be markdown noise (`**`, backticks, quotes) —
  # skip it, then require 8+ value chars. `$` is allowed *inside* the value: excluding it to
  # dodge ${VAR} interpolation silently missed a real root password beginning with `$`.
  # Interpolation is handled by IGNORE instead.
  "assigned credential|(password|passwd|secret|api[_-]?key|apikey|auth[_-]?token)[[:space:]]*[:=][[:space:]*\`\"']*[^[:space:]\"'\`<>{}]{8,}"
)

# Placeholders — these are documentation, not leaks.
IGNORE='<[^>]*>|\$\{|\$\(|CHANGEME|CHANGE_ME|REDACTED|EXAMPLE|example\.com|your-|YOUR_|xxxx|\.\.\.|placeholder|strong-random|TODO|FIXME|\*\*\*'

findings=0
report=""

scan_content() {
  local label="$1" content="$2"
  local entry regex name line
  for entry in "${PATTERNS[@]}"; do
    name="${entry%%|*}"
    regex="${entry#*|}"
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      echo "$line" | grep -qEi "$IGNORE" && continue
      report+="  ${label}: ${name}"$'\n'
      # Mask quoted/backticked values and long strings. A scanner that echoes the
      # secret to the terminal and the log has just made the problem worse.
      report+="    $(echo "$line" | cut -c1-100 \
        | sed -E "s/\`[^\`]{6,}\`/<REDACTED>/g; s/\"[^\"]{6,}\"/<REDACTED>/g; s/'[^']{6,}'/<REDACTED>/g" \
        | sed -E 's/[A-Za-z0-9_+\/.@-]{12,}/<REDACTED>/g')"$'\n'
      findings=$((findings + 1))
    done < <(echo "$content" | grep -nEi "$regex" 2>/dev/null | head -5)
  done
}

case "${1:---staged}" in
  --staged)
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      scan_content "$f" "$(git show ":$f" 2>/dev/null)"
    done < <(git diff --cached --name-only --diff-filter=ACM)
    ;;
  --files)
    shift
    for f in "$@"; do
      [ -f "$f" ] && scan_content "$f" "$(cat "$f")"
    done
    ;;
  *)
    echo "usage: secret-scan.sh [--staged | --files <path>...]" >&2
    exit 64
    ;;
esac

if [ "$findings" -eq 0 ]; then
  exit 0
fi

{
  echo ""
  echo "═══ SECRET SCAN: ${findings} potential credential(s) ═══"
  echo "$report"
  echo "  Values above are redacted in this output; the originals are in your files."
  echo "  Rotate anything real — redacting the file is not remediation."
  echo ""
} >&2

mkdir -p "$LOGDIR" 2>/dev/null && \
  printf '%s secret-scan mode=%s findings=%d repo=%s\n' \
    "$(date -Iseconds)" "$MODE" "$findings" "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" \
    >> "$LOGDIR/secret-scan.log" 2>/dev/null

case "$MODE" in
  block) echo "  BLOCKED (mode=block). Override once with: MAEGLEY_SECRET_SCAN_MODE=warn git commit ..." >&2
         exit 1 ;;
  *)     echo "  Allowed (mode=${MODE}). This becomes blocking in rollout Wave 1." >&2
         exit 0 ;;
esac
