# cc-resume-watchdog

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

1. A `SessionStart` and `UserPromptSubmit` hook checks a heartbeat file. If the
   session is already covered it exits without printing anything.
2. Otherwise it returns `additionalContext` holding the exact `Monitor` call to
   make, already filled in with this session's transcript path.
3. The monitor runs `bin/cc-resume-watch`, which polls the transcript. When the
   last conversational entry is a transient stream failure that has been sitting
   for `grace` seconds, it prints one line. That line becomes a task notification,
   which restarts the turn.

Hooks cannot call tools, which is why step 2 goes through the model rather than
arming the monitor directly. The heartbeat is what makes this self-healing. If the
monitor was never armed, or died, the next prompt asks again. While a watcher is
alive the hook costs one `stat` per prompt and prints nothing.

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
retrying those is worse than stalling. It also de-duplicates on message uuid and
stops after `max` resumes, so an outage cannot turn into a loop.

## Install

```
/plugin marketplace add nnemirovsky/cc-resume-watchdog
/plugin install cc-resume-watchdog
```

Needs `bash`, `jq`, and a session transcript on disk. Hooks load at session start,
so restart Claude Code afterwards.

## Tuning

```
bin/cc-resume-watch <transcript.jsonl> [grace=25] [poll=10] [max=25]
```

* `grace` is how many seconds the error must sit as the last entry before a resume
  fires. Lower recovers faster. Too low and it can fire while Claude Code is still
  finishing up.
* `poll` is the transcript poll interval in seconds.
* `max` is the resume cap for one session. The watcher prints a stand-down line and
  exits once it is passed.

Both scripts read these overrides, which the test suite uses so nothing touches
real state:

* `CC_RESUME_HEARTBEAT` is the file the watcher touches on every poll.
* `CC_RESUME_STATE_DIR` is the hook's state root. Defaults to
  `$XDG_STATE_HOME/cc-resume-watchdog`.
* `CC_RESUME_HB_MAX_AGE` is how many seconds a heartbeat stays trusted. Default 90.

## Limits

* Covers turn death, not process death. If the CLI exits, the monitor goes with it.
  That case needs an external supervisor.
* Subagent turns die the same way and are not covered. A subagent that hits this
  returns null to its caller.
* Arming depends on the model acting on the hook's context. The `UserPromptSubmit`
  re-check keeps that eventually consistent rather than one-shot.

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
