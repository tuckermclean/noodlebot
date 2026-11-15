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

# O: PICKUP=0; C: the harness lacks the small start
setup O hold; setup C hold
s09loop O $(UV O) PICKUP=0 FAKE_HARNESS_SCRIPT="$S08/plain.events"; Opid=$s09pid
s09loop C $(UV C) FAKE_HARNESS_SMALL=0 FAKE_HARNESS_SCRIPT="$S08/plain.events"; Cpid=$s09pid
ticker O; ticker C
DL=$(($(date +%s) + 30))
ok "S09-AC-6: PICKUP=0: the owner comment gets report.py's own reply (as before this node)" dl ge nrec 1 O
ok "S09-AC-6: the harness lacking the small start: the comment gets report.py's own reply" dl ge nrec 1 C
ok "S09-AC-6: PICKUP=0: one status-log line says so" dl is s09count 1 O 'PICKUP=0: pickup off'
ok "S09-AC-6: the harness lacking the capability: one status-log line says so" dl is s09count 1 C 'harness fake lacks small-model start: pickup off'
mark O C; ticks_since 2 O C
ok "S09-AC-6: PICKUP=0: no pickup run starts" is s09small 0 O
ok "S09-AC-6: PICKUP=0: said once per loop start, after several ticks: one 'pickup off' line" is s09count 1 O 'pickup off'
ok "S09-AC-6: PICKUP=0: the reply to the comment is posted once, no pickup folder is made" sh -c "[ '$(nrec O)' = 1 ] && [ ! -e '$(s09st O)/pickup' ]"
ok "S09-AC-6: the harness lacking the capability: no pickup run starts" is s09small 0 C
ok "S09-AC-6: the harness lacking the capability: said once per loop start: one 'pickup off' line" is s09count 1 C 'pickup off'
ok "S09-AC-6: the harness lacking the capability: only that capability is said (one 'lacks' line)" is s09count 1 C 'lacks '
ok "S09-AC-6: the harness lacking the capability: the reply is posted once, no pickup folder is made" sh -c "[ '$(nrec C)' = 1 ] && [ ! -e '$(s09st C)/pickup' ]"
# once per loop start: a second start of the loop says it again
stop_loop "$Opid" O; stop_loop "$Cpid" C
s09loop O $(UV O) PICKUP=0 FAKE_HARNESS_SCRIPT="$S08/plain.events"
s09loop C $(UV C) FAKE_HARNESS_SMALL=0 FAKE_HARNESS_SCRIPT="$S08/plain.events"
DL=$(($(date +%s) + 20))
ok "S09-AC-6: a second start of the loop (PICKUP=0) says it again" dl is s09count 2 O 'PICKUP=0: pickup off'
ok "S09-AC-6: a second start of the loop (no capability) says it again" dl is s09count 2 C 'harness fake lacks small-model start: pickup off'
mark O C; ticks_since 2 O C
ok "S09-AC-6: and only once more each; still no run, still one reply" sh -c "[ '$(s09count O 'pickup off')' = 2 ] && [ '$(s09count C 'pickup off')' = 2 ] && [ '$(s09small O)' = 0 ] && [ '$(s09small C)' = 0 ] && [ '$(nrec O)' = 1 ] && [ '$(nrec C)' = 1 ]"
loop_end
