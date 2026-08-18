#!/usr/bin/env bash
# Shared helpers for the bats suite.

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PLUGIN_ROOT
WATCH_BIN="$PLUGIN_ROOT/bin/cc-resume-watch"
ARM_HOOK="$PLUGIN_ROOT/hooks/handlers/arm-watchdog.sh"
export WATCH_BIN ARM_HOOK

# iso_from_epoch <epoch> -> 2026-08-18T20:31:12Z, on BSD and GNU date alike
iso_from_epoch() {
  date -u -r "$1" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -d "@$1" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null
}

now_epoch() { date -u +%s; }

# api_error_entry <uuid> <seconds_ago> <text>
api_error_entry() {
  local uuid="$1" ago="$2" text="$3"
  local ts
  ts=$(iso_from_epoch "$(( $(now_epoch) - ago ))")
  jq -cn --arg u "$uuid" --arg t "$ts" --arg x "$text" \
    '{type:"assistant",uuid:$u,timestamp:$t,isApiErrorMessage:true,error:"server_error",
      message:{model:"<synthetic>",stop_reason:"stop_sequence",content:[{type:"text",text:$x}]}}'
}

# assistant_entry <uuid> <seconds_ago> <text>
assistant_entry() {
  local uuid="$1" ago="$2" text="$3"
  local ts
  ts=$(iso_from_epoch "$(( $(now_epoch) - ago ))")
  jq -cn --arg u "$uuid" --arg t "$ts" --arg x "$text" \
    '{type:"assistant",uuid:$u,timestamp:$t,
      message:{model:"claude-opus-5",stop_reason:"end_turn",content:[{type:"text",text:$x}]}}'
}

# user_entry <uuid> <seconds_ago> <text>
user_entry() {
  local uuid="$1" ago="$2" text="$3"
  local ts
  ts=$(iso_from_epoch "$(( $(now_epoch) - ago ))")
  jq -cn --arg u "$uuid" --arg t "$ts" --arg x "$text" \
    '{type:"user",uuid:$u,timestamp:$t,message:{role:"user",content:$x}}'
}

# progress_entry <uuid> <seconds_ago>   bookkeeping row that must not count as continuation
progress_entry() {
  local uuid="$1" ago="$2"
  local ts
  ts=$(iso_from_epoch "$(( $(now_epoch) - ago ))")
  jq -cn --arg u "$uuid" --arg t "$ts" '{type:"progress",uuid:$u,timestamp:$t}'
}

# run_watch <transcript> <grace> <poll> <max> <run_seconds> [heartbeat]
# Runs the watcher for a bounded time and echoes everything it printed.
run_watch() {
  local transcript="$1" grace="$2" poll="$3" max="$4" secs="$5" hb="${6:-}"
  local out; out="$BATS_TEST_TMPDIR/watch.out"
  : > "$out"
  CC_RESUME_HEARTBEAT="$hb" "$WATCH_BIN" "$transcript" "$grace" "$poll" "$max" > "$out" 2>&1 &
  local pid=$!
  sleep "$secs"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  cat "$out"
}

TRANSIENT_TEXT="API Error: Connection lost mid-response. The response above may be incomplete."
CREDITS_TEXT="You're out of usage credits. Run /usage-credits to keep using Fable 5 or /model to switch models."
export TRANSIENT_TEXT CREDITS_TEXT
