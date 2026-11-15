#!/bin/bash
# S09 (pickup agent), the loop's part, in three files (each loop case costs seconds and a file may take 30 s):
#   loop-s09.test.sh         S09-AC-2 and the loop's share of S09-AC-5 / S09-AC-6 (a pace hold does not stop a run, the setting reaches
#                            pickup.py, --pickup is passed): this file
#   loop-s09-off.test.sh     S09-AC-6: PICKUP=0 and a harness lacking the capability
#   loop-s09-budget.test.sh  S09-AC-5: the budget and the ceiling in the loop
# The part: S09-AC-2 (a tick with items starts one pickup run through the harness's small start,
# no turn, no start, no SCHED_MAX slot; each run is one status-log event), S09-AC-5 (a pace hold alone does not stop it; the
# budget and the ceiling do, and the first such tick says so once), S09-AC-6 (PICKUP=0 or a harness lacking the capability:
# no run, one status-log line per loop start). Fixture: testdata/lib/loop-s09.sh (the S08 fixture, a fake forge per run,
# a fake usage.py); the fake harness's small start (FAKE_HARNESS_SMALL_SCRIPT, FAKE_HARNESS_SMALL=0) is the pickup session.
#
# THE CONTRACT of the loop's step (the unit-level contract is in the header of pickup.test.sh):
#  - settings (environment of the loop): PICKUP (default 1; 0 turns the step off), PICKUP_RUNS (default 12), PICKUP_CEILING
#    (default 90%); pickup.py reads the last two itself from the environment it inherits.
#  - once per tick, after the report step and only for a tick that reached the forge, the loop runs `pickup.py run` (with
#    the report step's arguments), also while the throttle holds: the pace hold is not consulted. The run takes no turn
#    of turn.py, no start count (state/<name>/node/*/starts), no `live` entry (no SCHED_MAX slot). The loop says each
#    line pickup.py prints on stdout as one status-log event.
#  - while the step is on report.py gets --pickup; while off it does not and replies "Not recorded ..." as before.
#  - off, one status-log line at each loop start (a restart says it again), no state/<name>/pickup folder:
#      PICKUP=0                            ->  "PICKUP=0: pickup off"
#      harness lacks the small-model start ->  "harness <name> lacks small-model start: pickup off"   (harness.py small fails)
#  - a run's event: "pickup run <name>: items [<item urls>]; decisions [<comment id> <action> ...]; cost $<x>" (cost of
#    the run's result event, four decimals: $0.0123 for the fake script).
#  - with the budget spent or the ceiling reached, the items get report.py's reply and the first such tick of a window says
#    one line starting "pickup: no run" (naming "budget" or "ceiling"); later ticks of the window say nothing.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
for v in $(env | cut -d= -f1 | grep -E '^(SCHED_|FAKE_|PICKUP|NOODLEBOT_|USAGE_|S09_|S08_)'); do unset "$v"; done
unset GH_TOKEN
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-s09.sh"

# R: one run in the window (PICKUP_RUNS=1); K: the ceiling (default 90%) with a window at 95%; both under a pace hold or none
setup R hold; setup K open 0.95
s09loop R $(UV R) PICKUP_RUNS=1 FAKE_HARNESS_SCRIPT="$S08/plain.events"
s09loop K $(UV K) FAKE_HARNESS_SCRIPT="$S08/plain.events"
ticker R; ticker K
DL=$(($(date +%s) + 30))
pk_on() { [ "$(s09small R)" -ge 1 ]; }   # the step works at all: the "nothing happened" checks need it
req() { pk_on && "$@"; }
ok "S09-AC-5: PICKUP_RUNS=1: the first comment of the window starts a run" dl ge s09small 1 R
ok "S09-AC-5: PICKUP_RUNS=1: ... and is handled" dl handled R "$ID_R"
c2=$(s09comment R 13 "a second unplaceable owner comment")
ok "S09-AC-5: with the budget spent, the second comment gets report.py's reply" req dl ge nrec 1 R
ok "S09-AC-5: with the budget spent, the first such tick says so: one 'pickup: no run' line naming the budget" dl sh -c \
	"[ \$(grep -ci 'pickup: no run.*budget' '$(s08st R)') = 1 ]"
c3=$(s09comment R 13 "a third unplaceable owner comment")
ok "S09-AC-5: the third comment gets report.py's reply too" req dl ge nrec 2 R
ok "S09-AC-5: the ceiling (default 90%) with the window at 95%: the comment gets report.py's reply" req dl ge nrec 1 K
ok "S09-AC-5: the ceiling: the first such tick says so (one 'pickup: no run' line naming the ceiling)" dl sh -c \
	"[ \$(grep -ci 'pickup: no run.*ceiling' '$(s08st K)') = 1 ]"
ok "S09-AC-5: the ceiling: the comment is handled" dl handled K "$ID_K"
mark R K; ticks_since 2 R K
ok "S09-AC-5: PICKUP_RUNS=1: no second run in the window (one small call)" req is s09small 1 R
ok "S09-AC-5: only the first such tick of the window says so (one 'pickup: no run' line)" req is s09count 1 R 'pickup: no run'
ok "S09-AC-5: the comments left by the budget are handled (not retried every tick)" req sh -c "grep -qx '$c2' '$(s09st R)/pickup/handled' && grep -qx '$c3' '$(s09st R)/pickup/handled'"
ok "S09-AC-5: the ceiling: no run started, the line said once, one reply" req sh -c "[ '$(s09small K)' = 0 ] && [ '$(s09count K 'pickup: no run')' = 1 ] && [ '$(nrec K)' = 1 ]"
loop_end
