#!/usr/bin/env bash
# dispatch.sh — route work items to agents by state.
#
# Steve kicks off work; the team moves it. This is the "team handles assignment"
# half: a state machine in code, not a coordinator agent making judgement calls
# about who does what. Routing is deterministic; the WORK is the model's.
#
# That split is deliberate. A PM agent that decides assignments would be a
# model making a decision a lookup table makes correctly every time, and would
# add a whole context window of cost and failure surface to do it.
#
# WHAT CHANGED (WR-009 / ADR-0001): this script is no longer the PRIMARY, every-
# 15-minutes dispatcher. It is now the RECONCILING SWEEP — the batch's own
# read-every-item logic, kept but slowed, run by a systemd .timer as the
# backstop behind the event-driven watcher (watch-dispatch.sh). Its job is to
# catch any transition the watcher missed (a dropped poll, a watcher restart, a
# push during downtime) and to do the housekeeping the re-scoped lock now needs
# (reap crash-orphaned markers, prune old dispatch records, probe watcher
# health). During cutover it also runs from the 15-minute cron unchanged, as the
# armed fallback — safe to coexist with the watcher because BOTH now dispatch
# through the one serialized, idempotent path in lib-dispatch.sh.
#
# The routing table and every per-item guard are UNCHANGED — they moved verbatim
# into lib-dispatch.sh so the watcher and this sweep cannot disagree about where
# an item goes. WR-009 changed WHEN dispatch fires, never WHERE (spec §3/§8).
#
# Work items are markdown with front matter:
#   ---
#   id: WR-004
#   project: ha-ops
#   state: new
#   owner: unassigned
#   infra: true          # optional — routes spec-ready to the Architect
#   user_facing: true    # optional — routes qa-passed to UAT
#   ---
#
# GUARDS (now cross-process, in lib-dispatch.sh — see there for the model):
#   * MAX_INFLIGHT active dispatches system-wide — a routing bug cannot cascade.
#   * per-agent mutex + per-item marker — an agent/item is dispatched once at a time.
#   * per-item dispatch record — one logical transition dispatches once (no self-trigger).
#   * Terminal states never dispatch. Anything touching prod stops for Steve.
#   * blocked escalates; it is never auto-routed to an agent.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib-dispatch.sh"

# --- working hours, decided here rather than by cron ---------------------------
# cron on this box runs in UTC and ignores CRON_TZ (that is a cronie feature;
# Debian/Ubuntu vixie-cron treats it as an env var for the job). A window
# expressed in crontab hours was therefore UTC no matter what it claimed. This
# guard resolves the zone at run time, so it is right through DST changes too.
if ! within_work_hours; then
  exit 0        # outside working hours — silent, this runs frequently
fi

# One sweep at a time. This is a SEPARATE lock from the per-decision dispatch
# lock (lib-dispatch.sh $LOCK): overlapping sweeps waste work, but a sweep must
# NOT hold the dispatch lock across its whole scan or it would starve the
# watcher — the very batching latency WR-009 removes. The per-item dispatch
# decisions serialize on $LOCK inside dispatch_one; this only stops two sweeps.
SWEEP_LOCK="${SWEEP_LOCK:-/tmp/maegley-reconcile.lock}"
exec 8>"$SWEEP_LOCK"
flock -n 8 || { echo "dispatch: another sweep holds the lock — skipping"; exit 0; }

cd "$REPO" || { echo "dispatch: no repo at $REPO" >&2; exit 1; }

dispatch_state_init
credit_hold_gc          # lift an expired credit hold (loud, once) even if the queue is idle
reap_stale_markers      # crash-orphaned markers wedge an agent's mutex — reap them
prune_records           # keep dispatched.d from growing without bound

git fetch -q origin 2>/dev/null; git merge -q --ff-only origin/main 2>/dev/null || true

ROUTED=""; STOPPED=""; BLOCKED=""; UNPROVISIONED=""; SHADOW=""; NEEDS_STEVE=""

# Snapshot every item's state BEFORE dispatching. The old notification announced
# what was STARTED — so a run that stranded its work still read as "DISPATCHED
# WR-001 → randal", i.e. success. Report what actually landed on origin instead.
declare -A BEFORE
for f in projects/*/*.md; do
  [ -e "$f" ] && head -1 "$f" | grep -q '^---$' || continue
  BEFORE["$f"]="$(fm state "$f")"
done

ORDERED="$(for f in projects/*/*.md; do
  [ -e "$f" ] && head -1 "$f" | grep -q '^---$' || continue
  pri="$(fm priority "$f")"; [[ "$pri" =~ ^[0-9]+$ ]] || pri=5
  printf '%s\t%s\n' "$pri" "$f"
done | sort -n -s | cut -f2)"

for f in $ORDERED; do
  id="$(fm id "$f")";    [ -n "$id" ] || continue
  state="$(fm state "$f")"; proj="$(fm project "$f")"
  infra="$(fm infra "$f")"; uf="$(fm user_facing "$f")"; adr="$(fm needs_adr "$f")"

  # Local sweep: confirm the item is on origin (agents pull from origin).
  origin_ok=1
  git cat-file -e "origin/main:$f" 2>/dev/null || origin_ok=0

  evaluate_item "$id" "$proj" "$state" "${infra:-false}" "${uf:-false}" "${adr:-false}" \
                "$(fm owner "$f")" "$f" "$origin_ok"

  case "$EV_STATUS" in
    routed)        ROUTED+="  $EV_REASON"$'\n' ;;
    shadow)        SHADOW+="  $EV_REASON"$'\n' ;;
    dry)           ROUTED+="  $EV_REASON"$'\n' ;;
    credit-held)   STOPPED+="  credit-held: $EV_REASON"$'\n' ;;   # WR-014: paused for credit
    held|stopped)  STOPPED+="  $EV_REASON"$'\n' ;;
    unprovisioned) UNPROVISIONED+="  $EV_REASON"$'\n' ;;
    blocked)       BLOCKED+="  $EV_REASON"$'\n' ;;
    unknown)       STOPPED+="  $EV_REASON"$'\n'
                   NEEDS_STEVE+="  $id — state '$state' is not in the state machine; Todd to correct"$'\n' ;;
    contradiction) STOPPED+="  $EV_REASON"$'\n'
                   NEEDS_STEVE+="  $id — state '$state' and owner disagree; Todd to resolve"$'\n' ;;
  esac
done

# --- report what actually changed on origin — the only honest report of a run.
git fetch -q origin 2>/dev/null; git merge -q --ff-only origin/main 2>/dev/null || true
LANDED=""
for f in projects/*/*.md; do
  [ -e "$f" ] && head -1 "$f" | grep -q '^---$' || continue
  now="$(fm state "$f")"; was="${BEFORE[$f]:-}"
  [ "$now" = "$was" ] && continue
  id="$(fm id "$f")"; who="$(fm owner "$f")"
  if [ "$now" = blocked ]; then
    NEEDS_STEVE+="  $id blocked — $(fm project "$f")"$'\n'
  else
    LANDED+="  $id  $was → $now  (now $who)"$'\n'
  fi
  case "$now" in
    qa-passed|uat-passed) NEEDS_STEVE+="  $id is verified and waiting on your deploy approval"$'\n' ;;
    needs-exec)           NEEDS_STEVE+="  $id — Todd will execute QA's run request; you will get a plain-language approval ask first if anything touches prod"$'\n' ;;
    token-needed)         NEEDS_STEVE+="  $id — a credential must be created; Todd asks Steve before minting it"$'\n' ;;
  esac
done

SUMMARY=""
[ -n "$LANDED" ]        && SUMMARY+="COMPLETED:"$'\n'"$LANDED"
[ -n "$BLOCKED" ]       && SUMMARY+="BLOCKED:"$'\n'"$BLOCKED"
[ -n "$UNPROVISIONED" ] && SUMMARY+="NEEDS AN AGENT:"$'\n'"$UNPROVISIONED"
[ -n "$STOPPED" ]       && SUMMARY+="HELD:"$'\n'"$STOPPED"

if [ "$DRY_RUN" = "1" ]; then
  # A PLAN reports intent; a RUN reports outcome. The dry run exists precisely to
  # show what WOULD be dispatched (dispatch_one echoes it without acting).
  PLAN=""
  [ -n "$ROUTED" ]        && PLAN+="WOULD DISPATCH:"$'\n'"$ROUTED"
  [ -n "$SHADOW" ]        && PLAN+="SHADOW (watcher would dispatch):"$'\n'"$SHADOW"
  [ -n "$BLOCKED" ]       && PLAN+="BLOCKED:"$'\n'"$BLOCKED"
  [ -n "$UNPROVISIONED" ] && PLAN+="NEEDS AN AGENT:"$'\n'"$UNPROVISIONED"
  [ -n "$STOPPED" ]       && PLAN+="HELD:"$'\n'"$STOPPED"
  echo "=== dispatch plan (nothing invoked) ==="; echo "${PLAN:-  nothing to route}"; exit 0
fi

# In shadow mode the sweep dispatches nothing; log the would-dispatch decisions
# so cutover stage 1 can be compared against the cron's actual dispatches.
[ -n "$SHADOW" ] && echo "$(date -Iseconds) dispatch: SHADOW would-dispatch:"$'\n'"$SHADOW" >> "$REPO/log/dispatch.log"

# Silence is the default: a run where nothing moved is not news.
[ -n "$LANDED" ] && sudo -n /usr/local/bin/notify '#program' "$SUMMARY" >/dev/null
NEEDS_STEVE="$NEEDS_STEVE$BLOCKED$UNPROVISIONED"
[ -n "$NEEDS_STEVE" ] && sudo -n /usr/local/bin/notify '#ops-prod' \
  "Needs you:"$'\n'"$NEEDS_STEVE" >/dev/null
echo "$(date -Iseconds) dispatch: routed=$(printf '%s' "$ROUTED" | grep -c .)" >> "$REPO/log/dispatch.log"

# The sweep is also the independent health prober: it runs OUTSIDE the watcher
# process, so it is exactly what can tell "the watcher is dead" from "the queue
# is idle" (ADR §4/§5). Non-fatal to the sweep itself.
"$HERE/dispatch-health.sh" >/dev/null 2>&1 || true
"$HERE/board.sh" >/dev/null 2>&1 || true
