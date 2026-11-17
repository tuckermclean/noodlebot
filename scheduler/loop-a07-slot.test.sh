#!/bin/bash
# A07-AC-5: an adoption unit and a triage share the one slot (the start queue is on: SCHED_RAMP=1): while a triage runs no
# adoption session starts; it starts once the triage has ended; never two at once.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-a07.sh"
a07_fork a07
a07_main a07 done
a07_issue a07 5
touch "$A07/hold.triage.5" "$A07/hold.one"
a07_run a07 SCHED_RAMP=1
need "A07-AC-5: no adoption: the labelled issue is triaged (/noodlebot:triage 5), it holds the slot" 15 a07_logged '^triage[.]5 run 1 /noodlebot:triage 5'
a07_main a07 two
ticks 4
chk "A07-AC-5: adoption wanted (two areas) while the triage runs: no adoption session (one slot)" test "$(a07_runs one)" = 0
chk "A07-AC-5: only the triage ran" test "$(grep -c . "$A07/claude.log")" = 1
rm -f "$A07/hold.triage.5"
need "A07-AC-5: once the triage has ended the adoption session for area one starts" 25 a07_logged '^one run 1 /noodlebot:adopt --area one'
chk "A07-AC-5: the triage ran once" test "$(a07_runs triage.5)" = 1
ticks 3
chk "A07-AC-5: still one adoption session (area two waits for it)" test "$(a07_runs two)" = 0
a07_stop
loop_end
