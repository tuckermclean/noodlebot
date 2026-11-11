#!/bin/bash
# G02: SCHED_MAX counts updates; a failing PR list starts nothing. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g02.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g02.sh"

# The state the main run is in when it comes to these cases: the throttle open (an allowed window), the PRs of the main part not wanting an update.
g02_rl 0.01 $(($(date +%s) + 7200))
g02_prs 201 MERGEABLE; g02_prs 205 MERGEABLE
# G02-AC-1: SCHED_MAX counts updates; a failing PR list starts nothing.
g02_prs 208 CONFLICTING; g02_prs 210 CONFLICTING
touch "$G02_GD/hold.208" "$G02_GD/hold.210"
g02_loop 1
ok "G02-AC-1: with SCHED_MAX=1 an update starts" waitf 10 sh -c "[ \$(( \$(cat '$G02_GD/runs.208' 2>/dev/null || echo 0) + \$(cat '$G02_GD/runs.210' 2>/dev/null || echo 0) )) -ge 1 ]"
wait_ticks 3
ok "G02-AC-1: and updates count toward SCHED_MAX: the other one does not start while it runs" sh -c "[ \$(( \$(cat '$G02_GD/runs.208' 2>/dev/null || echo 0) + \$(cat '$G02_GD/runs.210' 2>/dev/null || echo 0) )) = 1 ]"
if [ -s "$G02_GD/runs.208" ]; then g02_first=208 g02_second=210; else g02_first=210 g02_second=208; fi
rm -f "$G02_GD/hold.$g02_first"
ok "G02-AC-1: the other one starts when the first has ended" waitf 8 g02_runsis $g02_second 1
rm -f "$G02_GD/hold.$g02_second"
waitf 6 g02_evis $g02_second 'rc 0' 1
g02_prs 208 MERGEABLE; g02_prs 210 MERGEABLE
touch "$G02_GD/open.fail"
g02_prs 211 CONFLICTING
g02_lines=$(wc -l <"$state/status.log")
wait_ticks 3
ok "G02-AC-1: when the PR list fails, no update starts" g02_runsis 211 0
ok "G02-AC-1: and the failure is logged" sh -c "tail -n +$((g02_lines + 1)) '$state/status.log' | grep -qi 'pr list failed'"
rm -f "$G02_GD/open.fail"
ok "G02-AC-1: once the list works, the PR gets its update" waitf 8 g02_runsis 211 1
g02_stop

loop_end
