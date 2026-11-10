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
g tag v0.1.0   # V01-AC-4: tagged commits, so a version is not just a sha
git clone -q --bare "$tmp/work" "$tmp/remote.git"
git clone -q "$tmp/remote.git" "$live"
g remote add origin "$tmp/remote.git" 2>/dev/null
commit c1 pass
g tag v0.2.0 && g push -q "$tmp/remote.git" v0.2.0 2>/dev/null

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
m1=0; printf '%s\n' "$out" | grep -Eq "^deployed $(short "$c0")[0-9a-f]*\.\.$(short "$c1")[0-9a-f]* \(version [^)]+\)\$" && m1=1
ok "D01-AC-1 prints deployed <old>..<new> (version <v>)" '[ "$m1" = 1 ]'
# V01-AC-4: the events name git describe --tags --always of the commit they deploy, refuse or return to.
# (expected versions come from the remote's own repository, where the tags are; deploy.sh must bring them to the live checkout)
ver() { git -C "$tmp/work" describe --tags --always "$1" 2>/dev/null; }
v1=$(ver "$c1")
ok "V01-AC-4 the expected version of the deployed commit is a tag, not a bare sha (guard)" '[ "$v1" = v0.2.0 ]'
ok "V01-AC-4 the deploy line is 'deployed <old>..<new> (version <describe of new>)'" '[ "$v1" = v0.2.0 ] && [ "$out" = "deployed $c0..$c1 (version $v1)" ]'
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
m2=0; printf '%s\n' "$out" | grep -Eq "^not deployed: $(short "$c2")[0-9a-f]* \(version [^)]+\) fails make test\$" && m2=1
ok "D01-AC-2 prints 'not deployed: <sha> (version <v>) fails make test'" '[ "$m2" = 1 ]'
v2=$(ver "$c2")
ok "V01-AC-4 the refused commit's version is tag-based, not a bare sha (guard)" 'case $v2 in v0.2.0-1-g*) true ;; *) false ;; esac'
ok "V01-AC-4 the failing commit's line is 'not deployed: <sha> (version <describe of it>) fails make test'" '[ -n "$v2" ] && [ "$out" = "not deployed: $c2 (version $v2) fails make test" ]'
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
ok "V01-AC-4 the rollback line is 'rolled back <cur>..<prev> (version <describe of prev>)'" '[ "$v1" = v0.2.0 ] && [ "$out" = "rolled back $c3..$c1 (version $v1)" ]'
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
ok "D01-AC-2 the failed fast-forward prints exactly one stdout line" '[ "$(runs a2)" = 1 ] && [ "$(printf "%s\n" "$out" | grep -c .)" = 1 ]'
ok "D01-AC-2 that line starts with 'not deployed: <sha>'" '[ "$(runs a2)" = 1 ] && printf "%s\n" "$out" | grep -Eq "^not deployed: $(short "$a2")[0-9a-f]*( |\$)"'
va2=$(ver "$a2")
ok "V01-AC-4 the cannot-fast-forward line is 'not deployed: <sha> (version <describe of it>) cannot fast-forward <live> (will retry the fast-forward)'" '[ -n "$va2" ] && [ "$out" = "not deployed: $a2 (version $va2) cannot fast-forward $live (will retry the fast-forward)" ]'
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

# D2: a make test killed on every run is retried a bounded number of times, then rejected with one status line.
commitm d2 "@echo d2 >>$log; kill -KILL \$\$PPID"
d2=$(full "$tmp/work" HEAD)
before=$(head_of)
d2out=""
i=0
while [ "$i" -lt 5 ]; do
	o=$(sh "$deploy" "$live" 2>/dev/null)
	d2out="$d2out$o
"
	i=$((i + 1))
done
ok "D01-AC-2 a make test killed on every run ran (guard)" '[ "$(runs d2)" -ge 1 ]'
ok "D01-AC-2 a make test killed on every run is run at most 3 times over 5 deploy runs" '[ "$(runs d2)" -ge 1 ] && [ "$(runs d2)" -le 3 ]'
ok "D01-AC-2 the always-killed commit never moves the live checkout" '[ "$(runs d2)" -ge 1 ] && [ "$(head_of)" = "$before" ]'
ok "D01-AC-2 the always-killed commit gives exactly one stdout line over 5 runs" '[ "$(runs d2)" -ge 1 ] && [ "$(printf "%s" "$d2out" | grep -c .)" = 1 ]'
ok "D01-AC-2 that line starts with 'not deployed: <sha>'" '[ "$(runs d2)" -ge 1 ] && printf "%s" "$d2out" | grep -Eq "^not deployed: $(short "$d2")[0-9a-f]*( |\$)"'
# leave a deployed state: a newer passing commit supersedes the rejected one
commit d3 pass
dep >/dev/null

# --- slice F (fresh review F2, F3) ---
# waitfor <seconds> <condition>: poll until the shell condition holds or the time runs out.
waitfor() { w=0; while [ "$w" -lt $(($1 * 10)) ]; do eval "$2" && return 0; sleep 0.1; w=$((w + 1)); done; return 1; }

# F2: a TERM to deploy.sh while no make test is running must not signal its caller's process group.
# A post-checkout hook of the live checkout holds `git worktree add` (after the traps are set, before make test starts).
commit f2 pass
f2=$(full "$tmp/work" HEAD)
hook=$live/.git/hooks/post-checkout
mkdir -p "$live/.git/hooks"
printf '#!/bin/sh\n: >%s/hook.started\nsleep 2\n' "$tmp" >"$hook"
chmod +x "$hook"
rm -f "$tmp/hook.started" "$tmp/f2.pid" "$tmp/f2.survived"
# the caller runs in its own session/process group, so a stray `kill 0` cannot reach this harness
setsid sh -c 'sh "$1" "$2" >/dev/null 2>&1 & echo $! >"$3"; wait $!; : >"$4"; sleep 1' sh "$deploy" "$live" "$tmp/f2.pid" "$tmp/f2.survived" &
callerpid=$!
waitfor 5 '[ -e "$tmp/hook.started" ] && [ -s "$tmp/f2.pid" ]'
f2guard=0; [ -e "$tmp/hook.started" ] && [ -s "$tmp/f2.pid" ] && f2guard=1
dpid=$(cat "$tmp/f2.pid" 2>/dev/null)
[ "$f2guard" = 1 ] && kill -TERM "$dpid" 2>/dev/null
waitfor 5 '[ -e "$tmp/f2.survived" ]'
ok "D01-AC-2 TERM test reached deploy.sh between traps and make test (guard)" '[ "$f2guard" = 1 ]'
ok "D01-AC-2 deploy.sh exits on TERM" '[ "$f2guard" = 1 ] && ! kill -0 "$dpid" 2>/dev/null'
ok "D01-AC-2 a TERM to deploy.sh does not kill its caller (no kill of the process group)" '[ "$f2guard" = 1 ] && [ -e "$tmp/f2.survived" ]'
kill -KILL "-$callerpid" 2>/dev/null; kill -KILL "$callerpid" 2>/dev/null
wait "$callerpid" 2>/dev/null
sleep 2.2 # let the hook finish
rm -f "$hook"
git -C "$live" worktree prune
dep >/dev/null
ok "D01-AC-2 after the TERM a later run deploys the commit" '[ "$(head_of)" = "$f2" ]'

# F3: a temporary fast-forward failure after make test passed must not reject the commit for good.
commit f3 pass
f3=$(full "$tmp/work" HEAD)
before=$(head_of)
: >"$live/.git/index.lock"
out1=$(dep)
during=$(head_of)
rm -f "$live/.git/index.lock"
out2=$(dep)
ok "D01-AC-1 make test ran for the commit while the fast-forward is blocked (guard)" '[ "$during" = "$before" ] && [ "$(runs f3)" -ge 1 ]'
ok "D01-AC-2 a temporarily blocked fast-forward is not reported as failing make test" '[ "$(runs f3)" -ge 1 ] && ! printf "%s\n%s\n" "$out1" "$out2" | grep -Eq "not deployed: $(short "$f3")[0-9a-f]* \(version [^)]+\) fails make test"'
ok "D01-AC-1 once the lock is gone the next run deploys the commit" '[ "$(runs f3)" -ge 1 ] && [ "$(head_of)" = "$f3" ]'
ok "D01-AC-1 make test is not run a second time for that sha" '[ "$(runs f3)" = 1 ]'

# --- V01-AC-4 robustness: a moved or conflicting tag must not stop a deploy ---
# tagcase <name> <moved|local>: a fresh remote and live clone, both having tag v1 on the first commit.
# moved: origin's v1 is then moved to the new commit. local: the live checkout's own v1 points elsewhere than origin's.
tagcase() {
	tn=$1; tw=$tmp/tw-$tn; tr=$tmp/tr-$tn; tl=$tmp/tl-$tn
	tg() { git -C "$tw" -c user.name=t -c user.email=t@t "$@"; }
	git init -q -b main "$tw"
	printf 'test:\n\t@true\n' >"$tw/Makefile"; echo t0 >"$tw/file"
	tg add -A && tg commit -q -m t0 && tg tag v1
	git clone -q --bare "$tw" "$tr"
	git clone -q "$tr" "$tl"
	echo t1 >"$tw/file"; tg add -A && tg commit -q -m t1
	t0=$(git -C "$tl" rev-parse HEAD); t1=$(git -C "$tw" rev-parse HEAD)
	if [ "$2" = moved ]; then
		tg tag -f v1 "$t1" >/dev/null && tg push -q --force "$tr" HEAD:main v1 2>/dev/null
	else
		tg tag v2 "$t1" && tg push -q "$tr" HEAD:main v2 2>/dev/null
		git -C "$tl" tag v2 "$t0"
	fi
	tout=$(NOODLEBOT_DATA=$tmp/data-$tn sh "$deploy" "$tl" 2>"$tmp/err-$tn"); trc=$?
	thead=$(git -C "$tl" rev-parse HEAD)
}
tagcase moved moved
ok "V01-AC-4 a tag moved on origin: the new commit is still deployed (live checkout moves)" '[ "$thead" = "$t1" ]'
ok "V01-AC-4 a tag moved on origin: exit status 0 as for a normal deploy" '[ "$trc" = 0 ]'
ok "V01-AC-4 a tag moved on origin: exactly one line 'deployed <old>..<new> (version <v>)'" 'printf "%s\n" "$tout" | grep -Eq "^deployed $t0\.\.$t1 \(version [^)]+\)\$" && [ "$(printf "%s\n" "$tout" | grep -c .)" = 1 ]'
tagcase local local
ok "V01-AC-4 a conflicting local tag: the new commit is still deployed (live checkout moves)" '[ "$thead" = "$t1" ]'
ok "V01-AC-4 a conflicting local tag: exit status 0 as for a normal deploy" '[ "$trc" = 0 ]'
ok "V01-AC-4 a conflicting local tag: exactly one line 'deployed <old>..<new> (version <v>)'" 'printf "%s\n" "$tout" | grep -Eq "^deployed $t0\.\.$t1 \(version [^)]+\)\$" && [ "$(printf "%s\n" "$tout" | grep -c .)" = 1 ]'

# --- P03-AC-5: deploy/retry and deploy/rollback-request markers, consumed by the next run ---
dd=$NOODLEBOT_DATA/deploy
dep1() { sh "$deploy" "$live" 2>/dev/null; }
nlines() { printf '%s\n' "$1" | grep -c .; }
in_rejected() { grep -qx "$1" "$dd/rejected" 2>/dev/null; }
dep >/dev/null   # settle anything pending
# a commit whose make test fails until an external marker exists: rejected first, "now passes" after
rmark=$tmp/r1.pass
commitm r1 "@echo r1 >>$log; [ -e $rmark ]"
r1=$(full "$tmp/work" HEAD)
before_r1=$(head_of)
dep >/dev/null
ok "P03-AC-5 setup: the failing commit is rejected and not deployed (guard)" 'in_rejected "$r1" && [ "$(head_of)" = "$before_r1" ]'
: >"$rmark"
echo "$r1 2" >"$dd/tries"; echo "$r1 1" >"$dd/passed"
printf '%s\n' "$r1" >"$dd/retry"
out=$(dep1)
ok "P03-AC-5 a retry of the rejected origin/main head whose make test now passes deploys it" '[ "$(head_of)" = "$r1" ]'
ok "P03-AC-5 the retry run printed a line saying the retry was requested" 'printf "%s\n" "$out" | grep -i "retry" | grep -qi "requested"'
ok "P03-AC-5 the retry run printed the deployed line too" 'printf "%s\n" "$out" | grep -q "^deployed $before_r1\.\.$r1 "'
ok "P03-AC-5 the retry run printed exactly two status lines (one per event)" '[ "$(nlines "$out")" = 2 ]'
ok "P03-AC-5 the retried commit is gone from deploy/rejected" '[ "$(head_of)" = "$r1" ] && ! in_rejected "$r1"'
ok "P03-AC-5 its counts are gone from deploy/tries and deploy/passed" '[ "$(head_of)" = "$r1" ] && ! grep -q "$r1" "$dd/tries" "$dd/passed" 2>/dev/null'
ok "P03-AC-5 make test ran again for the retried commit" '[ "$(runs r1)" = 2 ]'
ok "P03-AC-5 the retry marker is gone after the run" '[ ! -e "$dd/retry" ]'

# a retry of a commit that is not rejected: one line saying there was nothing to retry
rej_before=$(cat "$dd/rejected" 2>/dev/null)
printf '%s\n' "$r1" >"$dd/retry"
out=$(dep1)
ok "P03-AC-5 a retry of a commit that is not rejected prints exactly one line" '[ "$(nlines "$out")" = 1 ]'
ok "P03-AC-5 that line says there was nothing to retry" 'printf "%s\n" "$out" | grep -qi "nothing"'
ok "P03-AC-5 that line mentions the retry" 'printf "%s\n" "$out" | grep -qi "retry"'
ok "P03-AC-5 nothing changed: head and deploy/rejected" '[ "$(head_of)" = "$r1" ] && [ "$(cat "$dd/rejected" 2>/dev/null)" = "$rej_before" ]'
ok "P03-AC-5 the marker of a nothing-to-retry is gone after the run" '[ ! -e "$dd/retry" ]'

# a rollback request with a rollback point (deploy/previous is the commit before r1)
prev_r1=$(cat "$dd/previous" 2>/dev/null)
printf '2026-11-10T03:15:00Z\n' >"$dd/rollback-request"
out=$(dep1)
ok "P03-AC-5 the rollback point is the commit before the deployed one (guard)" '[ "$prev_r1" = "$before_r1" ]'
ok "P03-AC-5 a rollback request leaves the live checkout at deploy/previous" '[ "$(head_of)" = "$before_r1" ]'
ok "P03-AC-5 the commit the rollback left is recorded in deploy/rejected" 'in_rejected "$r1"'
ok "P03-AC-5 the rollback run printed a line saying the rollback was requested" 'printf "%s\n" "$out" | grep -i "rollback\|rolled back" | grep -qi "requested"'
ok "P03-AC-5 the rollback run printed exactly one status line (the rolled-back commit is not redeployed)" '[ "$(nlines "$out")" = 1 ]'
ok "P03-AC-5 the rollback marker is gone after the run" '[ ! -e "$dd/rollback-request" ]'

# a rollback request without a rollback point: one line saying there was nothing to roll back
rm -f "$dd/previous"
rej_before=$(cat "$dd/rejected" 2>/dev/null)
head_before=$(head_of)
printf '2026-11-10T03:16:00Z\n' >"$dd/rollback-request"
out=$(dep1)
ok "P03-AC-5 a rollback request without a rollback point prints exactly one line" '[ "$(nlines "$out")" = 1 ]'
ok "P03-AC-5 that line says there was nothing to roll back" 'printf "%s\n" "$out" | grep -qi "nothing\|no rollback point"'
ok "P03-AC-5 that line mentions the rollback" 'printf "%s\n" "$out" | grep -qi "roll"'
ok "P03-AC-5 nothing changed: head and deploy/rejected" '[ "$(head_of)" = "$head_before" ] && [ "$(cat "$dd/rejected" 2>/dev/null)" = "$rej_before" ]'
ok "P03-AC-5 the marker of a rollback without a rollback point is gone after the run" '[ ! -e "$dd/rollback-request" ]'

echo
if [ "$fails" -eq 0 ]; then echo "all deploy tests passed"; else echo "$fails deploy test(s) FAILED"; exit 1; fi
