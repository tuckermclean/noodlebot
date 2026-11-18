#!/bin/bash
# A07 review: the WAITING-PR a FAILED unit releases goes to answered/ as <ts>-SPEC-PR-CLOSED when its PR was closed without
# merging (SPEC-PR means merged), and as <ts>-SPEC-PR when the merged PR never took its step; the rendered unattended.md
# explains answered/ to a resumed session.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-a07.sh"
. "$src/testdata/lib/loop-a07-resume.sh"
a07_fork a07
a07_main a07 two
a07_run a07
need "A07-AC-2: area one's session ends with WAITING-PR 22" 15 a07_waiting one
chk "A07-AC-2: unattended.md tells a resumed session about answered/ and SPEC-PR-CLOSED" sh -c "grep -q 'answered/' '$(a07_ud one)/unattended.md' && grep -q 'SPEC-PR-CLOSED' '$(a07_ud one)/unattended.md'"
a07_close a07 22
need "A07-AC-2: the PR closed without merging: FAILED" 20 a07_failed one
need "A07-AC-2: the released WAITING-PR is answered/<ts>-SPEC-PR-CLOSED" 6 a07r_answered one SPEC-PR-CLOSED
chk "A07-AC-2: not <ts>-SPEC-PR (that means merged)" test ! "$(a07r_answered one SPEC-PR && echo y)"
a07_stop
rm -f "$A07"/runs.* "$A07/claude.log"
a07_skip=0
A07_TICK=2
a07_fork late
a07_main late two
a07_run late
need "A07-AC-2: late: area one's session ends with WAITING-PR 22" 15 a07_waiting one
a07_break_fetch late
a07_merge late 22
ticks 2
a07_fix_fetch late
need "A07-AC-2: late: the merged PR never took its step: FAILED" 25 a07_failed one
need "A07-AC-2: late: the released WAITING-PR is answered/<ts>-SPEC-PR (merged)" 6 a07r_answered one SPEC-PR
chk "A07-AC-2: late: not <ts>-SPEC-PR-CLOSED" test ! "$(a07r_answered one SPEC-PR-CLOSED && echo y)"
a07_stop
loop_end
