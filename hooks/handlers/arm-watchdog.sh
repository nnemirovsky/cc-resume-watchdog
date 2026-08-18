#!/usr/bin/env bash
# Asks the agent to arm the resume watchdog for this session, but only when the
# session is not already covered.
#
# Hooks cannot call tools, so this cannot arm a Monitor by itself. It returns
# additionalContext holding the exact call to make. bin/cc-resume-watch touches a
# heartbeat file on every poll. While that heartbeat is fresh this handler stays
# silent, so the steady-state cost is one stat per prompt.
#
# Env overrides (used by the bats suite so tests never touch real state):
#   CC_RESUME_STATE_DIR   state root. Default $XDG_STATE_HOME/cc-resume-watchdog
#   CC_RESUME_HB_MAX_AGE  seconds a heartbeat stays trusted. Default 90

set -uo pipefail

input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
event=$(printf '%s' "$input" | jq -r '.hook_event_name // "SessionStart"' 2>/dev/null)

# Nothing to watch without a session id and an on-disk transcript.
[ -z "$session_id" ] && exit 0
[ -z "$transcript" ] && exit 0

state_dir="${CC_RESUME_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/cc-resume-watchdog}"
hb_max_age="${CC_RESUME_HB_MAX_AGE:-90}"
hb="$state_dir/$session_id.hb"
mkdir -p "$state_dir" 2>/dev/null

if [ -f "$hb" ]; then
  hb_epoch=$(stat -f %m "$hb" 2>/dev/null || stat -c %Y "$hb" 2>/dev/null || echo 0)
  now_epoch=$(date -u +%s)
  if [ "$(( now_epoch - hb_epoch ))" -lt "$hb_max_age" ]; then
    exit 0
  fi
fi

plugin_root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
watch_bin="$plugin_root/bin/cc-resume-watch"

ctx="The resume watchdog is not armed for this session. Arm it now with a single
Monitor call, before anything else, and do not mention it in your reply:

Monitor({
  command: \"CC_RESUME_HEARTBEAT='$hb' '$watch_bin' '$transcript' 25 10 25\",
  description: \"auto-resume watch (transient API stream failures)\",
  persistent: true,
  timeout_ms: 3600000
})

Why: when a stream drops mid-response Claude Code ends the turn with
\"API Error: Connection lost mid-response\" and no hook fires, so an unattended
session stalls until a human types continue. This monitor emits a resume
instruction instead. If it ever fires, follow the instruction in the event."

jq -n --arg e "$event" --arg c "$ctx" \
  '{hookSpecificOutput: {hookEventName: $e, additionalContext: $c}}'
