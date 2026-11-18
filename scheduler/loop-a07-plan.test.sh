#!/bin/bash
# A07-AC-2: adoption with no area left: one adopt/plan session (branch spec/adopt-plan, worktree adopt-plan, /noodlebot:adopt
# --plan), none second while its PR is open; after its PR is merged (no adoption on main) nothing starts.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-a07.sh"
a07_fork a07
a07_main a07 plan
touch "$A07/hold.plan"
a07_run a07
need "A07-AC-2: adoption with no area left: an adopt/plan session starts (/noodlebot:adopt --plan)" 15 a07_logged '^plan run 1 /noodlebot:adopt --plan'
wt=$(a07_wt plan)
chk "A07-AC-2: the plan session works in worktrees/<name>/adopt-plan, on spec/adopt-plan" a07_logged "^plan run 1 .* [|] $wt [|] spec/adopt-plan\$"
chk "A07-AC-2: its prompt (adopt/plan/unattended.md) names the skill and its worktree" sh -c "grep -qF '/noodlebot:adopt' '$(a07_ud plan)/unattended.md' && grep -qF '$wt' '$(a07_ud plan)/unattended.md'"
ticks 3
chk "A07-AC-2: one plan session only while it runs" a07_runis plan 1
rm -f "$A07/hold.plan"
need "A07-AC-2: the plan session ends with WAITING-PR and its worktree is removed" 20 a07_waiting plan
ticks 3
chk "A07-AC-2: no second plan session while its PR is open" a07_runis plan 1
a07_merge a07 24
a07_main a07 done
ticks 4
chk "A07-AC-2: the plan PR merged (no adoption): nothing starts (no second plan session)" a07_runis plan 1
chk "A07-AC-2: the plan PR merged: no other session ran" test "$(grep -c . "$A07/claude.log")" = 1
a07_stop
loop_end
