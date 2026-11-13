#!/bin/bash
# U03-AC-2 (loop part): with the throttle holding and the start queue on (SCHED_RAMP=1), an issue labelled at the second tick
# has its "queued for triage" milestone by the third tick, and no session starts.
# Fixture: testdata/lib/loop-g01.sh (a fresh loop o/up, 1 s tick, X01 and X02 held by FAILED; its fake claude logs every session
# to $GD/claude.log) with the real report.py (SCHED_REPORT=1) posting to the fake gh api of testdata/lib/report-units.sh.
# The label is added by a file ($GD/labelled) that the gh wrapper below turns into the issue list issues.py reads, so no database
# is written while the fake gh answers. Ticks are counted by the loop's merged-PR poll ($GD/polls), one per tick.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g01.sh"
fakegh_lib=$src/testdata/lib
. "$fakegh_lib/report-fakegh.sh"
pyc_setup
. "$fakegh_lib/report-units.sh"

# the gh of the run: the events and the other `gh pr list` calls go to the G01 fake, the list issues.py reads (labels=noodlebot&)
# is $GD/labelled's issue, every other `gh api -X` call (report.py's) goes to the units' fake
cat >"$tmp/bin6/gh" <<EOS
#!/bin/sh
case "\$*" in
*"--state merged"*) echo x >>"$GD/polls" ;;
esac
case "\$*" in
*/events*) exec python3 -I "$GD/gh.py" "\$@" ;;
*"labels=noodlebot&"*)
	if [ -e "$GD/labelled" ]; then echo '[{"number": 46, "title": "labelled at the second tick", "state": "open", "body": "", "labels": [{"name": "noodlebot"}]}]'
	else echo '[]'; fi
	exit 0 ;;
esac
if [ "\$1" = api ] && [ "\$2" = -X ]; then exec "$ubin/gh" "\$@"; fi
exec python3 -I "$GD/gh.py" "\$@"
EOS
chmod +x "$tmp/bin6/gh"
: >"$GD/polls"

loopu03() {
	NOODLEBOT_DATA=$data6 PATH=$tmp/bin6:$PATH SCHED_REPORT=1 SCHED_SITE=0 SCHED_RAMP=1 SCHED_TICK=1 SCHED_POLL=0.2 \
		bash "$tmp/nb6/scheduler/loop.sh" o/up >>"$tmp/g01-loop.out" 2>&1 &
	pids+=("$!"); lp6=$!
}
queued46() { [ "$(ucount 46 'queued for triage')" -ge 1 ]; }

rl6 0.99 $(($(date +%s) + 3600))
loopu03
ok "U03-AC-2 setup: the throttle engages" within 8 "throttle engaged"
ok "U03-AC-2 setup: the loop has ticked at least twice" wait_polls "$GD/polls" 0 2
p0=$(polls "$GD/polls")
touch "$GD/labelled"   # the issue is labelled at the second tick
ok "U03-AC-2: the labelled issue gets its queued milestone" wait_until 15 queued46
p1=$(polls "$GD/polls")
ok "U03-AC-2: ... by the third tick (within two ticks of the label)" test "$p1" -le $((p0 + 2))
wait_ticks 2
ok "U03-AC-2: with the throttle holding, the milestone names the hold" test "$(ucount 46 'the throttle holds new sessions')" = 1
ok "U03-AC-2: the milestone is posted once over the ticks that follow" test "$(ucount 46 'queued for triage')" = 1
ok "U03-AC-2: no session starts: the fake claude never ran" test ! -s "$GD/claude.log"
ok "U03-AC-2: no session starts: no start in the status log" test "$(count 'started (triage|node|[A-Z][0-9]+)')" = 0
touch "$HOME/STOP-up"
for f in "$state"/pr/*/session.pid "$state"/issue/*/session.pid; do [ -e "$f" ] && kill -KILL -- "-$(cat "$f")" 2>/dev/null; done
loop_end
