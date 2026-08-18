#!/usr/bin/env bash
# SessionStart hook body for the rewake watcher.
#
# Runs detached (async) and stays alive for the session. On the first transient
# stream failure it prints the resume instruction to stderr and exits 2, which is
# what asyncRewake turns into a wake-up for the model. That covers the window
# before the user's first message, which the Monitor path cannot reach because
# only a turn can call a tool.
#
# One shot by construction: the rewake fires on process exit. The Monitor armed
# from the same session covers everything after that.

set -uo pipefail

input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)

[ -z "$session_id" ] && exit 0
[ -z "$transcript" ] && exit 0

state_dir="${CC_RESUME_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/resume-watchdog}"
mkdir -p "$state_dir" 2>/dev/null

plugin_root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

CC_RESUME_MODE=rewake \
CC_RESUME_LEDGER="$state_dir/$session_id.resumed" \
exec "$plugin_root/bin/cc-resume-watch" "$transcript" "${CC_RESUME_GRACE:-25}" "${CC_RESUME_POLL:-10}" 1
