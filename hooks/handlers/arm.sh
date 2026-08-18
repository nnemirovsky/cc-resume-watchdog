#!/usr/bin/env bash
# Keeps exactly one resume watcher alive per session.
#
# Declared async + asyncRewake on SessionStart, UserPromptSubmit and PostToolUse.
# In the common case a watcher is already up and this exits in a stat and a signal
# check. When none is up, this process becomes the watcher via exec, so the pid it
# recorded stays valid.
#
# Three events rather than one because the rewake fires on process exit, so every
# resume consumes the watcher. SessionStart covers the window before the user has
# typed anything, and the other two put a fresh watcher back within one prompt or
# one tool call.
#
# Env overrides (used by the bats suite so tests never touch real state):
#   CC_RESUME_STATE_DIR   state root. Default $XDG_STATE_HOME/resume-watchdog
#   CC_RESUME_GRACE       seconds a dead turn must sit before a resume. Default 25
#   CC_RESUME_POLL        transcript poll interval. Default 10
#   CC_RESUME_MAX         resumes per rolling window. Default 12

set -uo pipefail

input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)

# Nothing to watch without a session id and an on-disk transcript.
[ -z "$session_id" ] && exit 0
[ -z "$transcript" ] && exit 0

state_dir="${CC_RESUME_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/resume-watchdog}"
mkdir -p "$state_dir" 2>/dev/null
state="$state_dir/$session_id"
pidfile="$state.pid"

# Claim the slot atomically. A plain "check then write" is not enough: SessionStart
# and UserPromptSubmit fire close enough together that both can pass the check
# before either writes, which spawns two watchers. noclobber makes the create fail
# when the file already exists, so exactly one caller wins.
claim() {
  set -C
  printf '%s\n' "$$" > "$pidfile" 2>/dev/null
}

attempt=0
until claim; do
  attempt=$(( attempt + 1 ))
  [ "$attempt" -gt 3 ] && exit 0

  pid=$(head -1 "$pidfile" 2>/dev/null)
  case "$pid" in
    "" | *[!0-9]*) pid=0 ;;
  esac

  # Someone live holds it, so this hook is a no-op.
  if [ "$pid" -gt 0 ] && kill -0 "$pid" 2>/dev/null; then
    exit 0
  fi

  # Stale, from a watcher that resumed and exited, or was killed. Clear and retry.
  rm -f "$pidfile"
done

plugin_root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

CC_RESUME_STATE="$state" \
exec "$plugin_root/bin/cc-resume-watch" \
  "$transcript" "${CC_RESUME_GRACE:-25}" "${CC_RESUME_POLL:-10}" "${CC_RESUME_MAX:-12}"
