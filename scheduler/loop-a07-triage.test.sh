#!/bin/bash
# A07-AC-5: a labelled issue is not triaged while an adoption is in progress (graph missing, then a graph with `adoption`):
# issues.py is not asked (the recorder in the fixture logs a call), one status-log line (naming triage and adoption); it is
# triaged after the adoption ends.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-a07.sh"
a07_fork a07
a07_issue a07 5
echo 22 >"$A07/pr.wrap"
touch "$A07/hold.scaffold"
a07_run a07
need "A07-AC-5: no graph: the adoption starts (scaffold session)" 15 a07_logged '^scaffold run 1 /noodlebot:adopt '
ticks 3
chk "A07-AC-5: graph missing, adoption running: issues.py is not asked" test ! -e "$A07/issues.called"
chk "A07-AC-5: no triage session starts" test "$(a07_runs triage.5)" = 0
tw() { a07_msgs | grep -i triage | grep -ci adopt; true; }
chk "A07-AC-5: one status-log line says the triage waits for the adoption (however many ticks)" test "$(tw)" = 1
rm -f "$A07/hold.scaffold"
need "A07-AC-5: the scaffold session ends with WAITING-PR" 20 a07_waiting scaffold
ticks 3
chk "A07-AC-5: graph still missing, the first PR open: issues.py is not asked" test ! -e "$A07/issues.called"
touch "$A07/hold.wrap"
a07_merge a07 21
a07_main a07 x
need "A07-AC-5: the graph now has adoption (area wrap): its session starts" 20 a07_logged '^wrap run 1 /noodlebot:adopt --area wrap'
ticks 3
chk "A07-AC-5: graph with adoption, an area session running: issues.py is not asked" test ! -e "$A07/issues.called"
chk "A07-AC-5: no triage session starts" test "$(a07_runs triage.5)" = 0
rm -f "$A07/hold.wrap"
need "A07-AC-5: the area session ends with WAITING-PR" 20 a07_waiting wrap
ticks 3
chk "A07-AC-5: graph with adoption, the area PR open: issues.py is not asked" test ! -e "$A07/issues.called"
a07_merge a07 22
a07_main a07 done
need "A07-AC-5: after the adoption ends the labelled issue is triaged (/noodlebot:triage 5)" 25 a07_logged '^triage[.]5 run 1 /noodlebot:triage 5'
chk "A07-AC-5: issues.py was asked once the adoption ended" test -s "$A07/issues.called"
a07_stop
loop_end
