#!/bin/bash
# G02: review1d #2 and #4: a symlinked runtime root, the template's sentence. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g02.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g02.sh"
. "$src/testdata/lib/loop-g02-review.sh"

# The state the main run is in when it comes to these cases: the throttle open (an allowed window), the PRs of the main part not wanting an update.
g02_rl 0.01 $(($(date +%s) + 7200))
g02_prs 201 MERGEABLE; g02_prs 205 MERGEABLE
# review1d #2: the runtime root reached through a symlink. 251 (node N31): its idle worktree holds the branch;
# 252 (node N32): the update commits locally, ends rc 1, and is started again (its own pr-252 is recognised).
ln -s "$g02_data" "$G02/link"
mkdir -p "$state/node/N31" "$state/node/N32"; echo "Q: wait" >"$state/node/N31/QUESTION.md"
g02_fetchrepo
git -C "$g02_data/repos/g02" worktree add -q -b node/N31-bb "$g02_wt/N31" origin/node/N31-bb
g02_prs 251 CONFLICTING; g02_prs 252 CONFLICTING
touch "$G02_GD/commit.252.1"; echo 1 >"$G02_GD/rc.252.1"; echo 1 >"$G02_GD/rc.252.2"
g02b_loop 0 "$G02/link" 0
ok "G02-AC-1 (review1d #2): under a symlinked runtime root, PR 251's update starts though the node's idle worktree holds the branch" waitf 10 grep -qF "nupd 251 run 1 /noodlebot:node --update 251 | $g02_wt/pr-251 | node/N31-bb" "$G02_GD/claude.log"
ok "G02-AC-2 (review1d #2): under a symlinked root, an update that committed locally and ended rc 1 is started again (252, start 2 of 2)" waitf 12 g02_runsis 252 2
ok "G02-AC-2 (review1d #2): and its second end without rc 0 writes FAILED" waitf 8 test -e "$state/pr/252/FAILED"
g02_stop
g02_prs 251 MERGEABLE; g02_prs 252 MERGEABLE

# review1d #4: the template says the scheduler removes the worktree only after rc 0 (the old sentence, "The
# scheduler removes @WT@ after you end.", said it always does).
ok "G02-AC-2 (review1d #4): unattended-node-update.md does not say the scheduler removes the worktree after every end" sh -c "! tr '\\n' ' ' <'$src/unattended-node-update.md' | tr -s ' ' | grep -qE 'scheduler removes @WT@ after you end[.,;]'"

loop_end
