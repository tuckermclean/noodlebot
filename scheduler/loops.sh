#!/bin/bash
# All repositories' loops at once, from the list in ~/.config/noodlebot/repos
# (one owner/name per line; blank lines and # comments are ignored, a line that is not owner/name is
# reported on stderr and skipped, a repeated line counts once).
#   scheduler/loops.sh start    start a loop in tmux session sched-<name> for each repository not running
#   scheduler/loops.sh stop     touch ~/STOP-<name> for each running loop, wait for it to exit, remove the file
#   scheduler/loops.sh status   one line per repository: loop, running sessions, what waits on the owner
# LOOPS_STOP_WAIT (default 300) is one deadline, in seconds, for all loops together to exit after stop;
# a loop checks STOP only between ticks. LOOPS_START_WAIT (default 10) is the same for start, for each
# started loop to take its lock. Sessions are never touched. The underlying mechanism is
# scheduler/loop.sh. Locks, sessions and markers are read under the runtime root,
# $NOODLEBOT_DATA/state/<name> (default ~/.local/share/noodlebot, as in loop.sh); start passes that
# root to each loop as NOODLEBOT_DATA, since a tmux server keeps its own environment and the loop
# would otherwise use another root and another lock.
# A loop runs when its loop.lock is held. That is read from /proc/locks, never by taking the lock:
# a probe holding it even for an instant makes a starting loop's own `flock -n` fail.
# start refuses (exit 1, nothing started) while ~/STOP exists, and while a loop from before the D02
# move still holds <checkout>/state/<name>/loop.lock: run scheduler/move-runtime.sh first.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -u
nb=$(cd "$(dirname "$0")/.." && pwd -P) || exit 2
list=$HOME/.config/noodlebot/repos
root=${NOODLEBOT_DATA:-$HOME/.local/share/noodlebot}
case $root in /*) ;; *) root=$PWD/$root ;; esac
wait_s=${LOOPS_STOP_WAIT:-300}
start_wait=${LOOPS_START_WAIT:-10}

usage() { echo "usage: loops.sh start|stop|status" >&2; exit 2; }
[ $# -eq 1 ] || usage
cmd=$1
case $cmd in start | stop | status) ;; *) usage ;; esac

repos=()
if [ -r "$list" ]; then
	while IFS= read -r line || [ -n "$line" ]; do
		line=${line%%#*}
		line=$(echo "$line" | tr -d '[:space:]')
		[ -n "$line" ] || continue
		case $line in
		*/*/* | /* | */) bad=1 ;;
		*/*) bad=0 ;;
		*) bad=1 ;;
		esac
		if [ $bad = 1 ]; then
			echo "loops.sh: ignoring '$line' in $list: not owner/name" >&2
			continue
		fi
		case " ${repos[*]-} " in *" $line "*) continue ;; esac
		repos+=("$line")
	done <"$list"
fi
if [ ${#repos[@]} -eq 0 ]; then
	echo "no repositories listed in $list"
	exit 0
fi

# held <lockfile>: some process holds a lock on the file, as /proc/locks shows it (a line
# "N: FLOCK ADVISORY WRITE <pid> <major>:<minor>:<inode> ...", major and minor in hex; lines with
# "->" are blocked waiters). Inode and device must match; where stat's device is not the one the
# kernel shows there (btrfs subvolumes, overlayfs), the device of the file's mount is tried. The pid
# is of no use: it is the short-lived `flock` command's, not the loop's.
held() {
	local f=$1 st ino dev mdev='' n type adv rw pid id rest lino ldev
	[ -e "$f" ] || return 1
	st=$(stat -L -c '%i %d' "$f" 2>/dev/null) || return 1
	ino=${st% *} dev=${st#* }
	dev=$(( ((dev >> 8) & 0xfff) | ((dev >> 32) & ~0xfff) )):$(( (dev & 0xff) | ((dev >> 12) & ~0xff) ))
	while read -r n type adv rw pid id rest; do
		[ "$type" = "->" ] && continue
		lino=${id##*:} ldev=${id%:*}
		[ "$lino" = "$ino" ] || continue
		ldev=$((16#${ldev%%:*})):$((16#${ldev#*:}))
		[ "$ldev" = "$dev" ] && return 0
		[ -n "$mdev" ] || { mdev=$(findmnt -n -o MAJ:MIN -T "$f" 2>/dev/null | tr -d ' '); mdev=${mdev:-none}; }
		[ "$ldev" = "$mdev" ] && return 0
	done </proc/locks
	return 1
}
# running <name>: the loop's lock is held.
running() { held "$root/state/$1/loop.lock"; }
# resolved <dir>: the directory with symbolic links resolved, or as given when it does not exist.
resolved() { (cd "$1" 2>/dev/null && pwd -P) || echo "$1"; }

rc=0
case $cmd in
start)
	if [ -e "$HOME/STOP" ]; then
		echo "$HOME/STOP exists: every loop would exit at once; remove it first. Nothing started." >&2
		exit 1
	fi
	if [ "$(resolved "$nb/state")" != "$(resolved "$root/state")" ]; then
		old=0
		for repo in "${repos[@]}"; do
			name=${repo#*/}
			if held "$nb/state/$name/loop.lock"; then
				echo "$repo: a loop from before the runtime move holds $nb/state/$name/loop.lock; stop it (touch ~/STOP), run $nb/scheduler/move-runtime.sh $nb, then start again." >&2
				old=1
			fi
		done
		[ $old = 0 ] || { echo "Nothing started." >&2; exit 1; }
	fi
	launched=()
	for repo in "${repos[@]}"; do
		name=${repo#*/}
		if running "$name"; then
			echo "$repo: loop already running"
			[ -e "$HOME/STOP-$name" ] && echo "$repo: note: $HOME/STOP-$name exists; the running loop will stop"
		else
			if [ -e "$HOME/STOP-$name" ]; then
				rm -f "$HOME/STOP-$name"
				echo "$repo: removed stale $HOME/STOP-$name"
			fi
			if tmux new -d -s "sched-$name" env NOODLEBOT_DATA="$root" "$nb/scheduler/loop.sh" "$repo"; then
				echo "$repo: started in tmux session sched-$name"
				launched+=("$repo")
			else
				echo "$repo: could not start tmux session sched-$name" >&2
				rc=1
			fi
		fi
	done
	deadline=$((SECONDS + start_wait))
	for repo in ${launched[@]+"${launched[@]}"}; do
		name=${repo#*/}
		while ! running "$name" && [ $SECONDS -lt $deadline ]; do sleep 0.2; done
		if ! running "$name"; then
			echo "$repo: loop did not take its lock within ${start_wait}s; run $nb/scheduler/loop.sh $repo directly or see $root/state/$name/status.log" >&2
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
			waiting+=("$repo")
		else
			echo "$repo: loop not running"
		fi
	done
	deadline=$((SECONDS + wait_s))
	for repo in ${waiting[@]+"${waiting[@]}"}; do
		name=${repo#*/}
		while running "$name" && [ $SECONDS -lt $deadline ]; do sleep 0.2; done
		if running "$name"; then
			echo "$repo: loop still running after ${wait_s}s; left $HOME/STOP-$name in place" >&2
			rc=1
		else
			rm -f "$HOME/STOP-$name"
			echo "$repo: loop stopped"
		fi
	done ;;
status)
	for repo in "${repos[@]}"; do
		name=${repo#*/}
		state=$root/state/$name
		if running "$name"; then loop="loop running"; else loop="loop not running"; fi
		live=() wait=()
		for f in "$state"/node/*/session.pid "$state"/issue/*/session.pid; do
			[ -e "$f" ] || continue
			p=$(cat "$f" 2>/dev/null) id=$(basename "$(dirname "$f")")
			case $p in '' | *[!0-9]*) continue ;; esac
			{ tr '\0' ' ' <"/proc/$p/cmdline"; } 2>/dev/null | grep -qE "run-session\.sh .* $id( |\$)|claude -p /node $id( |\$)" || continue
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
