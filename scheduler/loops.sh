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
# would otherwise use another root and another lock. Likewise every USAGE_* and SCHED_* variable, and PICKUP, PICKUP_RUNS and PICKUP_CEILING, set in
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
# M04: with ~/.config/noodlebot/units present (its contents do not matter), start runs the first `tmux new` of a
# run, when no tmux server runs, as `systemd-run --user --scope --collect --unit noodlebot-loops tmux new ...`
# (the later ones directly), so the server outlives the login session; a server already running in a
# session-<n>.scope gets one line saying the loops end with that login and how to move them (read from
# /proc/<pid>/cgroup, or <NOODLEBOT_PROC_ROOT>/<pid>/cgroup in tests). start and status read
# `loginctl show-user <user> -p Linger` and print one line on Linger=no; nothing is ever changed (no
# enable-linger, nothing written under ~/.config/systemd). If systemd-run is missing or fails, that tmux new
# runs directly, one line says the loops run in the calling shell's session, and systemd-run is not tried
# again in that run. Without the units file neither loginctl nor systemd-run is called, status prints
# nothing new, and start prints that one calling-shell line.
# M05: start writes the settings it passes to $root/state/loops.env (mode 0600, one VAR=value per line, written
# by temp file and rename) and removes $root/state/loops.stopped; stop writes loops.stopped. `loops.sh watch`
# (for a timer or cron; prints only failures, besides the shared "no repositories listed" and login-scope lines) starts, under its own lock $root/state/watch.lock, every listed loop and the
# API whose lock is not held, as start does and with the settings of loops.env (never evaluated), unless ~/STOP,
# ~/STOP-<name> (that repository) or loops.stopped exists. It waits like start for what it started to take its
# locks, leaves them running when it exits, and appends one line per restart to $root/state/<name>/status.log:
# "<UTC stamp> loops.sh watch: restarted the loop (heartbeat <n> s old)" or "(no heartbeat)". watch exits 1, starting
# nothing, when it cannot open watch.lock. A loop whose lock is held and whose heartbeat is older than LOOPS_STALE
# (default 1800) s is never signalled: watch appends "<UTC stamp> loops.sh watch: <owner/name>: loop is stale (heartbeat <n> s old)"
# to $root/state/watch.log and has `report.py --stale <n>` comment on the open log issue, once per stale episode (the marker
# state/<name>/stale.posted stays until a watch sees the heartbeat fresh; a failed post says so on stderr and is retried).
#   scheduler/loops.sh watch-unit   print the system service and timer for a watch every LOOPS_WATCH_EVERY (default 5min)
# and the commands that install them (the owner runs them once); it calls no systemctl, systemd-run or sudo and writes nothing.
# M05: with the units file and `systemctl --user` answering, start also sets up a transient user timer noodlebot-watch that runs
# `loops.sh watch` every LOOPS_WATCH_EVERY, with start's NOODLEBOT_DATA and PATH, unless it is already active; stop stops it;
# status adds one line naming the active watch timers (system, user or none). The system timer from watch-unit outlives the user manager.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -u
nb=$(cd "$(dirname "$0")/.." && pwd -P) || exit 2
list=$HOME/.config/noodlebot/repos
root=${NOODLEBOT_DATA:-$HOME/.local/share/noodlebot}
case $root in /*) ;; *) root=$PWD/$root ;; esac
wait_s=${LOOPS_STOP_WAIT:-300}
start_wait=${LOOPS_START_WAIT:-10}

usage() { echo "usage: loops.sh start|stop|status|watch|watch-unit" >&2; exit 2; }
[ $# -eq 1 ] || usage
cmd=$1
case $cmd in start | stop | status | watch | watch-unit) ;; *) usage ;; esac
if [ "$cmd" = watch-unit ]; then
	every=${LOOPS_WATCH_EVERY:-5min}
	u=$(id -un); uid=$(id -u)
	wroot=${NOODLEBOT_DATA:-$HOME/.local/share/noodlebot}
	case $wroot in /*) ;; *) wroot=$PWD/$wroot ;; esac
	wroot=$(cd "$wroot" 2>/dev/null && pwd -P || echo "$wroot")
	# systemd quoting: Environment="K=V" escapes \ and " and doubles %; ExecStart doubles % and $ and quotes the path when needed
	q() { local v=${1//\\/\\\\}; v=${v//\"/\\\"}; echo "${v//%/%%}"; }
	# a checkout path with a quote, a backslash or a control character is refused; "$" stays single in ExecStart (only arguments are substituted)
	case $nb in *[\"\'\\]* | *[[:cntrl:]]*) echo "loops.sh watch-unit: the checkout path holds a quote, a backslash or a control character; move the checkout" >&2; exit 1 ;; esac
	ex=${nb//%/%%}
	case $ex in *[[:space:]]*) ex=\"$ex/scheduler/loops.sh\" ;; *) ex=$ex/scheduler/loops.sh ;; esac
	svc="[Unit]
Description=noodlebot watch: start the loops and the API that are not running

[Service]
Type=oneshot
User=$u
ExecStart=$ex watch
Environment=\"HOME=$(q "$HOME")\"
Environment=\"NOODLEBOT_DATA=$(q "$wroot")\"
Environment=\"PATH=$(q "$PATH")\"
Environment=XDG_RUNTIME_DIR=/run/user/$uid
KillMode=process"
	tmr="[Unit]
Description=noodlebot watch every $every

[Timer]
OnBootSec=$every
OnUnitActiveSec=$every

[Install]
WantedBy=timers.target"
	# a here-document delimiter that no line of the units equals
	d=EOF; while printf '%s\n%s\n' "$svc" "$tmr" | grep -qx "$d"; do d=${d}_; done
	printf '# /etc/systemd/system/noodlebot-watch.service\n%s\n\n# /etc/systemd/system/noodlebot-watch.timer\n%s\n\n# install (run these lines):\n' "$svc" "$tmr"
	printf "sudo tee /etc/systemd/system/noodlebot-watch.service >/dev/null <<'%s'\n%s\n%s\n" "$d" "$svc" "$d"
	printf "sudo tee /etc/systemd/system/noodlebot-watch.timer >/dev/null <<'%s'\n%s\n%s\n" "$d" "$tmr" "$d"
	echo "sudo systemctl daemon-reload"
	echo "sudo systemctl enable --now noodlebot-watch.timer"
	exit 0
fi

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
		# o/n and github:o/n are one repository: the second spelling is dropped
		dup=0; for r in ${repos[@]+"${repos[@]}"}; do [ "${r#github:}" != "${line#github:}" ] || dup=1; done
		[ $dup = 0 ] || continue
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
# The list is read afresh up to three times first, as one read can miss a line (see below).
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
	# /proc/locks is a seq_file read by position: when other locks come and go during one read, a line
	# can be skipped (even for one cat), and a skipped line is a false "not held". Reading again from a
	# new open fixes it, so when the list has no line for the file it is read afresh, up to three times in
	# all, before the fdinfo fallback is tried. grep reads the file in large chunks and passes on only the
	# lines with the inode (a superset of what lockmatch accepts, which still checks the device), so bash's
	# byte-at-a-time read from a pipe sees a few lines, not the whole list, and a not-held probe stays cheap.
	local try
	for try in 1 2 3; do
		lockmatch < <(grep -s -E ":$ino([[:space:]]|\$)" "${NOODLEBOT_PROC_LOCKS:-/proc/locks}") && return 0
	done
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
# M04 helpers. units: ~/.config/noodlebot/units is present.
units=0
[ -e "$HOME/.config/noodlebot/units" ] && units=1
use_sd=0 said_where=0
say_where() {
	[ $said_where = 1 ] && return 0
	said_where=1
	echo "loops.sh: the loops and the server run in the calling shell's session and end with it; see the README on ~/.config/noodlebot/units."
}
# linger_line: one line when loginctl reports Linger=no for the user (units file only; read only).
linger_line() {
	[ $units = 1 ] || return 0
	local u l
	u=$(id -un 2>/dev/null) || return 0
	l=$(loginctl show-user "$u" -p Linger 2>/dev/null) || return 0
	case $l in
	Linger=no) echo "loops.sh: lingering is off for $u: a logout stops the loops and the API; run 'loginctl enable-linger $u' to keep them." ;;
	esac
	return 0
}
# user_timer_state: the state `systemctl --user is-active noodlebot-watch.timer` prints (empty when systemctl --user does not answer)
user_timer_state() {
	command -v systemctl >/dev/null 2>&1 || return 0
	systemctl --user is-active noodlebot-watch.timer 2>/dev/null </dev/null
	return 0
}
# watch_line: one line naming the active watch timers (units file only; read only).
watch_line() {
	[ $units = 1 ] || return 0
	local w=
	command -v systemctl >/dev/null 2>&1 || { echo "loops.sh: watch timers active: none"; return 0; }
	[ "$(systemctl is-active noodlebot-watch.timer 2>/dev/null </dev/null)" = active ] && w=system
	[ "$(systemctl --user is-active noodlebot-watch.timer 2>/dev/null </dev/null)" = active ] && w=${w:+$w and }user
	echo "loops.sh: watch timers active: ${w:-none}"
	return 0
}
# server_pid: the pid of the running tmux server (empty when none).
server_pid() {
	local p
	p=$(tmux display -p '#{pid}' 2>/dev/null) || return 0
	case $p in '' | *[!0-9]*) return 0 ;; esac
	echo "$p"
}
# check_server: with the units file, decide how the first tmux new runs, and say when a running server is in a login session.
check_server() {
	[ $units = 1 ] || return 0
	local p cg
	p=$(server_pid)
	if [ -z "$p" ]; then
		use_sd=1
		return 0
	fi
	cg=$(cat "${NOODLEBOT_PROC_ROOT:-/proc}/$p/cgroup" 2>/dev/null) || return 0
	case $cg in
	*user@*.service*) ;;
	*/session-*.scope*) echo "loops.sh: the tmux server runs in a login session's scope, so the loops and the API end with that login session; to move them: stop the loops (loops.sh stop), end the tmux server, then start again." ;;
	esac
	return 0
}
# tnew <tmux new arguments>: tmux new, the first one through systemd-run when check_server chose so.
tnew() {
	local r
	if [ $use_sd = 1 ]; then
		use_sd=0
		if command -v systemd-run >/dev/null 2>&1; then
			systemd-run --user --scope --collect --unit noodlebot-loops tmux new "$@" && return 0
			r=$?
			# with --scope the status is the command's: a server running now means tmux itself failed
			[ -z "$(server_pid)" ] || return $r
		fi
		say_where
	elif [ $units = 0 ]; then
		say_where
	fi
	tmux new "$@"
}
# running <name>: the loop's lock is held.
running() { held "$root/state/$1/loop.lock"; }
# resolved <dir>: the directory with symbolic links resolved, or as given when it does not exist.
resolved() { (cd "$1" 2>/dev/null && pwd -P) || echo "$1"; }

# stale_check <repo> <name>: a held loop whose heartbeat is older than LOOPS_STALE is noted in watch.log and reported once per episode
stale_check() {
	local hb age sig why errf mark=$root/state/$2/stale.posted
	hb=$(cat "$root/state/$2/heartbeat" 2>/dev/null)
	case $hb in '' | *[!0-9]*) rm -f "$mark"; return 0 ;; esac
	age=$(( $(date +%s) - hb ))
	if [ "$age" -le "${LOOPS_STALE:-1800}" ]; then rm -f "$mark"; return 0; fi
	[ -e "$mark" ] && return 0
	errf=$(mktemp "${TMPDIR:-/tmp}/loops-stale.XXXXXX") || errf=/dev/null
	sig=$(sh "$nb/scheduler/version.sh" --signature "$nb" 2>/dev/null) || sig=
	[ -n "$sig" ] || sig="— n00dl3b0t unknown"
	echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) loops.sh watch: $1: loop is stale (heartbeat $age s old)" >>"$root/state/watch.log"
	if NOODLEBOT_FORGE_REPO=$1 NOODLEBOT_FORGE_TOKEN_SCRIPT=$HOME/.config/noodlebot/token timeout 120 python3 -I "$nb/scheduler/report.py" --repo "$1" --state "$root/state/$2" --stale "$age" --signature "$sig" 8>&- >/dev/null 2>"$errf"; then
		: >"$mark"
	else
		why=$(grep -v '^[[:space:]]*$' "$errf" 2>/dev/null | tail -n 1 | tr -d '\r' | cut -c1-300)
		echo "loops.sh watch: $1: the stale-loop comment was not posted${why:+ ($why)}; the next watch tries again" >&2
	fi
	[ "$errf" = /dev/null ] || rm -f "$errf"
}

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
	linger_line
	check_server
	pass=()
	for v in $(compgen -v | grep -E '^((USAGE|SCHED)_[A-Za-z0-9_]*|PICKUP(_[A-Za-z0-9_]*)?)$'); do pass+=("$v=${!v}"); done
	# M05: the settings passed are recorded for `watch`; start is wanted again
	if mkdir -p "$root/state" 2>/dev/null; then
		( umask 077; { for ((i = 0; i < ${#pass[@]}; i++)); do printf '%s\n' "${pass[i]}"; done; } >"$root/state/.loops.env.$$" && mv -f "$root/state/.loops.env.$$" "$root/state/loops.env" ) 2>/dev/null
		rm -f "$root/state/loops.stopped"
	fi
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
			if tnew -d -s "sched-$name" env NOODLEBOT_DATA="$root" ${pass[@]+"${pass[@]}"} "$nb/scheduler/loop.sh" "$repo"; then
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
		elif tnew -d -s sched-api env NOODLEBOT_DATA="$root" python3 "$nb/scheduler/api.py"; then
			echo "api: started in tmux session sched-api"
			api_launched=1
		else
			echo "api: could not start tmux session sched-api" >&2
			rc=1
		fi
	fi
	tstate=
	[ $units = 1 ] && tstate=$(user_timer_state)
	if [ -n "$tstate" ] && [ "$tstate" != active ]; then
		systemctl --user reset-failed noodlebot-watch.timer noodlebot-watch.service >/dev/null 2>&1 </dev/null
		systemd-run --user --unit noodlebot-watch "--on-active=${LOOPS_WATCH_EVERY:-5min}" "--on-unit-active=${LOOPS_WATCH_EVERY:-5min}" --property=KillMode=process "--setenv=NOODLEBOT_DATA=$(resolved "$root")" "--setenv=PATH=$PATH" "$nb/scheduler/loops.sh" watch >/dev/null 2>&1 </dev/null || {
			echo "loops.sh: the watch timer noodlebot-watch could not be set up" >&2
			rc=1
		}
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
watch)
	if [ -e "$HOME/STOP" ] || [ -e "$root/state/loops.stopped" ]; then exit 0; fi
	mkdir -p "$root/state" || exit 1
	{ exec 8>"$root/state/watch.lock"; } 2>/dev/null || { echo "loops.sh watch: cannot open $root/state/watch.lock" >&2; exit 1; }
	{ flock -w 120 8 || { echo "loops.sh watch: another watch holds $root/state/watch.lock" >&2; exit 1; }; }
	said_where=1 # from a timer there is no calling shell
	# stop may have run while this watch waited for the lock
	if [ -e "$HOME/STOP" ] || [ -e "$root/state/loops.stopped" ]; then exit 0; fi
	wpass=()
	if [ -r "$root/state/loops.env" ]; then
		while IFS= read -r line || [ -n "$line" ]; do
			case $line in [A-Za-z_]*=*) wpass+=("$line") ;; esac
		done <"$root/state/loops.env"
	fi
	check_server
	launched=()
	for repo in "${repos[@]}"; do
		name=$(rtname "$repo")
		if running "$name"; then stale_check "$repo" "$name"; continue; fi
		[ -e "$HOME/STOP-$name" ] && continue
		if [ -e "$HOME/STOP" ] || [ -e "$root/state/loops.stopped" ]; then break; fi
		hb=$(cat "$root/state/$name/heartbeat" 2>/dev/null)
		case $hb in '' | *[!0-9]*) how="no heartbeat" ;; *) how="heartbeat $(( $(date +%s) - hb )) s old" ;; esac
		if tnew -d -s "sched-$name" env NOODLEBOT_DATA="$root" ${wpass[@]+"${wpass[@]}"} "$nb/scheduler/loop.sh" "$repo" 8>&-; then
			mkdir -p "$root/state/$name"
			echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) loops.sh watch: restarted the loop ($how)" >>"$root/state/$name/status.log"
			launched+=("$repo")
		else
			echo "$repo: could not start tmux session sched-$name" >&2
			rc=1
		fi
	done
	api_launched=0
	if [ -e "$nb/scheduler/api.py" ] && ! held "$root/api.lock" && [ ! -e "$HOME/STOP" ] && [ ! -e "$root/state/loops.stopped" ]; then
		if tnew -d -s sched-api env NOODLEBOT_DATA="$root" python3 "$nb/scheduler/api.py" 8>&-; then
			api_launched=1
		else
			echo "api: could not start tmux session sched-api" >&2
			rc=1
		fi
	fi
	deadline=$((SECONDS + start_wait))
	if [ $api_launched = 1 ]; then
		while ! held "$root/api.lock" && [ $SECONDS -lt $deadline ]; do sleep 0.2; done
		held "$root/api.lock" || { echo "api: server did not take its lock within ${start_wait}s" >&2; rc=1; }
	fi
	for repo in ${launched[@]+"${launched[@]}"}; do
		name=$(rtname "$repo")
		while ! running "$name" && [ $SECONDS -lt $deadline ]; do sleep 0.2; done
		running "$name" || { echo "$repo: loop did not take its lock within ${start_wait}s; see $root/state/$name/status.log" >&2; rc=1; }
	done ;;
stop)
	if [ $units = 1 ] && [ -n "$(user_timer_state)" ]; then systemctl --user stop noodlebot-watch.timer >/dev/null 2>&1 </dev/null; fi
	mkdir -p "$root/state" 2>/dev/null && : >"$root/state/loops.stopped"
	# a watch already past its checks is starting loops: let it finish, then stop what it started
	if [ -d "$root/state" ]; then
		( { exec 9>>"$root/state/watch.lock"; } 2>/dev/null && { flock -w $((start_wait + 30)) 9 || echo "loops.sh stop: a watch still holds $root/state/watch.lock" >&2; } )
	fi
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
			if [ "$hpid" -le 0 ] || ! tr '\0' ' ' 2>/dev/null <"/proc/$hpid/cmdline" | grep -q 'scheduler/api\.py'; then
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
		for f in "$state"/node/*/session.pid "$state"/issue/*/session.pid "$state"/adopt/*/session.pid; do
			[ -e "$f" ] || continue
			p=$(cat "$f" 2>/dev/null) id=$(basename "$(dirname "$f")")
			case $f in */adopt/*) id=$(dirname "$f") ;; esac   # an adoption unit is found by its state folder
			case $p in '' | *[!0-9]*) continue ;; esac
			python3 -I -B "$nb/scheduler/harness.py" matches "$id" "$({ tr '\0' ' ' <"/proc/$p/cmdline"; } 2>/dev/null)" || continue
			case $f in */issue/*) id="#$id" ;; */adopt/*) id="adopt/$(basename "$id")" ;; esac
			live+=("$id")
		done
		for d in "$state"/node/*/ "$state"/issue/*/ "$state"/adopt/*/; do
			[ -d "$d" ] || continue
			id=$(basename "$d") d=${d%/}
			case $d in */issue/*) id="#$id" ;; */adopt/*) id="adopt/$id" ;; esac
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
	fi
	linger_line
	watch_line ;;
esac
exit $rc
