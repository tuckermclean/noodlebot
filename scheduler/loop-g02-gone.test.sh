#!/bin/bash
# G02: a node-PR update's question is released when its PR is no longer open (review-fresh #1). Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g02.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g02.sh"

# The state the main run is in when it comes to these cases: the throttle open, no open PR wanting an update.
g02_rl 0.01 $(($(date +%s) + 7200))
g02_prs 201 MERGEABLE; g02_prs 205 MERGEABLE
# pr/301: node PR, QUESTION.md, PR gone.  pr/302: the same with ANSWER.md too.  pr/203: node PR still open (203 is in prs.tsv).
# pr/305: a spec PR's update (no node file), QUESTION.md, no open PR.
for g02_i in 301 302 203; do
	mkdir -p "$state/pr/$g02_i"; echo N99 >"$state/pr/$g02_i/node"; echo "Q: which side?" >"$state/pr/$g02_i/QUESTION.md"
done
echo "A: this side" >"$state/pr/302/ANSWER.md"
mkdir -p "$state/pr/305"; echo "Q: spec question" >"$state/pr/305/QUESTION.md"
g02_released() { [ ! -e "$state/pr/$1/QUESTION.md" ] && ls "$state/pr/$1/answered/"*QUESTION.md >/dev/null 2>&1; }
g02_kept() { [ -e "$state/pr/$1/QUESTION.md" ] && [ ! -d "$state/pr/$1/answered" ]; }

# The PR list fails: nothing moves (these ticks run before the list works).
touch "$G02_GD/open.fail"
g02_loop 0
wait_ticks 1   # setup: the loop is running
wait_ticks 3
ok "G02-AC-2 (review-fresh #1): the open-PR list fails: a gone node PR's QUESTION.md (301) stays" g02_kept 301
ok "G02-AC-2 (review-fresh #1): the open-PR list fails: QUESTION.md and ANSWER.md (302) stay" sh -c "[ -e '$state/pr/302/QUESTION.md' ] && [ -e '$state/pr/302/ANSWER.md' ] && [ ! -d '$state/pr/302/answered' ]"

# The list works again.
rm -f "$G02_GD/open.fail"
ok "G02-AC-2 (review-fresh #1): the PR is no longer open: QUESTION.md (301) moves into pr/301/answered/" waitf 8 g02_released 301
ok "G02-AC-2 (review-fresh #1): and is gone from pr/301/" test ! -e "$state/pr/301/QUESTION.md"
ok "G02-AC-2 (review-fresh #1): QUESTION.md and ANSWER.md (302) both move into pr/302/answered/" waitf 8 sh -c "ls '$state'/pr/302/answered/*QUESTION.md >/dev/null 2>&1 && ls '$state'/pr/302/answered/*ANSWER.md >/dev/null 2>&1"
ok "G02-AC-2 (review-fresh #1): and both are gone from pr/302/" sh -c "[ ! -e '$state/pr/302/QUESTION.md' ] && [ ! -e '$state/pr/302/ANSWER.md' ]"
wait_ticks 3
ok "G02-AC-2 (review-fresh #1): no update session starts for the released PRs (301, 302)" sh -c "! grep -qE ' (301|302) run ' '$G02_GD/claude.log' 2>/dev/null"
ok "G02-AC-2 (review-fresh #1): a node PR that is still open (203) keeps its QUESTION.md" g02_kept 203
ok "G02-AC-2 (review-fresh #1): a spec PR's update folder (305, no node file) is not touched" g02_kept 305
g02_stop

loop_end
