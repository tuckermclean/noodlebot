#!/bin/bash
# A07-AC-2: a graph with two areas: one session for the first (prompt names the area, its globs and the inventory command),
# nothing for the second while the first's PR is open or its unit is held (a question); an ANSWER.md written into the unit's
# state folder starts it again; after its PR is merged and the area is gone from the graph, one session for the second.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-a07.sh"
a07_fork a07
a07_main a07 two
touch "$A07/hold.one" "$A07/question.one.1"
a07_run a07
need "A07-AC-2: two areas: one session for the first (/noodlebot:adopt --area one)" 15 a07_logged '^one run 1 /noodlebot:adopt --area one'
wt=$(a07_wt one)
chk "A07-AC-2: it works in worktrees/<name>/adopt-one, on spec/adopt-one" a07_logged "^one run 1 .* [|] $wt [|] spec/adopt-one\$"
u=$(a07_ud one)/unattended.md
chk "A07-AC-2: its prompt names the area one" grep -qwF 'one' "$u"
chk "A07-AC-2: its prompt names the area's globs (src/one/)" grep -qF 'src/one/' "$u"
chk "A07-AC-2: its prompt names the inventory command (inventory.py)" grep -qF 'inventory.py' "$u"
chk "A07-AC-2: its prompt names the skill and its worktree" sh -c "grep -qF '/noodlebot:adopt' '$u' && grep -qF '$wt' '$u'"
ticks 2
chk "A07-AC-2: nothing for the second area while the first runs" test "$(a07_runs two)" = 0
rm -f "$A07/hold.one"
need "A07-AC-2: a question (QUESTION.md) ends the session and holds the unit" 20 test -s "$(a07_ud one)/QUESTION.md" -a ! -e "$(a07_ud one)/session.pid"
ticks 3
chk "A07-AC-2: a question holds the unit: no new session for it" a07_runis one 1
chk "A07-AC-2: a question holds the unit: nothing for the second area" test "$(a07_runs two)" = 0
echo "a" >"$(a07_ud one)/ANSWER.md"
need "A07-AC-2: an ANSWER.md in the unit's state folder starts it again (second run of area one)" 20 a07_runis one 2
need "A07-AC-2: the answered run ends with WAITING-PR and its worktree is removed" 20 a07_waiting one
ticks 3
chk "A07-AC-2: no third run of area one while its PR (22) is open" a07_runis one 2
chk "A07-AC-2: nothing for the second area while the first's PR is open" test "$(a07_runs two)" = 0
touch "$A07/hold.two"
a07_merge a07 22
a07_main a07 one
need "A07-AC-2: after the PR is merged and the area gone from the graph: one session for the second area" 20 a07_logged '^two run 1 /noodlebot:adopt --area two'
chk "A07-AC-2: the second area's session works in worktrees/<name>/adopt-two, on spec/adopt-two" a07_logged "^two run 1 .* [|] $(a07_wt two) [|] spec/adopt-two\$"
chk "A07-AC-2: the second area's prompt names its globs (src/two/)" grep -qF 'src/two/' "$(a07_ud two)/unattended.md"
ticks 3
chk "A07-AC-2: the second area has one session, area one none again" test "$(a07_runs two)" = 1 -a "$(a07_runs one)" = 2
a07_stop
loop_end
