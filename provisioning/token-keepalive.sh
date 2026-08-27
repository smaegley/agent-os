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
# WHAT IT MEASURES (WR-019 Defect 3): each run reads the credential's expiresAt before
# and after the round-trip and reports the TRUTH — `refreshed (+Nh)` only when the
# timestamp actually advanced, `already valid, no renewal needed (Nh left)` when the
# round-trip succeeded against a still-healthy token (the normal case for most
# identities on most fires — a healthy outcome, not a failure), and the FAILED branch
# only when the round-trip itself fails. Because renewal is expiry-driven not
# use-driven, "already valid" is the expected majority outcome and does not set rc.
# NOTE (ADR-0010 §6): WR-013 criterion 8's MULTI-DAY case is still separate — this
# proves renewal-on-use over a single expiry window, not over multi-day silence.
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

# Read claudeAiOauth.expiresAt (ms since epoch) from an identity's credential file —
# the same field, same extraction doctor.sh asserts on. Empty if unreadable. This is
# what lets us MEASURE a renewal instead of assuming one (WR-019 Defect 3).
keepalive_expiry() {
  sudo -n grep -oE '"expiresAt":[0-9]+' "/home/$1/.claude/.credentials.json" 2>/dev/null | head -1 | cut -d: -f2
}

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
  # Measure the renewal; do not assume it. "Refresh on use" is EXPIRY-driven, not
  # round-trip-driven: a still-valid token is not re-minted just because we complete an
  # authenticated round-trip (measured — WR-019 Defect 3). So capture expiresAt before
  # and after and branch on whether it actually advanced, instead of reporting
  # "refreshed" on any exit 0 — which is false on every run where the token was healthy,
  # i.e. most runs.
  exp_before="$(keepalive_expiry "$u")"
  # Minimal authenticated no-op as the agent. `< /dev/null` so it never blocks on stdin;
  # a fixed short prompt; output discarded. A non-zero exit means the ROUND-TRIP itself
  # failed — surface it so the timer's status (and doctor.sh) can see a failing keep-alive.
  if timeout "$TIMEOUT" sudo -u "$u" bash -lc \
        "$CLAUDE_BIN -p --output-format json 'keepalive: reply with the single word ok' >/dev/null 2>&1 < /dev/null"; then
    exp_after="$(keepalive_expiry "$u")"
    now_ms=$(( $(date +%s) * 1000 ))
    if [[ "$exp_before" =~ ^[0-9]+$ ]] && [[ "$exp_after" =~ ^[0-9]+$ ]]; then
      if [ "$exp_after" -gt "$exp_before" ]; then
        echo "token-keepalive: refreshed '$u' (+$(( (exp_after - exp_before) / 3600000 ))h)"
      else
        # Round-trip OK, token was still valid, so nothing was re-minted. This is the
        # NORMAL state for most identities on most fires — a HEALTHY outcome, not a
        # failure, and it must NOT set rc.
        echo "token-keepalive: '$u' already valid, no renewal needed ($(( (exp_after - now_ms) / 3600000 ))h left)"
      fi
    else
      # Round-trip succeeded but the expiry timestamp was unreadable, so a renewal
      # cannot be confirmed. Do not claim one. Round-trip OK ⇒ not a failure, rc unset.
      echo "token-keepalive: '$u' round-trip ok, expiry unreadable — cannot confirm renewal" >&2
    fi
  else
    echo "token-keepalive: FAILED to refresh '$u' (exit $?) — credential may be aging out; doctor.sh is the loud backstop" >&2
    rc=1
  fi
done
exit "$rc"
