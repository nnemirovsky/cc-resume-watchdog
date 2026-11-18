# Security policy

## Reporting a vulnerability

Report privately through GitHub, not in a public issue:

**[Open a private security advisory](https://github.com/nnemirovsky/cc-resume-watchdog/security/advisories/new)**

The report is visible only to the maintainer ([@nnemirovsky](https://github.com/nnemirovsky)) until an advisory is published, so nothing sensitive is exposed while a fix is prepared. Expect an acknowledgement within a week.

If the form is unavailable, open a normal issue that says only "I would like a private channel for a security report", with no details, and a private advisory will be opened for you.

Never attach real credentials, tokens, personal data or private files to a report. Describe the shape of the problem instead.

## Supported versions

Only the latest release gets security fixes.

## Scope

resume-watchdog wakes Claude without you, so a wake-up nobody wanted is the main risk. In scope:

- Resuming after an error that is not on the transient allowlist, such as a rate limit, a billing or login error or a refused request.
- Resuming the same dead turn twice, or more often than the hourly limit allows.
- Anything other than the API error text and the subagent's transcript name reaching the wake-up message, for example transcript content that would read as instructions to Claude.
- Acting on a process other than the Claude Code instance that owns the session.
- Writing outside its state directory, or state files that another local user can plant or redirect.

Out of scope:

- What Claude does after the wake-up. Claude Code and the model decide that.
- Anything that needs an attacker who can already run code as you or write to `~/.claude`.

