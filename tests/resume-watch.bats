#!/usr/bin/env bats

load helpers

setup() {
  TRANSCRIPT="$BATS_TEST_TMPDIR/transcript.jsonl"
  export CC_RESUME_STATE="$BATS_TEST_TMPDIR/sess"
}

teardown() {
  pkill -f "cc-resume-watch $TRANSCRIPT" 2>/dev/null
  return 0
}

@test "asks for a resume when a transient stream failure is the last entry" {
  api_error_entry u1 120 "$TRANSIENT_TEXT" > "$TRANSCRIPT"
  run watch_hit "$TRANSCRIPT" 5
  [ "$status" -eq 2 ]
  [[ "$output" == *"RESUME-WATCH:"* ]]
  [[ "$output" == *"Pick up exactly where you left off"* ]]
  [[ "$output" == *"(resume 1/12 in the last 60m)"* ]]
}

@test "stays up and quiet for an error that needs a human" {
  api_error_entry u2 120 "$CREDITS_TEXT" > "$TRANSCRIPT"
  run watch_quiet "$TRANSCRIPT" 5 3
  [ -z "$output" ]
  still_alive
}

@test "stays up and quiet when the last entry is a normal assistant message" {
  assistant_entry u3 120 "all done" > "$TRANSCRIPT"
  run watch_quiet "$TRANSCRIPT" 5 3
  [ -z "$output" ]
  still_alive
}

@test "stays quiet when something already continued after the error" {
  { api_error_entry u4 300 "$TRANSIENT_TEXT"; user_entry u5 120 "continue"; } > "$TRANSCRIPT"
  run watch_quiet "$TRANSCRIPT" 5 3
  [ -z "$output" ]
}

@test "progress rows after the error do not count as continuation" {
  { api_error_entry u6 300 "$TRANSIENT_TEXT"; progress_entry u7 10; } > "$TRANSCRIPT"
  run watch_hit "$TRANSCRIPT" 5
  [ "$status" -eq 2 ]
}

@test "waits out the grace period" {
  api_error_entry u8 1 "$TRANSIENT_TEXT" > "$TRANSCRIPT"
  run watch_quiet "$TRANSCRIPT" 600 3
  [ -z "$output" ]
  still_alive
}

@test "a drop already in the ledger is not resumed again" {
  api_error_entry u9 120 "$TRANSIENT_TEXT" > "$TRANSCRIPT"
  echo u9 > "$CC_RESUME_STATE.resumed"
  run watch_quiet "$TRANSCRIPT" 5 3
  [ -z "$output" ]
  still_alive
}

@test "resuming records the uuid so the next watcher skips it" {
  api_error_entry u10 120 "$TRANSIENT_TEXT" > "$TRANSCRIPT"
  run watch_hit "$TRANSCRIPT" 5
  [ "$status" -eq 2 ]
  grep -qxF u10 "$CC_RESUME_STATE.resumed"
}

@test "the rate limit carries across watcher generations" {
  # Each resume kills its watcher, so the count has to live on disk.
  now=$(now_epoch)
  for _ in $(seq 1 12); do echo "$now" >> "$CC_RESUME_STATE.fired"; done
  api_error_entry u11 120 "$TRANSIENT_TEXT" > "$TRANSCRIPT"
  run watch_quiet "$TRANSCRIPT" 5 3
  [ -z "$output" ]
  still_alive
}

@test "the rate limit forgets fires older than the window" {
  old=$(( $(now_epoch) - 7200 ))
  for _ in $(seq 1 12); do echo "$old" >> "$CC_RESUME_STATE.fired"; done
  api_error_entry u12 120 "$TRANSIENT_TEXT" > "$TRANSCRIPT"
  run watch_hit "$TRANSCRIPT" 5
  [ "$status" -eq 2 ]
}

@test "the watcher exits when the session that owns it is gone" {
  assistant_entry u13 120 "idle" > "$TRANSCRIPT"
  dead=$(bash -c 'echo $$')
  run env CC_RESUME_OWNER="$dead" "$WATCH_BIN" "$TRANSCRIPT" 5 1 12
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the watcher stays up while its session is alive" {
  assistant_entry u14 120 "idle" > "$TRANSCRIPT"
  CC_RESUME_OWNER=$$ run watch_quiet "$TRANSCRIPT" 5 3
  [ -z "$output" ]
  still_alive
}

@test "the watcher releases its own pidfile when it exits" {
  # The weaker version of this only checked a foreign pidfile was left alone, so it
  # kept passing after release_pidfile was accidentally deleted.
  api_error_entry u15 120 "$TRANSIENT_TEXT" > "$TRANSCRIPT"
  # exec keeps the pid, so the pidfile names the watcher itself. Exit 2 is the
  # resume, so it has to be captured rather than tripping the test.
  run bash -c "echo \$\$ > '$CC_RESUME_STATE.pid'; exec '$WATCH_BIN' '$TRANSCRIPT' 5 1 12"
  [ "$status" -eq 2 ]
  [ ! -f "$CC_RESUME_STATE.pid" ]
}

@test "the watcher leaves a pidfile that belongs to someone else alone" {
  assistant_entry u15b 120 "idle" > "$TRANSCRIPT"
  dead=$(bash -c 'echo $$')
  echo 999999 > "$CC_RESUME_STATE.pid"
  run env CC_RESUME_OWNER="$dead" "$WATCH_BIN" "$TRANSCRIPT" 5 1 12
  [ -f "$CC_RESUME_STATE.pid" ]
  [ "$(cat "$CC_RESUME_STATE.pid")" = "999999" ]
}

@test "every exit path records why" {
  # A watcher died mid-session and left nothing to diagnose it with.
  api_error_entry u15c 120 "$TRANSIENT_TEXT" > "$TRANSCRIPT"
  run watch_hit "$TRANSCRIPT" 5
  [ "$status" -eq 2 ]
  grep -q "resumed" "$CC_RESUME_STATE.log"

  assistant_entry u15d 120 "idle" > "$TRANSCRIPT"
  dead=$(bash -c 'echo $$')
  run env CC_RESUME_OWNER="$dead" CC_RESUME_STATE="$CC_RESUME_STATE" "$WATCH_BIN" "$TRANSCRIPT" 5 1 12
  grep -q "owner-gone" "$CC_RESUME_STATE.log"
}

@test "a killed watcher puts a replacement in the field" {
  # Arming is activity-driven, so an idle session that loses its watcher gets no
  # replacement until someone types. Dying is the last chance to fix that.
  assistant_entry u15e 120 "idle" > "$TRANSCRIPT"
  CC_RESUME_OWNER=$$ CC_RESUME_STATE="$CC_RESUME_STATE" \
    "$WATCH_BIN" "$TRANSCRIPT" 5 1 12 >/dev/null 2>&1 &
  first=$!
  sleep 1
  kill -TERM "$first"
  sleep 2
  run kill -0 "$first"
  [ "$status" -ne 0 ]                                   # the original is gone
  n=$(pgrep -f "cc-resume-watch $TRANSCRIPT" | grep -c . || true)
  [ "$n" -eq 1 ]                                        # and exactly one took over
  grep -q "signal-TERM" "$CC_RESUME_STATE.log"
}

@test "tolerates a half-written final line" {
  api_error_entry u16 120 "$TRANSIENT_TEXT" > "$TRANSCRIPT"
  printf '{"type":"assistant","uuid":"trunc' >> "$TRANSCRIPT"
  run watch_hit "$TRANSCRIPT" 5
  [ "$status" -eq 2 ]
}

@test "tolerates a missing transcript without dying" {
  run watch_quiet "$BATS_TEST_TMPDIR/nope.jsonl" 5 3
  [ -z "$output" ]
  still_alive
}

@test "resumes every transient variant" {
  local i=0
  for t in \
    "API Error: Connection closed mid-response. The response above may be incomplete." \
    "API Error: Response stalled mid-stream. The response above may be incomplete." \
    "API Error: The response stopped arriving. The response above may be incomplete." \
    "API Error: Server error mid-response. The response above may be incomplete." \
    "API Error: Your computer went to sleep mid-response. The response above may be incomplete." \
    "API Error: Unable to connect to API (ECONNRESET)" \
    "Request timed out"
  do
    i=$(( i + 1 ))
    export CC_RESUME_STATE="$BATS_TEST_TMPDIR/variant-$i"
    api_error_entry "variant-$i" 120 "$t" > "$TRANSCRIPT"
    run watch_hit "$TRANSCRIPT" 5
    [ "$status" -eq 2 ] || { echo "no resume for: $t"; return 1; }
  done
}

@test "ignores the errors that need a human" {
  local i=0
  for t in \
    "You've hit your session limit, resets 2am" \
    "Not logged in. Please run /login" \
    "Prompt is too long"
  do
    i=$(( i + 1 ))
    export CC_RESUME_STATE="$BATS_TEST_TMPDIR/human-$i"
    api_error_entry "human-$i" 120 "$t" > "$TRANSCRIPT"
    run watch_quiet "$TRANSCRIPT" 5 2
    [ -z "$output" ] || { echo "unexpected resume for: $t"; return 1; }
  done
}

@test "a watcher with no resolvable owner and no live parent stands down" {
  # The registry is not always there: a short-lived session can be gone before the
  # watcher ever looks. Without this the watcher polls forever, which is the leak
  # the whole owner check exists to prevent. Observed live on a real orphan.
  assistant_entry u17 120 "idle" > "$TRANSCRIPT"
  bash -c "'$WATCH_BIN' '$TRANSCRIPT' 5 1 12 >/dev/null 2>&1 & echo \$! > '$BATS_TEST_TMPDIR/wpid'"
  sleep 1
  wpid=$(cat "$BATS_TEST_TMPDIR/wpid")
  sleep 4
  run kill -0 "$wpid"
  [ "$status" -ne 0 ]
}

@test "an explicit owner still wins over the parent check" {
  assistant_entry u18 120 "idle" > "$TRANSCRIPT"
  CC_RESUME_OWNER=$$ run watch_quiet "$TRANSCRIPT" 5 3
  [ -z "$output" ]
  still_alive
}
