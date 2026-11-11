#!/bin/sh
# Tests scheduler/report.py: the PR milestones of a unit, a triage's done and the closing of resolved issues (U01-AC-3, U01-AC-6).
#   sh scheduler/report-prs.test.sh   (make test)
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
ustatus_init
pyc "
import json
db = json.load(open('$udb'))
for n in range(51, 55):
    db['issues'][str(n)] = {'number': n, 'title': 'Seeded %d' % n, 'body': '', 'labels': [], 'state': 'open', 'node_id': 'I_%d' % n}
json.dump(db, open('$udb', 'w'))"
mkspec V04 share-a '#51'
mkspec V05 share-b '#51'
mkspec V06 share-triage '#52'
git -C "$uclone" add nodes && git -C "$uclone" -c user.name=t -c user.email=t@t commit -q -m specs2 &&
	git -C "$uclone" update-ref refs/remotes/origin/main HEAD
# U01-AC-3, U01-AC-6: the PR milestones on a node's home issue, a triage's done, and the loop closing (and reopening) the
# issues a merged node resolves.
pyc "
import json
db = json.load(open('$udb'))
for n in range(55, 71):
    db['issues'][str(n)] = {'number': n, 'title': 'Seeded %d' % n, 'body': '', 'labels': [], 'state': 'open', 'node_id': 'I_%d' % n}
json.dump(db, open('$udb', 'w'))"
mkspec W01 pr-one '#55'
mkspec W02 pr-two '#55'
mkspec W03 closer '#56'
mkspec X01 solo '#58'
mkspec X02 pair '#59, #60'
mkspec X03 build-me ''
mkspec X06 asks '#62'
mkspec X07 follows '#63'
git -C "$uclone" add nodes && git -C "$uclone" -c user.name=t -c user.email=t@t commit -q -m specs3 &&
	git -C "$uclone" update-ref refs/remotes/origin/main HEAD
# self-check of the patterns used below against the text they are meant to match
ok "U01-AC-3: (self-check) the Stage pattern matches a stage line" umatch '\A\*\*Stage:\*\*' '**Stage:** PR #312 open, final review running'
ok "U01-AC-3: (self-check) the PR-naming pattern matches '#312' and a pull URL" sh -c "P='(#|pull/)312\\b'; pyc \"import re,sys; sys.exit(0 if re.search(sys.argv[1], '#312') and re.search(sys.argv[1], 'https://github.com/owner/repo/pull/312.') and not re.search(sys.argv[1], '#3120') else 1)\" \"\$P\""

ustate5=$tmp/ustate5
mkdir -p "$ustate5/node/W01" "$ustate5/node/W02" "$ustate5/node/W03" "$ustate5/issue/57" "$ustate5/issue/69" \
	"$ustate5/node/X01" "$ustate5/node/X02" "$ustate5/node/X03" "$ustate5/node/X06" "$ustate5/node/X07"
: >"$ustate5/status.log"
rm -f "$tmp/ufail"
usetpulls '[]'
urun "$ustate5"
ev "started W01 (pr-one) in /wt, pid 1, start 1 of 2" "$ustate5"
ev "started W03 (closer) in /wt, pid 2, start 1 of 2" "$ustate5"
ur3
ok "U01-AC-3: (precondition) W01's start is the one comment on its home issue (55)" test "$(unum 55)" = 1
ok "U01-AC-3: (precondition) W03's start is the one comment on its home issue (56)" test "$(unum 56)" = 1

# the PR opened, with its link, once; no CI result while a check run is still running
usetchecks s1 '[{"name": "test", "status": "completed", "conclusion": "success"}, {"name": "build", "status": "in_progress", "conclusion": null}]'
usetpulls "[$(upull 312 node/W01-pr-one s1), $(upull 314 node/W03-closer s3)]"
usetchecks s3 '[{"name": "test", "status": "completed", "conclusion": "success"}]'
ur3
ok "U01-AC-3: the PR opened is one comment on the home issue, over three runs (CI still running adds none)" test "$(unum 55)" = 2
ok "U01-AC-3: the PR-opened comment has the PR's link" test "$(ucount 55 'github\.com/owner/repo/pull/312\b')" = 1
ok "U01-AC-3: the PR-opened comment begins with a Stage line" test "$(ucount 55 '\A\*\*Stage:\*\*(?s:.*)pull/312\b')" = 1
ok "U01-AC-3: the other node's PR opened is on its own home issue (56), with its CI result (all check runs complete)" test "$(ucount 56 'pull/314\b')" = 1 -a "$(unum 56)" = 3

# the CI result once all check runs are complete: passed
usetchecks s1 '[{"name": "test", "status": "completed", "conclusion": "success"}, {"name": "build", "status": "completed", "conclusion": "success"}]'
ur3
ok "U01-AC-3: the CI result is posted once all check runs are complete, once over three runs" test "$(unum 55)" = 3
ok "U01-AC-3: it says the checks passed and begins with a Stage line" umatch '(?is)\A\*\*Stage:\*\*.*(pass|success|green)' "$(ulast 55)"
ok "U01-AC-3: the other node's CI result says passed" test "$(ucount 56 '(?is)\A\*\*Stage:\*\*.*(pass|success|green)')" = 1

# a new head commit: one more CI result, with the failing checks' names, after all its check runs complete
usetchecks s2 '[{"name": "test", "status": "completed", "conclusion": "success"}, {"name": "lint", "status": "completed", "conclusion": "failure"}, {"name": "unit", "status": "queued", "conclusion": null}]'
usetpulls "[$(upull 312 node/W01-pr-one s2), $(upull 314 node/W03-closer s3)]"
ur3
ok "U01-AC-3: a new head commit with a check run still queued adds no CI result" test "$(unum 55)" = 3
usetchecks s2 '[{"name": "test", "status": "completed", "conclusion": "success"}, {"name": "lint", "status": "completed", "conclusion": "failure"}, {"name": "unit", "status": "completed", "conclusion": "failure"}]'
ur3
ok "U01-AC-3: once the new head's check runs are complete its CI result is posted once (a CI result per head commit)" test "$(unum 55)" = 4
ok "U01-AC-3: the failed CI result names the failing checks (lint, unit)" sh -c "printf '%s\n' \"\$1\" | grep -q 'lint' && printf '%s\n' \"\$1\" | grep -q 'unit' && printf '%s\n' \"\$1\" | head -n 1 | grep -q '^\*\*Stage:\*\*'" _ "$(ulast 55)"
ok "U01-AC-3: the earlier head's CI result is not repeated" test "$(ucount 55 '(?is)\A\*\*Stage:\*\*.*(pass|success|green)')" = 1

# each Fresh review verdict once
ucomment 312 $'Fresh review (approve)\nlooks fine' 2026-02-03T00:00:00Z bot NONE Bot https://x/312/1
ucomment 312 $'Thanks, will look later' 2026-02-03T00:01:00Z owner OWNER User https://x/312/2
ur3
ok "U01-AC-3: a Fresh review (approve) PR comment gives one milestone with its verdict, once over three runs" test "$(unum 55)" = 5 -a "$(ucount 55 '(?i)approve')" = 1
ok "U01-AC-3: another PR comment adds nothing (the owner's thanks)" test "$(ucount 55 'Thanks, will look later|will look later')" = 0
ucomment 312 $'Fresh review (request_changes)\nthe lint failure' 2026-02-03T00:02:00Z bot NONE Bot https://x/312/3
ur3
ok "U01-AC-3: a second Fresh review (request_changes) gives one more milestone with its verdict, once" test "$(unum 55)" = 6 -a "$(ucount 55 '(?i)request.changes')" = 1
ok "U01-AC-3: the verdict milestone begins with a Stage line" umatch '(?is)\A\*\*Stage:\*\*.*request.changes' "$(ulast 55)"
ok "U01-AC-3: every milestone comment on W01's home issue begins with a Stage line" ustage_all 55
ok "U01-AC-3: every milestone comment on W03's home issue begins with a Stage line" ustage_all 56

# merged once (the issue is also on W02's Resolves line, so it stays open: no closing comment mixes in)
usetpulls "[$(upull 314 node/W03-closer s3)]"
echo "312 node/W01-pr-one" >"$ustate5/merged-prs.tsv"
echo "312 node/W01-pr-one 2026-02-04T00:00:00Z true" >"$ustate5/closed-prs.tsv"
ur3
ok "U01-AC-3: a merged PR gives one merged milestone naming the PR, once over three runs" test "$(unum 55)" = 7 -a "$(ucount 55 '(?i)merged')" -ge 1
ok "U01-AC-3: the merged milestone names the PR and begins with a Stage line" umatch '(?is)\A\*\*Stage:\*\*.*(#|pull/)312\b' "$(ulast 55)"
ok "U01-AC-3: a merged PR is not reported as closed without merging" test "$(ucount 55 '(?i)closed without')" = 0
ok "U01-AC-6: the issue stays open while another node resolving it (W02) is not merged" test "$(ustateof 55)" = open

# closed without merging once (the issue is not closed: the node is not merged)
usetpulls '[]'
echo "314 node/W03-closer 2026-02-04T00:00:00Z false" >>"$ustate5/closed-prs.tsv"
ur3
ok "U01-AC-3: a PR closed without merging gives one milestone, once over three runs" test "$(unum 56)" = 4
ok "U01-AC-3: the closed milestone says closed and names the PR, with a Stage line" umatch '(?is)\A\*\*Stage:\*\*.*clos.*' "$(ulast 56)"
ok "U01-AC-3: and names the PR number" umatch '(#|pull/)314\b' "$(ulast 56)"
ok "U01-AC-6: a PR closed without merging does not close its home issue" test "$(ustateof 56)" = open

# a triage that ends done: done once, with its spec PR when there is one
ev "started triage of #57 in /wt, pid 9, start 1 of 2" "$ustate5"
ev "started triage of #69 in /wt, pid 10, start 1 of 2" "$ustate5"
ur3
usetpulls "[$(upull 320 spec/triage-57-foo s9)]"
ev "triage of #57 done (rc 0); its label is now noodlebot-triaged" "$ustate5"
ev "triage of #69 done (rc 0); its label is now noodlebot-triaged" "$ustate5"
ur3
ok "U01-AC-3: a triage that ends done posts done once, with its spec PR (over three runs)" test "$(ucount 57 '(?is)\A(?=.*pull/320\b)(?=.*\bdone\b)')" = 1
ok "U01-AC-3: that comment begins with a Stage line" test "$(ucount 57 '(?is)\A\*\*Stage:\*\*(?=.*pull/320\b)(?=.*\bdone\b)')" = 1
ok "U01-AC-3: a triage that ends done with no spec PR posts done once, without a PR link" test "$(ucount 69 '(?i)\bdone\b')" = 1 -a "$(ucount 69 'pull/')" = 0
ok "U01-AC-3: its comment begins with a Stage line" test "$(ucount 69 '(?is)\A\*\*Stage:\*\*(?=.*\bdone\b)')" = 1
ok "U01-AC-6: a triage never closes its issue (57 and 69 stay open, nothing else closes them)" test "$(ustateof 57)$(ustateof 69)" = openopen
usetpulls '[]'

# U01-AC-6: closing. A node's last issue closes after the merge, with one comment naming the PR.
# The shared issue (55): W02 merged too -> closed at the first run after that holds.
echo "313 node/W02-pr-two" >>"$ustate5/merged-prs.tsv"
urun "$ustate5"
ok "U01-AC-6: when the last node resolving the issue is merged, the next run closes it" test "$(ustateof 55)" = closed
ok "U01-AC-6: and the closing comment names the merged PR (313)" test "$(ucount 55 '(#|pull/)313\b')" -ge 1
n55=$(unum 55)
urun "$ustate5"; urun "$ustate5"
ok "U01-AC-6: the close is not repeated (no further comment, still closed)" test "$(unum 55)" = "$n55" -a "$(ustateof 55)" = closed

# a node with one Resolves issue
ev "started X01 (solo) in /wt, pid 3, start 1 of 2" "$ustate5"
ev "started X02 (pair) in /wt, pid 4, start 1 of 2" "$ustate5"
ev "started X03 (build-me) in /wt, pid 5, start 1 of 2" "$ustate5"
ev "started X06 (asks) in /wt, pid 6, start 1 of 2" "$ustate5"
ev "started X07 (follows) in /wt, pid 7, start 1 of 2" "$ustate5"
ur3
xb=$(cat "$ustate5/node/X03/issue" 2>/dev/null)
ok "U01-AC-6: (precondition) the homes exist and are open before any merge" test "$(ustateof 58)$(ustateof 59)$(ustateof 60)" = openopenopen -a -n "$xb" -a "$(ustateof "${xb:-0}")" = open
printf 'Q1: hold the issue?\nx06-unique-q-line\n' >"$ustate5/node/X06/QUESTION.md"
ev "session X06 ended (rc 0) with QUESTION.md" "$ustate5"
mkdir "$ustate5/node/X07/answered"
echo node/X07-followup-1 >"$ustate5/node/X07/FOLLOWUP"
ur3
ok "U01-AC-6: (precondition) X06's question is posted on its home issue" test "$(ucontains 62 "$ustate5/node/X06/QUESTION.md")" = 1
printf '%s\n' "331 node/X01-solo" "332 node/X02-pair" "333 node/X03-build-me" "336 node/X06-asks" "337 node/X07-follows" >>"$ustate5/merged-prs.tsv"
urun "$ustate5"
ok "U01-AC-6: a merged node's home issue (the only Resolves issue) is closed" test "$(ustateof 58)" = closed
ok "U01-AC-6: it has a comment naming the merged PR (331)" test "$(ucount 58 '(#|pull/)331\b')" -ge 1
ok "U01-AC-6: both issues on a Resolves line are closed (home 59)" test "$(ustateof 59)" = closed
ok "U01-AC-6: and the other issue on the line (60)" test "$(ustateof 60)" = closed
ok "U01-AC-6: each of them has a comment naming the PR (332)" test "$(ucount 59 '(#|pull/)332\b')" -ge 1 -a "$(ucount 60 '(#|pull/)332\b')" -ge 1
ok "U01-AC-6: a merged node's Build issue is closed" test "$(ustateof "${xb:-0}")" = closed
ok "U01-AC-6: and has a comment naming the PR (333)" test "$(ucount "${xb:-0}" '(#|pull/)333\b')" -ge 1
ok "U01-AC-6: an issue whose unit has an open question stays open" test "$(ustateof 62)" = open
ok "U01-AC-6: an issue whose unit has a follow-up in progress (FOLLOWUP marker) stays open" test "$(ustateof 63)" = open
urun "$ustate5"; urun "$ustate5"
c58=$(ucount 58 '(#|pull/)331\b')
ok "U01-AC-6: over more runs the held issues stay open and the closed ones get no further comments" test "$(ustateof 62)$(ustateof 63)" = openopen -a "$(ucount 58 '(#|pull/)331\b')" = "$c58" -a "$(ucount 60 '(#|pull/)332\b')" = 1

# the question is answered but not released: still held
echo "Q1: go" >"$ustate5/node/X06/ANSWER.md"
urun "$ustate5"
ok "U01-AC-6: an answered question not yet released (QUESTION.md and ANSWER.md both there) still holds the issue open" test "$(ustateof 62)" = open
# released: QUESTION.md and ANSWER.md moved into answered/
mkdir "$ustate5/node/X06/answered" && rm "$ustate5/node/X06/QUESTION.md" "$ustate5/node/X06/ANSWER.md"
urun "$ustate5"
ok "U01-AC-6: once the answer is released, the first run after closes the issue" test "$(ustateof 62)" = closed
ok "U01-AC-6: with a comment naming the PR (336)" test "$(ucount 62 '(#|pull/)336\b')" -ge 1
# follow-up done: FOLLOWUP marker moved into answered/
mv "$ustate5/node/X07/FOLLOWUP" "$ustate5/node/X07/answered/FOLLOWUP"
urun "$ustate5"
ok "U01-AC-6: once the follow-up is done (no FOLLOWUP marker), the first run after closes the issue" test "$(ustateof 63)" = closed
ok "U01-AC-6: with a comment naming the PR (337)" test "$(ucount 63 '(#|pull/)337\b')" -ge 1

# a new QUESTION.md of a unit whose home issue is closed reopens the issue and posts the question there
printf 'Q1: one more thing?\nreopen-unique-line\n' >"$ustate5/node/X01/QUESTION.md"
ev "session X01 ended (rc 0) with QUESTION.md" "$ustate5"
urun "$ustate5"; urun "$ustate5"; urun "$ustate5"
ok "U01-AC-6: a new question on a closed home issue reopens it" test "$(ustateof 58)" = open
ok "U01-AC-6: and the question is posted there once, whole, with its heading" test "$(ucontains 58 "$ustate5/node/X01/QUESTION.md")" = 1 -a "$(ucount 58 '(?m)^## X01 asks$')" = 1
ok "U01-AC-6: the reopened issue is not closed again while the question is open" test "$(ustateof 58)" = open
rm "$ustate5/node/X01/QUESTION.md"; mkdir "$ustate5/node/X01/answered"
urun "$ustate5"
ok "U01-AC-6: and it closes again at the first run after the question is released" test "$(ustateof 58)" = closed
ok "U01-AC-6: no node or triage issue other than the resolved ones was closed (triage issues 57 and 69 stay open)" test "$(ustateof 57)$(ustateof 69)" = openopen
ok "U01-AC-6: the status issue is still open" test "$(ustateof "$ustatus")" = open


if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
