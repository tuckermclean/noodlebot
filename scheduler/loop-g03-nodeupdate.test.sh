#!/bin/bash
# G03 with G02's node-PR updates: a node's feedback and its PR's update exclude each other, and node feedback starts after an update left its idle pr-<N> worktree on the PR's branch. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g03.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g03.sh"

# The fixture's fake claude does not know a node PR's update (/noodlebot:node --update N): it is kind nupd, id nupd.<N>.
sed -i '/^"\/noodlebot:triage --update "\*)/i "/noodlebot:node --update "*) kind=nupd k=${p##* } ;;' "$tmp/bin6/claude"
clone=$data6/repos/up
g03n_prs() { sed -i "s/^$1 \\(.*\\) [A-Z]*\$/$1 \\1 $2/" "$GD/prs.tsv"; }
# g03n_fb <PR> <node ID> <branch> <run>: the node's feedback session <run> started in the node's worktree on the branch.
g03n_fb() { grep -qF "fbnode $1 run $4 /noodlebot:node --feedback $1 | $wt6/$2 | $3 |" "$GD/claude.log"; }
g03n_detached() { [ -d "$1" ] && ! git -C "$1" symbolic-ref -q HEAD >/dev/null; }
g03n_nofail() { ! grep -qE 'checking out .* failed' "$state/status.log"; }
g03n_gone() { [ ! -e "$1" ]; }

rl6 0.01 $(($(date +%s) + 7200))
loop6
ok "G03 setup: the first tick records the open PRs' feedback" g03_first
x=$state/node/X01 p=$state/pr/11 y=$state/node/X02 q=$state/pr/12

# Cases 1 and 2 run side by side. Case 1: no node feedback while that PR's node-PR update runs (PR 11, node X01).
# Case 2: no node-PR update while the node's feedback session runs (PR 12, node X02).
g03_hold nupd.11; g03_hold fbnode.12; g03_hold nupd.12
g03n_prs 11 CONFLICTING
fbadd 12 conversation 132 'node point'
ok "G03 setup: the node-PR update of PR 11 starts and runs" waitf 30 runsis nupd.11 1
ok "G03 setup: the feedback session of node X02 starts and runs" waitf 30 runsis fbnode.12 1
fbadd 11 conversation 121 'first point'
fbadd 11 line 122 'second point'
g03n_prs 12 CONFLICTING
wait_ticks 3
ok "G03-AC-4: no node feedback session starts while the update of that node's PR runs" runsis fbnode.11 0
ok "G03-AC-4: nothing is handed over meanwhile (no FEEDBACK.md in the node's folder)" test ! -e "$x/FEEDBACK.md"
# The same without the session being the loop's child: restart the loop while fbnode.12 is still held, so alive() alone
# (not a wait on its own child) has to see the node feedback session as the node's.
g03n_took() { tail -n +"$1" "$state/status.log" | grep -qE 'running: .*X02'; }
g03n_l=$(($(wc -l <"$state/status.log") + 1))
kill "$lp6"; wait "$lp6" 2>/dev/null
ok "G03-AC-4 (restarted loop): stopping the loop leaves the feedback session of X02 running" runsis fbnode.12 1
loop6
ok "G03-AC-4 (restarted loop): the restarted loop takes the running session of X02 over" waitf 30 g03n_took "$g03n_l"
wait_ticks 3
ok "G03-AC-4 (restarted loop): alive() counts the feedback session no longer its child: no update of PR 12 starts while it runs" runsis nupd.12 0
ok "G03-AC-4 (restarted loop): the status log has no line saying X02's session ended" test "$(grep -cE 'X02.* ended' "$state/status.log")" = 0
ok "G03-AC-4: alive() counts a running node feedback session (its command ends in --feedback <N>) as the node's session: no update of PR 12 starts while it runs" runsis nupd.12 0
g03_release nupd.11; g03_release fbnode.12
ok "G03-AC-4: held node feedback starts its session after the update ended" waitf 30 runsis fbnode.11 1
ok "G03-AC-4: with every held item" sh -c "grep -qF '$(fburl 11 conversation 121)' '$GD/fbseen.fbnode.11.1' && grep -qF '$(fburl 11 line 122)' '$GD/fbseen.fbnode.11.1'"
ok "G03-AC-4: the update of PR 12 starts after the feedback session ended" waitf 30 runsis nupd.12 1
g03_release nupd.12
ok "G03 setup: both updates and the feedback sessions are over" waitf 30 sh -c "grep -q 'update of PR #12 ended' '$state/status.log' && [ ! -e '$x/session.pid' ] && [ ! -e '$y/session.pid' ]"
ok "G03-AC-4: and the update of PR 11 did not start again" runsis nupd.11 1

# Case 3: feedback after an update left its idle pr-<N> worktree on the branch, with an unpushed commit of its own, and
# the node's own worktree detached (node/<ID>/detached names the branch). 3a: it ended with an answered question and the
# PR is not CONFLICTING any more; 3b: it ended FAILED. (An answered question: G06 holds node feedback while one is open.)
git -C "$clone" fetch -q origin
g03n_prs 11 MERGEABLE; g03n_prs 12 MERGEABLE
wait_ticks 2   # the loop has seen that before the answered question below exists: no update restarts
g03n_setup() {   # g03n_setup <PR> <node ID> <branch>
	git -C "$wt6/$2" checkout -q --detach && echo "$3" >"$state/node/$2/detached" &&
		{ [ -d "$wt6/pr-$1" ] || git -C "$clone" worktree add -q "$wt6/pr-$1" "$3"; } &&
		git -C "$wt6/pr-$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "update: merge of main (unpushed)" &&
		git -C "$wt6/pr-$1" rev-parse HEAD
}
mkdir -p "$state/node/X01" "$state/pr/11" "$state/pr/12"
u11=$(g03n_setup 11 X01 node/X01-first); u12=$(g03n_setup 12 X02 node/X02-followup-1)
ok "G03 setup: both nodes' worktrees are detached by their updates, each pr-<N> holds the branch with a commit of its own" test -n "$u11" -a -n "$u12" -a -e "$x/detached" -a -e "$y/detached"
rm -f "$p/done" "$q/done"
echo X01 >"$p/node"; echo "Q: which side wins?" >"$p/QUESTION.md"; echo "A: ours" >"$p/ANSWER.md"
echo X02 >"$q/node"; echo "2018-01-01T00:00:00Z second exit (rc 1) without finishing the update" >"$q/FAILED"
fbadd 11 conversation 141 'after the update (question)'
fbadd 12 conversation 241 'after the update (failed)'

ok "G03-AC-3: 3a (update ended with an answered question): the node's feedback session starts in the node's worktree on the PR's branch" waitf 30 g03n_fb 11 X01 node/X01-first 2
ok "G03-AC-3: 3a: the pr-11 worktree is detached" g03n_detached "$wt6/pr-11"
ok "G03-AC-3: 3a: the update's unpushed commit is not on the branch" sh -c "test -n '$u11' && ! git -C '$clone' merge-base --is-ancestor $u11 refs/heads/node/X01-first && ! git -C '$wt6/X01' merge-base --is-ancestor $u11 HEAD"
ok "G03-AC-3: 3a: node/X01/detached is gone" g03n_gone "$x/detached"
ok "G03-AC-3: 3b (update ended FAILED): the node's feedback session starts in the node's worktree on the PR's branch" waitf 30 g03n_fb 12 X02 node/X02-followup-1 2
ok "G03-AC-3: 3b: the pr-12 worktree is detached" g03n_detached "$wt6/pr-12"
ok "G03-AC-3: 3b: the update's unpushed commit is not on the branch" sh -c "test -n '$u12' && ! git -C '$clone' merge-base --is-ancestor $u12 refs/heads/node/X02-followup-1 && ! git -C '$wt6/X02' merge-base --is-ancestor $u12 HEAD"
ok "G03-AC-3: 3b: node/X02/detached is gone" g03n_gone "$y/detached"
ok "G03-AC-3: the status log has no 'checking out ... failed' line" g03n_nofail
g03_stop
loop_end
