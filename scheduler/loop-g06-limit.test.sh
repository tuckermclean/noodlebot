#!/bin/bash
# G06: a pending FEEDBACK.md of a bot PR missing from the open-PR list stays while the list is as long as its --limit (it may be cut short), and moves into answered/ once a shorter list lacks the PR. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g03.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g03.sh"

# A fake gh of this file: while $GD/g06big exists the open-PR list is 500 lines (the loop's --limit) of other PRs, made by awk
# (as loop-g02-gone2.test.sh does); every other call goes to the fixture's gh.
G06=$tmp/G06; mkdir -p "$G06"
cp "$tmp/bin6/gh" "$G06/gh-fixture"
cat >"$tmp/bin6/gh" <<'EOT'
#!/bin/sh
case " $* " in
*" --state open "*) if [ -e "$GD/g06big" ]; then
	awk 'BEGIN { for (n = 1001; n <= 1500; n++) print n " other/b" n " 0000000000000000000000000000000000000000 false MERGEABLE" }'
	exit 0
fi ;;
esac
exec "$G06_FIXTURE_GH" "$@"
EOT
chmod +x "$tmp/bin6/gh"
export G06_FIXTURE_GH=$G06/gh-fixture

# PR 13 (a bot's spec PR) has a pending FEEDBACK.md in pr/13/ and no session; the open-PR list lacks it from the start.
p=$state/pr/13
mkdir -p "$p"
printf 'PR: 13\nBranch: spec/c1\n\nkind: conversation\nid: 321\nurl: %s\nauthor: o\ntime: 2026-11-10T10:00:00Z\nbody: spec point\n' "$(fburl 13 conversation 321)" >"$p/FEEDBACK.md"
touch "$GD/g06big"
rl6 0.01 $(($(date +%s) + 7200))
loop6
wait_ticks 1   # setup: the loop is running
wait_ticks 6
ok "G06-AC-3: the open-PR list is as long as its --limit (500 lines) and lacks PR 13: its FEEDBACK.md stays" test -s "$p/FEEDBACK.md"
ok "G06-AC-3: and nothing is in answered/" sh -c "! ls '$p'/answered/*-FEEDBACK.md >/dev/null 2>&1"
ok "G06-AC-3: no status-log line says it moved" sh -c "! grep -E 'no longer open|FEEDBACK.md moved' '$state/status.log'"

# A shorter list (the fixture's, without PR 13): the PR is gone and the FEEDBACK.md moves, as G03 does.
grep -v '^13 ' "$GD/prs.tsv" >"$GD/prs.tsv.new" && mv "$GD/prs.tsv.new" "$GD/prs.tsv"
rm -f "$GD/g06big"
ok "G06-AC-3: a shorter list that lacks PR 13: FEEDBACK.md leaves pr/13/" waitf 15 test ! -e "$p/FEEDBACK.md"
ok "G06-AC-3: it is in pr/13/answered/ as <ts>-FEEDBACK.md" sh -c "ls '$p'/answered/*-FEEDBACK.md >/dev/null 2>&1"
ok "G06-AC-3: and the status log says PR #13 is no longer open and its FEEDBACK.md moved" sh -c "grep -qE 'PR #13 is no longer open.*FEEDBACK.md moved' '$state/status.log'"
g03_stop
loop_end
