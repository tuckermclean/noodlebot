#!/bin/bash
# G06-AC-1: as loop-g06-branch.test.sh, case 2: the node's worktree was not detached by the update (it is on a branch of its own, node/X02-side, with a commit of its own). Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g06.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g06.sh"

rl6 0.01 $(($(date +%s) + 7200))
loop6
ok "G06 setup: the first tick records the open PRs' feedback" waitf 40 test -d "$state/feedback"
y=$state/node/X02 br=node/X02-followup-1
s=$(g06_leftover_setup 12 X02 $br plain)
nc=${s#node=}; nc=${nc%% *}; uc=${s##*upd=}
ok "G06 setup: node worktree X02 is on its own branch (not detached) with a commit of its own, pr-12 holds the branch with the update's unpushed commit" test -n "$nc" -a -n "$uc" -a ! -e "$y/detached"
# the update ended with an answered question (the PR is not CONFLICTING any more)
mkdir -p "$state/pr/12"; echo X02 >"$state/pr/12/node"
echo "Q: which side wins?" >"$state/pr/12/QUESTION.md"; echo "A: ours" >"$state/pr/12/ANSWER.md"
fbadd 12 conversation 241 'after the update'

ok "G06-AC-1: the node's feedback session starts in the node's worktree on the PR's branch" waitf 30 g06_fb 12 X02 $br 1
ok "G06-AC-1: the pr-12 worktree is detached" g06_detached "$wt6/pr-12"
ok "G06-AC-1: the update's unpushed commit is not on the branch" sh -c "! git -C '$clone' merge-base --is-ancestor $uc refs/heads/$br && ! git -C '$wt6/X02' merge-base --is-ancestor $uc HEAD"
ok "G06-AC-1: no node/X02/detached marker appears" test ! -e "$y/detached"
ok "G06-AC-1: the node's own commit is kept (on the branch, or under refs/noodlebot/leftover/, or still on its own branch)" g06_anyref "$nc"
ok "G06-AC-1: the status log has no 'checking out ... failed' and no 'feedback not started' line" sh -c "! grep -qE 'checking out .* failed|feedback not started' '$state/status.log'"
g03_stop
loop_end
