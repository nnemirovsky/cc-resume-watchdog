# Privacy policy

resume-watchdog runs entirely on your machine. It has no server, makes no network
requests, and collects no telemetry. Nothing it reads or writes is sent to the
author or to any third party.

## What it reads

* The transcript of the current Claude Code session, and the transcripts of that
  session's subagents. Only the last 80 lines are parsed, and only for the
  entry type, message id, timestamp and error text, to tell whether a turn died on
  a transient API error.
* Claude Code's session registry under `~/.claude/sessions/`, to find the process
  id of the Claude Code instance that owns the session.

## What it writes

Small state files per session, under `$XDG_STATE_HOME/resume-watchdog`
(`~/.local/state/resume-watchdog` by default):

* the process id of the running watcher
* the message ids of turns it has already resumed
* the times of recent resumes, for the rate limit
* the time, reason and process ids when a watcher exits

None of these hold message content. Delete the directory at any time to remove
them.

## What it passes to Claude

When it resumes a session, it hands Claude Code a short wake-up message that
quotes the API error text and, for a subagent, the subagent's transcript name.
That message becomes part of your session like any other turn, and Claude Code
handles it under Anthropic's terms, not this plugin's.

## Contact

Questions go to [GitHub issues](https://github.com/nnemirovsky/cc-resume-watchdog/issues).