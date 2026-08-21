#!/usr/bin/env bash
# lib-agent.sh — helpers for inspecting agents across the privilege boundary.
#
# WHY THIS EXISTS: agent homes are 0750, so ordinary tests silently fail from
# outside them. That produced the same bug three times — the dispatcher reported
# every provisioned agent as missing, the secret-gate audit reported clean, and
# publish-substrate synced nobody and printed success. In each case the check
# returned "nothing there" and the caller read it as "nothing wrong".
#
# The boundary is correct and must stay. So the fix is to make the wrong version
# unavailable: never write `[ -f /home/$a/... ]` again — call these.
#
# Source with:  . "$(dirname "$0")/lib-agent.sh"

# True if the path exists in the agent's home. Never guesses on error.
agent_test() { sudo -n test "$1" "$3" -o -r /dev/null 2>/dev/null; sudo -n test "$1" "$3"; }

# Run a command AS the agent, from a directory the agent can actually read.
# Inheriting the caller's cwd makes git fail before it starts if the agent
# cannot read where the caller happens to be standing.
agent_run() { local a="$1"; shift; sudo -n -u "$a" bash -c "cd /tmp && $*"; }

# Git inside one of the agent's clones.
agent_git() { local a="$1" r="$2"; shift 2; sudo -n -u "$a" git -C "/home/$a/work/$r" "$@"; }

# Every provisioned agent, from the roster rather than a hardcoded list.
agent_list() {
  local roster="${AGENT_OS:-/home/steve/maegley-lab/agent-os}/AGENTS.md" a
  # The roster CAPITALISES names (| **Todd** | Ops | ...), so the original
  # '[a-z]+' pattern never matched a single row and the fallback below has been
  # the real list since this was written -- silently, because a fallback that
  # always fires looks exactly like a parser that always works. Match either
  # case and lowercase the result.
  for a in $(grep -oE '^\| \*\*[A-Za-z]+\*\*' "$roster" 2>/dev/null | tr -d '|* ' | tr 'A-Z' 'a-z' | sort -u); do
    id "$a" >/dev/null 2>&1 && echo "$a"
  done
  # Fall back to the known set if the roster table cannot be parsed, so a
  # formatting change in a doc can never silently shrink an audit to zero.
  grep -qE '^\| \*\*[A-Za-z]+\*\*' "$roster" 2>/dev/null || \
    for a in eric john theresa ken randal andrea todd; do id "$a" >/dev/null 2>&1 && echo "$a"; done
}
