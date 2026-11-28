#!/bin/sh
# Tests scheduler/report.py: an unreadable frozen-line record in the last final review (U07-AC-1, U07-AC-2).
#   sh scheduler/report-u07.test.sh   (make test)
#
# THE CONTRACT these checks fix (the implementation must write exactly this); it replaces the rule in the contract
# comment of scheduler/report-u05.test.sh that a line that does not parse gives null.
#
# 1. A frozen line of the last comment headed `Fresh review (<verdict>)` is any line of its body that holds the text
#    `Frozen test lines changed:` in any letter case. U05's reading of a line stays: it parses when only marks that are no
#    letter, digit, underscore or `>` come before the text, and only `*`, `_`, backticks and blanks surround `none` or a
#    count from 1 without a leading zero after the colon, with an optional CR at the line's end. The merge record's "frozen":
#      null          when the comment has no frozen line, or there is no review;
#      "none" or <n> when every frozen line parses and all give that same value;
#      "unreadable"  when a frozen line does not parse, or two give different values.
#    It is kept across runs that read no new comment and replaced by a newer review.
# 2. The item of a PR that U04 makes ready, frozen "unreadable": as for a count (U05-AC-3),
#      <ID>'s PR #<N> changes frozen test lines: needs your approval (reviewed at <sha>, CI passed)
#      <ID>'s PR #<N> is ready to merge (frozen test line changes approved; reviewed at <sha>, CI passed)
#    with U04's forge note after either when it applies; a PR that is not ready gets U04's item.
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
N=36
state=$tmp/U07/s
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
# session, no question) unless it says otherwise.
mg27=UNKNOWN; mg28=UNKNOWN
i=1
while [ "$i" -le "$N" ]; do
	use "$i"
	mkdir -p "$state/node/$id"
	chk "$head"
	i=$((i + 1))
done
use 29; chkfail "$head"
rv() { review "$1" approve "$(shortof "$1")" "looks fine${nl}$2"; } # <i> <the lines after the first>
# 1-9: one line that does not parse
use 1; rv 1 "> Frozen test lines changed: 2"
use 2; rv 2 "Frozen test lines changed: 2 lines"
use 3; rv 3 "Frozen test lines changed: two"
use 4; rv 4 "Frozen test lines changed:"
use 5; rv 5 "Frozen test lines changed: 0"
use 6; rv 6 "Frozen test lines changed: -1"
use 7; rv 7 "Frozen test lines changed: 02"
use 8; rv 8 "frozen test lines changed: 2"
use 9; rv 9 "Note: Frozen test lines changed: 2"
# 10-14: two lines
use 10; rv 10 "Frozen test lines changed: none${nl}> Frozen test lines changed: 2"
use 11; rv 11 "> Frozen test lines changed: 2${nl}Frozen test lines changed: none"
use 12; rv 12 "Frozen test lines changed: none${nl}Frozen test lines changed: 2"
use 13; rv 13 "Frozen test lines changed: 2${nl}Frozen test lines changed: none"
use 14; rv 14 "Frozen test lines changed: 3${nl}scheduler/a.test.sh:1 at c0ffee1${nl}Frozen test lines changed: 3"
# 15-19: U05's accepted forms
use 15; rv 15 "- Frozen test lines changed: 2"
use 16; rv 16 "**Frozen test lines changed:** 3"
use 17; rv 17 "**Frozen test lines changed: 3**"
use 18; rv 18 "\`Frozen test lines changed: none\`"
use 19; review 19 approve "$sh7" "$(printf 'looks fine\r\nFrozen test lines changed: 4\r\nscheduler/a.test.sh:1 at c0ffee1\r')"
# 20: no line.  21: approved at the head.  22: seven characters.  23: approved at the first head, a push and a new review follow.
use 20; rv 20 "nothing changed here"
use 21; rv 21 "> Frozen test lines changed: 2"; approve 21 "Frozen lines approved at $head"
use 22; rv 22 "Frozen test lines changed: 2 lines"; approve 22 "Frozen lines approved at $sh7"
use 23; rv 23 "Frozen test lines changed: two"; approve 23 "Frozen lines approved at $sh7"
# 24-26: not the owner
use 24; rv 24 "> Frozen test lines changed: 2"; said 24 stranger NONE User "Frozen lines approved at $head"
use 25; rv 25 "> Frozen test lines changed: 2"; said 25 bot NONE Bot "Frozen lines approved at $head"
use 26; rv 26 "> Frozen test lines changed: 2"; said 26 owner CONTRIBUTOR User "Frozen lines approved at $head"
# 27: UNKNOWN, no approval.  28: UNKNOWN, approved.  29: CI failed.
use 27; rv 27 "Frozen test lines changed: 2 lines"
use 28; rv 28 "Frozen test lines changed: 2 lines"; approve 28 "Frozen lines approved at $sh7"
use 29; rv 29 "Frozen test lines changed: 2 lines"; approve 29 "Frozen lines approved at $sh7"
# 30: an unreadable review, then a later one at the same head that says none.  31: then one that says 3.
use 30; rv 30 "> Frozen test lines changed: 2"; approve 30 "Frozen lines approved at $sh7"; frozen 30 "$sh7" none
use 31; rv 31 "> Frozen test lines changed: 2"; frozen 31 "$sh7" 3
# 32: the unreadable line below the first lines.  33: two counts that differ.  34: the owner's approval then a newer unreadable review
use 32; rv 32 "one${nl}two${nl}three${nl}  Frozen test lines changed: 2 files${nl}more"
use 33; rv 33 "Frozen test lines changed: 2${nl}Frozen test lines changed: 3"
use 34; frozen 34 "$sh7" 2; rv 34 "> Frozen test lines changed: 2"
use 35; rv 35 "> Frozen test lines changed: 2"; approve 35 "Frozen lines approved at $sh7${nl}I read it. Go ahead."
use 36; rv 36 "Frozen test lines changed: none"
publish
go
show

ok "U07-AC-2: (precondition) the Waiting on you section is there" test -s "$tmp/wait"
u() { # <i> <label>: the record says unreadable and the item asks for the approval
	ok "U07-AC-1: ($1) $2: frozen is \"unreadable\"" rc "$1" frozen '"unreadable"'
	ok "U07-AC-2: ($1) $2: the item says the PR needs the owner's approval" needs "$1"
}
u 1 "the line quoted"
u 2 "more text after the count"
u 3 "a word for the count"
u 4 "no value after the colon"
u 5 "a count of 0"
u 6 "a negative count"
u 7 "a leading zero"
u 8 "another letter case"
u 9 "other words before the text"
u 10 "none, then a quoted line"
u 11 "a quoted line, then none"
u 12 "none, then 2"
u 13 "2, then none"
ok "U07-AC-1: (14) 3 twice: frozen is 3" rc 14 frozen 3
ok "U07-AC-2: (14) 3 twice: the item says the PR needs the owner's approval" needs 14
ok "U07-AC-1: (15) the line as a list item: frozen is 2" rc 15 frozen 2
ok "U07-AC-1: (16) bold with the colon inside: frozen is 3" rc 16 frozen 3
ok "U07-AC-1: (17) the whole line bold: frozen is 3" rc 17 frozen 3
ok "U07-AC-1: (18) backticks, none: frozen is \"none\"" rc 18 frozen '"none"'
ok "U07-AC-1: (19) CRLF line endings: frozen is 4" rc 19 frozen 4
ok "U07-AC-1: (20) no line holding the text: frozen is null" rc 20 frozen null
ok "U07-AC-2: (20) no line: U04's ready item" plain 20
ok "U07-AC-1: (21) unreadable, the owner's approval at the head: frozen is \"unreadable\", approved is the head" test "$(rec 21 frozen)/$(rec 21 approved)" = "\"unreadable\"/\"$(headof 21)\""
ok "U07-AC-2: (21) approved at the head: ready, changes approved" approved 21
ok "U07-AC-2: (22) approved at seven characters of the head: ready, changes approved" approved 22
ok "U07-AC-1: (22) frozen is \"unreadable\"" rc 22 frozen '"unreadable"'
ok "U07-AC-2: (23, precondition) approved at its first head: ready, changes approved" approved 23
ok "U07-AC-2: (24) another user's approval does not count: needs approval" needs 24
ok "U07-AC-1: (24) frozen is \"unreadable\"" rc 24 frozen '"unreadable"'
ok "U07-AC-2: (25) the bot's approval does not count: needs approval" needs 25
ok "U07-AC-2: (26) no owner mark, no approval: needs approval" needs 26
ok "U07-AC-2: (27) mergeable UNKNOWN, no approval: needs approval, with the forge note" needs 27 note
ok "U07-AC-2: (28) mergeable UNKNOWN, approved: ready, changes approved, with the forge note" approved 28 note
ok "U07-AC-1: (29) CI failed: the record keeps frozen \"unreadable\"" rc 29 frozen '"unreadable"'
ok "U07-AC-2: (29) CI failed: U04's still being worked on item, no frozen-line text" notready 29 'CI failed'
ok "U07-AC-1: (30) a later review at the same head says none: frozen is \"none\"" rc 30 frozen '"none"'
ok "U07-AC-2: (30) U04's ready item" plain 30
ok "U07-AC-1: (31) a later review says 3: frozen is 3" rc 31 frozen 3
ok "U07-AC-1: (32) an unreadable line below the first lines, with leading blanks: frozen is \"unreadable\"" rc 32 frozen '"unreadable"'
ok "U07-AC-2: (32) needs approval" needs 32
ok "U07-AC-1: (33) two lines that give 2 and 3: frozen is \"unreadable\"" rc 33 frozen '"unreadable"'
ok "U07-AC-1: (34) a review with 2, then a newer unreadable one: frozen is \"unreadable\"" rc 34 frozen '"unreadable"'
ok "U07-AC-2: (35) the owner's words after the first line: ready, changes approved" approved 35
ok "U07-AC-1: (36) none: frozen is \"none\"" rc 36 frozen '"none"'
ok "U07-AC-2: (36) none: U04's ready item" plain 36

# Phase 2. Runs that read no new comment keep the record; a push after the approval.
pyc "
import json
db = json.load(open('$udb'))
for c in db['comments']:
    if 500 < int(c['issue']) <= 500 + $N: c['issue'] = '0'
json.dump(db, open('$udb', 'w'))"
ap23=$(shortof 23)
hd23=$(mksha cd 23)
use 23; chk "$hd23"
rv 23 "Frozen test lines changed: two"
publish
go
show
ok "U07-AC-1: (23, push) the record has the new head" rc 23 head "\"$hd23\""
ok "U07-AC-1: (23, push) the record keeps the earlier approval" rc 23 approved "\"$ap23\""
ok "U07-AC-1: (23, push) the new review is unreadable again" rc 23 frozen '"unreadable"'
ok "U07-AC-2: (23, push) an approval naming an earlier head does not count: needs approval again" needs 23
ok "U07-AC-1: (no new comment) 1: frozen \"unreadable\" kept" rc 1 frozen '"unreadable"'
ok "U07-AC-1: (no new comment) 2: frozen \"unreadable\" kept" rc 2 frozen '"unreadable"'
ok "U07-AC-1: (no new comment) 21: frozen \"unreadable\" and the approval kept" test "$(rec 21 frozen)/$(rec 21 approved)" = "\"unreadable\"/\"$(headof 21)\""
ok "U07-AC-1: (no new comment) 30: frozen \"none\" kept" rc 30 frozen '"none"'
ok "U07-AC-1: (no new comment) 20: frozen null kept" rc 20 frozen null
ok "U07-AC-2: (no new comment) 1: still needs approval" needs 1
ok "U07-AC-2: (no new comment) 21: still ready, changes approved" approved 21
ok "U07-AC-2: (no new comment) 27: still needs approval, with the forge note" needs 27 note
ok "U07-AC-2: (no new comment) 28: still approved, with the forge note" approved 28 note
ok "U07-AC-2: (no new comment) 29: still U04's still being worked on item" notready 29 'CI failed'

[ "$fails" -eq 0 ] || { echo "$fails failed"; exit 1; }
