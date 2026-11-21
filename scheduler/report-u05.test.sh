#!/bin/sh
# Tests scheduler/report.py: the frozen-line fields of the merge record of each open node PR and the frozen-line wording of
# a ready PR's "Waiting on you" item (U05-AC-2, U05-AC-3).
#   sh scheduler/report-u05.test.sh   (make test)
#
# THE CONTRACT these checks fix (the implementation must write exactly this).
#
# 1. report.json, key "merge", the entry of each open node PR (U04's keys stay), gets two more keys:
#      "frozen"   "none", or the number <n> (a JSON integer, 1 or more) of the `Frozen test lines changed: <n>` line of the
#                 last comment whose first line is headed `Fresh review (<verdict>)`, or null when that comment has no such
#                 line (`Frozen test lines changed: none` gives "none") or there is no review;
#      "approved" the <sha>, as written (7 to 40 hex characters), of the last conversation comment by the owner (login, not
#                 a bot, author_association OWNER) whose first line, without surrounding whitespace, is exactly
#                 `Frozen lines approved at <sha>`, any text after the first line accepted; else null.
#    Both survive runs that read no new comment. Another user, the bot, an author the forge does not mark as the owner, a
#    quoted line and more text on the first line make no approval.
# 2. The item of a PR that U04 makes ready (an approving review at the head, CI passed, no session, no question):
#      frozen a number, the head does not start with "approved":
#        <ID>'s PR #<N> changes frozen test lines: needs your approval (reviewed at <sha>, CI passed)
#      frozen a number, the head starts with "approved":
#        <ID>'s PR #<N> is ready to merge (frozen test line changes approved; reviewed at <sha>, CI passed)
#      U04's note "the forge has not said whether it merges cleanly" follows either when it applies;
#      frozen "none" or null, and a PR that is not ready: U04's item.
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
fakegh_lib=$src/testdata/lib
. "$fakegh_lib/report-fakegh.sh"
tmp=$(mktemp -d) && [ -d "$tmp" ] || exit 1
spids=
trap 'kill $spids 2>/dev/null; rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
ok() { name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
pyc_setup
. "$fakegh_lib/report-units.sh"
ustatus_init

nl=$(printf '\n_'); nl=${nl%_}
N=26
state=$tmp/U05/s
mkdir -p "$state"
: >"$state/status.log"

mksha() { printf '%s%02x%036d' "$1" "$2" 0; } # <2 hex chars> <number>: a 40-character sha
use() { # <i>: the case's node, PR, head, short head
	i=$1
	id=$(printf 'K%02d' "$i")
	pr=$((500 + i))
	eval "head=\${hd$i:-}"
	[ -n "$head" ] || head=$(mksha ab "$i")
	sh7=$(printf %s "$head" | cut -c1-7)
	eval "mg=\${mg$i:-MERGEABLE}"
}
publish() { # the PR list and open-prs.tsv of every case
	pulls=
	: >"$state/open-prs.tsv"
	i=1
	while [ "$i" -le "$N" ]; do
		use "$i"
		pulls="$pulls${pulls:+, }$(upull "$pr" "node/$id-x" "$head")"
		printf '%s\tnode/%s-x\t%s\tfalse\t%s\n' "$pr" "$id" "$head" "$mg" >>"$state/open-prs.tsv"
		i=$((i + 1))
	done
	usetpulls "[$pulls]"
}
rn=0
stamp() { rn=$((rn + 1)); printf '2026-03-%02dT%02d:%02d:00Z' $((1 + rn / 1440)) $((rn / 60 % 24)) $((rn % 60)); }
review() { # <i> <verdict> <sha> <body after the first line>
	use "$1"
	ucomment "$pr" "Fresh review ($2) at $3${4:+$nl$4}" "$(stamp)" bot NONE Bot "https://x/$pr/$rn"
}
frozen() { # <i> <sha> <count or none>: an approving review that records the frozen lines
	if [ "$3" = none ]; then
		review "$1" approve "$2" "looks fine${nl}Frozen test lines changed: none"
	else
		review "$1" approve "$2" "looks fine${nl}Frozen test lines changed: $3${nl}scheduler/a.test.sh:12 at c0ffee1${nl}scheduler/b.test.sh:3 at c0ffee1${nl}The PR needs the owner's approval: a comment by the owner whose first line is Frozen lines approved at $2"
	fi
}
said() { # <i> <login> <association> <type> <body>: a comment of the PR by that author
	use "$1"
	ucomment "$pr" "$5" "$(stamp)" "$2" "$3" "$4" "https://x/$pr/$rn"
}
approve() { said "$1" owner OWNER User "$2"; } # <i> <body>: a comment by the owner
chk() { usetchecks "$1" '[{"name": "test", "status": "completed", "conclusion": "success"}, {"name": "lint", "status": "completed", "conclusion": "success"}]'; }
chkfail() { usetchecks "$1" '[{"name": "test", "status": "completed", "conclusion": "success"}, {"name": "lint", "status": "completed", "conclusion": "failure"}]'; }
go() { urun "$state"; }
show() {
	uq "sorted((i for i in db['issues'].values() if 'noodlebot-status' in i['labels'] and i['title'].startswith('noodlebot log')), key=lambda i: i['number'])[-1]['body']" >"$tmp/body"
	awk '/^## Waiting on you/ {f=1; next} /^## / {f=0} f' "$tmp/body" >"$tmp/wait"
}
item() { use "$1"; grep -F "$id" "$tmp/wait" | grep -E "PR #$pr([^0-9]|\$)" >"$tmp/item"; }
rec() { # <i> <key>: the merge record's value as JSON (ABSENT when the PR has no record; null when the record lacks frozen or approved)
	use "$1"
	pyc "import json,sys; m = (json.load(open(sys.argv[1])).get('merge') or {}).get(sys.argv[2]); print('ABSENT' if m is None else json.dumps(m[sys.argv[3]]) if sys.argv[3] in m else 'null' if sys.argv[3] in ('frozen', 'approved') else 'ABSENT')" "$state/report.json" "$pr" "$2"
}
rc() { [ "$(rec "$1" "$2")" = "$3" ]; }
has() { grep -qF -- "$1" "$tmp/item"; }
needs() { # <i> [note]: the frozen-line item that asks for the approval
	use "$1"; item "$1"
	has "$id's PR #$pr changes frozen test lines: needs your approval (reviewed at $sh7, CI passed)" && ! has 'ready to merge' && ! has 'still being worked on' &&
		{ [ "${2:-}" != note ] || has 'the forge has not said whether it merges cleanly'; } &&
		{ [ "${2:-}" = note ] || ! has 'has not said'; }
}
approved() { # <i> [note]: the item that says ready with the frozen-line changes approved
	use "$1"; item "$1"
	has "$id's PR #$pr is ready to merge (frozen test line changes approved; reviewed at $sh7, CI passed)" && ! has 'needs your approval' && ! has 'still being worked on' &&
		{ [ "${2:-}" != note ] || has 'the forge has not said whether it merges cleanly'; } &&
		{ [ "${2:-}" = note ] || ! has 'has not said'; }
}
plain() { # <i>: U04's ready item, without any frozen-line text
	use "$1"; item "$1"
	has "$id's PR #$pr is ready to merge (reviewed at $sh7, CI passed)" && ! has 'frozen' && ! has 'needs your approval'
}
notready() { # <i> <text it has>: U04's still-being-worked-on item, without frozen-line text
	item "$1"
	has 'still being worked on' && has "$2" && ! has 'ready to merge' && ! has 'frozen' && ! has 'needs your approval'
}
shortof() { use "$1"; printf %s "$sh7"; }
headof() { use "$1"; printf %s "$head"; }

usetpulls '[]'
go

# Phase 1. Every case is a node with its open PR that U04 makes ready (an approving review at the head, CI passed, no
# session, no question) unless it says otherwise; the owner's comments and the review's frozen line are what differ.
mg16=UNKNOWN; mg17=UNKNOWN
N=33 # cases 27-33 (the line's markdown forms) are added to the same state folder and runs
i=1
while [ "$i" -le "$N" ]; do
	use "$i"
	mkdir -p "$state/node/$id"
	chk "$head"
	i=$((i + 1))
done
use 15; chkfail "$head"
# 1: none.  2: 2 lines, no approval.  3: the approval names the whole head.  4: seven characters.
use 1; frozen 1 "$sh7" none
use 2; frozen 2 "$sh7" 2
use 3; frozen 3 "$sh7" 2;  approve 3 "Frozen lines approved at $head"
use 4; frozen 4 "$sh7" 2;  approve 4 "Frozen lines approved at $sh7"
# 5: approved at its first head (a push and a new review follow in phase 2)
use 5; frozen 5 "$sh7" 2;  approve 5 "Frozen lines approved at $sh7"
# 6-10: the same first line from another user, the bot, the owner's login without the owner mark, another login marked owner, a bot of the owner's login
use 6;  frozen 6 "$sh7" 2;  said 6 stranger NONE User "Frozen lines approved at $head"
use 7;  frozen 7 "$sh7" 2;  said 7 bot NONE Bot "Frozen lines approved at $head"
use 8;  frozen 8 "$sh7" 2;  said 8 owner CONTRIBUTOR User "Frozen lines approved at $head"
use 9;  frozen 9 "$sh7" 2;  said 9 stranger OWNER User "Frozen lines approved at $head"
use 10; frozen 10 "$sh7" 2; said 10 owner OWNER Bot "Frozen lines approved at $head"
# 11: quoted.  12: more text on the first line.
use 11; frozen 11 "$sh7" 2; approve 11 "> Frozen lines approved at $head"
use 12; frozen 12 "$sh7" 2; approve 12 "Frozen lines approved at $head thanks"
# 13: the owner's words after the first line.
use 13; frozen 13 "$sh7" 2; approve 13 "Frozen lines approved at $sh7${nl}I read the two lines. Go ahead."
# 14: a review with no frozen line
use 14; review 14 approve "$sh7" "looks fine"
# 15: CI failed.  16: UNKNOWN, no approval.  17: UNKNOWN, approved.
use 15; frozen 15 "$sh7" 2; approve 15 "Frozen lines approved at $sh7"
use 16; frozen 16 "$sh7" 2
use 17; frozen 17 "$sh7" 2; approve 17 "Frozen lines approved at $sh7"
# 18: six hex characters.  19: surrounding whitespace.
use 18; frozen 18 "$sh7" 2; approve 18 "Frozen lines approved at $(printf %s "$head" | cut -c1-6)"
use 19; frozen 19 "$sh7" 2; approve 19 "  Frozen lines approved at $sh7  "
# 20: an earlier approval, then the one at the head (the last counts).  21: the approval, then an ordinary owner comment.
use 20; frozen 20 "$sh7" 2; approve 20 "Frozen lines approved at $(mksha cd 20)"; approve 20 "Frozen lines approved at $head"
use 21; frozen 21 "$sh7" 2; approve 21 "Frozen lines approved at $sh7"; approve 21 'thanks, looking'
# 22: a review with 2 lines, then the last review says none.  23: no review at all, but an approval.
use 22; frozen 22 "$sh7" 2; approve 22 "Frozen lines approved at $sh7"; frozen 22 "$sh7" none
use 23; approve 23 "Frozen lines approved at $sh7"
# 24: the frozen line well below the first lines.  25: not hex.  26: 41 hex characters.
use 24; review 24 approve "$sh7" "looks fine${nl}one${nl}two${nl}Frozen test lines changed: 3${nl}more"
use 25; frozen 25 "$sh7" 2; approve 25 "Frozen lines approved at zzzzzzz"
use 26; frozen 26 "$sh7" 2; approve 26 "Frozen lines approved at ${head}a"
# 27: a list item.  28, 29: bold.  30: backticks, none.  31: CRLF line endings.  32: quoted.  33: more text after the count.
use 27; review 27 approve "$sh7" "looks fine${nl}- Frozen test lines changed: 2"
use 28; review 28 approve "$sh7" "looks fine${nl}**Frozen test lines changed:** 3"
use 29; review 29 approve "$sh7" "looks fine${nl}**Frozen test lines changed: 3**"
use 30; review 30 approve "$sh7" "looks fine${nl}\`Frozen test lines changed: none\`"
use 31; review 31 approve "$sh7" "$(printf 'looks fine\r\nFrozen test lines changed: 4\r\nscheduler/a.test.sh:1 at c0ffee1\r')"
use 32; review 32 approve "$sh7" "looks fine${nl}> Frozen test lines changed: 2"
use 33; review 33 approve "$sh7" "looks fine${nl}Frozen test lines changed: 2 lines"
publish
go
show

ok "U05-AC-3: (precondition) the Waiting on you section is there" test -s "$tmp/wait"
# 1: none
ok "U05-AC-2: (1) review says none: the record's frozen is \"none\"" rc 1 frozen '"none"'
ok "U05-AC-2: (1) no approval: the record's approved is null" rc 1 approved null
ok "U05-AC-3: (1) frozen none: U04's ready item" plain 1
# 2: two lines, no approval
ok "U05-AC-2: (2) review says 2: the record's frozen is the number 2" rc 2 frozen 2
ok "U05-AC-2: (2) no approval comment: approved is null" rc 2 approved null
ok "U05-AC-3: (2) the item says the PR needs the owner's approval" needs 2
# 3, 4: the approval names the head
ok "U05-AC-2: (3) the owner's approval at the whole head: approved is that sha" rc 3 approved "\"$(headof 3)\""
ok "U05-AC-2: (3) the record's frozen is 2" rc 3 frozen 2
ok "U05-AC-3: (3) the item says ready to merge with the frozen test line changes approved" approved 3
ok "U05-AC-2: (4) the approval names seven characters of the head: approved is those seven" rc 4 approved "\"$(shortof 4)\""
ok "U05-AC-3: (4) a seven-character prefix of the head counts: ready, changes approved" approved 4
# 5: approved at the first head
ok "U05-AC-3: (5, precondition) approved at its head: ready, changes approved" approved 5
# 6-10: not the owner
ok "U05-AC-2: (6) the same first line from another user: approved is null" rc 6 approved null
ok "U05-AC-3: (6) another user's line is no approval: needs approval" needs 6
ok "U05-AC-2: (7) the same first line from the bot: approved is null" rc 7 approved null
ok "U05-AC-3: (7) the bot's line is no approval: needs approval" needs 7
ok "U05-AC-2: (8) the owner's login without the forge's owner mark: approved is null" rc 8 approved null
ok "U05-AC-3: (8) no owner mark, no approval: needs approval" needs 8
ok "U05-AC-2: (9) another login marked as owner: approved is null" rc 9 approved null
ok "U05-AC-3: (9) another login is no approval: needs approval" needs 9
ok "U05-AC-2: (10) the owner's login typed Bot: approved is null" rc 10 approved null
ok "U05-AC-3: (10) a bot is no approval: needs approval" needs 10
# 11, 12: quoted, more text
ok "U05-AC-2: (11) the line quoted: approved is null" rc 11 approved null
ok "U05-AC-3: (11) a quoted line is no approval: needs approval" needs 11
ok "U05-AC-2: (12) more text on the first line: approved is null" rc 12 approved null
ok "U05-AC-3: (12) more text on the first line is no approval: needs approval" needs 12
# 13: words below the first line
ok "U05-AC-2: (13) the owner's words after the first line: approved is the sha" rc 13 approved "\"$(shortof 13)\""
ok "U05-AC-3: (13) words after the first line: ready, changes approved" approved 13
# 14: no frozen line
ok "U05-AC-2: (14) a review with no frozen line: frozen is null" rc 14 frozen null
ok "U05-AC-3: (14) no frozen line: U04's ready item" plain 14
# 15: CI failed
ok "U05-AC-2: (15) CI failed: the record still has frozen 2" rc 15 frozen 2
ok "U05-AC-3: (15) CI failed: U04's still being worked on item, no frozen-line text" notready 15 'CI failed'
# 16, 17: UNKNOWN
ok "U05-AC-3: (16) mergeable UNKNOWN, frozen 2, no approval: needs approval, with the forge note" needs 16 note
ok "U05-AC-3: (17) mergeable UNKNOWN, frozen 2, approved: ready, changes approved, with the forge note" approved 17 note
# 18, 19
ok "U05-AC-2: (18) six hex characters: approved is null" rc 18 approved null
ok "U05-AC-3: (18) six hex characters is no approval: needs approval" needs 18
ok "U05-AC-2: (19) the first line with surrounding whitespace: approved is the sha" rc 19 approved "\"$(shortof 19)\""
ok "U05-AC-3: (19) whitespace around the line: ready, changes approved" approved 19
# 20, 21: the last approval, an ordinary comment after it
ok "U05-AC-2: (20) the last approval comment counts: approved is the head" rc 20 approved "\"$(headof 20)\""
ok "U05-AC-3: (20) an earlier approval and then one at the head: ready, changes approved" approved 20
ok "U05-AC-2: (21) an ordinary owner comment after the approval does not take it away" rc 21 approved "\"$(shortof 21)\""
ok "U05-AC-3: (21) ready, changes approved" approved 21
# 22: the last review says none
ok "U05-AC-2: (22) the last review says none after one that said 2: frozen is \"none\"" rc 22 frozen '"none"'
ok "U05-AC-3: (22) frozen none: U04's ready item" plain 22
# 23: no review
ok "U05-AC-2: (23) no review: frozen is null, an approval is still recorded" test "$(rec 23 frozen)/$(rec 23 approved)" = "null/\"$(shortof 23)\""
ok "U05-AC-3: (23) no review: U04's still being worked on item (no final review)" notready 23 'no final review'
# 24: the line below
ok "U05-AC-2: (24) the frozen line below the first lines is found: frozen is 3" rc 24 frozen 3
ok "U05-AC-3: (24) the item says the PR needs the owner's approval" needs 24
# 25, 26
ok "U05-AC-2: (25) seven characters that are not hex: approved is null" rc 25 approved null
ok "U05-AC-2: (26) 41 characters: approved is null" rc 26 approved null
ok "U05-AC-3: (26) 41 characters is no approval: needs approval" needs 26
# 27-33: how the frozen line is written
ok "U05-AC-2: (27) the line as a list item: frozen is 2" rc 27 frozen 2
ok "U05-AC-2: (28) the line in bold with the colon inside: frozen is 3" rc 28 frozen 3
ok "U05-AC-2: (29) the whole line in bold: frozen is 3" rc 29 frozen 3
ok "U05-AC-2: (30) the line in backticks, none: frozen is \"none\"" rc 30 frozen '"none"'
ok "U05-AC-2: (31) CRLF line endings: frozen is 4" rc 31 frozen 4
ok "U05-AC-2: (32) the line quoted is not read: frozen is null" rc 32 frozen null
ok "U05-AC-2: (33) more text after the count is not read: frozen is null" rc 33 frozen null
ok "U05-AC-3: (27) a list-item line with a count: the item says the PR needs the owner's approval" needs 27
ok "U05-AC-3: (31) a CRLF line with a count: the item says the PR needs the owner's approval" needs 31

# Phase 2. Runs that read no new comment keep the record; a push after the approval; an approval that comes later.
pyc "
import json
db = json.load(open('$udb'))
for c in db['comments']:
    if 500 < int(c['issue']) <= 500 + $N: c['issue'] = '0'
json.dump(db, open('$udb', 'w'))"
# 5: a pushed commit, CI passed on it, a new final review at the new head; the old approval names the earlier head
hd5=$(mksha cd 5)
use 5; chk "$hd5"
frozen 5 "$(printf %s "$hd5" | cut -c1-7)" 2
# 2, 14: the owner approves now, after the review
use 2; approve 2 "Frozen lines approved at $sh7${nl}ok"
use 14; approve 14 "Frozen lines approved at $sh7"
publish
go
show
ok "U05-AC-2: (5, push) the record has the new head" rc 5 head "\"$hd5\""
ok "U05-AC-2: (5, push) the record keeps the earlier approval" rc 5 approved "\"ab05000\""
ok "U05-AC-2: (5, push) frozen is 2 from the new review" rc 5 frozen 2
ok "U05-AC-3: (5, push) an approval naming an earlier head does not count: needs approval again" needs 5
ok "U05-AC-2: (2, later approval) approved is the sha" rc 2 approved "\"$(shortof 2)\""
ok "U05-AC-3: (2, later approval) the approval comes after the review: ready, changes approved" approved 2
ok "U05-AC-2: (14, later approval) frozen stays null, approved is the sha" test "$(rec 14 frozen)/$(rec 14 approved)" = "null/\"$(shortof 14)\""
ok "U05-AC-3: (14, later approval) frozen null: still U04's ready item" plain 14
ok "U05-AC-2: (no new comment) 1: frozen \"none\", approved null kept" test "$(rec 1 frozen)/$(rec 1 approved)" = '"none"/null'
ok "U05-AC-2: (no new comment) 3: frozen 2 and the approval kept" test "$(rec 3 frozen)/$(rec 3 approved)" = "2/\"$(headof 3)\""
ok "U05-AC-2: (no new comment) 4: the seven-character approval kept" test "$(rec 4 frozen)/$(rec 4 approved)" = "2/\"$(shortof 4)\""
ok "U05-AC-2: (no new comment) 6: frozen 2, approved null kept" test "$(rec 6 frozen)/$(rec 6 approved)" = '2/null'
ok "U05-AC-2: (no new comment) 22: frozen \"none\" kept" rc 22 frozen '"none"'
ok "U05-AC-2: (no new comment) 23: frozen null, the approval kept" test "$(rec 23 frozen)/$(rec 23 approved)" = "null/\"$(shortof 23)\""
ok "U05-AC-3: (no new comment) 3: still ready, changes approved" approved 3
ok "U05-AC-3: (no new comment) 4: still ready, changes approved" approved 4
ok "U05-AC-3: (no new comment) 6: still needs approval" needs 6
ok "U05-AC-3: (no new comment) 16: still needs approval, with the forge note" needs 16 note
ok "U05-AC-3: (no new comment) 17: still approved, with the forge note" approved 17 note
ok "U05-AC-3: (no new comment) 1: still U04's ready item" plain 1
ok "U05-AC-3: (no new comment) 15: still U04's still being worked on item" notready 15 'CI failed'

[ "$fails" -eq 0 ] || { echo "$fails failed"; exit 1; }
