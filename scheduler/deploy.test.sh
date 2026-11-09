#!/bin/sh
# Test of scheduler/deploy.sh against a fake remote of the scheduler's own repository: main moves
# through a passing and a failing commit, each commit's own Makefile `test:` target passes or fails
# and logs its run. The live checkout is a clone. Everything lives under mktemp -d with its own HOME.
#   sh scheduler/deploy.test.sh   (make test)
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
# ok <name> <condition>: PASS when the whole shell condition (a string, evaluated here) succeeds.
# Guards (e.g. "$m2" = 1) belong inside the condition so a missing deploy.sh cannot pass vacuously.
ok() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

export HOME=$tmp/home
export NOODLEBOT_DATA=$tmp/data   # the runtime root, outside the live clone (D01 Q2)
mkdir -p "$HOME"
log=$tmp/make.log
: >"$log"
deploy=$src/deploy.sh
live=$tmp/live

git init -q -b main "$tmp/work"
g() { git -C "$tmp/work" -c user.name=t -c user.email=t@t "$@"; }
# commit <label> <pass|fail|slow>: a new commit on the remote's main whose make test logs "<label>".
commit() {
	case $2 in
	pass) body="@echo $1 >>$log" ;;
	fail) body="@echo $1 >>$log; exit 1" ;;
	slow) body="@echo $1 >>$log; sleep 3" ;;
	esac
	printf 'test:\n\t%s\n' "$body" >"$tmp/work/Makefile"
	echo "$1" >"$tmp/work/file"
	g add -A && g commit -q -m "$1" && g push -q "$tmp/remote.git" HEAD:main 2>/dev/null
}
commit c0 pass
git clone -q --bare "$tmp/work" "$tmp/remote.git"
git clone -q "$tmp/remote.git" "$live"
g remote add origin "$tmp/remote.git" 2>/dev/null
commit c1 pass

full() { git -C "$1" rev-parse "$2"; }
head_of() { full "$live" HEAD; }
short() { printf %.7s "$1"; }
runs() { grep -c "^$1\$" "$log"; }
dep() { sh "$deploy" "$live" 2>&1; }
prev_is() { [ "$(cat "$NOODLEBOT_DATA/deploy/previous" 2>/dev/null | xargs -r -n1 git -C "$live" rev-parse 2>/dev/null)" = "$1" ]; }

c0=$(head_of)
c1=$(full "$tmp/work" HEAD)

# D01-AC-1: a passing new commit is deployed.
out=$(dep)
m1=0; printf '%s\n' "$out" | grep -Eq "^deployed $(short "$c0")[0-9a-f]*\.\.$(short "$c1")[0-9a-f]*\$" && m1=1
ok "D01-AC-1 prints deployed <old>..<new>" '[ "$m1" = 1 ]'
ok "D01-AC-1 live checkout moved to the new commit" '[ "$(head_of)" = "$c1" ]'
ok "D01-AC-1 deploy/previous is the old HEAD" 'prev_is "$c0"'
ok "D01-AC-1 make test ran once for the commit" '[ "$(runs c1)" = 1 ]'
deployed1=$m1
out=$(dep)
ok "D01-AC-1 nothing to do prints nothing" '[ "$deployed1" = 1 ] && [ -z "$out" ]'

# D01-AC-2: a failing commit is not deployed and not tried again.
commit c2 fail
c2=$(full "$tmp/work" HEAD)
out=$(dep)
m2=0; printf '%s\n' "$out" | grep -Eq "^not deployed: $(short "$c2")[0-9a-f]* fails make test\$" && m2=1
ok "D01-AC-2 prints 'not deployed: <sha> fails make test'" '[ "$m2" = 1 ]'
ok "D01-AC-2 the failure is one line" '[ "$m2" = 1 ] && [ "$(printf "%s\n" "$out" | grep -c .)" = 1 ]'
ok "D01-AC-2 live checkout stays on the old commit" '[ "$m2" = 1 ] && [ "$(head_of)" = "$c1" ]'
ok "D01-AC-2 make test ran for the failing commit" '[ "$(runs c2)" = 1 ]'
out=$(dep)
ok "D01-AC-2 second run prints nothing" '[ "$m2" = 1 ] && [ -z "$out" ]'
ok "D01-AC-2 second run does not run make test for that sha again" '[ "$m2" = 1 ] && [ "$(runs c2)" = 1 ]'
ok "D01-AC-2 live checkout still on the old commit after the second run" '[ "$m2" = 1 ] && [ "$(head_of)" = "$c1" ]'
commit c3 pass
c3=$(full "$tmp/work" HEAD)
out=$(dep)
ok "D01-AC-2 a newer passing commit deploys after a rejected one" '[ "$(head_of)" = "$c3" ] && [ "$(runs c3)" = 1 ]'
ok "D01-AC-2 previous is the commit deployed from" 'prev_is "$c1"'

# D01-AC-3: --rollback returns to the recorded previous commit, and it sticks.
out=$(sh "$deploy" --rollback "$live" 2>&1)
ok "D01-AC-3 rollback returns the live checkout to the previous commit" '[ "$(head_of)" = "$c1" ]'
rb=0; [ "$(head_of)" = "$c1" ] && rb=1
out=$(dep)
ok "D01-AC-3 rollback sticks: the next deploy does not move back to the commit just left" '[ "$rb" = 1 ] && [ "$(head_of)" = "$c1" ]'
ok "D01-AC-3 rollback sticks: the next deploy prints nothing" '[ "$rb" = 1 ] && [ -z "$out" ]'
ok "D01-AC-3 rollback sticks: make test is not rerun for the rolled-back commit" '[ "$rb" = 1 ] && [ "$(runs c3)" = 1 ]'
commit c4 pass
c4=$(full "$tmp/work" HEAD)
out=$(dep)
ok "D01-AC-3 a newer commit deploys after a rollback" '[ "$rb" = 1 ] && [ "$(head_of)" = "$c4" ]'

# D01-AC-4: two concurrent runs deploy at most once.
commit c5 slow
c5=$(full "$tmp/work" HEAD)
sh "$deploy" "$live" >"$tmp/out.a" 2>&1 &
pa=$!
sleep 1 # the second run starts while the first is inside its slow make test
sh "$deploy" "$live" >"$tmp/out.b" 2>&1 &
pb=$!
wait $pa; wait $pb
n=$(cat "$tmp/out.a" "$tmp/out.b" 2>/dev/null | grep -c "^deployed ")
ok "D01-AC-4 exactly one run prints deployed" '[ "$n" = 1 ]'
ok "D01-AC-4 make test ran once for the commit" '[ "$(runs c5)" = 1 ]'
ok "D01-AC-4 live checkout is at the new commit" '[ "$(head_of)" = "$c5" ]'
ok "D01-AC-4 previous is the original HEAD" 'prev_is "$c4"'

lockheld() {
	commit c6 pass; c6=$(full "$tmp/work" HEAD); before=$(head_of)
	mkdir -p "$NOODLEBOT_DATA/deploy"
	( flock 9; sleep 3 ) 9>"$NOODLEBOT_DATA/deploy/lock" &
	hp=$!; sleep 0.5
	timeout 1 sh "$deploy" "$live" >/dev/null 2>&1
	during=$(head_of); ran=$(runs c6)
	wait $hp
	[ "$ran" = 0 ] && [ "$during" = "$before" ]
}

# D01 (runtime root, D02): deploy.sh writes nothing inside the live checkout; its state and lock are under $NOODLEBOT_DATA/deploy.
ok "D01-AC-1 deploys, rejects and rollback leave no state/ folder in the live checkout" '[ ! -e "$live/state" ]'
ok "D01-AC-1 the live checkout has no untracked or ignored file after all runs" '[ -z "$(git -C "$live" status --porcelain --ignored 2>&1)" ]'
ok "D01-AC-1 the deploy state is under NOODLEBOT_DATA/deploy" '[ -s "$NOODLEBOT_DATA/deploy/previous" ]'
ok "D01-AC-4 the lock is NOODLEBOT_DATA/deploy/lock (a held lock makes a run wait or skip, deploying nothing)" 'lockheld'

# --- slice D review findings (A1 clean environment, A2 unfast-forwardable, A3 killed make test) ---
# commitm <label> <Makefile recipe line> [extra file]: a new commit on main whose make test runs that recipe line.
commitm() {
	printf 'test:\n\t%s\n' "$2" >"$tmp/work/Makefile"
	echo "$1" >"$tmp/work/file"
	[ -n "${3:-}" ] && echo "$1" >"$tmp/work/$3"
	g add -A && g commit -q -m "$1" && g push -q "$tmp/remote.git" HEAD:main 2>/dev/null
}
# Settle the pending commit from the lock test so the cases below start from a deployed state.
dep >/dev/null

# A1: make test runs in a clean environment; the loop's own variables must not reach it.
commitm a1 "@echo a1 >>$log; [ -z \"\$\$SCHED_MAX\" ] && [ -z \"\$\$SCHED_TICK\" ] && [ -z \"\$\$SCHED_POLL\" ] && [ -z \"\$\$SCHED_REPORT\" ] && [ -z \"\$\$SCHED_THROTTLE\" ] && [ -z \"\$\$NOODLEBOT_DATA\" ]"
a1=$(full "$tmp/work" HEAD)
out=$(SCHED_MAX=1 SCHED_TICK=7 SCHED_POLL=9 SCHED_REPORT=0 SCHED_THROTTLE=1 sh "$deploy" "$live" 2>&1)
ok "D01-AC-1 make test ran for a commit that fails when the loop's variables are set" '[ "$(runs a1)" = 1 ]'
ok "D01-AC-1 a commit whose make test needs a clean environment is deployed (SCHED_*/NOODLEBOT_DATA not passed on)" '[ "$(head_of)" = "$a1" ]'
ok "D01-AC-1 and it is not reported as failing make test" '[ "$(runs a1)" = 1 ] && ! printf "%s\n" "$out" | grep -q "not deployed"'

# A2: make test passes but the live checkout cannot be fast-forwarded (untracked file where the commit adds one).
echo mine >"$live/a2.txt"
commitm a2 "@echo a2 >>$log" a2.txt
a2=$(full "$tmp/work" HEAD)
before=$(head_of)
out=$(sh "$deploy" "$live" 2>/dev/null)
ok "D01-AC-2 make test ran once for the commit that cannot be fast-forwarded" '[ "$(runs a2)" = 1 ]'
ok "D01-AC-2 the live checkout stays on the old commit when the fast-forward fails" '[ "$(runs a2)" = 1 ] && [ "$(head_of)" = "$before" ]'
ok "D01-AC-2 the failed fast-forward prints at most one stdout line (a status event)" '[ "$(runs a2)" = 1 ] && [ "$(printf "%s\n" "$out" | grep -c .)" -le 1 ]'
out=$(sh "$deploy" "$live" 2>/dev/null)
ok "D01-AC-2 the same commit is not tried again: make test is not rerun" '[ "$(runs a2)" = 1 ]'
ok "D01-AC-2 the later run prints nothing on stdout" '[ "$(runs a2)" = 1 ] && [ -z "$out" ]'
ok "D01-AC-2 the live checkout still on the old commit after the later run" '[ "$(runs a2)" = 1 ] && [ "$(head_of)" = "$before" ]'
rm -f "$live/a2.txt"

# A3: a make test killed by a signal is temporary: nothing is recorded, a later run retries.
a3m=$tmp/a3.marker
commitm a3 "@echo a3 >>$log; if [ ! -e $a3m ]; then : >$a3m; kill -KILL \$\$PPID; fi"
a3=$(full "$tmp/work" HEAD)
before=$(head_of)
out=$(sh "$deploy" "$live" 2>/dev/null)
ok "D01-AC-2 make test ran and was killed by a signal" '[ "$(runs a3)" = 1 ] && [ -e "$a3m" ]'
ok "D01-AC-2 a killed make test does not print not deployed" '[ "$(runs a3)" = 1 ] && ! printf "%s\n" "$out" | grep -q "not deployed"'
ok "D01-AC-2 a killed make test leaves the live checkout alone" '[ "$(runs a3)" = 1 ] && [ "$(head_of)" = "$before" ]'
out=$(dep)
ok "D01-AC-2 a later run retries the commit (make test runs again)" '[ "$(runs a3)" = 2 ]'
ok "D01-AC-2 and deploys it once make test passes" '[ "$(runs a3)" = 2 ] && [ "$(head_of)" = "$a3" ]'

echo
if [ "$fails" -eq 0 ]; then echo "all deploy tests passed"; else echo "$fails deploy test(s) FAILED"; exit 1; fi
