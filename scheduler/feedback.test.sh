#!/bin/sh
# Tests scheduler/feedback.py (G03) against a fake `gh api` serving fixtures under scheduler/testdata/feedback/.
#   sh scheduler/feedback.test.sh   (make test)
#
# The command-line interface these tests fix for feedback.py:
#   python3 -I feedback.py --repo O/N --state DIR --owner LOGIN --prs FILE        find new feedback
#   python3 -I feedback.py --repo O/N --state DIR --owner LOGIN --prs FILE mark N  advance PR N's record
#  * FILE is the loop's open-prs.tsv: one line per open PR, "<number> <branch> <headOid> <is_bot> <mergeable>",
#    space separated; is_bot is "true" for the bot's PRs, "false" for a human's (never read, never printed).
#  * DIR is state/<name>. The record of PR N is the file DIR/feedback/N (any content, the newest conversation-
#    comment, line-comment and review IDs); "no feedback/ folder" means a first run. The FEEDBACK.md written for
#    PR N is DIR/feedback/N.md. A PR no longer in FILE loses both files.
#  * The units' folders are DIR/node/<ID>/ (branch node/<ID>-...; ID is what precedes the first "-" after
#    "node/") and DIR/pr/<N>/ (branch spec/*). An owner comment is an answer when its html_url is in
#    ANSWER.md or answered/*-ANSWER.md of the PR's unit; such a comment is not feedback.
#  * stdout: one line per PR with new feedback, "<N> <branch>", in FILE order. Nothing else on stdout.
#    Exit 0 when every PR was read; non-zero when a gh call failed (the PR is then not printed, its record and
#    file untouched, the other PRs still handled). `mark N` prints nothing and exits 0.
#  * gh is called as `gh api --paginate repos/O/N/<issues|pulls>/<PR>/<comments|reviews>` (no query string);
#    a failing call exits non-zero. With --paginate gh prints each page's JSON array one after the other, so
#    the output may be several concatenated arrays.
#  * FEEDBACK.md: a line "PR: N" and "Branch: B"; then per item these lines (as "key: value"):
#        kind: conversation | line | review    id: ID    url: URL    author: LOGIN    time: TIME
#        body: the text (starting on the same line)
#    and for a line comment also "file: PATH", "line: N" and "thread: ID of the thread's first comment".
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
ok() { name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }

data=$tmp/data
mkdir -p "$tmp/bin"
cp -R "$src/testdata/feedback" "$data"
export FB_DATA=$data FB_FAIL=$tmp/fail FB_CALLS=$tmp/calls
cat >"$tmp/bin/gh" <<'EOS'
#!/bin/sh
# fake gh: only `gh api --paginate repos/o/r/(issues|pulls)/N/(comments|reviews)`, served from $FB_DATA.
[ "$1" = api ] && [ "$2" = --paginate ] && [ $# -eq 3 ] || { echo "fake gh: unexpected: $*" >&2; exit 2; }
case $3 in
repos/o/r/issues/*/comments | repos/o/r/pulls/*/comments | repos/o/r/pulls/*/reviews) ;;
*) echo "fake gh: unexpected path $3" >&2; exit 2 ;;
esac
echo "$3" >>"$FB_CALLS"
f=$(echo "${3#repos/o/r/}" | tr / -)
if [ -s "$FB_FAIL" ] && grep -qxF "$3" "$FB_FAIL"; then echo "gh: HTTP 502" >&2; exit 1; fi
if [ -f "$FB_DATA/$f.json" ]; then cat "$FB_DATA/$f.json"; else echo '[]'; fi
EOS
chmod +x "$tmp/bin/gh"
export PATH=$tmp/bin:$PATH
export GH_TOKEN=fake

prs=$data/open-prs.tsv
fb() { python3 -I "$src/feedback.py" --repo o/r --state "$state" --owner owner --prs "${PRS:-$prs}" "$@"; }
# silent: feedback.py ran fine (exit 0) and printed nothing (a missing script is a failure, not "nothing")
silent() { o=$(fb 2>/dev/null); [ $? -eq 0 ] && [ -z "$o" ]; }
nums() { cut -d' ' -f1 | tr '\n' ' '; }

# --- first run: no feedback/ folder -------------------------------------------------------------------------
state=$tmp/a
mkdir -p "$state/node/N22" "$state/node/N23/answered" "$state/pr/24"
echo "answer: https://github.com/o/r/pull/22#issuecomment-2200" >"$state/node/N22/ANSWER.md"
echo "answer: https://github.com/o/r/pull/23#issuecomment-2300" >"$state/node/N23/answered/20261105-ANSWER.md"
echo "answer: https://github.com/o/r/pull/24#issuecomment-2400" >"$state/pr/24/ANSWER.md"
out=$(fb 2>"$tmp/err"); rc=$?
ok "G03-AC-2: the first run (no feedback/ folder) prints nothing and exits 0" test "$rc" = 0 -a -z "$out" -a -d "$state/feedback"
miss=
for n in 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 26 27; do [ -e "$state/feedback/$n" ] || miss="$miss $n"; done
ok "G03-AC-2: the first run records every open bot PR (missing:${miss:- none})" test -z "$miss"
ok "G03-AC-1: a human's PR is never recorded" test -d "$state/feedback" -a ! -e "$state/feedback/25" -a ! -e "$state/feedback/25.md"
ok "G03-AC-2: the second run, nothing new, prints nothing" silent

# a new owner comment on PR 11 after the record (older items 1100, 1101 are recorded)
python3 -I - "$data/issues-11-comments.json" <<'EOS'
import json, sys
new = {"id": 1102, "html_url": "https://github.com/o/r/pull/11#issuecomment-1102", "user": {"login": "owner", "type": "User"},
       "author_association": "OWNER", "body": "NEWITEM-BODY also update the docs", "created_at": "2026-11-09T09:30:00Z"}
open(sys.argv[1], "a").write(json.dumps([new]) + "\n")
EOS
rec=$tmp/rec11; cp "$state/feedback/11" "$rec" 2>/dev/null
echo "repos/o/r/pulls/11/reviews" >"$FB_FAIL"; : >"$FB_CALLS"
out=$(fb 2>"$tmp/err"); rc=$?
ok "G03-AC-2: a failing gh call exits non-zero" test "$rc" -ne 0 -a "$rc" -ne 2 && grep -qxF repos/o/r/pulls/11/reviews "$FB_CALLS"
ok "G03-AC-2: a failing gh call prints nothing for that PR" test "$rc" -ne 0 -a "$rc" -ne 2 -a -z "$out" -a -s "$FB_CALLS"
ok "G03-AC-2: a failing gh call leaves the record unchanged" cmp -s "$rec" "$state/feedback/11"
: >"$FB_FAIL"
out=$(fb 2>"$tmp/err"); rc=$?
ok "G03-AC-2: the next run prints the item, only that PR, exit 0" test "$out" = "11 node/N11-conv" -a "$rc" = 0
md=$state/feedback/11.md
ok "G03-AC-2: FEEDBACK.md holds the PR and its branch" sh -c 'grep -qxF "PR: 11" "$1" && grep -qxF "Branch: node/N11-conv" "$1"' x "$md"
ok "G03-AC-2: FEEDBACK.md holds the item's kind, ID, URL, author and time" sh -c '
	grep -qxF "kind: conversation" "$1" && grep -qxF "id: 1102" "$1" &&
	grep -qxF "url: https://github.com/o/r/pull/11#issuecomment-1102" "$1" && grep -qxF "author: owner" "$1" &&
	grep -qxF "time: 2026-11-09T09:30:00Z" "$1"' x "$md"
ok "G03-AC-2: FEEDBACK.md holds the item's body" grep -qF "NEWITEM-BODY also update the docs" "$md"
ok "G03-AC-2: a later item prints the PR with only the new item" sh -c '[ -s "$1" ] && ! grep -qF "please rename the flag" "$1" && ! grep -qxF "id: 1101" "$1"' x "$md"
fb mark 11; ok "G03-AC-1: mark exits 0" test $? -eq 0
ok "G03-AC-1: after mark, no more for the same items" silent

# the record of a PR no longer open is removed
grep -v '^18 ' "$prs" >"$tmp/prs-no18"
PRS=$tmp/prs-no18 fb >/dev/null 2>&1
ok "G03-AC-2: the record of a PR no longer open is removed" test -e "$state/feedback/17" -a ! -e "$state/feedback/18"
ok "G03-AC-2: the records of the open ones stay" test -e "$state/feedback/11" -a -e "$state/feedback/12"

# --- later-seen bot PRs start from an empty record: the kinds of feedback ------------------------------------
cp -R "$src/testdata/feedback/." "$data/"; : >"$FB_FAIL"
state=$tmp/b
mkdir -p "$state/feedback" "$state/node/N22" "$state/node/N23/answered" "$state/pr/24"
cp "$tmp/a/node/N22/ANSWER.md" "$state/node/N22/"; cp "$tmp/a/node/N23/answered/"* "$state/node/N23/answered/"; cp "$tmp/a/pr/24/ANSWER.md" "$state/pr/24/"
out=$(fb 2>"$tmp/err"); rc=$?
ok "G03-AC-1: exit 0 on a clean read" test "$rc" = 0
printed=$(printf '%s\n' "$out" | nums)
has() { case " $printed" in *" $1 "*) return 0 ;; esac; return 1; }
ok "G03-AC-1: an owner's conversation comment prints the PR (read from the second page)" has 11
ok "G03-AC-1: an owner's line comment prints the PR (its review's body empty)" has 12
ok "G03-AC-1: a CHANGES_REQUESTED review prints the PR" has 13
ok "G03-AC-1: a COMMENTED review with a body prints the PR" has 14
ok "G03-AC-1: an owner's comment on a spec PR prints it" has 26
ok "G03-AC-1: a follow-up PR (node/<ID>-followup-<n>) prints" has 27
ok "G03-AC-1: an owner comment on the PR from before the record (empty record) prints" has 10
not() { [ "$rc" = 0 ] && [ -n "$printed" ] && ! has "$1"; }
ok "G03-AC-1: an approval does not print the PR" not 15
ok "G03-AC-1: a review with an empty body does not print the PR" not 16
ok "G03-AC-1: a comment that is only a thumbs-up emoji does not print" not 17
ok "G03-AC-1: a comment that is only :+1: does not print" not 18
ok "G03-AC-1: a comment that is only +1 does not print" not 19
ok "G03-AC-1: another user's comment does not print" not 20
ok "G03-AC-1: the bot's own comment does not print" not 21
ok "G03-AC-1: an owner comment recorded as an answer (node unit ANSWER.md) does not print" not 22
ok "G03-AC-1: an owner comment recorded as an answer (answered/*-ANSWER.md) does not print" not 23
ok "G03-AC-1: an owner comment recorded as an answer (pr/<N>/ANSWER.md) does not print" not 24
ok "G03-AC-1: a comment on a human's PR does not print" not 25
ok "G03-AC-1: the printed lines are \"<N> <branch>\" in the PR list's order" test "$out" = "10 node/N10-old
11 node/N11-conv
12 node/N12-line
13 node/N13-changes
14 node/N14-commented
26 spec/triage-5-thing
27 node/N27-followup-1"

# a line comment's file, line and thread; the kinds of the other items
md=$state/feedback/12.md
ok "G03-AC-2: FEEDBACK.md holds a line comment's kind, ID, URL and author" sh -c '
	grep -qxF "kind: line" "$1" && grep -qxF "id: 1201" "$1" && grep -qxF "author: owner" "$1" &&
	grep -qxF "url: https://github.com/o/r/pull/12#discussion_r1201" "$1"' x "$md"
ok "G03-AC-2: FEEDBACK.md holds a line comment's time and body" sh -c '
	grep -qxF "time: 2026-11-03T12:00:00Z" "$1" && grep -qF "use a constant here" "$1"' x "$md"
ok "G03-AC-2: FEEDBACK.md holds a line comment's file, line and thread" sh -c '
	grep -qxF "file: src/a.py" "$1" && grep -qxF "line: 42" "$1" && grep -qxF "thread: 1200" "$1"' x "$md"
ok "G03-AC-2: the bot's own line comment is not an item" sh -c '[ -s "$1" ] && ! grep -qxF "id: 1200" "$1"' x "$md"
ok "G03-AC-2: FEEDBACK.md of a review holds kind, ID, URL, author, time and body" sh -c '
	grep -qxF "kind: review" "$1" && grep -qxF "id: 1300" "$1" && grep -qxF "author: owner" "$1" &&
	grep -qxF "url: https://github.com/o/r/pull/13#pullrequestreview-1300" "$1" &&
	grep -qxF "time: 2026-11-02T11:00:00Z" "$1" && grep -qF "this needs a test" "$1"' x "$state/feedback/13.md"
ok "G03-AC-2: FEEDBACK.md of a spec PR holds the PR and its branch" sh -c '
	grep -qxF "PR: 26" "$1" && grep -qxF "Branch: spec/triage-5-thing" "$1"' x "$state/feedback/26.md"

# mark advances every printed PR; nothing prints afterwards
for n in 10 11 12 13 14 26 27; do fb mark "$n"; done
ok "G03-AC-1: after feedback.py mark, no more for the same items (every kind)" silent

# --- S09: hand over an item that came from outside the PR (the pickup step's feedback decision) ----------------
# The interface S09 fixes (scheduler/pickup.test.sh uses it through pickup.py):
#   python3 -I feedback.py --repo O/N --state DIR --owner LOGIN --prs FILE add N ITEMFILE
# ITEMFILE is a JSON object {"id": comment id, "url", "author": login, "time", "body"} (other keys are ignored). PR N must be
# an open bot PR of FILE on node/<ID>-... or spec/...; the item goes into the unit's FEEDBACK.md (node/<ID>/ or pr/<N>/ of DIR),
# written as the loop's hand-over writes it ("# Feedback", "PR: N", "Branch: B" when the file is new; per item kind
# (conversation), id, url, author, time, body: continuation lines indented), appended when the file exists; an item whose URL
# the file holds is not added twice; the unit's starts file is set to 0, as the loop's hand-over does. Exit 0 and nothing on
# stdout when done; exit 1 (a line on stderr), nothing written, when N is no such PR or the item file is unreadable. The record
# DIR/feedback/ is not touched (the item is not on the PR).
s9=$tmp/S09; mkdir -p "$s9/state/node/F06"
s9prs=$s9/open-prs.tsv
printf '20 node/F06-thing aaaa true MERGEABLE\n21 node/G07-human bbbb false MERGEABLE\n26 spec/triage-5-thing cccc true MERGEABLE\n27 feature/x dddd true MERGEABLE\n' >"$s9prs"
echo 2 >"$s9/state/node/F06/starts"
s9item() { python3 -I -c 'import json, sys; json.dump({"id": int(sys.argv[2]), "url": sys.argv[3], "author": "owner", "time": "2026-06-02T10:00:00Z", "body": sys.argv[4], "extra": 1}, open(sys.argv[1], "w"))' "$@"; }
s9add() { python3 -I "$src/feedback.py" --repo o/r --state "$s9/state" --owner owner --prs "$s9prs" add "$@"; }
s9item "$s9/i1.json" 5001 "https://github.com/o/r/issues/13#issuecomment-5001" "please also handle empty input"
s9item "$s9/i2.json" 5002 "https://github.com/o/r/issues/14#issuecomment-5002" "first line
second line"
out=$(s9add 20 "$s9/i1.json" 2>"$tmp/err"); rc=$?
f=$s9/state/node/F06/FEEDBACK.md
ok "S09-AC-3: feedback.py add 20 exits 0 and prints nothing" test "$rc" = 0 -a -z "$out"
ok "S09-AC-3: add writes the node unit's FEEDBACK.md with the PR and its branch" sh -c 'grep -qxF "# Feedback" "$1" && grep -qxF "PR: 20" "$1" && grep -qxF "Branch: node/F06-thing" "$1"' x "$f"
ok "S09-AC-3: add writes the item's kind, id, url, author, time and body" sh -c '
	grep -qxF "kind: conversation" "$1" && grep -qxF "id: 5001" "$1" && grep -qxF "url: https://github.com/o/r/issues/13#issuecomment-5001" "$1" &&
	grep -qxF "author: owner" "$1" && grep -qxF "time: 2026-06-02T10:00:00Z" "$1" && grep -qxF "body: please also handle empty input" "$1"' x "$f"
ok "S09-AC-3: add sets the unit's starts to 0 (the loop starts its feedback session)" test "$(cat "$s9/state/node/F06/starts" 2>/dev/null)" = 0
ok "S09-AC-3: add leaves the PR's record alone (no feedback/ folder made)" test -s "$f" -a ! -e "$s9/state/feedback"
s9add 20 "$s9/i2.json" >/dev/null 2>&1; rc=$?
ok "S09-AC-3: a second item is appended to the same FEEDBACK.md (one header, both items)" sh -c '[ "$2" = 0 ] && [ "$(grep -c "^# Feedback" "$1")" = 1 ] && [ "$(grep -c "^PR: 20" "$1")" = 1 ] && [ "$(grep -c "^kind: " "$1")" = 2 ] && grep -qxF "id: 5001" "$1" && grep -qxF "id: 5002" "$1"' x "$f" "$rc"
ok "S09-AC-3: a body of several lines: the first on the body line, the rest indented" sh -c 'grep -qxF "body: first line" "$1" && grep -qxF "  second line" "$1"' x "$f"
cp "$f" "$s9/f.before"
s9add 20 "$s9/i1.json" >/dev/null 2>&1; rc=$?
ok "S09-AC-3: adding an item whose URL the file holds changes nothing (exit 0)" sh -c '[ "$1" = 0 ] && [ -s "$3" ] && cmp -s "$2" "$3"' x "$rc" "$s9/f.before" "$f"
s9item "$s9/i3.json" 5003 "https://github.com/o/r/pull/26#issuecomment-5003" "the spec needs a rollback section"
s9add 26 "$s9/i3.json" >/dev/null 2>&1; rc=$?
ok "S09-AC-3: add for a spec PR writes pr/26/FEEDBACK.md with the PR and the branch" sh -c '[ "$2" = 0 ] && grep -qxF "PR: 26" "$1" && grep -qxF "Branch: spec/triage-5-thing" "$1" && grep -qxF "id: 5003" "$1"' x "$s9/state/pr/26/FEEDBACK.md" "$rc"
for n in 21 27 99; do
	out=$(s9add $n "$s9/i1.json" 2>/dev/null); rc=$?
	ok "S09-AC-4: add for PR $n (a human's / on another branch / not in the list) exits 1 and prints nothing (the first add worked)" test "$rc" = 1 -a -z "$out" -a -s "$f"
done
ok "S09-AC-4: and writes no unit folder for them" test -s "$f" -a ! -e "$s9/state/node/G07" -a ! -e "$s9/state/pr/21" -a ! -e "$s9/state/pr/27" -a ! -e "$s9/state/pr/99"
s9add 20 "$s9/none.json" >/dev/null 2>&1; rc=$?
ok "S09-AC-3: add with an unreadable item file exits 1 and leaves FEEDBACK.md as it was" sh -c '[ "$1" = 1 ] && [ -s "$3" ] && cmp -s "$2" "$3"' x "$rc" "$s9/f.before" "$f"

[ "$fails" -eq 0 ] || { echo "$fails FAILED"; exit 1; }
echo "all passed"
