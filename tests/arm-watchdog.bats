#!/usr/bin/env bats

load helpers

setup() {
  export CC_RESUME_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export CC_RESUME_HB_MAX_AGE=90
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  SESSION_ID="sess-abc"
  TRANSCRIPT="$BATS_TEST_TMPDIR/transcript.jsonl"
  : > "$TRANSCRIPT"
}

hook_input() {
  jq -cn --arg s "${1-$SESSION_ID}" --arg t "${2-$TRANSCRIPT}" --arg e "${3-SessionStart}" \
    '{session_id:$s, transcript_path:$t, hook_event_name:$e, cwd:"/tmp"}'
}

@test "asks for the monitor when the session is not covered" {
  emitted=$(hook_input | "$ARM_HOOK")
  [ -n "$emitted" ]
  [[ "$emitted" == *"Monitor("* ]]
  run jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' <<< "$emitted"
  [ "$status" -eq 0 ]
}

@test "the instruction carries the transcript, the heartbeat and the watcher" {
  ctx=$(hook_input | "$ARM_HOOK" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx" == *"$TRANSCRIPT"* ]]
  [[ "$ctx" == *"$CC_RESUME_STATE_DIR/$SESSION_ID.hb"* ]]
  [[ "$ctx" == *"$PLUGIN_ROOT/bin/cc-resume-watch"* ]]
  [[ "$ctx" == *"persistent: true"* ]]
}

@test "tells the model to load Monitor before calling it" {
  # Monitor is a deferred tool in most sessions. Calling it cold fails with
  # InputValidationError, so the instruction has to say to load the schema first.
  ctx=$(hook_input | "$ARM_HOOK" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx" == *'ToolSearch("select:Monitor")'* ]]
  [[ "$ctx" == *"deferred tool"* ]]
}

@test "tells the model not to narrate the arming" {
  # Without this the model announces "arming the watchdog first" in its reply,
  # which it did in 8 of 10 trial runs against the softer earlier wording.
  ctx=$(hook_input | "$ARM_HOOK" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx" == *"SILENCE:"* ]]
  [[ "$ctx" == *"Answer only what the user actually asked"* ]]
}

@test "stays silent while the heartbeat is fresh" {
  mkdir -p "$CC_RESUME_STATE_DIR"
  : > "$CC_RESUME_STATE_DIR/$SESSION_ID.hb"
  output=$(hook_input | "$ARM_HOOK")
  [ -z "$output" ]
}

@test "asks again once the heartbeat goes stale" {
  mkdir -p "$CC_RESUME_STATE_DIR"
  : > "$CC_RESUME_STATE_DIR/$SESSION_ID.hb"
  CC_RESUME_HB_MAX_AGE=0 output=$(hook_input | CC_RESUME_HB_MAX_AGE=0 "$ARM_HOOK")
  [[ "$output" == *"Monitor("* ]]
}

@test "echoes the event name it was called for" {
  output=$(hook_input "$SESSION_ID" "$TRANSCRIPT" UserPromptSubmit | "$ARM_HOOK")
  run jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' <<< "$output"
  [ "$status" -eq 0 ]
}

@test "stays silent without a session id" {
  output=$(hook_input "" "$TRANSCRIPT" | "$ARM_HOOK")
  [ -z "$output" ]
}

@test "stays silent without a transcript path" {
  output=$(hook_input "$SESSION_ID" "" | "$ARM_HOOK")
  [ -z "$output" ]
}

@test "stays silent on input that is not json" {
  output=$(printf 'not json' | "$ARM_HOOK")
  [ -z "$output" ]
}
