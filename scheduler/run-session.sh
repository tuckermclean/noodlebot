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
here=$(cd "$(dirname "$0")" && pwd -P)   # before the cd: $0 may be relative
plugin=$(cd "$here/../plugin" && pwd -P)
cd "$wt" || { echo 2 >"$dir/session.rc"; exit 2; }
unset ANTHROPIC_API_KEY GH_TOKEN GITHUB_TOKEN
# the forge the session reaches (G04): the repository, the forge CLI and the token script (never a token: GH_TOKEN stays unset)
[ -z "${NOODLEBOT_FORGE_REPO:-}" ] || export NOODLEBOT_FORGE_REPO
export NOODLEBOT_FORGE="$here/forge.py" NOODLEBOT_FORGE_TOKEN_SCRIPT="${NOODLEBOT_FORGE_TOKEN_SCRIPT:-$HOME/.config/noodlebot/token}"
[ -z "${NOODLEBOT_VERSION:-}" ] || export NOODLEBOT_VERSION
# the harness backend (harness.py, SCHED_HARNESS) runs the session, keeps its credential and writes events.jsonl: its
# first stage becomes the agent CLI (a direct child of this script, the process the loop signals), the second one
# passes the raw stream on and records the events. The exit code is the first stage's.
pf="$dir/agent.pid"; rm -f "$pf"
if [ -n "$sid" ]; then
	python3 -I "$here/harness.py" exec-resume "$pf" "$wt" "$dir" "$sid" "$(cat "$dir/resume-prompt.md")" \
		| python3 -I "$here/harness.py" record "$dir" append "$pf"
	rc=${PIPESTATUS[0]}
else
	python3 -I "$here/harness.py" exec-start "$pf" "$wt" "$dir" "$prompt" "$dir/unattended.md" "$plugin" \
		| python3 -I "$here/harness.py" record "$dir" fresh "$pf"
	rc=${PIPESTATUS[0]}
fi
rm -f "$pf"
echo "$rc" >"$dir/session.rc.tmp" && mv "$dir/session.rc.tmp" "$dir/session.rc"
exit "$rc"
