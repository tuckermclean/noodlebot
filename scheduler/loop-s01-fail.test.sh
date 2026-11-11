#!/bin/bash
# S01-AC-5: listing closed PRs fails. Part of the end-to-end test of scheduler/loop.sh.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-fakes.sh"
. "$src/testdata/lib/loop-s01.sh"
loop4; loop1s=$lp4
# six sessions run (the check is in loop-s01.test.sh); B05 is the one whose closed PR must not stop it
waitf 20 sh -c "[ \$(ls '$S01'/child.B0[1-6].1 2>/dev/null | wc -l) = 6 ]"
p5=$(pg B05)
wait_until 5 s01_started 6

# S01-AC-5: listing closed PRs fails.
kill "$loop1s"; wait "$loop1s" 2>/dev/null
sleep 0.5   # nothing to observe: the loop is gone
printf '16 node/B05-n5 %s 0\n' "$(date +%s)" >>"$S01/closed.tsv"
touch "$S01/closed.fail"; rm -f "$state/node/B07/FAILED"
lines=$(wc -l <"$state/status.log")
loop4; loop3s=$lp4
wait_ticks 4
s01ok "S01-AC-5: a failing closed-PR query stops no session (B05's PR is closed)" grp_up "$p5"
s01ok "S01-AC-5: and starts none (B07 is ready)" test "$(s01runs B07)" = 0
s01ok "S01-AC-5: and the failure is logged" sh -c "tail -n +$((lines + 1)) '$state/status.log' | grep -qiE 'list.*fail|fail.*(list|closed)'"
s01ok "S01-AC-5: and no FAILED is written for B05" test ! -e "$state/node/B05/FAILED"
kill "$loop3s"; wait "$loop3s" 2>/dev/null
s01_cleanup

loop_end
