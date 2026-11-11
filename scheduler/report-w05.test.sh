#!/bin/sh
# Tests scheduler/report.py: links to the status site, with --site and without (W05-AC-2, W05-AC-3, W05-AC-4).
#   sh scheduler/report-w05.test.sh   (make test)
# One scripted scenario (testdata/lib/report-w05.sh) runs twice on a fake gh: with --site and without it. The run without
# --site is compared with testdata/report-w05.golden, made with report.py as it was before W05.
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
fakegh_lib=$src/testdata/lib
. "$fakegh_lib/report-fakegh.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
ok() { name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
pyc_setup
. "$fakegh_lib/report-units.sh"
. "$fakegh_lib/report-sessions.sh"
rs_script
. "$fakegh_lib/report-w05.sh"
S=https://ex.github.io/noodlebot
L() { printf '%s/#/repo/owner/repo?node=%s' "$S" "$1"; }
ACT=$S/#/activity?repo=owner/repo

w05_scenario site "$S"
o=$tmp/site/out
has() { grep -qF -- "$2" "$o/$1"; }          # has <file> <text>: the text is somewhere in the file
hasline() { grep -qxF -- "$2" "$o/$1"; }     # hasline <file> <text>: a line of the file is exactly the text
lacks() { ! grep -qF -- "$2" "$o/$1"; }
ok "W05-AC-2: (harness) the five runs with --site succeed" test "$(tr -d '\n' <"$o/rc")" = 00000
ok "W05-AC-2: the log issue's body has the status-site line under the title, as change 3 gives it" sh -c "sed -n 1,4p '$o/logbody' | grep -qxF -- '**Status site:** [owner/repo]($S/#/repo/owner/repo) · [throttle]($S/#/throttle) · [activity]($ACT)'"
ok "W05-AC-2: the body links a running session's heading" has logbody "### [K04]($(L K04)), running for"
ok "W05-AC-2: the body links the waiting items (a question, two FAILED)" sh -c "grep -qF -- '[K03]($(L K03))' '$o/logbody' && grep -qF -- '[K05]($(L K05))' '$o/logbody' && grep -qF -- '[K07]($(L K07))' '$o/logbody'"
ok "W05-AC-2: the body leaves an ID inside a code span (the FAILED path) as it is" has logbody "delete \`$tmp/site/state/node/K05/FAILED\`"
ok "W05-AC-2: the body does not link an ID in a session's narration (copied text)" hasline logbody "> Working on K01 and K02 now."
ok "W05-AC-2: the body does not link a word that is not a graph node (K98)" sh -c "grep -qF 'K98 FAILED' '$o/logbody' && ! grep -qF '[K98](' '$o/logbody'"
ok "W05-AC-2: the overview links the waiting items" sh -c "grep -qF -- '[K03]($(L K03))' '$o/overview' && grep -qF -- '[K05]($(L K05))' '$o/overview'"
ok "W05-AC-2: the overview links the nodes ready next" sh -c "grep -qF -- '- [K01]($(L K01)) one-name' '$o/overview' && grep -qF -- '- [K04]($(L K04)) four-name' '$o/overview'"
ok "W05-AC-2: the overview links the FAILED unit of yesterday's summary, not a word that is no node (K99)" sh -c "grep 'Units that wrote FAILED' '$o/overview' | grep -qF '[K05]($(L K05))' && ! grep -qF '[K99](' '$o/overview'"
ok "W05-AC-2: the overview does not link a word that is not a graph node (K98)" sh -c "grep -qF 'K98 FAILED' '$o/overview' && ! grep -qF '[K98](' '$o/overview'"
ok "W05-AC-2: the closing summary links the FAILED unit (K07)" sh -c "grep 'Units that wrote FAILED' '$o/summary' | grep -qF '[K07]($(L K07))'"
ok "W05-AC-2: the closing summary does not link a word that is no node (K99)" sh -c "grep -qF 'K99' '$o/summary' && ! grep -qF '[K99](' '$o/summary'"
ok "W05-AC-2: an event comment links the nodes of a started line" sh -c "grep -qF -- 'started [K06]($(L K06)) (six-name)' '$o/events' && grep -qF -- 'started [K07]($(L K07)) (seven-name)' '$o/events'"
ok "W05-AC-2: an event comment links the node of an ended line" has events "session [K07]($(L K07)) ended (rc 0)"
ok "W05-AC-2: an event comment leaves a code span, an existing link, a URL and a non-node alone, and links the node" has events "released [K01]($(L K01)) (answered) see \`K02\` and [K03](https://example.com/x) and https://example.com/K01 and K99"
ok "W05-AC-2: a non-node in an event comment (K99) is not linked, a node of the same comment is" sh -c "grep -qF '[K06](' '$o/events' && grep -qF 'K99' '$o/events' && ! grep -qF '[K99](' '$o/events'"
ok "W05-AC-2: the question note on the log issue links the node in its heading and leaves the code span" sh -c "grep -qxF -- '## [K03]($(L K03)) asks' '$o/asksnote' && grep -qF 'starting the reply with \`K03:\`' '$o/asksnote'"

ok "W05-AC-3: a Build issue's body has the line linking the node's view" hasline buildbody "On the status site: [K06 six-name]($(L K06))"
ok "W05-AC-3: a node unit's first milestone on an existing issue has the same line" hasline c41 "On the status site: [K07 seven-name]($(L K07))"
ok "W05-AC-3: the line is on the first milestone only (once over the issue's two milestones)" test "$(grep -cF 'On the status site: [K07 seven-name]' "$o/all")" = 1
ok "W05-AC-3: a node unit whose first milestone is its question has the line too" hasline c42 "On the status site: [K03 three-name]($(L K03))"
ok "W05-AC-3: a triage unit's first milestone links the repository's activity view" hasline c45 "On the status site: [triage issues of owner/repo]($ACT)"
ok "W05-AC-3: a node mention in a milestone's stage line is linked" has c42 "**Stage:** [K03]($(L K03)) asks a question, waiting for your answer"
ok "W05-AC-3: a node mention in the loop's own text of a milestone is linked (the question's heading)" hasline c42 "## [K03]($(L K03)) asks"
ok "W05-AC-3: the QUESTION.md naming nodes is posted byte for byte as written" test "$(cat "$o/qcopied")" = 1
ok "W05-AC-3: the QUESTION.md's own mentions and links are not linked" sh -c "grep -qxF -- 'Q1: merge K01 before K02?' '$o/c42' && grep -qxF -- 'See [K02](https://example.com/q) and \`K01\`; K03 agrees.' '$o/c42'"

# An event line as loop.sh writes it for a follow-up start: the leading ID is a mention, the ID in the worktree path and in the
# branch name is not. One more run on the site scenario's state (wd, wsite and the helpers still name the run with --site).
{
	echo "2026-05-10T09:21:00Z open=[] merged-prs=[]; started K06 (six-name) as a follow-up on node/K06-six-name in $tmp/worktrees/repo/K06, pid 8, start 1 of 2"
	echo "2026-05-10T09:21:01Z open=[] merged-prs=[]; started K07 (seven-name) in $tmp/worktrees/repo/K07, pid 9, start 1 of 2"
} >>"$wstate/status.log"
wrun 2026-05-10T09:25:00 6
W="$wd" pyc "
import json, os
d = os.environ['W']; db = json.load(open(d + '/gh.json'))
open(d + '/out/events2', 'w').write('\\n'.join(c['body'] for c in db['comments'] if c['body'].startswith('- \`')))"
ok "W05-AC-2: (harness) the extra run with --site succeeds" test "$(tail -n 1 "$o/rc")" = 0
ok "W05-AC-2: an event comment links the leading node of a follow-up start line, not the ID in its branch name or worktree path" sh -c "grep -qF -- 'started [K06]($(L K06)) (six-name) as a follow-up on node/K06-six-name in $tmp/worktrees/repo/K06, pid' '$o/events2'"
ok "W05-AC-2: an event comment leaves an ID that ends the worktree path (/<ID>) unlinked" sh -c "grep -qF -- 'in $tmp/worktrees/repo/K07, pid' '$o/events2' && grep -qF -- 'started [K07]($(L K07)) (seven-name) in' '$o/events2'"

# Without --site: the same scenario posts what report.py posted before W05 (the golden).
w05_scenario plain
w05_norm "$tmp/plain" >"$tmp/plain.norm"
ok "W05-AC-4: (harness) the five runs without --site succeed" test "$(tr -d '\n' <"$tmp/plain/out/rc")" = 00000
ok "W05-AC-4: every body and comment posted without --site is byte for byte what report.py posted before W05" cmp -s "$tmp/plain.norm" "$src/testdata/report-w05.golden"
if ! cmp -s "$tmp/plain.norm" "$src/testdata/report-w05.golden"; then diff "$src/testdata/report-w05.golden" "$tmp/plain.norm" | head -n 12; fi
ok "W05-AC-4: without --site no link to a site is posted" sh -c "! grep -qE 'status site|/#/' '$tmp/plain/out/all'"

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
