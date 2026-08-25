#!/usr/bin/env bash
# token-keepalive.sh — keep agent Claude credentials alive across quiet periods
# (WR-013, ADR-0010 §6).
#
# THE PROBLEM (finding, 2026-08-25): Claude tokens last ~8h and refresh ON USE. All
# seven agent tokens expired together over a three-day quiet period because nothing
# dispatched, so nothing refreshed. A conversational Todd that Steve talks to WEEKLY
# dies in exactly its use pattern (WR-013 criterion 8) — the feature is unusable
# without this.
#
# THE FIX: a scheduled, minimal AUTHENTICATED no-op run as the agent identity, well
# inside the ~8h window (the .timer fires every 4h). "Refresh on use" then becomes the
# fix rather than the failure cause. `doctor.sh`'s expiry check (added 2026-08-21) stays
# as the LOUD BACKSTOP if this keep-alive itself fails.
#
# FLAGGED, NOT PROVEN (ADR-0010 §6, Consequences): that a periodic no-op actually
# refreshes the token as "refresh on use" implies must be CONFIRMED against real token
# behaviour before WR-013 criterion 8 is claimed. This script asserts the mechanism; it
# does not measure it. QA/operator: verify a token's expiry timestamp advances after a
# run before accepting criterion 8.
#
# SCOPE: WR-013 owns TODD's survival, so `todd` is the default. The finding was
# fleet-wide (all seven identities); the identical keep-alive SHOULD cover every agent,
# but that roll-out is a separate operator task (ADR-0010 §6) — extend KEEPALIVE_USERS
# to do it. This touches no prod and mints nothing: it only exercises an existing
# credential to stop it aging out.
set -uo pipefail

# Space-separated identities to keep warm. Default: just Todd (this item's scope).
USERS="${KEEPALIVE_USERS:-todd}"
# A trivial prompt; the point is the authenticated round-trip, not the answer. Output is
# discarded. Kept short and bounded so a hung call cannot wedge the timer.
TIMEOUT="${KEEPALIVE_TIMEOUT:-120}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"

rc=0
for u in $USERS; do
  if ! id "$u" >/dev/null 2>&1; then
    echo "token-keepalive: no such user '$u' — skipping" >&2
    continue
  fi
  if ! sudo -n test -f "/home/$u/.claude/.credentials.json" 2>/dev/null; then
    echo "token-keepalive: '$u' has no credential file — nothing to refresh (doctor.sh backstop should already be loud)" >&2
    rc=1
    continue
  fi
  # Minimal authenticated no-op as the agent. `< /dev/null` so it never blocks on stdin;
  # a fixed short prompt; output discarded. A non-zero exit means the refresh did NOT
  # happen — surface it so the timer's status (and doctor.sh) can see a failing keep-alive.
  if timeout "$TIMEOUT" sudo -u "$u" bash -lc \
        "$CLAUDE_BIN -p --output-format json 'keepalive: reply with the single word ok' >/dev/null 2>&1 < /dev/null"; then
    echo "token-keepalive: refreshed '$u'"
  else
    echo "token-keepalive: FAILED to refresh '$u' (exit $?) — credential may be aging out; doctor.sh is the loud backstop" >&2
    rc=1
  fi
done
exit "$rc"
