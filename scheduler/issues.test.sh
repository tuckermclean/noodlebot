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

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: all issues checks"
