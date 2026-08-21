#!/usr/bin/env bash
# lib-dispatch.sh — the one place routing and the *act* of dispatching live.
#
# WHY THIS EXISTS (WR-009 / ADR-0001): dispatch used to be a single 15-minute
# cron run, and that run was quietly the concurrency control — "one run at a
# time (whole-run flock), capped per run (MAX_DISPATCH), one dispatch per agent
# per run (the in-memory BUSY set)." WR-009 replaces the batch with an
# event-driven watcher that reacts to origin moving, plus a low-frequency
# reconcile sweep as the backstop. The moment there is more than one thing that
# can dispatch — the watcher, the reconcile timer, and (during cutover) the old
# cron — those per-run guarantees evaporate unless they are re-expressed as
# CROSS-PROCESS guards that all dispatchers share. That shared substrate is here.
#
# The model (ADR-0001 §2): there is exactly ONE serialized dispatch path.
#   * flock re-scoped to "perform one dispatch DECISION", not "one whole run",
#     so the watcher is not blocked for 30 minutes behind a running agent.
#   * the running.d/<id> marker (which the board already reads) is the mutex
#     substrate: written under the lock, it is what the item-busy, per-agent, and
#     in-flight-cap checks all count. Board truth and mutex are the same fact.
#   * a per-item dispatch record (dispatched.d/<id> = last-dispatched state)
#     kills self-triggering and gives debounce for free: an agent committing its
#     own state change + evidence does not re-dispatch itself, and several
#     commits for one logical transition dispatch once.
#
# route() and the per-item guards are IDENTICAL to the batch's — WR-009 changes
# WHEN dispatch fires, never WHERE items go (spec §3/§8). This file is sourced
# by dispatch.sh (the reconcile/backstop) and watch-dispatch.sh (the watcher);
# both call evaluate_item(), so the routing table cannot drift between them.
#
# NB: values the ADR left to the implementer are pinned in ENV-overridable
# defaults below and documented in provisioning/EVENT-DISPATCH.txt. Every fact
# carried from the work request about the batch (AGENT_TIMEOUT=1800, the
# running.d location, terminal states) was confirmed against dispatch.sh before
# this was written; Eric re-confirms against the running dispatcher per §6.16.

# ---------------------------------------------------------------------------
# Config — the design-detail values ADR-0001 §7 left to the implementer.
# ---------------------------------------------------------------------------
REPO="${PROGRAM_REPO:-/home/steve/maegley-lab/program}"
STATE_DIR="${MAEGLEY_STATE:-/home/steve/.local/state/maegley}"
RUNDIR="$STATE_DIR/running.d"          # per-item live markers — the board reads these
RECDIR="$STATE_DIR/dispatched.d"       # per-item last-dispatched-state — anti self-trigger
HWM="$STATE_DIR/watch-last-commit"     # watcher high-water mark (last processed origin SHA)
HEARTBEAT="$STATE_DIR/watch-heartbeat" # watcher liveness; aged out by the reconcile health probe
LOCK="${DISPATCH_LOCK:-/tmp/maegley-dispatch.lock}"   # same lock the batch used, re-scoped

MAX_INFLIGHT="${MAX_INFLIGHT:-${MAX_DISPATCH:-2}}"   # cascade cap, was MAX_DISPATCH=2 per run
AGENT_TIMEOUT="${AGENT_TIMEOUT:-1800}"               # confirmed against dispatch.sh L55
MARKER_TTL="${MARKER_TTL:-$AGENT_TIMEOUT}"           # a marker older than this is a crash orphan
RECORD_TTL_DAYS="${RECORD_TTL_DAYS:-7}"              # prune stale dispatch records after N days

WORK_TZ="${WORK_TZ:-America/Denver}"
WORK_START="${WORK_START:-7}"; WORK_END="${WORK_END:-20}"   # inclusive, matches dispatch.sh

DRY_RUN="${DRY_RUN:-0}"                 # compute + report, touch nothing
DISPATCH_SHADOW="${DISPATCH_SHADOW:-0}" # cutover stage 1: decide + log, dispatch NOTHING

# Populated by evaluate_item for the caller to report on.
EV_STATUS=""; EV_WHO=""; EV_REASON=""

dispatch_state_init() { mkdir -p "$RUNDIR" "$RECDIR" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# Front-matter readers. dispatch.sh reads the local working copy; the watcher
# reads git objects at a fixed pushed SHA (never a live working copy — that is
# how write-during-read is eliminated, ADR §3).
# ---------------------------------------------------------------------------
fm()      { sed -n '2,/^---$/p' "$2" | grep -E "^$1:" | head -1 | cut -d: -f2- | xargs; }
fm_blob() { # fm_blob <field> <commit> <path> [gitdir-repo]
  git -C "${4:-$REPO}" show "$2:$3" 2>/dev/null \
    | sed -n '2,/^---$/p' | grep -E "^$1:" | head -1 | cut -d: -f2- | xargs; }

# ---------------------------------------------------------------------------
# route() — state → who acts next. VERBATIM from dispatch.sh. Terminal/stop
# states are absent on purpose (they echo ""); unknown states echo UNKNOWN.
# This is the routing table WR-009 must not touch.
# ---------------------------------------------------------------------------
route() {  # state infra uf adr owner
  case "$1" in
    new)            echo theresa ;;
    spec-ready)     { [ "$2" = true ] || [ "$4" = true ]; } && echo john || echo randal ;;
    design-ready)   echo randal ;;
    env-needed)     echo ken ;;
    token-needed)   echo "" ;;
    qa-ready|qa-prep|built) echo eric ;;
    # needs-exec is where the machine says "an operator must act" (AGENTS.md). WR-011
    # gives that operator a runtime: an item explicitly routed to Todd (owner=todd) is
    # dispatched to him and its non-destructive steps run unattended; every other owner
    # (steve, unassigned) still STOPS here — visibly waiting on a human, exactly as
    # before. Todd himself escalates a prod-touching step by setting owner=steve (the
    # unchanged "waiting on Steve" expression), and the release-only `approve` command
    # (slack-bridge, ADR-0008) flips it back to owner=todd, which re-dispatches him.
    #
    # WR-012/ADR-0002 adds ONE more owner to the same shape: an approved deploy of an
    # eric-deployable app resumes ERIC (owner=eric), who invokes `deploy`. This is the
    # deploy step landing on exactly one role by target class — Eric for the disposable
    # apps, Todd for every OUT target — with no new state and no new routing target
    # beyond the two owners. The parked-at-stop record-clear in evaluate_item (scoped to
    # needs-exec) already makes the steve→eric owner-flip re-dispatch, same as steve→todd.
    needs-exec)     case "$5" in todd) echo todd ;; eric) echo eric ;; *) echo "" ;; esac ;;
    hold)           echo "" ;;
    adr-needed)     echo john ;;
    qa-passed)      [ "$3" = true ] && echo andrea || echo "" ;;
    uat-passed)     echo "" ;;
    *)              echo "UNKNOWN" ;;
  esac
}
KNOWN_TERMINAL="needs-exec token-needed qa-passed uat-passed accepted done hold"

within_work_hours() {
  [ "${IGNORE_HOURS:-0}" = "1" ] && return 0
  local h; h="$(TZ="$WORK_TZ" date +%-H)"
  [ "$h" -ge "$WORK_START" ] && [ "$h" -le "$WORK_END" ]
}

# ---------------------------------------------------------------------------
# Cross-process guards. All counting reads running.d, which is written only
# under the dispatch lock, so a check-then-set inside the locked section is
# atomic by virtue of the single serialized path (ADR §2).
# ---------------------------------------------------------------------------
_marker_fresh() { # $1=marker file — true if it exists and is younger than MARKER_TTL
  [ -f "$1" ] || return 1
  local ts; ts="$(awk '{print $2}' "$1" 2>/dev/null)"
  [ -n "$ts" ] || return 1
  [ $(( $(date +%s) - ts )) -lt "$MARKER_TTL" ]
}
item_busy()   { _marker_fresh "$RUNDIR/$1"; }
agent_busy()  { # $1=who — true if any fresh marker is owned by this agent
  local m
  for m in "$RUNDIR"/*; do
    [ -e "$m" ] || continue
    _marker_fresh "$m" || continue
    [ "$(awk '{print $1}' "$m")" = "$1" ] && return 0
  done
  return 1
}
inflight_count() { local n=0 m; for m in "$RUNDIR"/*; do [ -e "$m" ] && _marker_fresh "$m" && n=$((n+1)); done; echo "$n"; }
already_dispatched() { [ -f "$RECDIR/$1" ] && [ "$(cat "$RECDIR/$1" 2>/dev/null)" = "$2" ]; }
record_dispatch()    { printf '%s\n' "$2" > "$RECDIR/$1"; }
write_marker()       { printf '%s %s\n' "$2" "$(date +%s)" > "$RUNDIR/$1"; }

# Reap crash orphans: a marker whose agent was killed between "start" and the
# EXIT-trap cleanup would otherwise wedge that agent's mutex forever. The batch
# never had this hazard (the whole-run flock + wait cleaned up); the re-scoped
# lock does, so the reconcile sweep enforces a TTL (ADR §3, Consequences).
reap_stale_markers() {
  local m
  for m in "$RUNDIR"/*; do
    [ -e "$m" ] || continue
    _marker_fresh "$m" && continue
    echo "$(date -Iseconds) reaped stale marker $(basename "$m")" >> "$REPO/log/dispatch.log" 2>/dev/null || true
    rm -f "$m"
  done
}
prune_records() { find "$RECDIR" -type f -mtime +"$RECORD_TTL_DAYS" -delete 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# resolve_target — apply the routing table and every guard the batch applied,
# EXCEPT the two that differ by caller:
#   * origin-existence: dispatch.sh reads the LOCAL copy and must confirm the
#     item exists on origin (agents pull from origin). The watcher reads AT the
#     pushed tip, so it is satisfied by construction — the crux (ADR §1).
#   * running.d/cap/record: applied later, under the lock, by dispatch_one.
# Echoes the agent on success; otherwise "STOP:<category>:<reason>".
# ---------------------------------------------------------------------------
resolve_target() { # id proj state infra uf adr owner
  local id=$1 proj=$2 state=$3 infra=${4:-false} uf=${5:-false} adr=${6:-false} owner=$7

  [ "$state" = blocked ] && { echo "STOP:blocked:$id [$proj] — blocked, needs Steve"; return; }

  local who; who="$(route "$state" "$infra" "$uf" "$adr" "$owner")"

  if [ "$who" = UNKNOWN ]; then
    case " $KNOWN_TERMINAL " in
      *" $state "*) echo "STOP:stopped:$id [$proj] state=$state — stops here by design" ;;
      *)            echo "STOP:unknown:$id [$proj] state='$state' is NOT A KNOWN STATE — unroutable, likely a typo" ;;
    esac
    return
  fi
  [ -z "$who" ] && { echo "STOP:stopped:$id [$proj] state=$state — stops here by design"; return; }

  # Unprovisioned role — reported, not silently stalled (dispatch.sh L149-157).
  # sudo required: agent homes are 0750, so a bare test false-negatives its own tooling.
  if ! id "$who" >/dev/null 2>&1 || ! sudo -n test -f "/home/$who/.claude/.credentials.json"; then
    echo "STOP:unprovisioned:$id [$proj] state=$state → $who (NOT PROVISIONED)"; return
  fi

  # Owner/state contradiction — routing follows state; a mismatched owner is a
  # self-contradiction the machine holds rather than dispatching wrong (L159-167).
  if [ -n "$owner" ] && [ "$owner" != unassigned ] && [ "$owner" != "$who" ]; then
    echo "STOP:contradiction:$id [$proj] state=$state routes to $who but owner says $owner — contradiction, not dispatched"
    return
  fi

  echo "$who"
}

# ---------------------------------------------------------------------------
# start_agent — the dispatch action itself. The notify + `sudo -u agent` pull +
# `timeout claude -p` + marker cleanup are VERBATIM from dispatch.sh L194-219;
# only the running.d write is gone (dispatch_one already did it under the lock).
# The agent runs backgrounded; the caller does NOT wait, so a reconcile oneshot
# returns in seconds. Both systemd units set KillMode=process, so the detached
# agent survives a service exit/restart; a marker orphaned by an uncleanly-killed
# agent is reaped by MARKER_TTL in the next sweep.
# ---------------------------------------------------------------------------
start_agent() { # id file state who
  local id=$1 f=$2 state=$3 who=$4
  # Steve asked for start visibility explicitly ("I see messages from each
  # person when they start"); completions alone were argued and overruled.
  sudo -n /usr/local/bin/notify '#program' \
    "${who^} starting $id ($state → next step)" >/dev/null 2>&1 || true

  # The session's working directory is `program`, so every SIBLING CLONE is
  # outside the sandbox and unreachable — regardless of what settings.json
  # allows. The prompt below tells the agent its code lives in those clones, so
  # the instruction and the capability contradicted each other: Eric blocked on
  # slack-bridge (2026-08-19), Randal on agent-os (2026-08-19), Randal on both
  # (2026-08-20). Three blocks, one cause, patched individually twice before
  # anyone looked at the class.
  #
  # Pass every clone the agent actually has as --add-dir. This grants TOOL REACH
  # only; the Write/Edit allow+deny rules in the agent's settings.json still
  # decide what may be modified, so the 2026-08-19 substrate boundary (agents may
  # change the machinery, never the rules) is unaffected.
  # ORDER MATTERS: the flags go BEFORE -p. `claude -p` takes the prompt as its
  # next argument, so `claude -p "${ADDDIRS[@]}" "<prompt>"` puts --add-dir where
  # the prompt belongs and dies with "Input must be provided either through stdin
  # or as a prompt argument". Shipped that way 2026-08-20 22:06 and it broke every
  # dispatch for ten hours: the agent exits in under a second, the running.d
  # marker is cleaned up normally, and nothing anywhere reports an error. The
  # board simply showed an item that never moved.
  #
  # Built INSIDE the agent's own shell: /home/<agent> is 0750 and the dispatcher
  # runs as steve, so globbing the agent's work dir from out here silently yields
  # nothing and the flag becomes a no-op — the same shape of failure as the bug
  # it is fixing.
  { sudo -u "$who" bash -lc "cd /home/$who/work/program && git pull -q origin main 2>/dev/null; \
    ADDDIRS=(); for d in \"/home/$who/work\"/*/; do [ -d \"\$d/.git\" ] || continue; \
      case \"\$d\" in */program/) continue ;; esac; ADDDIRS+=( --add-dir \"\${d%/}\" ); done; \
    timeout "$AGENT_TIMEOUT" claude \"\${ADDDIRS[@]}\" -p \"You are ${who^}. Work item ${id} is in state '${state}' and routed to you.

Read ${f} in full, then do YOUR role's part of it — no more.

Project CODE lives in sibling clones under /home/${who}/work/ (e.g. ~/work/ha-ops), not in
the program repo — program holds specs, decisions, and status. The work item names the code it
concerns; if you need a repo you do not have, set state to 'blocked' saying which, and stop. Follow the skills you have
(spec-template if you are writing a spec, definition-of-done before claiming anything complete).

When done, IN THIS ORDER — the order matters, an interrupted run must never leave the state
claiming work that is not committed:
  1. Commit AND PUSH your actual artifact first (code, spec, ADR, evidence) in whichever repo
     it belongs to.
  2. Only then update the item's front-matter 'state:' and 'owner:' in the program repo.
  3. Commit AND PUSH that. Verify with 'git status -sb' that nothing is ahead or dirty in any
     repo you touched — unpushed work is invisible to everyone else and will be re-dispatched.

If you cannot complete it, set state to 'blocked', say why in the item, commit, and stop.
Do not route it onward yourself and do not do another role's work.\" < /dev/null" \
    >> "$REPO/log/dispatch.log" 2>&1 \
      || rm -f "$RECDIR/$id"; rm -f "$RUNDIR/$id"; } &
  # ^ A FAILED agent run clears its dispatch record so the item can be retried.
  # The record is written when dispatch STARTS, so without this a run that dies
  # instantly still marks the transition "done" and suppresses every retry at
  # that state -- permanently and silently, since nothing reports the failure.
  # Hit three times in twelve hours on WR-011 (arg-parsing death, then an expired
  # token, then again after re-auth) and cleared by hand each time. The
  # anti-self-trigger property is unaffected: a SUCCESSFUL run keeps its record,
  # and a run that changes state makes the old record irrelevant anyway.
  disown 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# dispatch_one — the serialized critical section. Re-checks every guard UNDER
# the lock (state may have moved since the caller resolved it), commits the
# decision by writing the marker + record while holding the lock, then releases
# the lock and starts the (long-lived) agent OUTSIDE it. This is what lets the
# watcher, the reconcile timer, and the cutover cron coexist without ever
# double-acting on one item (ADR §2/§6).
#   returns 0 and sets EV_STATUS=routed  when it dispatched (or shadow/dry)
#   returns 1 and sets EV_STATUS=held     when a guard deferred it
# ---------------------------------------------------------------------------
dispatch_one() { # id file state who
  local id=$1 f=$2 state=$3 who=$4 decision
  # The fd-9 redirection MUST be inside the command substitution, on the brace
  # group, so flock locks the subshell's fd — not outside, where it would be
  # string text. flock is blocking here (no -n): a competing dispatcher waits
  # its turn rather than dropping the item on the floor.
  decision="$(
    {
      flock 9 || exit 0
      if item_busy "$id";            then echo "held:$id [$state] → $who (item already running)"; exit 0; fi
      if already_dispatched "$id" "$state"; then echo "held:$id [$state] → $who (already dispatched this transition)"; exit 0; fi
      if agent_busy "$who";          then echo "held:$id [$state] → $who ($who already busy)"; exit 0; fi
      if [ "$(inflight_count)" -ge "$MAX_INFLIGHT" ]; then echo "held:$id [$state] → $who (in-flight cap $MAX_INFLIGHT reached)"; exit 0; fi
      if [ "$DISPATCH_SHADOW" = 1 ]; then echo "shadow:$id [$state] → $who (would dispatch)"; exit 0; fi
      if [ "$DRY_RUN" = 1 ];        then echo "dry:$id [$state] → $who (would dispatch)"; exit 0; fi
      write_marker "$id" "$who"
      record_dispatch "$id" "$state"
      echo "go:$who"
    } 9>"$LOCK"
  )"

  case "$decision" in
    go:*)      start_agent "$id" "$f" "$state" "$who"; EV_STATUS=routed; EV_WHO=$who
               EV_REASON="$id [$state] → $who"; return 0 ;;
    shadow:*)  EV_STATUS=shadow; EV_WHO=$who; EV_REASON="${decision#shadow:}"; return 0 ;;
    dry:*)     EV_STATUS=dry;    EV_WHO=$who; EV_REASON="${decision#dry:}";    return 0 ;;
    held:*)    EV_STATUS=held;   EV_WHO=$who; EV_REASON="${decision#held:}";   return 1 ;;
    *)         EV_STATUS=held;   EV_WHO=$who; EV_REASON="$id lock unavailable"; return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# evaluate_item — resolve + (if routable) dispatch, in one call. The single
# entry point dispatch.sh and the watcher share. Sets EV_STATUS / EV_WHO /
# EV_REASON for the caller to report. The optional check_origin arg is for
# dispatch.sh reading a local copy; the watcher passes "" (already at the tip).
# ---------------------------------------------------------------------------
evaluate_item() { # id proj state infra uf adr owner file [origin_ok]
  local id=$1 proj=$2 state=$3 infra=$4 uf=$5 adr=$6 owner=$7 f=$8 origin_ok=${9:-1}
  local target; target="$(resolve_target "$id" "$proj" "$state" "$infra" "$uf" "$adr" "$owner")"

  case "$target" in
    STOP:blocked:*)       EV_STATUS=blocked;       EV_REASON="${target#STOP:blocked:}";       return 1 ;;
    STOP:stopped:*)
      # WR-011 resume path. Todd's escalate→approve round-trip keeps state=needs-exec and
      # only flips owner (todd→steve on escalate, steve→todd on approve). The anti-self
      # -trigger record keys on STATE alone, so without this the post-approval owner flip
      # would be suppressed as "already dispatched this transition" and Todd would never
      # be re-triggered. When a needs-exec item parks here (owner=steve, waiting), clear
      # its record so the later flip to owner=todd dispatches. This is inert everywhere
      # else: a stopped item is never dispatched, and any OTHER resurrection changes the
      # state (a new fingerprint that dispatches regardless), so only the same-state
      # owner flip depends on it. Scoped to needs-exec to touch nothing else.
      [ "$state" = needs-exec ] && rm -f "$RECDIR/$id" 2>/dev/null || true
      EV_STATUS=stopped;       EV_REASON="${target#STOP:stopped:}";       return 1 ;;
    STOP:unknown:*)       EV_STATUS=unknown;       EV_REASON="${target#STOP:unknown:}";       return 1 ;;
    STOP:unprovisioned:*) EV_STATUS=unprovisioned; EV_REASON="${target#STOP:unprovisioned:}"; return 1 ;;
    STOP:contradiction:*) EV_STATUS=contradiction; EV_REASON="${target#STOP:contradiction:}"; return 1 ;;
  esac

  # Agents pull from origin; an item that exists only in this local copy would
  # send an agent to look for a file that is not there (dispatch.sh L169-175).
  # The watcher never trips this — it reads at the pushed tip.
  if [ "$origin_ok" != 1 ]; then
    EV_STATUS=stopped; EV_REASON="$id [$proj] — not pushed to origin; agents cannot see it"; return 1
  fi

  dispatch_one "$id" "$f" "$state" "$target"
}
