#!/bin/sh
# Tests scheduler/report.py: the questions of a spec-PR feedback session (G03-AC-10).
#   sh scheduler/report-g03.test.sh   (make test)
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
for n in (51, 52, 90, 91, 92, 93):
    db['issues'][str(n)] = {'number': n, 'title': 'Seeded %d' % n, 'body': '', 'labels': [], 'state': 'open', 'node_id': 'I_%d' % n}
json.dump(db, open('$udb', 'w'))"
mkspec G91 fb-node '#51'
git -C "$uclone" add nodes && git -C "$uclone" -c user.name=t -c user.email=t@t commit -q -m specs2 &&
	git -C "$uclone" update-ref refs/remotes/origin/main HEAD

gs=$tmp/gstate
mkdir -p "$gs/node/G91" "$gs/pr/90" "$gs/pr/91" "$gs/pr/92"
: >"$gs/status.log"
# open-prs.tsv as the loop writes it: <number> <branch> <headOid> <is_bot> <mergeable>
printf '%s\n' '90 spec/triage-52-fb-spec aaa111 true MERGEABLE' '91 spec/other-topic bbb222 true MERGEABLE' \
	'92 spec/triage-53-update ccc333 true MERGEABLE' '95 node/G91-fb-node ddd444 true MERGEABLE' >"$gs/open-prs.tsv"
fbmd() { printf '# Feedback on PR %s\n\nPR: %s\nBranch: %s\n\nkind: comment\nid: 1\n' "$1" "$1" "$2" >"$3"; }
fbmd 90 spec/triage-52-fb-spec "$gs/pr/90/FEEDBACK.md"
fbmd 91 spec/other-topic "$gs/pr/91/FEEDBACK.md"
fbmd 95 node/G91-fb-node "$gs/node/G91/FEEDBACK.md"
printf 'Q1: which placement?\ng03-q90-unique\n' >"$gs/pr/90/QUESTION.md"
printf 'Q1: which scope?\ng03-q91-unique\n' >"$gs/pr/91/QUESTION.md"
printf 'Q1: update only?\ng03-q92-unique\n' >"$gs/pr/92/QUESTION.md"
printf 'Q1: which node way?\ng03-qnode-unique\n' >"$gs/node/G91/QUESTION.md"
urun "$gs"; urun "$gs"; urun "$gs"
ok "G03-AC-10: a feedback session's QUESTION.md of a PR on spec/triage-<N>-* is posted on issue N, once over three runs" test "$(ucount 52 'g03-q90-unique')" = 1
ok "G03-AC-10: and is not posted on the PR itself" test "$(ucount 90 'g03-q90-unique')" = 0
ok "G03-AC-10: a feedback session's QUESTION.md of a PR on another spec branch is posted on the PR itself, once over three runs" test "$(ucount 91 'g03-q91-unique')" = 1
ok "G03-AC-10: and not on the issue of the other PR" test "$(ucount 52 'g03-q91-unique')" = 0
ok "G03-AC-10: an update's QUESTION.md (no FEEDBACK.md) is not posted" test "$(uq "len([c for c in db['comments'] if 'g03-q92-unique' in c['body']])")" = 0
ok "G03-AC-10: a node's feedback question stays the node's: posted on its home issue, once" test "$(ucount 51 'g03-qnode-unique')" = 1
ok "G03-AC-10: and not on its PR" test "$(ucount 95 'g03-qnode-unique')" = 0
ok "G03-AC-10: no pr/<N>/issue file is written for a spec-PR feedback unit" test ! -e "$gs/pr/90/issue" -a ! -e "$gs/pr/91/issue"
ok "G03-AC-10: no Build issue is made for a PR" test "$(uq "len([i for i in db['issues'].values() if 'PR #' in i['title']])")" = 0

uowned 52 "put it in G03" https://x/g03-ans90
uowned 91 "keep the scope" https://x/g03-ans91
urun "$gs"; urun "$gs"; urun "$gs"
ok "G03-AC-10: the owner's comment on issue N after the question becomes pr/<PR>/ANSWER.md" grep -qsF 'https://x/g03-ans90' "$gs/pr/90/ANSWER.md"
ok "G03-AC-10: ANSWER.md holds the owner's words" grep -qsF 'put it in G03' "$gs/pr/90/ANSWER.md"
ok "G03-AC-10: the owner's comment on the PR itself becomes its pr/<PR>/ANSWER.md" grep -qsF 'https://x/g03-ans91' "$gs/pr/91/ANSWER.md"
ok "G03-AC-10: an answer is not the answer of the other PR" sh -c "! grep -qsF 'g03-ans91' '$gs/pr/90/ANSWER.md' && ! grep -qF 'g03-ans90' '$gs/pr/91/ANSWER.md'"
ok "G03-AC-10: the update without FEEDBACK.md got no answer" test ! -e "$gs/pr/92/ANSWER.md"
ok "G03-AC-10: the questions are still posted once after the answers" test "$(ucount 52 'g03-q90-unique')$(ucount 91 'g03-q91-unique')" = 11

echo "report-g03: $fails failure(s)"
[ "$fails" = 0 ]
