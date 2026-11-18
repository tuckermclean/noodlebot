#!/bin/bash
# A07-AC-2 (S2+S4 re-review): a unit's WAITING-PR is released as a merged answered/<ts>-SPEC-PR only once its PR is merged: the
# graph is reordered while area one's PR is open (area two becomes the first area); area one keeps its WAITING-PR (or releases
# it only after the merge) and is never FAILED or started again, and after the merge its release is a <ts>-SPEC-PR.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-a07.sh"
. "$src/testdata/lib/loop-a07-resume.sh"
. "$src/testdata/lib/loop-a07-reorder.sh"
a07_fork a07
a07_main a07 two
a07_run a07
need "A07-AC-2: area one's session ends with WAITING-PR 22" 15 a07_waiting one
touch "$A07/hold.two"
a07o_reorder a07
need "A07-AC-2: the reordered graph is fetched: area two (now first) is started" 20 a07_logged '^two run 1 /noodlebot:adopt --area two'
ticks 3
chk "A07-AC-2: reordered, PR 22 open: area one's WAITING-PR is still there or not released as merged (no answered/<ts>-SPEC-PR)" sh -c "[ -s '$(a07_ud one)/WAITING-PR' ] || ! ls '$(a07_ud one)/answered' 2>/dev/null | grep -q 'SPEC-PR\$'"
chk "A07-AC-2: reordered, PR 22 open: area one's WAITING-PR is not released as <ts>-SPEC-PR" test ! "$(a07r_answered one SPEC-PR && echo y)"
chk "A07-AC-2: reordered, PR 22 open: area one holds no FAILED and no second session" sh -c "[ ! -e '$(a07_ud one)/FAILED' ] && [ '$(a07_runs one)' = 1 ]"
a07_merge a07 22
ticks 3
chk "A07-AC-2: PR 22 merged: area one's WAITING-PR is kept or released as <ts>-SPEC-PR, never as -CLOSED" sh -c "[ -s '$(a07_ud one)/WAITING-PR' ] || ls '$(a07_ud one)/answered' | grep -q -- '-SPEC-PR\$'"
a07_stop
loop_end
