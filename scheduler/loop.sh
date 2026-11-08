#!/bin/bash
# Node scheduler for one repository: starts a `claude -p "/noodlebot:node <ID>"` session for every
# ready node (ready.py --all), each in its own worktree, all at once (SCHED_MAX caps them; default
# 0, no cap), plus one triage at a time for issues the owner labels `noodlebot`.
#   tmux new -d -s sched ~/gitrepos/noodlebot/scheduler/loop.sh [owner/name]   (default tuckermclean/themonolith)
# One loop per repository, each with its own lock, state and status issue.
#   touch ~/STOP          (every loop exits within seconds; running sessions keep going)
#   touch ~/STOP-<name>   (only that repository's loop exits)
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
repo=${1:-tuckermclean/themonolith}
case $repo in */*) ;; *) echo "loop.sh: the argument is owner/name, not $repo" >&2; exit 2 ;; esac
nb=$(cd "$(dirname "$0")/.." && pwd -P) || exit 2
here=$nb/scheduler
clone=$nb/repos/${repo#*/}
wtroot=$nb/worktrees/${repo#*/}
state=$nb/state/${repo#*/}
oauth=$HOME/.config/noodlebot/oauth-token
log=$state/status.log
tick_s=${SCHED_TICK:-60} poll_s=${SCHED_POLL:-2} quiet_s=600
mkdir -p "$state/node" "$state/issue" "$wtroot"
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
# starts_of <dir> / set_starts <dir> <n>: a task's session starts (node/<ID> or issue/<N>).
starts_of() { cat "$1/starts" 2>/dev/null || echo 0; }
set_starts() { echo "$2" >"$1/starts"; }
[ -r "$oauth" ] || { echo "loop.sh: $oauth is missing (claude setup-token)" >&2; exit 2; }
exec 9>"$state/loop.lock"
flock -n 9 || { echo "loop.sh: another loop is already running for $repo" >&2; exit 1; }
[ -d "$clone/.git" ] || git clone -q "https://github.com/$repo" "$clone" || { echo "loop.sh: cannot clone $repo" >&2; exit 2; }

# alive <pid> <key>: the process exists and is that task's session, whose prompt ends in <key>
# (a node ID or an issue number); guards against pid reuse.
alive() {
	kill -0 "$1" 2>/dev/null || return 1
	tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null | grep -qE "run-session\.sh .* $2( |\$)|claude -p /node $2( |\$)"
}

# limit_exit <dir>: the session ended because of the plan's usage limit: its last rate_limit_event is
# not "allowed", or its last result names a usage or rate limit. Such an end uses up no start.
limit_exit() {
	tail -c 400000 "$1/session.jsonl" 2>/dev/null | python3 -I -c '
import json, re, sys
ev = res = None
for line in sys.stdin:
    if "\"rate_limit_event\"" in line or "\"type\":\"result\"" in line.replace(" ", ""):
        try: d = json.loads(line)
        except ValueError: continue
        if d.get("type") == "rate_limit_event": ev = d
        elif d.get("type") == "result": res = d
st = ((ev or {}).get("rate_limit_info") or {}).get("status", "allowed")
txt = str((res or {}).get("result") or "") + " " + str((res or {}).get("subtype") or "")
sys.exit(0 if st != "allowed" or re.search(r"usage limit|rate limit|limit reached|hit your limit", txt, re.I) else 1)'
}

# not_counted <dir>: give back the start a limit exit used.
not_counted() { local n; n=$(starts_of "$1"); [ "$n" -gt 0 ] && set_starts "$1" $((n - 1)); }

# ended <dir> <saw>: a recorded session is gone; report how it ended and clear its pid file.
ended() {
	local d=$1 saw=$2 id rc p
	id=$(basename "$d")
	p=$(cat "$d/session.pid"); wait "$p" 2>/dev/null
	rc=$(cat "$d/session.rc" 2>/dev/null || echo '?')
	rm -f "$d/session.pid"
	if [ "$(basename "$(dirname "$d")")" = issue ]; then triage_ended "$d" "$saw" "$rc"; return; fi
	if [ -e "$d/QUESTION.md" ]; then say "$saw; session $id ended (rc $rc) with QUESTION.md"
	elif [ -e "$d/WAITING-PR" ]; then say "$saw; session $id ended (rc $rc) waiting for spec PR #$(cat "$d/WAITING-PR")"
	elif [[ " $open $merged " == *" $id "* ]]; then say "$saw; session $id ended (rc $rc) with a PR"
	elif [ "$rc" != 0 ] && limit_exit "$d"; then
		not_counted "$d"
		say "$saw; session $id stopped by the usage limit (rc $rc); start not counted, it resumes when the throttle opens"
	elif [ "$(starts_of "$d")" -ge 2 ]; then
		echo "$(date -u +%FT%TZ) second exit (rc $rc) with no PR and no QUESTION.md" >"$d/FAILED"
		set_starts "$d" 0   # deleting FAILED gives the node 2 fresh starts
		say "$saw; session $id ended (rc $rc), no PR, no QUESTION.md, 2 starts used: wrote FAILED"
	else say "$saw; session $id ended (rc $rc), no PR, no QUESTION.md; may start again"
	fi
}

# triage_ended <dir> <saw> <rc>: an issue's triage session is gone. Done (rc 0, no question): the
# label becomes noodlebot-triaged (issues.py done) and its worktree goes.
triage_ended() {
	local d=$1 saw=$2 rc=$3 n
	n=$(basename "$d")
	if [ -e "$d/QUESTION.md" ]; then say "$saw; triage of #$n ended (rc $rc) with QUESTION.md"
	elif [ "$rc" = 0 ]; then
		set_starts "$d" 0
		git -C "$clone" worktree remove --force "$wtroot/issue-$n" 2>/dev/null
		if GH_TOKEN=$tick_tok python3 -I "$here/issues.py" done --repo "$repo" --number "$n" 2>>"$state/report.log"; then
			say "$saw; triage of #$n done (rc 0); its label is now noodlebot-triaged"
		else
			echo "$(date -u +%FT%TZ) triage done, but swapping the label failed (report.log); remove the noodlebot label, then delete this file" >"$d/FAILED"
			say "$saw; triage of #$n done (rc 0), but swapping its label failed: wrote FAILED"
		fi
	elif limit_exit "$d"; then
		not_counted "$d"
		say "$saw; triage of #$n stopped by the usage limit (rc $rc); start not counted"
	elif [ "$(starts_of "$d")" -ge 2 ]; then
		echo "$(date -u +%FT%TZ) second exit (rc $rc) without finishing" >"$d/FAILED"
		set_starts "$d" 0
		say "$saw; triage of #$n ended (rc $rc), 2 starts used: wrote FAILED"
	else say "$saw; triage of #$n ended (rc $rc); may start again"
	fi
}

# launch <worktree> <dir> <prompt>: start a session in the background; sets pid and node (the
# prompt's last word: a node ID or an issue number).
launch() {
	rm -f "$2/session.rc"
	# 9>&-: the session must not hold the loop's lock.
	setsid "$here/run-session.sh" "$1" "$2" "$3" </dev/null 9>&- >"$2/session.jsonl" 2>"$2/session.stderr" &
	pid=$! node=${3##* }
	echo "$pid" >"$2/session.pid"
	set_starts "$2" $(($(starts_of "$2") + 1))
}

# start_triage <N> <saw>: triage issue N (/noodlebot:triage) in a worktree of origin/main.
start_triage() {
	local n=$1 saw=$2 d=$state/issue/$1 wt=$wtroot/issue-$1 released
	mkdir -p "$d"
	released=$(sh "$here/release-markers.sh" "$d") || { note "$saw; releasing #$n's markers failed"; return 1; }
	if [ -n "$released" ]; then set_starts "$d" 0; say "$saw; #$n: $(echo "$released" | paste -sd';')"; fi
	[ "$(starts_of "$d")" -lt 2 ] || { note "$saw; #$n is labelled but has used 2 starts; nothing started"; return 1; }
	[ -d "$wt" ] || git -C "$clone" worktree add -q --detach "$wt" origin/main || { note "$saw; worktree for #$n failed"; return 1; }
	sed -e "s|@N@|$n|g" -e "s|@REPO@|$repo|g" -e "s|@DIR@|$d|g" -e "s|@WT@|$wt|g" \
		"$here/unattended-triage.md" >"$d/unattended.md"
	launch "$wt" "$d" "/noodlebot:triage $n"
	say "$saw; started triage of #$n in $wt, pid $pid, start $(starts_of "$d") of 2"
}

# cleanup_merged: a merged node's worktree is not needed again. Keep its evidence (out/node/<ID>)
# under state/archive/<ID>-out and remove the worktree; files a container made belong to podman's
# subordinate ids, so plain rm may need podman unshare.
cleanup_merged() {
	local id wt
	for id in $merged; do
		wt=$wtroot/$id
		[ -d "$wt" ] && [ ! -e "$state/node/$id/session.pid" ] || continue
		mkdir -p "$state/archive"
		[ -d "$wt/out/node/$id" ] && [ ! -e "$state/archive/$id-out" ] && mv "$wt/out/node/$id" "$state/archive/$id-out"
		rm -rf "$wt" 2>/dev/null || podman unshare rm -rf "$wt" 2>/dev/null
		git -C "$clone" worktree prune
		if [ -d "$wt" ]; then note "$id merged, but removing its worktree failed"
		else say "$id merged: removed its worktree, evidence kept in state/archive/$id-out"; fi
	done
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

# start_node <ID> <name> <saw>: start a ready node's session (/node, or the plugin's skill).
start_node() {
	local id=$1 name=$2 saw=$3 d=$state/node/$1 wt=$wtroot/$1 released skill=/noodlebot:node
	mkdir -p "$d"
	# An answer or a merged spec PR is new information: the node gets 2 fresh starts.
	released=$(sh "$here/release-markers.sh" "$d") || { note "$saw; releasing $id's markers failed"; return 1; }
	if [ -n "$released" ]; then set_starts "$d" 0; say "$saw; $id: $(echo "$released" | paste -sd';')"; fi
	[ "$(starts_of "$d")" -lt 2 ] || { note "$saw; $id ready but has used 2 starts; not started"; return 1; }
	if [ ! -d "$wt" ]; then
		git -C "$clone" worktree add -q -b "node/$id-$name" "$wt" origin/main 2>/dev/null ||
			git -C "$clone" worktree add -q "$wt" "node/$id-$name" || { note "$saw; worktree for $id failed"; return 1; }
	fi
	sed -e "s|@ID@|$id|g" -e "s|@NAME@|$name|g" -e "s|@STATE@|$state|g" -e "s|@WT@|$wt|g" -e "s|@REPO@|$repo|g" \
		"$here/unattended.md" >"$d/unattended.md"
	# The repository's own /node skill while main still has one; the bot's plugin skill after.
	git -C "$clone" cat-file -e origin/main:.claude/skills/node/SKILL.md 2>/dev/null && skill=/node
	launch "$wt" "$d" "$skill $id"
	live+=("$pid $id")
	say "$saw; started $id ($name) in $wt, pid $pid, start $(starts_of "$d") of 2"
}

# live: "<pid> <key>" for every running session (a node ID, or an issue number for a triage).
open='' merged='' tick_tok='' live=() throttled=0
tick() {
	date +%s >"$state/heartbeat"
	git -C "$clone" fetch -q origin || { note "git fetch failed; nothing started"; return; }
	# Keep the clone's own checkout on origin/main: sessions in its worktrees also load skills and
	# agents from it, so a stale checkout would offer them stale ones.
	git -C "$clone" merge -q --ff-only origin/main 2>/dev/null || git -C "$clone" checkout -q --detach origin/main 2>/dev/null ||
		note "the clone's checkout could not follow origin/main"
	local tok
	tick_tok=''
	tok=$(~/.config/noodlebot/token "$repo") || { note "no GitHub App token; nothing started"; return; }
	tick_tok=$tok
	# pipefail: a failed gh must stop the tick, never read as "no PRs".
	if ! GH_TOKEN=$tok gh pr list --repo $repo --state merged --limit 500 --json number,headRefName \
			-q '.[] | "\(.number) \(.headRefName)"' >"$state/merged-prs.tsv" ||
		! open=$(GH_TOKEN=$tok gh pr list --repo $repo --state open --limit 500 --json headRefName -q '.[].headRefName' | ids); then
		note "gh pr list failed; nothing started"; return
	fi
	merged=$(cut -d' ' -f2 "$state/merged-prs.tsv" | ids)
	cut -d' ' -f1 "$state/merged-prs.tsv" >"$state/merged-prs.txt"
	local saw="open=[${open% }] merged-prs=[${merged% }]" f id name triaging='' p
	tok=''

	# Running sessions: recorded in pid files, so this works after a restart too.
	live=()
	for f in "$state"/node/*/session.pid "$state"/issue/*/session.pid; do
		[ -e "$f" ] || continue
		id=$(basename "$(dirname "$f")") p=$(cat "$f")
		if alive "$p" "$id"; then live+=("$p $id"); [[ $f == */issue/* ]] && triaging=$id
		else ended "$(dirname "$f")" "$saw"; fi
	done
	cleanup_merged
	local cap=${SCHED_MAX:-0} usage
	# The throttle: usage.py reads the plan's windows from every repository's sessions (one account,
	# one budget). While it says hold, no new session starts; running ones are never stopped.
	if [ "${SCHED_THROTTLE:-1}" = 1 ]; then
		usage=$(python3 -I "$here/usage.py" --state-root "$(dirname "$state")" 2>>"$state/report.log") || usage="open: usage unknown"
		if [[ $usage == hold:* ]]; then
			[ "$throttled" = 1 ] || say "$saw; throttle engaged, no new sessions: ${usage#hold: }"
			throttled=1
		elif [ "$throttled" = 1 ]; then
			say "$saw; throttle released: ${usage#open: }"; throttled=0
		fi
	fi
	full() { [ "$throttled" = 1 ] || { [ "$cap" -gt 0 ] && [ "${#live[@]}" -ge "$cap" ]; }; }

	# Issues the owner labelled `noodlebot`: one triage at a time, alongside the nodes.
	local n
	if [ -z "$triaging" ] && ! full && n=$(GH_TOKEN=$tick_tok python3 -I "$here/issues.py" next --repo "$repo" --state "$state" 2>>"$state/report.log"); then
		[ -z "$n" ] || { start_triage "$n" "$saw" && live+=("$pid $n"); }
	fi

	# Every ready node that has no session yet, in graph order (SCHED_MAX caps the sessions; 0: none).
	git -C "$clone" show origin/main:docs/graph.yaml >"$state/graph.yaml" || { note "no graph on origin/main"; return; }
	git -C "$clone" log --format=%s origin/main >"$state/subjects.txt"
	local args=() ready
	for id in $merged; do args+=(--merged "$id"); done
	for id in $open; do args+=(--open "$id"); done
	ready=$(python3 -I "$here/ready.py" --graph "$state/graph.yaml" --markers "$state/node" \
		--subjects "$state/subjects.txt" --merged-prs "$state/merged-prs.txt" --all "${args[@]}") ||
		{ note "$saw; ready.py failed; nothing started"; return; }
	while read -r id name; do
		[ -n "$id" ] || continue
		[ -e "$state/node/$id/session.pid" ] && continue   # its session is running
		full && break
		start_node "$id" "$name" "$saw"
	done <<<"$ready"

	local held=''; [ "$throttled" = 1 ] && held="; throttle holding new sessions"
	if [ "${#live[@]}" = 0 ]; then note "$saw; nothing ready$held"
	else
		local l=() e k
		for e in "${live[@]}"; do
			k=${e#* }; [ -d "$state/issue/$k" ] && [ ! -d "$state/node/$k" ] && k="#$k"
			l+=("$k (pid ${e%% *})")
		done
		note "$saw; running: $(IFS=,; echo "${l[*]}" | sed 's/,/, /g')$held"
	fi
}

# fingerprint: the markers and exit files under node/ and issue/; a change means "look again now".
fingerprint() {
	find "$state/node" "$state/issue" -maxdepth 2 -type f \( -name QUESTION.md -o -name ANSWER.md -o -name WAITING-PR \
		-o -name FAILED -o -name session.rc \) -printf '%p %T@\n' 2>/dev/null | sort | cksum
}

# pause: until the next GitHub poll is due, or sooner when a marker changes, any session exits or
# ~/STOP appears.
pause() {
	local fp end e
	fp=$(fingerprint) end=$(($(date +%s) + tick_s))
	while [ "$(date +%s)" -lt "$end" ]; do
		sleep "$poll_s"
		{ [ -e ~/STOP ] || [ -e ~/STOP-"${repo#*/}" ]; } && return
		for e in "${live[@]}"; do alive "${e%% *}" "${e#* }" || return; done
		[ "$(fingerprint)" != "$fp" ] && return
	done
}

while :; do
	[ -e ~/STOP ] || [ -e ~/STOP-"${repo#*/}" ] && { say "found ~/STOP; loop exits (sessions keep running: ${live[*]:-none})"; exit 0; }
	tick
	report; rc=$?; tick_tok=''; [ $rc = 3 ] && continue
	pause
done
