#!/usr/bin/env bash
# watch-dispatch.sh — the event-driven dispatch trigger (WR-009 / ADR-0001 §1).
#
# The state machine already knows when something happened: an item's front-matter
# state: changing IS the event. The 15-minute batch threw that knowledge away and
# rediscovered it up to 15 minutes later by re-reading every item. This watches
# for the change and reacts to it instead.
#
# THE CRUX (ADR §1, work request): agents commit in their OWN clones and PUSH.
# The authoritative event is therefore "origin moved," NOT "a local file
# changed." A local file-watch (inotify / a systemd .path unit) watches the
# wrong thing — this host's working copy does not change until something pulls,
# which is downstream of and can diverge from the pushed truth. So the trigger
# is the cheapest thing that observes the AUTHORITATIVE event:
#
#   every POLL_INTERVAL seconds:
#     git ls-remote origin <ref>         # a bare ref query — no fetch, no checkout
#     if the tip has not advanced: do NOTHING (idle costs one ref query, nothing else)
#     if it has advanced: fetch objects, diff which items' state: transitioned
#       between the last-processed commit and the new tip, and dispatch the ones
#       that route to an agent — through the ONE serialized path (lib-dispatch.sh).
#
# Reading item front-matter from git OBJECTS at a fixed SHA (never the live
# working tree) is what makes write-during-read a non-issue (ADR §3): agents
# pushing meanwhile only advance origin to a new tip, handled on the next poll.
#
# Self-trigger is guarded HERE, by construction (ADR-0009 §2): on the diff path
# we dispatch an item only when its front-matter state: actually TRANSITIONED
# between the high-water commit and the tip. An agent's own follow-up commit at an
# unchanged state (evidence, a status note, a finding left in place) is not a
# transition, so it does not re-dispatch — without consulting a record or
# comparing committer identity. A legitimate RETURN to a routable state (e.g.
# blocked -> qa-ready) IS a transition and dispatches even past a stale record
# (the flag threaded into evaluate_item). Several commits landing together for one
# logical transition are all at or before the same fetched tip, so the resulting
# state is evaluated once. The full-re-evaluation fallback (no valid high-water
# mark) has no "previous" to diff, so there it falls back to the TTL-bounded
# record in lib-dispatch.sh for debounce.
#
# HEALTH (ADR §5, spec §6.11 ship gate): a dead watcher looks exactly like an
# idle queue, so this touches a heartbeat every loop and pings the systemd
# watchdog. The independent reconcile timer ages the heartbeat out and alerts
# fail-loud if it goes stale — a signal this process cannot suppress by dying.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib-dispatch.sh"

POLL_INTERVAL="${POLL_INTERVAL:-10}"           # ADR §6 recommends ~10-15s; the new latency floor
RECORD_REF="${RECORD_REF:-refs/heads/main}"    # the authoritative record ref on origin
RECORD_ORIGIN="${RECORD_ORIGIN:-origin}"

log() { echo "$(date -Iseconds) watch: $*" >> "$REPO/log/dispatch.log" 2>/dev/null || true; }

heartbeat() {
  : > "$HEARTBEAT" 2>/dev/null || true
  # Feed the systemd watchdog if we were started with WatchdogSec set. A hung
  # loop is then restarted by systemd (the self-healing layer, ADR §5).
  [ -n "${WATCHDOG_USEC:-}" ] && command -v systemd-notify >/dev/null 2>&1 \
    && systemd-notify WATCHDOG=1 2>/dev/null || true
}

remote_tip() { git -C "$REPO" ls-remote "$RECORD_ORIGIN" "$RECORD_REF" 2>/dev/null | awk 'NR==1{print $1}'; }

# Dispatch every routable item that transitioned in (last, tip]. If last is empty
# or is not an ancestor of tip (first run, or a rebase/force-push rewrote history),
# fall back to evaluating ALL items at tip — safe, because the dispatch record
# makes an already-handled transition a no-op.
process_range() { # last tip
  local last=$1 tip=$2 files f mode
  if [ -n "$last" ] && git -C "$REPO" merge-base --is-ancestor "$last" "$tip" 2>/dev/null; then
    mode=diff       # we have a real "previous" — gate on a genuine state: transition
    files="$(git -C "$REPO" diff --name-only "$last" "$tip" -- projects/ 2>/dev/null \
             | grep -E '^projects/[^/]+/[^/]+\.md$' || true)"
  else
    mode=full       # no valid high-water — no "previous" to diff; lean on the TTL'd record
    [ -n "$last" ] && log "high-water $last not an ancestor of $tip — full re-evaluation"
    files="$(git -C "$REPO" ls-tree -r --name-only "$tip" -- projects/ 2>/dev/null \
             | grep -E '^projects/[^/]+/[^/]+\.md$' || true)"
  fi
  [ -n "$files" ] || return 0

  local id proj state infra uf adr owner prevstate transition
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # Front matter read from the git object at the pushed tip — never a live file.
    [ "$(git -C "$REPO" show "$tip:$f" 2>/dev/null | head -1)" = '---' ] || continue
    id="$(fm_blob id "$tip" "$f")";        [ -n "$id" ] || continue
    state="$(fm_blob state "$tip" "$f")";  proj="$(fm_blob project "$tip" "$f")"
    infra="$(fm_blob infra "$tip" "$f")";  uf="$(fm_blob user_facing "$tip" "$f")"
    adr="$(fm_blob needs_adr "$tip" "$f")"; owner="$(fm_blob owner "$tip" "$f")"

    # ADR-0009 §2 — the self-trigger guard, author-free. On the diff path, compare
    # the state: field at the high-water commit against the tip: dispatch ONLY on a
    # genuine transition. A changed file whose state did not move (an agent's own
    # evidence/status commit) is NOT a transition -> skipped, so an agent never
    # re-dispatches itself. A real state: change -> transition=1, which also tells
    # dispatch_one to ignore any stale destination-state record for this item, so a
    # legitimate return to a routable state is no longer silently suppressed.
    #   NB fm_blob on a commit where the file did not exist yields "" — so a brand
    #   new item ("" -> new) reads as a transition and dispatches, as it must.
    # The full-re-evaluation path has no meaningful "previous": transition=0, and
    # the TTL-bounded record in lib-dispatch.sh provides debounce.
    transition=0
    if [ "$mode" = diff ]; then
      prevstate="$(fm_blob state "$last" "$f")"
      [ "$prevstate" = "$state" ] && continue   # file touched but state unchanged — not an event
      transition=1
    fi

    # origin_ok=1: we are reading AT the pushed tip, so the item is on origin by
    # construction — the crux resolved (ADR-0001 §1). An unpushed local edit never
    # advances the ref and never reaches here.
    evaluate_item "$id" "$proj" "$state" "${infra:-false}" "${uf:-false}" "${adr:-false}" \
                  "$owner" "$f" 1 "$transition"
    case "$EV_STATUS" in
      routed) log "dispatched $EV_REASON" ;;
      shadow) log "SHADOW would-dispatch $EV_REASON" ;;
      held)   log "held $EV_REASON" ;;
    esac
  done <<< "$files"
}

dispatch_state_init
log "watcher up (poll=${POLL_INTERVAL}s, ref=$RECORD_REF, shadow=${DISPATCH_SHADOW}, cap=$MAX_INFLIGHT)"
heartbeat
# Tell systemd we are ready (Type=notify) so WatchdogSec supervision begins.
[ -n "${NOTIFY_SOCKET:-}" ] && command -v systemd-notify >/dev/null 2>&1 \
  && systemd-notify --ready 2>/dev/null || true

# Resume from the persisted high-water mark so pushes during downtime are caught
# and already-dispatched transitions are not replayed (ADR §3, crash recovery).
LAST="$(cat "$HWM" 2>/dev/null || true)"

while :; do
  heartbeat

  # Work-hours gate matches the batch's: no dispatching outside 07:00-20:00 local.
  # We simply idle (still heartbeating, so health stays green); the accumulated
  # range (LAST, tip] is picked up when hours resume. The reconcile timer's
  # health probe is likewise gated to work hours, so idle nights raise no alarm.
  if ! within_work_hours; then sleep "$POLL_INTERVAL"; continue; fi

  TIP="$(remote_tip)"
  if [ -z "$TIP" ]; then
    log "ls-remote returned nothing — origin unreachable?"     # transient; retry next poll
    sleep "$POLL_INTERVAL"; continue
  fi

  if [ "$TIP" != "$LAST" ]; then
    # Ref advanced — fetch objects only (no merge, no checkout: the working tree
    # stays the reconcile's to manage), then act on the immutable tree at TIP.
    if git -C "$REPO" fetch -q "$RECORD_ORIGIN" 2>/dev/null; then
      process_range "$LAST" "$TIP"
      LAST="$TIP"
      printf '%s\n' "$LAST" > "$HWM"     # advance the high-water mark only after processing
    else
      log "fetch failed after ref moved to $TIP — will retry"
    fi
  fi

  sleep "$POLL_INTERVAL"
done
