#!/bin/bash
# G04-AC-6 (end to end): a loop given fake:<path>, with a gh on PATH that fails on any call, uses the fake forge: runtime
# name = the last component of <path>, clones <path>/repo.git, starts a node, sees the node's PR (written by the test as
# the session, into the fake forge's state folder) and stops the session when the test marks the PR merged.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g04.sh"

g04_gh_fail
g04_fake fk1
fk=$G04/fk/fk1
st=$g04data/state/fk1
nodes() { cat "$st/status.log" 2>/dev/null; }
sess() { cat "$st/node/A01/session.pid" 2>/dev/null; }
sess_up() { local p; p=$(sess); [ -n "$p" ] && grp_up "$p"; }
. "$src/testdata/lib/loop-fakes.sh"

g04_run "fake:$fk" fk1
gate=0
if wait_until 15 g04_ticking "$st"; then gate=1; pass "G04-AC-6: fake:<path>: the loop ticks in state/fk1 (the last component of the path)"; else fail "G04-AC-6: fake:<path>: the loop ticks in state/fk1 (the last component of the path)"; fi
if [ "$gate" = 1 ]; then
	ok "G04-AC-6: the clone is repos/fk1, cloned from <path>/repo.git" test "$(git -C "$g04data/repos/fk1" remote get-url origin 2>/dev/null)" = "$fk/repo.git"
	ok "G04-AC-6: the node A01 is started: its session runs" wait_until 15 sess_up
else
	fail "G04-AC-6: the clone is repos/fk1, cloned from <path>/repo.git"
	fail "G04-AC-6: the node A01 is started: its session runs"
fi
if [ "$gate" = 1 ] && sess_up; then
	p=$(sess)
	ok "G04-AC-6: the worktree is worktrees/fk1/A01" test -d "$g04data/worktrees/fk1/A01"
	# the test acts as the session: it writes the node's PR into the fake forge
	python3 - "$fk" <<'PY'
import json, sys
p = sys.argv[1] + "/prs.json"
json.dump([{"number": 7, "title": "A01 first-node", "body": "", "state": "open", "head": "node/A01-first-node",
            "head_sha": "a" * 40, "base": "main", "author": {"login": "noodlebot[bot]", "is_bot": True, "is_owner": False},
            "mergeable": "MERGEABLE", "created_at": "2026-06-01T12:00:00Z", "merged_at": None, "closed_at": None}], open(p, "w"))
PY
	seen() { grep -qE '^7 node/A01-first-node ' "$st/open-prs.tsv" 2>/dev/null && grep -qF 'open=[A01]' "$st/status.log"; }
	ok "G04-AC-6: the loop sees the PR: open-prs.tsv lists #7 on node/A01-first-node and the tick's list names A01" wait_until 10 seen
	wait_ticks 2 "$st"
	ok "G04-AC-6: an open PR stops nothing: the session still runs" grp_up "$p"
	python3 - "$fk" <<'PY'
import json, sys
p = sys.argv[1] + "/prs.json"
d = json.load(open(p))
d[0].update(state="merged", merged_at="2026-06-01T13:00:00Z", closed_at="2026-06-01T13:00:00Z")
json.dump(d, open(p, "w"))
PY
	ok "G04-AC-6: the PR marked merged: the session's process group is gone" wait_until 10 grp_gone "$p"
	ok "G04-AC-6: one status-log line says the session of A01 was stopped, its PR #7 merged" wait_until 5 sh -c "grep -qE 'stopped session A01: its PR #7 is merged' '$st/status.log'"
else
	for c in "the worktree is worktrees/fk1/A01" "the loop sees the PR: open-prs.tsv lists #7 on node/A01-first-node and the tick's list names A01" \
		"an open PR stops nothing: the session still runs" "the PR marked merged: the session's process group is gone" \
		"one status-log line says the session of A01 was stopped, its PR #7 merged"; do fail "G04-AC-6: $c"; done
fi
g04_stop
if [ "$gate" = 1 ]; then ok "G04-AC-6: the failing gh was never called" test ! -e "$G04/gh.called"; else fail "G04-AC-6: the failing gh was never called (the loop did not tick on the fake forge)"; fi
[ ! -e "$G04/gh.called" ] || sed 's/^/      gh called: /' "$G04/gh.called" | head -5
loop_end
