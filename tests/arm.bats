#!/usr/bin/env bats

load helpers

setup() {
  export CC_RESUME_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  export CC_RESUME_POLL=1
  SESSION_ID="sess-abc"
  TRANSCRIPT="$BATS_TEST_TMPDIR/transcript.jsonl"
  assistant_entry a1 120 "idle" > "$TRANSCRIPT"
  PIDFILE="$CC_RESUME_STATE_DIR/$SESSION_ID.pid"
}

teardown() {
  [ -f "$PIDFILE" ] && kill "$(head -1 "$PIDFILE")" 2>/dev/null
  return 0
}

# arm_bg [event] - run the hook detached, give it a moment, leave it running
arm_bg() {
  hook_input "$SESSION_ID" "$TRANSCRIPT" "${1:-SessionStart}" | "$ARM_HOOK" &
  sleep 1
}

@test "arms a watcher when the session has none" {
  arm_bg
  [ -f "$PIDFILE" ]
  pid=$(head -1 "$PIDFILE")
  kill -0 "$pid"
  # the hook execs into the watcher, so the recorded pid is the watcher itself
  ps -o command= -p "$pid" | grep -q "cc-resume-watch"
}

@test "does nothing when a live watcher is already recorded" {
  arm_bg
  first=$(head -1 "$PIDFILE")
  hook_input "$SESSION_ID" "$TRANSCRIPT" UserPromptSubmit | "$ARM_HOOK"
  [ "$(head -1 "$PIDFILE")" = "$first" ]
  kill -0 "$first"
}

@test "arms a replacement once the recorded watcher is gone" {
  # every resume consumes the watcher, so the next hook has to put one back
  mkdir -p "$CC_RESUME_STATE_DIR"
  bash -c 'echo $$' > "$PIDFILE"          # a pid that has already exited
  stale=$(head -1 "$PIDFILE")
  arm_bg PostToolUse
  fresh=$(head -1 "$PIDFILE")
  [ "$fresh" != "$stale" ]
  kill -0 "$fresh"
}

@test "stays silent without a session id" {
  run bash -c "hook_input() { jq -cn '{transcript_path:\"$TRANSCRIPT\",hook_event_name:\"SessionStart\"}'; }; hook_input | '$ARM_HOOK'"
  [ "$status" -eq 0 ]
  [ ! -f "$PIDFILE" ]
}

@test "stays silent without a transcript path" {
  run bash -c "jq -cn '{session_id:\"$SESSION_ID\",hook_event_name:\"SessionStart\"}' | '$ARM_HOOK'"
  [ "$status" -eq 0 ]
  [ ! -f "$PIDFILE" ]
}

@test "stays silent on input that is not json" {
  run bash -c "printf 'not json' | '$ARM_HOOK'"
  [ "$status" -eq 0 ]
  [ ! -f "$PIDFILE" ]
}

@test "a garbage pidfile is treated as no watcher" {
  mkdir -p "$CC_RESUME_STATE_DIR"
  echo "not-a-pid" > "$PIDFILE"
  arm_bg
  pid=$(head -1 "$PIDFILE")
  [[ "$pid" =~ ^[0-9]+$ ]]
  kill -0 "$pid"
}

@test "two hooks firing at once still leave exactly one watcher" {
  # SessionStart and UserPromptSubmit fire close enough together that a plain
  # check-then-write spawned two. The claim has to be atomic.
  for _ in 1 2 3 4 5 6; do
    hook_input "$SESSION_ID" "$TRANSCRIPT" SessionStart | "$ARM_HOOK" &
  done
  sleep 2
  n=$(pgrep -f "cc-resume-watch $TRANSCRIPT" | grep -c . || true)
  [ "$n" -eq 1 ]
  [ "$(head -1 "$PIDFILE")" = "$(pgrep -f "cc-resume-watch $TRANSCRIPT")" ]
}
