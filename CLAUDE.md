# resume-watchdog

Claude Code plugin that resumes a session when a turn is killed by a transient API
stream failure. Entirely bash based.

## Dependencies

- bash (4.0+)
- jq

## File structure

```
CLAUDE.md              # This file. Contributor notes, not loaded as plugin context
.claude-plugin/
  plugin.json          # Plugin metadata and version
  marketplace.json     # Marketplace listing metadata
hooks/
  hooks.json           # SessionStart, UserPromptSubmit, PostToolUse. All async+asyncRewake
  handlers/
    arm.sh             # Singleton guard, then execs into the watcher
bin/
  cc-resume-watch      # The watcher. Exits 2 to wake the model
tests/
  helpers.bash         # Transcript fixture builders and a bounded watcher runner
  arm.bats
  resume-watch.bats
  subagents.bats
```

## The mechanism, in short

A stream that drops after Claude Code has emitted a block is not retried, because
re-issuing could run the same tool calls twice. The turn ends with a synthetic
assistant message carrying `isApiErrorMessage: true` and `model: "<synthetic>"`, and
the main agent loop returns on it before reaching the Stop hook runner. That is why
no hook fires.

An `async` plus `asyncRewake` hook that exits 2 wakes the model with the process's
stderr as the body. No model involvement and no tool call, which is the whole
mechanism here.

Verified against 2.1.234 and 2.1.235:

- The gate is `e.async || (e.asyncRewake && K)`, so `async: true` backgrounds
  regardless of interactivity. Without it a headless run would execute the hook
  synchronously and wedge.
- `SessionStart`, `UserPromptSubmit` and `PostToolUse` all honour the rewake.
- The rewake fires on process *exit*, so a watcher is spent by resuming. That is
  why three events arm, not one.
- Claude Code never reaps the detached process, which is why the watcher follows
  its owner pid out.

`arm.sh` claims `<state>.pid` with noclobber, so when SessionStart and
UserPromptSubmit fire together exactly one of them wins. The winner execs into the
watcher, which keeps the recorded pid valid. Every later arming event finds a live
pid and exits after a `kill -0`, which is what keeps the arming self-healing instead
of one-shot. A watcher killed while its owner is still alive spawns its own
replacement and logs why it went to `<state>.log`.

Subagent transcripts under `<transcript>/subagents/` are watched too. A background
subagent that dies transiently cannot be resumed, so the parent gets woken to decide
whether to re-dispatch the work.

## Detection rules

- Only the last `assistant` or `user` entry in the transcript counts. `progress`,
  `system` and `attachment` rows keep being appended after a dead turn and must not
  read as "something continued".
- `TRANSIENT_RE` is an allowlist. Everything not on it stalls the session on
  purpose.
- Resumes are de-duplicated on message uuid and rate limited to `max_per_hour`
  inside a rolling `CC_RESUME_WINDOW`. The limit exists to catch a loop where every
  resume dies again, not to budget a long session. Both live on disk because a
  watcher only survives until it resumes once.
- While throttled the watcher stays up and quiet rather than exiting, so the
  session is still covered when the window clears.

## Testing

```
bats tests/*.bats
shellcheck --severity=error bin/cc-resume-watch hooks/handlers/*.sh
```

Tests must not touch the real `~/.claude` or state dir. Use `CC_RESUME_STATE_DIR`
for `arm.sh`, `CC_RESUME_STATE` for the watcher, and pin `CC_RESUME_OWNER` so the
watcher never reads the session registry.

## Commits

Scoped conventional commits, lowercase description. Example:
`feat(watch): add ECONNRESET to the resume allowlist`.
