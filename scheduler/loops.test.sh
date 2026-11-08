#!/bin/sh
# Test of scheduler/loops.sh (start | stop | status over the repositories in
# ~/.config/noodlebot/repos) with a fake tmux and a fake loop.sh on a temporary PATH.
# Each scenario gets its own noodlebot root and HOME under a temporary directory.
#   sh scheduler/loops.test.sh   (make test)
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

# setup <scenario> [list]: a noodlebot root with the copied loops.sh (if any), a fake loop.sh
# and a fake run-session.sh, HOME with the list (two repositories unless "nolist").
setup() {
	sc=$tmp/$1
	nb=$sc/nb
	HOME=$sc/home TMUXLOG=$sc/tmux.log
	export HOME TMUXLOG
	mkdir -p "$HOME/.config/noodlebot" "$nb/scheduler"
	[ -e "$src/loops.sh" ] && cp "$src/loops.sh" "$nb/scheduler/"
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

[ "$fails" = 0 ] || { echo "$fails failed"; exit 1; }
echo "all passed"
