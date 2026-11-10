#!/bin/bash
# Node scheduler for one repository: starts a `claude -p "/noodlebot:node <ID>"` session for every
# ready node (ready.py --all), each in its own worktree, all at once (SCHED_MAX caps them; default
# 0, no cap), plus one triage at a time for issues the owner labels `noodlebot`, or one update session
# for a bot's spec/* PR that conflicts with main or whose graph gives an ID of main to another node
# (/noodlebot:triage --update <N>; the same one slot as a triage).
#   tmux new -d -s sched ~/gitrepos/noodlebot/scheduler/loop.sh [owner/name]   (default tuckermclean/themonolith)
# One loop per repository, each with its own lock, state and status issue.
#   touch ~/STOP          (every loop exits within seconds; running sessions keep going)
#   touch ~/STOP-<name>   (only that repository's loop exits)
# It acts as soon as something changes: it checks the node markers and the running session every
# SCHED_POLL seconds (default 2, local only) and asks GitHub about PRs every SCHED_TICK seconds
# (default 60); a running session whose node's PR is merged, or closed without merging after the session
# started (and no open PR), is stopped (its process group), and a closed PR holds the node with FAILED; after each tick it updates the GitHub status issue (report.py). Only one loop runs at a time ($NOODLEBOT_DATA/state/<name>/loop.lock). Sessions run under setsid and
# are recorded in node/<ID>/session.pid, so a restarted loop picks up a running session instead of
# starting a second one.
# Self-deploy: each tick runs deploy.sh on this checkout (a passing origin/main is fast-forwarded in,
# a failing one is one status line); when the checkout's HEAD moved, the loop execs the new loop.sh
# (same pid, same arguments) and takes over its running sessions like a restart. deploy.sh's stderr
# goes to state/<name>/deploy.log; its state and lock are $NOODLEBOT_DATA/deploy/ (the loop passes its runtime root).
# Layout under $NOODLEBOT_DATA (default ~/.local/share/noodlebot; never inside a Git working tree, else exit 2):
#   repos/<name>             a clone of the repository, used only by the scheduler (never the owner's checkout)
#   worktrees/<name>/<ID>    one worktree per node, on node/<ID>-<name>
#   worktrees/<name>/pr-<N>  one worktree per spec-PR update, on the PR's branch
#   state/<name>/            status.log, heartbeat, report.json/report.log (the GitHub status issue); node/<ID>/{session.jsonl,session.stderr,unattended.md,
#                            session.pid,session.rc,starts} and the markers ready.py reads:
#                            QUESTION.md, ANSWER.md (the owner's), WAITING-PR, FAILED;
#                            answered/ keeps released questions and spec PRs;
#                            issue/<N>/ (a triage) and pr/<N>/ (a spec-PR update: also from, done) hold the same files
# An older installation (repos/, worktrees/, state/ in the checkout) is moved once with
# scheduler/move-runtime.sh <checkout>, after stopping the loops (touch ~/STOP) and waiting for no session.
# At start, once, it makes sure the labels noodlebot, noodlebot-triaged and noodlebot-status exist (labels.py).
# Reads ~/.config/noodlebot/token (GitHub App token for gh) and ~/.config/noodlebot/oauth-token
# (CLAUDE_CODE_OAUTH_TOKEN, read by run-session.sh for the session only).
set -u -o pipefail
repo=${1:-tuckermclean/themonolith}
case $repo in */*) ;; *) echo "loop.sh: the argument is owner/name, not $repo" >&2; exit 2 ;; esac
nb=$(cd "$(dirname "$0")/.." && pwd -P) || exit 2
here=$nb/scheduler
root=${NOODLEBOT_DATA:-$HOME/.local/share/noodlebot}
case $root in /*) ;; *) root=$PWD/$root ;; esac
clone=$root/repos/${repo#*/}
wtroot=$root/worktrees/${repo#*/}
state=$root/state/${repo#*/}
oauth=$HOME/.config/noodlebot/oauth-token
log=$state/status.log
tick_s=${SCHED_TICK:-60} poll_s=${SCHED_POLL:-2} quiet_s=600
# The runtime root must not lie inside a Git working tree (sessions would load its CLAUDE.md and
# AGENTS.md). The root may not exist yet: ask from its nearest existing ancestor.
probe=$root
while [ ! -d "$probe" ] && [ "$probe" != / ] && [ "$probe" != . ]; do probe=$(dirname "$probe"); done
if top=$(git -C "$probe" rev-parse --show-toplevel 2>/dev/null); then
	echo "loop.sh: the runtime root $root is inside the Git working tree $top; set NOODLEBOT_DATA to a folder outside it" >&2
	exit 2
fi
mkdir -p "$root" || exit 2
mkdir -p "$state/node" "$state/issue" "$state/pr" "$wtroot"
start_head=$(git -C "$nb" rev-parse -q --verify HEAD 2>/dev/null || true)
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
# starts_of <dir> / set_starts <dir> <n>: a task's session starts (node/<ID>, issue/<N> or pr/<N>).
starts_of() { cat "$1/starts" 2>/dev/null || echo 0; }
set_starts() { echo "$2" >"$1/starts"; }
[ -r "$oauth" ] || { echo "loop.sh: $oauth is missing (claude setup-token)" >&2; exit 2; }
exec 9>"$state/loop.lock"
flock -n 9 || { echo "loop.sh: another loop is already running for $repo" >&2; exit 1; }
[ -d "$clone/.git" ] || git clone -q "https://github.com/$repo" "$clone" || { echo "loop.sh: cannot clone $repo" >&2; exit 2; }

# The label step, once per loop start (never on a tick): the labels the bot relies on exist in the
# repository. A failure is logged and the loop goes on.
ensure_labels() {
	local tok out
	tok=$(~/.config/noodlebot/token "$repo" 2>>"$state/report.log") || { say "label step: no GitHub App token; labels not checked"; return; }
	if out=$(GH_TOKEN=$tok python3 -I "$here/labels.py" ensure --repo "$repo" 2>>"$state/report.log"); then
		[ -z "$out" ] || say "label step: $(echo "$out" | sed 's/^created label //' | paste -sd' ' | sed 's/^/created labels: /')"
	else
		say "label step failed (see report.log); carrying on"
	fi
}
ensure_labels

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

# bg_cut_off <dir>: the CLI said on session.stderr that it stopped background tasks still running
# after the last turn (whatever the exit code). Such an end uses up no start.
bg_cut_off() {
	tail -c 100000 "$1/session.stderr" 2>/dev/null | tr '\n' ' ' |
		grep -qiE 'background tasks? still running.*after the last turn.*stopping them'
}

# not_counted <dir>: give back the start a limit exit used.
not_counted() { local n; n=$(starts_of "$1"); [ "$n" -gt 0 ] && set_starts "$1" $((n - 1)); }

# fu_branch <node dir>: the follow-up branch in its FOLLOWUP marker; fails if there is none (a missing,
# empty or blank marker is no marker).
fu_branch() { local b; b=$(tr -d '[:space:]' <"$1/FOLLOWUP" 2>/dev/null) && [ -n "$b" ] && echo "$b"; }

# has_pr <dir> <ID>: the node has an open or merged PR that ends a session as "with a PR". A follow-up
# (its FOLLOWUP marker holds the branch) counts only a PR on its own follow-up branch.
has_pr() {
	local br
	if br=$(fu_branch "$1"); then
		grep -qxF "$br" "$state/open-prs.txt" 2>/dev/null || awk -v b="$br" '$2 == b { f = 1 } END { exit !f }' "$state/merged-prs.tsv"
	else
		[[ " $open $merged " == *" $2 "* ]]
	fi
}

# record_stop <dir> <rc>: write <dir>/stopped, "<UTC time> <reason>", for a session that ended with no
# PR, QUESTION.md or WAITING-PR. rc is the session.rc value, or ? when there is none.
record_stop() {
	local why="rc $2"
	if [ "$2" != 0 ] && limit_exit "$1"; then why='usage limit'
	elif [ "$2" = '?' ]; then why='stopped (no exit code)'
	elif [[ $2 =~ ^[0-9]+$ ]] && [ "$2" -gt 128 ]; then why="stopped (signal $(($2 - 128)))"
	fi
	echo "$(date -u +%FT%TZ) $why" >"$1/stopped" 2>/dev/null || true
}

# ended <dir> <saw>: a recorded session is gone; report how it ended and clear its pid file.
ended() {
	local d=$1 saw=$2 id rc p
	id=$(basename "$d")
	p=$(cat "$d/session.pid"); wait "$p" 2>/dev/null
	rc=$(cat "$d/session.rc" 2>/dev/null || echo '?')
	rm -f "$d/session.pid"
	if [ "$(basename "$(dirname "$d")")" = issue ]; then triage_ended "$d" "$saw" "$rc"; return; fi
	if [ "$(basename "$(dirname "$d")")" = pr ]; then update_ended "$d" "$saw" "$rc"; return; fi
	if [ -e "$d/FAILED" ]; then record_stop "$d" "$rc"; say "$saw; session $id ended (rc $rc), held by FAILED"
	elif [ -e "$d/QUESTION.md" ]; then rm -f "$d/stopped"; say "$saw; session $id ended (rc $rc) with QUESTION.md"
	elif [ -e "$d/WAITING-PR" ]; then rm -f "$d/stopped"; say "$saw; session $id ended (rc $rc) waiting for spec PR #$(cat "$d/WAITING-PR")"
	elif has_pr "$d" "$id"; then rm -f "$d/stopped"; say "$saw; session $id ended (rc $rc) with a PR"
	elif bg_cut_off "$d"; then
		record_stop "$d" "$rc"
		not_counted "$d"
		say "$saw; session $id ended (rc $rc) with its background work cut off; start not counted"
	elif [ "$rc" != 0 ] && limit_exit "$d"; then
		record_stop "$d" "$rc"
		not_counted "$d"
		say "$saw; session $id stopped by the usage limit (rc $rc); start not counted, it resumes when the throttle opens"
	elif record_stop "$d" "$rc"; [ "$(starts_of "$d")" -ge 2 ]; then
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
	elif bg_cut_off "$d"; then
		not_counted "$d"
		say "$saw; triage of #$n ended (rc $rc) with its background work cut off; start not counted"
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

# update_ended <dir> <saw> <rc>: a spec-PR update session is gone. rc 0: its worktree goes and the
# main and PR-head commits it started from are kept (done); the PR is not started again until one moves.
update_ended() {
	local d=$1 saw=$2 rc=$3 n
	n=$(basename "$d")
	if bg_cut_off "$d"; then
		not_counted "$d"
		say "$saw; update of PR #$n ended (rc $rc) with its background work cut off; start not counted"
	elif [ "$rc" = 0 ]; then
		set_starts "$d" 0
		git -C "$clone" worktree remove --force "$wtroot/pr-$n" 2>/dev/null
		[ -e "$d/from" ] && mv "$d/from" "$d/done"
		say "$saw; update of PR #$n ended (rc 0); not started again until main or the PR's head moves"
	elif limit_exit "$d"; then
		not_counted "$d"
		say "$saw; update of PR #$n stopped by the usage limit (rc $rc); start not counted"
	elif [ "$(starts_of "$d")" -ge 2 ]; then
		echo "$(date -u +%FT%TZ) second exit (rc $rc) without finishing the update" >"$d/FAILED"
		set_starts "$d" 0
		say "$saw; update of PR #$n ended (rc $rc), 2 starts used: wrote FAILED"
	else say "$saw; update of PR #$n ended (rc $rc); may start again"
	fi
}

# stop_group <pid>: end a session's process group (setsid made its pid the pgid): SIGTERM, SIGKILL
# after a grace of 3 s, and return once the group is gone, with the leader reaped.
stop_group() {
	local p=$1 i st
	kill -TERM -- "-$p" 2>/dev/null
	for i in $(seq 1 40); do
		[ "$i" = 15 ] && kill -KILL -- "-$p" 2>/dev/null
		st=$(sed 's/.*) //' "/proc/$p/stat" 2>/dev/null | cut -c1)
		[ "$st" = Z ] && wait "$p" 2>/dev/null
		kill -0 -- "-$p" 2>/dev/null || return 0
		sleep 0.2
	done
	return 1
}

# pr_done <ID> <start>: a node's session started at <start> (epoch s) has no more use: sets why to the
# reason ("merged"/"closed") and prn to the PR. Merged; or no open PR and a PR on node/<ID>-* closed
# without merging at or after <start>. For a follow-up (FOLLOWUP marker) only a PR on its follow-up
# branch counts: the node's earlier merged PR is no reason to stop it.
pr_done() {
	local id=$1 start=$2 n br t m fb=''
	if fb=$(fu_branch "$state/node/$id"); then
		prn=$(awk -v b="$fb" '$2 == b { print $1 }' "$state/merged-prs.tsv" | sort -n | tail -n1)
		[ -n "$prn" ] && { why=merged; return 0; }
	elif [[ " $merged " == *" $id "* ]]; then
		prn=$(awk -v b="node/$id-" 'index($2, b) == 1 { print $1 }' "$state/merged-prs.tsv" | sort -n | tail -n1)
		why=merged; return 0
	fi
	[[ " $open " == *" $id "* ]] && return 1
	while read -r n br t m; do
		[ "$m" = false ] || continue
		if [ -n "$fb" ]; then [ "$br" = "$fb" ] || continue; else [[ $br == node/$id-* ]] || continue; fi
		t=$(date -d "$t" +%s 2>/dev/null) || continue
		[ "$t" -ge "$start" ] && { prn=$n why=closed; return 0; }
	done <"$state/closed-prs.tsv"
	return 1
}

# stop_done <dir> <pid> <saw>: stop a session whose PR is done, wait until its group is gone, say so once, and reap it. A closed PR
# holds the node (FAILED naming the PR, starts 0: deleting FAILED gives it 2 fresh starts).
stop_done() {
	local d=$1 p=$2 saw=$3 id prn why
	id=$(basename "$d")
	pr_done "$id" "$(stat -c %Y "$d/session.pid" 2>/dev/null || echo 0)" || return 1
	if [ "$why" = closed ]; then
		echo "$(date -u +%FT%TZ) PR #$prn was closed without merging; delete this file to start the node again" >"$d/FAILED"
		set_starts "$d" 0
	fi
	# a group that survived SIGKILL is not reaped and no event is written: it stays live, retried next tick
	stop_group "$p" || { note "$saw; session $id (pid $p) survived SIGKILL"; return 1; }
	say "$saw; stopped session $id: its PR #$prn is $why"
	ended "$d" "$saw"
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
		-e "s|@LOOP@|$here/loop.sh|g" "$here/unattended-triage.md" >"$d/unattended.md"
	launch "$wt" "$d" "/noodlebot:triage $n"
	say "$saw; started triage of #$n in $wt, pid $pid, start $(starts_of "$d") of 2"
}

# start_update <N> <branch> <main> <head> <saw>: update spec PR N (/noodlebot:triage --update N) in a
# worktree on its branch (by name: nodes.py recognises a spec branch by name). <main> and <head> are the
# commits it starts from.
start_update() {
	local n=$1 br=$2 mainc=$3 head=$4 saw=$5 d=$state/pr/$1 wt=$wtroot/pr-$1 released
	mkdir -p "$d"
	released=$(sh "$here/release-markers.sh" "$d") || { note "$saw; releasing PR #$n's markers failed"; return 1; }
	if [ -n "$released" ]; then set_starts "$d" 0; say "$saw; PR #$n: $(echo "$released" | paste -sd';')"; fi
	[ "$(starts_of "$d")" -lt 2 ] || { note "$saw; PR #$n needs an update but has used 2 starts; nothing started"; return 1; }
	if [ -d "$wt" ]; then
		# left by an earlier end without rc 0: bring it to the PR's current head, not mid-merge
		{ git -C "$wt" merge --abort; git -C "$wt" checkout -q -f -B "$br" "origin/$br" &&
			git -C "$wt" reset -q --hard "origin/$br" && git -C "$wt" clean -qfd; } 2>/dev/null ||
			{ note "$saw; resetting the worktree of PR #$n failed"; return 1; }
	else
		git -C "$clone" worktree add -q -B "$br" "$wt" "origin/$br" || { note "$saw; worktree for PR #$n failed"; return 1; }
	fi
	sed -e "s|@N@|$n|g" -e "s|@REPO@|$repo|g" -e "s|@DIR@|$d|g" -e "s|@WT@|$wt|g" \
		-e "s|@LOOP@|$here/loop.sh|g" "$here/unattended-update.md" >"$d/unattended.md"
	echo "$mainc $head" >"$d/from"
	launch "$wt" "$d" "/noodlebot:triage --update $n"
	say "$saw; started update of PR #$n in $wt, pid $pid, start $(starts_of "$d") of 2"
}

# graph_clash <branch>: origin/<branch>'s graph gives an ID of origin/main's graph to a node of another name.
graph_clash() {
	git -C "$clone" show "origin/main:docs/graph.yaml" >"$state/graph.main.yaml" 2>/dev/null &&
		git -C "$clone" show "origin/$1:docs/graph.yaml" >"$state/graph.pr.yaml" 2>/dev/null &&
		python3 -I -c '
import sys, yaml
def pairs(f):
    return {n["id"]: n["name"] for n in (yaml.safe_load(open(f)) or {}).get("nodes", [])}
try:
    m, b = pairs(sys.argv[1]), pairs(sys.argv[2])
except Exception:
    sys.exit(1)
sys.exit(0 if any(i in m and m[i] != nm for i, nm in b.items()) else 1)' "$state/graph.main.yaml" "$state/graph.pr.yaml"
}

# next_update: every bot spec/* PR (one line each) that needs an update (CONFLICTING, or a clash of IDs with
# main; UNKNOWN waits), has no FAILED and is not held by a finished update of the same main and head.
next_update() {
	local n br oid bot mg mainc
	mainc=$(git -C "$clone" rev-parse -q --verify origin/main) || return 1
	while read -r n br oid bot mg; do
		[[ $br == spec/* ]] && [ "$bot" = true ] || continue
		[ -e "$state/pr/$n/FAILED" ] && continue
		[ "$(cat "$state/pr/$n/done" 2>/dev/null)" = "$mainc $oid" ] && continue
		if [ "$mg" = CONFLICTING ] || { [ "$mg" = MERGEABLE ] && graph_clash "$br"; }; then
			echo "$n $br $mainc $oid"
		fi
	done <"$state/open-prs.tsv"
}

# followup_done <saw>: a follow-up whose PR (on its follow-up branch) is merged is done: its FOLLOWUP
# marker moves into answered/ (a running session was stopped by stop_done before).
followup_done() {
	local f d id br prn ts
	for f in "$state"/node/*/FOLLOWUP; do
		d=$(dirname "$f") id=$(basename "$d")
		br=$(fu_branch "$d") || continue
		prn=$(awk -v b="$br" '$2 == b { print $1 }' "$state/merged-prs.tsv" | sort -n | tail -n1)
		[ -n "$prn" ] || continue
		ts=$(date -u +%Y%m%dT%H%M%SZ)
		mkdir -p "$d/answered"
		mv "$f" "$d/answered/$ts-FOLLOWUP" && say "$1; $id: its follow-up PR #$prn is merged, the follow-up is done"
	done
}

# cleanup_merged: a merged node's worktree is not needed again. Keep its evidence (out/node/<ID>)
# under $NOODLEBOT_DATA/state/archive/<ID>-out (a follow-up's, when that exists, under <ID>-out-<UTC time>) and remove the worktree;
# files a container made belong to podman's subordinate ids, so plain rm may need podman unshare.
# A follow-up in progress (FOLLOWUP marker) keeps its worktree.
cleanup_merged() {
	local id wt arch
	for id in $merged; do
		wt=$wtroot/$id
		[ -d "$wt" ] && [ ! -e "$state/node/$id/session.pid" ] && ! fu_branch "$state/node/$id" >/dev/null || continue
		mkdir -p "$state/archive"
		arch=$id-out
		[ -e "$state/archive/$arch" ] && arch=$id-out-$(date -u +%Y%m%dT%H%M%SZ)
		[ -d "$wt/out/node/$id" ] && [ ! -e "$state/archive/$arch" ] && mv "$wt/out/node/$id" "$state/archive/$arch"
		rm -rf "$wt" 2>/dev/null || podman unshare rm -rf "$wt" 2>/dev/null
		git -C "$clone" worktree prune
		if [ -d "$wt" ]; then note "$id merged, but removing its worktree failed"
		else say "$id merged: removed its worktree, evidence kept in state/archive/$arch"; fi
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

# followup_branch <ID>: the branch for a new follow-up of a merged node: node/<ID>-followup-<n>, n one
# more than the highest among the clone's branches, origin's and the merged and closed PRs.
followup_branch() {
	local n
	n=$({ git -C "$clone" branch -a --format='%(refname:short)'; cut -d' ' -f2 "$state/merged-prs.tsv" "$state/closed-prs.tsv"; } 2>/dev/null |
		sed -n "s#^\(origin/\)\{0,1\}node/$1-followup-\([0-9][0-9]*\)\$#\2#p" | sort -n | tail -n1)
	echo "node/$1-followup-$((${n:-0} + 1))"
}

# save_leftover <ID> <wt> <dir> <saw>: uncommitted changes in an existing worktree (modified, staged,
# deleted, untracked and not ignored) are written to <dir>/leftover/<UTC timestamp>.patch, then the
# worktree is reset to HEAD and the untracked files saved are removed. Sets leftover_patch to the patch
# file name (empty when the worktree is clean). Fails, resetting nothing, if the patch cannot be written.
leftover_patch=''
save_leftover() {
	local id=$1 wt=$2 d=$3 saw=$4 ts patch tmpd ex=()
	# the node's evidence stays even where out/ is not ignored (an excluded path that is ignored makes git add fail)
	git -C "$wt" check-ignore -q "out/node/$id/x" || ex=(":(exclude)out/node/$id")
	leftover_patch=''
	[ -n "$(git -C "$wt" status --porcelain -- . "${ex[@]}" 2>/dev/null)" ] || return 0
	ts=$(date -u +%Y%m%dT%H%M%SZ) patch=$d/leftover/$ts.patch
	if mkdir -p "$d/leftover" && tmpd=$(mktemp -d "$d/leftover/.tmp.XXXXXX") &&
		GIT_INDEX_FILE=$tmpd/index git -C "$wt" read-tree HEAD &&
		GIT_INDEX_FILE=$tmpd/index git -C "$wt" add -A -- . "${ex[@]}" &&
		GIT_INDEX_FILE=$tmpd/index git -C "$wt" diff --binary --cached HEAD >"$tmpd/patch" &&
		[ -s "$tmpd/patch" ] && [ ! -e "$patch" ] && mv "$tmpd/patch" "$patch"; then
		rm -rf "$tmpd"
	else
		[ -n "${tmpd:-}" ] && rm -rf "$tmpd"
		note "$saw; $id: cannot write the leftover patch for its uncommitted changes; not started"; return 1
	fi
	git -C "$wt" restore -q --source=HEAD --staged --worktree -- . "${ex[@]}" && git -C "$wt" clean -fdq -- . "${ex[@]}" || { note "$saw; $id: resetting the worktree after the leftover patch failed; not started"; return 1; }
	leftover_patch=$ts.patch
	say "$saw; $id: uncommitted changes of an earlier session saved as leftover/$leftover_patch and the worktree reset"
}

# start_node <ID> <name> <saw> [followup]: start a ready node's session (/node, or the plugin's skill).
# A merged node's answer ("followup") starts on a branch of its own, node/<ID>-followup-<n>, which the
# FOLLOWUP marker keeps until its PR is merged.
start_node() {
	local id=$1 name=$2 saw=$3 kind=${4:-} d=$state/node/$1 wt=$wtroot/$1 released skill=/noodlebot:node br=node/$1-$2 prompt=unattended.md
	mkdir -p "$d"
	# A follow-up with no marker yet and a worktree here: the merged node's leftover. Hold it before the
	# answer is released (markers untouched), so cleanup_merged retries and a later tick starts it.
	if [ "$kind" = followup ] && ! fu_branch "$d" >/dev/null && [ -d "$wt" ]; then
		note "$saw; $id: a worktree not on its follow-up branch is in the way; not started"; return 1
	fi
	# An answer or a merged spec PR is new information: the node gets 2 fresh starts.
	released=$(sh "$here/release-markers.sh" "$d") || { note "$saw; releasing $id's markers failed"; return 1; }
	if [ -n "$released" ]; then set_starts "$d" 0; say "$saw; $id: $(echo "$released" | paste -sd';')"; fi
	[ "$(starts_of "$d")" -lt 2 ] || { note "$saw; $id ready but has used 2 starts; not started"; return 1; }
	if [ "$kind" = followup ]; then
		prompt=unattended-followup.md
		if br=$(fu_branch "$d"); then
			if [ -d "$wt" ] && [ "$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" != "$br" ]; then
				note "$saw; $id: a worktree not on its follow-up branch is in the way; not started"; return 1
			fi
		else
			br=$(followup_branch "$id"); echo "$br" >"$d/FOLLOWUP"
		fi
	fi
	if [ ! -d "$wt" ]; then
		git -C "$clone" worktree add -q -b "$br" "$wt" origin/main 2>/dev/null ||
			git -C "$clone" worktree add -q "$wt" "$br" || { note "$saw; worktree for $id failed"; return 1; }
	fi
	local ncommits reason='' resume=0 rsed=()
	[ -r "$here/$prompt" ] || { note "$saw; $id: no $prompt; not started"; return 1; }
	save_leftover "$id" "$wt" "$d" "$saw" || return 1
	ncommits=$(git -C "$wt" rev-list --count origin/main..HEAD 2>/dev/null || echo 0)
	if [ "${ncommits:-0}" -gt 0 ] || [ -d "$wt/out/node/$id" ]; then
		resume=1
		reason=$(cut -d' ' -f2- "$d/stopped" 2>/dev/null | head -n1)
		rsed=(-e "s|@REASON@|${reason:-not recorded}|g" -e "s|@COMMITS@|${ncommits:-0}|g" -e "s|@PATCH@|$state/node/$id/leftover/$leftover_patch|g")
	fi
	# the resume section sits between @RESUME-BEGIN@/@RESUME-END@, the patch lines between @PATCH-BEGIN@/@PATCH-END@
	{ if [ "$resume" = 1 ]; then cat; else sed '/^@RESUME-BEGIN@$/,/^@RESUME-END@$/d'; fi; } <"$here/$prompt" 2>/dev/null |
	{ if [ -n "$leftover_patch" ]; then cat; else sed '/^@PATCH-BEGIN@$/,/^@PATCH-END@$/d'; fi; } |
	sed -e '/^@\(RESUME\|PATCH\)-\(BEGIN\|END\)@$/d' "${rsed[@]}" \
		-e "s|@ID@|$id|g" -e "s|@NAME@|$name|g" -e "s|@STATE@|$state|g" -e "s|@WT@|$wt|g" -e "s|@REPO@|$repo|g" \
		-e "s|@BR@|$br|g" -e "s|@LOOP@|$here/loop.sh|g" >"$d/unattended.md" || { note "$saw; $id: rendering $prompt failed; not started"; return 1; }
	# The repository's own /node skill while main still has one; the bot's plugin skill after.
	git -C "$clone" cat-file -e origin/main:.claude/skills/node/SKILL.md 2>/dev/null && skill=/node
	launch "$wt" "$d" "$skill $id"
	live+=("$pid $id")
	say "$saw; started $id ($name)${kind:+ as a follow-up on $br} in $wt, pid $pid, start $(starts_of "$d") of 2"
}

# deploy: self-deploy this checkout (deploy.sh); its stdout lines are status events, its stderr goes
# to deploy.log. Never fails the tick; 9>&- keeps the loop's lock from deploy.sh and make test.
deploy() {
	[ -x "$here/deploy.sh" ] && [ -n "$start_head" ] || return 0
	local line
	NOODLEBOT_DATA="$root" "$here/deploy.sh" "$nb" </dev/null 9>&- 2>"$state/deploy.err" | while IFS= read -r line; do say "$line" >/dev/null; done
	if [ -s "$state/deploy.err" ]; then sed "s/^/$(date -u +%FT%TZ) /" "$state/deploy.err" >>"$state/deploy.log"; fi
	return 0
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
		! GH_TOKEN=$tok gh pr list --repo $repo --state open --limit 500 --json number,headRefName,headRefOid,author,mergeable \
			-q '.[] | "\(.number) \(.headRefName) \(.headRefOid) \(.author.is_bot) \(.mergeable)"' >"$state/open-prs.tsv" ||
		! cut -d' ' -f2 "$state/open-prs.tsv" >"$state/open-prs.txt" ||
		! open=$(ids <"$state/open-prs.txt") ||
		! GH_TOKEN=$tok gh pr list --repo $repo --state closed --limit 500 --json number,headRefName,closedAt,mergedAt \
			-q '.[] | "\(.number) \(.headRefName) \(.closedAt) \(.mergedAt != null)"' >"$state/closed-prs.tsv"; then
		note "gh pr list failed; nothing started"; return
	fi
	merged=$(cut -d' ' -f2 "$state/merged-prs.tsv" | ids)
	cut -d' ' -f1 "$state/merged-prs.tsv" >"$state/merged-prs.txt"
	local saw="open=[${open% }] merged-prs=[${merged% }]" f id name triaging='' p
	tok=''

	# Running sessions: recorded in pid files, so this works after a restart too.
	live=()
	for f in "$state"/node/*/session.pid "$state"/issue/*/session.pid "$state"/pr/*/session.pid; do
		[ -e "$f" ] || continue
		id=$(basename "$(dirname "$f")") p=$(cat "$f")
		if alive "$p" "$id"; then
			[[ $f == */node/* ]] && stop_done "$(dirname "$f")" "$p" "$saw" && continue
			live+=("$p $id"); [[ $f == */issue/* || $f == */pr/* ]] && triaging=$id
		else ended "$(dirname "$f")" "$saw"; fi
	done
	followup_done "$saw"
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
		[ -z "$n" ] || { start_triage "$n" "$saw" && live+=("$pid $n") && triaging=$n; }
	fi
	# A bot's spec PR that needs an update: one session at a time, sharing the triage's slot.
	if [ -z "$triaging" ] && ! full; then
		local un ub um uh
		while read -r un ub um uh; do
			[ -n "$un" ] || continue
			# a failed start does not keep the later PRs from their turn
			start_update "$un" "$ub" "$um" "$uh" "$saw" && { live+=("$pid $un"); triaging=$un; break; }
		done < <(next_update)
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
	while read -r id name kind; do
		[ -n "$id" ] || continue
		[ -e "$state/node/$id/session.pid" ] && continue   # its session is running
		full && break
		start_node "$id" "$name" "$saw" "$kind"
	done <<<"$ready"

	local held=''; [ "$throttled" = 1 ] && held="; throttle holding new sessions"
	if [ "${#live[@]}" = 0 ]; then note "$saw; nothing ready$held"
	else
		local l=() e k
		for e in "${live[@]}"; do
			k=${e#* }
			if [ -d "$state/pr/$k" ] && [ ! -d "$state/node/$k" ]; then k="PR #$k"
			elif [ -d "$state/issue/$k" ] && [ ! -d "$state/node/$k" ]; then k="#$k"; fi
			l+=("$k (pid ${e%% *})")
		done
		note "$saw; running: $(IFS=,; echo "${l[*]}" | sed 's/,/, /g')$held"
	fi
}

# fingerprint: the markers and exit files under node/, issue/ and pr/; a change means "look again now".
fingerprint() {
	find "$state/node" "$state/issue" "$state/pr" -maxdepth 2 -type f \( -name QUESTION.md -o -name ANSWER.md -o -name WAITING-PR \
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
	deploy   # after the tick body, so one tick never mixes the old loop with new helpers
	if [ -n "$start_head" ] && [ "$(git -C "$nb" rev-parse -q --verify HEAD 2>/dev/null)" != "$start_head" ]; then
		exec bash "$here/loop.sh" "$repo" 9>&-   # 9>&-: the new process takes the lock itself
	fi
	pause
done
