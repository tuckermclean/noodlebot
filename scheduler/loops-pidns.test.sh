#!/bin/sh
# Test of the lock probes in a pid namespace (D06-AC-11): held() in loops.sh, site.py and api.py.
#   sh scheduler/loops-pidns.test.sh   (make test)
# In a pid namespace of its own (the container) /proc/locks leaves out a lock whose taker (the short-lived
# `flock` command of a loop) is not visible; the lock is still on the fdinfo of the process holding the file
# open. NOODLEBOT_PROC_LOCKS (tests only) names the file the probes read instead of /proc/locks, so a real
# held lock can be shown with an empty /proc/locks, and a fabricated line with no lock held.
# Scratch lives under a folder named D06.
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
. "$src/testdata/lib/common.sh"
unset TMUX NOODLEBOT_PROC_LOCKS
base=${TMPDIR:-/tmp}/D06
mkdir -p "$base" || exit 1
tmp=$(mktemp -d "$base/pidns.XXXXXX") || exit 1
cleanup() {
	touch "$tmp"/*/release 2>/dev/null
	pkill -f "$tmp/" 2>/dev/null; sleep 0.3; pkill -9 -f "$tmp/" 2>/dev/null
	rm -rf "$tmp"; rmdir "$base" 2>/dev/null
	true
}
trap cleanup EXIT
trap 'exit 1' INT TERM

ok() { _n=$1; shift; if "$@"; then pass "$_n"; else fail "$_n"; fi; }
no() { _n=$1; shift; if "$@"; then fail "$_n"; else pass "$_n"; fi; }
has() { grep -qE -- "$1" "$2" 2>/dev/null; }

mkdir -p "$tmp/bin"
: >"$tmp/empty"
# a fake tmux: logs its arguments, runs `new -d -s <sess> <cmd...>` detached.
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

# probe.py <site|api> <lockfile>: prints held or free, from the real module's held().
cat >"$tmp/probe.py" <<'EOT'
import importlib.util, os, sys
src = os.environ["D06_SRC"]
sys.path.insert(0, src)
spec = importlib.util.spec_from_file_location("m_" + sys.argv[1], os.path.join(src, sys.argv[1] + ".py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print("held" if m.held(sys.argv[2]) else "free")
EOT
# fab.py <lockfile>: a /proc/locks line for the file, as the kernel writes it (pid 4242).
cat >"$tmp/fab.py" <<'EOT'
import os, sys
st = os.stat(sys.argv[1])
print("1: FLOCK  ADVISORY  WRITE 4242 %02x:%02x:%d 0 EOF" % (os.major(st.st_dev), os.minor(st.st_dev), st.st_ino))
EOT
D06_SRC=$src; export D06_SRC
probe() { python3 -I -B "$tmp/probe.py" "$1" "$2" 2>/dev/null; }

# scenario <name>: a runtime root, a checkout copy of loops.sh with a fake loop.sh and api.py, HOME with one repository.
scenario() {
	sc=$tmp/$1 nb=$sc/nb data=$sc/data
	HOME=$sc/home TMUXLOG=$sc/tmux.log NOODLEBOT_DATA=$data
	export HOME TMUXLOG NOODLEBOT_DATA
	mkdir -p "$HOME/.config/noodlebot" "$nb/scheduler/harnesses" "$data/state/alpha"
	cp "$src/loops.sh" "$src/harness.py" "$nb/scheduler/"
	cp "$src"/harnesses/*.py "$nb/scheduler/harnesses/"
	echo o/alpha >"$HOME/.config/noodlebot/repos"
	cat >"$nb/scheduler/loop.sh" <<'EOT'
#!/bin/sh
name=${1#*/}
st=$NOODLEBOT_DATA/state/$name
mkdir -p "$st"
exec 9>"$st/loop.lock"
flock -n 9 || exit 1
echo $$ >"$st/loop.pid"
while [ ! -e "$HOME/STOP" ] && [ ! -e "$HOME/STOP-$name" ]; do sleep 0.2; done
EOT
	cat >"$nb/scheduler/api.py" <<'EOT'
#!/usr/bin/env python3
import fcntl, os, signal, sys, time
here = os.path.dirname(os.path.abspath(__file__))
def log(s):
    with open(os.path.join(here, "api.log"), "a") as h:
        h.write(s + "\n")
lk = open(os.path.join(os.environ["NOODLEBOT_DATA"], "api.lock"), "w")
try:
    fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    log("lockfail")
    sys.exit(1)
log("start pid=%d" % os.getpid())
def stop(*a):
    log("term")
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
while True:
    time.sleep(0.1)
EOT
	chmod +x "$nb/scheduler/loop.sh" "$nb/scheduler/api.py"
	: >"$sc/tmux.log"
}
# hold <name> <lockfile>: a process that holds the lock as a loop's shell does: it takes it with the
# `flock` command, which exits at once, and keeps fd 9 open until $sc/release-<name> exists.
hold() {
	rm -f "$sc/held-$1" "$sc/release-$1"
	setsid sh -c 'exec 9>"$1"; flock -n 9 || exit 1; : >"$2"; while [ ! -e "$3" ]; do sleep 0.1; done; true' sh "$2" "$sc/held-$1" "$sc/release-$1" >/dev/null 2>&1 </dev/null &
	wait_file 10 "$sc/held-$1"
}
# unhold <name> <lockfile>: let the holder go and wait until the lock is free.
unhold() {
	: >"$sc/release-$1"
	wait_until 10 flock -n "$2" true
}
loops() { timeout 40 bash "$nb/scheduler/loops.sh" "$@" >"$sc/out" 2>&1 </dev/null; echo $? >"$sc/rc"; }
rc_is() { [ "$(cat "$sc/rc" 2>/dev/null)" = "$1" ]; }
loop_line() { grep '^o/alpha:' "$sc/out"; }
api_line() { grep '^api:' "$sc/out"; }

EMPTY=$tmp/empty
LL=data/state/alpha/loop.lock AL=data/api.lock

echo "# D06-AC-11: empty /proc/locks, real locks held by processes that keep the fd open"
scenario held
: >"$data/state/alpha/loop.lock"; : >"$data/api.lock"
hold loop "$data/state/alpha/loop.lock"
hold api "$data/api.lock"
export NOODLEBOT_PROC_LOCKS=$EMPTY
loops status
ok "D06-AC-11:status:loop-running-with-empty-proc-locks" sh -c "loop_line=\$(grep '^o/alpha:' '$sc/out'); case \$loop_line in *'loop running'*) true ;; *) false ;; esac"
ok "D06-AC-11:status:api-server-running-with-empty-proc-locks" has '^api: server running' "$sc/out"
no "D06-AC-11:status:loop-not-reported-not-running" has 'loop not running' "$sc/out"
ok "D06-AC-11:site.py:loop-lock-held" test "$(probe site "$data/state/alpha/loop.lock")" = held
ok "D06-AC-11:api.py:loop-lock-held" test "$(probe api "$data/state/alpha/loop.lock")" = held
ok "D06-AC-11:site.py:api-lock-held" test "$(probe site "$data/api.lock")" = held
ok "D06-AC-11:api.py:api-lock-held" test "$(probe api "$data/api.lock")" = held
loops start
ok "D06-AC-11:start:rc-0" rc_is 0
ok "D06-AC-11:start:sees-running-loop" has 'o/alpha: loop already running' "$sc/out"
ok "D06-AC-11:start:sees-running-api-server" has 'api: server already running' "$sc/out"
no "D06-AC-11:start:starts-no-second-loop-or-server" has 'sched-' "$sc/tmux.log"

echo "# D06-AC-11: with the locks released each probe reports not held"
unhold loop "$data/state/alpha/loop.lock"
unhold api "$data/api.lock"
loops status
ok "D06-AC-11:released:status-loop-not-running" has 'o/alpha: loop not running' "$sc/out"
ok "D06-AC-11:released:status-api-not-running" has '^api: server not running' "$sc/out"
ok "D06-AC-11:released:site.py-loop-lock-free" test "$(probe site "$data/state/alpha/loop.lock")" = free
ok "D06-AC-11:released:api.py-loop-lock-free" test "$(probe api "$data/state/alpha/loop.lock")" = free
ok "D06-AC-11:released:site.py-api-lock-free" test "$(probe site "$data/api.lock")" = free
ok "D06-AC-11:released:api.py-api-lock-free" test "$(probe api "$data/api.lock")" = free
loops stop
ok "D06-AC-11:released:stop-says-loop-not-running" has 'o/alpha: loop not running' "$sc/out"
ok "D06-AC-11:released:stop-says-api-not-running" has 'api: server not running' "$sc/out"
unset NOODLEBOT_PROC_LOCKS

echo "# D06-AC-11: stop with an empty /proc/locks stops the loop and signals the API server (never pid 0)"
scenario stop
export NOODLEBOT_PROC_LOCKS=$EMPTY LOOPS_STOP_WAIT=20
setsid "$nb/scheduler/loop.sh" o/alpha >/dev/null 2>&1 </dev/null &
setsid python3 "$nb/scheduler/api.py" >/dev/null 2>&1 </dev/null &
wait_file 10 "$data/state/alpha/loop.pid"
wait_line 10 '^start pid=' "$nb/scheduler/api.log"
apid=$(sed -n 's/^start pid=//p' "$nb/scheduler/api.log")
loops stop
ok "D06-AC-11:stop:rc-0" rc_is 0
ok "D06-AC-11:stop:waited-for-the-loop-lock" has 'o/alpha: loop stopped' "$sc/out"
ok "D06-AC-11:stop:loop-lock-free-when-stop-returned" flock -n "$data/state/alpha/loop.lock" true
ok "D06-AC-11:stop:STOP-file-removed" test ! -e "$HOME/STOP-alpha"
ok "D06-AC-11:stop:api-server-got-TERM" has '^term$' "$nb/scheduler/api.log"
no "D06-AC-11:stop:holder-not-pid-0-nor-refused" has 'not the API server|not signalled' "$sc/out"
ok "D06-AC-11:stop:api-server-stopped" has '^api: server stopped' "$sc/out"
ok "D06-AC-11:stop:api-server-process-gone" sh -c "! kill -0 '${apid:-0}' 2>/dev/null"
unset NOODLEBOT_PROC_LOCKS LOOPS_STOP_WAIT

echo "# D06-AC-11: NOODLEBOT_PROC_LOCKS names the file the probes read (a line, no lock held)"
scenario fab
: >"$data/state/alpha/loop.lock"; : >"$data/api.lock"
python3 -I "$tmp/fab.py" "$data/state/alpha/loop.lock" >"$sc/locks-loop"
python3 -I "$tmp/fab.py" "$data/api.lock" >"$sc/locks-api"
cat "$sc/locks-loop" "$sc/locks-api" >"$sc/locks-both"
# a line for another inode, which must match nothing
sed 's/:[0-9]* 0 EOF/:999999999 0 EOF/' "$sc/locks-loop" >"$sc/locks-other"
ok "D06-AC-11:override:control-no-lock-is-held" flock -n "$data/state/alpha/loop.lock" true
export NOODLEBOT_PROC_LOCKS=$sc/locks-loop
ok "D06-AC-11:override:site.py-reads-the-named-file" test "$(probe site "$data/state/alpha/loop.lock")" = held
ok "D06-AC-11:override:api.py-reads-the-named-file" test "$(probe api "$data/state/alpha/loop.lock")" = held
loops status
ok "D06-AC-11:override:loops.sh-status-reads-the-named-file" has 'o/alpha: loop running' "$sc/out"
export NOODLEBOT_PROC_LOCKS=$sc/locks-other
ok "D06-AC-11:override:site.py-other-inode-not-held" test "$(probe site "$data/state/alpha/loop.lock")" = free
ok "D06-AC-11:override:api.py-other-inode-not-held" test "$(probe api "$data/state/alpha/loop.lock")" = free
loops status
ok "D06-AC-11:override:loops.sh-other-inode-not-running" has 'o/alpha: loop not running' "$sc/out"
unset NOODLEBOT_PROC_LOCKS
# start in a scenario of its own: without the override it would start a real loop and server
scenario fab2
: >"$data/state/alpha/loop.lock"; : >"$data/api.lock"
python3 -I "$tmp/fab.py" "$data/state/alpha/loop.lock" >"$sc/locks-both"
python3 -I "$tmp/fab.py" "$data/api.lock" >>"$sc/locks-both"
export NOODLEBOT_PROC_LOCKS=$sc/locks-both
loops start
ok "D06-AC-11:override:loops.sh-start-reads-the-named-file" has 'o/alpha: loop already running' "$sc/out"
ok "D06-AC-11:override:loops.sh-start-sees-api-server" has 'api: server already running' "$sc/out"
no "D06-AC-11:override:start-launched-nothing" has 'sched-' "$sc/tmux.log"
unset NOODLEBOT_PROC_LOCKS

echo "# D06-AC-11 control: on the host, /proc/locks lists the lock and nothing changes"
scenario host
: >"$data/state/alpha/loop.lock"; : >"$data/api.lock"
hold loop "$data/state/alpha/loop.lock"
hold api "$data/api.lock"
ok "D06-AC-11:host:site.py-held" test "$(probe site "$data/state/alpha/loop.lock")" = held
ok "D06-AC-11:host:api.py-held" test "$(probe api "$data/state/alpha/loop.lock")" = held
loops status
ok "D06-AC-11:host:status-loop-running" has 'o/alpha: loop running' "$sc/out"
unhold loop "$data/state/alpha/loop.lock"
unhold api "$data/api.lock"
ok "D06-AC-11:host:site.py-free-after-release" test "$(probe site "$data/state/alpha/loop.lock")" = free
ok "D06-AC-11:host:api.py-free-after-release" test "$(probe api "$data/state/alpha/loop.lock")" = free

echo "# D06-AC-11: in a pid namespace of its own (passes when unshare is refused)"
scenario ns
# inner.sh: takes the locks as a loop does (flock exits, this shell keeps fd 9 and 8), probes, releases, probes.
cat >"$sc/inner.sh" <<'EOT'
#!/bin/sh
nb=$1 data=$2 tmp=$3
unset NOODLEBOT_PROC_LOCKS
exec 9>"$data/state/alpha/loop.lock"; flock -n 9 || exit 3
exec 8>"$data/api.lock"; flock -n 8 || exit 3
pr() { python3 -I -B "$tmp/probe.py" "$1" "$2" 2>/dev/null; }
echo "held:site-loop=$(pr site "$data/state/alpha/loop.lock")"
echo "held:api-loop=$(pr api "$data/state/alpha/loop.lock")"
echo "held:site-api=$(pr site "$data/api.lock")"
echo "held:api-api=$(pr api "$data/api.lock")"
echo "held:status=$(bash "$nb/scheduler/loops.sh" status 2>&1 </dev/null | tr '\n' '|')"
exec 9>&- 8>&-
echo "free:site-loop=$(pr site "$data/state/alpha/loop.lock")"
echo "free:api-loop=$(pr api "$data/state/alpha/loop.lock")"
echo "free:site-api=$(pr site "$data/api.lock")"
echo "free:api-api=$(pr api "$data/api.lock")"
echo "free:status=$(bash "$nb/scheduler/loops.sh" status 2>&1 </dev/null | tr '\n' '|')"
EOT
: >"$data/state/alpha/loop.lock"; : >"$data/api.lock"
if timeout 20 unshare --user --map-root-user --pid --fork --mount-proc sh -c 'test -r /proc/self/status && ! test -r /proc/1/status.nonexistent' >/dev/null 2>&1; then
	timeout 30 unshare --user --map-root-user --pid --fork --mount-proc sh "$sc/inner.sh" "$nb" "$data" "$tmp" >"$sc/ns.out" 2>"$sc/ns.err" </dev/null
	ok "D06-AC-11:pidns:inner-script-ran-to-its-end" has '^free:status=' "$sc/ns.out"
	ok "D06-AC-11:pidns:site.py-sees-held-loop-lock" has '^held:site-loop=held' "$sc/ns.out"
	ok "D06-AC-11:pidns:api.py-sees-held-loop-lock" has '^held:api-loop=held' "$sc/ns.out"
	ok "D06-AC-11:pidns:site.py-sees-held-api-lock" has '^held:site-api=held' "$sc/ns.out"
	ok "D06-AC-11:pidns:api.py-sees-held-api-lock" has '^held:api-api=held' "$sc/ns.out"
	ok "D06-AC-11:pidns:loops.sh-status-sees-loop-and-server" has '^held:status=.*o/alpha: loop running.*api: server running' "$sc/ns.out"
	ok "D06-AC-11:pidns:site.py-free-after-release" has '^free:site-loop=free' "$sc/ns.out"
	ok "D06-AC-11:pidns:api.py-free-after-release" has '^free:api-loop=free' "$sc/ns.out"
	ok "D06-AC-11:pidns:loops.sh-status-not-running-after-release" has '^free:status=.*o/alpha: loop not running.*api: server not running' "$sc/ns.out"
else
	pass "D06-AC-11:pidns: unshare --user --map-root-user --pid --fork --mount-proc is refused here; the namespace case is skipped (the cases above cover each probe)"
fi

echo "# D06-AC-11: stop signals the server found by its /proc/<pid> path when the lock's owner pid is another process"
scenario stowner
# an API server whose lock was taken by a short-lived `flock` command on an fd the server keeps open: the pid
# on the lock line is the dead flock command's, only the /proc/<pid>/fdinfo path names the server.
cat >"$nb/scheduler/api.py" <<'EOT'
#!/usr/bin/env python3
import os, signal, subprocess, sys, time
here = os.path.dirname(os.path.abspath(__file__))
def log(s):
    with open(os.path.join(here, "api.log"), "a") as h:
        h.write(s + "\n")
lk = open(os.path.join(os.environ["NOODLEBOT_DATA"], "api.lock"), "w")
fd = lk.fileno()
if subprocess.run(["flock", "-n", str(fd)], pass_fds=(fd,)).returncode != 0:
    log("lockfail")
    sys.exit(1)
log("start pid=%d" % os.getpid())
def stop(*a):
    log("term")
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
while True:
    time.sleep(0.1)
EOT
export NOODLEBOT_PROC_LOCKS=$EMPTY LOOPS_STOP_WAIT=20
setsid "$nb/scheduler/loop.sh" o/alpha >/dev/null 2>&1 </dev/null &
setsid python3 "$nb/scheduler/api.py" >/dev/null 2>&1 </dev/null &
wait_file 10 "$data/state/alpha/loop.pid"
wait_line 10 '^start pid=' "$nb/scheduler/api.log"
apid2=$(sed -n 's/^start pid=//p' "$nb/scheduler/api.log")
loops status
ok "D06-AC-11:stop-owner:status-sees-api-server-running" has '^api: server running' "$sc/out"
loops stop
ok "D06-AC-11:stop-owner:rc-0" rc_is 0
ok "D06-AC-11:stop-owner:api-server-got-TERM" has '^term$' "$nb/scheduler/api.log"
no "D06-AC-11:stop-owner:no-refusal-message" has 'not the API server|not signalled' "$sc/out"
ok "D06-AC-11:stop-owner:api-server-stopped" has '^api: server stopped' "$sc/out"
ok "D06-AC-11:stop-owner:api-server-process-gone" sh -c "! kill -0 '${apid2:-0}' 2>/dev/null"
unset NOODLEBOT_PROC_LOCKS LOOPS_STOP_WAIT

[ "$fails" = 0 ] || { echo "$fails FAILED"; exit 1; }
echo "all passed"
