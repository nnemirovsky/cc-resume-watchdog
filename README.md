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

Two watchers, same detection, different delivery.

**The rewake watcher** starts at `SessionStart` as an `async` plus `asyncRewake`
hook, with no model involvement at all. On the first transient failure it writes
the resume instruction to stderr and exits 2, and Claude Code turns that into a
wake-up for the model. This is what covers the window before you have typed
anything, including on a resumed session. It is good for one hit, because the
rewake fires when the process exits.

**The monitor** covers everything after that. The same `SessionStart` hook, plus
`UserPromptSubmit`, checks a heartbeat file and returns `additionalContext` holding
the exact `Monitor` call to make, already filled in with this session's transcript
path. Each line the monitor prints becomes a task notification, which restarts the
turn. Unlimited hits, rate limited.

The monitor half goes through the model because hooks cannot call tools. The
heartbeat is what makes it self-healing. If it was never armed, or died, the next
prompt asks again, and while a watcher is alive the hook costs one `stat` per
prompt and prints nothing.

The two share a ledger of resumed message uuids, so a single drop is never resumed
twice.

Both watchers resolve the pid of the Claude Code process that owns their transcript
and exit once it is gone. Claude Code never reaps a detached async hook, so without
that a watcher outlives the session it was watching.

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

* `CC_RESUME_MODE` is `monitor` (default) or `rewake`.
* `CC_RESUME_HEARTBEAT` is the file the watcher touches on every poll.
* `CC_RESUME_LEDGER` is the shared list of resumed uuids.
* `CC_RESUME_OWNER_PID` is the Claude Code pid to follow. Resolved from the session
  registry when unset.
* `CC_RESUME_WINDOW` is the rate-limit window in seconds. Default 3600.
* `CC_RESUME_STATE_DIR` is the hook's state root. Defaults to
  `$XDG_STATE_HOME/resume-watchdog`.
* `CC_RESUME_HB_MAX_AGE` is how many seconds a heartbeat stays trusted. Default 90.

## Limits

* Covers turn death, not process death. If the CLI exits, so do the watchers, by
  design.
* Subagent turns die the same way and are not covered. A subagent that hits this
  returns null to its caller.
* The monitor half depends on the model acting on the hook's context. Measured at
  16/16 over two trials of fresh sessions with an ordinary first prompt, and the
  `UserPromptSubmit` re-check keeps it eventually consistent. The rewake half needs
  no model at all.

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
