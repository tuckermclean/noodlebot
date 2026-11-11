#!/bin/sh
# Tests scheduler/report.py: each unit's home issue and its milestones (U01-AC-1, U01-AC-2, U01-AC-9).
#   sh scheduler/report-units.test.sh   (make test)
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
ustate=$tmp/ustate
mkdir -p "$ustate/node/T01" "$ustate/node/T02" "$ustate/node/T03" "$ustate/issue/45"
: >"$ustate/status.log"
urun "$ustate"
ustatus=$(uq "[i['number'] for i in db['issues'].values() if 'noodlebot-status' in i['labels']][0]"); ustatus=${ustatus:-200}
ev "started T01 (zero-issues) in /wt, pid 1, start 1 of 2" "$ustate"
ev "started T02 (one-issue) in /wt, pid 2, start 1 of 2" "$ustate"
ev "started T03 (two-issues) in /wt, pid 3, start 1 of 2" "$ustate"
ev "started triage of #45 in /wt, pid 4, start 1 of 2" "$ustate"
ev "session T01 (pid 1) running, log 5 bytes" "$ustate"
ev "usage ok, nothing to do" "$ustate"
ev "stopped session T04 (pid 9)" "$ustate"
ev "released T04 (answered)" "$ustate"
ev "throttle hold: 5-hour window projected high" "$ustate"
urun "$ustate"; rc1=$?
urun "$ustate"; urun "$ustate"
build1=$(cat "$ustate/node/T01/issue" 2>/dev/null)
ok "U01-AC-1: the runs succeed" test "$rc1" = 0
ok "U01-AC-1: a triage's home issue is the issue it triages (issue/45/issue holds 45)" test "$(cat "$ustate/issue/45/issue" 2>/dev/null)" = 45
ok "U01-AC-1: a node with one Resolves issue has it as home (node/T02/issue holds 41)" test "$(cat "$ustate/node/T02/issue" 2>/dev/null)" = 41
ok "U01-AC-1: a node with two Resolves issues has the first as home (node/T03/issue holds 42)" test "$(cat "$ustate/node/T03/issue" 2>/dev/null)" = 42
ok "U01-AC-1: the other issue on the line is linked in the first milestone comment" sh -c "printf '%s\n' \"\$1\" | grep -qF '#43'" _ "$(ufirst 42)"
ok "U01-AC-1: a node with no Resolves line gets one Build issue, over three runs" test "$(ubuilds 'Build T01 zero-issues')" = 1
ok "U01-AC-1: the Build issue is labelled noodlebot-unit" test "$(uq "[i['labels'] for i in db['issues'].values() if i['title'] == 'Build T01 zero-issues'][0]")" = "['noodlebot-unit']"
ok "U01-AC-1: the Build issue is the node's home (node/T01/issue)" test -n "$build1" -a "$build1" = "$(uq "[i['number'] for i in db['issues'].values() if i['title'] == 'Build T01 zero-issues'][0]")"
ok "U01-AC-1: no Build issue for a node that has a Resolves issue" test "$(uq "len([i for i in db['issues'].values() if i['title'].startswith('Build T02') or i['title'].startswith('Build T03')])")" = 0
ok "U01-AC-2: a start is one comment on the node's home issue (one Resolves issue)" test "$(unum 41)" = 1
ok "U01-AC-2: a start is one comment on the home issue (two Resolves issues)" test "$(unum 42)" = 1
ok "U01-AC-2: a start is one comment on the Build issue" test "$(unum "$build1")" = 1
ok "U01-AC-2: a triage's start is one comment on the triaged issue" test "$(unum 45)" = 1
ok "U01-AC-2: each start comment begins with a Stage line" test "$(ucount 41 '\A\*\*Stage:\*\*')" = 1
ok "U01-AC-2: the start comment says its start count" test "$(ucount 41 '1 of 2')" = 1
ok "U01-AC-2: ticks, notes and other units' events add no other comment (all home issues, three runs)" test "$(unum 41)$(unum 42)$(unum 45)$(unum "$build1")" = "1111"
for i in 41 42 45 "$build1"; do ok "U01-AC-2: every comment on issue $i starts with a Stage line" ustage_all "$i"; done

printf 'Q1: which way?\nRecommendation: left.\nQ2: unique-t02-line\n' >"$ustate/node/T02/QUESTION.md"
printf 'Q1: triage question?\nq-unique-triage-line\n' >"$ustate/issue/45/QUESTION.md"
ev "session T02 ended (rc 0) with QUESTION.md" "$ustate"
ev "triage of #45 ended (rc 0) with QUESTION.md" "$ustate"
urun "$ustate"; urun "$ustate"; urun "$ustate"
ok "U01-AC-2: the question is one comment on the home issue holding the whole QUESTION.md, over three runs" test "$(ucontains 41 "$ustate/node/T02/QUESTION.md")" = 1
ok "U01-AC-2: the question comment begins with a Stage line" test "$(ucount 41 '\A\*\*Stage:\*\*(?s:.*)Q2: unique-t02-line')" = 1
ok "U01-AC-2: the question comment has the heading '## T02 asks'" test "$(ucount 41 '(?m)^## T02 asks$')" = 1
ok "U01-AC-2: the node's issue holds the start and the question, nothing else" test "$(unum 41)" = 2
ok "U01-AC-2: a triage's question is one comment on the triaged issue with the whole QUESTION.md" test "$(ucontains 45 "$ustate/issue/45/QUESTION.md")" = 1
ok "U01-AC-2: a triage's question has the heading '## #45 asks'" test "$(ucount 45 '(?m)^## #45 asks$')" = 1
ok "U01-AC-2: the triaged issue holds the start and the question, nothing else" test "$(unum 45)" = 2
for i in 41 45; do ok "U01-AC-2: every comment on issue $i starts with a Stage line (question)" ustage_all "$i"; done

uowner "$ustatus" "T02: go ahead"
urun "$ustate"; rc2=$?
urun "$ustate"; urun "$ustate"
ok "U01-AC-2: an answer on the status issue is recorded (exit 3)" sh -c "[ $rc2 = 3 ] && [ -e '$ustate/node/T02/ANSWER.md' ]"
ok "U01-AC-2: answer received is one comment on the home issue, over three runs" test "$(unum 41)" = 3
ok "U01-AC-2: the answer-received comment begins with a Stage line and is not the question" sh -c "printf '%s\n' \"\$1\" | head -n 1 | grep -q '^\*\*Stage:\*\*' && ! printf '%s\n' \"\$1\" | grep -q unique-t02-line" _ "$(ulast 41)"

rm "$ustate/node/T02/QUESTION.md" "$ustate/node/T02/ANSWER.md"; mkdir "$ustate/node/T02/answered"
ev "started T02 (one-issue) in /wt, pid 5, start 2 of 2" "$ustate"
urun "$ustate"; urun "$ustate"; urun "$ustate"
ok "U01-AC-2: a resume is one comment on the home issue, over three runs" test "$(unum 41)" = 4
ok "U01-AC-2: the resume comment begins with a Stage line, says resumed and its start count" sh -c "printf '%s\n' \"\$1\" | head -n 1 | grep -q '^\*\*Stage:\*\*' && printf '%s\n' \"\$1\" | grep -qi resum && printf '%s\n' \"\$1\" | grep -q '2 of 2'" _ "$(ulast 41)"
ok "U01-AC-2: the first start comment still says 1 of 2 and is not repeated" test "$(ucount 41 '1 of 2')" = 1

printf '2026-02-03T00:00:00Z 2 starts with no PR\nsecond-line-detail-two\n' >"$ustate/node/T03/FAILED"
ev "session T03 ended (rc 0), no PR, no QUESTION.md, 2 starts used: wrote FAILED" "$ustate"
urun "$ustate"; urun "$ustate"; urun "$ustate"
ok "U01-AC-2: FAILED is one comment on the home issue, over three runs" test "$(unum 42)" = 2
ok "U01-AC-2: the FAILED comment begins with a Stage line and holds the first line of FAILED, not the others" sh -c "printf '%s\n' \"\$1\" | head -n 1 | grep -q '^\*\*Stage:\*\*' && printf '%s\n' \"\$1\" | grep -qF '2 starts with no PR' && ! printf '%s\n' \"\$1\" | grep -q second-line-detail-two" _ "$(ulast 42)"
ok "U01-AC-2: the other homes got nothing from the FAILED event or the ticks" test "$(unum 41)$(unum 45)$(unum "$build1")" = "421"
ok "U01-AC-1: the recorded homes are kept after all the runs" test "$(cat "$ustate/node/T02/issue")$(cat "$ustate/node/T03/issue")$(cat "$ustate/issue/45/issue")$(cat "$ustate/node/T01/issue")" = "414245$build1"
ok "U01-AC-1: still one Build issue after all the runs" test "$(ubuilds 'Build T01 zero-issues')" = 1
for i in 41 42 45 "$build1"; do ok "U01-AC-2: every comment on issue $i starts with a Stage line (all milestones)" ustage_all "$i"; done

# U01-AC-9: a failed GitHub call while creating a Build issue or posting a milestone: logged, non-zero, retried once.
ustate2=$tmp/ustate2
mkdir -p "$ustate2/node/T05" "$ustate2/node/T06" "$ustate2/node/T07"
: >"$ustate2/status.log"
rm -f "$tmp/ufail"
urun "$ustate2"
ev "started T05 (zero-again) in /wt, pid 1, start 1 of 2" "$ustate2"
ev "started T06 (six-one) in /wt, pid 2, start 1 of 2" "$ustate2"
echo '/issues Build T05' >"$tmp/ufail"
urun "$ustate2"; rcb=$?
ok "U01-AC-9: a failing Build issue creation exits non-zero" test "$rcb" != 0
ok "U01-AC-9: and logs the error on stderr" test -s "$tmp/uerr"
ok "U01-AC-9: and no Build issue exists yet" test "$(ubuilds 'Build T05 zero-again')" = 0
rm -f "$tmp/ufail"
urun "$ustate2"; rcb2=$?
urun "$ustate2"
ok "U01-AC-9: the next run succeeds and creates the Build issue once" sh -c "[ $rcb2 = 0 ] && [ \"\$1\" = 1 ]" _ "$(ubuilds 'Build T05 zero-again')"
b5=$(cat "$ustate2/node/T05/issue" 2>/dev/null)
ok "U01-AC-9: its start milestone is posted once, over the runs" test "$(unum "$b5")" = 1
ok "U01-AC-9: the other node's start milestone is posted once, over the runs" test "$(unum 46)" = 1

printf 'Q1: retry me?\nretry-unique-line\n' >"$ustate2/node/T06/QUESTION.md"
ev "session T06 ended (rc 0) with QUESTION.md" "$ustate2"
echo 'issues/46/comments' >"$tmp/ufail"
urun "$ustate2"; rcq=$?
ok "U01-AC-9: a failing question post exits non-zero with the error on stderr" sh -c "[ $rcq != 0 ] && [ -s '$tmp/uerr' ]"
ok "U01-AC-9: the question is not on the issue yet" test "$(ucontains 46 "$ustate2/node/T06/QUESTION.md")" = 0
rm -f "$tmp/ufail"
urun "$ustate2"; rcq2=$?
urun "$ustate2"
ok "U01-AC-9: the next run posts the question once" sh -c "[ $rcq2 = 0 ] && [ \"\$1\" = 1 ]" _ "$(ucontains 46 "$ustate2/node/T06/QUESTION.md")"

ev "started T07 (seven-one) in /wt, pid 3, start 1 of 2" "$ustate2"
echo 'issues/47/comments' >"$tmp/ufail"
urun "$ustate2"; rcm=$?
ok "U01-AC-9: a failing start post exits non-zero with the error on stderr" sh -c "[ $rcm != 0 ] && [ -s '$tmp/uerr' ]"
ok "U01-AC-9: the start milestone is not on the issue yet" test "$(unum 47)" = 0
rm -f "$tmp/ufail"
urun "$ustate2"; rcm2=$?
urun "$ustate2"; urun "$ustate2"
ok "U01-AC-9: the next run posts the start once, over three runs" sh -c "[ $rcm2 = 0 ] && [ \"\$1\" = 1 ]" _ "$(unum 47)"

# U01-AC-9: the first run after the change, from a report.json of the old version, posts no milestone for what came before.
ustate3=$tmp/ustate3
mkdir -p "$ustate3/node/T08" "$ustate3/node/T09"
ev "started T08 (eight-one) in /wt, pid 1, start 1 of 2" "$ustate3"
ev "session T08 ended (rc 0) with QUESTION.md" "$ustate3"
printf 'Q1: from before?\nbefore-unique-line\n' >"$ustate3/node/T08/QUESTION.md"
qkey=$(stat -c %Y "$ustate3/node/T08/QUESTION.md")
maxid=$(uq "max([c['id'] for c in db['comments']] or [0])")
printf '{"issue": %s, "comment_id": %s, "log_offset": %s, "questions": {"T08": "%s"}, "body_hash": "x", "body_time": 0}\n' \
	"$ustatus" "$maxid" "$(wc -c <"$ustate3/status.log")" "$qkey" >"$ustate3/report.json"
pyc "
import json
db = json.load(open('$udb'))
db['pulls'] = [{'number': 9, 'head': {'ref': 'node/T08-eight-one', 'sha': 'abc123'}}]
db['checks'] = {'abc123': [{'name': 'test', 'status': 'completed', 'conclusion': 'failure'}]}
db['comments'].append({'id': len(db['comments']) + 1, 'issue': '9', 'body': 'Fresh review (approve)\nfine', 'user': {'login': 'bot', 'type': 'Bot'},
    'author_association': 'NONE', 'created_at': '2026-01-01T00:00:00Z', 'html_url': 'u'})
json.dump(db, open('$udb', 'w'))"
urun "$ustate3"; rc3=$?
urun "$ustate3"
ok "U01-AC-9: the first run after the change succeeds" test "$rc3" = 0
ok "U01-AC-9: it posts no milestone for a start, a question or an open PR from before (nothing on #48)" test "$(unum 48)" = 0
ok "U01-AC-9: and nothing on the PR (its one earlier comment only)" test "$(unum 9)" = 1
ev "started T09 (nine-one) in /wt, pid 2, start 1 of 2" "$ustate3"
urun "$ustate3"
ok "U01-AC-9: a start after the change is posted on its home issue" test "$(unum 50)" = 1
rm -f "$tmp/ufail"


if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
