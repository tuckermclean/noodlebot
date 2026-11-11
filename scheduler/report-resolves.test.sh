#!/bin/sh
# Tests scheduler/report.py: answers to units that share issues, old report.json files, reopened issues (U01-AC-4, U01-AC-6, U01-AC-9).
#   sh scheduler/report-resolves.test.sh   (make test)
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
# U01-AC-4 (S2b): an owner comment led by the ID of a unit that is not waiting is not the waiting unit's answer.
mkspec V10 share-wait '#54'
mkspec V11 share-done '#54'
mkspec V12 lone-asker ''
git -C "$uclone" add nodes && git -C "$uclone" -c user.name=t -c user.email=t@t commit -q -m specs3 &&
	git -C "$uclone" update-ref refs/remotes/origin/main HEAD
ustate6=$tmp/ustate6
mkdir -p "$ustate6/node/V10" "$ustate6/node/V11" "$ustate6/node/V12"
: >"$ustate6/status.log"
urun "$ustate6"
printf 'Q1: wait?\nv10-unique-q-line\n' >"$ustate6/node/V10/QUESTION.md"
printf 'Q1: done?\nv11-unique-q-line\n' >"$ustate6/node/V11/QUESTION.md"
printf 'Q1: lone?\nv12-unique-q-line\n' >"$ustate6/node/V12/QUESTION.md"
ev "session V10 ended (rc 0) with QUESTION.md" "$ustate6"
ev "session V11 ended (rc 0) with QUESTION.md" "$ustate6"
ev "session V12 ended (rc 0) with QUESTION.md" "$ustate6"
urun "$ustate6"; urun "$ustate6"
uowned 54 "V11: yes" https://x/s6-v11
urun "$ustate6"; urun "$ustate6"
ok "U01-AC-4: (precondition) V10 and V11 share issue 54 and V11 is answered by its ID prefix, V10 still waits" sh -c "[ \"\$(cat '$ustate6/node/V10/issue' 2>/dev/null)\$(cat '$ustate6/node/V11/issue' 2>/dev/null)\" = 5454 ] && grep -q '^V11: yes\$' '$ustate6/node/V11/ANSWER.md' && [ ! -e '$ustate6/node/V10/ANSWER.md' ]"
uowned 54 "V11: actually no" https://x/s6-v11-again
urun "$ustate6"; urun "$ustate6"; urun "$ustate6"
ok "U01-AC-4: a comment led by the ID of a unit that is not waiting (V11, answered) is not recorded as the waiting unit's (V10) answer" sh -c "[ ! -e '$ustate6/node/V10/ANSWER.md' ] && ! grep -q 'actually no' '$ustate6/node/V11/ANSWER.md'"
ok "U01-AC-4: and gets one reply over repeated runs, saying it is not recorded" test "$(ubcount 54 '\A(?!\*\*Stage:)Not recorded')" = 1
ok "U01-AC-4: and no reaction" test "$(ureact https://x/s6-v11-again)" = 0
h12=$(cat "$ustate6/node/V12/issue" 2>/dev/null)
uowned "$h12" "Q12: go ahead" https://x/s6-q12
urun "$ustate6"; urun "$ustate6"
ok "U01-AC-4: a leading token that only looks like an ID (Q12:, no such unit) with one waiting unit is that unit's answer" sh -c "grep -q '^Q12: go ahead\$' '$ustate6/node/V12/ANSWER.md'"
ok "U01-AC-4: and it gets one +1 reaction" test -n "$h12" -a "$(ureact https://x/s6-q12)" = 1

# Risks (S2b): a spec-PR update task (state pr/<N>/) is not a unit and has no home issue.
nis6=$(uq "len(db['issues'])")
mkdir -p "$ustate6/pr/77"
printf '2026-02-04T00:00:00Z second exit (rc 1) without finishing\npr77-detail\n' >"$ustate6/pr/77/FAILED"
printf 'Q1: update?\npr77-unique-q-line\n' >"$ustate6/pr/77/QUESTION.md"
urun "$ustate6"; urun "$ustate6"; urun "$ustate6"
ok "Risks: a pr/<N> folder with FAILED and QUESTION.md creates no issue (no Build PR issue, issue count unchanged)" test "$(uq "len(db['issues'])")" = "$nis6" -a "$(uq "len([i for i in db['issues'].values() if 'PR #' in i['title']])")" = 0
ok "Risks: and no pr/<N>/issue file is written" test ! -e "$ustate6/pr/77/issue"
ok "Risks: and no comment (milestone or question) names PR #77 or its question" test "$(uq "len([c for c in db['comments'] if 'PR #77' in c['body'] or 'pr77-unique-q-line' in c['body']])")" = 0

# U01-AC-9 + U01-AC-6 (S3b): the first run of this version on a report.json of the old version closes nothing that was
# merged before it, comments on nothing, and still closes a candidate held at that run once the hold ends.
pyc "
import json
db = json.load(open('$udb'))
for n in range(71, 77):
    db['issues'][str(n)] = {'number': n, 'title': 'Seeded %d' % n, 'body': '', 'labels': [], 'state': 'open', 'node_id': 'I_%d' % n}
db['issues']['71']['state'] = 'closed'
json.dump(db, open('$udb', 'w'))"
mkspec Y01 old-merged '#71, #72'
mkspec Y02 old-asking '#73'
mkspec Y03 old-shared-a '#74'
mkspec Y04 old-shared-b '#74'
mkspec Z01 reopened ''
git -C "$uclone" add nodes && git -C "$uclone" -c user.name=t -c user.email=t@t commit -q -m specs4 &&
	git -C "$uclone" update-ref refs/remotes/origin/main HEAD
ok "U01-AC-6: (self-check) the PATCH pattern matches a logged call and not another issue's" sh -c "printf 'PATCH repos/owner/repo/issues/73\nPATCH repos/owner/repo/issues/730\n' | grep -c '^PATCH repos/owner/repo/issues/73\$' | grep -qx 1"

ustate7=$tmp/ustate7
mkdir -p "$ustate7/node/Y01" "$ustate7/node/Y02" "$ustate7/node/Y03" "$ustate7/node/Y04"
: >"$ustate7/status.log"
usetpulls '[]'
printf 'Q1: asking when merged?\ny02-unique-q-line\n' >"$ustate7/node/Y02/QUESTION.md"
printf '401 node/Y01-old-merged\n402 node/Y02-old-asking\n403 node/Y03-old-shared-a\n' >"$ustate7/merged-prs.tsv"
yqkey=$(stat -c %Y "$ustate7/node/Y02/QUESTION.md")
ymax=$(uq "max([c['id'] for c in db['comments']] or [0])")
printf '{"issue": %s, "comment_id": %s, "log_offset": 0, "questions": {"Y02": "%s"}, "body_hash": "x", "body_time": 0}\n' \
	"$ustatus" "$ymax" "$yqkey" >"$ustate7/report.json"
: >"$tmp/ucalls"
urun "$ustate7"; rcy=$?
ok "U01-AC-9: the first run on an old report.json succeeds" test "$rcy" = 0
ok "U01-AC-9: it posts no comment on an already-closed Resolves issue of a node merged before (71)" test "$(unum 71)" = 0
ok "U01-AC-9: nor on the still-open one (72)" test "$(unum 72)" = 0
ok "U01-AC-9: it makes no PATCH of the closed Resolves issue (71)" test "$(upatches 71)" = 0
ok "U01-AC-9: nor of the open one (72)" test "$(upatches 72)" = 0
ok "U01-AC-9: and 72 is still open, 71 still closed" test "$(ustateof 72)$(ustateof 71)" = openclosed
urun "$ustate7"; urun "$ustate7"; urun "$ustate7"
ok "U01-AC-9: over further runs nothing is posted on 71 or 72" test "$(unum 71)$(unum 72)" = 00
ok "U01-AC-9: over further runs nothing is closed or changed for them (no PATCH of 71 or 72, 72 open)" test "$(upatches 71)$(upatches 72)" = 00 -a "$(ustateof 72)" = open
ok "U01-AC-6: a candidate held at that first run (73: its unit's question is open) is not closed and has no comment" test "$(ustateof 73)" = open -a "$(unum 73)" = 0 -a "$(upatches 73)" = 0
ok "U01-AC-6: a candidate held by another node not merged (74: Y04) is not closed and has no comment" test "$(ustateof 74)" = open -a "$(unum 74)" = 0 -a "$(upatches 74)" = 0
rm "$ustate7/node/Y02/QUESTION.md"; mkdir "$ustate7/node/Y02/answered"
urun "$ustate7"; urun "$ustate7"; urun "$ustate7"
ok "U01-AC-6: at the first run after the question is released, the held candidate (73) is closed" test "$(ustateof 73)" = closed
ok "U01-AC-6: with one comment naming the PR (402), once over three runs" test "$(ucount 73 '(#|pull/)402\b')" = 1
ok "U01-AC-6: and one PATCH closing it" test "$(upatches 73)" = 1
ok "U01-AC-6: the other held candidate (74) still waits for Y04" test "$(ustateof 74)" = open -a "$(unum 74)" = 0
echo "404 node/Y04-old-shared-b" >>"$ustate7/merged-prs.tsv"
urun "$ustate7"
ok "U01-AC-6: at the first run after the other node is merged, 74 is closed" test "$(ustateof 74)" = closed
n74=$(unum 74)
urun "$ustate7"; urun "$ustate7"
ok "U01-AC-6: with a comment naming a merged PR (403 or 404), none added over further runs" test "$(ucount 74 '(#|pull/)40[34]\b')" -ge 1 -a "$(unum 74)" = "$n74"
ok "U01-AC-6: the closing is one comment (the merged milestone of Y04 and the closing comment: two at most)" test "$n74" -ge 1 -a "$n74" -le 2
ok "U01-AC-6: and one PATCH closing it" test "$(upatches 74)" = 1
ok "U01-AC-9: and still nothing for the issues of the node merged before (71, 72)" test "$(unum 71)$(unum 72)$(upatches 71)$(upatches 72)" = 0000

# U01-AC-6 (S3b): a home issue closed by someone else is reopened by the unit's new QUESTION.md, which is posted there once.
ustate8=$tmp/ustate8
mkdir -p "$ustate8/node/Z01"
: >"$ustate8/status.log"
urun "$ustate8"
ev "started Z01 (reopened) in /wt, pid 1, start 1 of 2" "$ustate8"
urun "$ustate8"; urun "$ustate8"
z1=$(cat "$ustate8/node/Z01/issue" 2>/dev/null)
ok "U01-AC-6: (precondition) Z01 has a Build issue as home with its start posted" test -n "$z1" -a "$(unum "$z1")" = 1
pyc "
import json
db = json.load(open('$udb')); db['issues']['$z1']['state'] = 'closed'; json.dump(db, open('$udb', 'w'))"
printf 'Q1: reopen me?\nz01-unique-q-line\n' >"$ustate8/node/Z01/QUESTION.md"
ev "session Z01 ended (rc 0) with QUESTION.md" "$ustate8"
urun "$ustate8"; urun "$ustate8"; urun "$ustate8"
ok "U01-AC-6: a new QUESTION.md of a unit whose home issue was closed by someone else reopens that issue" test "$(ustateof "$z1")" = open
ok "U01-AC-6: and the question is posted there once, in full" test "$(ucontains "$z1" "$ustate8/node/Z01/QUESTION.md")" = 1
ok "U01-AC-6: the reopened issue is not closed again by the loop and holds the start and the question only" test "$(unum "$z1")" = 2


if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
