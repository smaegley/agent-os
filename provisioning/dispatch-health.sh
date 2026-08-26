#!/usr/bin/env bash
# dispatch-health.sh — is the event-driven dispatcher actually alive? (WR-009 §6.11)
#
# THE SHIP GATE. The work request is explicit: "This work must not ship without
# that check." An event-driven dispatcher fails silent MORE easily than a cron
# one, not less — a dead watcher looks exactly like an idle queue: no error, no
# missing cron line, just work that quietly stops moving. It has already failed
# silently for hours twice.
#
# This is the fail-loud layer of the two-layer health design (ADR §5). The other
# layer is systemd's own WatchdogSec/Restart=always, which self-heals a hung or
# crashed process. This layer catches what the watchdog CANNOT: the service
# disabled, masked, or the box wedged — the cases that otherwise read as idle.
# It runs from the reconcile .timer, i.e. OUTSIDE the watcher process, so it is a
# signal the watcher cannot suppress by dying (a health check the dying thing
# emits is worthless).
#
# It is deliberately QUIET until the watcher is actually deployed, so it can ship
# and run (called by dispatch.sh) all through cutover stages 0-1 while the cron
# is still primary, without crying wolf. It alerts on the healthy->down EDGE, not
# every cycle, so a genuinely-down watcher does not spam #ops-prod every 5 min.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib-dispatch.sh"

HEARTBEAT_MAX_AGE="${HEARTBEAT_MAX_AGE:-120}"     # >> poll interval (10s); alive => age always under this
WATCH_UNIT="${WATCH_UNIT:-maegley-dispatch-watch.service}"
HEALTH_STATE="$STATE_DIR/watch-health-last"       # last reported status — alert only on change

report() { # status detail  (status: up|down)
  local status=$1 detail=$2 prev
  prev="$(cat "$HEALTH_STATE" 2>/dev/null || echo unknown)"
  printf '%s\n' "$status" > "$HEALTH_STATE" 2>/dev/null || true
  echo "$(date -Iseconds) health: $status — $detail" >> "$REPO/log/dispatch.log" 2>/dev/null || true
  [ "$status" = "$prev" ] && return 0        # no edge — stay quiet
  case "$status" in
    down) sudo -n /usr/local/bin/notify '#ops-prod' \
            "Dispatcher watcher is DOWN — $detail. Event-driven dispatch is not firing; the */15 cron dispatch.sh is still moving the backlog as the fallback, so nothing is stranded, but latency is back to the 15-min cron interval until the watcher is restarted." \
            >/dev/null 2>&1 || true ;;
    up)   [ "$prev" = down ] && sudo -n /usr/local/bin/notify '#ops-prod' \
            "Dispatcher watcher is back UP — event-driven dispatch restored ($detail)." \
            >/dev/null 2>&1 || true ;;
  esac
}

# --- is the watcher even expected to be running yet? -------------------------
# Quiet before deployment: if it has never written a heartbeat AND the unit is
# not enabled, the watcher is not deployed — say nothing (cutover stages 0-1).
enabled=0
command -v systemctl >/dev/null 2>&1 && systemctl is-enabled "$WATCH_UNIT" >/dev/null 2>&1 && enabled=1
if [ ! -e "$HEARTBEAT" ] && [ "$enabled" != 1 ]; then
  exit 0
fi

# --- the two things a fail-loud probe must catch -----------------------------
# 1. The unit is enabled but not active (disabled-at-runtime, masked, crashed
#    past Restart= — the watchdog's blind spots).
if [ "$enabled" = 1 ] && command -v systemctl >/dev/null 2>&1 \
   && ! systemctl is-active "$WATCH_UNIT" >/dev/null 2>&1; then
  report down "$WATCH_UNIT is enabled but not active ($(systemctl is-active "$WATCH_UNIT" 2>&1))"
  exit 0
fi

# 2. The process claims to be up but the heartbeat has gone stale (a wedged loop
#    the watchdog somehow missed, or a wedged box).
if [ ! -e "$HEARTBEAT" ]; then
  report down "no heartbeat file at $HEARTBEAT (watcher never started, or state dir gone)"
  exit 0
fi
age=$(( $(date +%s) - $(stat -c %Y "$HEARTBEAT" 2>/dev/null || echo 0) ))
if [ "$age" -gt "$HEARTBEAT_MAX_AGE" ]; then
  report down "heartbeat is ${age}s old (threshold ${HEARTBEAT_MAX_AGE}s)"
  exit 0
fi

report up "heartbeat ${age}s old"
