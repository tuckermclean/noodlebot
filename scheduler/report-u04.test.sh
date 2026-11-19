#!/bin/sh
# Tests scheduler/report.py: the merge record of each open node PR and the "Waiting on you" item that says whether the
# PR is ready to merge or still being worked on (U04-AC-1, U04-AC-2).
#   sh scheduler/report-u04.test.sh   (make test)
#
# THE CONTRACT these checks fix (the implementation must write exactly this).
#
# 1. report.json, key "merge": an object keyed by the PR number as a string ("501"), one entry for each open PR whose
#    branch is node/<ID>-*, written on every run (the first run, which only seeds, included), with these keys:
#      "head"        the PR's head sha as the PR list gives it (40 hex characters);
#      "review_head" the <sha> of `at <sha>` on the FIRST line of the last comment whose first line is headed
#                    `Fresh review (<verdict>)`, as written there (7 or more hex characters), or null when that line
#                    names none (a sha on a later line does not count), or when there is no such comment;
#      "verdict"     the <verdict> of that comment ("approve", "request_changes", ...), null when there is none;
#      "ci"          "passed", "failed", "pending" (check runs not all complete) or "none" (no check runs, or the call
#                    to read them failed) for the check runs of "head".
#    The entry survives runs that read no new comment (the review's head and verdict are kept), and its "ci" is taken
#    again whenever "head" is not the PR's current head and while the last result was not final (pending / none).
#    A quoted line (`> Fresh review (approve) at <sha>`) is not a review, as for U01's milestones.
#
# 2. The status issue's "Waiting on you" section, one line for a node's open PR, that contains the node's ID and
#    `PR #<N>` (the existing item "- <ID>'s PR #<N>: open, no session running on it ..." is the line this replaces):
#      ready:      contains "ready to merge" and the reviewed head (its first 7 characters, as the review wrote them
#                  or as the PR's head starts), and not "still being worked on";
#      ready, `mergeable` not MERGEABLE/CONFLICTING (UNKNOWN, null, missing fifth field of open-prs.tsv):
#                  as ready, and also contains "has not said whether it merges cleanly" (a MERGEABLE PR's line has no
#                  such text);
#      not ready (no session in node/<ID> or pr/<N>, no QUESTION.md in node/<ID>): contains "still being worked on",
#                  not "ready to merge", and for each reason that holds, in any order:
#        QUESTION.md in pr/<N> without ANSWER.md   "open question"
#        QUESTION.md in pr/<N> with ANSWER.md      "answer waits for a session"
#        mergeable CONFLICTING                     "conflicts with its base"
#        head differs from the review's            the PR's head and the review's head, 7 characters each, and
#                                                  "no head" when the last review names none, or "no final review"
#                                                  when there is none
#        verdict is not approve                    the verdict as written (e.g. request_changes)
#        CI pending / failed / none                "CI pending" / "CI failed" / "no CI result"
#      and the line of a reason that does not hold does not say it.
#    With a live session in node/<ID> or in pr/<N> there is no such line; with a QUESTION.md in node/<ID> there is none
#    either (the node's own "asks a question" item is listed instead). A pr/<N> QUESTION.md also keeps its own
#    "PR #<N> asks a question" item.
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
. "$fakegh_lib/report-sessions.sh"
rs_script
ustatus_init

N=21
state=$tmp/s
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
		if [ "$mg" = - ]; then
			printf '%s\tnode/%s-x\t%s\tfalse\n' "$pr" "$id" "$head" >>"$state/open-prs.tsv"
		else
			printf '%s\tnode/%s-x\t%s\tfalse\t%s\n' "$pr" "$id" "$head" "$mg" >>"$state/open-prs.tsv"
		fi
		i=$((i + 1))
	done
	usetpulls "[$pulls]"
}
rn=0
review() { # <i> <verdict> <sha or empty> [extra second line]
	use "$1"
	if [ -n "$3" ]; then first="Fresh review ($2) at $3"; else first="Fresh review ($2)"; fi
	rn=$((rn + 1))
	ucomment "$pr" "$first"$'\n'"${4:-looks fine}" "2026-02-03T00:$(printf %02d "$rn"):00Z" bot NONE Bot "https://x/$pr/$rn"
}
chk() { # <sha> <passed|failed|pending>
	case $2 in
	passed) usetchecks "$1" '[{"name": "test", "status": "completed", "conclusion": "success"}, {"name": "lint", "status": "completed", "conclusion": "success"}]' ;;
	failed) usetchecks "$1" '[{"name": "test", "status": "completed", "conclusion": "success"}, {"name": "lint", "status": "completed", "conclusion": "failure"}]' ;;
	pending) usetchecks "$1" '[{"name": "test", "status": "completed", "conclusion": "success"}, {"name": "lint", "status": "in_progress", "conclusion": null}]' ;;
	esac
}
go() { urun "$state"; }
show() { # the status body, its Waiting on you section, one case's PR line ($tmp/item)
	uq "sorted((i for i in db['issues'].values() if 'noodlebot-status' in i['labels'] and i['title'].startswith('noodlebot log')), key=lambda i: i['number'])[-1]['body']" >"$tmp/body"
	awk '/^## Waiting on you/ {f=1; next} /^## / {f=0} f' "$tmp/body" >"$tmp/wait"
}
item() { # <i>: $tmp/item holds the lines of the section naming the node and its PR
	use "$1"
	grep -F "$id" "$tmp/wait" | grep -E "PR #$pr([^0-9]|\$)" >"$tmp/item"
}
rec() { # <i> <key>: the merge record's value (None for null; ABSENT when the PR has no record)
	use "$1"
	pyc "import json,sys; m = (json.load(open(sys.argv[1])).get('merge') or {}).get(sys.argv[2]); print('ABSENT' if m is None else m.get(sys.argv[3], 'ABSENT'))" "$state/report.json" "$pr" "$2"
}
has() { grep -qF -- "$1" "$tmp/item"; }
rc() { [ "$(rec "$1" "$2")" = "$3" ]; }
isready() { item "$1"; has 'ready to merge' && ! has 'still being worked on'; }
isnot() { item "$1"; has 'still being worked on' && ! has 'ready to merge'; }
noitem() { item "$1"; [ ! -s "$tmp/item" ]; }
mentions() { # <i> <text...>: the item has each text
	item "$1"; shift
	for t in "$@"; do has "$t" || return 1; done
}
lacks() { # <i> <text...>: there is an item and it has none of the texts
	item "$1"; shift
	[ -s "$tmp/item" ] || return 1
	for t in "$@"; do ! has "$t" || return 1; done
}
ONLYQ='open question|answer waits for a session'
ONLYC='conflicts with its base'
ONLYCI='CI pending|CI failed|no CI result'
nothas() { item "$1"; [ -s "$tmp/item" ] && ! grep -qE -- "$2" "$tmp/item"; }
short() { use "$1"; printf %s "$sh7"; }
ciis() { item "$1"; has "$2" && ! grep -qE -- "$3" "$tmp/item"; } # <i> <text it has> <regex it lacks>

# the starting point: one seeding run with no PR (the PR milestones start with the PRs already there)
usetpulls '[]'
go

# Phase 1. Every case is ready to merge except for the one thing it is about.
i=1
while [ "$i" -le "$N" ]; do
	use "$i"
	mkdir -p "$state/node/$id"
	chk "$head" passed
	case $i in
	2 | 3 | 4 | 17 | 18 | 21) ;;
	*) review "$i" approve "$sh7" ;;
	esac
	i=$((i + 1))
done
# 2: the #104 sequence: an approving review at an old commit, then pushes (the head is the last commit), CI passed on it
old2=$(mksha cd 2); sh2=$(printf %s "$old2" | cut -c1-7)
review 2 approve "$sh2"
# 3: a review whose first line names no head (a sha on a later line does not count)
use 3; review 3 approve '' "I looked at $head and it is fine"
# 4: request_changes at the head
review 4 request_changes "$(short 4)" "the lint failure"
# 5, 6, 7: CI pending, failed, no check runs
use 5; chk "$head" pending
use 6; chk "$head" failed
use 7; usetchecks "$head" '[]'
# 8, 9: live sessions (in node/<ID>; in pr/<N>, a node-PR update)
use 8; sh "$tmp/rs/run-session.sh" --node "$id" &
spid8=$!; echo "$spid8" >"$state/node/$id/session.pid"
use 9; mkdir -p "$state/pr/$pr"; echo "$id" >"$state/pr/$pr/node"; echo 1 >"$state/pr/$pr/starts"
sh "$tmp/rs/run-session.sh" --update "$pr" &
spid9=$!; echo "$spid9" >"$state/pr/$pr/session.pid"
spids="$spid8 $spid9"
rs_wait "$spid8" "$spid9"
# 10, 11: a QUESTION.md in pr/<N>, unanswered and answered
use 10; mkdir -p "$state/pr/$pr"; echo "$id" >"$state/pr/$pr/node"; printf 'Q1: which way?\n' >"$state/pr/$pr/QUESTION.md"
use 11; mkdir -p "$state/pr/$pr"; echo "$id" >"$state/pr/$pr/node"; printf 'Q1: which way?\n' >"$state/pr/$pr/QUESTION.md"; printf 'Q1: left\n' >"$state/pr/$pr/ANSWER.md"
# 12: a QUESTION.md in node/<ID>
use 12; printf 'Q1: which way?\n' >"$state/node/$id/QUESTION.md"
# 13: CONFLICTING; 14, 15, 16: UNKNOWN, null, no fifth field; 20: conflicts and CI failed
mg13=CONFLICTING; mg14=UNKNOWN; mg15=null; mg16=-; mg20=CONFLICTING
use 20; chk "$head" failed
# 17: no review at all (nothing to post)
# 18: the last review wins (approve, then request_changes, then a quoted approve and a chat comment)
use 18; review 18 approve "$sh7"; review 18 request_changes "$sh7" "worse now"
ucomment "$pr" "> Fresh review (approve) at $sh7"$'\nquoted' 2026-02-03T00:50:00Z bot NONE Bot "https://x/$pr/q"
ucomment "$pr" 'thanks, looking' 2026-02-03T00:51:00Z owner OWNER User "https://x/$pr/t"
# 19: the check runs of the head cannot be read
use 19; echo "GET .*/commits/$head/check-runs" >"$tmp/ufail"
# 21: the review names the whole 40-character head
use 21; review 21 approve "$head"
publish
go
show

ok "U04-AC-2: (precondition) the Waiting on you section is there" test -s "$tmp/wait"
# 1: ready
ok "U04-AC-2: (1) approve at the head, CI passed, no session: the item says ready to merge, not still being worked on" isready 1
ok "U04-AC-2: (1) the ready item names the reviewed head" mentions 1 "$(short 1)"
ok "U04-AC-2: (1) a MERGEABLE PR's item does not say the forge has not said" lacks 1 'has not said whether it merges cleanly'
ok "U04-AC-1: (1) the record has the PR's head" rc 1 head "$(use 1; echo "$head")"
ok "U04-AC-1: (1) the record has the review's head as written" rc 1 review_head "$(short 1)"
ok "U04-AC-1: (1) the record has the review's verdict" rc 1 verdict approve
ok "U04-AC-1: (1) the record has the CI result passed" rc 1 ci passed
# 2: #104
ok "U04-AC-2: (2, #104) a review at an older commit: still being worked on, not ready" isnot 2
ok "U04-AC-2: (2, #104) the item names the unreviewed head and the reviewed one" mentions 2 "$(short 2)" "$sh2"
ok "U04-AC-1: (2, #104) the record has the PR's head and the review's older head" test "$(rec 2 head)/$(rec 2 review_head)" = "$(use 2; echo "$head")/$sh2"
ok "U04-AC-1: (2, #104) the record has CI on the head passed" rc 2 ci passed
# 3: names no head
ok "U04-AC-2: (3) a review naming no head: still being worked on, not ready" isnot 3
ok "U04-AC-2: (3) the item names the PR's head and says the review names no head" mentions 3 "$(short 3)" 'no head'
ok "U04-AC-1: (3) the record has no review head (a later line's sha does not count)" rc 3 review_head None
ok "U04-AC-1: (3) the record has the verdict approve" rc 3 verdict approve
# 4: request_changes
ok "U04-AC-2: (4) request_changes at the head: still being worked on, not ready" isnot 4
ok "U04-AC-2: (4) the item names the verdict" mentions 4 request_changes
ok "U04-AC-2: (4) the item does not blame CI, a question or a conflict" nothas 4 "$ONLYQ|$ONLYC|$ONLYCI"
ok "U04-AC-1: (4) the record has the verdict request_changes and the head it names" test "$(rec 4 verdict)/$(rec 4 review_head)" = "request_changes/$(short 4)"
# 5-7: CI
ok "U04-AC-2: (5) CI pending: still being worked on, not ready" isnot 5
ok "U04-AC-2: (5) the item says CI pending and not CI failed or no CI result" ciis 5 'CI pending' 'CI failed|no CI result'
ok "U04-AC-1: (5) the record has ci pending" rc 5 ci pending
ok "U04-AC-2: (6) CI failed: still being worked on, not ready" isnot 6
ok "U04-AC-2: (6) the item says CI failed and not CI pending or no CI result" ciis 6 'CI failed' 'CI pending|no CI result'
ok "U04-AC-1: (6) the record has ci failed" rc 6 ci failed
ok "U04-AC-2: (7) no check runs: still being worked on, not ready" isnot 7
ok "U04-AC-2: (7) the item says no CI result and not CI pending or CI failed" ciis 7 'no CI result' 'CI pending|CI failed'
ok "U04-AC-1: (7) the record has ci none" rc 7 ci none
# 8, 9: live sessions
ok "U04-AC-2: (8) a live session in node/<ID>: no PR item (ready to merge or still being worked on)" noitem 8
ok "U04-AC-2: (9) a live session in pr/<N>: no PR item" noitem 9
# 10, 11: a question in pr/<N>
ok "U04-AC-2: (10) QUESTION.md in pr/<N>, unanswered: still being worked on, not ready" isnot 10
ok "U04-AC-2: (10) the item says the PR has an open question, and no answer waits" ciis 10 'open question' 'answer waits for a session|CI |conflicts'
ok "U04-AC-2: (10) the existing 'PR #N asks a question' item is still listed" grep -qF "PR #$((500 + 10)) asks a question" "$tmp/wait"
ok "U04-AC-2: (11) QUESTION.md and ANSWER.md in pr/<N>, no session yet: still being worked on, not ready" isnot 11
ok "U04-AC-2: (11) the item says the answer waits for a session, not an open question" ciis 11 'answer waits for a session' 'open question|CI |conflicts'
# 12: a question in node/<ID>
ok "U04-AC-2: (12) QUESTION.md in node/<ID>: no PR item" noitem 12
ok "U04-AC-2: (12) the node's own question item is listed" grep -qF 'K12 asks a question' "$tmp/wait"
ok "U04-AC-2: (12) no ready-to-merge or still-being-worked-on text for the node anywhere in the section" sh -c "! grep -F K12 '$tmp/wait' | grep -qE 'ready to merge|still being worked on'"
# 13-16, 20: mergeable
ok "U04-AC-2: (13) mergeable CONFLICTING: still being worked on, not ready" isnot 13
ok "U04-AC-2: (13) the item says it conflicts with its base, and blames nothing else" ciis 13 'conflicts with its base' 'open question|answer waits|CI |request_changes|no head|no final review'
ok "U04-AC-2: (14) mergeable UNKNOWN, everything else met: ready to merge" isready 14
ok "U04-AC-2: (14) the item says the forge has not said whether it merges cleanly" mentions 14 'has not said whether it merges cleanly'
ok "U04-AC-2: (15) mergeable null: ready to merge, with the forge note" isready 15
ok "U04-AC-2: (15) the item says the forge has not said whether it merges cleanly" mentions 15 'has not said whether it merges cleanly'
ok "U04-AC-2: (16) no fifth field in open-prs.tsv: ready to merge, with the forge note" isready 16
ok "U04-AC-2: (16) the item says the forge has not said whether it merges cleanly" mentions 16 'has not said whether it merges cleanly'
ok "U04-AC-2: (20) a conflict and CI failed: still being worked on, not ready" isnot 20
ok "U04-AC-2: (20) the item says it conflicts with its base" mentions 20 'conflicts with its base'
ok "U04-AC-2: (20) the item also says CI failed" mentions 20 'CI failed'
# 17: no review
ok "U04-AC-2: (17) no Fresh review: still being worked on, not ready" isnot 17
ok "U04-AC-2: (17) the item names the PR's head and says there is no final review" mentions 17 "$(short 17)" 'no final review'
ok "U04-AC-1: (17) the record has no review head and no verdict" test "$(rec 17 review_head)/$(rec 17 verdict)" = None/None
# 18: the last review wins
ok "U04-AC-2: (18) the last review requests changes (a quoted approve does not count): still being worked on" isnot 18
ok "U04-AC-2: (18) the item names the verdict request_changes" mentions 18 request_changes
ok "U04-AC-1: (18) the record has the last review's verdict" rc 18 verdict request_changes
# 19: check runs unreadable
ok "U04-AC-2: (19) the check runs cannot be read: still being worked on, not ready" isnot 19
ok "U04-AC-1: (19) the record's ci is none (the check runs could not be read)" rc 19 ci none
ok "U04-AC-1: (19) the failure is logged" grep -q 'check-runs' "$tmp/uerr"
# 21: the whole head
ok "U04-AC-2: (21) the review names the 40-character head: ready to merge, naming the head" isready 21
ok "U04-AC-1: (21) the record has the review's head as written (all 40 characters)" rc 21 review_head "$(use 21; echo "$head")"

# Phase 2. Runs that read no new comment, a new head, CI settling, sessions ending, the conflict gone, the check runs readable.
pyc "
import json
db = json.load(open('$udb')); db['comments'] = [c for c in db['comments'] if not (500 < int(c['issue']) <= 500 + $N)]; json.dump(db, open('$udb', 'w'))"
review 2 approve "$(use 2; echo "$head")"           # the #104 PR gets a review at its last commit
chk "$(use 5; echo "$head")" passed                 # 5: the pending checks finish
sh6old=$(short 6); hd6=$(mksha ef 6); use 6; chk "$hd6" passed         # 6: a new head, CI passed on it, the review names the old one
kill "$spid8" "$spid9" 2>/dev/null; wait "$spid8" "$spid9" 2>/dev/null; spids=
mg13=MERGEABLE                                       # 13: the conflict is gone
rm -f "$tmp/ufail"                                   # 19: the check runs can be read
publish
go
show

ok "U04-AC-1: (1, no new comment) the record keeps the review's head" rc 1 review_head "$(short 1)"
ok "U04-AC-1: (1, no new comment) the record keeps the review's verdict" rc 1 verdict approve
ok "U04-AC-1: (1, no new comment) the record keeps the PR's head and CI" test "$(rec 1 head)/$(rec 1 ci)" = "$(use 1; echo "$head")/passed"
ok "U04-AC-2: (1, no new comment) the PR is still ready to merge" isready 1
ok "U04-AC-1: (4, no new comment) the record keeps request_changes and its head" test "$(rec 4 verdict)/$(rec 4 review_head)" = "request_changes/$(short 4)"
ok "U04-AC-2: (4, no new comment) the PR is still not ready" isnot 4
ok "U04-AC-1: (3, no new comment) the record keeps no review head with the verdict approve" test "$(rec 3 review_head)/$(rec 3 verdict)" = None/approve
ok "U04-AC-1: (18, no new comment) the record keeps the last review's verdict" rc 18 verdict request_changes
ok "U04-AC-1: (21, no new comment) the record keeps the whole review head" rc 21 review_head "$(use 21; echo "$head")"
ok "U04-AC-2: (2, #104) a review at the last commit: ready to merge" isready 2
ok "U04-AC-2: (2, #104) the item names the last commit" mentions 2 "$(short 2)"
ok "U04-AC-1: (2, #104) the record has the new review's head" rc 2 review_head "$(use 2; echo "$head")"
ok "U04-AC-1: (5) the finished checks: the record's ci is passed" rc 5 ci passed
ok "U04-AC-2: (5) the PR is ready to merge once CI passed" isready 5
ok "U04-AC-1: (6) the record has the new head" rc 6 head "$hd6"
ok "U04-AC-1: (6) the CI result is taken again for the new head (passed, not the old head's failed)" rc 6 ci passed
ok "U04-AC-1: (6) the record keeps the review's old head" rc 6 review_head "$sh6old"
ok "U04-AC-2: (6) the new head is unreviewed: still being worked on, not ready" isnot 6
ok "U04-AC-2: (6) the item names the new head and the reviewed one" mentions 6 "$(short 6)" "$sh6old"
ok "U04-AC-2: (6) and does not blame CI (passed on the new head)" nothas 6 "$ONLYCI"
ok "U04-AC-2: (8) the node's session ended: ready to merge" isready 8
ok "U04-AC-2: (9) the PR's session ended: ready to merge" isready 9
ok "U04-AC-2: (13) the conflict gone: ready to merge" isready 13
ok "U04-AC-2: (13) and no note, mergeable is MERGEABLE" lacks 13 'has not said whether it merges cleanly'
ok "U04-AC-1: (19) the check runs read again: the record's ci is passed" rc 19 ci passed
ok "U04-AC-2: (19) and the PR is ready to merge" isready 19

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
