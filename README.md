# resume-watchdog

A Claude Code plugin that resumes a session after a turn is killed by a transient
API stream failure. This is the failure mode no hook fires for.

```
API Error: Connection lost mid-response. The response above may be incomplete.
```

The turn ends right there. Left unattended, the session sits idle until a human
types `continue`. Across 47 days of my own transcripts that happened 115 times, and
the worst stalls ran 40 to 79 hours.

## Why no hook catches it

Claude Code retries a dropped stream only before the first event arrives. Once a
block of text or a tool call has been emitted, re-issuing the request could run the
same tool calls twice, so Claude Code keeps the partial output and ends the turn
instead. That behaviour is
[documented](https://code.claude.com/docs/en/errors) and deliberate.

The main agent loop then returns on the error before it reaches the Stop hook
runner, so `Stop` never fires. Neither does `PostToolUse`, because no tool
completed, nor `UserPromptSubmit`, because nobody typed anything. An `OnError` hook
was requested in
[anthropics/claude-code#21168](https://github.com/anthropics/claude-code/issues/21168)
and closed without being built.

One in-process channel does survive the dead turn. A background task notification
re-invokes the agent loop. This plugin rides that channel.

## How it works

One watcher per session, and no tool calls.

`SessionStart`, `UserPromptSubmit` and `PostToolUse` all run the same arming hook,
declared `async` plus `asyncRewake`. When a watcher is already up the hook exits in
a stat and a signal check. When none is up, the hook process becomes the watcher
via `exec`, so the pid it recorded stays valid.

The watcher polls the transcript. When the last conversational entry is a transient
stream failure that has been sitting for `grace` seconds, it writes the resume
instruction to stderr and exits 2.

It watches the session's subagents too. Those run in the background, so the parent
gets a launch confirmation immediately and only learns the outcome later. A subagent
that dies this way never reports back at all, and the parent sits waiting on a
result that is not coming. It cannot be resumed from outside the process, so the
watcher tells the parent which one died and lets it decide whether to re-dispatch.
A live subagent writes to its transcript constantly, so anything touched inside the
grace window is skipped without being parsed. The session's own dead turn takes
priority over a dead child. Claude Code turns a rewake hook's exit 2 into a
wake-up for the model, carrying that stderr, and the turn picks up.

Three events rather than one because the rewake fires on process exit, so every
resume consumes the watcher. `SessionStart` covers the window before you have typed
anything, including on a resumed session, and the other two put a fresh watcher
back within one prompt or one tool call.

Cross-process state, because each watcher is short-lived:

* `<session>.pid` is the singleton marker, released on exit if still owned.
* `<session>.resumed` is the uuid ledger, so one drop is never resumed twice by two
  generations of watcher.
* `<session>.fired` is the rate-limit log, so the limit holds across them.
* `<session>.log` records why each watcher exited.

The watcher also resolves the pid of the Claude Code process that owns its
transcript and exits once that dies. Claude Code never reaps a detached async hook,
so without that a watcher outlives the session it was watching.

The registry is not always available. A watcher armed at `SessionStart` can start
before the session file is written, and a short-lived session can be gone before the
watcher ever looks. When there is no owner to resolve, the watcher falls back to its
parent: a hook-armed watcher is exec'd by Claude Code and keeps it as a parent for
as long as it lives, so being parented to init means there is nothing left to watch
for and it stands down.

## What it resumes

Only failures where the stream died and both the request and the account are fine:

```
Connection lost mid-response
Connection closed mid-response
Response stalled mid-stream
The response stopped arriving
Server error mid-response
Your computer went to sleep mid-response
Unable to connect to API (ECONNRESET, ENOTFOUND, ConnectionRefused)
Request timed out
```

It never resumes anything else. Out of usage credits, session limit reached,
`Please run /login`, prompt too long and refusals all need a human, and quietly
retrying those is worse than stalling. Resumes are also de-duplicated on message
uuid and rate limited, so a tight failure loop cannot run away.

## Install

```
/plugin marketplace add nnemirovsky/cc-resume-watchdog
/plugin install resume-watchdog
```

Needs `bash`, `jq`, and a session transcript on disk. Hooks load at session start,
so restart Claude Code afterwards.

## Tuning

```
bin/cc-resume-watch <transcript.jsonl> [grace=25] [poll=10] [max_per_hour=12]
```

The hook passes these through from `CC_RESUME_GRACE`, `CC_RESUME_POLL` and
`CC_RESUME_MAX`.

* `grace` is how many seconds the error must sit as the last entry before a resume
  fires. Lower recovers faster. Too low and it can fire while Claude Code is still
  finishing up.
* `poll` is the transcript poll interval in seconds.
* `max_per_hour` is a rolling rate limit, not a lifetime budget. A session running
  for days can absorb hundreds of drops, because a normal one recovers in a try or
  two and they arrive spread out. What the limit is there for is the other case,
  where every resume dies again immediately. Once the window is spent the watcher
  prints one hold-off line and goes quiet until it clears. It never exits, so the
  session is still covered after the outage passes.

Both scripts read these overrides, which the test suite uses so nothing touches
real state:

* `CC_RESUME_STATE` is the state file prefix for one session.
* `CC_RESUME_STATE_DIR` is the hook's state root. Defaults to
  `$XDG_STATE_HOME/resume-watchdog`.
* `CC_RESUME_OWNER` is the Claude Code pid to follow. Resolved from the session
  registry when unset, and failing that the watcher follows its own parent.
* `CC_RESUME_WINDOW` is the rate-limit window in seconds. Default 3600.
* `CC_RESUME_STATE_DIR` is the hook's state root. Defaults to
  `$XDG_STATE_HOME/resume-watchdog`.
* `CC_RESUME_HB_MAX_AGE` is how many seconds a heartbeat stays trusted. Default 90.

## Limits

* Covers turn death, not process death. If the CLI exits, so do the watchers, by
  design.
* Subagent turns die the same way and are not covered. A subagent that hits this
  returns null to its caller.
* Every arming event is activity-driven, so an idle session that loses its watcher
  gets no replacement until you next type or a tool runs. A watcher that is killed
  puts a replacement in the field before it goes, which covers the deaths it can
  see coming. A hard kill is not one of them.
* If a resumed turn drops again before it makes its first tool call, nothing is
  armed for that stretch, because the watcher that resumed it is spent and the next
  arming event has not happened yet. Narrow, and the next prompt or tool call
  closes it.
* `PostToolUse` runs the arming hook on every tool call. In the common case that is
  a stat and a `kill -0`, and it is backgrounded, so it does not sit on the tool's
  critical path.

## Development

```
bats tests/*.bats
shellcheck --severity=error bin/cc-resume-watch hooks/handlers/*.sh
```

Load the plugin from a working tree instead of through the marketplace:

```
claude --plugin-dir /path/to/cc-resume-watchdog
```

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT
