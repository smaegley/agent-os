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
    # 'qa-ready' is the agents' own token, not mine. They had no published state
    # vocabulary, so they coined one and used it consistently — Randal even noted
    # "states are convention tokens" in his handoff. Their word wins: it is the one
    # actually written into the work items. 'built' kept as an accepted synonym.
    qa-ready|built) echo eric ;;                          # QA verifies — different access than the builder
    qa-passed)      [ "$3" = true ] && echo andrea || echo "" ;;
    uat-passed)     echo "" ;;                            # → Steve approves deploy
    *)              echo "" ;;
  esac
}

ROUTED=""; STOPPED=""; BLOCKED=""; UNPROVISIONED=""; n=0

for f in projects/*/*.md; do
  [ -e "$f" ] || continue
  head -1 "$f" | grep -q '^---$' || continue          # no front matter → not a work item
  id="$(fm id "$f")";    [ -n "$id" ] || continue
  state="$(fm state "$f")"; proj="$(fm project "$f")"
  infra="$(fm infra "$f")"; uf="$(fm user_facing "$f")"

  if [ "$state" = blocked ]; then
    BLOCKED+="  $id [$proj] — blocked, needs Steve"$'\n'; continue
  fi

  who="$(route "$state" "${infra:-false}" "${uf:-false}")"
  if [ -z "$who" ]; then
    STOPPED+="  $id [$proj] state=$state — no auto-route (terminal, or awaiting Steve)"$'\n'
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

  # Agents pull from origin; the dispatcher reads the local working copy. An
  # item that exists only locally dispatches an agent to look for a file that
  # is not there — which is exactly what happened on the first live run.
  if ! git cat-file -e "origin/main:$f" 2>/dev/null; then
    STOPPED+="  $id [$proj] — not pushed to origin; agents cannot see it"$'\n'
    continue
  fi

  if [ "$n" -ge "$MAX_DISPATCH" ]; then
    STOPPED+="  $id [$proj] state=$state → $who (deferred: run cap $MAX_DISPATCH reached)"$'\n'
    continue
  fi

  ROUTED+="  $id [$proj] state=$state → $who"$'\n'
  n=$((n+1))
  [ "$DRY_RUN" = "1" ] && continue

  sudo -u "$who" bash -lc "cd /home/$who/work/program && git pull -q origin main 2>/dev/null; \
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
    >> "$REPO/log/dispatch.log" 2>&1 &
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

SUMMARY=""
[ -n "$BLOCKED" ]       && SUMMARY+="BLOCKED:"$'\n'"$BLOCKED"
[ -n "$ROUTED" ]        && SUMMARY+="DISPATCHED:"$'\n'"$ROUTED"
[ -n "$UNPROVISIONED" ] && SUMMARY+="NEEDS AN AGENT:"$'\n'"$UNPROVISIONED"
[ -n "$STOPPED" ]       && SUMMARY+="HELD:"$'\n'"$STOPPED"

if [ "$DRY_RUN" = "1" ]; then
  echo "=== dispatch plan (nothing invoked) ==="; echo "${SUMMARY:-  nothing to route}"; exit 0
fi

[ -n "$ROUTED$BLOCKED$UNPROVISIONED" ] || exit 0
sudo -n /usr/local/bin/notify '#program' "Dispatch — "$'\n'"$SUMMARY" >/dev/null
[ -n "$BLOCKED$UNPROVISIONED" ] && sudo -n /usr/local/bin/notify '#ops-prod' \
  "Steve — needs you:"$'\n'"$BLOCKED$UNPROVISIONED" >/dev/null
echo "$(date -Iseconds) dispatch: routed=$n" >> "$REPO/log/dispatch.log"
