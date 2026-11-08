#!/bin/bash
# All repositories' loops at once, from the list in ~/.config/noodlebot/repos
# (one owner/name per line; blank lines and # comments are ignored).
#   scheduler/loops.sh start    start a loop in tmux session sched-<name> for each repository not running
#   scheduler/loops.sh stop     touch ~/STOP-<name> for each running loop, wait for it to exit, remove the file
#   scheduler/loops.sh status   one line per repository: loop, running sessions, what waits on the owner
# LOOPS_STOP_WAIT (default 300) is how many seconds stop waits for each loop; a loop checks STOP only
# between ticks. Sessions are never touched. The underlying mechanism is scheduler/loop.sh.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -u
nb=$(cd "$(dirname "$0")/.." && pwd -P) || exit 2
list=$HOME/.config/noodlebot/repos
wait_s=${LOOPS_STOP_WAIT:-300}

usage() { echo "usage: loops.sh start|stop|status" >&2; exit 2; }
[ $# -eq 1 ] || usage
cmd=$1
case $cmd in start | stop | status) ;; *) usage ;; esac

repos=()
if [ -r "$list" ]; then
	while read -r line; do
		line=${line%%#*}
		line=$(echo "$line" | tr -d '[:space:]')
		[ -n "$line" ] && repos+=("$line")
	done <"$list"
fi
if [ ${#repos[@]} -eq 0 ]; then
	echo "no repositories listed in $list"
	exit 0
fi

# running <name>: the loop's lock is held.
running() { [ -e "$nb/state/$1/loop.lock" ] && ! flock -n "$nb/state/$1/loop.lock" true 2>/dev/null; }

rc=0
case $cmd in
start)
	for repo in "${repos[@]}"; do
		name=${repo#*/}
		if running "$name"; then
			echo "$repo: loop already running"
		elif tmux new -d -s "sched-$name" "$nb/scheduler/loop.sh" "$repo"; then
			echo "$repo: started in tmux session sched-$name"
		else
			echo "$repo: could not start tmux session sched-$name" >&2
			rc=1
		fi
	done ;;
stop)
	waiting=()
	for repo in "${repos[@]}"; do
		name=${repo#*/}
		if running "$name"; then
			touch "$HOME/STOP-$name"
			echo "$repo: stopping (waiting for the loop to exit)"
			waiting+=("$name")
		else
			echo "$repo: loop not running"
		fi
	done
	deadline=$((SECONDS + wait_s))
	for name in "${waiting[@]}"; do
		while running "$name" && [ $SECONDS -lt $deadline ]; do sleep 0.2; done
		if running "$name"; then
			echo "$name: loop still running after ${wait_s}s; left $HOME/STOP-$name in place" >&2
			rc=1
		else
			rm -f "$HOME/STOP-$name"
			echo "$name: loop stopped"
		fi
	done ;;
status)
	for repo in "${repos[@]}"; do
		name=${repo#*/}
		state=$nb/state/$name
		if running "$name"; then loop="loop running"; else loop="loop not running"; fi
		live=() wait=()
		for f in "$state"/node/*/session.pid "$state"/issue/*/session.pid; do
			[ -e "$f" ] || continue
			p=$(cat "$f") id=$(basename "$(dirname "$f")")
			tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null | grep -qE "run-session\.sh .* $id( |\$)|claude -p /node $id( |\$)" || continue
			case $f in */issue/*) id="#$id" ;; esac
			live+=("$id")
		done
		for d in "$state"/node/*/ "$state"/issue/*/; do
			[ -d "$d" ] || continue
			id=$(basename "$d") d=${d%/}
			case $d in */issue/*) id="#$id" ;; esac
			if [ -e "$d/FAILED" ]; then wait+=("$id FAILED")
			elif [ -e "$d/QUESTION.md" ] && [ -e "$d/ANSWER.md" ]; then wait+=("$id answered")
			elif [ -e "$d/QUESTION.md" ]; then wait+=("$id QUESTION")
			elif [ -e "$d/WAITING-PR" ]; then wait+=("$id WAITING-PR")
			fi
		done
		s=none w=nothing
		[ ${#live[@]} -gt 0 ] && s=$(IFS=,; echo "${live[*]}")
		[ ${#wait[@]} -gt 0 ] && w=$(IFS=,; echo "${wait[*]}" | sed 's/,/, /g')
		echo "$repo: $loop; sessions: $s; waiting on you: $w"
	done ;;
esac
exit $rc
