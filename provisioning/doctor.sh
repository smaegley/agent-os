#!/usr/bin/env bash
# doctor.sh — assert every invariant the agent org depends on, for every agent.
#
# WHY: six times in one day a protection was correct but was not reaching where
# the work happened — a key installed but not permitted; a permission pattern
# that did not match the command; a secret gate absent from every agent's clone;
# QA verbs pointed at a port nothing listens on; git patterns that missed
# `git -C`; and a substrate no agent could pull, leaving each frozen 4 to 12
# commits behind. Every one was found by accident, and each looked healthy from
# outside until someone happened to look.
#
# None of those were subtle once checked. They were simply never checked. That
# is what this fixes: the invariants are asserted on a schedule instead of being
# rediscovered when something breaks.
#
# Exits non-zero if any check fails, so the sweep can escalate.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib-agent.sh"

MIRROR=/opt/agent-os.git
FAIL=0; REPORT=""
ok()   { printf '  ✓ %-8s %s\n' "$1" "$2"; }
bad()  { printf '  ✗ %-8s %s\n' "$1" "$2"; REPORT+="  $1: $2"$'\n'; FAIL=1; }

echo "agent org doctor — $(date '+%Y-%m-%d %H:%M')"

SUBSTRATE_HEAD="$(git -C "$MIRROR" rev-parse HEAD 2>/dev/null || echo unknown)"
[ "$SUBSTRATE_HEAD" = unknown ] && bad "mirror" "no substrate mirror at $MIRROR"

for a in $(agent_list); do
  # --- identity ------------------------------------------------------------
  # Existence is not validity. Randal's token expired 2026-08-21 and every
  # dispatch to him failed 401 while this check happily reported "authenticated"
  # -- the file was right there. Tokens refresh on use, so an agent that stops
  # being dispatched for any reason silently ages out and cannot come back
  # without an interactive login. Compare expiresAt to now; it costs a file read.
  if ! sudo -n test -f "/home/$a/.claude/.credentials.json"; then
    bad "$a" "not authenticated — cannot be dispatched"
  else
    exp="$(sudo -n grep -oE '"expiresAt":[0-9]+' "/home/$a/.claude/.credentials.json" 2>/dev/null | head -1 | cut -d: -f2)"
    now_ms=$(( $(date +%s) * 1000 ))
    if [ -z "$exp" ]; then
      ok "$a" "authenticated (no expiry recorded)"
    elif [ "$exp" -le "$now_ms" ]; then
      bad "$a" "TOKEN EXPIRED $(( (now_ms - exp) / 3600000 ))h ago — dispatches will 401; needs interactive re-login"
    else
      ok "$a" "authenticated (expires in $(( (exp - now_ms) / 3600000 ))h)"
    fi
  fi

  # --- the boundary itself, re-asserted rather than assumed ----------------
  sudo -n -u "$a" ls /home/steve/.ssh/ >/dev/null 2>&1 \
    && bad "$a" "CAN READ OPS KEYS — boundary broken" || ok "$a" "cannot read ops keys"
  sudo -n -u "$a" sudo -n true >/dev/null 2>&1 \
    && bad "$a" "HAS SUDO — boundary broken" || ok "$a" "no sudo"

  # --- protections must be where the work happens, not merely to exist -----
  for r in program ha-ops; do
    sudo -n test -d "/home/$a/work/$r/.git" || continue
    sudo -n test -f "/home/$a/work/$r/.git/hooks/pre-commit" \
      && ok "$a" "secret gate in $r" || bad "$a" "NO secret gate in $r — commits unscanned"
  done

  # --- substrate currency: stale rules are followed just as confidently ----
  if sudo -n test -d "/home/$a/work/agent-os/.git"; then
    h="$(agent_git "$a" agent-os rev-parse HEAD 2>/dev/null)"
    if [ "$h" = "$SUBSTRATE_HEAD" ]; then ok "$a" "substrate current"
    else
      n="$(git -C "$MIRROR" rev-list --count "$h"..HEAD 2>/dev/null || echo '?')"
      bad "$a" "substrate $n commits stale — running outdated skills"
    fi
  else
    bad "$a" "no agent-os clone — has no skills at all"
  fi

  # --- unpushed work is invisible work -------------------------------------
  for r in program ha-ops agent-os slack-bridge proxmox-dashboard; do
    sudo -n test -d "/home/$a/work/$r/.git" || continue
    dirty="$(agent_git "$a" "$r" status --porcelain 2>/dev/null | wc -l)"
    ahead="$(agent_git "$a" "$r" status -sb 2>/dev/null | grep -o 'ahead [0-9]*' || true)"
    [ "$dirty" != 0 ] && bad "$a" "$r has $dirty uncommitted file(s)"
    [ -n "$ahead" ]   && bad "$a" "$r is $ahead — work nobody else can see"
  done
done


# --- the operator is not exempt ------------------------------------------
# Every check above loops over AGENT identities. Todd's own trees were never
# looked at — and on 2026-08-18 it was the operator, not an agent, who left the
# production reply path uncommitted. A doctor that watches only the supervised
# half reports "all invariants hold" while the supervisor is the one adrift.
echo
for t in /home/steve/maegley-lab/program /home/steve/maegley-lab/agent-os \
         /home/steve/work/slack-bridge /home/codex/ha; do
  [ -d "$t/.git" ] || continue
  n="$(basename "$t")"
  dirty="$(git -C "$t" status --porcelain 2>/dev/null | wc -l)"
  ahead="$(git -C "$t" status -sb 2>/dev/null | grep -o 'ahead [0-9]*' || true)"
  [ "$dirty" != 0 ] && bad "operator" "$n has $dirty uncommitted file(s)" || true
  [ -n "$ahead" ]   && bad "operator" "$n is $ahead — work nobody else can see" || true
  { [ "$dirty" = 0 ] && [ -z "$ahead" ]; } && ok "operator" "$n clean and pushed" || true
done

# --- the record mirror must not be behind GitHub -------------------------
# The status-answer path reads /srv/git/program.git and refreshes its clone at
# answer time, but it can only detect a FETCH failure — never that its origin is
# itself stale. A mirror that quietly stops updating yields confidently wrong
# status answers with no error anywhere. Assert freshness here instead.
echo
MIRROR=/srv/git/program.git
if [ -d "$MIRROR" ]; then
  before="$(git --git-dir="$MIRROR" rev-parse main 2>/dev/null || echo none)"
  git --git-dir="$MIRROR" remote update --prune >/dev/null 2>&1
  after="$(git --git-dir="$MIRROR" rev-parse main 2>/dev/null || echo none)"
  if [ "$after" = none ]; then
    bad "mirror" "cannot read $MIRROR — the status answer path has no record"
  elif [ "$before" != "$after" ]; then
    bad "mirror" "record mirror was STALE (was ${before:0:7}, now ${after:0:7}) — status answers were wrong"
  else
    ok "mirror" "record mirror current with GitHub (${after:0:7})"
  fi
fi

# --- what RUNS must exist in the record ----------------------------------
# The check that would have caught the slack-bridge relay. A dirty-tree check
# cannot: those files live outside every working tree, so git status is clean
# and honest while production is unrecorded. Compare the running bytes against
# the committed bytes instead — the only question that actually matters.
echo
MANIFEST="$HERE/deployed-artifacts.tsv"
declare -A RECORD=( [agent-os]=/opt/agent-os.git \
                    [slack-bridge]=/srv/git/slack-bridge.git \
                    [proxmox-dashboard]=/srv/git/proxmox-dashboard.git )
if [ ! -f "$MANIFEST" ]; then
  bad "deploy" "no deployed-artifacts.tsv — nothing asserts that what runs is recorded"
else
  while IFS=$'\t' read -r hostpath key repopath; do
    case "${hostpath:-}" in ''|\#*) continue ;; esac
    [ -n "${repopath:-}" ] || { bad "deploy" "malformed manifest line: $hostpath"; continue; }
    gd="${RECORD[$key]:-}"
    [ -n "$gd" ] || { bad "deploy" "$hostpath names unknown repo key '$key'"; continue; }
    sudo -n test -e "$hostpath" 2>/dev/null || { ok "deploy" "$(basename "$hostpath") not installed here"; continue; }
    live="$(sudo -n sha256sum "$hostpath" 2>/dev/null | cut -d" " -f1)"
    rec="$(git --git-dir="$gd" show "HEAD:$repopath" 2>/dev/null | sha256sum | cut -d" " -f1)"
    if [ -z "$rec" ] || ! git --git-dir="$gd" cat-file -e "HEAD:$repopath" 2>/dev/null; then
      bad "deploy" "$hostpath RUNS BUT IS IN NO REPO ($key:$repopath missing) — nothing to inspect"
    elif [ "$live" = "$rec" ]; then
      ok "deploy" "$(basename "$hostpath") matches $key:$repopath"
    else
      bad "deploy" "$hostpath DIFFERS from $key:$repopath — host and record disagree"
    fi
  done < "$MANIFEST"
fi

# --- WR-012: the eric deploy grant is EXACTLY what ADR-0002 says ----------
# The first agent grant that MUTATES prod, so its bound is asserted here rather
# than trusted — the evidence for the grant does NOT rest on Eric's word (Eric
# verifies a grant that empowers Eric; this and `sudo -n -l -U eric` are the
# third-party checks anyone can run). ABSENT is fine — the pre-WR-012 posture, as
# with any not-yet-installed manifest artifact. PRESENT-BUT-WRONG fails loud:
# broader, narrower, tampered, or drifted (criterion 5).
echo
# Resolve the deploy grant's config the SAME way `deploy` does (deploy:43-53): the
# operator's /etc/maegley-deploy.conf may relocate the substrate mirror and the
# allowlist path at provision time, and both are env-overridable. This is also the
# criterion-5 testability hook: a reviewer can point SUBSTRATE_GIT at a SCRATCH bare
# repo (a tampered / OUT-target / empty allowlist) and confirm check #4 "fails loud"
# WITHOUT loosening the live grant/sudoers/mirror — which QA and the operator must
# never do (ADR-0002 §Consequences). Unset → the authoritative /opt/agent-os.git,
# the same repo `deploy` is bounded by, so doctor and deploy cannot disagree.
DEPLOY_CONF="${DEPLOY_CONF:-/etc/maegley-deploy.conf}"
conf_substrate=""; conf_allow=""
if [ -r "$DEPLOY_CONF" ]; then
  conf_substrate="$(. "$DEPLOY_CONF" >/dev/null 2>&1; printf '%s' "${SUBSTRATE_GIT:-}")"
  conf_allow="$(. "$DEPLOY_CONF" >/dev/null 2>&1; printf '%s' "${ALLOW_PATH:-}")"
fi
SUBSTRATE_GIT="${SUBSTRATE_GIT:-${conf_substrate:-/opt/agent-os.git}}"
ALLOW_PATH="${ALLOW_PATH:-${conf_allow:-provisioning/eric-deployable.allow}}"

DEPLOY_WRAPPER=/usr/local/bin/deploy
if ! sudo -n test -e "$DEPLOY_WRAPPER" 2>/dev/null; then
  ok "deploy" "eric deploy grant not installed here (pre-WR-012 posture)"
else
  # 1. `sudo -n -l -U eric` lists the deploy grant and nothing BROADER — no
  #    wildcard, no general sudo, no third entry (criterion 2). The bound is "no
  #    broader power", NOT "no other line": every agent also holds the pre-existing
  #    `(root) NOPASSWD: /usr/local/bin/notify` grant, which is not part of this
  #    grant's surface — tolerate it, and only it. Assert the deploy line is
  #    present exactly and that nothing beyond it and the shared notify grant appears.
  # Fixture hook (criterion-5 testability): a reviewer may feed a CANNED `sudo -l`
  # transcript via ERIC_SUDO_L_FIXTURE=<file> to exercise the "broader / drifted /
  # tampered grant fails loud" half against a SIMULATED grant, WITHOUT loosening the
  # live sudoers (which QA and the operator must never do). Unset → the live grant.
  if [ -n "${ERIC_SUDO_L_FIXTURE:-}" ]; then
    sudo_l_out="$(cat "$ERIC_SUDO_L_FIXTURE" 2>/dev/null || true)"
  else
    sudo_l_out="$(sudo -n -l -U eric 2>/dev/null || true)"
  fi
  runlines="$(printf '%s\n' "$sudo_l_out" | sed -n '/may run the following/,$p' | grep -E '^[[:space:]]*\(' || true)"
  deploy_re='\(deploy-svc\)[[:space:]]+NOPASSWD:[[:space:]]+/usr/local/bin/deploy$'
  notify_re='\(root\)[[:space:]]+NOPASSWD:[[:space:]]+/usr/local/bin/notify$'
  broader="$(printf '%s\n' "$runlines" | grep -vE "$deploy_re" | grep -vE "$notify_re" | grep -c . || true)"
  if printf '%s\n' "$runlines" | grep -qE "$deploy_re" && [ "${broader:-0}" -eq 0 ]; then
    ok "deploy" "eric grant is exactly (deploy-svc) NOPASSWD: /usr/local/bin/deploy (plus the shared notify grant)"
  else
    bad "deploy" "eric sudo grant WRONG — deploy line missing or a BROADER/DRIFTED grant present: $(printf '%s' "$runlines" | tr '\n' '|')"
  fi

  # 2. The wrapper is deploy-svc/root-owned and NOT eric-writable — a mediated
  #    command Eric could rewrite is not mediated at all.
  own="$(sudo -n stat -c '%U' "$DEPLOY_WRAPPER" 2>/dev/null)"
  case "$own" in
    root|deploy-svc) ok "deploy" "wrapper owned by $own" ;;
    *) bad "deploy" "wrapper owned by '$own' — must be root or deploy-svc" ;;
  esac
  sudo -n -u eric test -w "$DEPLOY_WRAPPER" 2>/dev/null \
    && bad "deploy" "wrapper is ERIC-WRITABLE — eric could rewrite the mediated command" \
    || ok "deploy" "wrapper not eric-writable"

  # 3. The deploy-svc credential/state is unreadable by eric — root/deploy-svc
  #    holds the secret, the agent never sees it (the credential rule).
  for p in /var/lib/deploy/state /var/lib/deploy/program; do
    sudo -n test -e "$p" 2>/dev/null || continue
    sudo -n -u eric test -r "$p" 2>/dev/null \
      && bad "deploy" "$p is ERIC-READABLE — deploy-svc credential/state exposed" \
      || ok "deploy" "$(basename "$p") unreadable by eric"
  done

  # 4. The allowlist that BOUNDS the grant contains NO out-of-bound target. The
  #    authoritative source is the SAME substrate git record `deploy` itself reads
  #    (deploy:112 — `git -C "$SUBSTRATE_GIT" show "HEAD:$ALLOW_PATH"`, parsed
  #    comments-stripped, whitespace-split, bare keys), resolved here through the very
  #    same $SUBSTRATE_GIT/$ALLOW_PATH config (env / deploy.conf), NOT any host file:
  #    a host `.allow` is not consumed by anything, so asserting it would guard the
  #    wrong place. The bound rides the mirror doctor already proves running==committed
  #    against, so it cannot silently grow to an OUT target without a recorded commit
  #    (§2, criterion 3).
  ALLOW_REC="$(git --git-dir="$SUBSTRATE_GIT" show "HEAD:$ALLOW_PATH" 2>/dev/null \
                 | sed -E 's/#.*//' | tr -s ' \t' '\n' | grep -E '^[a-z0-9._-]+$' || true)"
  if [ -z "$ALLOW_REC" ]; then
    bad "deploy" "no eric-deployable allowlist in the substrate record — deploy would refuse everything; bound unverifiable"
  elif printf '%s\n' "$ALLOW_REC" | grep -qxE 'agent-os|ha-ops'; then
    bad "deploy" "substrate allowlist contains an OUT target ($(printf '%s\n' "$ALLOW_REC" | grep -xE 'agent-os|ha-ops' | tr '\n' ' ')) — must stay human-gated"
  else
    ok "deploy" "substrate allowlist bounded [$(printf '%s' "$ALLOW_REC" | tr '\n' ' ')] — no OUT target"
  fi
fi

# --- conversational surface + token survival (WR-013, ADR-0010) --------------
# The runtime half (conversation-runner + its .path unit) and the token keep-alive
# timer that lets a weekly-talked-to Todd survive quiet periods (ADR-0010 §6). Both
# are SHIP-GATED (WR-011 approve path + WR-009 §6.11), so ABSENCE is expected before
# enable — reported, not failed. HEALTH is asserted once installed, "as doctor does
# the other units" (ADR-0010 Handoff §3).
CR_BIN=/usr/local/sbin/conversation-runner
if [ -x "$CR_BIN" ]; then
  if systemctl is-enabled slack-bridge-conversation-runner.path >/dev/null 2>&1; then
    ok "todd" "conversation-runner installed and its .path unit enabled"
  else
    bad "todd" "conversation-runner installed but its .path unit is NOT enabled — conversational turns will not fire"
  fi
else
  ok "todd" "conversational surface not installed (expected until WR-011/WR-009 ship-gates clear)"
fi

if systemctl cat maegley-token-keepalive.timer >/dev/null 2>&1; then
  if systemctl is-active maegley-token-keepalive.timer >/dev/null 2>&1; then
    ok "todd" "token keep-alive timer active — quiet-period expiry mitigated"
  else
    bad "todd" "token keep-alive timer installed but NOT active — tokens will age out in quiet periods (WR-013 crit 8)"
  fi
else
  ok "todd" "token keep-alive timer not installed — quiet-period token expiry UNMITIGATED (WR-013/ADR-0010 §6); the expiry check above is the only backstop"
fi

# --- WR-014/ADR-0011: an active credit hold is EXPECTED, not a fault ----------
# A hold pauses dispatch until credits return; it is correct behaviour, so this is
# an `ok` line (never `bad`) — it must NOT flip doctor's exit code, or the daily
# sweep would escalate every credit block to #ops-prod as a false alarm (spec
# §5.6, ADR-0011 §7). The shared hold state lives in steve's MAEGLEY_STATE (0700),
# so read it directly when doctor runs as steve, else via sudo (run by the sweep
# as todd). Absence => no hold => no line, exactly as when idle.
echo
HOLDFILE="${MAEGLEY_STATE:-/home/steve/.local/state/maegley}/credit-hold"
hreset="$( { cat "$HOLDFILE" 2>/dev/null || sudo -n cat "$HOLDFILE" 2>/dev/null; } | head -1 )"
if [[ "$hreset" =~ ^[0-9]+$ ]] && [ "$(date +%s)" -lt "$hreset" ]; then
  ok "dispatch" "credit hold ACTIVE — dispatch paused until $(date -d "@$hreset" '+%Y-%m-%d %H:%M %Z') (credits exhausted); expected, not a fault"
fi

echo
if [ "$FAIL" = 0 ]; then
  echo "all invariants hold"
else
  echo "FAILURES:"; printf '%s' "$REPORT"
fi
exit "$FAIL"
