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
#
# 3. More of the contract (the record and the item are written as above):
#    - the first line's `at <sha>` is the one of the heading `Fresh review (<verdict>) at <sha>`: a first line that has
#      an "at <sha>" elsewhere ("Fresh review (approve) - I looked at <sha> closely") names no head either;
#    - a failed read of a PR's comments leaves the PR not ready for that run (the item says it is still being worked
#      on; the reason is the implementation's), its stored review is kept, and the next run that reads them gives the
#      verdict (request_changes) as for any new comment;
#    - the CI result is taken again for the same head while it is not "passed": a re-run that turns "failed" into
#      "passed" is recorded, and the PR is ready once it has;
#    - a PR with no record (a report.json from before the record, with pr_since but no "merge") has its comments read in
#      full, not since pr_since: its last review is found and the PR can be ready on the first run that has the record;
#    - a reason that does not hold is not said: the item of a PR whose review names its head (request_changes there,
#      CONFLICTING, a question in pr/<N>) has no text about an unreviewed head and names no other sha than the head.
#    - the record of a PR whose comments could not be read in a run has "unread": true (set on the run whose comments
#      read for that PR failed; removed, or false, on the next run that reads them; a run that read them has no
#      "unread": true), so that site.py, which reads report.json only, does not call that PR ready;
#    - a live session started by loop.sh for a node's PR feedback, `run-session.sh <worktree> <state>/node/<ID>
#      /noodlebot:node --feedback <N>` (a session in node/<ID> whose command line does not end in the ID), is a live
#      session in node/<ID>: the PR has no item while it runs, and its ready item comes when it ends;
#    - a record whose review_head names the PR's head but whose verdict is null (a hand-edited report.json) is not ready,
#      and the item says what is missing after "still being worked on" (a reason, never an empty list).
#    - an open node PR whose node has no node/<ID> state folder has its new comments read on every run too: an approve and
#      then a request_changes at the same head gives the record verdict request_changes and an item that is not ready; a run
#      that reads no new comment keeps the record;
#    - a run whose milestone post for a review comment of the PR fails (the home issue's comment call) does not read the
#      comments after it and so leaves the PR not ready for that run ("unread": true); the next run reads them all;
#    - a record with "unread": true is not ready in any item built from it, also the morning overview's, which is built
#      before the run reads the PR's comments again.
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

# Phase 2b. The items of the PRs whose review names their head (4: request_changes, 10, 11: a question in pr/<N>, 20: a
# conflict) do not say the head is unreviewed; 6 (a new head, the review names the old one) does.
MISM='no final review|not the reviewed head|unreviewed|no head'
othersha() { # <i> <review head>: the item names no sha but the PR's head (7 characters) and the review's head
	item "$1"; use "$1"
	[ -s "$tmp/item" ] || return 1
	grep -oE '[0-9a-f]{7,}' "$tmp/item" | grep -vxF -e "$sh7" -e "$2" -e "$head" >"$tmp/othersha"
	[ ! -s "$tmp/othersha" ]
}
for c in 4 10 11 20; do
	ok "U04-AC-2: ($c) the review names the head: the item has no text about an unreviewed head" nothas "$c" "$MISM"
	ok "U04-AC-2: ($c) the item names no sha other than the PR's head" othersha "$c" "$(short "$c")"
done
hasmism() { item "$1"; grep -qE "$MISM" "$tmp/item"; }
ok "U04-AC-2: (6) a new head the review does not name: the item has the text about the unreviewed head (the check is not loose)" hasmism 6
for c in 4 10 11 20; do
	ok "U04-AC-2: ($c) the item says the PR is still being worked on" isnot "$c"
done

# Phase 3. A state of its own (no report.json: its first run is the seed run), the PRs 31-36 already open, their reviews
# and check runs there. 31: approve at the head, CI passed. 32: the same, then request_changes and the comments unreadable.
# 33: CI failed, then re-run and passed on the same head. 35, 36: a review whose first line names no head (a later
# line's sha, or an "at <sha>" that is not the heading's).
reviewl() { # <i> <first line> <second line>: a bot comment of two lines, the newline written literally
	use "$1"
	rn=$((rn + 1))
	ucomment "$pr" "$2
$3" "2026-02-03T00:$(printf %02d "$rn"):00Z" bot NONE Bot "https://x/$pr/$rn"
}
sinceb=$tmp/sinceb
mkdir -p "$sinceb"
cat >"$sinceb/gh" <<GHEOF
#!/bin/sh
# the fake gh, but a comments call with &since=<time> gets the comments created at or after it, as the forge does
out=\$("$ubin/gh" "\$@") || { rc=\$?; printf '%s\n' "\$out"; exit \$rc; }
since=
for a in "\$@"; do case \$a in *"&since="*) since=\${a#*&since=}; since=\${since%%&*} ;; esac; done
if [ -z "\$since" ]; then printf '%s\n' "\$out"; else
	printf '%s\n' "\$out" | python3 -I -c 'import json, sys; print(json.dumps([c for c in json.load(sys.stdin) if c["created_at"] >= sys.argv[1]]))' "\$since"
fi
GHEOF
chmod +x "$sinceb/gh"
urun3() { env PATH="$sinceb:$ubin:$PATH" python3 -I "$src/report.py" --repo owner/repo --state "$1" --worktrees "$tmp/worktrees/repo" --clone "$uclone" --owner owner 2>"$tmp/uerr"; }
publish3() { # <i>...: the PR list and open-prs.tsv of these cases
	pulls=
	: >"$state/open-prs.tsv"
	for i in "$@"; do
		use "$i"
		pulls="$pulls${pulls:+, }$(upull "$pr" "node/$id-x" "$head")"
		printf '%s\tnode/%s-x\t%s\tfalse\tMERGEABLE\n' "$pr" "$id" "$head" >>"$state/open-prs.tsv"
	done
	usetpulls "[$pulls]"
}
state=$tmp/s2
mkdir -p "$state"
: >"$state/status.log"
for i in 31 32 33 35 36; do
	use "$i"
	mkdir -p "$state/node/$id"
	chk "$head" passed
done
use 33; chk "$head" failed
review 31 approve "$(short 31)"
review 32 approve "$(short 32)"
review 33 approve "$(short 33)"
reviewl 35 "Fresh review (approve)" "I looked at $(use 35; echo "$head") and it is fine"
reviewl 36 "Fresh review (approve) - I looked at $(short 36) closely" "looks fine"
rm -f "$tmp/ufail"
publish3 31 32 33 35 36
urun3 "$state"
ok "U04-AC-1: (seed 31) the first run records the PR's head" rc 31 head "$(use 31; echo "$head")"
ok "U04-AC-1: (seed 31) the first run records the review's head" rc 31 review_head "$(short 31)"
ok "U04-AC-1: (seed 31) the first run records the verdict" rc 31 verdict approve
ok "U04-AC-1: (seed 31) the first run records ci passed" rc 31 ci passed
ok "U04-AC-1: (seed 33) the first run records ci failed" rc 33 ci failed
ok "U04-AC-1: (seed 35) a sha on the review's second line is not its head" rc 35 review_head None
ok "U04-AC-1: (seed 36) an 'at <sha>' that is not the heading's is not the review's head" rc 36 review_head None
ok "U04-AC-1: (seed 36) the verdict is still approve" rc 36 verdict approve
urun3 "$state"; show
ok "U04-AC-2: (35, a newline in the review) the review's first line names no head: still being worked on, not ready" isnot 35
ok "U04-AC-2: (35) the item names the PR's head and says the review names no head" mentions 35 "$(short 35)" 'no head'
ok "U04-AC-2: (36) an 'at <sha>' that is not the heading's: still being worked on, not ready" isnot 36
ok "U04-AC-2: (36) the item says the review names no head" mentions 36 'no head'
ok "U04-AC-2: (32) (precondition) ready to merge at run k" isready 32
ok "U04-AC-2: (33) CI failed on the head: still being worked on, saying CI failed" ciis 33 'CI failed' 'CI pending|no CI result'
# 32: a request_changes comment and the comments of the PR unreadable
review 32 request_changes "$(short 32)" "now it fails"
use 32; echo "GET .*/issues/$pr/comments" >"$tmp/ufail"
# 33: the checks are re-run on the same head and pass
use 33; chk "$head" passed
urun3 "$state"; show
ok "U04-AC-1: (32, failed read) the comments could not be read: the failure is logged" grep -q 'comments' "$tmp/uerr"
notunread() { v=$(rec "$1" unread); [ "$v" = ABSENT ] || [ "$v" = False ]; } # <i>: the record has no "unread": true
ok "U04-AC-1: (32, failed read) the record has \"unread\": true" rc 32 unread True
ok "U04-AC-1: (31, comments read) the record has no \"unread\": true" notunread 31
ok "U04-AC-2: (32, failed read) the item says the PR is still being worked on and not that it is ready to merge" isnot 32
ok "U04-AC-1: (33, CI re-run) the same head's check runs now pass: the record's ci is passed" rc 33 ci passed
ok "U04-AC-2: (33, CI re-run) the PR is ready to merge" isready 33
rm -f "$tmp/ufail"
urun3 "$state"; show
ok "U04-AC-1: (32, read again) the record has the verdict request_changes" rc 32 verdict request_changes
ok "U04-AC-2: (32, read again) request_changes: still being worked on, not ready" isnot 32
ok "U04-AC-2: (32, read again) the item names the verdict request_changes" mentions 32 request_changes
ok "U04-AC-2: (32, read again) the item has no text about an unreviewed head" nothas 32 "$MISM"
ok "U04-AC-1: (32, read again) the record has no \"unread\": true any more" notunread 32

# Phase 4. The upgrade: a report.json written before the record (pr_since set after the approving review, a chat comment
# after it, no "merge"). 34: approve at the head, CI passed.
state=$tmp/s3
mkdir -p "$state"
: >"$state/status.log"
use 34; mkdir -p "$state/node/$id"; chk "$head" passed
review 34 approve "$(short 34)"
ucomment "$pr" 'thanks, looking' 2026-02-03T00:58:00Z owner OWNER User "https://x/$pr/chat"
publish3 34
urun3 "$state"
pyc "
import json
p = '$state/report.json'; r = json.load(open(p)); assert r.get('pr_seed') and r.get('pr_since', {}).get('$pr') == '2026-02-03T00:58:00Z', r
del r['merge']; json.dump(r, open(p, 'w'))"
urun3 "$state"; show
ok "U04-AC-1: (34, upgrade) the run with no record reads the PR's comments in full: the record has the review's head" rc 34 review_head "$(short 34)"
ok "U04-AC-1: (34, upgrade) the record has the verdict approve" rc 34 verdict approve
ok "U04-AC-1: (34, upgrade) the record has ci passed" rc 34 ci passed
ok "U04-AC-2: (34, upgrade) the PR is ready to merge" isready 34

# Phase 5. A state of its own. 41: a record whose review names the head but whose verdict is null (hand-edited), a run
# that reads no new comment. 42: a node-PR feedback session in node/<ID>, as loop.sh starts it.
state=$tmp/s4
mkdir -p "$state"
: >"$state/status.log"
for i in 41 42; do
	use "$i"
	mkdir -p "$state/node/$id"
	chk "$head" passed
	review "$i" approve "$(short "$i")"
	ucomment "$pr" 'thanks, looking' 2026-02-03T00:59:00Z owner OWNER User "https://x/$pr/chat"
done
publish3 41 42
urun3 "$state"
urun3 "$state"; show
ok "U04-AC-2: (41, 42; precondition) both PRs are ready to merge" sh -c "grep -F K41 '$tmp/wait' | grep -qF 'ready to merge' && grep -F K42 '$tmp/wait' | grep -qF 'ready to merge'"
use 42
sh "$tmp/rs/run-session.sh" "$tmp/wt" "$state/node/$id" /noodlebot:node --feedback "$pr" &
spid42=$!; echo "$spid42" >"$state/node/$id/session.pid"
spids="$spid42"
rs_wait "$spid42"
pyc "
import json
p = '$state/report.json'; r = json.load(open(p)); r['merge']['541']['verdict'] = None; json.dump(r, open(p, 'w'))"
urun3 "$state"; show
ok "U04-AC-2: (42, feedback session) a live node-PR feedback session in node/<ID>: no PR item" noitem 42
ok "U04-AC-2: (41, verdict null) the review's head and a null verdict: still being worked on, not ready" isnot 41
ok "U04-AC-2: (41, verdict null) the item says a reason after 'still being worked on'" sh -c "grep -F -- 'still being worked on' '$tmp/item' | sed 's/.*still being worked on//' | grep -qE '[A-Za-z0-9]'"
kill "$spid42" 2>/dev/null; wait "$spid42" 2>/dev/null; spids=
urun3 "$state"; show
ok "U04-AC-2: (42, feedback session ended) the PR is ready to merge" isready 42

# Phase 6 (B1). A state of its own; K51 has no node/<ID> folder. Its record follows its comments at every run: approve ready,
# a run that reads nothing new keeps it, then request_changes at the same head.
state=$tmp/s5
mkdir -p "$state"
: >"$state/status.log"
use 51; chk "$head" passed
review 51 approve "$(short 51)"
publish3 51
urun3 "$state"
urun3 "$state"; show
ok "U04-AC-1: (51, no node folder) the record has the verdict approve" rc 51 verdict approve
ok "U04-AC-2: (51, no node folder) approve at the head, CI passed: ready to merge" isready 51
urun3 "$state"; show
ok "U04-AC-1: (51, no new comment) the record keeps the verdict approve" rc 51 verdict approve
ok "U04-AC-2: (51, no new comment) the PR is still ready to merge" isready 51
review 51 request_changes "$(short 51)" "now it fails"
urun3 "$state"; show
ok "U04-AC-1: (51, no node folder) a new request_changes at the same head: the record has the verdict request_changes" rc 51 verdict request_changes
ok "U04-AC-2: (51, no node folder) the item says the PR is still being worked on, not ready to merge" isnot 51
ok "U04-AC-2: (51, no node folder) the item names the verdict request_changes" mentions 51 request_changes

# Phase 7 (N1). K52 has a node folder and is ready at run k. Then an approve and a request_changes are posted, and the
# milestone post on the node's home issue fails: the run reads no further than the first comment, so the PR is not ready.
state=$tmp/s6
mkdir -p "$state/node/K52"
echo 45 >"$state/node/K52/issue"   # the node's home issue (a seeded one of the fake)
: >"$state/status.log"
use 52; chk "$head" passed
review 52 approve "$(short 52)"
publish3 52
urun3 "$state"
urun3 "$state"; show
ok "U04-AC-2: (52, precondition) ready to merge at run k" isready 52
home52=45
review 52 approve "$(short 52)" "again"
review 52 request_changes "$(short 52)" "no, it fails"
echo "POST .*/issues/$home52/comments" >"$tmp/ufail"
urun3 "$state"; show
ok "U04-AC-2: (52, failed milestone post) the failure was injected" grep -q "injected failure for POST .*/issues/$home52/comments" "$tmp/uerr"
ok "U04-AC-2: (52, failed milestone post) the item does not say ready to merge, says still being worked on" isnot 52
ok "U04-AC-1: (52, failed milestone post) the record has \"unread\": true (the comments after the failed post were not read)" rc 52 unread True
rm -f "$tmp/ufail"
urun3 "$state"; show
ok "U04-AC-1: (52, posts work again) the record has the verdict request_changes" rc 52 verdict request_changes
ok "U04-AC-2: (52, posts work again) the item says still being worked on and names request_changes" mentions 52 'still being worked on' request_changes
ok "U04-AC-2: (52, posts work again) the item does not say ready to merge" isnot 52
ok "U04-AC-1: (52, posts work again) the record has no \"unread\": true" notunread 52

# Phase 8 (N2). K53 is ready; its record is edited to "unread": true (as if the comments of the last run could not be read),
# and the next run, on a new day, reads the PR's comments again and fails. The overview is built before that read: its line for
# the PR does not say ready to merge.
state=$tmp/s7
mkdir -p "$state/node/K53"
: >"$state/status.log"
use 53; chk "$head" passed
review 53 approve "$(short 53)"
publish3 53
urun3 "$state"
urun3 "$state"; show
ok "U04-AC-2: (53, precondition) ready to merge" isready 53
pyc "
import json
p = '$state/report.json'; r = json.load(open(p)); r['merge']['553']['unread'] = True; json.dump(r, open(p, 'w'))"
use 53; echo "GET .*/issues/$pr/comments" >"$tmp/ufail"
d19day1=$(python3 -I -c 'import os, datetime as d
v = os.environ.get("NOODLEBOT_NOW")
try:
    t = d.datetime.fromisoformat(v).astimezone() if v else d.datetime.now().astimezone()
except ValueError:
    t = d.datetime.now().astimezone()
print((t.date() + d.timedelta(days=1)).isoformat() + "T09:00:00")') # the day after the two runs above, as report.py dates it
env PATH="$sinceb:$ubin:$PATH" TZ=UTC NOODLEBOT_NOW=$d19day1 python3 -I "$src/report.py" --repo owner/repo --state "$state" --worktrees "$tmp/worktrees/repo" --clone "$uclone" --owner owner 2>"$tmp/uerr"
rm -f "$tmp/ufail"
uq "[c['body'] for c in db['comments'] if c['body'].startswith('## Morning overview') and 'K53' in c['body']][-1]" >"$tmp/overview"
grep -F K53 "$tmp/overview" | grep -E "PR #553([^0-9]|\$)" >"$tmp/item"
ok "U04-AC-2: (53, unread record) the morning overview has a line for the PR" test -s "$tmp/item"
ok "U04-AC-2: (53, unread record) the overview's line does not say ready to merge" sh -c "[ -s '$tmp/item' ] && ! grep -qF 'ready to merge' '$tmp/item'"
ok "U04-AC-2: (53, unread record) the overview's line says still being worked on" has 'still being worked on'

# Phase U06 (U06-AC-1, U06-AC-3). Every scratch path is under $tmp/U06. The fake gh of these runs filters a comments call's
# `since` by the comment's update time (updated_at, or created_at when never edited), strictly after it, as the forge does for
# an edited comment: an edited older comment comes back with an update time after the cursor.
u6=$tmp/U06
mkdir -p "$u6/bin"
cat >"$u6/bin/gh" <<GHEOF
#!/bin/sh
out=\$("$ubin/gh" "\$@") || { rc=\$?; printf '%s\n' "\$out"; exit \$rc; }
since=
for a in "\$@"; do case \$a in *"&since="*) since=\${a#*&since=}; since=\${since%%&*} ;; esac; done
if [ -z "\$since" ]; then printf '%s\n' "\$out"; else
	printf '%s\n' "\$out" | python3 -I -c 'import json, sys; print(json.dumps([c for c in json.load(sys.stdin) if (c.get("updated_at") or c["created_at"]) > sys.argv[1]]))' "\$since"
fi
GHEOF
chmod +x "$u6/bin/gh"
urun6() { env PATH="$u6/bin:$ubin:$PATH" python3 -I "$src/report.py" --repo owner/repo --state "$1" --worktrees "$tmp/worktrees/repo" --clone "$uclone" --owner owner 2>"$tmp/uerr"; }
u6n=0
u6review() { # <i> <verdict> [extra]: a Fresh review at the case's head, created later than the one before; $u6id is its id
	use "$1"
	u6n=$((u6n + 1))
	ucomment "$pr" "Fresh review ($2) at $sh7
${3:-looks fine}" "2026-03-01T00:$(printf %02d "$u6n"):00Z" bot NONE Bot "https://x/$pr/u6$u6n"
	u6id=$(uq "[c['id'] for c in db['comments'] if c['issue'] == '$pr'][-1]")
}
u6edit() { # <comment id> <verdict> <i> <update time>: the comment edited to another verdict
	use "$3"
	pyc "
import json, sys
db = json.load(open('$udb'))
for c in db['comments']:
    if c['id'] == int(sys.argv[1]):
        c['body'] = 'Fresh review (%s) at %s\nedited' % (sys.argv[2], sys.argv[3]); c['updated_at'] = sys.argv[4]
json.dump(db, open('$udb', 'w'))" "$1" "$2" "$sh7" "$4"
}
u6kept() { # <i>: the values of the merge record other than head, review_head, verdict, ci, unread (the kept comment id)
	use "$1"
	pyc "
import json, sys
m = (json.load(open(sys.argv[1])).get('merge') or {}).get(sys.argv[2]) or {}
print(' '.join(str(v) for k, v in sorted(m.items()) if k not in ('head', 'review_head', 'verdict', 'ci', 'unread')))" "$state/report.json" "$pr"
}
u6pub() { # <i>...: the PR list and open-prs.tsv of these cases
	publish3 "$@"
}

# U06-A. 71: FAILED in node/<ID>; 72: FAILED in pr/<N>; 74: FAILED in node/<ID> and CI failed; 75: the control, no FAILED.
# Each is a PR U04 makes ready (approve at its head, CI passed, MERGEABLE, no session, no question) but for the FAILED.
state=$u6/f
mkdir -p "$state"
: >"$state/status.log"
for i in 71 72 74 75; do
	use "$i"
	mkdir -p "$state/node/$id"
	chk "$head" passed
	u6review "$i" approve
done
use 74; chk "$head" failed
use 71; echo "gave up" >"$state/node/$id/FAILED"
use 74; echo "gave up" >"$state/node/$id/FAILED"
use 72; mkdir -p "$state/pr/$pr"; echo "$id" >"$state/pr/$pr/node"; echo "gave up" >"$state/pr/$pr/FAILED"
u6pub 71 72 74 75
urun6 "$state"
urun6 "$state"
d19day2=$(python3 -I -c 'import os, datetime as d
v = os.environ.get("NOODLEBOT_NOW")
try:
    t = d.datetime.fromisoformat(v).astimezone() if v else d.datetime.now().astimezone()
except ValueError:
    t = d.datetime.now().astimezone()
print((t.date() + d.timedelta(days=2)).isoformat() + "T09:00:00")') # two days after the two runs above (case 53 already used the day after), as report.py dates it
env PATH="$u6/bin:$ubin:$PATH" TZ=UTC NOODLEBOT_NOW=$d19day2 python3 -I "$src/report.py" --repo owner/repo --state "$state" --worktrees "$tmp/worktrees/repo" --clone "$uclone" --owner owner 2>"$tmp/uerr"
show
uq "[c['body'] for c in db['comments'] if c['body'].startswith('## Morning overview') and 'K71' in c['body']][-1]" >"$tmp/u6overview"
ovitem() { # <i>: the overview's line for the node's PR ($tmp/item)
	use "$1"
	grep -F "$id" "$tmp/u6overview" | grep -E "PR #$pr([^0-9]|\$)" >"$tmp/item"
}
ovnot() { ovitem "$1"; has 'still being worked on' && has 'its run failed' && ! has 'ready to merge'; }
ok "U06-AC-1: (precondition) the control 75 without FAILED is ready to merge" isready 75
ok "U06-AC-1: (71) FAILED in node/<ID>: the item says the PR is still being worked on, not ready to merge" isnot 71
ok "U06-AC-1: (71) the item names that its run failed" mentions 71 'its run failed'
ok "U06-AC-1: (71) the item does not blame CI, a question, a conflict or the review" nothas 71 "$ONLYQ|$ONLYC|$ONLYCI|request_changes|no head|no final review"
ok "U06-AC-1: (71) the **K71 FAILED** item is still listed" grep -qF '**K71 FAILED**' "$tmp/wait"
ok "U06-AC-1: (71) the record still says the review approves the head (the failed run is not a verdict)" test "$(rec 71 verdict)/$(rec 71 review_head)/$(rec 71 ci)" = "approve/$(short 71)/passed"
ok "U06-AC-1: (72) FAILED in pr/<N>: the item says the PR is still being worked on, not ready to merge" isnot 72
ok "U06-AC-1: (72) the item names that its run failed" mentions 72 'its run failed'
ok "U06-AC-1: (72) the **PR #572 FAILED** item is still listed" grep -qF '**PR #572 FAILED**' "$tmp/wait"
ok "U06-AC-1: (74) FAILED and CI failed: still being worked on, not ready to merge" isnot 74
ok "U06-AC-1: (74) the item names both reasons, its run failed and CI failed" mentions 74 'its run failed' 'CI failed'
ok "U06-AC-1: (74) the **K74 FAILED** item is still listed" grep -qF '**K74 FAILED**' "$tmp/wait"
ok "U06-AC-1: (75) the control's item does not name a failed run" lacks 75 'run failed'
ok "U06-AC-1: (precondition) the morning overview has a line for the control's PR" sh -c "grep -F K75 '$tmp/u6overview' | grep -qE 'PR #575([^0-9]|\$)'"
ok "U06-AC-1: (71, overview) the line for the PR says still being worked on, its run failed, not ready to merge" ovnot 71
ok "U06-AC-1: (72, overview) the line for the PR says still being worked on, its run failed, not ready to merge" ovnot 72
ovmentions() { ovitem "$1"; shift; for t in "$@"; do has "$t" || return 1; done; }
ok "U06-AC-1: (74, overview) the line for the PR names both reasons" ovmentions 74 'its run failed' 'CI failed'
ok "U06-AC-1: (75, overview) the control's line says ready to merge" sh -c "grep -F K75 '$tmp/u6overview' | grep -E 'PR #575([^0-9]|\$)' | grep -qF 'ready to merge'"
# the owner deletes FAILED to retry
use 71; rm -f "$state/node/$id/FAILED"
use 72; rm -f "$state/pr/$pr/FAILED"
urun6 "$state"; show
ok "U06-AC-1: (71, FAILED removed) the PR's item is U04's ready item again" isready 71
ok "U06-AC-1: (71, FAILED removed) the item names the reviewed head and no failed run" sh -c "grep -F K71 '$tmp/wait' | grep -E 'PR #571([^0-9]|\$)' | grep -qF '$(short 71)' && ! grep -F K71 '$tmp/wait' | grep -qF 'run failed'"
ok "U06-AC-1: (72, FAILED removed) the PR's item is U04's ready item again" isready 72
ok "U06-AC-1: (71, 72, FAILED removed) no FAILED item for them any more" sh -c "! grep -qE 'K71 FAILED|PR #572 FAILED' '$tmp/wait'"
ok "U06-AC-1: (74, FAILED still there) the item is not ready" isnot 74

# U06-B. State $u6/e: 61 is an edited-review sequence, 62 a record from before this node (no comment id kept).
# 61: approve (a), then request_changes (b), both at the head.  62: request_changes (c1), then approve (c2).
state=$u6/e
mkdir -p "$state"
: >"$state/status.log"
for i in 61 62; do
	use "$i"
	mkdir -p "$state/node/$id"
	chk "$head" passed
done
u6pub 61 62
urun6 "$state"   # the seed run: the PRs are open, no comment yet
u6review 61 approve; ida=$u6id
u6review 61 request_changes "the lint failure"; idb=$u6id
u6review 62 request_changes "not yet"; idc1=$u6id
u6review 62 approve; idc2=$u6id
urun6 "$state"; show
ok "U06-AC-3: (61) an approve and a newer request_changes at the head: not ready, the verdict named" mentions 61 'still being worked on' request_changes
ok "U06-AC-3: (61) the record has the verdict request_changes" rc 61 verdict request_changes
ok "U06-AC-3: (61) the record keeps the id of the last Fresh review (the newer comment)" test "$(u6kept 61)" = "$idb"
ok "U06-AC-3: (62) the record keeps the id of its last Fresh review (the approving comment)" test "$(u6kept 62)" = "$idc2"
ok "U06-AC-3: (62, precondition) approve last: ready to merge" isready 62
# the older approving comment of 61 and the older request_changes of 62 are edited; 62's record is made one from before this node
u6edit "$ida" approve 61 2026-03-01T05:00:00Z
u6edit "$idc1" request_changes 62 2026-03-01T05:00:00Z
pyc "
import json
p = '$state/report.json'; r = json.load(open(p))
r['merge']['562'] = {k: r['merge']['562'][k] for k in ('head', 'review_head', 'verdict', 'ci')}; json.dump(r, open(p, 'w'))"
ok "U06-AC-3: (62, precondition) the edited record has no kept id" test -z "$(u6kept 62)"
urun6 "$state"; show
ok "U06-AC-3: (61, older review edited) the record keeps the verdict request_changes" rc 61 verdict request_changes
ok "U06-AC-3: (61, older review edited) the record keeps the review head" rc 61 review_head "$(short 61)"
ok "U06-AC-3: (61, older review edited) the record keeps the newer comment's id" test "$(u6kept 61)" = "$idb"
ok "U06-AC-3: (61, older review edited) the PR is still not ready, the verdict named" mentions 61 'still being worked on' request_changes
ok "U06-AC-3: (61, older review edited) the item does not say ready to merge" isnot 61
ok "U06-AC-3: (62, no kept id) a record without an id takes the run's last review as U04 does: request_changes" rc 62 verdict request_changes
ok "U06-AC-3: (62, no kept id) the PR is not ready, the verdict named" mentions 62 'still being worked on' request_changes
ok "U06-AC-3: (62, no kept id) the record now keeps the id of that review" test "$(u6kept 62)" = "$idc1"
# a new approving review with a higher id
u6review 61 approve "fixed"; idd=$u6id
urun6 "$state"; show
ok "U06-AC-3: (61, newer review) a new approve at the head with a higher id: the record has the verdict approve" rc 61 verdict approve
ok "U06-AC-3: (61, newer review) the record keeps the new comment's id" test "$(u6kept 61)" = "$idd"
ok "U06-AC-3: (61, newer review) the PR is ready to merge" isready 61
# the newest review itself is edited (same id) to request_changes
u6edit "$idd" request_changes 61 2026-03-01T07:00:00Z
urun6 "$state"; show
ok "U06-AC-3: (61, newest review edited) the record has the verdict request_changes" rc 61 verdict request_changes
ok "U06-AC-3: (61, newest review edited) the record keeps the same comment id" test "$(u6kept 61)" = "$idd"
ok "U06-AC-3: (61, newest review edited) the PR is not ready, the verdict named" mentions 61 'still being worked on' request_changes
ok "U06-AC-3: (61, newest review edited) the item does not say ready to merge" isnot 61

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
