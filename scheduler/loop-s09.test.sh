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

# H: the throttle holds on a pace, the start queue is on: N01 waits, the pickup run does not
setup H hold
s09loop H $(UV H) SCHED_RAMP=1 FAKE_HARNESS_SCRIPT="$S08/plain.events"
# K2: a 95% window, the ceiling at 99%; the throttle is open and the one SCHED_MAX slot is taken by N01's session
setup K2 open 0.95
s09loop K2 $(UV K2) PICKUP_CEILING=99% SCHED_MAX=1 S08_IDLE=1 FAKE_HARNESS_SCRIPT="$S08/plain.events"
ticker H; ticker K2
DL=$(($(date +%s) + 30))
pk_on() { [ "$(s09small H)" -ge 1 ]; }   # the step works at all: the "nothing happened" checks need it, so that a loop without it does not pass them
req() { pk_on && "$@"; }

ok "S09-AC-2: throttle on a pace hold, one unplaceable owner comment: one pickup session runs (one small call)" dl ge s09small 1 H
ok "S09-AC-5: the throttle held (a pace hold) and did not stop the run" dl s09log H 'throttle engaged'
ok "S09-AC-2: the pickup session ran in a folder of the run's state (state/H/pickup/)" grep -qs "^small $(s09st H)/pickup/" "$S08/H.log"
ok "S09-AC-2: its decision is recorded: the comment is handled" dl handled H "$ID_H"
ok "S09-AC-2: and its reply is on the thread, naming the comment and that nothing changed" dl sh -c \
	"python3 -I '$TOOL' reply '$(fk H)' 13 'fake://owner/repo/issues/13#c$ID_H' | grep -qi nothing"
ok "S09-AC-2: each run is one status-log event: a 'pickup run' line" dl is s09count 1 H 'pickup run '
ok "S09-AC-2: the event names the item (its URL) and the run's cost" s09log H "pickup run .*fake://owner/repo/issues/13#c$ID_H.*cost \\\$0\\.0123"
ok "S09-AC-2: the event names the decision (<id> note)" s09log H "pickup run .*decisions \\[$ID_H note"
ok "S09-AC-2 (slot): N01 starts on the open throttle and takes the one SCHED_MAX slot" dl ge s09units 1 K2
ok "S09-AC-2 (slot): with the slot taken, the pickup run starts all the same (95% is below the 99% ceiling)" dl ge s09small 1 K2

# two ticks of both loops, then everything that must not have happened (the second tick has a handled item and no items)
mark H K2; ticks_since 2 H K2
ok "S09-AC-2: a tick with no items (the comment is handled) runs no more session" req is s09small 1 H
ok "S09-AC-2: one status-log event of a run (one 'pickup run' line), and nothing else said of pickup" req sh -c "[ '$(s09count H 'pickup run ')' = 1 ] && [ '$(s09count H 'pickup')' = 1 ]"
ok "S09-AC-6 (control): with the step on and the capability there, nothing is said to be lacking or off" req is s09count 0 H 'lacks |pickup off'
ok "S09-AC-5/6: the loop passed --pickup to report.py: no 'Not recorded' reply to the comment" req is nrec 0 H
ok "S09-AC-2: no unit session started (no start, no resume call on the fake harness)" req is s09units 0 H
ok "S09-AC-2: the run took no start count (no starts file under node/)" req sh -c "! ls '$(s09st H)'/node/*/starts 2>/dev/null | grep -q N01"
ok "S09-AC-2: the run took no S07 turn (no start record of turn.py under the runtime root)" req test ! -e "$tmp/d-H/state/starts.json"
ok "S09-AC-2: nothing of the pickup run in the start queue (waiting.json)" req sh -c "! grep -qi pickup '$(s09st H)/waiting.json' 2>/dev/null"
ok "S09-AC-2 (slot): N01's session is still running with one start, and one pickup run was made" req sh -c "kill -0 \$(cat '$S08/K2/pid.1') 2>/dev/null && [ \"\$(cat '$(s09st K2)/node/N01/starts')\" = 1 ] && [ '$(s09small K2)' = 1 ]"
ok "S09-AC-2 (slot): one start call in all (N01's), the run being no start" req is s09units 1 K2
ok "S09-AC-5: PICKUP_CEILING=99% (the loop's setting reaches pickup.py): nothing is said to be refused" req is s09count 0 K2 'pickup: no run'
loop_end
