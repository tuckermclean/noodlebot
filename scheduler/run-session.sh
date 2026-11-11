#!/bin/bash
# run-session.sh <worktree> <state-dir> <prompt> [<session id>]: one unattended session ("/node B03",
# "/noodlebot:triage 46"), with the bot's plugin (../plugin) loaded, started by loop.sh
# under setsid, so it has its own process group and no terminal: stopping the loop or closing its
# tmux window never stops a session. Writes the exit code to <node-state-dir>/session.rc (the loop
# reads it, even after a restart). stdout/stderr are set up by the loop. With a session id it resumes
# that conversation (the harness's resume) with the prompt in <state-dir>/resume-prompt.md, after the
# usage limit left it idle; <prompt> then only names the task, as the loop's process check reads it.
set -u
wt=$1 dir=$2 prompt=$3 sid=${4:-}
plugin=$(cd "$(dirname "$0")/../plugin" && pwd -P)
cd "$wt" || { echo 2 >"$dir/session.rc"; exit 2; }
unset ANTHROPIC_API_KEY GH_TOKEN GITHUB_TOKEN
[ -z "${NOODLEBOT_VERSION:-}" ] || export NOODLEBOT_VERSION
here=$(cd "$(dirname "$0")" && pwd -P)
# the harness backend (harness.py, SCHED_HARNESS) runs the session, keeps its credential and writes events.jsonl
if [ -n "$sid" ]; then
	python3 -I "$here/harness.py" resume "$wt" "$dir" "$sid" "$(cat "$dir/resume-prompt.md")"
else
	python3 -I "$here/harness.py" start "$wt" "$dir" "$prompt" "$dir/unattended.md" "$plugin"
fi
rc=$?
echo "$rc" >"$dir/session.rc.tmp" && mv "$dir/session.rc.tmp" "$dir/session.rc"
exit "$rc"
