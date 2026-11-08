#!/bin/bash
# run-session.sh <worktree> <state-dir> <prompt>: one unattended session ("/node B03",
# "/noodlebot:triage 46"), with the bot's plugin (../plugin) loaded, started by loop.sh
# under setsid, so it has its own process group and no terminal: stopping the loop or closing its
# tmux window never stops a session. Writes the exit code to <node-state-dir>/session.rc (the loop
# reads it, even after a restart). stdout/stderr are set up by the loop.
set -u
wt=$1 dir=$2 prompt=$3
plugin=$(cd "$(dirname "$0")/../plugin" && pwd -P)
cd "$wt" || { echo 2 >"$dir/session.rc"; exit 2; }
unset ANTHROPIC_API_KEY GH_TOKEN GITHUB_TOKEN
CLAUDE_CODE_OAUTH_TOKEN=$(cat "$HOME/.config/noodlebot/oauth-token"); export CLAUDE_CODE_OAUTH_TOKEN
claude -p "$prompt" --plugin-dir "$plugin" --permission-mode auto --permission-prompts none \
	--output-format stream-json --verbose --append-system-prompt "$(cat "$dir/unattended.md")"
rc=$?
echo "$rc" >"$dir/session.rc.tmp" && mv "$dir/session.rc.tmp" "$dir/session.rc"
exit "$rc"
