#!/bin/sh
# runtests.sh <test file>...       run the test files, in parallel, and time them
#
# Runs every file given (also after one fails) with bash when its basename is loop.test.sh and with
# sh otherwise, up to $TEST_JOBS at once (default: twice the number of CPUs, else 2). Each file's output is
# captured and printed whole when the file ends, so outputs never interleave. After each file prints
# "TIME <seconds> <file>", then "FAILED <file>" when the file exited non-zero (deploy.sh reads these lines to rerun
# the failed files alone), and "SLOW: <file> took <s>s, budget <n>s" when it took longer than
# $TEST_FILE_BUDGET seconds (default 30). At the end prints "SLOW: total took <s>s, budget <n>s" when
# the whole run took longer than $TEST_BUDGET seconds (default 180), and last "TOTAL <seconds>".
# Exits non-zero when any file failed; with TEST_BUDGET_ENFORCE=1 also when a file or the total is
# over its budget (without it time never fails the run). Each file runs under `setsid` in a process group of its
# own, with NBRT_<runner pid>=<file number> in its environment, which every process it starts inherits, also across
# `setsid`. When a file ends, the runner stops what is left carrying its mark and its group (TERM, then KILL a few
# seconds later; no wait when nothing is left). On INT, TERM or HUP it does the same for every file, never for its
# own group, and exits non-zero. A watcher in a session of its own, holding none of the runner's stdio, does it too
# when the runner is gone (killed with KILL) and ends with it. A test file stopped that way may not run its EXIT
# trap, so its own scratch folders can stay behind.
set -u
jobs=${TEST_JOBS:-$(expr 2 \* "$(nproc 2>/dev/null || echo 1)")}
fbudget=${TEST_FILE_BUDGET:-30}
tbudget=${TEST_BUDGET:-180}
enforce=${TEST_BUDGET_ENFORCE:-0}
[ "$jobs" -ge 1 ] 2>/dev/null || jobs=1
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

own=$(sed 's/^.*) //' "/proc/$$/stat" | cut -d' ' -f3)
# marked <n|all>: the pids carrying the mark of file n (or of any file) of this run.
marked() {
	if [ "$1" = all ]; then
		grep -l -a -z -s "^NBRT_$$=" /proc/[0-9]*/environ 2>/dev/null
	else
		grep -l -a -z -x -F -s "NBRT_$$=$1" /proc/[0-9]*/environ 2>/dev/null
	fi | sed 's|^/proc/\([0-9]*\)/environ$|\1|' | grep -vx "$$"
}
# sendsig <signal>: to $_p (pids) and to the process groups $_g, never our own.
sendsig() {
	[ -z "$_p" ] || kill -s "$1" $_p 2>/dev/null
	for _x in $_g; do
		[ "$_x" = "$own" ] || kill -s "$1" -- "-$_x" 2>/dev/null
	done
	return 0
}
# _grp <groups>: true when one of the process groups still has members.
_grp() {
	for _y in $1; do kill -s 0 -- "-$_y" 2>/dev/null && return 0; done
	return 1
}
# reap <n|all>: stops what is left of file n (or of all files): its marked processes and its group. TERM, then
# KILL for what is still there after 3 s; waits only when something was signalled.
reap() {
	_p=$(marked "$1")
	if [ "$1" = all ]; then _g=$(cat "$tmp"/*.pg 2>/dev/null); else _g=$(cat "$tmp/$1.pg" 2>/dev/null); fi
	_h=""
	for _x in $_g; do
		case $_x in '' | *[!0-9]* | 0 | 1) continue ;; esac
		kill -s 0 -- "-$_x" 2>/dev/null && _h="$_h $_x"
	done
	_g=$_h
	[ -n "$_p$_g" ] || return 0
	sendsig TERM
	_i=0
	while [ "$_i" -lt 30 ] && { [ -n "$(marked "$1")" ] || _grp "$_g"; }; do sleep 0.1; _i=$((_i + 1)); done
	_p=$(marked "$1")
	sendsig KILL
}
# On a signal: stop every file started and what it started, then exit non-zero.
interrupted() {
	trap '' INT TERM HUP
	reap all
	for w in $(pgrep -P $$ 2>/dev/null); do kill "$w" 2>/dev/null; done
	exit 130
}
trap interrupted INT TERM HUP

now() { date +%s.%N; }
# over <seconds> <budget>: true when seconds > budget
over() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }
elapsed() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.2f", b - a }'; }

# One worker per file; it records its output, status and times, and last of all the .done marker.
work() {
	case $(basename "$2") in loop.test.sh) sh=bash ;; *) sh=sh ;; esac
	s=$(now)
	env -u NB_TEST_SHELL "NBRT_$$=$1" setsid -w sh -c 'echo $$ >"$0"; exec "$@"' "$tmp/$1.pg" "$sh" "$2" >"$tmp/$1.out" 2>&1 </dev/null
	echo $? >"$tmp/$1.rc"
	elapsed "$s" "$(now)" >"$tmp/$1.time"
	reap "$1"
	rm -f "$tmp/$1.pg"
	: >"$tmp/$1.done"
}

# The watcher: in a session of its own (started from a subshell so that it is no child of ours, and `wait` below
# does not wait for it), with no stdio of ours. When the runner is gone (also killed with KILL) it stops every
# marked process of the run and removes the scratch folder; it ends with the run.
(
	cd / || exit 1
	setsid sh -c '
		rp=$1 t=$2
		alive() { [ -e "/proc/$rp/stat" ] && ! sed "s/^.*) //" "/proc/$rp/stat" | grep -q "^[ZX]"; }
		pids() { grep -l -a -z -s "^NBRT_$rp=" /proc/[0-9]*/environ 2>/dev/null | sed "s|^/proc/\([0-9]*\)/environ\$|\1|" | grep -vx "$$"; }
		while alive; do sleep 1; done
		p=$(pids)
		if [ -n "$p" ]; then
			kill -s TERM $p 2>/dev/null
			i=0
			while [ "$i" -lt 15 ] && [ -n "$(pids)" ]; do sleep 0.2; i=$((i + 1)); done
			p=$(pids)
			[ -z "$p" ] || kill -s KILL $p 2>/dev/null
		fi
		case $t in /?*) [ ! -d "$t" ] || rm -rf "$t" ;; esac
	' watch "$$" "$tmp" </dev/null >/dev/null 2>&1 &
)

n=$#
start=$(now)
failed=0
slow=0
next=1 # next file to start
shown=0
running=""
while [ "$shown" -lt "$n" ]; do
	if [ "$next" -le "$n" ] && [ "$(echo $running | wc -w)" -lt "$jobs" ]; then
		eval "f=\${$next}"
		work "$next" "$f" &
		running="$running $next"
		next=$((next + 1))
		continue
	fi
	progressed=0
	for i in $running; do
		[ -e "$tmp/$i.done" ] || continue
		eval "f=\${$i}"
		cat "$tmp/$i.out"
		t=$(cat "$tmp/$i.time")
		echo "TIME $t $f"
		if [ "$(cat "$tmp/$i.rc")" -ne 0 ]; then failed=1; echo "FAILED $f"; fi
		if over "$t" "$fbudget"; then echo "SLOW: $f took ${t}s, budget ${fbudget}s"; slow=1; fi
		running=$(echo $running | tr ' ' '\n' | grep -vx "$i" | tr '\n' ' ')
		shown=$((shown + 1))
		progressed=1
	done
	[ "$progressed" = 1 ] || sleep 0.1
done
wait
total=$(elapsed "$start" "$(now)")
if over "$total" "$tbudget"; then echo "SLOW: total took ${total}s, budget ${tbudget}s"; slow=1; fi
echo "TOTAL $total"
[ "$failed" -eq 0 ] || exit 1
[ "$enforce" != 1 ] || [ "$slow" -eq 0 ] || exit 1
exit 0
