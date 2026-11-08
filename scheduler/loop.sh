#!/bin/bash
# Node scheduler for one repository: starts `claude -p "/node <ID>"` for the first ready node
# (ready.py) in its own worktree, one session at a time.
#   tmux new -d -s sched ~/gitrepos/noodlebot/scheduler/loop.sh
#   touch ~/STOP          (the loop exits within seconds; a running session keeps going)
# It acts as soon as something changes: it checks the node markers and the running session every
# SCHED_POLL seconds (default 2, local only) and asks GitHub about PRs every SCHED_TICK seconds
# (default 60); after each tick it updates the GitHub status issue (report.py). Only one loop runs at a time (state/<name>/loop.lock). Sessions run under setsid and
# are recorded in node/<ID>/session.pid, so a restarted loop picks up a running session instead of
# starting a second one.
# Layout under ~/gitrepos/noodlebot (all ignored by git):
#   repos/<name>             a clone of the repository, used only by the scheduler (never the owner's checkout)
#   worktrees/<name>/<ID>    one worktree per node, on node/<ID>-<name>
#   state/<name>/            status.log, heartbeat, report.json/report.log (the GitHub status issue); node/<ID>/{session.jsonl,session.stderr,unattended.md,
#                            session.pid,session.rc,starts} and the markers ready.py reads:
#                            QUESTION.md, ANSWER.md (the owner's), WAITING-PR, FAILED;
#                            answered/ keeps released questions and spec PRs
# Reads ~/.config/noodlebot/token (GitHub App token for gh) and ~/.config/noodlebot/oauth-token
# (CLAUDE_CODE_OAUTH_TOKEN, read by run-session.sh for the session only).
set -u -o pipefail
repo=tuckermclean/themonolith
nb=$(cd "$(dirname "$0")/.." && pwd -P) || exit 2
here=$nb/scheduler
clone=$nb/repos/${repo#*/}
wtroot=$nb/worktrees/${repo#*/}
state=$nb/state/${repo#*/}
oauth=$HOME/.config/noodlebot/oauth-token
log=$state/status.log
tick_s=${SCHED_TICK:-60} poll_s=${SCHED_POLL:-2} quiet_s=600
mkdir -p "$state/node" "$wtroot"
pid='' node='' last_note='' last_note_t=0

say() { echo "$(date -u +%FT%TZ) $*" >>"$log"; echo "$*"; }
# note <text> [<extra>]: like say, but a line equal to the last note is written only every
# $quiet_s seconds (with <extra> appended), so an idle loop leaves one line per 10 minutes.
note() {
	local now; now=$(date +%s)
	if [ "$1" != "$last_note" ] || [ $((now - last_note_t)) -ge $quiet_s ]; then
		say "$1${2:+, $2}"; last_note=$1 last_note_t=$now
	fi
}
ids() { sed -n 's#^node/\([A-Z][0-9][0-9]\)-.*#\1#p' | sort -u | tr '\n' ' '; }
starts_of() { cat "$state/node/$1/starts" 2>/dev/null || echo 0; }
set_starts() { echo "$2" >"$state/node/$1/starts"; }
[ -r "$oauth" ] || { echo "loop.sh: $oauth is missing (claude setup-token)" >&2; exit 2; }
exec 9>"$state/loop.lock"
flock -n 9 || { echo "loop.sh: another loop is already running for $repo" >&2; exit 1; }
[ -d "$clone/.git" ] || git clone -q "https://github.com/$repo" "$clone" || { echo "loop.sh: cannot clone $repo" >&2; exit 2; }

# alive <pid> <ID>: the process exists and is that node's session (guards against pid reuse).
alive() {
	kill -0 "$1" 2>/dev/null || return 1
	tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null | grep -qE "run-session\.sh .* $2( |\$)|claude -p /node $2( |\$)"
}

# ended <ID> <saw>: a recorded session is gone; report how it ended and clear its pid file.
ended() {
	local id=$1 saw=$2 d=$state/node/$1 rc p
	p=$(cat "$d/session.pid"); wait "$p" 2>/dev/null
	rc=$(cat "$d/session.rc" 2>/dev/null || echo '?')
	rm -f "$d/session.pid"
	if [ -e "$d/QUESTION.md" ]; then say "$saw; session $id ended (rc $rc) with QUESTION.md"
	elif [ -e "$d/WAITING-PR" ]; then say "$saw; session $id ended (rc $rc) waiting for spec PR #$(cat "$d/WAITING-PR")"
	elif [[ " $open $merged " == *" $id "* ]]; then say "$saw; session $id ended (rc $rc) with a PR"
	elif [ "$(starts_of "$id")" -ge 2 ]; then
		echo "$(date -u +%FT%TZ) second exit (rc $rc) with no PR and no QUESTION.md" >"$d/FAILED"
		set_starts "$id" 0   # deleting FAILED gives the node 2 fresh starts
		say "$saw; session $id ended (rc $rc), no PR, no QUESTION.md, 2 starts used: wrote FAILED"
	else say "$saw; session $id ended (rc $rc), no PR, no QUESTION.md; may start again"
	fi
}

# report: after each tick (reusing its token, so no extra token request), mirror the state to the GitHub status issue and take the owner's answers
# from it (report.py). Returns 3 when it wrote an ANSWER.md, so the loop ticks again at once. Its
# failures go to report.log only: the scheduler never depends on it.
report() {
	[ "${SCHED_REPORT:-1}" = 1 ] || return 0
	[ -n "$tick_tok" ] || return 0   # the tick had no token or did not reach GitHub
	GH_TOKEN=$tick_tok timeout 120 python3 -I "$here/report.py" --repo "$repo" --state "$state" --worktrees "$wtroot" \
		2>&1 | sed "s/^/$(date -u +%FT%TZ) /" >>"$state/report.log"
}

open='' merged='' tick_tok=''
tick() {
	date +%s >"$state/heartbeat"
	git -C "$clone" fetch -q origin || { note "git fetch failed; nothing started"; return; }
	local tok
	tick_tok=''
	tok=$(~/.config/noodlebot/token) || { note "no GitHub App token; nothing started"; return; }
	tick_tok=$tok
	# pipefail: a failed gh must stop the tick, never read as "no PRs".
	if ! GH_TOKEN=$tok gh pr list --repo $repo --state merged --limit 500 --json number,headRefName \
			-q '.[] | "\(.number) \(.headRefName)"' >"$state/merged-prs.tsv" ||
		! open=$(GH_TOKEN=$tok gh pr list --repo $repo --state open --limit 500 --json headRefName -q '.[].headRefName' | ids); then
		note "gh pr list failed; nothing started"; return
	fi
	merged=$(cut -d' ' -f2 "$state/merged-prs.tsv" | ids)
	cut -d' ' -f1 "$state/merged-prs.tsv" >"$state/merged-prs.txt"
	local saw="open=[${open% }] merged-prs=[${merged% }]" f id
	tok=''

	# The running session, if any: recorded in a pid file, so this works after a restart too.
	pid='' node=''
	for f in "$state"/node/*/session.pid; do
		[ -e "$f" ] || continue
		id=$(basename "$(dirname "$f")")
		if alive "$(cat "$f")" "$id"; then pid=$(cat "$f") node=$id
		else ended "$id" "$saw"; fi
	done
	if [ -n "$pid" ]; then
		note "$saw; session $node (pid $pid) running" "log $(stat -c %s "$state/node/$node/session.jsonl" 2>/dev/null) bytes"
		return
	fi

	git -C "$clone" show origin/main:docs/graph.yaml >"$state/graph.yaml" || { note "no graph on origin/main"; return; }
	git -C "$clone" log --format=%s origin/main >"$state/subjects.txt"
	local args=() next name wt released
	for id in $merged; do args+=(--merged "$id"); done
	for id in $open; do args+=(--open "$id"); done
	next=$(python3 -I "$here/ready.py" --graph "$state/graph.yaml" --markers "$state/node" \
		--subjects "$state/subjects.txt" --merged-prs "$state/merged-prs.txt" "${args[@]}") ||
		{ note "$saw; ready.py failed; nothing started"; return; }
	[ -n "$next" ] || { note "$saw; nothing ready"; return; }
	id=${next%% *} name=${next#* }
	mkdir -p "$state/node/$id"
	# An answer or a merged spec PR is new information: the node gets 2 fresh starts.
	released=$(sh "$here/release-markers.sh" "$state/node/$id") || { note "$saw; releasing $id's markers failed"; return; }
	if [ -n "$released" ]; then set_starts "$id" 0; say "$saw; $id: $(echo "$released" | paste -sd';')"; fi
	[ "$(starts_of "$id")" -lt 2 ] || { note "$saw; $id ready but has used 2 starts; nothing started"; return; }

	wt=$wtroot/$id
	if [ ! -d "$wt" ]; then
		git -C "$clone" worktree add -q -b "node/$id-$name" "$wt" origin/main 2>/dev/null ||
			git -C "$clone" worktree add -q "$wt" "node/$id-$name" || { note "$saw; worktree for $id failed"; return; }
	fi
	sed -e "s|@ID@|$id|g" -e "s|@NAME@|$name|g" -e "s|@STATE@|$state|g" -e "s|@WT@|$wt|g" \
		"$here/unattended.md" >"$state/node/$id/unattended.md"
	rm -f "$state/node/$id/session.rc"
	# 9>&-: the session must not hold the loop's lock.
	setsid "$here/run-session.sh" "$wt" "$state/node/$id" "$id" </dev/null 9>&- \
		>"$state/node/$id/session.jsonl" 2>"$state/node/$id/session.stderr" &
	pid=$! node=$id
	echo "$pid" >"$state/node/$id/session.pid"
	set_starts "$id" $(($(starts_of "$id") + 1))
	say "$saw; started $id ($name) in $wt, pid $pid, start $(starts_of "$id") of 2"
}

# fingerprint: the markers and exit files under node/; a change means "look again now".
fingerprint() {
	find "$state/node" -maxdepth 2 -type f \( -name QUESTION.md -o -name ANSWER.md -o -name WAITING-PR \
		-o -name FAILED -o -name session.rc \) -printf '%p %T@\n' 2>/dev/null | sort | cksum
}

# pause: until the next GitHub poll is due, or sooner when a marker changes, the session exits or
# ~/STOP appears.
pause() {
	local fp end
	fp=$(fingerprint) end=$(($(date +%s) + tick_s))
	while [ "$(date +%s)" -lt "$end" ]; do
		sleep "$poll_s"
		[ -e ~/STOP ] && return
		[ -n "$pid" ] && ! alive "$pid" "$node" && return
		[ "$(fingerprint)" != "$fp" ] && return
	done
}

while :; do
	[ -e ~/STOP ] && { say "found ~/STOP; loop exits (session ${node:-none} ${pid:+pid $pid }keeps running)"; exit 0; }
	tick
	report; rc=$?; tick_tok=''; [ $rc = 3 ] && continue
	pause
done
