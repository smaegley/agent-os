#!/usr/bin/env bash
# board.sh — regenerate the work board from git state.
#
# The board is DERIVED, never hand-maintained. A status page that is updated by
# hand drifts from the repo and then quietly becomes fiction — the same failure
# as a QA tool reporting "clean" when it cannot see. Every value here is read
# from the work items at run time; if the page and the repo disagree, the page
# is stale and re-running this fixes it.
set -uo pipefail
export TZ="${MAEGLEY_TZ:-America/Denver}"   # HA's configured zone; the box itself runs UTC
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
  hold)         echo "—|0|on hold — you parked it; no agent will pick it up" ;;
  adr-needed)   echo "John|0|queued — built, but its design record needs correcting" ;;
  *)            echo "—|0|$1" ;;
esac; }

ROWS=""; MINE=0; TOTAL=0
for f in projects/*/*.md; do
  head -1 "$f" | grep -q '^---$' || continue
  id="$(fm id "$f")"; [ -n "$id" ] || continue
  st="$(fm state "$f")"; proj="$(fm project "$f")"; own="$(fm owner "$f")"
  title="$(grep -m1 '^# ' "$f" | sed 's/^# *//;s/Work request — //' | cut -c1-78)"
  IFS='|' read -r actor mine desc <<<"$(meaning "$st")"

  # A held item should say what it is waiting on, or 'hold' reads as 'forgotten'.
  if [ "$st" = hold ]; then
    hr="$(fm hold_reason "$f")"
    [ -n "$hr" ] && desc="on hold — $hr"
  fi

  # Live overrides durable: a running marker means an agent is on it right now.
  RUNMARK="/home/steve/.local/state/maegley/running.d/$id"
  if [ -f "$RUNMARK" ]; then
    read -r r_who r_ts < "$RUNMARK"
    r_min=$(( ( $(date +%s) - r_ts ) / 60 ))
    if [ "$r_min" -le 40 ]; then
      actor="${r_who^}"; mine=0
      desc="IN PROGRESS — ${r_who^} working now (${r_min}m elapsed)"
    else
      desc="$desc (a run started ${r_min}m ago and may have died — Todd should check)"
    fi
  fi
  TOTAL=$((TOTAL+1)); [ "$mine" = 1 ] && MINE=$((MINE+1))
  cls=$([ "$mine" = 1 ] && echo "mine" || echo "team")
  [ -f "$RUNMARK" ] && [ "${r_min:-99}" -le 40 ] && cls="live"
  updated="$(git log -1 --format='%ar' -- "$f" 2>/dev/null)"

  # For anything waiting on Steve, pull the actual ask onto the page. A board
  # that says "needs you" and makes him go find out what is only half a board.
  DETAIL=""
  if [ "$mine" = 1 ]; then
    case "$st" in
      needs-exec)
        rq="$(ls -t projects/*/qa/*run-request*.md 2>/dev/null | xargs -r grep -l "work_item: $id" 2>/dev/null | head -1)"
        if [ -n "$rq" ]; then
          tests="$(grep -E '^#{2,3} (T-|Pre-step)' "$rq" | sed -e 's/^#* *//' -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')"
          nlines="$(sed -n '/^```$/,/^```$/p' "$rq" | grep -vE '^```|^\s*$' | wc -l)"
          warn=""
          grep -qE '\-\-apply|deletes data|DESTRUCTIVE' "$rq" && \
            warn="<span class=\"warn\">This request contains a step that WRITES to production. Read it before running any of it.</span>"
          DETAIL="<tr class=\"detail\"><td></td><td colspan=5><div class=\"ask\">"
          DETAIL+="<b>QA needs these run</b> — ${nlines} commands across:<pre>$tests</pre>"
          DETAIL+="$warn<span class=\"hint\">Open <code>$rq</code> for the commands — do not run a partial set; the tests build on each other. Paste output back to Claude.</span>"
          DETAIL+="</div></td></tr>"
        fi ;;
      blocked)
        why="$(grep -m1 -A2 -iE '^\*\*(why|blocked|reason)' "$f" 2>/dev/null | tail -1 | cut -c1-220)"
        [ -n "$why" ] || why="$(git log -1 --format='%s' -- "$f")"
        DETAIL="<tr class=\"detail\"><td></td><td colspan=5><div class=\"ask\"><b>Why it stopped</b><p>$(echo "$why" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g')</p></div></td></tr>" ;;
    esac
  fi
  ROWS+="<tr class=\"$cls\"><td class=\"id\">$id</td><td>$title</td>"
  ROWS+="<td><span class=\"st st-$st\">$st</span></td>"
  ROWS+="<td class=\"who\">$actor</td><td class=\"desc\">$desc</td><td class=\"age\">$updated</td></tr>$DETAIL"
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
CRONLINE="$(crontab -l 2>/dev/null | grep -E 'dispatch\.sh' | grep -v '^#' | head -1)"
if [ -n "$CRONLINE" ]; then
  MIN="$(echo "$CRONLINE" | awk '{print $1}')"; HRS="$(echo "$CRONLINE" | awk '{print $2}')"
  case "$MIN" in
    \*/*) EVERY="every ${MIN#*/} min" ;;
    *)    EVERY="hourly" ;;
  esac
  NEXT="$EVERY, ${HRS/-/:00–}:00"
else
  NEXT="NOT SCHEDULED — work only moves when dispatch.sh is run by hand"
fi
STAMP="$(date '+%-d %b %Y, %H:%M')"
ROWS="$ROWS" ACTIVITY="$ACTIVITY" MINE="$MINE" TOTAL="$TOTAL" STAMP="$STAMP" \
LAST="$LAST" NEXT="$NEXT" TPL="$HERE/board-template.html" OUTF="$OUT" python3 - <<'PYEOF'
import os, pathlib
t = pathlib.Path(os.environ['TPL']).read_text()
for k in ('ROWS','ACTIVITY','MINE','TOTAL','STAMP','LAST','NEXT'):
    t = t.replace(f'<!--{k}-->', os.environ.get(k, ''))
pathlib.Path(os.environ['OUTF']).write_text(t)
PYEOF
echo "→ board written: $OUT  ($MINE of $TOTAL waiting on you)"
