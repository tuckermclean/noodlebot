#!/bin/bash
# G02: a node's unpushed commits survive its PR's update (N15, N16). Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g02.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g02.sh"

# The state the main run is in when it comes to these cases: the throttle open (an allowed window), the PRs of the main part not wanting an update.
g02_rl 0.01 $(($(date +%s) + 7200))
g02_prs 201 MERGEABLE; g02_prs 205 MERGEABLE
# G02-AC-1/2 (second review, finding 1): a node's unpushed commits survive its PR's update. N15: its idle
# worktree worktrees/<name>/N15 is on node/N15-rho with a local commit origin lacks, its question is open
# (no session), its PR 215 is CONFLICTING. The update must not start while the branch holds that commit.
# Finding 2: N16 is merged, its follow-up branch node/N16-followup-1 has PR 216 (CONFLICTING) and an answered
# question; after the update the follow-up session must start in worktrees/<name>/N16 on that branch.
sed -i 's/ [A-Z]*$/ MERGEABLE/' "$G02_GD/prs.tsv"
g02g fetch -q "$G02/remote.git" main && g02g reset -q --hard FETCH_HEAD
printf '  - {id: N15, name: rho, deps: []}\n  - {id: N16, name: sigma, deps: []}\n' >>"$G02/work/docs/graph.yaml"
g02g commit -q -a -m "graph: N15, N16" && g02g commit -q --allow-empty -m "N16 sigma: merged (#7)" && g02g push -q "$G02/remote.git" main
for g02_i in node/N15-rho node/N16-followup-1; do
	g02g checkout -q -b "$g02_i" main && g02g commit -q --allow-empty -m "branch $g02_i" && g02g push -q "$G02/remote.git" "$g02_i"; g02g checkout -q main
done
printf '215 node/N15-rho app/noodlebot true CONFLICTING\n216 node/N16-followup-1 app/noodlebot true CONFLICTING\n' >>"$G02_GD/prs.tsv"
git -C "$g02_data/repos/g02" fetch -q origin
git -C "$g02_data/repos/g02" worktree add -q -b node/N15-rho "$g02_wt/N15" origin/node/N15-rho
echo local >"$g02_wt/N15/unpushed.txt"; git -C "$g02_wt/N15" add unpushed.txt
git -C "$g02_wt/N15" -c user.name=t -c user.email=t@t commit -q -m "UNPUSHED local commit"
g02_unp=$(git -C "$g02_wt/N15" rev-parse HEAD)
git -C "$g02_data/repos/g02" worktree add -q -b node/N16-followup-1 "$g02_wt/N16" origin/node/N16-followup-1
mkdir -p "$state/node/N15" "$state/node/N16"
echo "Q: wait" >"$state/node/N15/QUESTION.md"
echo node/N16-followup-1 >"$state/node/N16/FOLLOWUP"; echo "Q: x" >"$state/node/N16/QUESTION.md"; echo "A: y" >"$state/node/N16/ANSWER.md"
touch "$G02_GD/hold.215" "$G02_GD/hold.216" "$G02_GD/hold.N15" "$G02_GD/hold.N16"
g02_loop 0
ok "G02-AC-1: the follow-up node's PR (216, CONFLICTING) gets its update" waitf 10 g02_runsis 216 1
wait_ticks 5
ok "G02-AC-1: N15's unpushed commit stays reachable from refs/heads/node/N15-rho over several ticks" git -C "$g02_data/repos/g02" merge-base --is-ancestor "$g02_unp" refs/heads/node/N15-rho
ok "G02-AC-1: no update of PR 215 starts while its branch holds a commit origin lacks" g02_runsis 215 0
rm -f "$G02_GD/hold.215" "$G02_GD/hold.216"
ok "G02-AC-2: the follow-up's update (216) ends with rc 0" waitf 8 g02_evis 216 'rc 0' 1
echo "A: go" >"$state/node/N15/ANSWER.md"
ok "G02-AC-1: N15, answered, resumes in worktrees/<name>/N15 on node/N15-rho" waitf 10 grep -qF "node N15 run 1 /noodlebot:node N15 | $g02_wt/N15 | node/N15-rho" "$G02_GD/claude.log"
ok "G02-AC-1: the resumed N15's worktree has its unpushed commit at or behind HEAD" git -C "$g02_wt/N15" merge-base --is-ancestor "$g02_unp" HEAD
ok "G02-AC-1: and the commit is still reachable from refs/heads/node/N15-rho" git -C "$g02_data/repos/g02" merge-base --is-ancestor "$g02_unp" refs/heads/node/N15-rho
ok "G02-AC-2: after its PR's update, the follow-up session of N16 starts in worktrees/<name>/N16 on node/N16-followup-1" waitf 10 grep -qF "node N16 run 1 /noodlebot:node N16 | $g02_wt/N16 | node/N16-followup-1" "$G02_GD/claude.log"
ok "G02-AC-2: and the follow-up is not blocked by 'a worktree not on its follow-up branch is in the way'" sh -c "! grep -q 'N16: a worktree not on its follow-up branch is in the way' '$state/status.log'"
rm -f "$G02_GD/hold.N15" "$G02_GD/hold.N16"
g02_stop

loop_end
