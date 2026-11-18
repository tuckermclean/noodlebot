#!/bin/sh
# D11-AC-1, D11-AC-2, D11-AC-3: after a test run no process is left behind, however a test file ends.
#   sh scheduler/runtests-d11.test.sh   (make test)
#
# Runs scheduler/runtests.sh on fake test files in a scratch folder. Each fake file makes its own `mktemp -d`
# folder and starts long-running processes with its working directory there: one with plain `&`, one with
# `setsid ... &` (each also once more from a subshell that ends, so that no process tree leads to it), and one through the shared start helper (whose fixture itself starts a `setsid ... &` process).
#  - D11-AC-1: the file exits without its cleanup, exits non-zero partway, or is killed with KILL from outside; the
#    runner's TIME / FAILED / SLOW / TOTAL lines and exit status are as D03 made them; a file that leaves nothing
#    behind adds no wait; within 10 s no process names the file's folder in its command line or working directory.
#  - D11-AC-2: the runner, in a process group of its own (a wrapper shell started with `setsid` leads it), is sent
#    TERM partway (a sentinel child of the wrapper, in the runner's group, must still run afterwards), or is
#    killed with KILL together with its group: within 10 s nothing of its files and nothing of the runner remains.
#  - D11-AC-3: the helper's fixture runs in its own session and ends with the shell of the test file that started
#    it (the file run alone with `sh <file>`, killed with TERM, and with KILL), with its setsid child; `$!` is the
#    fixture's pid, a child of the test shell that can be killed and waited for; `x=$(<start> & echo ok)` returns
#    at once; the fixture also ends at its hard lifetime. ("Every fixture starts through it" is the reviewer's.)
#
# THE SHARED START HELPER (the interface this test fixes; the implementer builds to it):
#   file:      scheduler/testdata/lib/fixture.sh, used as   . "$src/testdata/lib/fixture.sh"
#   function:  fixture_start <command> [args...] </dev/null >/dev/null 2>&1 &
#              The CALLER writes the trailing `&` (and the fixture's redirections) on the line, as the frozen start
#              lines already have one; the function then runs in the background subshell, so `$!` is that subshell's
#              pid. The function starts the watch (a process in a session of its own with stdin, stdout and stderr on
#              /dev/null, so it holds none of the caller's) and then `exec`s the fixture as `setsid <command>`: the
#              subshell is not a group leader, so setsid does not fork and the fixture keeps the pid `$!` names,
#              as a child of the test shell, in a session and process group of its own.
#   variables: sourcing the file exports NB_TEST_SHELL=$$ (the pid of the sourcing shell, the test shell) unless it
#              is set already (so scripts such as fake tmux, started by fixtures, find the test shell through it).
#              The fixture's environment holds NB_FIXTURE_MARK=<unique per fixture>, which its descendants inherit,
#              also across setsid. NB_FIXTURE_LIFETIME=<seconds> (read when the fixture starts; default several
#              minutes, well over TEST_FILE_BUDGET) is the fixture's hard lifetime.
#   watch:     polls (about every second) whether the test shell NB_TEST_SHELL is gone (not there, or a zombie) or
#              the lifetime is over; then stops the fixture's process group and every process that carries the
#              fixture's NB_FIXTURE_MARK (TERM, then KILL a few seconds later) and exits.
# D11_RUNNER / D11_HELPER override the runner / helper file (for trying the test on prototypes).
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
runner=${D11_RUNNER:-$src/runtests.sh}
helper=${D11_HELPER:-$src/testdata/lib/fixture.sh}
. "$src/testdata/lib/common.sh"
unset TMUX USAGE_7D_MARGIN NOODLEBOT_DATA NOODLEBOT_VERSION TEST_JOBS TEST_FILE_BUDGET TEST_BUDGET TEST_BUDGET_ENFORCE
unset NB_TEST_SHELL NB_FIXTURE_MARK NB_FIXTURE_LIFETIME D11TAG
tmp=$(mktemp -d) && [ -d "$tmp" ] || exit 1
tag=d11.$$
# Every process a scenario starts carries D11TAG=$tag.<id> in its environment (also across setsid), which is how
# this file finds, and at the end stops, what its scenarios started. Only processes with this run's pid in the tag.
tagged() { grep -l -a -z -x -s "D11TAG=$1" /proc/[0-9]*/environ 2>/dev/null | sed 's|^/proc/\([0-9]*\)/environ$|\1|'; }
reap_all() {
	_p=$(grep -l -a -z -s "^D11TAG=$tag\." /proc/[0-9]*/environ 2>/dev/null | sed 's|^/proc/\([0-9]*\)/environ$|\1|' | grep -vx "$$")
	# shellcheck disable=SC2086
	[ -z "$_p" ] || kill -KILL $_p 2>/dev/null
	return 0
}
cleanup() { reap_all; rm -rf "$tmp"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

rd=$tmp/rd w=$tmp/w f=$tmp/f
mkdir -p "$rd" "$w" "$f"
now_ms() { echo $(($(date +%s%N) / 1000000)); }
isnum() { case $1 in '' | *[!0-9]*) return 1 ;; esac; }
statf() { sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f1-4; } # state ppid pgrp session
alive() { [ -e "/proc/$1/stat" ] && ! statf "$1" | grep -q '^[ZX]'; }
pgrp_of() { statf "$1" | cut -d' ' -f3; }
sid_of() { statf "$1" | cut -d' ' -f4; }
ppid_of() { statf "$1" | cut -d' ' -f2; }
gone2() { ! alive "$1" && ! alive "$2"; }
sid_is_pid() { [ "$(sid_of "$1")" = "$1" ] && [ "$(pgrp_of "$1")" = "$1" ]; }
# named <id>: the processes that name the scenario's folders ($tmp/<id>/) in their command line or working directory.
named() {
	{
		grep -l -a -F -f "$tmp/pat.$1" /proc/[0-9]*/cmdline 2>/dev/null | sed 's|^/proc/\([0-9]*\)/cmdline$|\1|'
		ls -l /proc/[0-9]*/cwd 2>/dev/null | grep -a -F -f "$tmp/pat.$1" | sed 's|^.* /proc/\([0-9]*\)/cwd .*$|\1|'
	} | sort -u
}
# left <id> [excluded pid]: what is left of the scenario: processes naming its folders, or carrying its tag.
left() { { named "$1"; tagged "$tag.$1"; } | sort -u | grep -vx -- "${2:-0}"; }
clear_ex() { [ -z "$(left "$1" "${2:-0}")" ]; }
shown() { for _p in $(left "$1" "${2:-0}"); do printf ' %s:%s' "$_p" "$(tr '\0' ' ' <"/proc/$_p/cmdline" 2>/dev/null | cut -c1-40)"; done; }

# --- the fake test files ---------------------------------------------------------------------------------------
cat >"$tmp/body.sh" <<'EOT'
d=$(mktemp -d) && [ -d "$d" ] || exit 1
n=$(basename "$0" .test.sh)
(cd "$d" && exec sleep 301) &
echo $! >>"$RD/$n.pids"
(cd "$d" && exec setsid sleep 302) &
echo $! >>"$RD/$n.pids"
( cd "$d" && sleep 306 & ) # left without a parent: no process tree leads to it
( cd "$d" && setsid sleep 307 & )
[ -f "$H" ] && . "$H"
fixture_start sh -c 'cd "$1" && { setsid sleep 303 & exec sleep 304; }' fx "$d" </dev/null >/dev/null 2>&1 &
echo $! >>"$RD/$n.pids"
EOT
mkfake() { { cat "$tmp/body.sh"; cat; } >"$f/$1.test.sh"; }
mkfake a <<'EOT'
touch "$RD/$n.ready"
exit 0
EOT
mkfake b <<'EOT'
touch "$RD/$n.ready"
echo "FAIL: crash partway"
exit 7
EOT
mkfake c <<'EOT'
echo $$ >"$RD/$n.shell"
touch "$RD/$n.ready"
sleep 300
EOT
for n in t k; do
	mkfake $n <<'EOT'
touch "$RD/$n.ready"
sleep 300
EOT
done
cat >"$f/z.test.sh" <<'EOT'
echo "PASS: nothing left behind"
EOT
# Files run alone with `sh <file>`: the fixture records its pid and its setsid child's pid.
cat >"$tmp/halone.sh" <<'EOT'
n=$(basename "$0" .test.sh)
[ -f "$H" ] && . "$H"
. "$COMMON"
[ "$n" != hd ] || { NB_FIXTURE_LIFETIME=2; export NB_FIXTURE_LIFETIME; }
fixture_start sh -c 'setsid sleep 303 & echo $! >"$1.child"; echo $$ >"$1.pid"; exec sleep 304' fx "$RD/$n" </dev/null >/dev/null 2>&1 &
echo $! >"$RD/$n.bang"
wait_file 10 "$RD/$n.child"
wait_file 10 "$RD/$n.pid"
touch "$RD/$n.ready"
sleep 300
EOT
for n in ha hb hd; do cp "$tmp/halone.sh" "$f/$n.test.sh"; done
cat >"$f/hc.test.sh" <<'EOT'
n=$(basename "$0" .test.sh)
[ -f "$H" ] && . "$H"
. "$COMMON"
fixture_start sh -c 'echo $$ >"$1.pid"; exec sleep 305' fx "$RD/$n" </dev/null >/dev/null 2>&1 &
b=$!
wait_file 10 "$RD/$n.pid"
fp=$(cat "$RD/$n.pid" 2>/dev/null)
set -- $(sed 's/^.*) //' "/proc/$b/stat" 2>/dev/null)
echo "bang=$b fixture=$fp shell=$$ ppid=${2:-} pgrp=${3:-} sid=${4:-}" >"$RD/$n.res"
kill "$b" 2>/dev/null
wait "$b"
echo "waited=$?" >>"$RD/$n.res"
t0=$(date +%s%N)
x=$(fixture_start sleep 306 </dev/null >/dev/null 2>&1 & echo ok)
t1=$(date +%s%N)
echo "subst=$x ms=$(((t1 - t0) / 1000000))" >>"$RD/$n.res"
touch "$RD/$n.done"
EOT
cat >"$tmp/wrap.sh" <<'EOT'
echo $$ >"$RD/$ID.wrapper"
sleep 599 &
echo $! >"$RD/$ID.sentinel"
sh "$RUNNER" "$@" &
rp=$!
echo $rp >"$RD/$ID.runner"
wait $rp
echo $? >"$RD/$ID.rc"
EOT

# --- starting a scenario ---------------------------------------------------------------------------------------
# prep <id>: the scenario's folder ($tmp/<id>, its TMPDIR) and the pattern file naming it.
prep() { mkdir -p "$tmp/$1"; printf '%s/\n' "$tmp/$1" >"$tmp/pat.$1"; }
# env_for <id>: the scenario's environment, as `export` lines to eval in the starting subshell.
scen_env() {
	D11TAG="$tag.$1" TMPDIR="$tmp/$1" RD="$rd" H="$helper" COMMON="$src/testdata/lib/common.sh" ID="$1" RUNNER="$runner"
	export D11TAG TMPDIR RD H COMMON ID RUNNER
}
# sh_run <id> "<env>" files...: the runner in the background; output o.<id>, wall ms o.<id>.ms, status o.<id>.rc.
sh_run() {
	_id=$1 _env=$2
	shift 2
	prep "$_id"
	(
		cd "$w" || exit 1
		scen_env "$_id"
		s=$(now_ms)
		# shellcheck disable=SC2086
		env $_env sh "$runner" "$@" >"$tmp/o.$_id" 2>&1 </dev/null
		echo $? >"$tmp/o.$_id.rc.tmp"
		echo $(($(now_ms) - s)) >"$tmp/o.$_id.ms"
		mv "$tmp/o.$_id.rc.tmp" "$tmp/o.$_id.rc"
	) &
}
# sh_wrap <id> files...: the runner led by a wrapper shell that setsid made the leader of a group of its own, with
# a sentinel child of the wrapper in that group; the wrapper records the pids and the runner's status in $rd.
sh_wrap() {
	_id=$1
	shift
	prep "$_id"
	(
		cd "$w" || exit 1
		scen_env "$_id"
		exec setsid sh "$tmp/wrap.sh" "$@" </dev/null >/dev/null 2>&1
	) &
}
# sh_file <id>: a fake file run alone, as `sh <file>`; $! is its shell.
sh_file() {
	prep "$1"
	(
		cd "$w" || exit 1
		scen_env "$1"
		exec sh "$f/$1.test.sh" </dev/null >/dev/null 2>&1
	) &
}
readpid() { cat "$rd/$1" 2>/dev/null; }

# --- the drivers: each runs one scenario and prints its PASS / FAIL lines to its own file; they run concurrently ---
has() { if grep -Eq -- "$3" "$2" 2>/dev/null; then pass "$1"; else fail "$1"; fi; }
hasnt() { if grep -Eq -- "$3" "$2" 2>/dev/null; then fail "$1"; else pass "$1"; fi; }
setup_ok() { # <label> <id>: the fake file started its three processes
	[ "$(wc -l <"$rd/$2.pids" 2>/dev/null)" = 3 ] && pass "$1:the fake file started its three background processes" || fail "$1:the fake file started its three background processes"
}
# drv_exit <id> <D11-AC-1 label> <env> <ready?>: a runner run on one fake file that ends on its own (or is killed by the driver).
drv_exit() {
	id=$1 L="D11-AC-1:$2"
	sh_run "$id" "$3" "$f/$id.test.sh"
	if [ "$id" = c ]; then
		wait_file 20 "$rd/c.ready" || fail "$L:the fake file started"
		sp=$(readpid c.shell)
		isnum "$sp" && kill -KILL "$sp" 2>/dev/null || fail "$L:the file's shell could be killed from outside"
	fi
	wait_file 30 "$tmp/o.$id.rc" || { fail "$L:the runner ended"; return; }
	setup_ok "$L" "$id"
	if wait_until 10 clear_ex "$id"; then
		pass "$L:within 10 s no process names the fake file's folder in its command line or working directory, none carries its mark"
	else
		fail "$L:within 10 s no process names the fake file's folder in its command line or working directory (left:$(shown "$id"))"
	fi
	rc=$(cat "$tmp/o.$id.rc")
	case $id in
	a) [ "$rc" = 0 ] && pass "$L:the runner exits 0 for a passing file" || fail "$L:the runner exits 0 for a passing file (got $rc)" ;;
	*) [ "$rc" = 1 ] && pass "$L:the runner exits 1 when the file failed" || fail "$L:the runner exits 1 when the file failed (got $rc)" ;;
	esac
	has "$L:a TIME line for the file" "$tmp/o.$id" "^TIME [0-9]+\.[0-9]{2} .*/$id\.test\.sh\$"
	has "$L:a TOTAL line" "$tmp/o.$id" '^TOTAL [0-9]+\.[0-9]{2}$'
	if [ "$id" = a ]; then
		hasnt "$L:no FAILED line for a passing file" "$tmp/o.$id" '^FAILED '
		has "$L:SLOW line for the file over its budget" "$tmp/o.$id" "^SLOW: .*/a\.test\.sh took [0-9.]+s, budget -1s\$"
		has "$L:SLOW line for the total over its budget" "$tmp/o.$id" '^SLOW: total took [0-9.]+s, budget -1s$'
	else
		has "$L:a FAILED line for the failed file" "$tmp/o.$id" "^FAILED .*/$id\.test\.sh\$"
		hasnt "$L:no SLOW line within the budgets" "$tmp/o.$id" '^SLOW:'
	fi
}
drv_a() { drv_exit a "a file that exits without its cleanup" "TEST_FILE_BUDGET=-1 TEST_BUDGET=-1"; }
drv_b() { drv_exit b "a file that exits non-zero partway" ""; }
drv_c() { drv_exit c "a file killed with KILL from outside" ""; }
drv_z() {
	L="D11-AC-1:a file that leaves nothing behind"
	sh_run z "" "$f/z.test.sh"
	wait_file 30 "$tmp/o.z.rc" || { fail "$L:the runner ended"; return; }
	ms=$(cat "$tmp/o.z.ms")
	[ "$ms" -lt 2000 ] && pass "$L:the runner ends within 2 s ($ms ms)" || fail "$L:the runner ends within 2 s (took $ms ms)"
	[ "$(cat "$tmp/o.z.rc")" = 0 ] && pass "$L:the runner exits 0" || fail "$L:the runner exits 0"
	has "$L:a TIME line" "$tmp/o.z" "^TIME [0-9]+\.[0-9]{2} .*/z\.test\.sh\$"
	has "$L:a TOTAL line" "$tmp/o.z" '^TOTAL [0-9]+\.[0-9]{2}$'
	has "$L:the file's output is printed whole" "$tmp/o.z" '^PASS: nothing left behind$'
}
# drv_wrap <id> <signal>: the runner (and a sentinel) led by a wrapper; the signal goes partway.
drv_wrap() {
	id=$1 sig=$2
	case $sig in TERM) L="D11-AC-2:the runner sent TERM partway" ;; *) L="D11-AC-2:the runner killed with KILL together with its process group" ;; esac
	sh_wrap "$id" "$f/$id.test.sh"
	wait_file 20 "$rd/$id.ready" || { fail "$L:the fake file started"; return; }
	setup_ok "$L" "$id"
	wait_file 5 "$rd/$id.sentinel"
	rp=$(readpid "$id.runner") wp=$(readpid "$id.wrapper") sn=$(readpid "$id.sentinel")
	if isnum "$rp" && isnum "$wp" && isnum "$sn" && [ "$(pgrp_of "$rp")" = "$wp" ] && [ "$(pgrp_of "$sn")" = "$wp" ]; then
		pass "$L:the runner and the sentinel are in the process group the wrapper leads"
	else
		fail "$L:the runner and the sentinel are in the process group the wrapper leads"
		return
	fi
	if [ "$sig" = TERM ]; then kill -TERM "$rp"; else kill -s KILL -- "-$wp"; fi
	if [ "$sig" = TERM ]; then ex=$sn; else ex=0; fi
	if wait_until 10 clear_ex "$id" "$ex"; then
		pass "$L:within 10 s nothing its test files started, and no process of the runner, remains"
	else
		fail "$L:within 10 s nothing its test files started, and no process of the runner, remains (left:$(shown "$id" "$ex"))"
	fi
	alive "$rp" && fail "$L:the runner's own process is gone" || pass "$L:the runner's own process is gone"
	if [ "$sig" = TERM ]; then
		alive "$sn" && pass "$L:the sentinel in the runner's group, started by no test file, is still running" || fail "$L:the sentinel in the runner's group, started by no test file, is still running"
	else
		alive "$sn" && fail "$L:the group kill took the sentinel too (the wrapper's group is gone)" || pass "$L:the group kill took the sentinel too (the wrapper's group is gone)"
	fi
}
drv_t() { drv_wrap t TERM; }
drv_k() { drv_wrap k KILL; }
# drv_alone <id> <signal>: a file using the helper, run alone and killed.
drv_alone() {
	id=$1 sig=$2 L="D11-AC-3:a helper file run alone and killed with $2"
	sh_file "$id"
	sp=$!
	if ! wait_file 20 "$rd/$id.ready"; then fail "$L:the file started"; kill -KILL "$sp" 2>/dev/null; return; fi
	fx=$(readpid "$id.pid") ch=$(readpid "$id.child") b=$(readpid "$id.bang")
	if isnum "$fx" && isnum "$ch" && alive "$fx" && alive "$ch"; then
		pass "$L:the fixture and its setsid child are running before the kill"
	else
		fail "$L:the fixture and its setsid child are running before the kill"
		kill -KILL "$sp" 2>/dev/null
		wait "$sp" 2>/dev/null
		return
	fi
	[ "$b" = "$fx" ] && pass "$L:\$! is the fixture's own pid" || fail "$L:\$! is the fixture's own pid (\$!=$b, fixture $fx)"
	wait_until 5 sid_is_pid "$fx" && pass "$L:the fixture runs in a session and group of its own" || fail "$L:the fixture runs in a session and group of its own"
	wait_until 5 sid_is_pid "$ch" && pass "$L:the fixture's setsid child runs in a session of its own" || fail "$L:the fixture's setsid child runs in a session of its own"
	kill -"$sig" "$sp"
	wait "$sp" 2>/dev/null
	wait_until 10 gone2 "$fx" "$ch"
	alive "$fx" && fail "$L:the fixture is gone within 10 s" || pass "$L:the fixture is gone within 10 s"
	alive "$ch" && fail "$L:the process the fixture started with setsid is gone within 10 s" || pass "$L:the process the fixture started with setsid is gone within 10 s"
}
drv_ha() { drv_alone ha TERM; }
drv_hb() { drv_alone hb KILL; }
drv_hc() {
	L="D11-AC-3:a start through the helper"
	sh_file hc
	sp=$!
	if ! wait_file 30 "$rd/hc.done"; then fail "$L:the file ran to its end (the start, the kill and wait, the command substitution)"; kill -KILL "$sp" 2>/dev/null; return; fi
	res=$rd/hc.res
	b=$(sed -n 's/^bang=\([0-9]*\) .*/\1/p' "$res") fp=$(sed -n 's/^.* fixture=\([0-9]*\) .*/\1/p' "$res")
	[ -n "$b" ] && [ "$b" = "$fp" ] && pass "$L:\$! is the fixture's own pid" || fail "$L:\$! is the fixture's own pid ($(head -1 "$res" 2>/dev/null))"
	has "$L:\$! is a child of the test shell" "$res" "^bang=$b fixture=[0-9]* shell=$sp ppid=$sp "
	has "$L:the fixture is its own session and group leader" "$res" "^bang=$b .* pgrp=$b sid=$b\$"
	has "$L:the shell can kill the fixture and wait for it" "$res" '^waited=143$'
	has "$L:a command substitution around the start returns" "$res" '^subst=ok ms=[0-9]+$'
	ms=$(sed -n 's/^subst=ok ms=\([0-9]*\)$/\1/p' "$res")
	[ -n "$ms" ] && [ "$ms" -lt 3000 ] && pass "$L:the command substitution returns within a few seconds ($ms ms)" || fail "$L:the command substitution returns within a few seconds (${ms:-no result})"
}
drv_hd() {
	L="D11-AC-3:the hard lifetime"
	sh_file hd
	sp=$!
	if ! wait_file 20 "$rd/hd.ready"; then fail "$L:the file started"; kill -KILL "$sp" 2>/dev/null; return; fi
	fx=$(readpid hd.pid) ch=$(readpid hd.child)
	isnum "$fx" && isnum "$ch" || { fail "$L:the fixture started"; kill -KILL "$sp" 2>/dev/null; return; }
	wait_until 10 gone2 "$fx" "$ch"
	alive "$fx" && fail "$L:a fixture with NB_FIXTURE_LIFETIME=2 is gone within 10 s, its test shell still running" || pass "$L:a fixture with NB_FIXTURE_LIFETIME=2 is gone within 10 s, its test shell still running"
	alive "$ch" && fail "$L:its setsid child is gone too" || pass "$L:its setsid child is gone too"
	alive "$sp" && pass "$L:the test shell was still running" || fail "$L:the test shell was still running"
	kill -KILL "$sp" 2>/dev/null
	wait "$sp" 2>/dev/null
}

# --- D11-AC-1 for a run of several files: the per-file stop, not the end-of-run sweep ---------------------------
# A leaking file m and a companion file mw that holds the run open (until the driver touches a flag, at most 25 s):
# what m left must be gone while the runner still runs, so the clear comes from the stop when m ended.
# m is a leaking file like the others, but its folder is made in $rd, apart from the runner's own scratch folder
# (which TMPDIR puts under $tmp/m/ and which the runner's processes name while it runs).
{ sed '1s|mktemp -d|mktemp -d "$RD/mleak.XXXXXX"|' "$tmp/body.sh"; printf '%s\n' 'touch "$RD/$n.ready"' 'exit 0'; } >"$f/m.test.sh"
cat >"$f/mw.test.sh" <<'EOT2'
. "$COMMON"
touch "$RD/mw.ready"
wait_file 25 "$RD/m.release"
echo "PASS: companion released"
EOT2
clear_m() { [ -z "$(named m)" ]; }
drv_m() {
	L="D11-AC-1:a run of several files, one leaving processes behind while another still runs"
	sh_run m "TEST_JOBS=2" "$f/m.test.sh" "$f/mw.test.sh"
	printf '%s\n' "$rd/mleak." >"$tmp/pat.m"
	if ! wait_file 20 "$rd/m.ready" || ! wait_file 20 "$rd/mw.ready"; then
		fail "$L:both fake files started"
		touch "$rd/m.release"
		return
	fi
	setup_ok "$L" m
	if wait_until 10 clear_m; then
		pass "$L:within 10 s of the leaking file ending no process names its folder or carries its mark"
	else
		fail "$L:within 10 s of the leaking file ending no process names its folder or carries its mark, while the runner still runs (left:$(named m | tr '\n' ' '))"
	fi
	if [ ! -e "$tmp/o.m.rc" ]; then
		pass "$L:the runner was still running when the folder was clear (the per-file stop did it, not the end-of-run sweep)"
	else
		fail "$L:the runner was still running when the folder was clear (the runner had ended)"
	fi
	touch "$rd/m.release"
	wait_file 30 "$tmp/o.m.rc" || { fail "$L:the runner ended once the companion was released"; return; }
	[ "$(cat "$tmp/o.m.rc")" = 0 ] && pass "$L:the runner exits 0" || fail "$L:the runner exits 0 (got $(cat "$tmp/o.m.rc"))"
	has "$L:a TIME line for the leaking file" "$tmp/o.m" '^TIME [0-9]+\.[0-9]{2} .*/m\.test\.sh$'
	has "$L:a TIME line for the companion" "$tmp/o.m" '^TIME [0-9]+\.[0-9]{2} .*/mw\.test\.sh$'
	has "$L:a TOTAL line" "$tmp/o.m" '^TOTAL [0-9]+\.[0-9]{2}$'
	wait_until 10 clear_ex m && pass "$L:nothing is left after the run" || fail "$L:nothing is left after the run (left:$(shown m))"
}

# --- run ---------------------------------------------------------------------------------------------------------
ids="a b c z t k ha hb hc hd"
ids="$ids m"
pids=""
for id in $ids; do
	( "drv_$id" ) >"$tmp/res.$id" 2>&1 &
	pids="$pids $!"
done
# shellcheck disable=SC2086
wait $pids
if [ -f "$helper" ] && ( . "$helper" && command -v fixture_start >/dev/null ) 2>/dev/null; then
	pass "D11-AC-3:the shared start helper defines fixture_start"
else
	fail "D11-AC-3:the shared start helper $helper defines fixture_start"
fi
for id in $ids; do
	cat "$tmp/res.$id"
	fails=$((fails + $(grep -c '^FAIL' "$tmp/res.$id")))
done
[ "$fails" -eq 0 ]
