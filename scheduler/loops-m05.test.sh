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

echo "# M05-AC-1: a restarted loop has exactly the recorded settings, whatever characters a value holds"
newcase ac1-chars alpha
# a tmux that runs its command as an argument vector, as tmux 3 does for several arguments (no shell sees the values)
cat >"$bin/tmux" <<'EOT'
#!/bin/sh
echo "$*" >>"$TMUXLOG"
case $1 in
new | new-session)
	shift
	while [ $# -gt 0 ]; do case $1 in -d) shift ;; -s) shift 2 ;; *) break ;; esac; done
	. "$NB_FIXTURE_SH"
	fixture_start "$@" >/dev/null 2>&1 </dev/null &
	exit 0 ;;
esac
echo "no server running" >&2
exit 1
EOT
chmod +x "$bin/tmux"
sx='a b $HOME "q" '"'"'s'"'"' *'
run start "SCHED_X=$sx" USAGE_7D_PACE=1
eq "M05-AC-1:chars:start-exits-0" "$(cat "$c/rc.start")" 0
lenv=$root/state/loops.env
eq "M05-AC-1:chars:loops.env-has-two-lines" "$(wc -l <"$lenv" 2>/dev/null | tr -d ' ')" 2
ok "M05-AC-1:chars:loops.env-holds-the-SCHED_X-line-byte-for-byte" grep -Fx -- "SCHED_X=$sx" "$lenv"
ok "M05-AC-1:chars:loops.env-holds-USAGE_7D_PACE=1" grep -Fx -- "USAGE_7D_PACE=1" "$lenv"
ok "M05-AC-1:chars:the-first-loop-has-the-SCHED_X-line-unchanged" grep -Fx -- "SCHED_X=$sx" "$root/state/alpha/env.out"
die alpha
rm -f "$root/state/alpha/env.out"
watch 1
waitheld "$root/state/alpha/loop.lock"
waitfile "$root/state/alpha/env.out"
eq "M05-AC-1:chars:watch-restarted-alpha" "$(newn alpha)" 2
ok "M05-AC-1:chars:the-restarted-loop-has-the-SCHED_X-line-unchanged" grep -Fx -- "SCHED_X=$sx" "$root/state/alpha/env.out"
ok "M05-AC-1:chars:the-restarted-loop-has-USAGE_7D_PACE=1" grep -Fx -- "USAGE_7D_PACE=1" "$root/state/alpha/env.out"
eq "M05-AC-1:chars:the-restarted-loop-has-no-other-setting" "$(cnt "$root/state/alpha/env.out" -E '^(SCHED_|USAGE_|PICKUP)')" 2
endcase

echo "# M05-AC-3: stop run while a watch is past its checks (loop and API take 2 s to take their locks): nothing is left running"
newcase ac3-inflight alpha
echo 2 >"$root/loop.delay"
watch 1 &
rpw=$!
wi=0
while [ "$wi" -lt 100 ] && { [ "$(newn alpha)" = 0 ] || [ "$(newn api)" = 0 ]; }; do sleep 0.1; wi=$((wi + 1)); done
eq "M05-AC-3:inflight:the-watch-started-the-loop-and-the-api" "$(newn alpha)$(newn api)" 11
run stop
wait $rpw
eq "M05-AC-3:inflight:stop-exits-0" "$(cat "$c/rc.stop" 2>/dev/null)" 0
ok "M05-AC-3:inflight:stop-writes-state-loops.stopped" test -e "$root/state/loops.stopped"
if held "$root/state/alpha/loop.lock"; then fail "M05-AC-3:inflight:no-loop-lock-held-once-stop-and-the-watch-have-returned"; else pass "M05-AC-3:inflight:no-loop-lock-held-once-stop-and-the-watch-have-returned"; fi
if held "$root/api.lock"; then fail "M05-AC-3:inflight:no-api-lock-held-once-stop-and-the-watch-have-returned"; else pass "M05-AC-3:inflight:no-api-lock-held-once-stop-and-the-watch-have-returned"; fi
sleep 2.5
if held "$root/state/alpha/loop.lock"; then fail "M05-AC-3:inflight:no-loop-lock-taken-within-the-delay-after-the-watch-returned"; else pass "M05-AC-3:inflight:no-loop-lock-taken-within-the-delay-after-the-watch-returned"; fi
if held "$root/api.lock"; then fail "M05-AC-3:inflight:no-api-lock-taken-within-the-delay-after-the-watch-returned"; else pass "M05-AC-3:inflight:no-api-lock-taken-within-the-delay-after-the-watch-returned"; fi
endcase


# ---- slice S2: the stale loop (M05-AC-2), watch-unit (M05-AC-5), and two follow-ups of the S1 review (M05-AC-1) ----
# Interface the tests give the implementation for a stale loop (M05-AC-2): a loop whose lock is held and whose heartbeat
# (state/<name>/heartbeat, epoch seconds) is older than LOOPS_STALE seconds (default 1800; older means a greater age) is
# never signalled. The watch writes one line to $root/state/watch.log, `<UTC stamp> loops.sh watch: <owner/name>: loop is
# stale (heartbeat <n> s old)`, and gets one comment posted on the repository's open log issue by report.py, which the
# watch calls itself (a hung loop runs no report.py): `python3 -I $nb/scheduler/report.py --repo <owner/name> --state
# $root/state/<name> --stale <n>` (<n> whole seconds), the forge reached as the loop's report does (NOODLEBOT_FORGE_REPO and
# NOODLEBOT_FORGE_TOKEN_SCRIPT=$HOME/.config/noodlebot/token exported). The comment names the loop (<name>) and holds
# `heartbeat <n> s old`. Once per stale episode: the watch keeps what it needs (not pinned) to post again only after a watch
# has seen the heartbeat fresh; a failed post leaves the watch.log line and puts one line on stderr, and the next watch posts.
# How many watch.log lines a repeated watch in one episode writes is not pinned.
unset LOOPS_STALE LOOPS_WATCH_EVERY
ln -s "$(command -v mkfifo)" "$tools/mkfifo" 2>/dev/null
# stalecase: the report tooling beside loops.sh, the fake gh on the case's PATH, a token script, no API, and a fake loop that
# traps every signal it can and records it in $root/signals
stalecase() {
	cp "$src"/*.py "$nb/scheduler/"; cp -R "$src/forges" "$nb/scheduler/forges"
	rm -f "$nb/scheduler/api.py"
	cp "$ubin/gh" "$bin/gh"
	cat >"$HOME/.config/noodlebot/token" <<EOT
#!/bin/sh
echo "\$*" >>"$c/token.calls"
echo tok
EOT
	chmod +x "$HOME/.config/noodlebot/token"
	cat >"$nb/scheduler/loop.sh" <<'EOT'
#!/bin/sh
name=${1#*/}
d=$NOODLEBOT_DATA/state/$name
mkdir -p "$d"
exec 9>"$d/loop.lock"
flock -n 9 || exit 1
sig=$NOODLEBOT_DATA/signals
trap 'echo TERM >>"$sig"' TERM
trap 'echo INT >>"$sig"' INT
trap 'echo HUP >>"$sig"' HUP
trap 'echo USR1 >>"$sig"' USR1
trap 'echo USR2 >>"$sig"' USR2
trap 'echo QUIT >>"$sig"' QUIT
echo $$ >"$d/loop.pid"
date +%s >"$d/heartbeat"
echo $$ >>"$d/starts"
while [ ! -e "$HOME/STOP-$name" ] && [ ! -e "$d/die" ] && [ ! -e "$NOODLEBOT_DATA/die.all" ]; do sleep 0.2; done
EOT
	chmod +x "$nb/scheduler/loop.sh"
}
# sethb <name> <age>: the loop's heartbeat is <age> seconds old
sethb() { hb=$(( $(date +%s) - $2 )); echo "$hb" >"$root/state/$1/heartbeat"; touch -d "@$hb" "$root/state/$1/heartbeat"; }
# loglines: the log issue's comments matching the regex (the shared fake forge's)
sc() { ucount "$lognum" "$1"; }
hbre='heartbeat [0-9]+ s old'
rm -f "$tmp/ufail"

echo "# M05-AC-2: a stale loop is never signalled; one watch.log line and one comment on the log issue per stale episode"
newcase ac2 alpha
stalecase
run start
eq "M05-AC-2:start-exits-0" "$(cat "$c/rc.start")" 0
waitheld "$root/state/alpha/loop.lock"
lpid=$(cat "$root/state/alpha/loop.pid" 2>/dev/null)
: >"$root/state/alpha/status.log"
urun "$root/state/alpha"
lognum=$(uq "[i['number'] for i in db['issues'].values() if i['title'].startswith('noodlebot log')][0]")
wl=$root/state/watch.log
re_a="(?s)(?=.*alpha)(?=.*$hbre)"
base_c=$(sc "$re_a")
sethb alpha 2000
watch 1
eq "M05-AC-2:stale:watch-exits-0" "$(wrc 1)" 0
eq "M05-AC-2:stale:the-loop-is-not-signalled" "$(cat "$root/signals" 2>/dev/null | tr '\n' ' ')" ""
eq "M05-AC-2:stale:the-loop-keeps-its-pid" "$(cat "$root/state/alpha/loop.pid" 2>/dev/null)" "$lpid"
ok "M05-AC-2:stale:the-loop-still-runs-and-holds-its-lock" held "$root/state/alpha/loop.lock"
eq "M05-AC-2:stale:the-loop-is-not-restarted-no-second-tmux-new" "$(newn alpha)" 1
eq "M05-AC-2:stale:one-watch.log-line" "$(wc -l <"$wl" 2>/dev/null | tr -d ' ')" 1
ok "M05-AC-2:stale:watch.log-line-begins-with-a-UTC-stamp-and-names-the-loop" grep -qE '^20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z .*alpha' "$wl"
age=$(sed -n 's/.*heartbeat \([0-9][0-9]*\) s old.*/\1/p' "$wl" 2>/dev/null | head -1)
ok "M05-AC-2:stale:watch.log-line-gives-the-heartbeat-age-in-seconds-2000-to-2200" test "${age:-0}" -ge 2000 -a "${age:-0}" -le 2200
eq "M05-AC-2:stale:one-comment-on-the-log-issue-naming-the-loop-and-the-age" "$(( $(sc "$re_a") - base_c ))" 1
cage=$(ulast "$lognum" | sed -n 's/.*heartbeat \([0-9][0-9]*\) s old.*/\1/p' | head -1)
ok "M05-AC-2:stale:the-comment-gives-the-heartbeat-age-in-seconds-2000-to-2200" test "${cage:-0}" -ge 2000 -a "${cage:-0}" -le 2200
ok "M05-AC-2:stale:the-token-script-ran-for-the-repository-as-in-a-loop" grep -q 'o/alpha' "$c/token.calls"
watch 2
eq "M05-AC-2:episode:a-second-watch-while-still-stale-posts-no-second-comment" "$(( $(sc "$re_a") - base_c ))" 1
eq "M05-AC-2:episode:still-no-signal" "$(cat "$root/signals" 2>/dev/null | tr '\n' ' ')" ""
sethb alpha 5
watch 3
eq "M05-AC-2:episode:a-watch-that-sees-the-heartbeat-fresh-posts-nothing" "$(( $(sc "$re_a") - base_c ))" 1
sethb alpha 2000
watch 4
eq "M05-AC-2:episode:stale-again-after-fresh-posts-one-more-comment-2-in-all" "$(( $(sc "$re_a") - base_c ))" 2
watch 5
eq "M05-AC-2:episode:and-only-one-for-that-episode" "$(( $(sc "$re_a") - base_c ))" 2
eq "M05-AC-2:episode:the-loop-was-never-signalled" "$(cat "$root/signals" 2>/dev/null | tr '\n' ' ')" ""
eq "M05-AC-2:episode:the-loop-keeps-its-pid" "$(cat "$root/state/alpha/loop.pid" 2>/dev/null)" "$lpid"
eq "M05-AC-2:episode:the-loop-was-never-restarted" "$(newn alpha)" 1
echo "# M05-AC-2: a failed post stays in watch.log and on stderr, and the next watch posts it"
sethb alpha 5
watch 6
sethb alpha 2000
l0=$(wc -l <"$wl" 2>/dev/null | tr -d ' ')
echo 'POST .*/comments' >"$tmp/ufail"
watch 7
rm -f "$tmp/ufail"
l1=$(wc -l <"$wl" 2>/dev/null | tr -d ' ')
ok "M05-AC-2:failed-post:the-line-is-in-watch.log" test "${l1:-0}" -gt "${l0:-0}"
eq "M05-AC-2:failed-post:no-comment-was-posted" "$(( $(sc "$re_a") - base_c ))" 2
ok "M05-AC-2:failed-post:one-line-on-stderr-naming-the-loop" grep -q 'alpha' "$c/out.watch7"
watch 8
eq "M05-AC-2:failed-post:the-next-watch-posts-it" "$(( $(sc "$re_a") - base_c ))" 3
eq "M05-AC-2:failed-post:the-loop-was-never-signalled" "$(cat "$root/signals" 2>/dev/null | tr '\n' ' ')" ""
endcase

echo "# M05-AC-2: LOOPS_STALE defaults to 1800 s: a heartbeat 1700 s old is not stale, 1900 s old is"
newcase ac2-def alpha beta
stalecase
run start
waitheld "$root/state/alpha/loop.lock"; waitheld "$root/state/beta/loop.lock"
wl=$root/state/watch.log
re_a="(?s)(?=.*alpha)(?=.*$hbre)"
re_b="(?s)(?=.*beta)(?=.*$hbre)"
base_a=$(sc "$re_a"); base_b=$(sc "$re_b")
sethb alpha 1700; sethb beta 1900
watch 1
eq "M05-AC-2:default:watch-exits-0" "$(wrc 1)" 0
eq "M05-AC-2:default:one-watch.log-line-in-all" "$(wc -l <"$wl" 2>/dev/null | tr -d ' ')" 1
ok "M05-AC-2:default:the-line-names-the-loop-1900-s-old" grep -q 'beta' "$root/state/watch.log"
eq "M05-AC-2:default:no-line-for-the-loop-1700-s-old" "$(cnt "$root/state/watch.log" alpha)" 0
eq "M05-AC-2:default:no-comment-for-the-loop-1700-s-old" "$(( $(sc "$re_a") - base_a ))" 0
eq "M05-AC-2:default:one-comment-for-the-loop-1900-s-old" "$(( $(sc "$re_b") - base_b ))" 1
eq "M05-AC-2:default:no-loop-is-signalled" "$(cat "$root/signals" 2>/dev/null | tr '\n' ' ')" ""
wenv LOOPS_STALE=1000 timeout 60 sh "$nb/scheduler/loops.sh" watch >"$c/out.watchL" 2>&1 </dev/null
eq "M05-AC-2:LOOPS_STALE=1000:the-loop-1700-s-old-is-stale-one-comment" "$(( $(sc "$re_a") - base_a ))" 1
eq "M05-AC-2:LOOPS_STALE=1000:the-loop-already-reported-this-episode-gets-no-second" "$(( $(sc "$re_b") - base_b ))" 1
eq "M05-AC-2:LOOPS_STALE=1000:no-loop-is-signalled" "$(cat "$root/signals" 2>/dev/null | tr '\n' ' ')" ""
endcase

echo "# M05-AC-5: watch-unit prints the system service and timer and the commands that install them; calls nothing, writes nothing"
# uhas <file> <section> <line>: the section holds the line exactly
uhas() { W=$3 S="[$2]" awk 'BEGIN { w = ENVIRON["W"]; s = ENVIRON["S"] } /^\[/ { cur = $0 } cur == s && $0 == w { f = 1 } END { exit !f }' "$1"; }
# uenv <file> <VAR=value>: Environment=VAR=value or Environment="VAR=value" in [Service]
uenv() { uhas "$1" Service "Environment=$2" || uhas "$1" Service "Environment=\"$2\""; }
lst() { find "$HOME" "$root" -printf '%p %s %T@\n' | sort; }
newcase ac5 alpha
for t in systemctl systemd-run sudo; do
	printf '#!/bin/sh\necho "%s $*" >>"%s"\nexit 0\n' "$t" "$c/calls" >"$bin/$t"
	chmod +x "$bin/$t"
done
: >"$c/calls"
wu_user=$(id -un); wu_uid=$(id -u)
wu_exec=$(cd "$nb/scheduler" && pwd -P)/loops.sh
wu_root=$(cd "$root" && pwd -P)
wu_check() { # <tag> <every> <extra VAR=value...>
	wt=$1 we=$2; shift 2
	before=$(lst)
	run watch-unit "$@"
	cp "$c/out.watch-unit" "$c/out.wu.$wt"
	o=$c/out.wu.$wt
	after=$(lst)
	eq "M05-AC-5:$wt:exits-0" "$(cat "$c/rc.watch-unit")" 0
	ok "M05-AC-5:$wt:names-noodlebot-watch.service" grep -q 'noodlebot-watch\.service' "$o"
	ok "M05-AC-5:$wt:service-Type=oneshot" uhas "$o" Service "Type=oneshot"
	ok "M05-AC-5:$wt:service-User=the-calling-user" uhas "$o" Service "User=$wu_user"
	ok "M05-AC-5:$wt:service-ExecStart=this-checkouts-loops.sh-watch" uhas "$o" Service "ExecStart=$wu_exec watch"
	ok "M05-AC-5:$wt:service-Environment-HOME" uenv "$o" "HOME=$HOME"
	ok "M05-AC-5:$wt:service-Environment-NOODLEBOT_DATA-the-resolved-root" uenv "$o" "NOODLEBOT_DATA=$wu_root"
	ok "M05-AC-5:$wt:service-Environment-PATH-the-calling-PATH" uenv "$o" "PATH=$bin:$tools"
	ok "M05-AC-5:$wt:service-Environment-XDG_RUNTIME_DIR" uenv "$o" "XDG_RUNTIME_DIR=/run/user/$wu_uid"
	ok "M05-AC-5:$wt:service-KillMode=process" uhas "$o" Service "KillMode=process"
	ok "M05-AC-5:$wt:names-noodlebot-watch.timer" grep -q 'noodlebot-watch\.timer' "$o"
	ok "M05-AC-5:$wt:timer-OnBootSec=$we" uhas "$o" Timer "OnBootSec=$we"
	ok "M05-AC-5:$wt:timer-OnUnitActiveSec=$we" uhas "$o" Timer "OnUnitActiveSec=$we"
	ok "M05-AC-5:$wt:timer-WantedBy=timers.target" uhas "$o" Install "WantedBy=timers.target"
	ok "M05-AC-5:$wt:install-commands-name-sudo-and-etc-systemd-system" grep -qE 'sudo.*/etc/systemd/system|/etc/systemd/system.*sudo' "$o"
	ok "M05-AC-5:$wt:install-commands-enable-the-timer-with-systemctl" grep -qE 'systemctl.*enable.*noodlebot-watch\.timer' "$o"
	if [ -s "$c/calls" ]; then fail "M05-AC-5:$wt:calls-no-systemctl-systemd-run-or-sudo"; else pass "M05-AC-5:$wt:calls-no-systemctl-systemd-run-or-sudo"; fi
	if [ "$before" = "$after" ]; then pass "M05-AC-5:$wt:writes-no-file-HOME-and-runtime-root-unchanged"; else fail "M05-AC-5:$wt:writes-no-file-HOME-and-runtime-root-unchanged"; fi
}
wu_check default 5min
wu_check every-2min 2min LOOPS_WATCH_EVERY=2min
endcase

echo "# M05-AC-1: watch does not run unlocked when it cannot open state/watch.lock"
newcase ac1-lockdir alpha
mkdir -p "$root/state/watch.lock"
: >"$root/state/loops.env"
watch 1
ok "M05-AC-1:lock-cannot-be-opened:watch-exits-non-zero" test "$(wrc 1)" != 0 -a "$(wrc 1)" != none
eq "M05-AC-1:lock-cannot-be-opened:no-tmux-new" "$(cnt "$TMUXLOG" '^new ')" 0
ok "M05-AC-1:lock-cannot-be-opened:no-loop-runs" test ! -e "$root/state/alpha/loop.pid"
endcase

# ---- follow-up cases of the S2 review (M05-AC-5, M05-AC-2) ----
# Interface the tests give the implementation for the install commands (M05-AC-5): `watch-unit` prints each unit's text
# after a comment line `# /etc/systemd/system/<file>`; the text runs to the next line beginning `#` or `sudo `, without
# the empty lines at its end;
# the install commands are every line from the first one beginning `sudo ` to the end of the output, and form a
# self-contained sh script: one `sudo tee /etc/systemd/system/<file> >/dev/null <<'EOF'` ... `EOF` here-document per unit
# holding exactly that unit's text, then `sudo systemctl daemon-reload` and `sudo systemctl enable --now
# noodlebot-watch.timer`. The case runs them under sh with a fake sudo first on PATH that logs its arguments and writes
# the stdin of `tee <file>` to a scratch copy of the file; nothing real is reached.
# Values for systemd (M05-AC-5): in the service, a value that needs it is quoted as systemd does: `Environment="K=V"`
# with `\` as `\\`, `"` as `\"` and `%` as `%%`; `ExecStart="<path>" watch` the same and `$` as `$$`. An ordinary path is
# not pinned either way (the frozen check takes it unquoted).
echo "# M05-AC-5: the printed install commands, run under sh with a fake sudo, install exactly the printed units and enable the timer"
# unit_text <printed output> <file>: the text printed for /etc/systemd/system/<file> (see above)
unit_text() { awk -v h="# /etc/systemd/system/$2" '$0 == h { f = 1; next } f && (/^#/ || /^sudo /) { exit } f { l[++n] = $0 }
	END { while (n > 0 && l[n] == "") n--; for (i = 1; i <= n; i++) print l[i] }' "$1"; }
newcase ac5-install alpha
mkdir -p "$c/sbin" "$c/etc" "$c/work"
cat >"$c/sbin/sudo" <<'EOT'
#!/bin/sh
# logs its arguments; `tee <file>...` writes its stdin to the files under $FAKE_ETC; runs nothing
echo "$*" >>"$SUDOLOG"
case $1 in
tee)
	shift
	cat >"$FAKE_ETC/.in"
	for f; do
		case $f in
		-*) ;;
		/etc/systemd/system/*) cp "$FAKE_ETC/.in" "$FAKE_ETC/${f#/etc/systemd/system/}" ;;
		*) echo "fake sudo: tee outside /etc/systemd/system: $f" >&2; exit 1 ;;
		esac
	done ;;
esac
exit 0
EOT
chmod +x "$c/sbin/sudo"
run watch-unit
awk '/^sudo / { f = 1 } f' "$c/out.watch-unit" >"$c/work/install.sh"
ok "M05-AC-5:install:the-output-holds-install-commands-from-a-sudo-line" test -s "$c/work/install.sh"
(cd "$c/work" && env -i PATH="$c/sbin:$tools" SUDOLOG="$c/sudo.log" FAKE_ETC="$c/etc" sh "$c/work/install.sh" >"$c/work/install.out" 2>&1 </dev/null)
eq "M05-AC-5:install:the-block-runs-under-sh-exit-0" "$?" 0
for uf in service timer; do
	eq "M05-AC-5:install:noodlebot-watch.$uf-written-equals-the-printed-unit-text" "$(cat "$c/etc/noodlebot-watch.$uf" 2>/dev/null | tr '\n' '~'; echo x)" "$(unit_text "$c/out.watch-unit" "noodlebot-watch.$uf" | tr '\n' '~'; echo x)"
	ok "M05-AC-5:install:the-printed-noodlebot-watch.$uf-text-is-not-empty" test -n "$(unit_text "$c/out.watch-unit" "noodlebot-watch.$uf")"
done
n1=$(grep -n '^systemctl daemon-reload$' "$c/sudo.log" 2>/dev/null | cut -d: -f1 | head -1)
n2=$(grep -n '^systemctl enable --now noodlebot-watch\.timer$' "$c/sudo.log" 2>/dev/null | cut -d: -f1 | head -1)
ok "M05-AC-5:install:daemon-reload-then-enable-now-the-timer-through-sudo-in-that-order" test "${n1:-0}" -gt 0 -a "${n2:-0}" -gt "${n1:-0}"
endcase

echo "# M05-AC-5: a HOME, runtime root, checkout and PATH entry with a space and a % are quoted and escaped for systemd"
# sdenv <file> <K=V>: a quoted Environment="..." line of [Service] decodes (\\ \" %%) to K=V
sdenv() { awk 'function dec(s,   o, i, ch, nx) { o = ""; i = 1
		while (i <= length(s)) { ch = substr(s, i, 1); nx = substr(s, i + 1, 1)
			if (ch == "\\" && (nx == "\\" || nx == "\"")) { o = o nx; i += 2 } else if (ch == "%" && nx == "%") { o = o "%"; i += 2 } else { o = o ch; i++ } }
		return o }
	/^\[/ { cur = $0 } cur == "[Service]" && index($0, "Environment=\"") == 1 && substr($0, length($0), 1) == "\"" { print dec(substr($0, 14, length($0) - 14)) }' "$1" | grep -qxF -- "$2"; }
# sdexec <file>: the decoded quoted word of ExecStart="..." (\\ \" %% $$), then the rest of the line
sdexec() { awk 'function dec(s,   o, i, ch, nx) { o = ""; i = 1
		while (i <= length(s)) { ch = substr(s, i, 1); nx = substr(s, i + 1, 1)
			if (ch == "\\" && (nx == "\\" || nx == "\"")) { o = o nx; i += 2 } else if (ch == "%" && nx == "%") { o = o "%"; i += 2 } else if (ch == "$" && nx == "$") { o = o "$"; i += 2 } else { o = o ch; i++ } }
		return o }
	/^\[/ { cur = $0 }
	cur == "[Service]" && index($0, "ExecStart=\"") == 1 { raw = ""; i = 12
		while (i <= length($0)) { ch = substr($0, i, 1); if (ch == "\\") { raw = raw substr($0, i, 2); i += 2; continue } if (ch == "\"") break; raw = raw ch; i++ }
		print dec(raw); print substr($0, i + 1) }' "$1"; }
newcase ac5-quote alpha
qh="$c/h o%Zme"; qr="$c/r oot%Zd"; qn="$c/n b%Z1"; qp="$c/p ath%Zd"
mkdir -p "$qh" "$qr" "$qn/scheduler" "$qp"
cp "$src/loops.sh" "$qn/scheduler/"; chmod +x "$qn/scheduler/loops.sh"
nb=$qn
run watch-unit HOME="$qh" NOODLEBOT_DATA="$qr" PATH="$qp:$bin:$tools"
unit_text "$c/out.watch-unit" noodlebot-watch.service >"$c/svc.txt"
o=$c/svc.txt
eq "M05-AC-5:quote:exits-0" "$(cat "$c/rc.watch-unit")" 0
q_root=$(cd "$qr" && pwd -P); q_exec=$(cd "$qn/scheduler" && pwd -P)/loops.sh
ok "M05-AC-5:quote:Environment-HOME-quoted-and-decodes-exact" sdenv "$o" "HOME=$qh"
ok "M05-AC-5:quote:Environment-NOODLEBOT_DATA-quoted-and-decodes-exact" sdenv "$o" "NOODLEBOT_DATA=$q_root"
ok "M05-AC-5:quote:Environment-PATH-quoted-and-decodes-exact" sdenv "$o" "PATH=$qp:$bin:$tools"
eq "M05-AC-5:quote:ExecStart-decodes-to-the-checkouts-loops.sh-then-watch" "$(sdexec "$o" | tr '\n' '|')" "$q_exec| watch|"
eq "M05-AC-5:quote:one-ExecStart-line" "$(cnt "$o" '^ExecStart=')" 1
mkdir -p "$c/verify-ok"
printf '[Service]\nType=oneshot\nExecStart=/bin/true\n' >"$c/verify-ok/ok.service"
if ! command -v systemd-analyze >/dev/null 2>&1; then
	echo "SKIP: M05-AC-5:quote:systemd-analyze-verify-accepts-the-units (systemd-analyze is not installed)"
elif ! (cd "$c/verify-ok" && timeout 30 systemd-analyze verify "$c/verify-ok/ok.service" >/dev/null 2>&1 </dev/null); then
	echo "SKIP: M05-AC-5:quote:systemd-analyze-verify-accepts-the-units (systemd-analyze verify does not run here, not even on a trivial unit)"
else
	mkdir -p "$c/verify"
	cp "$o" "$c/verify/noodlebot-watch.service"
	unit_text "$c/out.watch-unit" noodlebot-watch.timer >"$c/verify/noodlebot-watch.timer"
	if (cd "$c/verify" && timeout 30 systemd-analyze verify "$c/verify/noodlebot-watch.service" "$c/verify/noodlebot-watch.timer" >"$c/verify.out" 2>&1 </dev/null); then
		pass "M05-AC-5:quote:systemd-analyze-verify-accepts-the-units"
	else
		fail "M05-AC-5:quote:systemd-analyze-verify-accepts-the-units ($(head -c 300 "$c/verify.out" | tr '\n' ' '))"
	fi
fi
endcase

echo "# M05-AC-2: a stale loop is not touched through tmux either, and its comment carries the bot's signature"
newcase ac2-tmux alpha
stalecase
cp "$src/version.sh" "$nb/scheduler/"
run start
waitheld "$root/state/alpha/loop.lock"
: >"$root/state/alpha/status.log"
urun "$root/state/alpha"
lognum=$(uq "[i['number'] for i in db['issues'].values() if i['title'].startswith('noodlebot log')][0]")
re_a="(?s)(?=.*alpha)(?=.*$hbre)"
base_c=$(sc "$re_a")
sethb alpha 2000
watch 1
eq "M05-AC-2:tmux:the-stale-comment-was-posted" "$(( $(sc "$re_a") - base_c ))" 1
eq "M05-AC-2:tmux:no-kill-send-keys-or-respawn-call-to-tmux" "$(cnt "$TMUXLOG" -E '^(kill|send|respawn)')" 0
eq "M05-AC-2:tmux:no-second-tmux-new" "$(newn alpha)" 1
sig_last() { ulast "$lognum" | awk 'NF { l = $0 } END { print l }'; }
ok "M05-AC-2:signature:the-stale-comment-ends-with-a-line-starting-n00dl3b0t-signature" sh -c 'case $1 in "— n00dl3b0t"*) exit 0 ;; *) exit 1 ;; esac' sh "$(sig_last)"
endcase

# ---- slice S3 (M05-AC-4: the user timer and the watch line of status; follow-ups of the S2 review) ----
# Correction of the comment on the quoting rules above: in ExecStart the path is not an argument, so systemd does not
# substitute `$` in it and the path's `$` stays a single `$` (only `%` is doubled, and the path quoted when it needs it);
# `$$` belongs to arguments only. A checkout path holding `"`, `'`, `\` or a control character is refused instead of quoted.
# Interfaces the tests give the implementation (M05-AC-4), with the units file present:
#   start calls, for the timer, `systemd-run --user --unit noodlebot-watch --on-active=<E> --on-unit-active=<E>
#   --property=KillMode=process <checkout>/scheduler/loops.sh watch` (<E> = LOOPS_WATCH_EVERY, default 5min), once, when
#   `systemctl --user is-active noodlebot-watch.timer` prints a state other than `active`; stop calls
#   `systemctl --user stop noodlebot-watch.timer`; status prints one more line, which names `watch` and, as whole words,
#   `system` and/or `user` for the active watch timers (read with `systemctl [--user] is-active noodlebot-watch.timer`,
#   which the fake answers from $c/sys.state and $c/user.state) or `none` for neither, never `api`.
# The fake systemd-run logs "$*" to $SDRLOG and runs nothing for the timer (a call naming noodlebot-watch), and
# execs the command after its options otherwise (the tmux of M04's scope call); the fake systemctl logs "$*" to $SCTLLOG.
ac4_fakes() { # <yes|no>: the fake systemd-run, and the fake systemctl when $1 is yes; the units file is made
	: >"$HOME/.config/noodlebot/units"
	SDRLOG=$c/sdr.log SCTLLOG=$c/sctl.log SCTLDIR=$c
	export SDRLOG SCTLLOG SCTLDIR
	: >"$SDRLOG"; : >"$SCTLLOG"
	cat >"$bin/systemd-run" <<'EOT'
#!/bin/sh
echo "$*" >>"$SDRLOG"
case " $* " in *noodlebot-watch*) exit 0 ;; esac
while [ $# -gt 0 ]; do
	case $1 in
	--unit | -u | --description | --slice | -p | --property) shift 2 ;;
	-*) shift ;;
	*) break ;;
	esac
done
exec "$@"
EOT
	chmod +x "$bin/systemd-run"
	[ "$1" = yes ] || return 0
	cat >"$bin/systemctl" <<'EOT'
#!/bin/sh
echo "$*" >>"$SCTLLOG"
u=0 ia=0 q=0
for a in "$@"; do
	case $a in --user) u=1 ;; is-active) ia=1 ;; -q | --quiet) q=1 ;; esac
done
if [ $ia = 1 ]; then
	if [ $u = 1 ]; then f=$SCTLDIR/user.state; else f=$SCTLDIR/sys.state; fi
	s=$(cat "$f" 2>/dev/null)
	if [ -z "$s" ]; then echo "Failed to connect to bus" >&2; exit 1; fi
	[ $q = 1 ] || echo "$s"
	[ "$s" = active ]
	exit $?
fi
exit 0
EOT
	chmod +x "$bin/systemctl"
}
# st_check <tag> <system state> <user state> <system|user|none>: status with those watch timers active
st_check() {
	echo "$2" >"$c/sys.state"; echo "$3" >"$c/user.state"; : >"$SDRLOG"; : >"$SCTLLOG"
	run status
	o=$c/out.status
	extra=$(grep -vxFf "$c/exp.status" "$o")
	eq "M05-AC-4:$1:status-prints-the-three-lines-of-today-and-one-more" "$(wc -l <"$o" | tr -d ' ')" 3
	eq "M05-AC-4:$1:status-keeps-the-lines-of-today-and-adds-one" "$(grep -cxFf "$c/exp.status" "$o")" 2
	ok "M05-AC-4:$1:the-watch-line-names-the-watch" sh -c "printf '%s\n' \"\$1\" | grep -qi watch" sh "$extra"
	ok "M05-AC-4:$1:the-watch-line-never-contains-api" sh -c "! printf '%s\n' \"\$1\" | grep -qi api" sh "$extra"
	case $4 in
	system) ok "M05-AC-4:$1:the-watch-line-names-the-system-timer-only" sh -c "printf '%s\n' \"\$1\" | grep -qiw system && ! printf '%s\n' \"\$1\" | grep -qiw -e user -e none" sh "$extra" ;;
	user) ok "M05-AC-4:$1:the-watch-line-names-the-user-timer-only" sh -c "printf '%s\n' \"\$1\" | grep -qiw user && ! printf '%s\n' \"\$1\" | grep -qiw -e system -e none" sh "$extra" ;;
	none) ok "M05-AC-4:$1:the-watch-line-says-none" sh -c "printf '%s\n' \"\$1\" | grep -qiw none && ! printf '%s\n' \"\$1\" | grep -qiw -e system -e user" sh "$extra" ;;
	esac
	eq "M05-AC-4:$1:status-calls-no-systemd-run" "$(cnt "$SDRLOG" '')" 0
	eq "M05-AC-4:$1:status-calls-systemctl-only-to-read-is-active" "$(cnt "$SCTLLOG" -vE '^(--user )?is-active ')" 0
}

echo "# M05-AC-4: units on, systemctl --user answering: start sets up the user timer unless active, stop stops it, status names the watch timers"
newcase ac4 alpha
ac4_fakes yes
echo inactive >"$c/user.state"; echo inactive >"$c/sys.state"
nbp=$(cd "$nb" && pwd -P)
printf '%s\n%s\n' "o/alpha: loop running; sessions: none; waiting on you: nothing" "api: server running; socket $root/api.sock" >"$c/exp.status"
run start
eq "M05-AC-4:start-exits-0" "$(cat "$c/rc.start")" 0
eq "M05-AC-4:inactive:start-makes-one-systemd-run-call-for-the-timer" "$(cnt "$SDRLOG" noodlebot-watch)" 1
tl=$(grep noodlebot-watch "$SDRLOG" | head -1)
eq "M05-AC-4:inactive:the-timer-call-is-the-exact-one-with-the-default-5min" "$tl" "--user --unit noodlebot-watch --on-active=5min --on-unit-active=5min --property=KillMode=process $nbp/scheduler/loops.sh watch"
: >"$SDRLOG"
run start LOOPS_WATCH_EVERY=2min
eq "M05-AC-4:every:start-makes-one-timer-call" "$(cnt "$SDRLOG" noodlebot-watch)" 1
tl=$(grep noodlebot-watch "$SDRLOG" | head -1)
eq "M05-AC-4:every:the-timer-call-has-LOOPS_WATCH_EVERY-twice" "$tl" "--user --unit noodlebot-watch --on-active=2min --on-unit-active=2min --property=KillMode=process $nbp/scheduler/loops.sh watch"
echo active >"$c/user.state"; : >"$SDRLOG"
run start
eq "M05-AC-4:active:start-makes-no-timer-call-when-the-timer-is-active" "$(cnt "$SDRLOG" noodlebot-watch)" 0
waitheld "$root/state/alpha/loop.lock"; waitheld "$root/api.lock"
st_check status-system active inactive system
st_check status-user inactive active user
st_check status-none inactive inactive none
echo "# M05-AC-4: units off: no timer call, status exactly as today, stop calls no systemctl"
rm -f "$HOME/.config/noodlebot/units"
echo inactive >"$c/user.state"; : >"$SDRLOG"; : >"$SCTLLOG"
run start
eq "M05-AC-4:off:start-makes-no-timer-call" "$(cnt "$SDRLOG" noodlebot-watch)" 0
eq "M05-AC-4:off:start-makes-no-systemd-run-call-at-all" "$(cnt "$SDRLOG" '')" 0
run status
eq "M05-AC-4:off:status-prints-exactly-what-it-prints-today" "$(cat "$c/out.status")" "$(cat "$c/exp.status")"
eq "M05-AC-4:off:status-has-no-watch-line" "$(cnt "$c/out.status" -i watch)" 0
: >"$SCTLLOG"
run stop
eq "M05-AC-4:off:stop-makes-no-systemctl-call-for-the-timer" "$(cnt "$SCTLLOG" -i noodlebot-watch)" 0
echo "# M05-AC-4: units on again: stop stops the user timer"
: >"$HOME/.config/noodlebot/units"
echo active >"$c/user.state"; : >"$SCTLLOG"
run stop
eq "M05-AC-4:stop:exits-0" "$(cat "$c/rc.stop")" 0
eq "M05-AC-4:stop:calls-systemctl-user-stop-noodlebot-watch.timer-once" "$(cnt "$SCTLLOG" -Fx -- '--user stop noodlebot-watch.timer')" 1
endcase

echo "# M05-AC-4: units on, no systemctl on PATH: no timer call, nothing new printed, status says none"
newcase ac4-noctl alpha
ac4_fakes no
run start
eq "M05-AC-4:no-systemctl:start-exits-0" "$(cat "$c/rc.start")" 0
eq "M05-AC-4:no-systemctl:start-makes-no-timer-call" "$(cnt "$SDRLOG" noodlebot-watch)" 0
eq "M05-AC-4:no-systemctl:start-prints-nothing-about-a-timer" "$(cnt "$c/out.start" -iE 'watch|timer')" 0
sort "$c/out.start" >"$base/ac4-noctl.start"
waitheld "$root/state/alpha/loop.lock"; waitheld "$root/api.lock"
printf '%s\n%s\n' "o/alpha: loop running; sessions: none; waiting on you: nothing" "api: server running; socket $root/api.sock" >"$c/exp.status"
run status
extra=$(grep -vxFf "$c/exp.status" "$c/out.status")
eq "M05-AC-4:no-systemctl:status-has-one-more-line-than-today" "$(wc -l <"$c/out.status" | tr -d ' ')" 3
ok "M05-AC-4:no-systemctl:the-watch-line-says-none" sh -c "printf '%s\n' \"\$1\" | grep -qi watch && printf '%s\n' \"\$1\" | grep -qiw none && ! printf '%s\n' \"\$1\" | grep -qi api" sh "$extra"
run stop
eq "M05-AC-4:no-systemctl:stop-exits-0" "$(cat "$c/rc.stop")" 0
eq "M05-AC-4:no-systemctl:stop-prints-nothing-about-a-timer" "$(cnt "$c/out.stop" -iE 'watch|timer')" 0
endcase

echo "# M05-AC-4: units on, systemctl --user prints no state: no timer call, nothing new printed, stop calls no systemctl"
newcase ac4-silent alpha
ac4_fakes yes
run start
eq "M05-AC-4:no-state:start-exits-0" "$(cat "$c/rc.start")" 0
eq "M05-AC-4:no-state:start-makes-no-timer-call" "$(cnt "$SDRLOG" noodlebot-watch)" 0
eq "M05-AC-4:no-state:start-prints-what-it-prints-without-systemctl" "$(sort "$c/out.start")" "$(cat "$base/ac4-noctl.start")"
: >"$SCTLLOG"
run stop
eq "M05-AC-4:no-state:stop-exits-0" "$(cat "$c/rc.stop")" 0
eq "M05-AC-4:no-state:stop-makes-no-systemctl-call-for-the-timer" "$(cnt "$SCTLLOG" -i stop)" 0
eq "M05-AC-4:no-state:stop-prints-nothing-about-a-timer" "$(cnt "$c/out.stop" -iE 'watch|timer')" 0
endcase

echo "# M05-AC-5: watch-unit refuses a checkout path with a quote, backslash or control character: one stderr line, exit 1, no unit"
wu_refuse() { # <tag> <directory name>
	d=$c/$2
	mkdir -p "$d/scheduler" && cp "$src/loops.sh" "$d/scheduler/"
	env -u TMUX PATH="$bin:$tools" sh "$d/scheduler/loops.sh" watch-unit >"$c/rf.out" 2>"$c/rf.err" </dev/null
	eq "M05-AC-5:refuse-$1:exits-1" "$?" 1
	eq "M05-AC-5:refuse-$1:prints-no-unit" "$(wc -c <"$c/rf.out" | tr -d ' ')" 0
	eq "M05-AC-5:refuse-$1:one-stderr-line" "$(wc -l <"$c/rf.err" | tr -d ' ')" 1
}
newcase ac5-refuse alpha
wu_refuse dquote 'q"q'
wu_refuse squote "q'q"
wu_refuse backslash 'q\q'
wu_refuse tab "$(printf 'q\tq')"
wu_refuse control "$(printf 'q\001q')"
endcase

echo "# M05-AC-5: a \$ in the checkout path stays one \$ in ExecStart (systemd substitutes it in arguments only); % is doubled"
newcase ac5-dollar alpha
for v in plain quoted; do
	case $v in plain) dn='d$Z%Zb' ;; quoted) dn='d $Z%Zb' ;; esac
	d=$c/$dn
	mkdir -p "$d/scheduler" && cp "$src/loops.sh" "$d/scheduler/"
	env -u TMUX PATH="$bin:$tools" sh "$d/scheduler/loops.sh" watch-unit >"$c/dl.out" 2>/dev/null </dev/null
	dp=$(cd "$d/scheduler" && pwd -P)/loops.sh
	dp=$(printf '%s' "$dp" | sed 's/%/%%/g')
	case $v in plain) want="ExecStart=$dp watch" ;; quoted) want="ExecStart=\"$dp\" watch" ;; esac
	eq "M05-AC-5:dollar-$v:ExecStart-has-a-single-dollar-and-doubled-percent" "$(grep '^ExecStart=' "$c/dl.out" | sort -u)" "$want"
done
endcase

echo "# M05-AC-5: a % in an Environment= value is written %% (systemd would read a specifier)"
newcase ac5-percent alpha
ph=$c/h%Zx
mkdir -p "$ph"
run watch-unit HOME="$ph"
eq "M05-AC-5:percent:exits-0" "$(cat "$c/rc.watch-unit")" 0
penv=$(grep '^Environment=' "$c/out.watch-unit" | sed 's/%%//g')
eq "M05-AC-5:percent:no-single-percent-in-the-Environment-lines" "$(printf '%s\n' "$penv" | grep -c '%')" 0
ok "M05-AC-5:percent:HOME-is-written-with-a-doubled-percent" grep -qF "$(printf '%s' "$ph" | sed 's/%/%%/g')" "$c/out.watch-unit"
endcase

echo "# M05-AC-2: a stale loop and no open log issue: one stderr line, no traceback, the watch.log line, and the next watch posts once an issue is open"
newcase ac2-nolog alpha
stalecase
run start
waitheld "$root/state/alpha/loop.lock"
pyc "
import json
db = json.load(open('$udb'))
for i in db['issues'].values():
    if i['title'].startswith('noodlebot log'): i['state'] = 'closed'
json.dump(db, open('$udb', 'w'))"
sethb alpha 2000
watch 1
eq "M05-AC-2:no-log-issue:no-traceback-in-the-output" "$(cnt "$c/out.watch1" -E 'Traceback|^  File ')" 0
eq "M05-AC-2:no-log-issue:the-output-is-one-line" "$(wc -l <"$c/out.watch1" | tr -d ' ')" 1
ok "M05-AC-2:no-log-issue:the-line-names-the-loop" grep -q alpha "$c/out.watch1"
eq "M05-AC-2:no-log-issue:the-watch.log-line-is-there" "$(cnt "$root/state/watch.log" alpha)" 1
eq "M05-AC-2:no-log-issue:the-loop-is-not-signalled" "$(cat "$root/signals" 2>/dev/null | tr '\n' ' ')" ""
ok "M05-AC-2:no-log-issue:the-line-says-why-it-was-not-posted-report.py-s-reason" grep -qi 'log issue' "$c/out.watch1"
eq "M05-AC-2:no-log-issue:the-reason-keeps-the-output-one-line-and-without-traceback" "$(wc -l <"$c/out.watch1" | tr -d ' ')$(cnt "$c/out.watch1" Traceback)" 10
: >"$root/state/alpha/status.log"
urun "$root/state/alpha"
lognum=$(uq "[i['number'] for i in db['issues'].values() if i['title'].startswith('noodlebot log') and i['state'] == 'open'][0]")
re_a="(?s)(?=.*alpha)(?=.*$hbre)"
base_c=$(sc "$re_a")
watch 2
eq "M05-AC-2:no-log-issue:the-next-watch-posts-the-comment-once-an-issue-is-open" "$(( $(sc "$re_a") - base_c ))" 1
endcase

echo "# M05-AC-4 (follow-ups): start clears a failed watch unit before the systemd-run call and says when the call fails; stop reads is-active and stops once"
newcase ac4-fail alpha
ac4_fakes yes
# a systemd-run that fails for the timer call while $c/sdr.fail exists, and notes how many systemctl lines were logged by then
cat >"$bin/systemd-run" <<'EOT'
#!/bin/sh
echo "$*" >>"$SDRLOG"
case " $* " in *noodlebot-watch*)
	grep -c '' "$SCTLLOG" >"$SCTLDIR/sdr.at"
	[ -e "$SCTLDIR/sdr.fail" ] && exit 1
	exit 0 ;;
esac
while [ $# -gt 0 ]; do
	case $1 in
	--unit | -u | --description | --slice | -p | --property) shift 2 ;;
	-*) shift ;;
	*) break ;;
	esac
done
exec "$@"
EOT
chmod +x "$bin/systemd-run"
rf='--user reset-failed noodlebot-watch.timer noodlebot-watch.service'
echo inactive >"$c/user.state"; : >"$c/sdr.fail"
run start
eq "M05-AC-4:failed:start-exits-1-when-the-timer-call-fails" "$(cat "$c/rc.start")" 1
eq "M05-AC-4:failed:start-calls-reset-failed-once-for-the-timer-and-the-service" "$(cnt "$SCTLLOG" -Fx -- "$rf")" 1
eq "M05-AC-4:failed:the-reset-failed-call-comes-before-the-systemd-run-call" "$(head -n "$(cat "$c/sdr.at" 2>/dev/null || echo 0)" "$SCTLLOG" | grep -cFx -- "$rf")" 1
eq "M05-AC-4:failed:one-line-names-noodlebot-watch" "$(cnt "$c/out.start" noodlebot-watch)" 1
ok "M05-AC-4:failed:the-line-says-the-timer-could-not-be-set-up" sh -c "grep noodlebot-watch \"\$1\" | grep -qi timer && grep noodlebot-watch \"\$1\" | grep -qiE 'could not|cannot|can.t|failed|unable|not set up'" sh "$c/out.start"
eq "M05-AC-4:failed:the-rest-of-the-output-is-what-it-is-without-a-timer" "$(grep -v noodlebot-watch "$c/out.start" | sort)" "$(cat "$base/ac4-noctl.start")"
ok "M05-AC-4:failed:the-loop-still-starts" waitheld "$root/state/alpha/loop.lock"
ok "M05-AC-4:failed:the-api-still-starts" waitheld "$root/api.lock"
echo "# M05-AC-4 (follow-ups): a good timer call is also preceded by reset-failed; none when active, silent or units off"
rm -f "$c/sdr.fail"; : >"$SCTLLOG"; : >"$SDRLOG"
run start
eq "M05-AC-4:failed:a-good-timer-call-exits-0" "$(cat "$c/rc.start")" 0
eq "M05-AC-4:reset:inactive-start-calls-reset-failed-once" "$(cnt "$SCTLLOG" -Fx -- "$rf")" 1
eq "M05-AC-4:reset:inactive-start-makes-one-timer-call" "$(cnt "$SDRLOG" noodlebot-watch)" 1
echo active >"$c/user.state"; : >"$SCTLLOG"; : >"$SDRLOG"
run start
eq "M05-AC-4:reset:active-start-calls-no-reset-failed" "$(cnt "$SCTLLOG" reset-failed)" 0
eq "M05-AC-4:reset:active-start-makes-no-timer-call" "$(cnt "$SDRLOG" noodlebot-watch)" 0
rm -f "$c/user.state"; : >"$SCTLLOG"; : >"$SDRLOG"; : >"$c/sdr.fail"
run start
eq "M05-AC-4:reset:no-state-start-calls-no-reset-failed" "$(cnt "$SCTLLOG" reset-failed)" 0
eq "M05-AC-4:reset:no-state-start-makes-no-timer-call" "$(cnt "$SDRLOG" noodlebot-watch)" 0
eq "M05-AC-4:reset:no-state-start-exits-0" "$(cat "$c/rc.start")" 0
echo inactive >"$c/user.state"; rm -f "$HOME/.config/noodlebot/units"; : >"$SCTLLOG"; : >"$SDRLOG"
run start
eq "M05-AC-4:reset:units-off-start-calls-no-reset-failed" "$(cnt "$SCTLLOG" reset-failed)" 0
eq "M05-AC-4:reset:units-off-start-exits-0-and-says-nothing-of-a-timer" "$(cat "$c/rc.start")$(cnt "$c/out.start" -iE 'watch|timer')" 00
: >"$SCTLLOG"
run stop
eq "M05-AC-4:stop-reads-only:units-off-stop-makes-no-systemctl-call" "$(cnt "$SCTLLOG" '')" 0
: >"$HOME/.config/noodlebot/units"; rm -f "$c/user.state"; : >"$SCTLLOG"
run stop
eq "M05-AC-4:stop-reads-only:no-state-stop-calls-only-is-active" "$(cnt "$SCTLLOG" -v -e '^--user is-active ')" 0
echo active >"$c/user.state"; : >"$SCTLLOG"
run stop
eq "M05-AC-4:stop-reads-only:answering-stop-calls-only-is-active-and-one-stop" "$(cnt "$SCTLLOG" -v -e '^--user is-active ' -e '^--user stop noodlebot-watch.timer$')" 0
eq "M05-AC-4:stop-reads-only:answering-stop-stops-the-timer-exactly-once" "$(cnt "$SCTLLOG" -Fx -- '--user stop noodlebot-watch.timer')" 1
endcase

[ "$fails" = 0 ] || { echo "$fails failed"; exit 1; }
echo "all passed"
