#!/bin/bash
# v0 node scheduler for one repository. Every 10 minutes: find the first ready node (ready.py) and, if
# no session is running, start `claude -p "/node <ID>"` for it in its own worktree. One session at a time.
#   tmux new -d -s sched ~/gitrepos/noodlebot/scheduler/loop.sh
#   touch ~/STOP          (the loop exits at its next tick; a running session keeps going)
# Layout under ~/gitrepos/noodlebot (all ignored by git):
#   repos/<name>             a clone of the repository, used only by the scheduler (never the owner's checkout)
#   worktrees/<name>/<ID>    one worktree per node, on node/<ID>-<name>
#   state/<name>/            status.log; node/<ID>/{session.jsonl,session.stderr,unattended.md,QUESTION.md,FAILED}
# Reads ~/.config/noodlebot/token (GitHub App token for gh) and ~/.config/noodlebot/oauth-token
# (CLAUDE_CODE_OAUTH_TOKEN, given to the session only). SCHED_TICK overrides the 600 s tick (tests).
set -u -o pipefail
repo=tuckermclean/themonolith
nb=$(cd "$(dirname "$0")/.." && pwd -P) || exit 2
here=$nb/scheduler
clone=$nb/repos/${repo#*/}
wtroot=$nb/worktrees/${repo#*/}
state=$nb/state/${repo#*/}
oauth=$HOME/.config/noodlebot/oauth-token
log=$state/status.log
mkdir -p "$state/node" "$wtroot"
declare -A starts
pid='' node=''

say() { echo "$(date -u +%FT%TZ) $*" >>"$log"; echo "$*"; }
ids() { sed -n 's#^node/\([A-Z][0-9][0-9]\)-.*#\1#p' | sort -u | tr '\n' ' '; }
[ -r "$oauth" ] || { echo "loop.sh: $oauth is missing (claude setup-token)" >&2; exit 2; }
[ -d "$clone/.git" ] || git clone -q "https://github.com/$repo" "$clone" || { echo "loop.sh: cannot clone $repo" >&2; exit 2; }

tick() {
	git -C "$clone" fetch -q origin || { say "git fetch failed; nothing started"; return; }
	local tok merged open
	tok=$(~/.config/noodlebot/token) || { say "no GitHub App token; nothing started"; return; }
	# pipefail: a failed gh must stop the tick, never read as "no PRs".
	if ! merged=$(GH_TOKEN=$tok gh pr list --repo $repo --state merged --limit 500 --json headRefName -q '.[].headRefName' | ids) ||
		! open=$(GH_TOKEN=$tok gh pr list --repo $repo --state open --limit 500 --json headRefName -q '.[].headRefName' | ids); then
		say "gh pr list failed; nothing started"; return
	fi
	local saw="open=[${open% }] merged-prs=[${merged% }]"

	if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
		say "$saw; session $node (pid $pid) running, log $(stat -c %s "$state/node/$node/session.jsonl") bytes"
		return
	fi
	if [ -n "$pid" ]; then
		wait "$pid"; local rc=$?
		if [[ " $open $merged " == *" $node "* ]]; then say "$saw; session $node ended (rc $rc) with a PR"
		elif [ -e "$state/node/$node/QUESTION.md" ]; then say "$saw; session $node ended (rc $rc) with QUESTION.md"
		elif [ "${starts[$node]}" -ge 2 ]; then
			echo "$(date -u +%FT%TZ) second exit (rc $rc) with no PR and no QUESTION.md" >"$state/node/$node/FAILED"
			say "$saw; session $node ended (rc $rc), no PR, no QUESTION.md, 2 starts used: wrote FAILED"
		else say "$saw; session $node ended (rc $rc), no PR, no QUESTION.md; may start again"
		fi
		pid='' node=''
	fi

	git -C "$clone" show origin/main:docs/graph.yaml >"$state/graph.yaml" || { say "no graph on origin/main"; return; }
	git -C "$clone" log --format=%s origin/main >"$state/subjects.txt"
	local args=() id next name wt
	for id in $merged; do args+=(--merged "$id"); done
	for id in $open; do args+=(--open "$id"); done
	next=$(python3 -I "$here/ready.py" --graph "$state/graph.yaml" --markers "$state/node" \
		--subjects "$state/subjects.txt" "${args[@]}") || { say "$saw; ready.py failed; nothing started"; return; }
	[ -n "$next" ] || { say "$saw; nothing ready"; return; }
	id=${next%% *} name=${next#* }
	[ "${starts[$id]:-0}" -lt 2 ] || { say "$saw; $id ready but has used 2 starts; nothing started"; return; }

	wt=$wtroot/$id
	if [ ! -d "$wt" ]; then
		git -C "$clone" worktree add -q -b "node/$id-$name" "$wt" origin/main 2>/dev/null ||
			git -C "$clone" worktree add -q "$wt" "node/$id-$name" || { say "$saw; worktree for $id failed"; return; }
	fi
	mkdir -p "$state/node/$id"
	sed -e "s|@ID@|$id|g" -e "s|@NAME@|$name|g" -e "s|@STATE@|$state|g" -e "s|@WT@|$wt|g" \
		"$here/unattended.md" >"$state/node/$id/unattended.md"
	(
		cd "$wt" || exit 2
		unset ANTHROPIC_API_KEY GH_TOKEN GITHUB_TOKEN
		CLAUDE_CODE_OAUTH_TOKEN=$(cat "$oauth"); export CLAUDE_CODE_OAUTH_TOKEN
		exec claude -p "/node $id" --permission-mode auto --permission-prompts none \
			--output-format stream-json --verbose --append-system-prompt "$(cat "$state/node/$id/unattended.md")"
	) </dev/null >"$state/node/$id/session.jsonl" 2>"$state/node/$id/session.stderr" &
	pid=$! node=$id
	starts[$id]=$((${starts[$id]:-0} + 1))
	say "$saw; started $id ($name) in $wt, pid $pid, start ${starts[$id]} of 2"
}

while :; do
	[ -e ~/STOP ] && { say "found ~/STOP; loop exits (session ${node:-none} ${pid:+pid $pid }keeps running)"; exit 0; }
	tick
	sleep "${SCHED_TICK:-600}"
done
