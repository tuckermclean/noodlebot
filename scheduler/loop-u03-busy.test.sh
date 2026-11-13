#!/bin/bash
# U03-AC-2 (loop part, a triage already running): with the throttle holding and the start queue on (SCHED_RAMP=1) and the triage
# of issue #46 running (the fake claude holds it), an issue #47 labelled later still has its "queued for triage" milestone within
# two ticks, saying it waits behind the triage of #46, and no further session starts. The loop must list the labelled issues
# (issues.py next) every tick while the throttle holds, whether or not a triage runs.
# Fixture as loop-u03.test.sh (loop-g01.sh, real report.py posting to the fake gh api of report-units.sh); the labels are files
# ($GD/labelled46, $GD/labelled47) that the gh wrapper turns into the issue list. Ticks are counted by the merged-PR poll.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g01.sh"
fakegh_lib=$src/testdata/lib
. "$fakegh_lib/report-fakegh.sh"
pyc_setup
. "$fakegh_lib/report-units.sh"

cat >"$tmp/bin6/gh" <<EOS
#!/bin/sh
case "\$*" in
*"--state merged"*) echo x >>"$GD/polls" ;;
esac
case "\$*" in
*/events*) exec python3 -I "$GD/gh.py" "\$@" ;;
*"labels=noodlebot&"*)
	out=
	for n in 46 47; do
		[ -e "$GD/labelled\$n" ] || continue
		[ -z "\$out" ] || out="\$out,"
		out="\$out{\"number\": \$n, \"title\": \"issue \$n\", \"state\": \"open\", \"body\": \"\", \"labels\": [{\"name\": \"noodlebot\"}]}"
	done
	echo "[\$out]"
	exit 0 ;;
esac
if [ "\$1" = api ] && [ "\$2" = -X ]; then exec "$ubin/gh" "\$@"; fi
exec python3 -I "$GD/gh.py" "\$@"
EOS
chmod +x "$tmp/bin6/gh"
: >"$GD/polls"
: >"$GD/prs.tsv"   # no open PR: no update session, so the running session is the triage of #46

NOODLEBOT_DATA=$data6 PATH=$tmp/bin6:$PATH SCHED_REPORT=1 SCHED_SITE=0 SCHED_RAMP=1 SCHED_TICK=1 SCHED_POLL=0.2 \
	bash "$tmp/nb6/scheduler/loop.sh" o/up >>"$tmp/g01-loop.out" 2>&1 &
pids+=("$!")
claude_ran() { [ -s "$GD/claude.log" ]; }
queued47() { [ "$(ucount 47 'queued for triage')" -ge 1 ]; }

ok "U03-AC-2 setup: the loop has ticked at least twice" wait_polls "$GD/polls" 0 2
touch "$GD/labelled46"
ok "U03-AC-2 setup: the triage of #46 starts and is held running" wait_until 20 claude_ran
rl6 0.99 $(($(date +%s) + 3600))
ok "U03-AC-2 setup: the throttle engages with the triage running" within 10 "throttle engaged"
ok "U03-AC-2 setup: the loop has ticked at least once more" wait_polls "$GD/polls" "$(polls "$GD/polls")" 1
p0=$(polls "$GD/polls")
touch "$GD/labelled47"   # labelled while the throttle holds and the triage of #46 runs
ok "U03-AC-2: behind a running triage with the throttle holding, the labelled issue gets its queued milestone" wait_until 15 queued47
p1=$(polls "$GD/polls")
ok "U03-AC-2: ... within two ticks of the label" test "$p1" -le $((p0 + 2))
ok "U03-AC-2: ... naming the triage it waits behind (#46)" test "$(ucount 47 'waits behind the triage of #46')" -ge 1
wait_ticks 2
ok "U03-AC-2: the milestone is posted once over the ticks that follow" test "$(ucount 47 'queued for triage')" = 1
ok "U03-AC-2: no new session starts: only the triage of #46 ran" test "$(wc -l <"$GD/claude.log")" = 1
ok "U03-AC-2: no new session starts: one start in the status log" test "$(count 'started (triage|node|[A-Z][0-9]+)')" = 1
touch "$HOME/STOP-up"
for f in "$state"/pr/*/session.pid "$state"/issue/*/session.pid; do [ -e "$f" ] && kill -KILL -- "-$(cat "$f")" 2>/dev/null; done
loop_end
