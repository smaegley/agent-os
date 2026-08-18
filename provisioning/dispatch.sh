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
# GUARDS (this is the piece with real runaway potential):
#   * MAX_DISPATCH items per run — a routing bug cannot cascade the backlog.
#   * One transition per item per run — each item is invoked at most once.
#   * Terminal states never dispatch. Anything touching prod stops for Steve.
#   * blocked escalates; it is never auto-routed to an agent.

set -uo pipefail

# Only one dispatch at a time. At a 15-minute cadence with a 30-minute agent
# timeout, overlapping runs are not a risk — they are a certainty. Two runs
# picking up the same item invoke the same agent twice on the same work, which
# is how WR-001 acquired two parallel pairs of commits for one verdict. Eric
# caught it and said so; without the lock it would recur every long run.
# --- working hours, decided here rather than by cron ---------------------------
# cron on this box runs in UTC and ignores CRON_TZ (that is a cronie feature;
# Debian/Ubuntu vixie-cron treats it as an env var for the job). A window
# expressed in crontab hours was therefore UTC no matter what it claimed. This
# guard resolves the zone at run time, so it is right through DST changes too.
WORK_TZ="${WORK_TZ:-America/Denver}"
WORK_START="${WORK_START:-7}"; WORK_END="${WORK_END:-20}"   # inclusive start, inclusive last hour
if [ "${IGNORE_HOURS:-0}" != "1" ]; then
  now_h="$(TZ="$WORK_TZ" date +%-H)"
  if [ "$now_h" -lt "$WORK_START" ] || [ "$now_h" -gt "$WORK_END" ]; then
    exit 0        # outside working hours — silent, this runs every 15 minutes
  fi
fi

LOCK=/tmp/maegley-dispatch.lock
exec 9>"$LOCK"
flock -n 9 || { echo "dispatch: another run holds the lock — skipping"; exit 0; }

REPO="${PROGRAM_REPO:-/home/steve/maegley-lab/program}"
MAX_DISPATCH="${MAX_DISPATCH:-2}"
AGENT_TIMEOUT="${AGENT_TIMEOUT:-1800}"   # code work needs far longer than doc work
DRY_RUN="${DRY_RUN:-0}"
cd "$REPO" || { echo "dispatch: no repo at $REPO" >&2; exit 1; }

git fetch -q origin 2>/dev/null; git merge -q --ff-only origin/main 2>/dev/null || true

fm() { sed -n '2,/^---$/p' "$2" | grep -E "^$1:" | head -1 | cut -d: -f2- | xargs; }

# state → who acts next. Terminal/stop states are absent on purpose.
route() {
  case "$1" in
    new)            echo theresa ;;                       # BA writes the spec
    spec-ready)     [ "$2" = true ] && echo john || echo randal ;;
    design-ready)   echo randal ;;
    env-needed)     echo ken ;;                           # build/refresh a test environment
    token-needed)   echo "" ;;                            # a credential only Todd can mint → stops
    # 'qa-ready' is the agents' own token, not mine. They had no published state
    # vocabulary, so they coined one and used it consistently — Randal even noted
    # "states are convention tokens" in his handoff. Their word wins: it is the one
    # actually written into the work items. 'built' kept as an accepted synonym.
    qa-ready|qa-prep|built) echo eric ;;                          # QA verifies — different access than the builder
    # QA is read-only by design, but some acceptance criteria can only be checked
    # by RUNNING the thing against prod. Rather than widen Eric's access or let him
    # infer a verdict from source, he writes the exact commands and Todd executes
    # them — Eric still never built it and still never guesses. Stops for Steve.
    needs-exec)     echo "" ;;
    qa-passed)      [ "$3" = true ] && echo andrea || echo "" ;;
    uat-passed)     echo "" ;;                            # → Steve approves deploy
    *)              echo "UNKNOWN" ;;
  esac
}

# States the machine deliberately stops on. Anything else is a mistake, not a decision.
KNOWN_TERMINAL="needs-exec token-needed qa-passed uat-passed accepted done"

ROUTED=""; STOPPED=""; BLOCKED=""; UNPROVISIONED=""; n=0

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
  infra="$(fm infra "$f")"; uf="$(fm user_facing "$f")"

  if [ "$state" = blocked ]; then
    BLOCKED+="  $id [$proj] — blocked, needs Steve"$'\n'; continue
  fi

  who="$(route "$state" "${infra:-false}" "${uf:-false}")"
  if [ "$who" = UNKNOWN ]; then
    case " $KNOWN_TERMINAL " in
      *" $state "*) STOPPED+="  $id [$proj] state=$state — stops here by design"$'\n' ;;
      *) STOPPED+="  $id [$proj] state='$state' is NOT A KNOWN STATE — unroutable, likely a typo"$'\n'
         NEEDS_STEVE+="  $id — state '$state' is not in the state machine; Todd to correct"$'\n' ;;
    esac
    continue
  fi
  if [ -z "$who" ]; then
    STOPPED+="  $id [$proj] state=$state — stops here by design"$'\n'
    continue
  fi

  # An unprovisioned role is reported, not silently stalled. This is how the
  # backlog tells you which agent to provision next — driven by real work
  # rather than by guessing at the roster up front.
  # Must use sudo to test: agent homes are 0750, so even the dispatcher cannot
  # stat them directly. Testing without it silently reports every provisioned
  # agent as missing — the boundary false-negatives its own tooling.
  if ! id "$who" >/dev/null 2>&1 || ! sudo -n test -f "/home/$who/.claude/.credentials.json"; then
    UNPROVISIONED+="  $id [$proj] state=$state → $who (NOT PROVISIONED)"$'\n'; continue
  fi

  # An agent that sets owner: john and state: design-ready has contradicted
  # itself — the state routes to randal. Routing follows state, so the item
  # lands on the wrong desk and burns a run. Third occurrence; hold instead.
  declared="$(fm owner "$f")"
  if [ -n "$declared" ] && [ "$declared" != unassigned ] && [ "$declared" != "$who" ]; then
    STOPPED+="  $id [$proj] state=$state routes to $who but owner says $declared — contradiction, not dispatched"$'\n'
    NEEDS_STEVE+="  $id — state '$state' and owner '$declared' disagree; Todd to resolve"$'\n'
    continue
  fi

  # Agents pull from origin; the dispatcher reads the local working copy. An
  # item that exists only locally dispatches an agent to look for a file that
  # is not there — which is exactly what happened on the first live run.
  if ! git cat-file -e "origin/main:$f" 2>/dev/null; then
    STOPPED+="  $id [$proj] — not pushed to origin; agents cannot see it"$'\n'
    continue
  fi

  case " ${BUSY:-} " in *" $who "*)
    STOPPED+="  $id [$proj] state=$state → $who (held: $who already dispatched this run)"$'\n'
    continue ;;
  esac

  if [ "$n" -ge "$MAX_DISPATCH" ]; then
    STOPPED+="  $id [$proj] state=$state → $who (deferred: run cap $MAX_DISPATCH reached)"$'\n'
    continue
  fi

  ROUTED+="  $id [$proj] state=$state → $who"$'\n'
  BUSY="${BUSY:-} $who"
  n=$((n+1))
  [ "$DRY_RUN" = "1" ] && continue

  # Steve asked for start visibility explicitly: "I see messages from each
  # person when they start". I argued completions were enough; he overruled.
  sudo -n /usr/local/bin/notify '#program' \
    "${who^} starting $id ($state → next step)" >/dev/null 2>&1 || true
  RUNDIR=/home/steve/.local/state/maegley/running.d; mkdir -p "$RUNDIR"
  printf '%s %s\n' "$who" "$(date +%s)" > "$RUNDIR/$id"

  { sudo -u "$who" bash -lc "cd /home/$who/work/program && git pull -q origin main 2>/dev/null; \
    timeout "$AGENT_TIMEOUT" claude -p \"You are ${who^}. Work item ${id} is in state '${state}' and routed to you.

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
    >> "$REPO/log/dispatch.log" 2>&1; rm -f "$RUNDIR/$id"; } &
done
wait

# An exit code is not evidence of work done. A run killed mid-sequence leaves
# commits unpushed and files uncommitted, and reports success — which is exactly
# how WR-001 came to sit at qa-ready locally with its code uncommitted elsewhere.
for who in $(echo "$ROUTED" | grep -oE '→ [a-z]+' | cut -d' ' -f2 | sort -u); do
  for r in program ha-ops agent-os; do
    d="/home/$who/work/$r"; sudo -n test -d "$d/.git" || continue
    dirty=$(sudo -n -u "$who" git -C "$d" status --porcelain 2>/dev/null | head -3)
    ahead=$(sudo -n -u "$who" git -C "$d" status -sb 2>/dev/null | grep -o 'ahead [0-9]*')
    [ -n "$dirty$ahead" ] && STOPPED+="  $who: $r left ${ahead:-dirty} — work not visible to others"$'\n'
  done
done

# What actually changed on origin — the only honest report of a run.
git fetch -q origin 2>/dev/null; git merge -q --ff-only origin/main 2>/dev/null || true
LANDED=""; NEEDS_STEVE=""
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
  # An item that stops needing agents starts needing Steve — say so plainly
  # rather than letting it sit silently in HELD looking parked.
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
  # A PLAN reports intent; a RUN reports outcome. Swapping the live summary to
  # outcomes correctly stopped "DISPATCHED" from reading as success — but it also
  # emptied the dry run, which exists precisely to show what WOULD be dispatched.
  PLAN=""
  [ -n "$ROUTED" ]        && PLAN+="WOULD DISPATCH:"$'\n'"$ROUTED"
  [ -n "$BLOCKED" ]       && PLAN+="BLOCKED:"$'\n'"$BLOCKED"
  [ -n "$UNPROVISIONED" ] && PLAN+="NEEDS AN AGENT:"$'\n'"$UNPROVISIONED"
  [ -n "$STOPPED" ]       && PLAN+="HELD:"$'\n'"$STOPPED"
  echo "=== dispatch plan (nothing invoked) ==="; echo "${PLAN:-  nothing to route}"; exit 0
fi

# Silence is the default: a run where nothing moved is not news.
[ -n "$LANDED" ] && sudo -n /usr/local/bin/notify '#program' "$SUMMARY" >/dev/null
NEEDS_STEVE="$NEEDS_STEVE$BLOCKED$UNPROVISIONED"
[ -n "$NEEDS_STEVE" ] && sudo -n /usr/local/bin/notify '#ops-prod' \
  "Needs you:"$'\n'"$NEEDS_STEVE" >/dev/null
echo "$(date -Iseconds) dispatch: routed=$n" >> "$REPO/log/dispatch.log"
"$(dirname "$0")/board.sh" >/dev/null 2>&1 || true
