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
# would otherwise use another root and another lock. Likewise every USAGE_* and SCHED_* variable set in
# start's environment is passed to each loop (one argument each, whatever the value holds; unset ones are
# not passed), e.g. `USAGE_7D_PACE=1 scheduler/loops.sh start`.
# A loop runs when its loop.lock is held. That is read from /proc/locks, never by taking the lock:
# a probe holding it even for an instant makes a starting loop's own `flock -n` fail.
# When $nb/scheduler/api.py exists, the read-only API server (P01) is managed too: start runs it in tmux
# session sched-api unless its $root/api.lock is held, stop ends it after the loops have exited, status
# adds a line with its socket $root/api.sock. Without api.py nothing about it is done or shown, and with no
# repositories listed nothing about it runs either (the list is read first). stop signals only a lock holder
# whose pid is > 0 and whose command line has scheduler/api.py, and leaves the server running (rc 1) if a loop
# is still running at the LOOPS_STOP_WAIT deadline.
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

# rtname <spec>: the runtime name: the last component of the path of [<forge>:]<path>.
rtname() { local p=${1#*:}; [ "$p" != "$1" ] || p=$1; p=${p%/}; echo "${p##*/}"; }
repos=()
if [ -r "$list" ]; then
	while IFS= read -r line || [ -n "$line" ]; do
		line=${line%%#*}
		line=$(echo "$line" | tr -d '[:space:]')
		[ -n "$line" ] || continue
		case $line in
		fake:/?*) bad=0 ;;
		github:*) case ${line#github:} in */*/* | /* | */ | */*/ | "") bad=1 ;; */*) bad=0 ;; *) bad=1 ;; esac ;;
		*:*) bad=1 ;;
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
# NESTED_PIDNS=0 only in the initial pid namespace, which the kernel names pid:[4026531836] (readlink of
# /proc/self/ns/pid; NSpid in /proc/self/status would show one pid under a /proc mounted in the
# namespace); 1 in any other or when unknown. Computed once.
NESTED_PIDNS=1
[ "$(readlink /proc/self/ns/pid 2>/dev/null)" = "pid:[4026531836]" ] && NESTED_PIDNS=0

# held <lockfile>: some process holds a lock on the file, as /proc/locks shows it (a line
# "N: FLOCK ADVISORY WRITE <pid> <major>:<minor>:<inode> ...", major and minor in hex; lines with
# "->" are blocked waiters). Inode and device must match; where stat's device is not the one the
# kernel shows there (btrfs subvolumes, overlayfs), the device of the file's mount is tried. The pid
# is of no use for a loop: it is the short-lived `flock` command's, not the loop's. For the API server, which
# takes the lock itself, it is the server (left in $hpid), and stop sends it TERM. NOODLEBOT_PROC_LOCKS names
# the file read instead of /proc/locks (tests only). If that has no line for the file, the lock lines in
# /proc/<pid>/fdinfo/* are tried (a pid namespace's /proc/locks lacks the locks); $hpid is then that <pid>.
held() {
	local f=$1 st ino dev mdev='' n type adv rw pid id rest lino ldev
	[ -e "$f" ] || return 1
	st=$(stat -L -c '%i %d' "$f" 2>/dev/null) || return 1
	ino=${st% *} dev=${st#* }
	dev=$(( ((dev >> 8) & 0xfff) | ((dev >> 32) & ~0xfff) )):$(( (dev & 0xff) | ((dev >> 12) & ~0xff) ))
	# lockmatch [pid]: reads lock lines; a match sets hpid (to the pid argument when given, else the line's).
	lockmatch() {
		while read -r n type adv rw pid id rest; do
			[ "$type" = "->" ] && continue
			lino=${id##*:} ldev=${id%:*}
			[ "$lino" = "$ino" ] || continue
			ldev=$((16#${ldev%%:*})):$((16#${ldev#*:}))
			[ "$ldev" = "$dev" ] && { hpid=${1:-$pid}; return 0; }
			[ -n "$mdev" ] || { mdev=$(findmnt -n -o MAJ:MIN -T "$f" 2>/dev/null | tr -d ' '); mdev=${mdev:-none}; }
			[ "$ldev" = "$mdev" ] && { hpid=${1:-$pid}; return 0; }
		done
		return 1
	}
	lockmatch <"${NOODLEBOT_PROC_LOCKS:-/proc/locks}" && return 0
	# No line in /proc/locks (in a pid namespace of its own it does not list the locks): only now look
	# at the lock lines in /proc/<pid>/fdinfo/<fd>, and only in the fds whose "ino:" is the file's
	# (one grep over all of them). The holder is the pid of the matching path, never the one on the line.
	# Skipped in the initial pid namespace, whose /proc/locks lists every lock (the scan could find
	# nothing, and costs seconds with thousands of fds), unless NOODLEBOT_PROC_LOCKS is set (tests).
	[ -n "${NOODLEBOT_PROC_LOCKS:-}" ] || [ "$NESTED_PIDNS" = 1 ] || return 1
	local fi p
	while read -r fi; do
		p=${fi#/proc/}; p=${p%%/*}
		lockmatch "$p" < <(sed -n 's/^lock:[[:space:]]*//p' "$fi" 2>/dev/null) && return 0
	done < <(grep -s -l -E "^ino:[[:space:]]+$ino\$" /proc/[0-9]*/fdinfo/* 2>/dev/null)
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
			name=$(rtname "$repo")
			if held "$nb/state/$name/loop.lock"; then
				echo "$repo: a loop from before the runtime move holds $nb/state/$name/loop.lock; stop it (touch ~/STOP), run $nb/scheduler/move-runtime.sh $nb, then start again." >&2
				old=1
			fi
		done
		[ $old = 0 ] || { echo "Nothing started." >&2; exit 1; }
	fi
	pass=()
	for v in $(compgen -v | grep -E '^(USAGE|SCHED)_[A-Za-z0-9_]*$'); do pass+=("$v=${!v}"); done
	launched=()
	for repo in "${repos[@]}"; do
		name=$(rtname "$repo")
		if running "$name"; then
			echo "$repo: loop already running"
			[ -e "$HOME/STOP-$name" ] && echo "$repo: note: $HOME/STOP-$name exists; the running loop will stop"
		else
			if [ -e "$HOME/STOP-$name" ]; then
				rm -f "$HOME/STOP-$name"
				echo "$repo: removed stale $HOME/STOP-$name"
			fi
			if tmux new -d -s "sched-$name" env NOODLEBOT_DATA="$root" ${pass[@]+"${pass[@]}"} "$nb/scheduler/loop.sh" "$repo"; then
				echo "$repo: started in tmux session sched-$name"
				launched+=("$repo")
			else
				echo "$repo: could not start tmux session sched-$name" >&2
				rc=1
			fi
		fi
	done
	api_launched=0
	if [ -e "$nb/scheduler/api.py" ]; then
		if held "$root/api.lock"; then
			echo "api: server already running"
		elif tmux new -d -s sched-api env NOODLEBOT_DATA="$root" python3 "$nb/scheduler/api.py"; then
			echo "api: started in tmux session sched-api"
			api_launched=1
		else
			echo "api: could not start tmux session sched-api" >&2
			rc=1
		fi
	fi
	deadline=$((SECONDS + start_wait))
	if [ $api_launched = 1 ]; then
		while ! held "$root/api.lock" && [ $SECONDS -lt $deadline ]; do sleep 0.2; done
		if ! held "$root/api.lock"; then
			echo "api: server did not take its lock within ${start_wait}s; run $nb/scheduler/api.py directly" >&2
			rc=1
		fi
	fi
	for repo in ${launched[@]+"${launched[@]}"}; do
		name=$(rtname "$repo")
		while ! running "$name" && [ $SECONDS -lt $deadline ]; do sleep 0.2; done
		if ! running "$name"; then
			echo "$repo: loop did not take its lock within ${start_wait}s; run $nb/scheduler/loop.sh $repo directly or see $root/state/$name/status.log" >&2
			rc=1
		fi
	done ;;
stop)
	waiting=()
	for repo in "${repos[@]}"; do
		name=$(rtname "$repo")
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
		name=$(rtname "$repo")
		while running "$name" && [ $SECONDS -lt $deadline ]; do sleep 0.2; done
		if running "$name"; then
			echo "$repo: loop still running after ${wait_s}s; left $HOME/STOP-$name in place" >&2
			rc=1
		else
			rm -f "$HOME/STOP-$name"
			echo "$repo: loop stopped"
		fi
	done
	if [ -e "$nb/scheduler/api.py" ]; then
		if held "$root/api.lock"; then
			case $hpid in '' | *[!0-9]* | 0) hpid=0 ;; esac
			if [ "$hpid" -le 0 ] || ! tr '\0' ' ' <"/proc/$hpid/cmdline" 2>/dev/null | grep -q 'scheduler/api\.py'; then
				echo "api: lock holder (pid $hpid) is not the API server; not signalled" >&2
				rc=1
			elif [ "$rc" != 0 ]; then
				echo "api: server left running: a loop is still running" >&2
			else
			kill -TERM "$hpid" 2>/dev/null
			deadline=$((SECONDS + 10))
			while held "$root/api.lock" && [ $SECONDS -lt $deadline ]; do sleep 0.2; done
			if held "$root/api.lock"; then
				echo "api: server still running after 10s" >&2
				rc=1
			else
				echo "api: server stopped"
			fi
			fi
		else
			echo "api: server not running"
		fi
	fi ;;
status)
	for repo in "${repos[@]}"; do
		name=$(rtname "$repo")
		state=$root/state/$name
		if running "$name"; then
			loop="loop running"
			v=$(cat "$state/version" 2>/dev/null) && [ -n "$v" ] && loop="loop running version $v"
		else loop="loop not running"; fi
		live=() wait=()
		for f in "$state"/node/*/session.pid "$state"/issue/*/session.pid; do
			[ -e "$f" ] || continue
			p=$(cat "$f" 2>/dev/null) id=$(basename "$(dirname "$f")")
			case $p in '' | *[!0-9]*) continue ;; esac
			python3 -I -B "$nb/scheduler/harness.py" matches "$id" "$({ tr '\0' ' ' <"/proc/$p/cmdline"; } 2>/dev/null)" || continue
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
	done
	if [ -e "$nb/scheduler/api.py" ]; then
		if held "$root/api.lock"; then echo "api: server running; socket $root/api.sock"
		else echo "api: server not running; socket $root/api.sock"; fi
	fi ;;
esac
exit $rc
