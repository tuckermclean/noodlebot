#!/bin/bash
# A07-AC-2: an adoption PR closed without merging holds that unit by FAILED naming the PR; the next area does not start.
# Assumed: FAILED names the PR as its number (22).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-a07.sh"
a07_fork a07
a07_main a07 two
a07_run a07
need "A07-AC-2: area one's session ends with WAITING-PR 22" 15 a07_waiting one
a07_close a07 22
need "A07-AC-2: its PR closed without merging: the unit is held by FAILED" 20 a07_failed one
chk "A07-AC-2: FAILED names the PR (#22)" grep -qE '#?22([^0-9]|$)' "$(a07_ud one)/FAILED"
ticks 4
chk "A07-AC-2: the held unit starts no second session" a07_runis one 1
chk "A07-AC-2: nothing for the second area while the first is held" test "$(a07_runs two)" = 0
a07_stop
loop_end
