#!/usr/bin/env bash
# Shared helpers for the bats suite.

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCH_BIN="$PLUGIN_ROOT/bin/cc-resume-watch"
ARM_HOOK="$PLUGIN_ROOT/hooks/handlers/arm.sh"
export PLUGIN_ROOT WATCH_BIN ARM_HOOK

TRANSIENT_TEXT="API Error: Connection lost mid-response. The response above may be incomplete."
CREDITS_TEXT="You're out of usage credits. Run /usage-credits to keep using Fable 5 or /model to switch models."
export TRANSIENT_TEXT CREDITS_TEXT

# iso_from_epoch <epoch> -> 2026-08-18T20:31:12Z, on BSD and GNU date alike
iso_from_epoch() {
  date -u -r "$1" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -d "@$1" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null
}
now_epoch() { date -u +%s; }

_entry() {  # _entry <jq-extra> <uuid> <seconds_ago> <text>
  local extra="$1" uuid="$2" ago="$3" text="$4" ts
  ts=$(iso_from_epoch "$(( $(now_epoch) - ago ))")
  jq -cn --arg u "$uuid" --arg t "$ts" --arg x "$text" "$extra"
}
api_error_entry() {
  _entry '{type:"assistant",uuid:$u,timestamp:$t,isApiErrorMessage:true,error:"server_error",
           message:{model:"<synthetic>",stop_reason:"stop_sequence",content:[{type:"text",text:$x}]}}' "$@"
}
assistant_entry() {
  _entry '{type:"assistant",uuid:$u,timestamp:$t,
           message:{model:"claude-opus-5",stop_reason:"end_turn",content:[{type:"text",text:$x}]}}' "$@"
}
user_entry() {
  _entry '{type:"user",uuid:$u,timestamp:$t,message:{role:"user",content:$x}}' "$@"
}
progress_entry() {
  _entry '{type:"progress",uuid:$u,timestamp:$t,note:$x}' "$1" "$2" "progress"
}

# watch_hit <transcript> <grace> - run to completion, expecting a quick exit.
# Prints stderr, returns the watcher's exit code (2 means it asked for a resume).
watch_hit() {
  local transcript="$1" grace="$2"
  CC_RESUME_STATE="${CC_RESUME_STATE:-}" "$WATCH_BIN" "$transcript" "$grace" 1 "${CC_RESUME_MAX:-12}" 2>&1
}

# watch_quiet <transcript> <grace> <secs> - run for a bounded time, expecting the
# watcher to stay up and say nothing. Prints anything it did say.
watch_quiet() {
  local transcript="$1" grace="$2" secs="$3" out="$BATS_TEST_TMPDIR/quiet.out"
  : > "$out"
  CC_RESUME_STATE="${CC_RESUME_STATE:-}" "$WATCH_BIN" "$transcript" "$grace" 1 "${CC_RESUME_MAX:-12}" > "$out" 2>&1 &
  local pid=$!
  sleep "$secs"
  local alive=0; kill -0 "$pid" 2>/dev/null && alive=1
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  echo "$alive" > "$BATS_TEST_TMPDIR/still_alive"
  cat "$out"
}
still_alive() { [ "$(cat "$BATS_TEST_TMPDIR/still_alive" 2>/dev/null)" = "1" ]; }

hook_input() {
  jq -cn --arg s "${1-$SESSION_ID}" --arg t "${2-$TRANSCRIPT}" --arg e "${3-SessionStart}" \
    '{session_id:$s, transcript_path:$t, hook_event_name:$e, cwd:"/tmp"}'
}
