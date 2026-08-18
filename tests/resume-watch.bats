#!/usr/bin/env bats

load helpers

setup() {
  TRANSCRIPT="$BATS_TEST_TMPDIR/transcript.jsonl"
  HB="$BATS_TEST_TMPDIR/session.hb"
}

@test "resumes when a transient stream failure is the last entry" {
  api_error_entry uuid-1 120 "$TRANSIENT_TEXT" > "$TRANSCRIPT"
  run run_watch "$TRANSCRIPT" 5 1 5 3
  [[ "$output" == *"RESUME-WATCH:"* ]]
  [[ "$output" == *"Connection lost mid-response"* ]]
  [[ "$output" == *"auto-resume 1/5"* ]]
}

@test "stays silent for a non-transient error that needs a human" {
  api_error_entry uuid-2 120 "$CREDITS_TEXT" > "$TRANSCRIPT"
  run run_watch "$TRANSCRIPT" 5 1 5 3
  [ -z "$output" ]
}

@test "stays silent when the last entry is a normal assistant message" {
  assistant_entry uuid-3 120 "all done" > "$TRANSCRIPT"
  run run_watch "$TRANSCRIPT" 5 1 5 3
  [ -z "$output" ]
}

@test "stays silent when something already continued after the error" {
  {
    api_error_entry uuid-4 300 "$TRANSIENT_TEXT"
    user_entry uuid-5 120 "continue"
  } > "$TRANSCRIPT"
  run run_watch "$TRANSCRIPT" 5 1 5 3
  [ -z "$output" ]
}

@test "progress rows after the error do not count as continuation" {
  {
    api_error_entry uuid-6 300 "$TRANSIENT_TEXT"
    progress_entry uuid-7 10
  } > "$TRANSCRIPT"
  run run_watch "$TRANSCRIPT" 5 1 5 3
  [[ "$output" == *"RESUME-WATCH:"* ]]
}

@test "waits out the grace period before resuming" {
  api_error_entry uuid-8 1 "$TRANSIENT_TEXT" > "$TRANSCRIPT"
  run run_watch "$TRANSCRIPT" 600 1 5 3
  [ -z "$output" ]
}

@test "resumes a given error only once" {
  api_error_entry uuid-9 120 "$TRANSIENT_TEXT" > "$TRANSCRIPT"
  run run_watch "$TRANSCRIPT" 5 1 5 5
  [ "$(grep -c 'RESUME-WATCH: the previous turn' <<< "$output")" -eq 1 ]
}

@test "holds off when the rate limit is already spent" {
  api_error_entry uuid-10 120 "$TRANSIENT_TEXT" > "$TRANSCRIPT"
  run run_watch "$TRANSCRIPT" 5 1 0 3
  [[ "$output" == *"Holding off"* ]]
  [[ "$output" != *"Pick up exactly where you left off"* ]]
}

@test "throttles a tight failure loop, then recovers once the window clears" {
  export CC_RESUME_WINDOW=4
  api_error_entry loop-1 60 "$TRANSIENT_TEXT" > "$TRANSCRIPT"
  (
    sleep 2; api_error_entry loop-2 60 "$TRANSIENT_TEXT" > "$TRANSCRIPT"
    sleep 4; api_error_entry loop-3 60 "$TRANSIENT_TEXT" > "$TRANSCRIPT"
  ) &
  feeder=$!
  run run_watch "$TRANSCRIPT" 5 1 1 9
  kill "$feeder" 2>/dev/null || true
  wait "$feeder" 2>/dev/null || true
  # one resume, then a hold-off for the burst, then a resume again once the
  # window aged out. The watcher must never exit on its own.
  [ "$(grep -c 'the previous turn was killed' <<< "$output")" -ge 2 ]
  [[ "$output" == *"Holding off"* ]]
}

@test "does not repeat the hold-off notice while it stays throttled" {
  export CC_RESUME_WINDOW=600
  api_error_entry hold-1 60 "$TRANSIENT_TEXT" > "$TRANSCRIPT"
  (
    sleep 2; api_error_entry hold-2 60 "$TRANSIENT_TEXT" > "$TRANSCRIPT"
    sleep 2; api_error_entry hold-3 60 "$TRANSIENT_TEXT" > "$TRANSCRIPT"
  ) &
  feeder=$!
  run run_watch "$TRANSCRIPT" 5 1 0 6
  kill "$feeder" 2>/dev/null || true
  wait "$feeder" 2>/dev/null || true
  [ "$(grep -c 'Holding off' <<< "$output")" -eq 1 ]
}

@test "tolerates a half-written final line" {
  api_error_entry uuid-11 120 "$TRANSIENT_TEXT" > "$TRANSCRIPT"
  printf '{"type":"assistant","uuid":"trunc' >> "$TRANSCRIPT"
  run run_watch "$TRANSCRIPT" 5 1 5 3
  [[ "$output" == *"RESUME-WATCH:"* ]]
}

@test "tolerates a missing transcript without dying" {
  run run_watch "$BATS_TEST_TMPDIR/does-not-exist.jsonl" 5 1 5 3
  [ -z "$output" ]
}

@test "writes a heartbeat when one is requested" {
  assistant_entry uuid-12 120 "idle" > "$TRANSCRIPT"
  run_watch "$TRANSCRIPT" 5 1 5 3 "$HB" > /dev/null
  [ -f "$HB" ]
}

@test "resumes every transient variant" {
  local texts=(
    "API Error: Connection closed mid-response. The response above may be incomplete."
    "API Error: Response stalled mid-stream. The response above may be incomplete."
    "API Error: The response stopped arriving. The response above may be incomplete."
    "API Error: Server error mid-response. The response above may be incomplete."
    "API Error: Your computer went to sleep mid-response. The response above may be incomplete."
    "API Error: Unable to connect to API (ECONNRESET)"
    "Request timed out"
  )
  local i=0
  for t in "${texts[@]}"; do
    i=$(( i + 1 ))
    api_error_entry "variant-$i" 120 "$t" > "$TRANSCRIPT"
    run run_watch "$TRANSCRIPT" 5 1 5 3
    [[ "$output" == *"RESUME-WATCH:"* ]] || {
      echo "no resume for variant: $t"; return 1
    }
  done
}

@test "ignores the other errors that need a human" {
  local texts=(
    "You've hit your session limit · resets 2am (Asia/Makassar)"
    "Not logged in · Please run /login"
    "Prompt is too long"
  )
  local i=0
  for t in "${texts[@]}"; do
    i=$(( i + 1 ))
    api_error_entry "human-$i" 120 "$t" > "$TRANSCRIPT"
    run run_watch "$TRANSCRIPT" 5 1 5 3
    [ -z "$output" ] || { echo "unexpected resume for: $t"; return 1; }
  done
}
