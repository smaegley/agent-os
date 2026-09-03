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

# Time since an identity last had its token ACTUALLY renewed, read from the
# keep-alive journal (WR-019 Defect 1). This reads only the honest post-Defect-3
# line — `token-keepalive: refreshed '<agent>' (+Nh)` is logged solely on a real
# expiresAt advance — so it cannot be fooled by a no-op run. Purely informational:
# it enriches the ok line and never affects the exit code. Empty if unavailable.
agent_last_renewal() {
  local out when
  out="$(journalctl -u maegley-token-keepalive.service --no-pager -o short-unix 2>/dev/null \
         || sudo -n journalctl -u maegley-token-keepalive.service --no-pager -o short-unix 2>/dev/null)"
  when="$(printf '%s\n' "$out" | grep -F "token-keepalive: refreshed '$1'" | tail -1 | awk '{print $1}')"
  [ -n "$when" ] || return 0
  echo "$(( ( $(date +%s) - ${when%.*} ) / 3600 ))h ago"
}

echo "agent org doctor — $(date '+%Y-%m-%d %H:%M')"

SUBSTRATE_HEAD="$(git -C "$MIRROR" rev-parse HEAD 2>/dev/null || echo unknown)"
[ "$SUBSTRATE_HEAD" = unknown ] && bad "mirror" "no substrate mirror at $MIRROR"

for a in $(agent_list); do
  # --- identity ------------------------------------------------------------
  # Assert on the credential that actually predicts failure — the REFRESH token —
  # not the disposable access token (WR-019 Defect 1). The access token lives ~8h
  # and the keep-alive timer is DAILY (Steve's 2026-08-26 cost ruling), so every
  # identity is EXPECTED to hold an expired access token for most of each day. That
  # is by design and harmless: as long as the refresh credential is live, the next
  # keep-alive fire re-mints the access token from it with no interactive login.
  # What actually ends in a browser login is a MISSING refresh credential (the
  # 2026-08-22→25 outage killed the fleet by killing the refresh credential through
  # multi-day silence, NOT by letting access tokens expire). So that is the only
  # condition this fails loudly on. The prior check alarmed on the expired access
  # token every single night and advised a re-login that cost six real browser
  # logins on 2026-08-25 (STATE.md).
  if ! sudo -n test -f "/home/$a/.claude/.credentials.json"; then
    bad "$a" "not authenticated — cannot be dispatched"
  else
    have_refresh="$(sudo -n grep -oE '"refreshToken":"[^"]+"' "/home/$a/.claude/.credentials.json" 2>/dev/null | head -1)"
    exp="$(sudo -n grep -oE '"expiresAt":[0-9]+' "/home/$a/.claude/.credentials.json" 2>/dev/null | head -1 | cut -d: -f2)"
    now_ms=$(( $(date +%s) * 1000 ))
    if [ -z "$have_refresh" ]; then
      bad "$a" "REFRESH CREDENTIAL MISSING — token cannot be renewed; needs interactive re-login"
    else
      # Refresh credential present ⇒ healthy. The access-token line below is
      # observability only; expired-between-fires is normal and stays ok.
      if [ -z "$exp" ]; then
        acc="access expiry not recorded"
      elif [ "$exp" -le "$now_ms" ]; then
        acc="access token expired $(( (now_ms - exp) / 3600000 ))h ago — expected between keep-alive fires"
      else
        acc="access token valid $(( (exp - now_ms) / 3600000 ))h"
      fi
      renewed="$(agent_last_renewal "$a")"
      ok "$a" "refresh credential live${renewed:+, last renewed $renewed}; $acc"
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
  # Three distinct cases, kept distinct (WR-019 Defect 2). Collapsing "AHEAD of the
  # mirror" into "stale" via a failed subtraction printed a literal `?` and told the
  # operator to catch up when the truth was the reverse — an unpublished commit the
  # mirror had never seen, i.e. the publish gap. The AHEAD branch NAMES that gap and
  # the action it implies (merge, then publish-substrate.sh), which is the opposite of
  # what "stale" implies. No `?` can reach a bad line: the count runs only once the
  # commit is confirmed a known ancestor, so it always yields a real integer.
  if sudo -n test -d "/home/$a/work/agent-os/.git"; then
    h="$(agent_git "$a" agent-os rev-parse HEAD 2>/dev/null)"
    if [ -z "$h" ]; then
      bad "$a" "cannot read agent-os HEAD — clone may be broken"
    elif [ "$h" = "$SUBSTRATE_HEAD" ]; then
      ok "$a" "substrate current"
    elif ! git -C "$MIRROR" cat-file -e "$h" 2>/dev/null; then
      bad "$a" "substrate AHEAD — unpublished commit ${h:0:7}, needs merge + publish-substrate.sh"
    elif git -C "$MIRROR" merge-base --is-ancestor "$h" "$SUBSTRATE_HEAD" 2>/dev/null; then
      n="$(git -C "$MIRROR" rev-list --count "$h..$SUBSTRATE_HEAD" 2>/dev/null)"
      if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt 0 ]; then
        bad "$a" "substrate $n commits stale — running outdated skills"
      else
        bad "$a" "substrate behind mirror at ${h:0:7} — running outdated skills"
      fi
    else
      bad "$a" "substrate DIVERGED from mirror (agent at ${h:0:7}, mirror at ${SUBSTRATE_HEAD:0:7}) — needs reconcile"
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

# --- WR-023 / ADR-0013: front-matter validation present, consistent, honest ---
# The write-time hook (validate-frontmatter.sh) catches a bad machine-matched field
# at commit. doctor is the backstop for a --no-verify bypass or an item committed
# before the hook existed, AND the ONLY host that can run the anti-drift consistency
# checks: it lives where lib-dispatch.sh, approve, intent, and the roster co-exist,
# while the hook fires in an arbitrary clone that may have none of them. ABSENT is
# fine — the validator is operator-installed substrate (ADR-0013 Handoff); PRESENT
# is asserted. Every check that cannot run on THIS host degrades to an ok "skipped"
# line, never a bad one — a cry-wolf backstop gets ignored (secret-scan.sh:21).
echo
FMV="$HERE/../plugins/maegley-core/hooks/validate-frontmatter.sh"
PROGRAM_REC="${MAEGLEY_PROGRAM:-/home/steve/maegley-lab/program}"
if [ ! -x "$FMV" ]; then
  ok "frontmatter" "validator not yet installed (ADR-0013 substrate pending operator install)"
else
  fmcfg="$("$FMV" --config 2>/dev/null || true)"
  if [ -z "$fmcfg" ]; then
    bad "frontmatter" "validator present but --config failed — cannot source lib-dispatch.sh to derive the state enum"
  else
    v_owners="$(printf '%s\n' "$fmcfg" | sed -n 's/^OWNERS=//p')"

    # (a) corpus sweep — no bad record already sitting in the tree (crit 6; live
    #     projects/*/WR-*.md, one level, which excludes archive/ and artifacts/).
    if [ -d "$PROGRAM_REC/projects" ]; then
      nf="$("$FMV" --files "$PROGRAM_REC"/projects/*/WR-*.md 2>/dev/null | grep -c 'front-matter:' || true)"
      if [ "${nf:-0}" -eq 0 ]; then
        ok "frontmatter" "live corpus clean — every record's machine-matched fields are valid"
      else
        bad "frontmatter" "${nf} bad field(s) in the live corpus — run: $FMV --files $PROGRAM_REC/projects/*/WR-*.md"
      fi
    else
      ok "frontmatter" "program corpus not on this host — sweep skipped"
    fi

    # (b) token regex three-way: validator == approve == slackbridge/intent (ADR-0013 D4).
    #     Compare the anchor-agnostic regex CORE so \A..\Z / ^..$ / unanchored do not read
    #     as drift. This folds the flagged approve<->intent duplication into a checked one.
    _core='WR-\[0-9\]\{[0-9,]+\}-\[A-Za-z0-9\]\{[0-9,]+\}-\[A-Za-z0-9\]\{[0-9,]+\}'
    APPROVE_BIN="$(command -v approve 2>/dev/null || echo /usr/local/bin/approve)"
    INTENT_SRC="${MAEGLEY_SLACKBRIDGE:-/home/steve/work/slack-bridge}/slackbridge/intent.py"
    v_tok="$(grep -oE "$_core" "$FMV"        2>/dev/null | head -1)"
    a_tok="$(grep -oE "$_core" "$APPROVE_BIN" 2>/dev/null | head -1)"
    i_tok="$(grep -oE "$_core" "$INTENT_SRC"  2>/dev/null | head -1)"
    if [ -z "$a_tok" ] || [ -z "$i_tok" ]; then
      ok "frontmatter" "token-regex cross-check skipped (approve/intent not on this host)"
    elif [ "$v_tok" = "$a_tok" ] && [ "$a_tok" = "$i_tok" ]; then
      ok "frontmatter" "token regex agrees: validator == approve == intent"
    else
      bad "frontmatter" "token regex DRIFT — validator[$v_tok] approve[$a_tok] intent[$i_tok] disagree"
    fi

    # (c) owner set == provisioned agents (ADR-0013 D4). Validator OWNERS minus the two
    #     non-agent literals (steve, unassigned) must equal the roster the machine dispatches to.
    v_agents="$(printf '%s\n' $v_owners | grep -vxE 'steve|unassigned' | sort -u | tr '\n' ' ' | sed 's/ *$//')"
    prov="$(agent_list | sort -u | tr '\n' ' ' | sed 's/ *$//')"
    if [ -z "$prov" ]; then
      ok "frontmatter" "owner cross-check skipped (roster unreadable on this host)"
    elif [ "$v_agents" = "$prov" ]; then
      ok "frontmatter" "owner set == provisioned agents ($prov)"
    else
      bad "frontmatter" "owner set DRIFT — validator agents[$v_agents] != provisioned[$prov]"
    fi

    # (d) AGENTS.md's state table is CHECKED documentation of route(), not a third source
    #     of truth (ADR-0013 D4). The table is a curated SUBSET, so assert containment: every
    #     token it documents must be a legal state, else the human doc has drifted from the machine.
    v_states=" $(printf '%s\n' "$fmcfg" | sed -n 's/^LEGAL_STATES=//p') "
    ROSTER="${AGENT_OS:-/home/steve/maegley-lab/agent-os}/AGENTS.md"
    doc_bad=""
    while IFS= read -r st; do
      [ -n "$st" ] || continue
      case "$v_states" in *" $st "*) : ;; *) doc_bad="$doc_bad $st" ;; esac
    done < <(grep -E '^\| `[a-z-]+` \|' "$ROSTER" 2>/dev/null | sed -E 's/^\| `([a-z-]+)`.*/\1/')
    if [ ! -r "$ROSTER" ]; then
      ok "frontmatter" "AGENTS.md state-table cross-check skipped (roster not on this host)"
    elif [ -z "$doc_bad" ]; then
      ok "frontmatter" "AGENTS.md state table ⊆ route() — human doc agrees with the machine"
    else
      bad "frontmatter" "AGENTS.md documents state(s) route() does not accept:$doc_bad — doc drifted from the machine"
    fi
  fi
fi

echo

# --- loaded-process freshness -----------------------------------------------
# running==committed is asserted for FILES; a long-running process that loaded an
# older copy passes every file check while behaving like the old code. That gap
# turned a published credit-hold fix into 44 wasted dispatches on 2026-08-26.
_wu=maegley-dispatch-watch.service
if systemctl is-active --quiet "$_wu" 2>/dev/null; then
  _st="$(date -d "$(systemctl show "$_wu" -p ActiveEnterTimestamp --value)" +%s 2>/dev/null || echo 0)"
  _nw=0
  for _f in "$HERE/watch-dispatch.sh" "$HERE/lib-dispatch.sh"; do
    [ -f "$_f" ] || continue
    _m="$(stat -c %Y "$_f" 2>/dev/null || echo 0)"
    [ "$_m" -gt "$_nw" ] && _nw="$_m"
  done
  if [ "$_nw" -gt "$_st" ]; then
    bad "watcher" "running code OLDER than the checked-out dispatcher ($(( (_nw-_st)/60 ))m stale) — restart maegley-dispatch-watch"
  else
    ok "watcher" "running current dispatcher code"
  fi
fi

if [ "$FAIL" = 0 ]; then
  echo "all invariants hold"
else
  echo "FAILURES:"; printf '%s' "$REPORT"
fi
exit "$FAIL"
