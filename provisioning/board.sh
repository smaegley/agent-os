#!/usr/bin/env bash
# board.sh — regenerate the work board from git state.
#
# The board is DERIVED, never hand-maintained. A status page that is updated by
# hand drifts from the repo and then quietly becomes fiction — the same failure
# as a QA tool reporting "clean" when it cannot see. Every value here is read
# from the work items at run time; if the page and the repo disagree, the page
# is stale and re-running this fixes it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${PROGRAM_REPO:-/home/steve/maegley-lab/program}"
OUT="${1:-/home/codex/ha/maegley-lab-board.html}"
cd "$REPO" || exit 1
git pull -q origin main 2>/dev/null

fm() { sed -n '2,/^---$/p' "$2" | grep -E "^$1:" | head -1 | cut -d: -f2- | xargs; }

# state → (who acts, is it Steve's move, human-readable meaning)
meaning() { case "$1" in
  new)          echo "Theresa|0|queued — needs requirements written" ;;
  spec-ready)   echo "John|0|queued — spec written, awaiting design decision" ;;
  design-ready) echo "Randal|0|queued — design recorded, awaiting build" ;;
  qa-ready)     echo "Eric|0|queued — built, awaiting independent verification" ;;
  needs-exec)   echo "You|1|QA wrote commands it cannot run — you or Todd execute" ;;
  qa-passed)    echo "You|1|verified — awaiting your approval to deploy" ;;
  uat-passed)   echo "You|1|user-tested — awaiting your approval to deploy" ;;
  blocked)      echo "You|1|stuck — needs a decision or access from you" ;;
  *)            echo "—|0|$1" ;;
esac; }

ROWS=""; MINE=0; TOTAL=0
for f in projects/*/*.md; do
  head -1 "$f" | grep -q '^---$' || continue
  id="$(fm id "$f")"; [ -n "$id" ] || continue
  st="$(fm state "$f")"; proj="$(fm project "$f")"; own="$(fm owner "$f")"
  title="$(grep -m1 '^# ' "$f" | sed 's/^# *//;s/Work request — //' | cut -c1-78)"
  IFS='|' read -r actor mine desc <<<"$(meaning "$st")"
  TOTAL=$((TOTAL+1)); [ "$mine" = 1 ] && MINE=$((MINE+1))
  cls=$([ "$mine" = 1 ] && echo "mine" || echo "team")
  updated="$(git log -1 --format='%ar' -- "$f" 2>/dev/null)"
  ROWS+="<tr class=\"$cls\"><td class=\"id\">$id</td><td>$title</td>"
  ROWS+="<td><span class=\"st st-$st\">$st</span></td>"
  ROWS+="<td class=\"who\">$actor</td><td class=\"desc\">$desc</td><td class=\"age\">$updated</td></tr>"
done

# What the agents have actually DONE — from git, the only honest source.
ACTIVITY=""
while IFS='|' read -r when who what; do
  [ -n "$who" ] || continue
  ACTIVITY+="<tr><td class=\"age\">$when</td><td class=\"who\">$who</td><td>$what</td></tr>"
done < <(git log --format='%ar|%an|%s' -10)
[ -n "$ACTIVITY" ] || ACTIVITY="<tr><td colspan=3 class=\"desc\">No commits yet.</td></tr>"

LAST="$(grep -E '^[0-9]{4}-' log/dispatch.log 2>/dev/null | tail -1 | cut -d' ' -f1 | cut -dT -f2 | cut -d+ -f1)"
LAST="${LAST:-never}"
if crontab -l 2>/dev/null | grep -q 'dispatch.sh'; then
  NEXT="hourly, 08:00–22:00 — next at $(date -d "$(date -d '+1 hour' '+%H:00')" '+%H:%M' 2>/dev/null)"
else
  NEXT="NOT SCHEDULED — work only moves when dispatch.sh is run by hand"
fi
STAMP="$(date '+%-d %b %Y, %H:%M')"
sed -e "s|<!--ROWS-->|$ROWS|" -e "s|<!--MINE-->|$MINE|" -e "s|<!--TOTAL-->|$TOTAL|" \
    -e "s|<!--STAMP-->|$STAMP|" -e "s|<!--ACTIVITY-->|$ACTIVITY|" -e "s|<!--LAST-->|$LAST|" -e "s|<!--NEXT-->|$NEXT|" "$HERE/board-template.html" > "$OUT"
echo "→ board written: $OUT  ($MINE of $TOTAL waiting on you)"
