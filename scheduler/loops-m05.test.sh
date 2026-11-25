#!/bin/sh
# Test of scheduler/loops.sh for M05 (loops-watchdog): the recorded settings, `loops.sh watch` and what it starts
# (M05-AC-1, M05-AC-3, M05-AC-6; the stale-loop and watch-unit cases (M05-AC-2, M05-AC-5) come with their slice).
#   sh scheduler/loops-m05.test.sh   (make test)
# Fakes of tmux, loop.sh and api.py come first on a scratch PATH made of the fakes and symlinks to the few tools loops.sh
# needs (no /usr/bin), so the real tmux, systemd-run, systemctl, loginctl and sudo are never reached. Every path is under
# $top/M05/<case>; the units file is never written, so loops.sh calls neither loginctl nor systemd-run.
# Interfaces the fakes give loops.sh:
#   tmux: logs "$*" to $TMUXLOG; `new -d -s <name> <cmd...>` runs <cmd> through fixture_start, so in a session of its own
#         as the real tmux server does; display, ls, has-session answer "no server".
#   loop.sh <owner/name>: takes $NOODLEBOT_DATA/state/<name>/loop.lock (after the seconds in $NOODLEBOT_DATA/loop.delay,
#         if that file exists), writes loop.pid, a heartbeat (epoch seconds, as the real loop does) and env.out (its
#         environment), appends its pid to starts; ends when $HOME/STOP-<name>, state/<name>/die or $NOODLEBOT_DATA/die.all exists.
#   api.py: the same with api.lock, api.pid, api.starts, and api.die in place of die.
# Interface the tests give the implementation (the wording of the watch's restart line in the repository's status.log):
#   one line per restart, beginning with the UTC stamp (YYYY-MM-DDTHH:MM:SSZ ) like every status.log line, then text
#   holding, in this order, `watch`, `restarted`, and either `heartbeat <n> s old` (<n> whole seconds, the age the
#   heartbeat had) or `no heartbeat`; e.g.
#     2026-03-10T09:05:00Z loops.sh watch: restarted the loop (heartbeat 600 s old)
#     2026-03-10T09:05:00Z loops.sh watch: restarted the loop (no heartbeat)
#   It must not look like a unit's start (report.py's START pattern `started <ID> (`): report.py posts it as an event
#   on the log issue and makes no milestone or unit issue from it.
# The watch runs with an empty environment: HOME, PATH, NOODLEBOT_DATA and the fakes' variables only.
#   Follow-up cases name state/watch.lock (the lock the watch takes, under the runtime root), which the test holds itself.
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
top=$(mktemp -d) && [ -d "$top" ] || exit 1
base=$top/M05
mkdir -p "$base" || exit 1
trap 'for d in "$base"/*/data; do : >"$d/die.all"; done 2>/dev/null; fixture_stop_all; rm -rf "$top"' EXIT
. "$src/testdata/lib/fixture.sh"; NB_FIXTURE_SH=$src/testdata/lib/fixture.sh; export NB_FIXTURE_SH
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
# eq <name> <got> <want>
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }
ok() { name=$1; shift; if "$@" 2>/dev/null; then pass "$name"; else fail "$name"; fi; }
# cnt <file> <grep args...>: the number of matching lines (0 for a missing file)
cnt() { f=$1; shift; n=$(grep -c "$@" "$f" 2>/dev/null); echo "${n:-0}"; }
# the session variables of a loop run must not leak into the scratch loops
for v in $(env | sed -n 's/^\(\(USAGE\|SCHED\|PICKUP\)[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
unset NOODLEBOT_DATA NOODLEBOT_VERSION NOODLEBOT_PROC_ROOT NOODLEBOT_PROC_LOCKS

# tools: symlinks to what loops.sh, the fakes and fixture.sh need; no /usr/bin on the PATH of a case
tools=$base/tools
mkdir -p "$tools"
for t in bash sh env flock stat grep sed tr findmnt readlink python3 sleep mkdir rm cat id timeout setsid date cut \
	basename dirname touch ls cp mv head tail wc awk sort uname printf echo test expr kill pgrep mktemp ln chmod; do
	p=$(command -v "$t" 2>/dev/null)
	case $p in /*) ln -s "$p" "$tools/$t" ;; esac
done

# newcase <name> <repo name>...: a scratch HOME, runtime root, checkout copy with the fakes, and the repository list
newcase() {
	cn=$1; shift
	c=$base/$cn; nb=$c/nb; bin=$c/bin; root=$c/data
	HOME=$c/home
	TMUXLOG=$c/tmux.log TMUXSTATE=$c/tmux.state
	export HOME TMUXLOG TMUXSTATE
	mkdir -p "$HOME/.config/noodlebot" "$nb/scheduler" "$root" "$bin"
	cp "$src/loops.sh" "$nb/scheduler/"
	: >"$HOME/.config/noodlebot/repos"
	for r in "$@"; do echo "o/$r" >>"$HOME/.config/noodlebot/repos"; done
	cat >"$bin/tmux" <<'EOT'
#!/bin/sh
echo "$*" >>"$TMUXLOG"
case $1 in
new | new-session)
	shift
	while [ $# -gt 0 ]; do case $1 in -d) shift ;; -s) shift 2 ;; *) break ;; esac; done
	. "$NB_FIXTURE_SH"
	fixture_start sh -c "$*" >/dev/null 2>&1 </dev/null &
	exit 0 ;;
esac
echo "no server running" >&2
exit 1
EOT
	chmod +x "$bin/tmux"
	cat >"$nb/scheduler/loop.sh" <<'EOT'
#!/bin/sh
name=${1#*/}
d=$NOODLEBOT_DATA/state/$name
mkdir -p "$d"
[ -s "$NOODLEBOT_DATA/loop.delay" ] && sleep "$(cat "$NOODLEBOT_DATA/loop.delay")"
exec 9>"$d/loop.lock"
flock -n 9 || exit 1
echo $$ >"$d/loop.pid"
date +%s >"$d/heartbeat"
env | sort >"$d/env.tmp" && mv "$d/env.tmp" "$d/env.out"
echo $$ >>"$d/starts"
while [ ! -e "$HOME/STOP-$name" ] && [ ! -e "$d/die" ] && [ ! -e "$NOODLEBOT_DATA/die.all" ]; do sleep 0.2; done
EOT
	chmod +x "$nb/scheduler/loop.sh"
	cat >"$nb/scheduler/api.py" <<'EOT'
import fcntl, os, time
root = os.environ["NOODLEBOT_DATA"]
delay = os.path.join(root, "loop.delay")
if os.path.exists(delay):
    time.sleep(float(open(delay).read()))
f = open(os.path.join(root, "api.lock"), "w")
fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
open(os.path.join(root, "api.pid"), "w").write(str(os.getpid()))
open(os.path.join(root, "api.starts"), "a").write(str(os.getpid()) + "\n")
while not os.path.exists(os.path.join(root, "api.die")) and not os.path.exists(os.path.join(root, "die.all")):
    time.sleep(0.2)
EOT
	NOODLEBOT_DATA=$root
	export NOODLEBOT_DATA
}
# run <start|stop|watch> [VAR=value...]: loops.sh on the case's PATH, with the given variables added; output in $c/out.<cmd>,
# status in $c/rc.<cmd>
run() { cmd=$1; shift; env -u TMUX PATH="$bin:$tools" "$@" timeout 60 sh "$nb/scheduler/loops.sh" "$cmd" >"$c/out.$cmd" 2>&1 </dev/null; echo $? >"$c/rc.$cmd"; }
# wenv: the empty environment of a watch run: what the case needs and nothing else (no SCHED_*, USAGE_*, PICKUP*)
wenv() { env -i HOME="$HOME" PATH="$bin:$tools" NOODLEBOT_DATA="$root" TMUXLOG="$TMUXLOG" TMUXSTATE="$TMUXSTATE" \
	NB_FIXTURE_SH="$NB_FIXTURE_SH" NB_TEST_SHELL="$NB_TEST_SHELL" "$@"; }
# watch <tag>: loops.sh watch with an empty environment; output in $c/out.watch<tag>, status in $c/rc.watch<tag>
watch() { wenv timeout 60 sh "$nb/scheduler/loops.sh" watch >"$c/out.watch$1" 2>&1 </dev/null; echo $? >"$c/rc.watch$1"; }
# held <lockfile>: the lock is held (probing it takes it for an instant only when it is free)
held() { [ -e "$1" ] && ! flock -n "$1" true 2>/dev/null; }
# waitheld <lockfile>: up to 10 s for the lock to be held
waitheld() { i=0; while ! held "$1" && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done; held "$1"; }
waitfree() { i=0; while held "$1" && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done; ! held "$1"; }
# die <name>: the loop's fake ends; waits for its lock to be free
die() { touch "$root/state/$1/die"; waitfree "$root/state/$1/loop.lock"; rm -f "$root/state/$1/die"; }
diea() { touch "$root/api.die"; waitfree "$root/api.lock"; rm -f "$root/api.die"; }
# wrc <tag>: the exit status of watch run <tag>
wrc() { cat "$c/rc.watch$1" 2>/dev/null || echo none; }
# newn <session>: tmux new calls for the session in the case's tmux log
newn() { cnt "$TMUXLOG" "^new .*-s sched-$1 "; }
alive() { [ -s "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }
endcase() { : >"$root/die.all"; }

# the report: the fake forge and report.py of the report*.test.sh files, in a folder of its own under M05
tmp=$base/report
mkdir -p "$tmp"
fakegh_lib=$src/testdata/lib
. "$fakegh_lib/report-fakegh.sh"
pyc_setup
. "$fakegh_lib/report-units.sh"

echo "# M05-AC-1: start records its settings; watch restarts dead loops and the API with them, leaves a running loop alone"
newcase ac1 alpha beta gamma
run start SCHED_MAX=2 USAGE_7D_PACE=1
eq "M05-AC-1:start-exits-0" "$(cat "$c/rc.start")" 0
lenv=$root/state/loops.env
eq "M05-AC-1:loops.env-mode-0600" "$(stat -c %a "$lenv" 2>/dev/null)" 600
eq "M05-AC-1:loops.env-holds-exactly-the-passed-settings" "$(sort "$lenv" 2>/dev/null | tr '\n' ' ')" "SCHED_MAX=2 USAGE_7D_PACE=1 "
gpid=$(cat "$root/state/gamma/loop.pid" 2>/dev/null)
apid=$(cat "$root/api.pid" 2>/dev/null)
# the report's first run (nothing old is posted), on alpha's runtime folder; the log issue is made then
: >"$root/state/alpha/status.log"
urun "$root/state/alpha"
lognum=$(uq "[i['number'] for i in db['issues'].values() if i['title'].startswith('noodlebot log')][0]")
nissues=$(uq "len(db['issues'])")
# alpha ended with a stale heartbeat file, beta with none, the API ended too; gamma keeps running
die alpha; die beta; diea
now=$(date +%s)
echo $((now - 600)) >"$root/state/alpha/heartbeat"; touch -d "@$((now - 600))" "$root/state/alpha/heartbeat"
rm -f "$root/state/beta/heartbeat"
: >"$TMUXLOG"
watch 1
alpha_ok=0
if [ "$(wrc 1)" = 0 ]; then waitheld "$root/state/alpha/loop.lock"; waitheld "$root/state/beta/loop.lock"; waitheld "$root/api.lock"; fi
eq "M05-AC-1:watch-restarts-alpha-once" "$(newn alpha)" 1
eq "M05-AC-1:watch-restarts-beta-once" "$(newn beta)" 1
eq "M05-AC-1:watch-starts-the-api-once" "$(newn api)" 1
eq "M05-AC-1:watch-leaves-the-running-loop-alone-no-tmux-new" "$(newn gamma)" 0
eq "M05-AC-1:running-loop-pid-unchanged" "$(cat "$root/state/gamma/loop.pid" 2>/dev/null)" "$gpid"
ok "M05-AC-1:running-loop-still-holds-its-lock" held "$root/state/gamma/loop.lock"
ok "M05-AC-1:restarted-loops-and-api-hold-their-locks" sh -c "[ -s '$root/state/alpha/starts' ] && [ \"\$(wc -l <'$root/state/alpha/starts')\" = 2 ] && [ \"\$(wc -l <'$root/state/beta/starts')\" = 2 ] && [ \"\$(wc -l <'$root/api.starts')\" = 2 ]"
for l in alpha beta; do
	ok "M05-AC-1:$l-restarted-with-SCHED_MAX=2" grep -qx 'SCHED_MAX=2' "$root/state/$l/env.out"
	ok "M05-AC-1:$l-restarted-with-USAGE_7D_PACE=1" grep -qx 'USAGE_7D_PACE=1' "$root/state/$l/env.out"
done
ok "M05-AC-1:the-api-was-not-started-with-the-old-pid" test "$(cat "$root/api.pid" 2>/dev/null)" != "$apid"
echo "# M05-AC-1: each restart is one line in the repository's status.log naming the watch and the heartbeat's age"
sl=$root/state/alpha/status.log
eq "M05-AC-1:alpha-one-restart-line" "$(cnt "$sl" -E 'watch.*restarted')" 1
eq "M05-AC-1:alpha-restart-line-is-the-only-line-naming-the-watch" "$(cnt "$sl" -i 'watch')" 1
ok "M05-AC-1:alpha-restart-line-begins-with-a-UTC-stamp" grep -qE '^20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z .*watch.*restarted' "$sl"
age=$(sed -n 's/.*watch.*restarted.*heartbeat \([0-9][0-9]*\) s old.*/\1/p' "$sl" 2>/dev/null)
ok "M05-AC-1:alpha-restart-line-gives-the-heartbeat-age-in-seconds-600-to-700" test "$age" -ge 600 -a "$age" -le 700
sl=$root/state/beta/status.log
eq "M05-AC-1:beta-one-restart-line" "$(cnt "$sl" -E 'watch.*restarted')" 1
ok "M05-AC-1:beta-restart-line-says-no-heartbeat" grep -qE 'watch.*restarted.*no heartbeat' "$sl"
eq "M05-AC-1:running-loop-gamma-has-no-restart-line" "$(cnt "$root/state/gamma/status.log" -i 'watch')" 0
echo "# M05-AC-1: report.py posts the restart line among the day's events on the log issue, and makes no unit start of it"
urun "$root/state/alpha"
eq "M05-AC-1:report-posts-the-restart-line-on-the-log-issue" "$(ucount "$lognum" 'watch[^\n]*restarted[^\n]*heartbeat [0-9]+ s old')" 1
eq "M05-AC-1:report-comment-is-an-event-line" "$(ucount "$lognum" '^- `[^`]*` [^\n]*watch[^\n]*restarted')" 1
eq "M05-AC-1:report-opens-no-unit-issue-for-the-restart-line" "$(uq "len(db['issues'])")" "$nissues"
eq "M05-AC-1:report-comments-only-on-the-log-issue" "$(uq "len([c for c in db['comments'] if c['issue'] != '$lognum'])")" 0
eq "M05-AC-1:report-posts-the-restart-line-once-over-a-further-run" "$(urun "$root/state/alpha"; ucount "$lognum" 'watch[^\n]*restarted')" 1
endcase

echo "# M05-AC-1: two watch runs at once start each dead loop and the API once"
newcase ac1-two alpha beta
echo 1 >"$root/loop.delay"
watch a &
pa=$!
watch b &
pb=$!
wait $pa $pb
if [ "$(wrc a)$(wrc b)" = 00 ]; then waitheld "$root/state/alpha/loop.lock"; waitheld "$root/state/beta/loop.lock"; waitheld "$root/api.lock"; fi
eq "M05-AC-1:two-watches:alpha-one-tmux-new" "$(newn alpha)" 1
eq "M05-AC-1:two-watches:beta-one-tmux-new" "$(newn beta)" 1
eq "M05-AC-1:two-watches:api-one-tmux-new" "$(newn api)" 1
ok "M05-AC-1:two-watches:both-loops-and-the-api-run" sh -c "[ -s '$root/state/alpha/loop.pid' ] && [ -s '$root/state/beta/loop.pid' ] && [ -s '$root/api.pid' ]"
eq "M05-AC-1:two-watches:alpha-one-restart-line" "$(cnt "$root/state/alpha/status.log" -E 'watch.*restarted')" 1
endcase

echo "# M05-AC-3: no restart while ~/STOP exists"
newcase ac3-stop alpha beta
touch "$HOME/STOP"
watch 1
eq "M05-AC-3:STOP:alpha-not-started" "$(newn alpha)" 0
eq "M05-AC-3:STOP:beta-not-started" "$(newn beta)" 0
ok "M05-AC-3:STOP:no-loop-runs" sh -c "[ ! -e '$root/state/alpha/loop.pid' ] && [ ! -e '$root/state/beta/loop.pid' ]"
rm -f "$HOME/STOP"
watch 2
if [ "$(wrc 2)" = 0 ]; then waitheld "$root/state/alpha/loop.lock"; waitheld "$root/state/beta/loop.lock"; fi
eq "M05-AC-3:STOP-removed:alpha-started" "$(newn alpha)" 1
eq "M05-AC-3:STOP-removed:beta-started" "$(newn beta)" 1
endcase

echo "# M05-AC-3: ~/STOP-<name> stops the restart of that repository only"
newcase ac3-stopname alpha beta
touch "$HOME/STOP-alpha"
watch 1
if [ "$(wrc 1)" = 0 ]; then waitheld "$root/state/beta/loop.lock"; fi
eq "M05-AC-3:STOP-alpha:alpha-not-started" "$(newn alpha)" 0
eq "M05-AC-3:STOP-alpha:beta-started" "$(newn beta)" 1
ok "M05-AC-3:STOP-alpha:alpha-does-not-run" test ! -e "$root/state/alpha/loop.pid"
ok "M05-AC-3:STOP-alpha:beta-runs" held "$root/state/beta/loop.lock"
endcase

echo "# M05-AC-3: after loops.sh stop nothing is started until the next loops.sh start"
newcase ac3-stopped alpha beta
run start
eq "M05-AC-3:stopped:start-exits-0" "$(cat "$c/rc.start")" 0
run stop
eq "M05-AC-3:stopped:stop-exits-0" "$(cat "$c/rc.stop")" 0
ok "M05-AC-3:stopped:stop-writes-state-loops.stopped" test -e "$root/state/loops.stopped"
waitfree "$root/state/alpha/loop.lock"; waitfree "$root/state/beta/loop.lock"; waitfree "$root/api.lock"
if held "$root/state/alpha/loop.lock" || held "$root/state/beta/loop.lock"; then fail "M05-AC-3:stopped:the-loops-ended"; else pass "M05-AC-3:stopped:the-loops-ended"; fi
: >"$TMUXLOG"
watch 1
eq "M05-AC-3:stopped:watch-starts-nothing-at-all" "$(cnt "$TMUXLOG" '^new ')" 0
watch 2
eq "M05-AC-3:stopped:a-second-watch-starts-nothing-either" "$(cnt "$TMUXLOG" '^new ')" 0
run start
eq "M05-AC-3:stopped:start-after-stop-exits-0" "$(cat "$c/rc.start")" 0
ok "M05-AC-3:stopped:start-removes-state-loops.stopped" test ! -e "$root/state/loops.stopped"
die alpha
: >"$TMUXLOG"
watch 3
if [ "$(wrc 3)" = 0 ]; then waitheld "$root/state/alpha/loop.lock"; fi
eq "M05-AC-3:started-again:watch-restarts-alpha" "$(newn alpha)" 1
eq "M05-AC-3:started-again:watch-leaves-beta-alone" "$(newn beta)" 0
ok "M05-AC-3:started-again:alpha-runs" held "$root/state/alpha/loop.lock"
endcase

echo "# M05-AC-6: the loop and the API server that watch starts outlive the watch run and its killed process group"
newcase ac6 alpha
# the watch in a session and process group of its own; its pid file is the group's id
setsid -w sh -c 'echo $$ >"$1"; env -i HOME="$2" PATH="$3" NOODLEBOT_DATA="$4" TMUXLOG="$5" TMUXSTATE="$6" NB_FIXTURE_SH="$7" NB_TEST_SHELL="$8" sh "$9" watch >"${10}" 2>&1 </dev/null; echo $? >"${11}"' \
	sh "$c/pgid" "$HOME" "$bin:$tools" "$root" "$TMUXLOG" "$TMUXSTATE" "$NB_FIXTURE_SH" "$NB_TEST_SHELL" "$nb/scheduler/loops.sh" "$c/out.watch1" "$c/rc.watch1" &
sw=$!
i=0; while [ ! -s "$c/rc.watch1" ] && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i + 1)); done
wait $sw
pgid=$(cat "$c/pgid" 2>/dev/null)
case $pgid in '' | *[!0-9]*) fail "M05-AC-6:watch-group-id-known"; pgid=0 ;; *) pass "M05-AC-6:watch-group-id-known" ;; esac
[ "$pgid" -gt 1 ] && kill -s KILL -- "-$pgid" 2>/dev/null
i=0; while [ "$pgid" -gt 1 ] && kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
if [ "$(wrc 1)" = 0 ]; then waitheld "$root/state/alpha/loop.lock"; waitheld "$root/api.lock"; fi
eq "M05-AC-6:watch-started-the-loop" "$(newn alpha)" 1
eq "M05-AC-6:watch-started-the-api" "$(newn api)" 1
ok "M05-AC-6:loop-still-runs-after-the-group-kill" alive "$root/state/alpha/loop.pid"
ok "M05-AC-6:loop-still-holds-its-lock" held "$root/state/alpha/loop.lock"
ok "M05-AC-6:api-still-runs-after-the-group-kill" alive "$root/api.pid"
ok "M05-AC-6:api-still-holds-its-lock" held "$root/api.lock"
endcase

# ---- follow-up cases of the slice review (M05-AC-1, M05-AC-3) ----
# waitwaiter <lockfile>: up to 10 s for a process to wait for the lock (a "->" line for its inode in /proc/locks); when
# /proc/locks does not list the lock at all (a pid namespace), a second's wait instead
waitwaiter() {
	wi=$(stat -L -c %i "$1" 2>/dev/null); wn=0
	while [ "$wn" -lt 100 ]; do
		grep -qE -- "->.*:$wi( |\$)" /proc/locks 2>/dev/null && return 0
		grep -qE -- ":$wi( |\$)" /proc/locks 2>/dev/null || { [ "$wn" -ge 10 ] && return 0; }
		sleep 0.1; wn=$((wn + 1))
	done
	return 1
}
# waitfile <file>: up to 10 s for the file to exist
waitfile() { wn=0; while [ ! -e "$1" ] && [ "$wn" -lt 100 ]; do sleep 0.1; wn=$((wn + 1)); done; [ -e "$1" ]; }

# racecase <case> <stopped|STOP>: a watch blocked on state/watch.lock, then ~/STOP or state/loops.stopped appears, then the
# lock is released: the watch must start nothing
racecase() {
	rn=$1; rhow=$2
	echo "# M05-AC-3: $rhow written while a watch waits for state/watch.lock: nothing is started when it gets the lock"
	newcase "$rn" alpha beta
	mkdir -p "$root/state"
	fixture_start flock "$root/state/watch.lock" sh -c 'until [ -e "$1" ]; do sleep 0.1; done' sh "$c/release" </dev/null >/dev/null 2>&1 &
	waitheld "$root/state/watch.lock"
	watch r &
	rpw=$!
	if waitwaiter "$root/state/watch.lock"; then pass "M05-AC-3:$rhow-race:watch-waits-for-the-lock"; else fail "M05-AC-3:$rhow-race:watch-waits-for-the-lock"; fi
	case $rhow in
	stopped) : >"$root/state/loops.stopped" ;;
	STOP) touch "$HOME/STOP" ;;
	esac
	touch "$c/release"
	wait $rpw
	eq "M05-AC-3:$rhow-race:watch-exits-0" "$(wrc r)" 0
	eq "M05-AC-3:$rhow-race:no-tmux-new-at-all" "$(cnt "$TMUXLOG" '^new ')" 0
	ok "M05-AC-3:$rhow-race:no-loop-runs" sh -c "[ ! -e '$root/state/alpha/loop.pid' ] && [ ! -e '$root/state/beta/loop.pid' ] && [ ! -e '$root/api.pid' ]"
	eq "M05-AC-3:$rhow-race:no-restart-line" "$(cnt "$root/state/alpha/status.log" -i 'watch')" 0
	endcase
}
racecase ac3-race-stopped stopped
racecase ac3-race-STOP STOP

echo "# M05-AC-1: two watches at once both exit 0 at once, release state/watch.lock, and leave the loops and the API running"
newcase ac1-two-rc alpha beta
echo 1 >"$root/loop.delay"
( t0=$(date +%s); watch a; echo $(( $(date +%s) - t0 )) >"$c/secs.a" ) &
pa=$!
( t0=$(date +%s); watch b; echo $(( $(date +%s) - t0 )) >"$c/secs.b" ) &
pb=$!
wait $pa $pb
eq "M05-AC-1:two-rc:first-watch-exits-0" "$(wrc a)" 0
eq "M05-AC-1:two-rc:second-watch-exits-0" "$(wrc b)" 0
ok "M05-AC-1:two-rc:each-watch-returns-within-30-s" sh -c "[ \"\$(cat '$c/secs.a')\" -le 30 ] && [ \"\$(cat '$c/secs.b')\" -le 30 ]"
ok "M05-AC-1:two-rc:loops-and-api-run-when-the-watches-have-exited" sh -c "[ -s '$root/state/alpha/loop.pid' ] && [ -s '$root/state/beta/loop.pid' ] && [ -s '$root/api.pid' ]"
ok "M05-AC-1:two-rc:alpha-holds-its-lock" held "$root/state/alpha/loop.lock"
ok "M05-AC-1:two-rc:beta-holds-its-lock" held "$root/state/beta/loop.lock"
ok "M05-AC-1:two-rc:api-holds-its-lock" held "$root/api.lock"
if held "$root/state/watch.lock"; then fail "M05-AC-1:two-rc:watch.lock-is-free-after-the-watches-exited"; else pass "M05-AC-1:two-rc:watch.lock-is-free-after-the-watches-exited"; fi
endcase

echo "# M05-AC-1: watch returns only when what it started holds its lock (a loop that takes 2 s to take it)"
newcase ac1-waits alpha beta
echo 2 >"$root/loop.delay"
watch 1
eq "M05-AC-1:waits:watch-exits-0" "$(wrc 1)" 0
eq "M05-AC-1:waits:alpha-started" "$(newn alpha)" 1
ok "M05-AC-1:waits:alpha-holds-its-lock-when-watch-returns" held "$root/state/alpha/loop.lock"
ok "M05-AC-1:waits:beta-holds-its-lock-when-watch-returns" held "$root/state/beta/loop.lock"
ok "M05-AC-1:waits:api-holds-its-lock-when-watch-returns" held "$root/api.lock"
endcase

echo "# M05-AC-1: the API restarted by watch gets none of the loop settings"
newcase ac1-apienv alpha
cat >"$nb/scheduler/api.py" <<'EOT'
import fcntl, os, time
root = os.environ["NOODLEBOT_DATA"]
f = open(os.path.join(root, "api.lock"), "w")
fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
open(os.path.join(root, "api.env.tmp"), "w").write("".join(k + "=" + v + "\n" for k, v in sorted(os.environ.items())))
os.rename(os.path.join(root, "api.env.tmp"), os.path.join(root, "api.env"))
while not os.path.exists(os.path.join(root, "api.die")) and not os.path.exists(os.path.join(root, "die.all")):
    time.sleep(0.2)
EOT
run start SCHED_MAX=2 USAGE_7D_PACE=1
eq "M05-AC-1:apienv:start-exits-0" "$(cat "$c/rc.start")" 0
waitfile "$root/api.env"
ok "M05-AC-1:apienv:the-fake-api-saw-its-data-root" grep -qx "NOODLEBOT_DATA=$root" "$root/api.env"
diea
rm -f "$root/api.env"
watch 1
waitheld "$root/api.lock"
waitfile "$root/api.env"
eq "M05-AC-1:apienv:watch-restarted-the-api" "$(newn api)" 2
ok "M05-AC-1:apienv:the-restarted-api-has-its-data-root" grep -qx "NOODLEBOT_DATA=$root" "$root/api.env"
eq "M05-AC-1:apienv:no-SCHED_MAX-in-the-apis-environment" "$(cnt "$root/api.env" '^SCHED_MAX=')" 0
eq "M05-AC-1:apienv:no-loop-setting-at-all-in-the-apis-environment" "$(cnt "$root/api.env" -E '^(SCHED_|USAGE_|PICKUP)')" 0
endcase

echo "# M05-AC-1: a restarted loop has exactly the recorded settings (its own env.out); watch says nothing about the calling shell"
newcase ac1-envout alpha
run start SCHED_MAX=2 USAGE_7D_PACE=1
eq "M05-AC-1:envout:start-exits-0" "$(cat "$c/rc.start")" 0
die alpha
rm -f "$root/state/alpha/env.out"
watch 1
waitheld "$root/state/alpha/loop.lock"
waitfile "$root/state/alpha/env.out"
eq "M05-AC-1:envout:watch-restarted-alpha" "$(newn alpha)" 2
ok "M05-AC-1:envout:the-restarted-loop-wrote-env.out" test -s "$root/state/alpha/env.out"
ok "M05-AC-1:envout:the-restarted-loop-has-SCHED_MAX=2" grep -qx 'SCHED_MAX=2' "$root/state/alpha/env.out"
ok "M05-AC-1:envout:the-restarted-loop-has-USAGE_7D_PACE=1" grep -qx 'USAGE_7D_PACE=1' "$root/state/alpha/env.out"
eq "M05-AC-1:envout:the-restarted-loop-has-no-other-setting" "$(cnt "$root/state/alpha/env.out" -E '^(SCHED_|USAGE_|PICKUP)')" 2
eq "M05-AC-1:envout:watch-output-does-not-mention-the-calling-shell" "$(cnt "$c/out.watch1" -i 'calling shell')" 0
endcase

[ "$fails" = 0 ] || { echo "$fails failed"; exit 1; }
echo "all passed"
