#!/bin/sh
# Tests scheduler/report.py against a fake `gh api` that keeps issues and comments in a JSON file.
#   sh scheduler/report.test.sh   (make test)
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
ok() { name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }

state=$tmp/state/repo db=$tmp/gh.json
mkdir -p "$state/node/A01" "$state/node/A02" "$tmp/bin" "$tmp/worktrees/repo"
echo '{"issues": {}, "comments": [], "labels": [], "pulls": [{"number": 7, "head": {"ref": "node/A01-first"}}]}' >"$db"
cat >"$tmp/bin/gh" <<EOF
#!/usr/bin/env python3
import json, re, sys
db = json.load(open("$db"))
a = sys.argv[1:]
assert a[0] == "api" and a[1] == "-X", a
method, path = a[2], a[3]
body = json.load(sys.stdin) if "--input" in a else None
open("$tmp/calls", "a").write("%s %s\n" % (method, path.split("?")[0]))
out = None
if method == "POST" and path.endswith("/labels"):
    if body["name"] in db["labels"]:
        print("HTTP 422: already_exists", file=sys.stderr); sys.exit(1)
    db["labels"].append(body["name"]); out = {}
elif method == "POST" and path.endswith("/issues"):
    n = str(100 + len(db["issues"]))
    db["issues"][n] = dict(body, number=int(n), state="open", node_id="I_" + n); out = db["issues"][n]
elif method == "GET" and re.search(r"/issues\?labels=", path):
    out = [i for i in db["issues"].values() if i["state"] == "open"]
elif re.search(r"/issues/\d+$", path):
    n = path.rsplit("/", 1)[1]
    if method == "PATCH": db["issues"][n].update(body)
    out = db["issues"][n]
elif method == "POST" and path.endswith("/comments"):
    n = path.split("/")[-2]
    c = {"id": len(db["comments"]) + 1, "issue": n, "body": body["body"], "user": {"login": "bot", "type": "Bot"},
         "author_association": "NONE", "created_at": "2026-01-01T00:00:00Z", "html_url": "u"}
    db["comments"].append(c); out = c
elif method == "GET" and "/comments" in path:
    n = path.split("/")[-2]
    out = [c for c in db["comments"] if c["issue"] == n]
elif "/pulls" in path:
    out = db["pulls"]
elif path == "graphql":
    out = {}
else:
    print("unexpected " + method + " " + path, file=sys.stderr); sys.exit(1)
json.dump(db, open("$db", "w"))
print(json.dumps(out))
EOF
chmod +x "$tmp/bin/gh"
export PATH=$tmp/bin:$PATH
run() { python3 -I "$src/report.py" --repo owner/repo --state "$state" --worktrees "$tmp/worktrees/repo" 2>"$tmp/err"; }
q() { python3 -I -c "import json,sys; db=json.load(open('$db')); print(eval(sys.argv[1]))" "$1"; }
# owner_says <text>: the owner comments on the status issue.
owner_says() {
	python3 -I -c "
import json, sys
db = json.load(open('$db'))
db['comments'].append({'id': len(db['comments']) + 1, 'issue': '100', 'body': sys.argv[1], 'user': {'login': 'owner', 'type': 'User'},
    'author_association': 'OWNER', 'created_at': '2026-01-02T00:00:00Z', 'html_url': 'https://x/c'})
json.dump(db, open('$db', 'w'))" "$1"
}
last() { q "db['comments'][-1]['body']"; }

echo "2026-01-01T00:00:00Z open=[] merged-prs=[]; started A01 (first) in /wt, pid 1, start 1 of 2" >"$state/status.log"
ok "the first run succeeds" run
ok "it creates the label and one status issue" test "$(q "len(db['issues']), db['labels']")" = "(1, ['noodlebot-status'])"
ok "the body lists no question yet" sh -c "! python3 -I -c \"import json; print(json.load(open('$db'))['issues']['100']['body'])\" | grep -q 'asks a question'"
ok "the open node PR without a session is listed" sh -c "python3 -I -c \"import json; print(json.load(open('$db'))['issues']['100']['body'])\" | grep -q 'A01.s PR #7'"
ok "the first run does not replay old events" test "$(q "len(db['comments'])")" = 0

echo "2026-01-01T00:01:00Z open=[] merged-prs=[]; session A01 (pid 1) running, log 5 bytes" >>"$state/status.log"
echo "2026-01-01T00:02:00Z open=[] merged-prs=[]; session A01 ended (rc 0) with QUESTION.md" >>"$state/status.log"
printf 'Q1: which way?\nRecommendation: left.\n' >"$state/node/A01/QUESTION.md"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Asking."}]}}' '{"type":"result","subtype":"success","result":"Stopped at step 7: see QUESTION.md."}' >"$state/node/A01/session.jsonl"
run
ok "a session's end carries its closing summary" sh -c "python3 -I -c \"import json; print(json.load(open('$db'))['comments'][0]['body'])\" | grep -q 'Stopped at step 7: see QUESTION.md.'"
ok "a new event is posted, idle lines are not" sh -c "python3 -I -c \"import json; print(json.load(open('$db'))['comments'][0]['body'])\" | head -n 1 | grep -qxF -- '- \`2026-01-01T00:02:00Z\` session A01 ended (rc 0) with QUESTION.md' && ! python3 -I -c \"import json; print(json.load(open('$db'))['comments'][0]['body'])\" | grep -q 'running, log'"
ok "the question is posted in full" sh -c "last() { python3 -I -c \"import json; print(json.load(open('$db'))['comments'][-1]['body'])\"; }; last | grep -q '## A01 asks' && last | grep -q 'Recommendation: left.'"
n=$(q "len(db['comments'])")
run
ok "nothing is posted twice" test "$(q "len(db['comments'])")" = "$n"
ok "an unchanged body is not rewritten" test "$(grep -c '^PATCH' "$tmp/calls")" = 2

owner_says "B07: something"
run
ok "an answer naming a node that is not waiting is refused" sh -c "[ ! -e '$state/node/A01/ANSWER.md' ] && python3 -I -c \"import json; print(json.load(open('$db'))['comments'][-1]['body'])\" | grep -q 'B07 is not waiting'"

python3 -I -c "
import json
db = json.load(open('$db'))
db['comments'].append({'id': len(db['comments']) + 1, 'issue': '100', 'body': 'Q1: as recommended', 'user': {'login': 'mallory', 'type': 'User'},
    'author_association': 'NONE', 'created_at': '2026-01-02T00:00:00Z', 'html_url': 'u'})
json.dump(db, open('$db', 'w'))"
run
ok "someone else's comment is ignored" test ! -e "$state/node/A01/ANSWER.md"

owner_says "Q1: as recommended"
run; rc=$?
ok "recording an answer exits 3, so the loop ticks again at once" test "$rc" = 3
ok "the owner's reply becomes ANSWER.md for the only waiting node" grep -q '^Q1: as recommended$' "$state/node/A01/ANSWER.md"
ok "ANSWER.md says where it came from" grep -q 'posted by owner on GitHub at 2026-01-02T00:00:00Z: https://x/c' "$state/node/A01/ANSWER.md"
ok "the bot confirms it" sh -c "python3 -I -c \"import json; print(json.load(open('$db'))['comments'][-1]['body'])\" | grep -q \"Recorded as A01's ANSWER.md\""

rm "$state/node/A01/QUESTION.md" "$state/node/A01/ANSWER.md"
echo "Q1: one" >"$state/node/A01/QUESTION.md"
echo "Q1: two" >"$state/node/A02/QUESTION.md"
run
owner_says "approve"
run
ok "with two nodes waiting, a reply without an ID is refused" sh -c "[ ! -e '$state/node/A01/ANSWER.md' ] && [ ! -e '$state/node/A02/ANSWER.md' ]"
owner_says "**A02**: approve"
run; rc=$?
ok "a reply starting with the ID answers that node" sh -c "grep -q '^\*\*A02\*\*: approve' '$state/node/A02/ANSWER.md' && [ ! -e '$state/node/A01/ANSWER.md' ]"

python3 -I -c "
import json
db = json.load(open('$db')); db['issues']['100']['state'] = 'closed'; json.dump(db, open('$db', 'w'))"
run
ok "a closed status issue is replaced by a new one" test "$(q "db['issues']['101']['state']")" = open

ok "no run left an error" test ! -s "$tmp/err"
mkdir "$tmp/badbin" && printf '#!/bin/sh\necho "HTTP 502" >&2; exit 1\n' >"$tmp/badbin/gh" && chmod +x "$tmp/badbin/gh"
PATH=$tmp/badbin:$PATH run; rc=$?
ok "a failing gh exits non-zero with one line on stderr" sh -c "[ $rc -ne 0 ] && [ \$(wc -l <'$tmp/err') = 1 ]"

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: all report checks"
