#!/usr/bin/env bats

load helpers

setup() {
  TRANSCRIPT="$BATS_TEST_TMPDIR/session.jsonl"
  SUBDIR="$BATS_TEST_TMPDIR/session/subagents"
  mkdir -p "$SUBDIR"
  export CC_RESUME_STATE="$BATS_TEST_TMPDIR/sess"
  assistant_entry parent-idle 120 "parent is fine" > "$TRANSCRIPT"
}

teardown() {
  pkill -f "cc-resume-watch $TRANSCRIPT" 2>/dev/null
  return 0
}

# age_file <path> <seconds_ago> - a live subagent writes constantly, so mtime is
# what separates one that is working from one that stopped
age_file() {
  local when
  when=$(date -u -r "$(( $(now_epoch) - $2 ))" +"%Y%m%d%H%M.%S" 2>/dev/null) \
    || when=$(date -u -d "@$(( $(now_epoch) - $2 ))" +"%Y%m%d%H%M.%S" 2>/dev/null)
  touch -t "$when" "$1"
}

@test "tells the parent when a subagent died transiently" {
  api_error_entry sub-1 120 "$TRANSIENT_TEXT" > "$SUBDIR/agent-aTask2-abc.jsonl"
  age_file "$SUBDIR/agent-aTask2-abc.jsonl" 120
  run watch_hit "$TRANSCRIPT" 5
  [ "$status" -eq 2 ]
  [[ "$output" == *"subagent agent-aTask2-abc"* ]]
  [[ "$output" == *"result is never going to arrive"* ]]
  [[ "$output" != *"Pick up exactly where you left off"* ]]
}

@test "says nothing about a subagent that is still working" {
  api_error_entry sub-2 120 "$TRANSIENT_TEXT" > "$SUBDIR/agent-aBusy-def.jsonl"
  # mtime is now, so it is still writing
  run watch_quiet "$TRANSCRIPT" 5 3
  [ -z "$output" ]
  still_alive
}

@test "ignores a subagent that stopped on an error needing a human" {
  api_error_entry sub-3 120 "$CREDITS_TEXT" > "$SUBDIR/agent-aCredits-ghi.jsonl"
  age_file "$SUBDIR/agent-aCredits-ghi.jsonl" 120
  run watch_quiet "$TRANSCRIPT" 5 3
  [ -z "$output" ]
  still_alive
}

@test "ignores a subagent that finished normally" {
  assistant_entry sub-4 120 "here is my report" > "$SUBDIR/agent-aDone-jkl.jsonl"
  age_file "$SUBDIR/agent-aDone-jkl.jsonl" 120
  run watch_quiet "$TRANSCRIPT" 5 3
  [ -z "$output" ]
  still_alive
}

@test "the parent's own dead turn wins over a dead subagent" {
  api_error_entry parent-dead 120 "$TRANSIENT_TEXT" > "$TRANSCRIPT"
  api_error_entry sub-5 120 "$TRANSIENT_TEXT" > "$SUBDIR/agent-aBoth-mno.jsonl"
  age_file "$SUBDIR/agent-aBoth-mno.jsonl" 120
  run watch_hit "$TRANSCRIPT" 5
  [ "$status" -eq 2 ]
  [[ "$output" == *"Pick up exactly where you left off"* ]]
  [[ "$output" != *"subagent"* ]]
}

@test "a subagent is reported once, not on every generation" {
  api_error_entry sub-6 120 "$TRANSIENT_TEXT" > "$SUBDIR/agent-aOnce-pqr.jsonl"
  age_file "$SUBDIR/agent-aOnce-pqr.jsonl" 120
  run watch_hit "$TRANSCRIPT" 5
  [ "$status" -eq 2 ]
  grep -qxF sub-6 "$CC_RESUME_STATE.resumed"
  run watch_quiet "$TRANSCRIPT" 5 3
  [ -z "$output" ]
}

@test "copes with a session that has no subagents at all" {
  rm -rf "$BATS_TEST_TMPDIR/session"
  run watch_quiet "$TRANSCRIPT" 5 3
  [ -z "$output" ]
  still_alive
}
