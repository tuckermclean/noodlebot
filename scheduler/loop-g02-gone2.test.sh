#!/bin/bash
# G02: the release of a gone node PR's question: its guards (a human's open PR, an open-PR list as long as its limit, a running session), the shared timestamp of the pair and the status-log event (review1g #1). Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g02.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g02.sh"

# A fake gh of this file: while $G02_GD/big exists the open-PR list is 500 lines (the loop's --limit) of other PRs, made by awk
# (the fixture's gh runs git once per line); every other call goes to the fixture's gh.
cat >"$G02/bin/gh" <<'EOT'
#!/bin/sh
case " $* " in
*" --state open "*) if [ -e "$G02_GD/big" ]; then
	awk 'BEGIN { for (n = 1001; n <= 1500; n++) print n " other/b" n " 0000000000000000000000000000000000000000 false MERGEABLE" }'
	exit 0
fi ;;
esac
exec python3 -I "$G02_GD/gh.py" "$@"
EOT
chmod +x "$G02/bin/gh"

g02_rl 0.01 $(($(date +%s) + 7200))
g02_prs 201 MERGEABLE; g02_prs 205 MERGEABLE
# pr/202: node PR, open, its author a human (prs.tsv: 202 tuckermclean false).  pr/311: QUESTION.md and ANSWER.md, PR gone.
# pr/313: QUESTION.md, PR gone.  pr/312: QUESTION.md, PR gone, but a session runs (a live stand-in, as run-session.sh <x> 312).
for g02_i in 202 311 312 313; do
	mkdir -p "$state/pr/$g02_i"; echo N99 >"$state/pr/$g02_i/node"; echo "Q: which side?" >"$state/pr/$g02_i/QUESTION.md"
done
echo "A: this side" >"$state/pr/311/ANSWER.md"
sh "$G02/fake/run-session.sh" x 312 </dev/null >/dev/null 2>&1 &
g02_sp=$!; pids+=("$g02_sp"); echo "$g02_sp" >"$state/pr/312/session.pid"
g02_kept2() { [ -e "$state/pr/$1/QUESTION.md" ] && [ ! -d "$state/pr/$1/answered" ]; }
g02_names() { ls "$state/pr/311/answered/" 2>/dev/null; }
g02_pair() {   # QUESTION.md and ANSWER.md of 311 are in answered/ under one <ts>-
	local q a
	q=$(ls "$state/pr/311/answered/" | grep -E '^[0-9]{8}T[0-9]{6}Z-QUESTION\.md$') && a=$(ls "$state/pr/311/answered/" | grep -E '^[0-9]{8}T[0-9]{6}Z-ANSWER\.md$') &&
		[ "${q%-QUESTION.md}" = "${a%-ANSWER.md}" ] && [ "$(g02_names | wc -l)" = 2 ]
}
g02_events() { grep -cE "PR #$1 is no longer open.*released" "$state/status.log" 2>/dev/null; }

# The open-PR list has as many lines as the limit: it may be cut short, so nothing moves.
touch "$G02_GD/big"
g02_loop 0
wait_ticks 1   # setup: the loop is running
wait_ticks 3
ok "G02-AC-2 (review1g #1): the open-PR list is as long as its limit (500 lines): a gone PR's QUESTION.md (313) stays" g02_kept2 313
ok "G02-AC-2 (review1g #1): the open-PR list is as long as its limit: QUESTION.md and ANSWER.md (311) stay" sh -c "[ -e '$state/pr/311/QUESTION.md' ] && [ -e '$state/pr/311/ANSWER.md' ] && [ ! -d '$state/pr/311/answered' ]"
ok "G02-AC-2 (review1g #1): the open-PR list is as long as its limit: no release event in the status log" sh -c "! grep -q 'is no longer open' '$state/status.log'"

# The list is whole.
rm -f "$G02_GD/big"
g02_rel() { [ ! -e "$state/pr/$1/QUESTION.md" ] && ls "$state/pr/$1/answered/"*-QUESTION.md >/dev/null 2>&1; }
ok "G02-AC-2 (review1g #1): the list is whole: the gone PR's QUESTION.md (313) moves into answered/" waitf 8 g02_rel 313
ok "G02-AC-2 (review1g #1): and so do QUESTION.md and ANSWER.md of 311" waitf 8 g02_rel 311
wait_ticks 3
ok "G02-AC-2 (review1g #1): a released pair (311) shares one <ts>- prefix in answered/, and answered/ holds nothing else" g02_pair
ok "G02-AC-2 (review1g #1): the status log has one event for 311: 'PR #311 is no longer open ... released'" test "$(g02_events 311)" = 1
ok "G02-AC-2 (review1g #1): the status log has one event for 313: 'PR #313 is no longer open ... released'" test "$(g02_events 313)" = 1
ok "G02-AC-2 (review1g #1): an open node PR by a human (202) keeps its QUESTION.md" g02_kept2 202
ok "G02-AC-2 (review1g #1): a gone PR with a running session (312) keeps its QUESTION.md" g02_kept2 312
ok "G02-AC-2 (review1g #1): and no event names PR 312 or PR 202 as released" sh -c "! grep -E 'PR #(312|202) is no longer open' '$state/status.log'"
g02_stop

loop_end
