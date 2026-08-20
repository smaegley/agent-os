#!/usr/bin/env bash
# mirror-record.sh — keep /srv/git/program.git current with GitHub.
#
# WHY THIS EXISTS: ADR-0007 §2 lets the answer runner read the record from "the
# local bare repo directly", and deploy/README §10b clones /srv/git/program.git
# for exactly that. The bare repo did not exist — agents push `program` straight
# to GitHub — so the status path had no record to read.
#
# WHY IT MATTERS MORE THAN IT LOOKS: status-answer refreshes its clone at answer
# time and fails loud if the FETCH fails, but it cannot tell that its origin is
# itself stale. A mirror that quietly stops updating produces confidently wrong
# status answers with no error anywhere — the silent-failure shape this program
# keeps rediscovering. So this runs often, and doctor.sh asserts the mirror is
# not behind GitHub (see the `record mirror` check there).
#
# Runs as steve, using the GitHub key steve already holds. The answer identity
# gets no credential, which is what keeps ADR-0007 §1's "status ships with no new
# credential" true.
set -uo pipefail
MIRROR=/srv/git/program.git
[ -d "$MIRROR" ] || { echo "mirror-record: no mirror at $MIRROR" >&2; exit 1; }
git --git-dir="$MIRROR" remote update --prune >/dev/null 2>&1 || {
  echo "mirror-record: fetch from GitHub failed" >&2; exit 1; }
chmod -R a+rX "$MIRROR"; chmod -R g+rwX "$MIRROR" 2>/dev/null || true
exit 0
