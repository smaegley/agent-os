#!/usr/bin/env bash
# validate-frontmatter.sh — catch machine-matched front-matter errors at WRITE time.
#
# WR-023 / ADR-0013. Three instances of one defect in eight days (WR-908, WR-018,
# WR-909): a plausible value written into a front-matter field that some component
# matches EXACTLY, validated by nothing, silent until someone tries to act on it —
# WR-018 sat dead five days on `state: spec` (a typo for `spec-ready`). This moves
# the check from use-time to write-time. It invents no rule: every target already
# exists and is authoritative (route(), approve._TOKEN_RE, the ask lifecycle).
#
# Install into a repo's commit path:  install-git-hooks.sh <repo>   (chains after
#   the secret scanner via pre-commit.local). Run manually / from doctor.sh:
#     validate-frontmatter.sh --staged                 (pre-commit: staged blobs)
#     validate-frontmatter.sh --files <path>...         (corpus sweep / fixtures)
#     validate-frontmatter.sh --config                  (print the derived rules)
#
# Modes (MAEGLEY_FRONTMATTER_VALIDATE_MODE, default "warn") — the secret scanner's
# ladder, verbatim (ADR-0013 Decision 2):
#   log    record findings, exit 0
#   warn   print findings loudly, exit 0     <- ships here
#   block  print findings, exit 1            <- Steve promotes per repo on a clean window
#
# A scanner that cries wolf gets disabled (secret-scan.sh:21). §5.6: the valid path
# must stay clean. Every message is headless-actionable (ADR-0013 Decision 3): on
# stderr, naming field, offending value, what would be legal (DERIVED, not typed),
# and where the fix lives — so an agent recovers from its own tool output alone.

set -uo pipefail

MODE="${MAEGLEY_FRONTMATTER_VALIDATE_MODE:-warn}"
LOGDIR="${MAEGLEY_PROGRAM_LOG:-$HOME/maegley-lab/program/log}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- authoritative sources (ADR-0013 Decision 4) ---------------------------
# state: READ, do not copy. The legal set is DERIVED from route()/KNOWN_TERMINAL in
# lib-dispatch.sh so the validator can never disagree with the router. Resolve the
# file: explicit override, else install-relative (hooks/ -> ../../../provisioning).
LIBDISPATCH="${MAEGLEY_LIBDISPATCH:-$HERE/../../../provisioning/lib-dispatch.sh}"

# pending_ask_token: DUPLICATE + doctor.sh consistency-check. The source is a compiled
# Python regex in /usr/local/bin/approve — cross-language, cross-host, absent in a bare
# clone — so it is carried here as the ERE equivalent of approve:80's \A...\Z form
# (bash `grep`/`[[ =~ ]]` have no \A/\Z; ^...$ on a single value is the same anchor).
# doctor.sh asserts three-way agreement validator <-> approve <-> slackbridge/intent.
TOKEN_RE='^WR-[0-9]{3,}-[A-Za-z0-9]{1,12}-[A-Za-z0-9]{4,16}$'

# pending_ask_state: DECLARE (ADR-0013 Decision 5). No single code source enumerates the
# ask lifecycle, so the set is declared here and this ADR is its provenance:
#   pending  Todd sets on escalation; approve._REQUIRE needs it to release (approve:83)
#   approved approve sets on release (approve:214)
#   done     Todd sets after executing the approved step (todd.md:133)
#   refused  recorded terminal outcome on a declined+cancelled ask (photo-album/archive/WR-017)
# Deliberately excludes WR-908's `awaiting-approval` and WR-909's `executed` (drift, not states).
PENDING_ASK_STATES="pending approved done refused"

# owner: ENUMERATE + doctor.sh consistency-check. The host id/credential check is
# unavailable at commit time, so the identity set is enumerated; doctor.sh asserts it
# equals the provisioned agents. Checks identity legality (the typo) only — NOT the
# owner/state contradiction, which resolve_target() already catches at dispatch and
# which false-positives on a legitimate mid-edit item (ADR-0013 Decision 4).
OWNERS="theresa john randal ken eric todd andrea steve unassigned"

# The pending_ask_* set is only meaningful whole (WR-909 had the token and neither other).
PENDING_TRIO="pending_ask_token pending_ask_step pending_ask_state"

# --- derive the legal state set from route() (ADR-0013 D4: never hand-typed) ---
# Fail LOUD on an unsourceable/absent routing table — a silent skip would fall open and
# reintroduce the whole defect class (spec §5.7, ADR-0013 "Negative/costs").
if [ ! -r "$LIBDISPATCH" ] || ! source "$LIBDISPATCH" 2>/dev/null || ! declare -F route >/dev/null; then
  {
    echo ""
    echo "═══ FRONT-MATTER VALIDATION: CANNOT RUN ═══"
    echo "  FATAL: could not source the routing table to derive the legal state set:"
    echo "    $LIBDISPATCH"
    echo "  The state enum is READ from route()/KNOWN_TERMINAL (ADR-0013 Decision 4); without"
    echo "  it this check refuses to run rather than fall open (a silent pass is the very defect"
    echo "  WR-023 exists to close). Point MAEGLEY_LIBDISPATCH at agent-os/provisioning/lib-dispatch.sh,"
    echo "  or repair the agent-os clone this hook lives in."
    echo ""
  } >&2
  exit 2
fi

# route()'s outer case arms are the legal non-terminal states; declare -f normalises
# indentation so the OUTER arms sit at 8 spaces (the nested `case \"\$5\"` arms — todd,
# eric, * — sit deeper and are excluded, as is the outer `*)` default which starts with `*`).
LEGAL_ORDER=()
declare -A LEGAL_SET=()
add_state() { [ -n "${1:-}" ] && [ -z "${LEGAL_SET[$1]:-}" ] && { LEGAL_SET[$1]=1; LEGAL_ORDER+=("$1"); }; }
while IFS= read -r tok; do add_state "$tok"; done < <(
  declare -f route | grep -E '^        [a-z][a-z0-9| -]*\)' | sed -E 's/\).*//; s/ *\| */\n/g; s/^ *//; s/ *$//'
)
for s in $KNOWN_TERMINAL blocked; do add_state "$s"; done   # terminal/stop states + the pre-route blocked case
LEGAL_STATES_LINE="${LEGAL_ORDER[*]}"

# --- helpers ---------------------------------------------------------------
word_in() { local w="$1" list="$2" x; for x in $list; do [ "$x" = "$w" ] && return 0; done; return 1; }

# fm_field <field>  (front-matter block on stdin) -> trimmed value of the first match.
# Anchored so `state:` never matches `pending_ask_state:`. Strips one layer of quotes.
fm_field() {
  local field="$1"
  grep -E "^[[:space:]]*${field}:" | head -1 \
    | sed -E "s/^[[:space:]]*${field}:[[:space:]]*//; s/[[:space:]]*$//; s/^'(.*)'$/\1/; s/^\"(.*)\"$/\1/"
}

findings=0
report=""
add_finding() {  # itemfield  offending  legal-line  fix-line
  report+="  ───────────────────────────────────────────────────────────────"$'\n'
  report+="  ✗ $1"$'\n'
  report+="      offending value: '$2'"$'\n'
  report+="      $3"$'\n'
  report+="      fix: $4"$'\n'
  findings=$((findings + 1))
}

# --- validate one item record ----------------------------------------------
validate_item() {  # label content
  local label="$1" content="$2"
  local -a lines=()
  mapfile -t lines <<< "$content"

  # Front-matter must open on line 1. A WR-<id>.md that does not is malformed — reported,
  # never silently passed (spec §5.7): a silent pass here is the whole defect class.
  if [ "${lines[0]:-}" != "---" ]; then
    add_finding "$label front-matter: (block)" "" \
      "no YAML front-matter block — an item record must open with '---' on line 1" \
      "add the front-matter block; this file is treated as an item by its WR-<id>.md name"
    return
  fi
  local i fmend=-1
  for ((i = 1; i < ${#lines[@]}; i++)); do
    [[ "${lines[i]}" =~ ^---[[:space:]]*$ ]] && { fmend=$i; break; }
  done
  if [ "$fmend" -lt 0 ]; then
    add_finding "$label front-matter: (block)" "" \
      "unterminated front-matter block — no closing '---'" \
      "close the front-matter with a '---' line"
    return
  fi

  local block; block="$(printf '%s\n' "${lines[@]:1:fmend-1}")"
  local state owner tok pstep pstate
  state="$(printf '%s' "$block"  | fm_field state)"
  owner="$(printf '%s' "$block"  | fm_field owner)"
  tok="$(printf '%s'   "$block"  | fm_field pending_ask_token)"
  pstep="$(printf '%s' "$block"  | fm_field pending_ask_step)"
  pstate="$(printf '%s' "$block" | fm_field pending_ask_state)"

  # state — legal iff in the set DERIVED from route()/KNOWN_TERMINAL/blocked.
  if [ -n "$state" ] && [ -z "${LEGAL_SET[$state]:-}" ]; then
    add_finding "$label front-matter: state" "$state" \
      "legal states: $LEGAL_STATES_LINE" \
      "the routing table route()/KNOWN_TERMINAL in agent-os/provisioning/lib-dispatch.sh (e.g. 'spec' is not a state; 'spec-ready' is)"
  fi

  # owner — identity legality only (the typo), not owner/state contradiction.
  if [ -n "$owner" ] && ! word_in "$owner" "$OWNERS"; then
    add_finding "$label front-matter: owner" "$owner" \
      "legal owners: $OWNERS" \
      "a provisioned agent, 'steve', or 'unassigned' (doctor.sh asserts this list == the provisioned agents)"
  fi

  # pending_ask_token — must match approve's shape verbatim.
  if [ -n "$tok" ] && ! [[ "$tok" =~ $TOKEN_RE ]]; then
    add_finding "$label front-matter: pending_ask_token" "$tok" \
      "required shape: WR-<id>-<step>-<nonce> matching $TOKEN_RE" \
      "mint the token per ADR-0008 §3 (a bare nonce is WR-909's bug); this is approve._TOKEN_RE (approve:80)"
  fi

  # pending_ask_state — must be in the declared accepted set.
  if [ -n "$pstate" ] && ! word_in "$pstate" "$PENDING_ASK_STATES"; then
    add_finding "$label front-matter: pending_ask_state" "$pstate" \
      "accepted set: $PENDING_ASK_STATES" \
      "the ask lifecycle (ADR-0013 Decision 5); 'awaiting-approval' (WR-908) and 'executed' (WR-909) are drift, not states"
  fi

  # pending_ask_* set-completeness — present-together (the exact WR-909 case).
  local f v present=() absent=()
  for f in $PENDING_TRIO; do
    case "$f" in
      pending_ask_token) v="$tok" ;;
      pending_ask_step)  v="$pstep" ;;
      pending_ask_state) v="$pstate" ;;
    esac
    if [ -n "$v" ]; then present+=("$f"); else absent+=("$f"); fi
  done
  if [ "${#present[@]}" -gt 0 ] && [ "${#absent[@]}" -gt 0 ]; then
    add_finding "$label front-matter: pending_ask_* set" "present: ${present[*]}" \
      "incomplete ask set — absent: ${absent[*]}; all of ($PENDING_TRIO) are required together" \
      "add the missing field(s) — an ask is only actionable whole (WR-909 had a token and neither other)"
  fi
}

# --- item identification ---------------------------------------------------
# Write-time guard (--staged): only the canonical live-record path
# projects/<proj>/WR-<id>.md — one level under projects/. This naturally excludes
# archive/ and artifacts/ (extra path segment) and non-item docs (specs, ADRs, status),
# so those are never forced to carry item front-matter (spec §5.7). Fixtures under
# artifacts/**/fixtures/ are likewise not blocked at write time.
is_live_record_path() { [[ "$1" =~ (^|/)projects/[^/]+/WR-[0-9]{3,}\.md$ ]]; }
# Explicit-list modes (--files): the caller chose the files; gate on the WR-<id>.md
# basename so a passed fixture or a swept live record is validated, a passed spec is not.
is_item_basename() { local b; b="$(basename "$1")"; [[ "$b" =~ ^WR-[0-9]{3,}\.md$ ]]; }

case "${1:---staged}" in
  --staged)
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      is_live_record_path "$f" || continue
      validate_item "$f" "$(git show ":$f" 2>/dev/null)"
    done < <(git diff --cached --name-only --diff-filter=ACM)
    ;;
  --files)
    shift
    for f in "$@"; do
      [ -f "$f" ] || continue
      is_item_basename "$f" || continue
      validate_item "$f" "$(cat "$f")"
    done
    ;;
  --config)
    # Machine-readable rules for doctor.sh's consistency checks (ADR-0013 D4).
    echo "TOKEN_RE=$TOKEN_RE"
    echo "OWNERS=$OWNERS"
    echo "PENDING_ASK_STATES=$PENDING_ASK_STATES"
    echo "LEGAL_STATES=$LEGAL_STATES_LINE"
    exit 0
    ;;
  *)
    echo "usage: validate-frontmatter.sh [--staged | --files <path>... | --config]" >&2
    exit 64
    ;;
esac

if [ "$findings" -eq 0 ]; then
  exit 0
fi

{
  echo ""
  echo "═══ FRONT-MATTER VALIDATION: ${findings} error(s) ═══"
  printf '%s' "$report"
  echo "  ───────────────────────────────────────────────────────────────"
  echo "  These fields are matched EXACTLY by machines (the router, approve). A bad value"
  echo "  is silent until someone acts on it — WR-018 sat dead five days on a state typo."
  echo "  Fix the value(s) above, then commit again."
  echo ""
} >&2

mkdir -p "$LOGDIR" 2>/dev/null && \
  printf '%s frontmatter-validate mode=%s findings=%d repo=%s\n' \
    "$(date -Iseconds)" "$MODE" "$findings" "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" \
    >> "$LOGDIR/frontmatter-validate.log" 2>/dev/null

case "$MODE" in
  block) echo "  BLOCKED (mode=block). Override once with: MAEGLEY_FRONTMATTER_VALIDATE_MODE=warn git commit ..." >&2
         exit 1 ;;
  log)   exit 0 ;;
  *)     echo "  Allowed (mode=${MODE}). Becomes blocking once Steve promotes this repo on a clean window (ADR-0013 Decision 2)." >&2
         exit 0 ;;
esac
