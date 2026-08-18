#!/usr/bin/env bats

load helpers

setup() {
  TRANSCRIPT="$BATS_TEST_TMPDIR/transcript.jsonl"
  LEDGER="$BATS_TEST_TMPDIR/session.resumed"
}

@test "rewake mode exits 2 so asyncRewake wakes the model" {
  api_error_entry rw-1 120 "$TRANSIENT_TEXT" > "$TRANSCRIPT"
  run run_rewake "$TRANSCRIPT" 5
  [ "$status" -eq 2 ]
  [[ "$output" == *"RESUME-WATCH:"* ]]
  [[ "$output" == *"Pick up exactly where you left off"* ]]
}

@test "rewake mode says nothing for an error that needs a human" {
  api_error_entry rw-2 120 "$CREDITS_TEXT" > "$TRANSCRIPT"
  run run_watch "$TRANSCRIPT" 5 1 5 3
  [ -z "$output" ]
}

@test "rewake mode records the uuid so the monitor will not repeat it" {
  api_error_entry rw-3 120 "$TRANSIENT_TEXT" > "$TRANSCRIPT"
  run run_rewake "$TRANSCRIPT" 5 "$LEDGER"
  [ "$status" -eq 2 ]
  grep -qxF rw-3 "$LEDGER"
}

@test "the monitor skips a drop the rewake already handled" {
  api_error_entry rw-4 120 "$TRANSIENT_TEXT" > "$TRANSCRIPT"
  mkdir -p "$(dirname "$LEDGER")"; echo rw-4 > "$LEDGER"
  CC_RESUME_LEDGER="$LEDGER" run run_watch "$TRANSCRIPT" 5 1 5 3
  [ -z "$output" ]
}

@test "a drop not in the ledger is still resumed" {
  api_error_entry rw-5 120 "$TRANSIENT_TEXT" > "$TRANSCRIPT"
  mkdir -p "$(dirname "$LEDGER")"; echo some-other-uuid > "$LEDGER"
  CC_RESUME_LEDGER="$LEDGER" run run_watch "$TRANSCRIPT" 5 1 5 3
  [[ "$output" == *"RESUME-WATCH:"* ]]
}

@test "the watcher exits when the session that owns it is gone" {
  # Claude Code never reaps a detached async hook, so the watcher has to notice.
  assistant_entry rw-6 120 "idle" > "$TRANSCRIPT"
  dead=$(bash -c 'echo $$')      # a pid that has already exited
  run env CC_RESUME_OWNER_PID="$dead" "$WATCH_BIN" "$TRANSCRIPT" 5 1 5
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the watcher keeps running while its session is alive" {
  assistant_entry rw-7 120 "idle" > "$TRANSCRIPT"
  CC_RESUME_OWNER_PID=$$ run run_watch "$TRANSCRIPT" 5 1 5 3
  [ -z "$output" ]
}
