#!/bin/sh
# Tests scheduler/report.py: the signature line on every comment and body (V01-AC-7) and the Build issue created twice (U01-AC-1, U01-AC-9).
#   sh scheduler/report-signed.test.sh   (make test)
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
. "$fakegh_lib/report-api.sh"
. "$fakegh_lib/report-units.sh"
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
# V01-AC-7: with --version and --signature, every comment report.py posts and the status issue body end with the
# signature line (after any cut), and the body's header names the version. Without them, nothing is signed.
# Each part starts from an empty fake database, so its status issue is number 100.
v7=v1.2.3-4-gabcdef0
sig7='— n00dl3b0t [v1.2.3-4-gabcdef0](https://github.com/acme-co/widget-kit/commit/0123456789abcdef0123456789abcdef01234567)'
printf '%s\n' "$sig7" >"$tmp/sig7"
cat >"$tmp/chk7.py" <<'PY'
import json, sys
db = json.load(open(sys.argv[1]))
sig = open(sys.argv[2], encoding="utf-8").read().strip()
mode = sys.argv[3]
arg = sys.argv[4] if len(sys.argv) > 4 else ""
bots = [c["body"] for c in db["comments"] if c["user"]["login"] == "bot"]
issues = db["issues"]
body = issues["100"]["body"] if "100" in issues else None
if mode == "ends":      # at least one bot comment holds arg, and each of them ends with the signature
    hit = [b for b in bots if arg in b]
    ok = bool(hit) and all(b.rstrip().endswith(sig) for b in hit)
elif mode == "all":     # at least 5 bot comments, each ends with the signature
    ok = len(bots) >= 5 and all(b.rstrip().endswith(sig) for b in bots)
elif mode == "cut":     # the cut comment: marker, then the signature at the very end, within GitHub's 65536
    hit = [b for b in bots if "(cut here" in b]
    ok = bool(hit) and all(b.rstrip().endswith(sig) and b.index("(cut here") < b.rindex(sig) and len(b) <= 65536 for b in hit)
elif mode == "body":
    ok = body is not None and body.rstrip().endswith(sig)
elif mode == "header":  # what precedes the first "## " heading names the version
    ok = body is not None and arg in body.split("\n## ")[0]
elif mode == "fallback":
    ok = body is not None and "status failed" in body and body.rstrip().endswith(sig) and arg in body.split("\n")[0:4].__str__()
elif mode == "unsigned":
    ok = len(bots) >= 3 and body is not None and not any("n00dl3b0t" in b for b in bots + [body])
else:
    ok = False
sys.exit(0 if ok else 1)
PY
chk7() { python3 -I "$tmp/chk7.py" "$db" "$tmp/sig7" "$@"; }
resetdb7() { echo '{"issues": {}, "comments": [], "labels": [], "pulls": []}' >"$db"; }
own7() {
	pyc "
import json, sys
db = json.load(open('$db'))
db['comments'].append({'id': len(db['comments']) + 1, 'issue': '100', 'body': sys.argv[1], 'user': {'login': 'owner', 'type': 'User'},
    'author_association': 'OWNER', 'created_at': '2026-01-09T00:00:00Z', 'html_url': 'https://x/c9'})
json.dump(db, open('$db', 'w'))" "$1"
}

state9=$tmp/state/repo9
mkdir -p "$state9/node/A01" "$state9/node/A02" "$state9/node/A03"
: >"$state9/status.log"
resetdb7
run9() { python3 -I "$src/report.py" --repo owner/repo --state "$state9" --worktrees "$tmp/worktrees/repo" --version "$v7" --signature "$sig7" 2>"$tmp/err9"; }
run9
printf 'Q1: which way?\n' >"$state9/node/A01/QUESTION.md"
{ printf 'Q1: a very long one\n'; awk 'BEGIN { for (i = 0; i < 1000; i++) printf "0123456789012345678901234567890123456789012345678901234567890123456789\n" }'; } >"$state9/node/A02/QUESTION.md"
printf 'Q1: short one\n' >"$state9/node/A03/QUESTION.md"
echo "2026-01-09T00:02:00Z open=[] merged-prs=[]; session A01 ended (rc 0) with QUESTION.md" >>"$state9/status.log"
own7 "B07: something"
own7 "A01: go"
run9; rc9a=$?
ok "V01-AC-7: the run with --version and --signature succeeds (answer recorded: exit 3)" test "$rc9a" = 3
ok "V01-AC-7: an event comment ends with the signature line" chk7 ends "session A01 ended"
ok "V01-AC-7: a question comment ends with the signature line" chk7 ends "## A03 asks"
ok "V01-AC-7: an answer reply (Recorded as ...) ends with the signature line" chk7 ends "Recorded as A01's ANSWER.md"
ok "V01-AC-7: a not-recorded reply ends with the signature line" chk7 ends "Not recorded as an answer"
ok "V01-AC-7: an over-long comment is cut, then the signature comes last, within GitHub's limit" chk7 cut
ok "V01-AC-7: every comment posted ends with the signature line" chk7 all
ok "V01-AC-7: the status issue body ends with the signature line" chk7 body
ok "V01-AC-7: the body's header names the version" chk7 header "$v7"
ok "V01-AC-7: the signed run leaves nothing on stderr" test ! -s "$tmp/err9"

# The fallback body (building the body fails: a FAILED that is a folder cannot be read) is signed too.
state10=$tmp/state/repo10
mkdir -p "$state10/node/X01/FAILED"
: >"$state10/status.log"
resetdb7
python3 -I "$src/report.py" --repo owner/repo --state "$state10" --worktrees "$tmp/worktrees/repo" --version "$v7" --signature "$sig7" 2>"$tmp/err10"
ok "V01-AC-7: the fallback status body ends with the signature line and names the version" chk7 fallback "$v7"

# Without the options nothing is signed.
state11=$tmp/state/repo11
mkdir -p "$state11/node/A01" "$state11/node/A02"
: >"$state11/status.log"
resetdb7
run11() { python3 -I "$src/report.py" --repo owner/repo --state "$state11" --worktrees "$tmp/worktrees/repo" 2>"$tmp/err11"; }
run11
printf 'Q1: which way?\n' >"$state11/node/A01/QUESTION.md"
echo "2026-01-09T00:02:00Z open=[] merged-prs=[]; session A02 ended (rc 0)" >>"$state11/status.log"
own7 "B07: something"
run11
ok "V01-AC-7: without the options no comment or body carries a signature" chk7 unsigned

# U01 fresh review (S6): the Build issue body is signed; a comment before the question is not its answer; a Build issue
# whose creating POST failed late is not created twice. Own units (T10..T13), appended to the fixture clone's specs.
mkspec T10 signed-build ''
mkspec T11 plain-build ''
mkspec T12 early-q '#51'
mkspec T13 late-fail ''
git -C "$uclone" add nodes && git -C "$uclone" -c user.name=t -c user.email=t@t commit -q -m specs3 &&
	git -C "$uclone" update-ref refs/remotes/origin/main HEAD
rm -f "$tmp/ufail"

# U01-AC-1 with V01-AC-7: the Build issue body ends with the signature line when --version and --signature are given.
ubody() { SIG=$(cat "$tmp/sig7") pyc "
import json, os, sys
db = json.load(open('$udb'))
b = [i['body'] for i in db['issues'].values() if i['title'] == sys.argv[1]]
if len(b) != 1: sys.exit(2)
if sys.argv[2] == 'ends': sys.exit(0 if b[0].rstrip().endswith(os.environ['SIG'].strip()) else 1)
sys.exit(0 if 'n00dl3b0t' not in b[0] else 1)" "$1" "$2"; }
ustate5=$tmp/ustate5 ustate6=$tmp/ustate6
mkdir -p "$ustate5/node/T10" "$ustate6/node/T11"
: >"$ustate5/status.log"; : >"$ustate6/status.log"
# the first run on a state folder only records what came before it (a fresh report.json); in the whole file ustate6 had its first run in an earlier case
urun "$ustate6"
usigned() { env PATH="$ubin:$PATH" python3 -I "$src/report.py" --repo owner/repo --state "$ustate5" --worktrees "$tmp/worktrees/repo" --clone "$uclone" --owner owner --version "$v7" --signature "$sig7" 2>"$tmp/uerr"; }
usigned
ev "started T10 (signed-build) in /wt, pid 1, start 1 of 2" "$ustate5"
ev "started T11 (plain-build) in /wt, pid 2, start 1 of 2" "$ustate6"
usigned; rcs=$?; usigned
urun "$ustate6"; urun "$ustate6"
ok "U01-AC-1: (signature) the signed runs succeed and create the Build issue once" sh -c "[ $rcs = 0 ] && [ \"\$1\" = 1 ]" _ "$(ubuilds 'Build T10 signed-build')"
ok "U01-AC-1: (signature) with --version and --signature the Build issue body ends with the signature line (V01-AC-7)" ubody 'Build T10 signed-build' ends
ok "U01-AC-1: (signature) without the options the Build issue body carries no signature" ubody 'Build T11 plain-build' none

# U01-AC-4: an owner comment posted after the unit's start milestone (after the floor) but before its question comment
# is not the answer; one posted after the question is.
ustate7=$tmp/ustate7
mkdir -p "$ustate7/node/T12"
: >"$ustate7/status.log"
urun "$ustate7"
ev "started T12 (early-q) in /wt, pid 1, start 1 of 2" "$ustate7"
urun "$ustate7"; urun "$ustate7"
ucomment 51 "too early, before the question" 2026-02-02T00:00:00Z owner OWNER User https://x/t12-early
printf 'Q1: ask late?\nt12-unique-q-line\n' >"$ustate7/node/T12/QUESTION.md"
ev "session T12 ended (rc 0) with QUESTION.md" "$ustate7"
# the run that posts the question cannot read the issue's comments (a failed GET), so the owner's earlier comment is
# first seen by a later run, when the question is already open: only the question's position can tell it is no answer
echo 'GET .*issues/51/comments' >"$tmp/ufail"
urun "$ustate7"
rm -f "$tmp/ufail"
urun "$ustate7"; urun "$ustate7"; urun "$ustate7"
ok "U01-AC-4: (cut-off) the question was posted on the home issue after the owner's comment" test "$(ucount 51 't12-unique-q-line')" = 1
ok "U01-AC-4: (cut-off) an owner comment after the start but before the question is not recorded as ANSWER.md" test ! -e "$ustate7/node/T12/ANSWER.md"
ok "U01-AC-4: (cut-off) and gets no reaction" test "$(ureact https://x/t12-early)" = 0
uowned 51 "t12 real answer" https://x/t12-late
urun "$ustate7"; rct=$?
urun "$ustate7"
ok "U01-AC-4: (cut-off) an owner comment after the question becomes ANSWER.md (exit 3)" sh -c "[ $rct = 3 ] && grep -q '^t12 real answer\$' '$ustate7/node/T12/ANSWER.md'"

# U01-AC-1, U01-AC-9: the creating POST makes the Build issue, then fails (a timeout after GitHub made it). The next run
# finds it by title: one issue with that title, and the unit's issue file holds its number.
ubin2=$tmp/ubin2
mkdir -p "$ubin2"
cat >"$ubin2/gh" <<EOF
#!/bin/sh
# the fake gh; a POST .../issues while $tmp/ucreatefail exists is made, then fails once
if [ "\$3 \${4##*/}" = "POST issues" ] && [ -e "$tmp/ucreatefail" ]; then
	rm -f "$tmp/ucreatefail"; "$ubin/gh" "\$@" >/dev/null; echo "HTTP 504: timeout after the issue was created" >&2; exit 1
fi
exec "$ubin/gh" "\$@"
EOF
chmod +x "$ubin2/gh"
ustate8=$tmp/ustate8
mkdir -p "$ustate8/node/T13"
: >"$ustate8/status.log"
urun2() { env PATH="$ubin2:$PATH" python3 -I "$src/report.py" --repo owner/repo --state "$1" --worktrees "$tmp/worktrees/repo" --clone "$uclone" --owner owner 2>"$tmp/uerr"; }
urun2 "$ustate8"
ev "started T13 (late-fail) in /wt, pid 1, start 1 of 2" "$ustate8"
: >"$tmp/ucreatefail"
urun2 "$ustate8"; rcl=$?
ok "U01-AC-9: (late failure) the run whose creating POST failed after the issue was made exits non-zero" test "$rcl" != 0
ok "U01-AC-9: (late failure) the issue exists once, the unit has no issue file yet" sh -c "[ \"\$1\" = 1 ] && [ ! -e '$ustate8/node/T13/issue' ]" _ "$(ubuilds 'Build T13 late-fail')"
urun2 "$ustate8"; rcl2=$?
urun2 "$ustate8"
ok "U01-AC-1: (late failure) the next runs succeed" test "$rcl2" = 0
ok "U01-AC-1: (late failure) still exactly one Build issue with that title" test "$(ubuilds 'Build T13 late-fail')" = 1
ok "U01-AC-1: (late failure) the unit's issue file holds that issue's number" test "$(cat "$ustate8/node/T13/issue" 2>/dev/null)" = "$(uq "[i['number'] for i in db['issues'].values() if i['title'] == 'Build T13 late-fail'][0]")"
ok "U01-AC-2: (late failure) its start milestone is on that issue once" test "$(unum "$(cat "$ustate8/node/T13/issue" 2>/dev/null)")" = 1


if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
