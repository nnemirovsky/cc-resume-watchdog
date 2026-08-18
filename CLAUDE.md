# cc-resume-watchdog

Claude Code plugin that resumes a session when a turn is killed by a transient API
stream failure. Entirely bash based.

## Dependencies

- bash (4.0+)
- jq

## File structure

```
.claude-plugin/
  plugin.json          # Plugin metadata and version
  marketplace.json     # Marketplace listing metadata
hooks/
  hooks.json           # Hook definitions (SessionStart, UserPromptSubmit)
  handlers/
    arm-watchdog.sh    # Emits additionalContext asking the agent to arm the monitor
bin/
  cc-resume-watch      # The watcher. Run under the Monitor tool, persistent
tests/
  helpers.bash         # Transcript fixture builders and a bounded watcher runner
  arm-watchdog.bats
  resume-watch.bats
```

## The mechanism, in short

A stream that drops after Claude Code has emitted a block is not retried, because
re-issuing could run the same tool calls twice. The turn ends with a synthetic
assistant message carrying `isApiErrorMessage: true` and `model: "<synthetic>"`, and
the main agent loop returns on it before reaching the Stop hook runner. That is why
no hook fires.

A background task notification does re-invoke the agent loop after that dead turn.
`bin/cc-resume-watch` runs under the Monitor tool, so each line it prints becomes
such a notification.

Hooks cannot call tools, so `arm-watchdog.sh` cannot arm the monitor. It returns
`hookSpecificOutput.additionalContext` with the call already filled in. The watcher
touches a heartbeat file every poll and the handler stays silent while that
heartbeat is fresh, which is what keeps the arming self-healing instead of one-shot.

## Detection rules

- Only the last `assistant` or `user` entry in the transcript counts. `progress`,
  `system` and `attachment` rows keep being appended after a dead turn and must not
  read as "something continued".
- `TRANSIENT_RE` is an allowlist. Everything not on it stalls the session on
  purpose.
- Resumes are de-duplicated on message uuid and rate limited to `max_per_hour`
  inside a rolling `CC_RESUME_WINDOW`. The limit exists to catch a loop where every
  resume dies again, not to budget a long session. The watcher never exits on its
  own, it only goes quiet until the window clears.

## Testing

```
bats tests/*.bats
shellcheck --severity=error bin/cc-resume-watch hooks/handlers/*.sh
```

Tests must not touch the real `~/.claude`. Use `CC_RESUME_STATE_DIR` and
`CC_RESUME_HEARTBEAT`.

## Commits

Scoped conventional commits, lowercase description. Example:
`feat(watch): add ECONNRESET to the resume allowlist`.
