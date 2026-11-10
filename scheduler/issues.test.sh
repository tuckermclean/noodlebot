#!/bin/sh
# Tests scheduler/issues.py against a fake `gh api` serving issues, their label events and labels.
#   sh scheduler/issues.test.sh   (make test)
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
ok() { name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }

state=$tmp/state
mkdir -p "$state" "$tmp/bin"
# Issues 10 (labelled by mallory), 11 (by the owner), 12 (by the owner), 13 (a pull request).
cat >"$tmp/db.json" <<'EOF'
{"issues": [{"number": 10}, {"number": 11}, {"number": 12}, {"number": 13, "pull_request": {}}],
 "events": {"10": [{"event": "labeled", "label": {"name": "noodlebot"}, "actor": {"login": "mallory"}}],
            "11": [{"event": "labeled", "label": {"name": "bug"}, "actor": {"login": "owner"}},
                   {"event": "labeled", "label": {"name": "noodlebot"}, "actor": {"login": "owner"}}],
            "12": [{"event": "labeled", "label": {"name": "noodlebot"}, "actor": {"login": "owner"}}],
            "13": [{"event": "labeled", "label": {"name": "noodlebot"}, "actor": {"login": "owner"}}]},
 "labels": [], "calls": []}
EOF
cat >"$tmp/bin/gh" <<EOF
#!/usr/bin/env python3
import json, re, sys
db = json.load(open("$tmp/db.json"))
method, path = sys.argv[3], sys.argv[4]
body = json.load(sys.stdin) if "--input" in sys.argv else None
db["calls"].append("%s %s" % (method, path.split("?")[0]))
out = None
if method == "GET" and "/issues?labels=noodlebot" in path:
    out = db["issues"]
elif method == "GET" and re.search(r"/issues/\d+/events", path):
    out = db["events"][path.split("/")[-2]]
elif method == "POST" and path.endswith("/labels") and "/issues/" not in path:
    if body["name"] in db["labels"]:
        json.dump(db, open("$tmp/db.json", "w")); print("HTTP 422: already_exists", file=sys.stderr); sys.exit(1)
    db["labels"].append(body["name"]); out = {}
elif method in ("POST", "DELETE") and re.search(r"/issues/\d+/labels", path):
    out = []
else:
    print("unexpected", method, path, file=sys.stderr); sys.exit(1)
json.dump(db, open("$tmp/db.json", "w"))
print(json.dumps(out))
EOF
chmod +x "$tmp/bin/gh"
export PATH=$tmp/bin:$PATH
next() { python3 -I "$src/issues.py" next --repo owner/repo --state "$state"; }

ok "the first issue the owner labelled is next, not one someone else labelled" test "$(next)" = 11
mkdir -p "$state/issue/11" && echo "Q1?" >"$state/issue/11/QUESTION.md"
ok "an issue waiting on the owner's answer is skipped" test "$(next)" = 12
echo "Q1: yes" >"$state/issue/11/ANSWER.md"
ok "once answered it is next again" test "$(next)" = 11
mkdir -p "$state/issue/12" && touch "$state/issue/11/FAILED" "$state/issue/12/FAILED"
ok "FAILED issues are skipped, and a pull request never counts" test -z "$(next)"

python3 -I "$src/issues.py" done --repo owner/repo --number 11
ok "done creates the triaged label, adds it and removes noodlebot" sh -c "python3 -I -c \"import json; print('\\n'.join(json.load(open('$tmp/db.json'))['calls'][-3:]))\" | tr '\n' ',' | grep -qx 'POST repos/owner/repo/labels,POST repos/owner/repo/issues/11/labels,DELETE repos/owner/repo/issues/11/labels/noodlebot,'"
ok "a second done does not fail on the existing label" python3 -I "$src/issues.py" done --repo owner/repo --number 12

# --- P01-AC-6: `next` also writes $state/issues.json, a cache of the open issues it read (for the API) ---
# Format: {"updated": <epoch int>, "issues": [{"number": N, "title": "<title>", "labelled": <true when the owner labelled it>}...]}
# for every non-PR issue gh listed (10 by mallory is labelled false), written to a temporary file and renamed, so no other
# file is left in the state folder. A failure to write it goes to stderr and changes neither stdout nor the exit status.
python3 -I -c "
import json
db = json.load(open('$tmp/db.json'))
for i, t in zip(db['issues'], ['Stranger idea', 'Fix the bug', 'Add the feature', 'A pull request']): i['title'] = t
json.dump(db, open('$tmp/db.json', 'w'))"
state2=$tmp/state2; mkdir -p "$state2"
next2() { python3 -I "$src/issues.py" next --repo owner/repo --state "$1" 2>"$tmp/next.err"; }
out2=$(next2 "$state2"); rc2=$?
ok "P01-AC-6: next with a cache to write still prints the first issue the owner labelled" test "$out2" = 11 -a "$rc2" = 0
ok "P01-AC-6: next writes \$state/issues.json with each non-PR open issue: number, title, labelled" python3 -I -c "
import json, sys
d = json.load(open('$state2/issues.json'))
sys.exit(0 if isinstance(d.get('updated'), int) and [(i['number'], i['title'], i['labelled']) for i in d['issues']] == [(10, 'Stranger idea', False), (11, 'Fix the bug', True), (12, 'Add the feature', True)] else 1)"  2>/dev/null
ok "P01-AC-6: issues.json is written by rename (no other file is left in the state folder)" test "$(ls -A "$state2")" = issues.json
ok "P01-AC-6: next logs nothing on stderr when it can write the cache" test ! -s "$tmp/next.err"
mkdir -p "$tmp/state3/issues.json/keep"   # a non-empty folder where the file goes: the rename fails
out3=$(next2 "$tmp/state3"); rc3=$?
ok "P01-AC-6: a failure to write issues.json does not change what next prints or its exit status" test "$out3" = 11 -a "$rc3" = 0
ok "P01-AC-6: a failure to write issues.json is logged on stderr" grep -q 'issues.json' "$tmp/next.err"
ok "P01-AC-6: a failed write leaves the state folder holding only what it held" test "$(ls -A "$tmp/state3")" = issues.json -a "$(ls -A "$tmp/state3/issues.json")" = keep

# --- P01-AC-6: a gh failure on the events of an issue that is held (FAILED) must not stop `next` from printing the eligible one ---
# Issue 20 is listed first and failed (its events call fails); issue 21 is eligible. A held issue is skipped without asking gh about it.
python3 -I -c "
import json
db = json.load(open('$tmp/db.json'))
db['issues'] = [{'number': 20, 'title': 'Held'}, {'number': 21, 'title': 'Eligible'}]
db['events'] = {'20': [], '21': [{'event': 'labeled', 'label': {'name': 'noodlebot'}, 'actor': {'login': 'owner'}}]}
json.dump(db, open('$tmp/db.json', 'w'))"
mkdir -p "$tmp/bin2" "$tmp/state4/issue/20"; touch "$tmp/state4/issue/20/FAILED"
cat >"$tmp/bin2/gh" <<EOF
#!/bin/sh
case "\$4" in */issues/20/events*) echo "HTTP 502: bad gateway" >&2; exit 1 ;; esac
exec "$tmp/bin/gh" "\$@"
EOF
chmod +x "$tmp/bin2/gh"
out4=$(PATH=$tmp/bin2:$PATH python3 -I "$src/issues.py" next --repo owner/repo --state "$tmp/state4" 2>"$tmp/next4.err"); rc4=$?
ok "P01-AC-6: with gh failing on the events of a held issue listed first, next still prints the eligible one" test "$out4" = 21
ok "P01-AC-6: ... and exits 0" test "$rc4" = 0

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: all issues checks"
