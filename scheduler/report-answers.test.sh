#!/bin/sh
# Tests scheduler/report.py: answers on home issues and on the status issue (U01-AC-4, U01-AC-5, U01-AC-7).
#   sh scheduler/report-answers.test.sh   (make test)
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
# U01-AC-4, U01-AC-5, U01-AC-7: answers on home issues, answers on the status issue, the status issue linking questions.
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

ustate4=$tmp/ustate4
mkdir -p "$ustate4/node/V01" "$ustate4/node/V02" "$ustate4/node/V04" "$ustate4/node/V05" "$ustate4/node/V06" "$ustate4/issue/52" \
	"$ustate4/node/V07" "$ustate4/node/V08" "$ustate4/node/V09" "$ustate4/issue/53"
: >"$ustate4/status.log"
rm -f "$tmp/ufail"
urun "$ustate4"
printf 'Q1: which way?\nv01-unique-q-line\n' >"$ustate4/node/V01/QUESTION.md"
ev "session V01 ended (rc 0) with QUESTION.md" "$ustate4"
urun "$ustate4"; urun "$ustate4"
h1=$(cat "$ustate4/node/V01/issue" 2>/dev/null)
ucomment "$h1" "early answer" 2026-01-15T00:00:00Z owner OWNER User https://x/v01-early
ucomment "$h1" "stranger answer" 2026-02-02T00:00:00Z mallory NONE User https://x/v01-other
ucomment "$h1" "member answer" 2026-02-02T00:00:00Z owner MEMBER User https://x/v01-member
ucomment "$h1" "bot answer" 2026-02-02T00:00:00Z owner OWNER Bot https://x/v01-bot
urun "$ustate4"; urun "$ustate4"; rcv=$?
ok "U01-AC-4: a comment from before the question, or by someone else (login, association, Bot), is not recorded" test -n "$h1" -a ! -e "$ustate4/node/V01/ANSWER.md"
ok "U01-AC-4: and gets no reply and no reaction (the home issue holds only the question)" sh -c "[ \"\$1\" = 1 ] && [ \"\$2\" = 0 ]" _ "$(ubn "$h1")" "$(uq "len(db['reactions'])")"
uowned "$h1" "go left" https://x/v01-own
urun "$ustate4"; rcv=$?
urun "$ustate4"; urun "$ustate4"
ok "U01-AC-4: an owner comment after the question becomes ANSWER.md without an ID prefix, exit 3" sh -c "[ $rcv = 3 ] && grep -q '^go left\$' '$ustate4/node/V01/ANSWER.md'"
ok "U01-AC-4: ANSWER.md carries the comment's URL" grep -qF 'https://x/v01-own' "$ustate4/node/V01/ANSWER.md"
ok "U01-AC-4: the comment gets one +1 reaction over three runs" test "$(ureact https://x/v01-own)" = 1
ok "U01-AC-4: and nothing else gets a reaction" test "$(uq "len(db['reactions'])")" = 1
ok "U01-AC-4: the answer-received milestone is one comment (with the URL), and there is no other reply" sh -c "[ \"\$1\" = 1 ] && [ \"\$2\" = 2 ]" _ "$(ubcount "$h1" 'https://x/v01-own')" "$(ubn "$h1")"
ok "U01-AC-4: the answer-received milestone begins with a Stage line" test "$(ubcount "$h1" '\A\*\*Stage:\*\*(?s:.*)https://x/v01-own')" = 1

ev "started V02 (no-question) in /wt, pid 1, start 1 of 2" "$ustate4"
urun "$ustate4"
h2=$(cat "$ustate4/node/V02/issue" 2>/dev/null)
uowned "$h2" "answer to nothing" https://x/v02-own
urun "$ustate4"; urun "$ustate4"; urun "$ustate4"
ok "U01-AC-4: with no question open, an owner comment is not recorded" test -n "$h2" -a ! -e "$ustate4/node/V02/ANSWER.md"
ok "U01-AC-4: and gets exactly one reply saying so (start + one reply), over three runs" sh -c "[ \"\$1\" = 2 ] && [ \"\$2\" = 1 ]" _ "$(ubn "$h2")" "$(ubcount "$h2" '\A(?!\*\*Stage:)(?i:(?s:.*)(not recorded|no question|not waiting|nothing))')"
ok "U01-AC-4: and gets no reaction" test "$(ureact https://x/v02-own)" = 0

printf 'Q1: share a?\nv04-unique-q-line\n' >"$ustate4/node/V04/QUESTION.md"
printf 'Q1: share b?\nv05-unique-q-line\n' >"$ustate4/node/V05/QUESTION.md"
ev "session V04 ended (rc 0) with QUESTION.md" "$ustate4"
ev "session V05 ended (rc 0) with QUESTION.md" "$ustate4"
urun "$ustate4"; urun "$ustate4"
uowned 51 "approve" https://x/share-plain
urun "$ustate4"; urun "$ustate4"; urun "$ustate4"
ok "U01-AC-4: two units share issue 51 (the first Resolves issue)" test "$(cat "$ustate4/node/V04/issue" 2>/dev/null)$(cat "$ustate4/node/V05/issue" 2>/dev/null)" = 5151
ok "U01-AC-4: two waiting units: an unprefixed comment is not recorded for either" sh -c "[ ! -e '$ustate4/node/V04/ANSWER.md' ] && [ ! -e '$ustate4/node/V05/ANSWER.md' ]"
ok "U01-AC-4: and gets one reply naming both units, over three runs" test "$(ubcount 51 '\A(?!\*\*Stage:)(?s:.*V04.*V05|.*V05.*V04)')" = 1
ok "U01-AC-4: and no reaction" test "$(ureact https://x/share-plain)" = 0
uowned 51 "V05: yes" https://x/share-v05
urun "$ustate4"; rcs=$?
urun "$ustate4"; urun "$ustate4"
ok "U01-AC-4: a comment starting with an ID is that unit's answer (V05), exit 3" sh -c "[ $rcs = 3 ] && grep -q '^V05: yes\$' '$ustate4/node/V05/ANSWER.md' && [ ! -e '$ustate4/node/V04/ANSWER.md' ]"
ok "U01-AC-4: it gets one +1 reaction and the URL in ANSWER.md" sh -c "[ \"\$1\" = 1 ] && grep -qF https://x/share-v05 '$ustate4/node/V05/ANSWER.md'" _ "$(ureact https://x/share-v05)"
ok "U01-AC-4: no second reply was posted (2 questions, 1 reply, 1 answer milestone)" test "$(ubn 51)" = 4

printf 'Q1: triage shared?\nt52-unique-q-line\n' >"$ustate4/issue/52/QUESTION.md"
printf 'Q1: node shared?\nv06-unique-q-line\n' >"$ustate4/node/V06/QUESTION.md"
ev "triage of #52 ended (rc 0) with QUESTION.md" "$ustate4"
ev "session V06 ended (rc 0) with QUESTION.md" "$ustate4"
urun "$ustate4"; urun "$ustate4"
uowned 52 "looks fine" https://x/tri-plain
urun "$ustate4"; urun "$ustate4"
ok "U01-AC-4: a triage of 52 and a node resolving 52: an unprefixed comment is not recorded" sh -c "[ ! -e '$ustate4/issue/52/ANSWER.md' ] && [ ! -e '$ustate4/node/V06/ANSWER.md' ]"
ok "U01-AC-4: and gets one reply naming both, over repeated runs" test "$(ubcount 52 '\A(?!\*\*Stage:)(?s:.*V06.*#52|.*#52.*V06)')" = 1
uowned 52 "**V06**: go" https://x/tri-v06
urun "$ustate4"; rct=$?
urun "$ustate4"
ok "U01-AC-4: a comment starting with **V06** is V06's answer and not the triage's, exit 3" sh -c "[ $rct = 3 ] && grep -qF '**V06**: go' '$ustate4/node/V06/ANSWER.md' && [ ! -e '$ustate4/issue/52/ANSWER.md' ]"
ok "U01-AC-4: it gets one +1 reaction" test "$(ureact https://x/tri-v06)" = 1

# U01-AC-5
printf 'Q1: status first?\n' >"$ustate4/node/V07/QUESTION.md"
printf 'Q1: home first?\n' >"$ustate4/node/V08/QUESTION.md"
ev "session V07 ended (rc 0) with QUESTION.md" "$ustate4"
ev "session V08 ended (rc 0) with QUESTION.md" "$ustate4"
urun "$ustate4"; urun "$ustate4"
h7=$(cat "$ustate4/node/V07/issue" 2>/dev/null); h8=$(cat "$ustate4/node/V08/issue" 2>/dev/null)
uowner "$ustatus" "V07: via status"
urun "$ustate4"; rc7=$?
cp "$ustate4/node/V07/ANSWER.md" "$tmp/v07.answer" 2>/dev/null
ok "U01-AC-5: a prefixed answer on the status issue is still recorded (exit 3)" sh -c "[ $rc7 = 3 ] && grep -q '^V07: via status\$' '$ustate4/node/V07/ANSWER.md'"
uowned "$h7" "later on home" https://x/v07-later
urun "$ustate4"; urun "$ustate4"
ok "U01-AC-5: answered on the status issue, a later comment on the home issue is not recorded" sh -c "cmp -s '$tmp/v07.answer' '$ustate4/node/V07/ANSWER.md' && ! grep -q 'later on home' '$ustate4/node/V07/ANSWER.md'"
uowned "$h8" "home answer" https://x/v08-home
urun "$ustate4"; rc8h=$?
cp "$ustate4/node/V08/ANSWER.md" "$tmp/v08.answer" 2>/dev/null
uowner "$ustatus" "V08: later on status"
urun "$ustate4"; urun "$ustate4"
ok "U01-AC-5: answered on the home issue (exit 3), a later prefixed comment on the status issue is not written over ANSWER.md" sh -c "[ $rc8h = 3 ] && cmp -s '$tmp/v08.answer' '$ustate4/node/V08/ANSWER.md' && grep -q '^home answer\$' '$ustate4/node/V08/ANSWER.md'"

# U01-AC-7
printf 'Q1: status link?\nv09-unique-q-line\n' >"$ustate4/node/V09/QUESTION.md"
printf 'Q1: triage link?\nt53-unique-q-line\n' >"$ustate4/issue/53/QUESTION.md"
ev "session V09 ended (rc 0) with QUESTION.md" "$ustate4"
ev "triage of #53 ended (rc 0) with QUESTION.md" "$ustate4"
urun "$ustate4"; urun "$ustate4"
h9=$(cat "$ustate4/node/V09/issue" 2>/dev/null)
sbody=$(uq "db['issues']['$ustatus']['body']")
url9=$(uq "[c['html_url'] for c in db['comments'] if c['issue'] == '$h9' and '## V09 asks' in c['body']][0]")
url53=$(uq "[c['html_url'] for c in db['comments'] if c['issue'] == '53' and '## #53 asks' in c['body']][0]")
ok "U01-AC-7: the node's question is on its home issue (precondition)" test -n "$url9" -a -n "$h9"
ok "U01-AC-7: the status issue has no comment with the node's QUESTION.md in full (nor its text)" test "$(ucontains "$ustatus" "$ustate4/node/V09/QUESTION.md")$(ucount "$ustatus" 'v09-unique-q-line')" = 00
ok "U01-AC-7: nor the triage's" test "$(ucontains "$ustatus" "$ustate4/issue/53/QUESTION.md")$(ucount "$ustatus" 't53-unique-q-line')" = 00
ok "U01-AC-7: nor any earlier question (T02, V01)" test "$(ucount "$ustatus" 'unique-t02-line|v01-unique-q-line|v04-unique-q-line')" = 0
ok "U01-AC-7: the Waiting on you item for the node's question links its comment on the home issue" sh -c "printf '%s\n' \"\$1\" | grep V09 | grep -qF \"\$2\"" _ "$sbody" "$url9"
ok "U01-AC-7: the item for the triage's question links its comment on the triaged issue" sh -c "printf '%s\n' \"\$1\" | grep '#53' | grep -qF \"\$2\"" _ "$sbody" "$url53"
ok "U01-AC-7: the status issue's events are still posted (session V09 ended, once)" test "$(ucount "$ustatus" 'session V09 ended')" = 1
ok "U01-AC-7: the footer says to answer on the unit's issue" sh -c "printf '%s\n' \"\$1\" | grep -qi \"unit's issue\"" _ "$sbody"
ok "U01-AC-7: the footer says a prefixed reply on the status issue still works" sh -c "printf '%s\n' \"\$1\" | grep -qi 'prefix'" _ "$sbody"
rm -f "$tmp/ufail"


if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
