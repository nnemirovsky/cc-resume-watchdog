# Contributing

Thanks for looking at `resume-watchdog`. This covers the dev loop and how tests
run.

## Local dev loop

Load the plugin from a working tree instead of through the marketplace:

```
claude --plugin-dir /path/to/cc-resume-watchdog
```

Every Claude Code restart re-reads the plugin from disk. No `/plugin install`, no
marketplace cache to flush.

Hooks load at session start, so a change to `hooks/hooks.json` or to a handler needs
a restart before it takes effect.

## Running tests

Everything is bash, and everything is covered by bats:

```
bats tests/*.bats
```

One file while iterating:

```
bats tests/resume-watch.bats
```

The suite builds synthetic transcripts in `$BATS_TEST_TMPDIR` and points both
scripts at a throwaway state directory through `CC_RESUME_STATE_DIR` and
`CC_RESUME_STATE`, so it never reads or writes your real `~/.claude`.

Lint before opening a PR:

```
shellcheck --severity=error bin/cc-resume-watch hooks/handlers/*.sh
```

CI runs both on every PR.

## Adding an error to the resume list

`TRANSIENT_RE` in `bin/cc-resume-watch` is an allowlist, and it should stay one. Add
a pattern only when the failure is purely a transport problem, meaning the request
and the account are both fine and re-running is safe. Anything that needs a human
decision must keep stalling the session.

Every pattern you add needs a case in the "resumes every transient variant" test,
and anything you deliberately exclude belongs in "ignores the other errors that need
a human".

## Commits

Scoped conventional commits with a lowercase description:

```
feat(watch): add ECONNRESET to the resume allowlist
fix(hook): keep quiet when the transcript path is missing
```
