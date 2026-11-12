#!/bin/sh
# A fake `claude` for the Claude Code backend's tests: install it as "claude" on a temporary PATH (a symlink).
# It prints a scripted stream-json file and exits with a chosen code, and records what it was given.
#   FAKE_CLAUDE_REC     folder for the records (required): "argv" gets "--- call" and then one argument per line,
#                       "env" gets "CLAUDE_CODE_OAUTH_TOKEN=<value|UNSET>", "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=<value|UNSET>",
#                       "GH_TOKEN=<set|unset>" and "ANTHROPIC_API_KEY=<set|unset>" per call
#   FAKE_CLAUDE_STREAM  file written to stdout (the raw stream-json); none: nothing
#   FAKE_CLAUDE_STDERR  file written to stderr
#   FAKE_CLAUDE_RC      exit code (default 0)
# The records hold the credential itself, so a test must keep $FAKE_CLAUDE_REC/env out of the files it scans for it.
rec=${FAKE_CLAUDE_REC:?FAKE_CLAUDE_REC}
mkdir -p "$rec"
{ echo "--- call"; for a in "$@"; do printf '%s\n' "$a"; done; } >>"$rec/argv"
{
	echo "CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN-UNSET}"
	echo "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS-UNSET}"
	echo "GH_TOKEN=${GH_TOKEN:+set}"
	echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:+set}"
} >>"$rec/env"
[ -z "${FAKE_CLAUDE_STREAM:-}" ] || cat "$FAKE_CLAUDE_STREAM"
[ -z "${FAKE_CLAUDE_STDERR:-}" ] || cat "$FAKE_CLAUDE_STDERR" >&2
exit "${FAKE_CLAUDE_RC:-0}"
