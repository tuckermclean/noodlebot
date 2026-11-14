#!/bin/sh
# Test of scheduler/loops.sh (start | stop | status over the repositories in
# ~/.config/noodlebot/repos) with a fake tmux and a fake loop.sh on a temporary PATH.
# Each scenario gets its own noodlebot root and HOME under a temporary directory.
#   Run through loops.test.sh, loops-root.test.sh, loops-status.test.sh and loops-api.test.sh (make test); sourced by them, not run on its own.
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d)
trap 'for d in "$tmp"/*/home; do touch "$d/STOP" 2>/dev/null; done; pkill -f "$tmp/" 2>/dev/null; sleep 0.3; pkill -9 -f "$tmp/" 2>/dev/null; rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
# ok <name> <command...>: PASS when the command succeeds.
ok() { name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
# no <name> <command...>: PASS when the command fails.
no() { name=$1; shift; if "$@"; then fail "$name"; else pass "$name"; fi; }

mkdir -p "$tmp/bin"
# tmux: logs its arguments; `new -d -s <sess> <cmd...>` runs the command detached.
cat >"$tmp/bin/tmux" <<'EOT'
#!/bin/sh
echo "$*" >>"$TMUXLOG"
case $1 in
new | new-session)
	shift
	while [ $# -gt 0 ]; do case $1 in -d) shift ;; -s) shift 2 ;; *) break ;; esac; done
	setsid sh -c "$*" >/dev/null 2>&1 </dev/null &
	exit 0 ;;
esac
exit 1
EOT
chmod +x "$tmp/bin/tmux"
PATH=$tmp/bin:$PATH
oldpath=$PATH
# want <part>...: this run includes a part (the test files set $parts; each runs some of the cases).
want() { for w; do case " $parts " in *" $w "*) return 0 ;; esac; done; return 1; }

# setup <scenario> [list]: a noodlebot root with the copied loops.sh (if any), a fake loop.sh
# and a fake run-session.sh, HOME with the list (two repositories unless "nolist").
setup() {
	sc=$tmp/$1
	nb=$sc/nb
	HOME=$sc/home TMUXLOG=$sc/tmux.log
	export HOME TMUXLOG
	# the older scenarios keep state under the noodlebot root: point the runtime root there
	NOODLEBOT_DATA=$nb; export NOODLEBOT_DATA
	mkdir -p "$HOME/.config/noodlebot" "$nb/scheduler"
	[ -e "$src/loops.sh" ] && cp "$src/loops.sh" "$nb/scheduler/"
	[ -f "$src/harness.py" ] && { mkdir -p "$nb/scheduler/harnesses"; cp "$src/harness.py" "$nb/scheduler/"; cp "$src"/harnesses/*.py "$nb/scheduler/harnesses/"; }
	[ -f "$src/forge.py" ] && { mkdir -p "$nb/scheduler/forges"; cp "$src/forge.py" "$nb/scheduler/"; cp "$src"/forges/*.py "$nb/scheduler/forges/"; }
	[ "${2:-}" = nolist ] || printf 'o/alpha\no/beta\n' >"$HOME/.config/noodlebot/repos"
	cat >"$nb/scheduler/loop.sh" <<'EOT'
#!/bin/sh
name=${1#*/}
nb=$(cd "$(dirname "$0")/.." && pwd -P)
mkdir -p "$nb/state/$name"
exec 9>"$nb/state/$name/loop.lock"
flock -n 9 || exit 1
echo $$ >"$nb/state/$name/loop.pid"
while [ ! -e "$HOME/STOP" ] && [ ! -e "$HOME/STOP-$name" ]; do sleep 0.2; done
EOT
	cat >"$nb/scheduler/run-session.sh" <<'EOT'
#!/bin/sh
while :; do sleep 0.2; done
EOT
	chmod +x "$nb/scheduler/loop.sh" "$nb/scheduler/run-session.sh"
}
# running <name>: the loop's lock is held.
running() { ! flock -n "$nb/state/$1/loop.lock" true 2>/dev/null; }
# start_loop <name>: a loop as the owner would have started it; waits for its lock.
start_loop() {
	setsid "$nb/scheduler/loop.sh" "o/$1" >/dev/null 2>&1 </dev/null &
	i=0; while ! running "$1" && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
}
# start_session <name> <ID>: a live session recorded in session.pid.
start_session() {
	mkdir -p "$nb/state/$1/node/$2"
	setsid sh "$nb/scheduler/run-session.sh" "o/$1" "$2" >/dev/null 2>&1 </dev/null &
	echo $! >"$nb/state/$1/node/$2/session.pid"
	sleep 0.3
}
# run <args>: loops.sh with a timeout; output in $sc/out, status in $sc/rc.
run() { timeout 30 sh "$nb/scheduler/loops.sh" "$@" >"$sc/out" 2>&1 </dev/null; echo $? >"$sc/rc"; }
alive() { kill -0 "$1" 2>/dev/null; }
loop_pid() { cat "$nb/state/$1/loop.pid" 2>/dev/null || echo 0; }
sessions_started() { grep -c "sched-$1" "$TMUXLOG" 2>/dev/null; true; }

if want A; then
echo "# M01-AC-1: start"
setup ac1
start_loop alpha
apid=$(loop_pid alpha)
run start
ok M01-AC-1:beta-loop-started-in-sched-beta sh -c "grep -q 'sched-beta' '$TMUXLOG'"
ok M01-AC-1:beta-lock-held-after-start sh -c "sleep 0.5; [ -e '$nb/state/beta/loop.lock' ] && ! flock -n '$nb/state/beta/loop.lock' true"
ok M01-AC-1:no-tmux-call-for-sched-alpha sh -c "[ -e '$TMUXLOG' ] && ! grep -q sched-alpha '$TMUXLOG'"
ok M01-AC-1:alpha-original-loop-still-alive sh -c "[ -e '$sc/tmux.log' ] && kill -0 $apid"
ok M01-AC-1:alpha-lock-still-held sh -c "[ -e '$sc/tmux.log' ] && ! flock -n '$nb/state/alpha/loop.lock' true"
ok M01-AC-1:start-exits-0 sh -c "[ \"\$(cat '$sc/rc')\" = 0 ]"

echo "# M01-AC-2: stop"
setup ac2
start_loop alpha
start_loop beta
start_session alpha A01
spid=$(cat "$nb/state/alpha/node/A01/session.pid")
run stop
ok M01-AC-2:alpha-loop-exited-when-stop-returned sh -c "[ -e '$sc/rc' ] && ! kill -0 $(loop_pid alpha) 2>/dev/null && flock -n '$nb/state/alpha/loop.lock' true"
ok M01-AC-2:beta-loop-exited-when-stop-returned sh -c "[ -e '$sc/rc' ] && ! kill -0 $(loop_pid beta) 2>/dev/null && flock -n '$nb/state/beta/loop.lock' true"
ok M01-AC-2:stop-exits-0 sh -c "[ \"\$(cat '$sc/rc')\" = 0 ]"
ok M01-AC-2:STOP-alpha-removed sh -c "[ \"\$(cat '$sc/rc')\" = 0 ] && [ ! -e '$HOME/STOP-alpha' ]"
ok M01-AC-2:STOP-beta-removed sh -c "[ \"\$(cat '$sc/rc')\" = 0 ] && [ ! -e '$HOME/STOP-beta' ]"
ok M01-AC-2:no-global-STOP sh -c "[ \"\$(cat '$sc/rc')\" = 0 ] && [ ! -e '$HOME/STOP' ]"
ok M01-AC-2:session-still-running sh -c "[ \"\$(cat '$sc/rc')\" = 0 ] && kill -0 $spid"
kill "$spid" 2>/dev/null

echo "# M01-AC-3: status"
setup ac3
start_loop alpha
start_session alpha A01
mkdir -p "$nb/state/alpha/node/A03" "$nb/state/beta/node/B02"
echo 77 >"$nb/state/alpha/node/A03/WAITING-PR"
echo "# Which colour?" >"$nb/state/beta/node/B02/QUESTION.md"
run status
lines=$(grep -c . "$sc/out")
aline=$(grep 'alpha' "$sc/out" | head -n 1)
bline=$(grep 'beta' "$sc/out" | head -n 1)
ok M01-AC-3:exactly-one-line-per-repository sh -c "[ '$lines' = 2 ]"
ok M01-AC-3:one-line-names-alpha sh -c "[ \$(grep -c alpha '$sc/out') = 1 ]"
ok M01-AC-3:one-line-names-beta sh -c "[ \$(grep -c beta '$sc/out') = 1 ]"
ok M01-AC-3:alpha-loop-running sh -c "echo '$aline' | grep -qi 'running' && ! echo '$aline' | grep -qi 'not running'"
ok M01-AC-3:beta-loop-not-running sh -c "echo '$bline' | grep -qi 'not running'"
ok M01-AC-3:alpha-shows-running-session-A01 sh -c "echo '$aline' | grep -q 'A01'"
ok M01-AC-3:alpha-shows-what-waits-A03 sh -c "echo '$aline' | grep -q 'A03'"
ok M01-AC-3:beta-shows-what-waits-B02 sh -c "echo '$bline' | grep -q 'B02'"
ok M01-AC-3:beta-does-not-show-alphas-session sh -c "[ -n '$bline' ] && ! echo '$bline' | grep -q 'A01'"
ok M01-AC-3:status-starts-nothing sh -c "[ \"\$(cat '$sc/rc')\" = 0 ] && [ ! -e '$TMUXLOG' ]"

echo "# Risk (not an AC): a missing list means no repositories"
setup nolist nolist
for cmd in start stop status; do
	run $cmd
	ok "Risk:$cmd-exits-0-without-list" sh -c "[ \"\$(cat '$sc/rc')\" = 0 ]"
	ok "Risk:$cmd-says-no-repositories" sh -c "grep -qi 'no repositor' '$sc/out'"
done
ok Risk:no-tmux-call-without-list sh -c "[ \"\$(cat '$sc/rc')\" = 0 ] && [ ! -e '$TMUXLOG' ]"
ok Risk:nothing-stopped-without-list sh -c "[ \"\$(cat '$sc/rc')\" = 0 ] && ! ls '$HOME'/STOP* 2>/dev/null | grep -q ."

echo "# M01-AC-3: status (sessions and waiting fields told apart)"
setup ac3b
start_loop alpha
start_session alpha A01
mkdir -p "$nb/state/alpha/node/A03" "$nb/state/alpha/node/A04" "$nb/state/beta/node/B02" "$nb/state/beta/node/B05" "$nb/state/beta/node/B06"
sh -c : &
stalepid=$!
wait "$stalepid"
echo "$stalepid" >"$nb/state/alpha/node/A04/session.pid"
echo 77 >"$nb/state/alpha/node/A03/WAITING-PR"
echo "# Which colour?" >"$nb/state/beta/node/B02/QUESTION.md"
echo boom >"$nb/state/beta/node/B05/FAILED"
run status
aline=$(grep 'alpha' "$sc/out" | head -n 1)
bline=$(grep 'beta' "$sc/out" | head -n 1)
asess=$(echo "$aline" | sed 's/.*sessions: *//; s/;.*//')
await=$(echo "$aline" | sed 's/.*waiting[^:]*: *//')
bsess=$(echo "$bline" | sed 's/.*sessions: *//; s/;.*//')
bwait=$(echo "$bline" | sed 's/.*waiting[^:]*: *//')
ok M01-AC-3:A01-in-sessions-field sh -c "echo '$asess' | grep -q 'A01'"
ok M01-AC-3:A01-not-in-waiting-field sh -c "[ -n '$await' ] && ! echo '$await' | grep -q 'A01'"
no M01-AC-3:stale-pid-A04-appears-nowhere grep -q A04 "$sc/out"
no M01-AC-3:no-marker-B06-appears-nowhere grep -q B06 "$sc/out"
ok M01-AC-3:A03-waiting-with-WAITING-PR sh -c "echo '$await' | grep -q 'A03 WAITING-PR'"
ok M01-AC-3:B02-waiting-with-QUESTION sh -c "echo '$bwait' | grep -q 'B02 QUESTION'"
ok M01-AC-3:B05-waiting-with-FAILED sh -c "echo '$bwait' | grep -q 'B05 FAILED'"
ok M01-AC-3:beta-sessions-field-none sh -c "[ '$bsess' = none ]"
ok M01-AC-3:A03-not-in-sessions-field sh -c "[ -n '$asess' ] && ! echo '$asess' | grep -q 'A03'"

echo "# M01-AC-1: start with a STOP file present"
setup ac1s
touch "$HOME/STOP"
run start
no M01-AC-1:global-STOP-start-exits-nonzero sh -c "[ \"\$(cat '$sc/rc')\" = 0 ]"
ok M01-AC-1:global-STOP-output-mentions-STOP sh -c "grep -q 'STOP' '$sc/out'"
ok M01-AC-1:global-STOP-no-tmux-call sh -c "[ \"\$(cat '$sc/rc')\" != '' ] && [ ! -e '$TMUXLOG' ]"
ok M01-AC-1:global-STOP-owners-file-kept sh -c "[ -e '$HOME/STOP' ]"
setup ac1t
touch "$HOME/STOP-beta"
run start
ok M01-AC-1:stale-STOP-beta-removed sh -c "[ ! -e '$HOME/STOP-beta' ]"
ok M01-AC-1:stale-STOP-alpha-loop-lock-held sh -c "sleep 0.7; [ -e '$nb/state/alpha/loop.lock' ] && ! flock -n '$nb/state/alpha/loop.lock' true"
ok M01-AC-1:stale-STOP-beta-loop-lock-held sh -c "[ -e '$nb/state/beta/loop.lock' ] && ! flock -n '$nb/state/beta/loop.lock' true"
ok M01-AC-1:stale-STOP-start-exits-0 sh -c "[ \"\$(cat '$sc/rc')\" = 0 ]"

echo "# Purpose: the list"
setup nonl
printf 'o/alpha\no/beta' >"$HOME/.config/noodlebot/repos"
run start
ok Purpose:no-trailing-newline-alpha-started sh -c "grep -q 'sched-alpha' '$TMUXLOG'"
ok Purpose:no-trailing-newline-beta-started sh -c "grep -q 'sched-beta' '$TMUXLOG'"
ok Purpose:no-trailing-newline-both-locks-held sh -c "sleep 0.7; [ -e '$nb/state/alpha/loop.lock' ] && [ -e '$nb/state/beta/loop.lock' ] && ! flock -n '$nb/state/alpha/loop.lock' true && ! flock -n '$nb/state/beta/loop.lock' true"
setup cmt
printf '# a comment\no/alpha\n\no/beta\n' >"$HOME/.config/noodlebot/repos"
run status
ok Purpose:comment-and-blank-lines-ignored-two-lines sh -c "[ \$(grep -c . '$sc/out') = 2 ] && [ \$(wc -l <'$sc/out') = 2 ]"

fi
if want B; then
echo "# runtime root: state lives under \${NOODLEBOT_DATA:-\$HOME/.local/share/noodlebot}/state (D02), not in the checkout"
export LOOPS_START_WAIT=3 LOOPS_STOP_WAIT=15
fi
# rt_lock <name>: the loop's lock under the runtime root $rt is held.
rt_lock() { [ -e "$rt/state/$1/loop.lock" ] && ! flock -n "$rt/state/$1/loop.lock" true 2>/dev/null; }
# rt_wait <name>: waits (at most 6 s) for that lock.
rt_wait() { i=0; while ! rt_lock "$1" && [ $i -lt 60 ]; do sleep 0.1; i=$((i + 1)); done; rt_lock "$1"; }
# rt_setup <scenario> <data dir | unset>: setup, a runtime root, and a fake loop.sh that keeps its
# lock and state under ${NOODLEBOT_DATA:-$HOME/.local/share/noodlebot}/state/<name>.
rt_setup() {
	setup "$1"
	if [ "$2" = unset ]; then unset NOODLEBOT_DATA; rt=$HOME/.local/share/noodlebot
	else NOODLEBOT_DATA=$2; export NOODLEBOT_DATA; rt=$2; fi
	cat >"$nb/scheduler/loop.sh" <<'EOT'
#!/bin/sh
name=${1#*/}
st=${NOODLEBOT_DATA:-$HOME/.local/share/noodlebot}/state/$name
mkdir -p "$st"
exec 9>"$st/loop.lock"
flock -n 9 || exit 1
echo $$ >"$st/loop.pid"
while [ ! -e "$HOME/STOP" ] && [ ! -e "$HOME/STOP-$name" ]; do sleep 0.2; done
EOT
	chmod +x "$nb/scheduler/loop.sh"
}
# rt_cases <label>: start, status and stop against the runtime root $rt.
rt_cases() {
	l=$1
	setsid "$nb/scheduler/loop.sh" "o/alpha" >/dev/null 2>&1 </dev/null &
	rt_wait alpha
	run start
	ok "M01-AC-1:$l:beta-lock-held-under-runtime-root" sh -c "sleep 0.3; [ -e '$rt/state/beta/loop.lock' ] && ! flock -n '$rt/state/beta/loop.lock' true"
	ok "M01-AC-1:$l:beta-started-in-sched-beta" sh -c "grep -q 'sched-beta' '$TMUXLOG'"
	ok "M01-AC-1:$l:running-alpha-left-alone" sh -c "[ -e '$TMUXLOG' ] && ! grep -q sched-alpha '$TMUXLOG'"
	ok "M01-AC-1:$l:alpha-lock-still-held" sh -c "! flock -n '$rt/state/alpha/loop.lock' true"
	ok "M01-AC-1:$l:start-exits-0" sh -c "[ \"\$(cat '$sc/rc')\" = 0 ]"
	mkdir -p "$rt/state/alpha/node/A01" "$rt/state/beta/node/B02"
	setsid sh "$nb/scheduler/run-session.sh" o/alpha A01 >/dev/null 2>&1 </dev/null &
	echo $! >"$rt/state/alpha/node/A01/session.pid"
	sp=$!
	echo "# Which colour?" >"$rt/state/beta/node/B02/QUESTION.md"
	sleep 0.3
	run status
	aline=$(grep 'alpha' "$sc/out" | head -n 1)
	bline=$(grep 'beta' "$sc/out" | head -n 1)
	ok "M01-AC-3:$l:alpha-loop-running" sh -c "echo '$aline' | grep -qi 'loop running'"
	ok "M01-AC-3:$l:beta-loop-running" sh -c "echo '$bline' | grep -qi 'loop running'"
	ok "M01-AC-3:$l:alpha-session-A01-read-from-runtime-root" sh -c "echo '$aline' | grep -q 'sessions: A01'"
	ok "M01-AC-3:$l:beta-waiting-B02-read-from-runtime-root" sh -c "echo '$bline' | grep -q 'B02 QUESTION'"
	run stop
	ok "M01-AC-2:$l:alpha-loop-stopped" sh -c "[ -e '$sc/rc' ] && flock -n '$rt/state/alpha/loop.lock' true"
	ok "M01-AC-2:$l:beta-loop-stopped" sh -c "[ -e '$sc/rc' ] && flock -n '$rt/state/beta/loop.lock' true"
	ok "M01-AC-2:$l:stop-exits-0" sh -c "[ \"\$(cat '$sc/rc')\" = 0 ]"
	ok "M01-AC-2:$l:STOP-files-removed" sh -c "[ ! -e '$HOME/STOP-alpha' ] && [ ! -e '$HOME/STOP-beta' ]"
	run status
	aline=$(grep 'alpha' "$sc/out" | head -n 1)
	ok "M01-AC-3:$l:alpha-loop-not-running-after-stop" sh -c "echo '$aline' | grep -qi 'loop not running'"
	kill "$sp" 2>/dev/null
}

if want B; then
rt_setup rta unset
rt_cases unset
ok M01-AC-1:unset:no-state-folder-in-checkout sh -c "[ ! -e '$nb/state' ]"

rt_setup rtb "$tmp/rtb/data"
rt_cases separate-data
ok M01-AC-1:separate-data:no-state-folder-in-checkout sh -c "[ ! -e '$nb/state' ]"

echo "# runtime root: the tmux server's environment lacks NOODLEBOT_DATA"
oldpath=$PATH
rt_setup rtc "$tmp/rtc/data"
mkdir -p "$sc/bin"
printf '#!/bin/sh\nexec env -u NOODLEBOT_DATA "%s/bin/tmux" "$@"\n' "$tmp" >"$sc/bin/tmux"
chmod +x "$sc/bin/tmux"
PATH=$sc/bin:$oldpath
run start
ok M01-AC-1:tmux-env:started-through-wrapper-tmux sh -c "grep -q 'sched-beta' '$TMUXLOG'"
ok M01-AC-1:tmux-env:beta-lock-under-NOODLEBOT_DATA sh -c "sleep 0.3; [ -e '$NOODLEBOT_DATA/state/beta/loop.lock' ] && ! flock -n '$NOODLEBOT_DATA/state/beta/loop.lock' true"
ok M01-AC-1:tmux-env:alpha-lock-under-NOODLEBOT_DATA sh -c "[ -e '$NOODLEBOT_DATA/state/alpha/loop.lock' ] && ! flock -n '$NOODLEBOT_DATA/state/alpha/loop.lock' true"
no M01-AC-1:tmux-env:nothing-under-default-root test -e "$HOME/.local/share/noodlebot/state"
ok M01-AC-1:tmux-env:start-exits-0 sh -c "[ \"\$(cat '$sc/rc')\" = 0 ]"
touch "$HOME/STOP"
PATH=$oldpath
unset LOOPS_START_WAIT LOOPS_STOP_WAIT NOODLEBOT_DATA

fi
if want B2 C; then
echo "# M01 run 3: a probe must not take a loop's lock; issue/ sessions; list hygiene; old lock; dead pids"
export LOOPS_START_WAIT=2 LOOPS_STOP_WAIT=15
REALFLOCK=$(command -v flock); export REALFLOCK
fi
# nl_setup <scenario> [list]: setup, plus a fake loop.sh that follows ${NOODLEBOT_DATA:-$HOME/.local/share/noodlebot},
# waits $LOOP_DELAY s between opening and locking its lock file (a slow start), and records
# state/<name>/exits when it finds the lock taken; and a wbin/flock that, when given a loop.lock path
# (not the fd form loop.sh uses), takes that lock and holds it 1 s before doing the real work.
nl_setup() {
	setup "$1" ${2:+"$2"}
	cat >"$nb/scheduler/loop.sh" <<'EOT'
#!/bin/sh
name=${1#*/}
st=${NOODLEBOT_DATA:-$HOME/.local/share/noodlebot}/state/$name
mkdir -p "$st"
exec 9>"$st/loop.lock"
sleep "${LOOP_DELAY:-0}"
flock -n 9 || { echo "another loop is already running" >>"$st/exits"; exit 1; }
echo $$ >"$st/loop.pid"
while [ ! -e "$HOME/STOP" ] && [ ! -e "$HOME/STOP-$name" ]; do sleep 0.2; done
EOT
	chmod +x "$nb/scheduler/loop.sh"
	mkdir -p "$sc/wbin"
	cat >"$sc/wbin/flock" <<'EOT'
#!/bin/sh
for a in "$@"; do case $a in */loop.lock) "$REALFLOCK" -n "$a" sleep 1 ;; esac; done
exec "$REALFLOCK" "$@"
EOT
	chmod +x "$sc/wbin/flock"
}
# run_w <args>: run with the widening flock first on PATH, for this invocation only.
run_w() { nl_path=$PATH; PATH=$sc/wbin:$PATH; run "$@"; PATH=$nl_path; }
# nl_pidwait <name>: waits (at most 4 s) for the loop to have taken its lock (it then writes loop.pid).
nl_pidwait() { i=0; while [ ! -s "$nb/state/$1/loop.pid" ] && [ $i -lt 40 ]; do sleep 0.1; i=$((i + 1)); done; [ -s "$nb/state/$1/loop.pid" ]; }
# nl_halt: stops alpha and beta loops through STOP-<name> files and waits for both locks to be free.
nl_halt() {
	touch "$HOME/STOP-alpha" "$HOME/STOP-beta"
	i=0
	while [ $i -lt 50 ]; do
		flock -n "$nb/state/alpha/loop.lock" true && flock -n "$nb/state/beta/loop.lock" true && break
		sleep 0.1; i=$((i + 1))
	done
	rm -f "$HOME/STOP-alpha" "$HOME/STOP-beta"
}
# nl_held <lockfile>: the lock is held (probes by taking it, so only after the loops are up).
nl_held() { [ -e "$1" ] && ! flock -n "$1" true 2>/dev/null; }
# nl_wait_free <lockfile>: waits (at most 5 s) until nobody holds the lock.
nl_wait_free() { i=0; while nl_held "$1" && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done; }

if want B2; then
nl_setup race
LOOP_DELAY=0.6; export LOOP_DELAY
r_rc=0 r_up=0
for it in 1 2; do
	rm -f "$nb/state/alpha/loop.pid" "$nb/state/beta/loop.pid"
	run_w start
	[ "$(cat "$sc/rc")" = 0 ] || r_rc=1
	for n in alpha beta; do
		nl_pidwait "$n" && kill -0 "$(cat "$nb/state/$n/loop.pid")" 2>/dev/null && nl_held "$nb/state/$n/loop.lock" || r_up=1
	done
	nl_halt
done
ok M01-AC-1:probe-race:start-exits-0-every-time test "$r_rc" = 0
ok M01-AC-1:probe-race:every-loop-holds-its-lock-after-start test "$r_up" = 0
no M01-AC-1:probe-race:no-loop-exited-already-running sh -c "cat '$nb'/state/*/exits 2>/dev/null | grep -q ."

nl_setup racest
LOOP_DELAY=0.8; export LOOP_DELAY
setsid "$nb/scheduler/loop.sh" o/alpha >/dev/null 2>&1 </dev/null &
sleep 0.3
run_w status
ok M01-AC-3:probe-race:loop-starting-during-status-takes-its-lock nl_pidwait alpha
no M01-AC-3:probe-race:status-did-not-make-the-loop-exit test -e "$nb/state/alpha/exits"
touch "$HOME/STOP"

nl_setup racesp
LOOP_DELAY=0.8; export LOOP_DELAY
setsid "$nb/scheduler/loop.sh" o/alpha >/dev/null 2>&1 </dev/null &
sleep 0.3
run_w stop
ok M01-AC-2:probe-race:loop-starting-during-stop-takes-its-lock nl_pidwait alpha
no M01-AC-2:probe-race:stop-did-not-make-the-loop-exit test -e "$nb/state/alpha/exits"
touch "$HOME/STOP"
unset LOOP_DELAY

fi
if want C; then
echo "# M01-AC-3: status with issue/ sessions and the answered state"
nl_setup iss
st=$nb/state/alpha
mkdir -p "$st/issue/46" "$st/issue/47" "$st/issue/49" "$st/node/C07" "$st/node/C08"
setsid "$nb/scheduler/run-session.sh" "$sc/wt" "$st/issue/46" "/noodlebot:triage 46" </dev/null >/dev/null 2>&1 &
echo $! >"$st/issue/46/session.pid"
echo "# Which?" >"$st/issue/47/QUESTION.md"
echo "# Which?" >"$st/issue/49/QUESTION.md"; echo "blue" >"$st/issue/49/ANSWER.md"
echo "# Which?" >"$st/node/C07/QUESTION.md"; echo "blue" >"$st/node/C07/ANSWER.md"
sleep 0.3
run status
aline=$(grep 'alpha' "$sc/out" | head -n 1)
asess=$(echo "$aline" | sed 's/.*sessions: *//; s/;.*//')
await=$(echo "$aline" | sed 's/.*waiting[^:]*: *//')
ok M01-AC-3:issue-session-shown-as-#46-in-sessions sh -c "echo '$asess' | grep -q '#46'"
ok M01-AC-3:issue-session-not-in-waiting sh -c "[ -n '$await' ] && ! echo '$await' | grep -q '#46'"
ok M01-AC-3:issue-QUESTION-waiting-as-#47 sh -c "echo '$await' | grep -q '#47 QUESTION'"
ok M01-AC-3:issue-answered-waiting-as-#49 sh -c "echo '$await' | grep -q '#49 answered'"
ok M01-AC-3:node-answered-waiting-as-C07 sh -c "echo '$await' | grep -q 'C07 answered'"
no M01-AC-3:answered-is-not-also-a-QUESTION sh -c "echo '$await' | grep -q 'C07 QUESTION\|#49 QUESTION'"
no M01-AC-3:node-without-marker-C08-appears-nowhere grep -q C08 "$sc/out"
ok M01-AC-3:issue-session-one-line-per-repository sh -c "[ \$(grep -c . '$sc/out') = 2 ]"
kill "$(cat "$st/issue/46/session.pid")" 2>/dev/null

echo "# M01-AC-3: status prints no noise for a dead session pid"
setup dead
mkdir -p "$nb/state/alpha/node/A04" "$nb/state/alpha/issue/9"
sh -c : &
deadpid=$!
wait "$deadpid"
echo "$deadpid" >"$nb/state/alpha/node/A04/session.pid"
echo "$deadpid" >"$nb/state/alpha/issue/9/session.pid"
run status
ok M01-AC-3:dead-pid:exactly-one-line-per-repository sh -c "[ \$(wc -l <'$sc/out') = 2 ]"
no M01-AC-3:dead-pid:no-such-file-noise grep -qi 'no such file' "$sc/out"
no M01-AC-3:dead-pid:no-line-besides-the-repositories sh -c "grep -v '^o/' '$sc/out' | grep -q ."
ok M01-AC-3:dead-pid:status-exits-0 sh -c "[ \"\$(cat '$sc/rc')\" = 0 ]"

echo "# Purpose: list hygiene"
nl_setup hyg
printf 'alpha\no/beta\no/beta\n' >"$HOME/.config/noodlebot/repos"
LOOP_DELAY=0.5; export LOOP_DELAY
run start
sleep 1
ok Purpose:slashless-line-ignored-with-a-message-naming-it sh -c "grep alpha '$sc/out' | grep -vi 'started' | grep -q ."
no Purpose:slashless-line-starts-no-tmux-session sh -c "grep -q 'sched-alpha' '$TMUXLOG'"
no Purpose:slashless-line-starts-no-loop test -e "$nb/state/alpha/loop.lock"
ok Purpose:duplicate-line-one-tmux-call sh -c "[ \$(grep -c 'sched-beta' '$TMUXLOG') = 1 ]"
ok Purpose:duplicate-line-one-loop-holds-its-lock sh -c "[ -e '$nb/state/beta/loop.lock' ] && ! flock -n '$nb/state/beta/loop.lock' true"
no Purpose:duplicate-line-no-loop-exited-already-running test -e "$nb/state/beta/exits"
ok Purpose:start-exits-0-when-the-rest-started sh -c "[ \"\$(cat '$sc/rc')\" = 0 ]"
run status
ok Purpose:duplicate-line-one-status-line sh -c "[ \$(grep -c beta '$sc/out') = 1 ]"
touch "$HOME/STOP"
unset LOOP_DELAY

echo "# runtime root: NOODLEBOT_DATA unset, the tmux server's value is another"
rt_setup rtd unset
mkdir -p "$sc/bin"
printf '#!/bin/sh\nexec env NOODLEBOT_DATA="%s/other" "%s/bin/tmux" "$@"\n' "$tmp" "$tmp" >"$sc/bin/tmux"
chmod +x "$sc/bin/tmux"
PATH=$sc/bin:$oldpath
run start
ok M01-AC-1:unset-vs-server:started-through-wrapper-tmux sh -c "grep -q 'sched-beta' '$TMUXLOG'"
ok M01-AC-1:unset-vs-server:alpha-lock-under-default-root sh -c "sleep 0.5; [ -e '$HOME/.local/share/noodlebot/state/alpha/loop.lock' ] && ! flock -n '$HOME/.local/share/noodlebot/state/alpha/loop.lock' true"
ok M01-AC-1:unset-vs-server:beta-lock-under-default-root sh -c "[ -e '$HOME/.local/share/noodlebot/state/beta/loop.lock' ] && ! flock -n '$HOME/.local/share/noodlebot/state/beta/loop.lock' true"
no M01-AC-1:unset-vs-server:nothing-under-the-servers-value test -e "$tmp/other/state"
ok M01-AC-1:unset-vs-server:start-exits-0 sh -c "[ \"\$(cat '$sc/rc')\" = 0 ]"
touch "$HOME/STOP"
PATH=$oldpath

echo "# M01-AC-1: a loop from before the D02 move holds the checkout's lock"
rt_setup old "$tmp/old/data"
mkdir -p "$nb/state/alpha"
oldlock=$nb/state/alpha/loop.lock
setsid "$REALFLOCK" "$oldlock" sleep 60 >/dev/null 2>&1 </dev/null &
oldpid=$!
i=0; while ! nl_held "$oldlock" && [ $i -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
run start
no M01-AC-1:old-lock:start-exits-nonzero sh -c "[ \"\$(cat '$sc/rc')\" = 0 ]"
ok M01-AC-1:old-lock:output-names-the-lock sh -c "grep -qF '$oldlock' '$sc/out'"
ok M01-AC-1:old-lock:nothing-started sh -c "[ -e '$sc/rc' ] && [ ! -e '$TMUXLOG' ]"
touch "$HOME/STOP"
pkill -P "$oldpid" 2>/dev/null
pkill -f "$oldlock" 2>/dev/null
nl_wait_free "$oldlock"
nl_wait_free "$rt/state/alpha/loop.lock"; nl_wait_free "$rt/state/beta/loop.lock"
rm -f "$HOME/STOP" "$TMUXLOG"
run start
ok M01-AC-1:old-lock-free:file-left-behind-is-no-obstacle sh -c "[ -e '$oldlock' ]"
ok M01-AC-1:old-lock-free:start-exits-0 sh -c "[ \"\$(cat '$sc/rc')\" = 0 ]"
ok M01-AC-1:old-lock-free:both-started sh -c "grep -q sched-alpha '$TMUXLOG' && grep -q sched-beta '$TMUXLOG'"
ok M01-AC-1:old-lock-free:locks-under-runtime-root sh -c "sleep 0.3; [ -e '$rt/state/alpha/loop.lock' ] && ! flock -n '$rt/state/alpha/loop.lock' true && ! flock -n '$rt/state/beta/loop.lock' true"
touch "$HOME/STOP"
unset LOOPS_START_WAIT LOOPS_STOP_WAIT NOODLEBOT_DATA REALFLOCK

fi
if want D; then
echo "# V01-AC-8: status names the version of a running loop"
setup v01
start_loop alpha
i=0; while [ ! -s "$nb/state/alpha/loop.pid" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
echo v9.8.7-3-g1a2b3c4 >"$nb/state/alpha/version"
mkdir -p "$nb/state/beta"; echo v1.1.1-stale >"$nb/state/beta/version"
run status
aline=$(grep 'alpha' "$sc/out" | head -n 1)
bline=$(grep 'beta' "$sc/out" | head -n 1)
ok V01-AC-8:running-loop-line-names-version sh -c "echo '$aline' | grep -qF 'version v9.8.7-3-g1a2b3c4'"
no V01-AC-8:stopped-loop-line-names-no-version sh -c "echo '$bline' | grep -qF 'version'"
ok V01-AC-8:still-one-line-per-repository sh -c "[ \$(grep -c . '$sc/out') = 2 ]"
touch "$HOME/STOP"

fi
if want E; then
echo "# P01-AC-10: the API server with the loops (only when the checkout has scheduler/api.py)"
export LOOPS_START_WAIT=5 LOOPS_STOP_WAIT=20
fi
# api_setup <scenario> [noapi]: setup, a runtime root of its own, loops that record their exit in the
# sequence log, a fake tmux that remembers each session's process and can kill it, and (unless noapi)
# a fake api.py that takes $NOODLEBOT_DATA/api.lock, logs its start and data root, and records its stop.
api_setup() {
	setup "$1"
	data=$sc/data; NOODLEBOT_DATA=$data; export NOODLEBOT_DATA
	mkdir -p "$data" "$sc/bin"
	seq=$nb/scheduler/seq.log; alog=$nb/scheduler/api.log
	cat >"$nb/scheduler/loop.sh" <<'EOT'
#!/bin/sh
name=${1#*/}
st=$NOODLEBOT_DATA/state/$name
mkdir -p "$st"
exec 9>"$st/loop.lock"
flock -n 9 || exit 1
echo $$ >"$st/loop.pid"
while [ ! -e "$HOME/STOP" ] && [ ! -e "$HOME/STOP-$name" ]; do sleep 0.2; done
sleep 0.5
echo "loop-exit $name" >>"$(dirname "$0")/seq.log"
EOT
	chmod +x "$nb/scheduler/loop.sh"
	cat >"$sc/bin/tmux" <<EOT
#!/bin/sh
echo "\$*" >>"\$TMUXLOG"
case \$1 in
new | new-session)
	shift
	while [ \$# -gt 0 ]; do case \$1 in -d) shift ;; -s) sess=\$2; shift 2 ;; *) break ;; esac; done
	setsid sh -c "\$*" >/dev/null 2>&1 </dev/null &
	echo \$! >"$sc/sess-\$sess.pid"
	exit 0 ;;
kill-session | kill-server)
	while [ \$# -gt 0 ]; do case \$1 in -t) sess=\${2#=}; shift 2 ;; *) shift ;; esac; done
	[ -e "$sc/sess-\$sess.pid" ] && kill -TERM -- "-\$(cat "$sc/sess-\$sess.pid")" 2>/dev/null
	exit 0 ;;
has-session)
	while [ \$# -gt 0 ]; do case \$1 in -t) sess=\${2#=}; shift 2 ;; *) shift ;; esac; done
	[ -e "$sc/sess-\$sess.pid" ] && kill -0 "\$(cat "$sc/sess-\$sess.pid")" 2>/dev/null
	exit \$? ;;
esac
exit 1
EOT
	chmod +x "$sc/bin/tmux"
	PATH=$sc/bin:$oldpath
	[ "${2:-}" = noapi ] && return 0
	cat >"$nb/scheduler/api.py" <<'EOT'
#!/usr/bin/env python3
import fcntl, os, signal, sys, time
here = os.path.dirname(os.path.abspath(__file__))
data = os.environ.get("NOODLEBOT_DATA", "")
def log(f, s):
    with open(os.path.join(here, f), "a") as h:
        h.write(s + "\n")
lk = open(os.path.join(data, "api.lock"), "w")
try:
    fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    log("api.log", "lockfail")
    sys.exit(1)
log("api.log", "start data=" + data)
def stop(*a):
    log("seq.log", "api-stop")
    sys.exit(0)
for s in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
    signal.signal(s, stop)
while True:
    time.sleep(0.1)
EOT
	chmod +x "$nb/scheduler/api.py"
}
api_wait() { i=0; while ! nl_held "$data/api.lock" && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done; }
api_gone() { i=0; while pgrep -f "$nb/scheduler/api.py" >/dev/null && [ $i -lt 20 ]; do sleep 0.1; i=$((i + 1)); done; ! pgrep -f "$nb/scheduler/api.py" >/dev/null; }
api_end() { touch "$HOME/STOP"; pkill -f "$nb/scheduler/api.py" 2>/dev/null; sleep 0.3; rm -f "$HOME/STOP"; PATH=$oldpath; }

if want E; then
oldpath=$PATH
api_setup ac10a
run start
api_wait
ok P01-AC-10:start-exits-0 sh -c "[ \"\$(cat '$sc/rc')\" = 0 ]"
ok P01-AC-10:start-launches-sched-api-in-tmux sh -c "grep -q 'sched-api' '$TMUXLOG'"
ok P01-AC-10:server-holds-api-lock-after-start sh -c "[ -e '$data/api.lock' ] && ! flock -n '$data/api.lock' true"
ok P01-AC-10:server-given-runtime-root-as-NOODLEBOT_DATA sh -c "grep -qx 'start data=$data' '$alog'"
ok P01-AC-10:loops-still-started sh -c "grep -q 'sched-alpha' '$TMUXLOG' && grep -q 'sched-beta' '$TMUXLOG'"
run start
sleep 0.5
ok P01-AC-10:second-start-exits-0 sh -c "[ \"\$(cat '$sc/rc')\" = 0 ]"
ok P01-AC-10:second-start-no-second-sched-api-call sh -c "[ \$(grep -c 'sched-api' '$TMUXLOG') = 1 ]"
ok P01-AC-10:second-start-no-second-server sh -c "[ \$(grep -c '^start' '$alog') = 1 ] && ! grep -q lockfail '$alog'"
echo "# P01-AC-10: status, server running"
run status
ok P01-AC-10:status-running-one-api-line sh -c "[ \$(grep -ci 'api' '$sc/out') = 1 ]"
ok P01-AC-10:status-running-says-running sh -c "l=\$(grep -i 'api' '$sc/out'); echo \"\$l\" | grep -q 'running' && ! echo \"\$l\" | grep -q 'not running'"
ok P01-AC-10:status-running-names-socket sh -c "grep -i 'api' '$sc/out' | grep -qF '$data/api.sock'"
ok P01-AC-10:status-still-a-line-per-repository sh -c "grep -c 'o/alpha' '$sc/out' | grep -qx 1 && grep -c 'o/beta' '$sc/out' | grep -qx 1"
echo "# P01-AC-10: stop"
: >"$seq"
run stop
ok P01-AC-10:stop-exits-0 sh -c "[ \"\$(cat '$sc/rc')\" = 0 ]"
ok P01-AC-10:stop-stops-the-server sh -c "grep -qx api-stop '$seq'"
ok P01-AC-10:stop-server-after-both-loops-exited sh -c "[ \$(grep -c '^loop-exit' '$seq') = 2 ] && [ \"\$(tail -n 1 '$seq')\" = api-stop ] && [ \$(grep -c '^api-stop' '$seq') = 1 ]"
ok P01-AC-10:stop-api-lock-free sh -c "[ -e '$data/api.lock' ] && flock -n '$data/api.lock' true"
ok P01-AC-10:stop-server-process-gone api_gone
echo "# P01-AC-10: status, server not running"
run status
ok P01-AC-10:status-stopped-one-api-line sh -c "[ \$(grep -ci 'api' '$sc/out') = 1 ]"
ok P01-AC-10:status-stopped-says-not-running sh -c "grep -i 'api' '$sc/out' | grep -q 'not running'"
ok P01-AC-10:status-stopped-names-socket sh -c "grep -i 'api' '$sc/out' | grep -qF '$data/api.sock'"
api_end

echo "# P01-AC-10: a server already running is left alone"
api_setup ac10b
setsid python3 "$nb/scheduler/api.py" >/dev/null 2>&1 </dev/null &
api_wait
run start
sleep 0.5
ok P01-AC-10:running-server-start-exits-0 sh -c "[ \"\$(cat '$sc/rc')\" = 0 ]"
ok P01-AC-10:running-server-no-sched-api-tmux-call sh -c "[ -e '$TMUXLOG' ] && ! grep -q 'sched-api' '$TMUXLOG'"
ok P01-AC-10:running-server-not-started-again sh -c "[ \$(grep -c '^start' '$alog') = 1 ] && ! grep -q lockfail '$alog'"
ok P01-AC-10:running-server-still-holds-lock sh -c "! flock -n '$data/api.lock' true"
ok P01-AC-10:running-server-loops-started sh -c "grep -q 'sched-alpha' '$TMUXLOG' && grep -q 'sched-beta' '$TMUXLOG'"
api_end

echo "# P01-AC-10: a checkout without api.py manages no server"
api_setup ac10c noapi
run start
sleep 0.5
ok P01-AC-10:no-api-py-start-exits-0 sh -c "[ \"\$(cat '$sc/rc')\" = 0 ]"
ok P01-AC-10:no-api-py-loops-started sh -c "grep -q 'sched-alpha' '$TMUXLOG' && grep -q 'sched-beta' '$TMUXLOG'"
no P01-AC-10:no-api-py-no-sched-api sh -c "grep -q 'sched-api' '$TMUXLOG'"
run status
ok P01-AC-10:no-api-py-status-two-lines sh -c "[ \$(grep -c . '$sc/out') = 2 ]"
no P01-AC-10:no-api-py-status-no-api-line sh -c "grep -qi 'api' '$sc/out'"
api_end
unset LOOPS_START_WAIT LOOPS_STOP_WAIT NOODLEBOT_DATA

fi
if want F; then
echo "# T03-AC-4: start passes its USAGE_* and SCHED_* variables to each loop, though the tmux server's environment lacks them"
export LOOPS_START_WAIT=3 LOOPS_STOP_WAIT=15
unset USAGE_7D_PACE USAGE_7D_MARGIN USAGE_5H_LIMIT SCHED_TICK SCHED_NOTE SCHED_OTHER USAGE_OTHER
setup t03env
cat >"$nb/scheduler/loop.sh" <<'EOT'
#!/bin/sh
name=${1#*/}
mkdir -p "$HOME/seen"
nb=$(cd "$(dirname "$0")/.." && pwd -P)
mkdir -p "$nb/state/$name"
exec 9>"$nb/state/$name/loop.lock"
flock -n 9 || exit 1
env >"$HOME/seen/$name.env"
printf '%s' "${SCHED_NOTE-unset}" >"$HOME/seen/$name.note"
while [ ! -e "$HOME/STOP" ] && [ ! -e "$HOME/STOP-$name" ]; do sleep 0.2; done
EOT
chmod +x "$nb/scheduler/loop.sh"
mkdir -p "$sc/bin"
# a tmux whose started command runs with a server's older environment (without the settings), arguments kept as given
cat >"$sc/bin/tmux" <<'EOT'
#!/bin/sh
echo "$*" >>"$TMUXLOG"
case $1 in
new | new-session)
	shift
	while [ $# -gt 0 ]; do case $1 in -d) shift ;; -s) shift 2 ;; *) break ;; esac; done
	setsid env -u USAGE_7D_PACE -u USAGE_7D_MARGIN -u USAGE_5H_LIMIT -u USAGE_OTHER -u SCHED_TICK -u SCHED_NOTE -u SCHED_OTHER "$@" >/dev/null 2>&1 </dev/null &
	exit 0 ;;
esac
exit 1
EOT
chmod +x "$sc/bin/tmux"
oldpath=$PATH
PATH=$sc/bin:$oldpath
USAGE_7D_PACE=1 USAGE_7D_MARGIN=0.2 SCHED_TICK=7 SCHED_NOTE="two words  here" run start
sleep 1
for n in alpha beta; do
	ok "T03-AC-4:start-exits-0" sh -c "[ \"\$(cat '$sc/rc')\" = 0 ]"
	ok "T03-AC-4:$n:USAGE_7D_PACE-reaches-the-loop" sh -c "grep -qx 'USAGE_7D_PACE=1' '$HOME/seen/$n.env'"
	ok "T03-AC-4:$n:USAGE_7D_MARGIN-reaches-the-loop" sh -c "grep -qx 'USAGE_7D_MARGIN=0.2' '$HOME/seen/$n.env'"
	ok "T03-AC-4:$n:SCHED_TICK-reaches-the-loop" sh -c "grep -qx 'SCHED_TICK=7' '$HOME/seen/$n.env'"
	ok "T03-AC-4:$n:value-with-a-space-unchanged" sh -c "[ \"\$(cat '$HOME/seen/$n.note')\" = 'two words  here' ]"
	no "T03-AC-4:$n:USAGE_5H_LIMIT-not-set-not-added" sh -c "grep -q '^USAGE_5H_LIMIT=' '$HOME/seen/$n.env'"
	no "T03-AC-4:$n:SCHED_OTHER-not-set-not-added" sh -c "grep -q '^SCHED_OTHER=' '$HOME/seen/$n.env'"
	ok "T03-AC-4:$n:NOODLEBOT_DATA-still-passed" sh -c "grep -q '^NOODLEBOT_DATA=' '$HOME/seen/$n.env'"
done
touch "$HOME/STOP"
sleep 0.5
PATH=$oldpath
unset LOOPS_START_WAIT LOOPS_STOP_WAIT NOODLEBOT_DATA

fi
if want H; then
echo "# S08-AC-5: start passes SCHED_HARNESS to each loop it starts (and passes nothing when it is unset)"
export LOOPS_START_WAIT=3 LOOPS_STOP_WAIT=15
unset SCHED_HARNESS
setup s08env
cat >"$nb/scheduler/loop.sh" <<'EOT'
#!/bin/sh
name=${1#*/}
mkdir -p "$HOME/seen"
nb=$(cd "$(dirname "$0")/.." && pwd -P)
mkdir -p "$nb/state/$name"
exec 9>"$nb/state/$name/loop.lock"
flock -n 9 || exit 1
env >"$HOME/seen/$name.env"
while [ ! -e "$HOME/STOP" ] && [ ! -e "$HOME/STOP-$name" ]; do sleep 0.2; done
EOT
chmod +x "$nb/scheduler/loop.sh"
mkdir -p "$sc/bin"
cat >"$sc/bin/tmux" <<'EOT'
#!/bin/sh
echo "$*" >>"$TMUXLOG"
case $1 in
new | new-session)
	shift
	while [ $# -gt 0 ]; do case $1 in -d) shift ;; -s) shift 2 ;; *) break ;; esac; done
	setsid env -u SCHED_HARNESS "$@" >/dev/null 2>&1 </dev/null &
	exit 0 ;;
esac
exit 1
EOT
chmod +x "$sc/bin/tmux"
oldpath=$PATH
PATH=$sc/bin:$oldpath
SCHED_HARNESS=fake run start
for n in alpha beta; do for _ in $(seq 50); do [ -s "$HOME/seen/$n.env" ] && break; sleep 0.1; done; done
for n in alpha beta; do
	ok "S08-AC-5:$n:SCHED_HARNESS-reaches-the-loop" sh -c "grep -qx 'SCHED_HARNESS=fake' '$HOME/seen/$n.env'"
done
touch "$HOME/STOP"
for n in alpha beta; do for _ in $(seq 50); do alive "$(loop_pid $n)" || break; sleep 0.1; done; done
rm -f "$HOME/STOP" "$HOME/seen"/*
run start
for n in alpha beta; do for _ in $(seq 50); do [ -s "$HOME/seen/$n.env" ] && break; sleep 0.1; done; done
for n in alpha beta; do
	no "S08-AC-5:$n:SCHED_HARNESS-unset-not-passed" sh -c "grep -q '^SCHED_HARNESS=' '$HOME/seen/$n.env'"
done
touch "$HOME/STOP"
sleep 0.5
PATH=$oldpath
unset LOOPS_START_WAIT LOOPS_STOP_WAIT NOODLEBOT_DATA

fi
[ "$fails" = 0 ] || { echo "$fails failed"; exit 1; }
echo "all passed"
