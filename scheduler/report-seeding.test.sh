#!/bin/sh
# Tests scheduler/report.py: the first run of this version beside failed GitHub calls and merged nodes (U01-AC-3, U01-AC-6, U01-AC-9).
#   sh scheduler/report-seeding.test.sh   (make test)
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
# U01-AC-3 "merged once" + U01-AC-9 (S3c, G1): a failed `gh pr list` leaves merged-prs.tsv empty (the loop truncates it first)
# while subjects.txt + graph.yaml still show the merges; the node's merged milestone is not posted again, no issue is created,
# nothing is closed or commented, once the file is back.
pyc "
import json
db = json.load(open('$udb'))
db['issues']['81'] = {'number': 81, 'title': 'Seeded 81', 'body': '', 'labels': [], 'state': 'open', 'node_id': 'I_81'}
json.dump(db, open('$udb', 'w'))"
mkspec P01 p-one '#81'
mkspec P02 p-two ''
mkspec P03 p-three ''
git -C "$uclone" add nodes && git -C "$uclone" -c user.name=t -c user.email=t@t commit -q -m specs5 &&
	git -C "$uclone" update-ref refs/remotes/origin/main HEAD
ustate9=$tmp/ustate9
mkdir -p "$ustate9/node/P01" "$ustate9/node/P02" "$ustate9/node/P03"
cat >"$ustate9/graph.yaml" <<'GRAPH'
nodes:
  - {id: P01, name: p-one, deps: []}
  - {id: P02, name: p-two, deps: []}
  - {id: P03, name: p-three, deps: []}
GRAPH
: >"$ustate9/status.log"
usetpulls '[]'
rm -f "$tmp/ufail"
# P03 was merged long ago: known from both sources at the seed run, no home issue
echo "703 node/P03-p-three" >"$ustate9/merged-prs.tsv"
echo "P03 p-three: long ago (#703)" >"$ustate9/subjects.txt"
: >"$ustate9/closed-prs.tsv"
urun "$ustate9"
ev "started P01 (p-one) in /wt, pid 1, start 1 of 2" "$ustate9"
ev "started P02 (p-two) in /wt, pid 2, start 1 of 2" "$ustate9"
urun "$ustate9"; urun "$ustate9"; urun "$ustate9"
p1=$(cat "$ustate9/node/P01/issue" 2>/dev/null); p2=$(cat "$ustate9/node/P02/issue" 2>/dev/null)
printf '701 node/P01-p-one\n702 node/P02-p-two\n703 node/P03-p-three\n' >"$ustate9/merged-prs.tsv"
printf 'P01 p-one: it (#701)\nP02 p-two: it (#702)\nP03 p-three: long ago (#703)\n' >"$ustate9/subjects.txt"
urun "$ustate9"; urun "$ustate9"; urun "$ustate9"
ok "U01-AC-3: (precondition G1) P01 (Resolves #81) and P02 (no Resolves line) each have one merged milestone naming their PR" test "$p1" = 81 -a -n "$p2" -a "$(ucount 81 '(?i)merged.*701|701.*merged')" -ge 1 -a "$(ucount "${p2:-0}" '(?i)merged.*702|702.*merged')" -ge 1
ok "U01-AC-6: (precondition G1) P01's issue 81 is closed" test "$(ustateof 81)" = closed
g1c=$(uq "len(db['comments'])"); g1i=$(uq "len(db['issues'])")
g1m1=$(ucount 81 '(?i)\bmerged\b'); g1m2=$(ucount "${p2:-0}" '(?i)\bmerged\b')
: >"$tmp/ucalls"
: >"$ustate9/merged-prs.tsv"; : >"$ustate9/closed-prs.tsv"
urun "$ustate9"; urun "$ustate9"; urun "$ustate9"
printf '701 node/P01-p-one\n702 node/P02-p-two\n703 node/P03-p-three\n' >"$ustate9/merged-prs.tsv"
urun "$ustate9"; urun "$ustate9"; urun "$ustate9"
ok "U01-AC-3: a run with merged-prs.tsv empty (failed gh pr list) and the file restored post no second merged milestone for P01 (Resolves line)" test "$(ucount 81 '(?i)\bmerged\b')" = "$g1m1"
ok "U01-AC-3: nor for P02 (no Resolves line)" test "$(ucount "${p2:-0}" '(?i)\bmerged\b')" = "$g1m2"
ok "U01-AC-9: no issue is created (no Build issue for P03, merged long ago with no home issue)" test "$(uq "len(db['issues'])")" = "$g1i" -a "$(ubuilds 'Build P03 p-three')" = 0 -a ! -e "$ustate9/node/P03/issue"
ok "U01-AC-9: no comment of any kind is added anywhere" test "$(uq "len(db['comments'])")" = "$g1c"
ok "U01-AC-6: nothing is closed or reopened again (no PATCH of 81, of P02's home or of any issue but the status body)" test "$(upatches 81)" = 0 -a "$(upatches "${p2:-0}")" = 0 -a "$(grep -c '^PATCH' "$tmp/ucalls" || true)" -le 3

# U01-AC-3 "the CI result once per PR head commit" (S3c, G2): a transient failure of the check-runs call (its message names the
# path, and so the sha, which here holds 404 / 403) is retried; the CI result is posted once after it succeeds.
mkspec Q01 q-one ''
mkspec Q02 q-two ''
git -C "$uclone" add nodes && git -C "$uclone" -c user.name=t -c user.email=t@t commit -q -m specs6 &&
	git -C "$uclone" update-ref refs/remotes/origin/main HEAD
ustate10=$tmp/ustate10
mkdir -p "$ustate10/node/Q01" "$ustate10/node/Q02"
: >"$ustate10/status.log"
usetpulls '[]'
urun "$ustate10"
ev "started Q01 (q-one) in /wt, pid 1, start 1 of 2" "$ustate10"
ev "started Q02 (q-two) in /wt, pid 2, start 1 of 2" "$ustate10"
urun "$ustate10"; urun "$ustate10"
q1=$(cat "$ustate10/node/Q01/issue" 2>/dev/null); q2=$(cat "$ustate10/node/Q02/issue" 2>/dev/null)
usetchecks c0404de '[{"name": "test", "status": "completed", "conclusion": "success"}]'
usetchecks c0403de '[{"name": "test", "status": "completed", "conclusion": "failure"}]'
usetpulls "[$(upull 604 node/Q01-q-one c0404de), $(upull 603 node/Q02-q-two c0403de)]"
echo 'GET .*check-runs' >"$tmp/ufail"
urun "$ustate10"
urun "$ustate10"
ok "U01-AC-3: (precondition G2) while the check-runs call fails no CI result is posted" test "$(ucount "${q1:-0}" '(?i)CI (passed|failed)')" = 0
rm -f "$tmp/ufail"
urun "$ustate10"; urun "$ustate10"; urun "$ustate10"
ok "U01-AC-3: after a transient HTTP 502 on the check-runs call of a head commit whose sha holds 404, its CI result is posted once" test -n "$q1" -a "$(ucount "$q1" '(?i)CI passed')" = 1
ok "U01-AC-3: likewise for a sha holding 403 (a failed result naming its failing check), once" test -n "$q2" -a "$(ucount "$q2" '(?is)CI failed.*test')" = 1
ok "U01-AC-3: and the PR opened is still posted once on each" test "$(ucount "${q1:-0}" 'pull/604\b')" = 1 -a "$(ucount "${q2:-0}" 'pull/603\b')" = 1

# U01-AC-9 (S3c, G3): the first run on an old report.json happens while the clone cannot be read; the issue of a node merged
# before, already closed, is never commented on or patched by later runs with the clone readable.
pyc "
import json
db = json.load(open('$udb'))
db['issues']['85'] = {'number': 85, 'title': 'Seeded 85', 'body': '', 'labels': [], 'state': 'closed', 'node_id': 'I_85'}
json.dump(db, open('$udb', 'w'))"
mkspec R01 r-one '#85'
git -C "$uclone" add nodes && git -C "$uclone" -c user.name=t -c user.email=t@t commit -q -m specs7 &&
	git -C "$uclone" update-ref refs/remotes/origin/main HEAD
urun_noclone() { env PATH="$ubin:$PATH" python3 -I "$src/report.py" --repo owner/repo --state "$1" --worktrees "$tmp/worktrees/repo" --clone "$tmp/no-such-clone" --owner owner 2>"$tmp/uerr"; }
ustate11=$tmp/ustate11
mkdir -p "$ustate11/node/R01"
: >"$ustate11/status.log"
usetpulls '[]'
echo "801 node/R01-r-one" >"$ustate11/merged-prs.tsv"
rmax=$(uq "max([c['id'] for c in db['comments']] or [0])")
printf '{"issue": %s, "comment_id": %s, "log_offset": 0, "questions": {}, "body_hash": "x", "body_time": 0}\n' \
	"$ustatus" "$rmax" >"$ustate11/report.json"
: >"$tmp/ucalls"
urun_noclone "$ustate11"
urun_noclone "$ustate11"
urun "$ustate11"; urun "$ustate11"; urun "$ustate11"; urun "$ustate11"
ok "U01-AC-9: with the clone unreadable at the first run, a node merged before and its closed Resolves issue (85) get no comment later" test "$(unum 85)" = 0
ok "U01-AC-9: and no PATCH of it ever, and it stays closed" test "$(upatches 85)" = 0 -a "$(ustateof 85)" = closed

# U01-AC-9 + U01-AC-3 (S3d, H1a): the seed run (first run with this bookkeeping) coincides with a failed `gh pr list`
# (merged-prs.tsv and closed-prs.tsv empty) while subjects.txt + graph.yaml show nodes merged long ago; once the files are
# back, those nodes get no merged milestone, no Build issue, no comment on their closed Resolves issue and no PATCH.
# Two cases: an old report.json (no pr_seed) and no report.json at all.
pyc "
import json
db = json.load(open('$udb'))
for n in (91, 92, 93, 94):
    db['issues'][str(n)] = {'number': n, 'title': 'Seeded %d' % n, 'body': '', 'labels': [], 'state': 'closed', 'node_id': 'I_%d' % n}
json.dump(db, open('$udb', 'w'))"
mkspec M01 m-one '#91'
mkspec M02 m-two ''
mkspec N01 n-one '#92'
mkspec N02 n-two ''
mkspec K01 k-one '#93'
mkspec K02 k-two ''
mkspec K03 k-three ''
mkspec H01 h-one '#95, #96'
git -C "$uclone" add nodes && git -C "$uclone" -c user.name=t -c user.email=t@t commit -q -m specs8 &&
	git -C "$uclone" update-ref refs/remotes/origin/main HEAD
# uanypatch: the PATCH calls since $tmp/ucalls was emptied, other than on the status issue.
uanypatch() { grep '^PATCH' "$tmp/ucalls" | grep -vc "issues/$ustatus\$" || true; }
ok "U01-AC-9: (self-check) uanypatch ignores the status issue and counts another" sh -c "printf 'PATCH repos/o/r/issues/$ustatus\nPATCH repos/o/r/issues/9\n' | grep '^PATCH' | grep -vc 'issues/$ustatus\$' | grep -qx 1"
usetpulls '[]'
rm -f "$tmp/ufail"
h1mk() { # <state> <A> <B> <issue of A>: nodes A (Resolves issue) and B (none), merged long ago per the subjects, graph and folders
	mkdir -p "$1/node/$2" "$1/node/$3"
	printf 'nodes:\n  - {id: %s, name: x-a, deps: []}\n  - {id: %s, name: x-b, deps: []}\n' "$2" "$3" >"$1/graph.yaml"
	: >"$1/status.log"; : >"$1/merged-prs.tsv"; : >"$1/closed-prs.tsv"
	printf '%s x-a: it (#%s)\n%s x-b: it (#%s)\n' "$2" "$4" "$3" "$(($4 + 1))" >"$1/subjects.txt"
}
h1back() { # <state> <A> <B> <PR of A>
	printf '%s node/%s-x-a\n%s node/%s-x-b\n' "$4" "$2" "$(($4 + 1))" "$3" >"$1/merged-prs.tsv"
	printf '%s node/%s-x-a 2026-01-01T00:00:00Z true\n%s node/%s-x-b 2026-01-01T00:00:00Z true\n' "$4" "$2" "$(($4 + 1))" "$3" >"$1/closed-prs.tsv"
}
# old report.json
ustate12=$tmp/ustate12
h1mk "$ustate12" M01 M02 911
sed -i 's/x-a/m-one/g; s/x-b/m-two/g' "$ustate12/graph.yaml" "$ustate12/subjects.txt"
h1max=$(uq "max([c['id'] for c in db['comments']] or [0])")
printf '{"issue": %s, "comment_id": %s, "log_offset": 0, "questions": {}, "body_hash": "x", "body_time": 0}\n' \
	"$ustatus" "$h1max" >"$ustate12/report.json"
h1c=$(uq "len(db['comments'])"); h1i=$(uq "len(db['issues'])")
: >"$tmp/ucalls"
urun "$ustate12"; urun "$ustate12"
printf '911 node/M01-m-one\n912 node/M02-m-two\n' >"$ustate12/merged-prs.tsv"
printf '911 node/M01-m-one 2026-01-01T00:00:00Z true\n912 node/M02-m-two 2026-01-01T00:00:00Z true\n' >"$ustate12/closed-prs.tsv"
urun "$ustate12"; urun "$ustate12"; urun "$ustate12"; urun "$ustate12"
ok "U01-AC-9: (H1a, old report.json) a seed run with merged-prs.tsv empty, then the file restored: no merged milestone on the closed Resolves issue (91)" test "$(ucount 91 '(?i)merged')" = 0
ok "U01-AC-9: (H1a, old report.json) no Build issue for the node without a Resolves line (M02)" test "$(ubuilds 'Build M02 m-two')" = 0 -a ! -e "$ustate12/node/M02/issue" -a "$(uq "len(db['issues'])")" = "$h1i"
ok "U01-AC-9: (H1a, old report.json) no comment of any kind is added anywhere" test "$(uq "len(db['comments'])")" = "$h1c"
ok "U01-AC-9: (H1a, old report.json) no PATCH of the closed Resolves issue (91) or of any issue but the status issue, and 91 stays closed" test "$(upatches 91)" = 0 -a "$(uanypatch)" = 0 -a "$(ustateof 91)" = closed
# no report.json at all
ustate13=$tmp/ustate13
h1mk "$ustate13" N01 N02 921
sed -i 's/x-a/n-one/g; s/x-b/n-two/g' "$ustate13/graph.yaml" "$ustate13/subjects.txt"
h1c=$(uq "len(db['comments'])"); h1i=$(uq "len(db['issues'])")
: >"$tmp/ucalls"
urun "$ustate13"; urun "$ustate13"
printf '921 node/N01-n-one\n922 node/N02-n-two\n' >"$ustate13/merged-prs.tsv"
printf '921 node/N01-n-one 2026-01-01T00:00:00Z true\n922 node/N02-n-two 2026-01-01T00:00:00Z true\n' >"$ustate13/closed-prs.tsv"
urun "$ustate13"; urun "$ustate13"; urun "$ustate13"; urun "$ustate13"
h1c2=$(uq "len(db['comments'])")
ok "U01-AC-9: (H1a, no report.json) no merged milestone on the closed Resolves issue (92)" test "$(ucount 92 '(?i)merged')" = 0
ok "U01-AC-9: (H1a, no report.json) no Build issue for the node without a Resolves line (N02)" test "$(ubuilds 'Build N02 n-two')" = 0 -a ! -e "$ustate13/node/N02/issue"
ok "U01-AC-9: (H1a, no report.json) no PATCH of 92 or of any issue but the status issue, and no comment added by the later runs" test "$(upatches 92)" = 0 -a "$(uanypatch)" = 0 -a "$h1c2" = "$h1c" -a "$(ustateof 92)" = closed

# U01-AC-9 + U01-AC-3 (S3d, H1b): the seed run happens with merged-prs.tsv filled but closed-prs.tsv empty (its call failed);
# once it is back, with an old PR closed without merging and the merged ones, nothing is posted for them.
ustate14=$tmp/ustate14
mkdir -p "$ustate14/node/K01" "$ustate14/node/K02" "$ustate14/node/K03"
printf 'nodes:\n  - {id: K01, name: k-one, deps: []}\n  - {id: K02, name: k-two, deps: []}\n  - {id: K03, name: k-three, deps: []}\n' >"$ustate14/graph.yaml"
: >"$ustate14/status.log"
printf 'K01 k-one: it (#931)\nK02 k-two: it (#932)\n' >"$ustate14/subjects.txt"
printf '931 node/K01-k-one\n932 node/K02-k-two\n' >"$ustate14/merged-prs.tsv"
: >"$ustate14/closed-prs.tsv"
printf '{"issue": %s, "comment_id": %s, "log_offset": 0, "questions": {}, "body_hash": "x", "body_time": 0}\n' \
	"$ustatus" "$h1max" >"$ustate14/report.json"
h1c=$(uq "len(db['comments'])"); h1i=$(uq "len(db['issues'])")
: >"$tmp/ucalls"
urun "$ustate14"; urun "$ustate14"
printf '931 node/K01-k-one 2026-01-02T00:00:00Z true\n932 node/K02-k-two 2026-01-02T00:00:00Z true\n930 node/K03-k-three 2026-01-01T00:00:00Z false\n' >"$ustate14/closed-prs.tsv"
urun "$ustate14"; urun "$ustate14"; urun "$ustate14"; urun "$ustate14"
ok "U01-AC-3: (H1b) a seed run with closed-prs.tsv empty, then restored: no closed-without-merging milestone for the old closed PR (930)" test "$(uq "len([c for c in db['comments'] if 'closed without' in c['body'].lower() and '#930' in c['body']])")" = 0
ok "U01-AC-9: (H1b) nothing else is new: no Build issue (K03), no comment anywhere, no PATCH but the status issue's" test "$(uq "len(db['issues'])")" = "$h1i" -a "$(ubuilds 'Build K03 k-three')" = 0 -a ! -e "$ustate14/node/K03/issue" -a "$(uq "len(db['comments'])")" = "$h1c" -a "$(uanypatch)" = 0
ok "U01-AC-9: (H1b) no merged milestone for K01 (Resolves 93, closed) either" test "$(ucount 93 '(?i)merged')" = 0 -a "$(ustateof 93)" = closed

# U01-AC-6 (S3d, H2): a Resolves issue of a merged node that the owner closed as "not planned" before the loop's rule holds
# is not patched, commented on or touched later; a sibling Resolves issue (95) still gets closed by the rule.
pyc "
import json
db = json.load(open('$udb'))
for n in (95, 96):
    db['issues'][str(n)] = {'number': n, 'title': 'Seeded %d' % n, 'body': '', 'labels': [], 'state': 'open', 'node_id': 'I_%d' % n}
json.dump(db, open('$udb', 'w'))"
ustate15=$tmp/ustate15
mkdir -p "$ustate15/node/H01"
: >"$ustate15/status.log"
usetpulls '[]'
printf 'Q1: asking while merged?\nh01-unique-q-line\n' >"$ustate15/node/H01/QUESTION.md"
echo "941 node/H01-h-one" >"$ustate15/merged-prs.tsv"
hkey=$(stat -c %Y "$ustate15/node/H01/QUESTION.md")
hmax=$(uq "max([c['id'] for c in db['comments']] or [0])")
printf '{"issue": %s, "comment_id": %s, "log_offset": 0, "questions": {"H01": "%s"}, "body_hash": "x", "body_time": 0}\n' \
	"$ustatus" "$hmax" "$hkey" >"$ustate15/report.json"
urun "$ustate15"; urun "$ustate15"
ok "U01-AC-6: (H2 precondition) both Resolves issues of the merged node H01 are held by its open question and untouched" test "$(ustateof 95)$(ustateof 96)" = openopen -a "$(unum 95)$(unum 96)" = 00
pyc "
import json
db = json.load(open('$udb'))
db['issues']['96'].update(state='closed', state_reason='not_planned')
json.dump(db, open('$udb', 'w'))"
: >"$tmp/ucalls"
rm "$ustate15/node/H01/QUESTION.md"; mkdir "$ustate15/node/H01/answered"
urun "$ustate15"; urun "$ustate15"; urun "$ustate15"; urun "$ustate15"
ok "U01-AC-6: (H2) the sibling Resolves issue (95) is closed by the rule with one comment naming the PR and one PATCH" test "$(ustateof 95)" = closed -a "$(ucount 95 '(#|pull/)941\b')" = 1 -a "$(upatches 95)" = 1
ok "U01-AC-6: (H2) the issue the owner closed as not planned (96) is not patched" test "$(upatches 96)" = 0
ok "U01-AC-6: (H2) and its state_reason is still not_planned and it is closed" test "$(uq "db['issues']['96']['state']+db['issues']['96'].get('state_reason','')")" = closednot_planned
ok "U01-AC-6: (H2) and it gets no comment, now or over later runs" test "$(unum 96)" = 0


if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
