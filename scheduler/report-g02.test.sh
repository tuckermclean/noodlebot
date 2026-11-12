#!/bin/sh
# Tests scheduler/report.py: a node-PR update's question, answer and status (G02-AC-3).
#   sh scheduler/report-g02.test.sh   (make test)
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
. "$fakegh_lib/report-sessions.sh"

# G02-AC-3: a node-PR update (state/pr/<N>/ with a `node` file naming the PR's node). Its QUESTION.md is posted once as a
# comment on the node's home issue (node/<ID>/issue), never on an issue of its own; the owner's comment after it there
# becomes pr/<N>/ANSWER.md; running, it is the section "PR #N", FAILED, an item under "Waiting on you".
# Own database, own fake gh, own state, all under $tmp/G02.
g02=$tmp/G02 g02db=$tmp/G02/gh.json
mkdir -p "$g02/bin" "$g02/rs" "$g02/clone" "$g02/worktrees"
pyc "
import json
issues = {str(n): {'number': n, 'title': 'Seeded %d' % n, 'body': '', 'labels': [], 'state': 'open', 'node_id': 'I_%d' % n} for n in range(61, 66)}
json.dump({'issues': issues, 'comments': [], 'labels': [], 'pulls': [], 'checks': {}, 'reactions': [], 'next': 300}, open('$g02db', 'w'))"
cat >"$g02/bin/gh.py" <<EOF
#!/usr/bin/env python3
import json, re, sys
db = json.load(open("$g02db"))
a = sys.argv[1:]
assert a[0] == "api" and a[1] == "-X", a
method, path = a[2], a[3]
body = json.load(sys.stdin) if "--input" in a else None
p = path.split("?")[0]
out = None
if method == "POST" and p.endswith("/labels"):
    if body["name"] in db["labels"]:
        print("HTTP 422: already_exists", file=sys.stderr); sys.exit(1)
    db["labels"].append(body["name"]); out = {}
elif method == "POST" and p.endswith("/issues"):
    n = str(db["next"]); db["next"] += 1
    db["issues"][n] = dict(body, number=int(n), state="open", node_id="I_" + n)
    db["issues"][n].setdefault("labels", []); out = db["issues"][n]
elif method == "GET" and re.search(r"/issues\?labels=", path):
    lab = re.search(r"labels=([^&]+)", path).group(1)
    out = [i for i in db["issues"].values() if i["state"] == "open" and lab in i["labels"]]
elif re.search(r"/issues/\d+$", p):
    n = p.rsplit("/", 1)[1]
    if n not in db["issues"]:
        print("HTTP 404: no issue " + n, file=sys.stderr); sys.exit(1)
    if method == "PATCH": db["issues"][n].update(body)
    out = db["issues"][n]
elif method == "POST" and p.endswith("/comments"):
    n = p.split("/")[-2]
    c = {"id": len(db["comments"]) + 1, "issue": n, "body": body["body"], "user": {"login": "bot", "type": "Bot"},
         "author_association": "NONE", "created_at": "2026-02-01T00:00:00Z", "html_url": "https://x/%s/%d" % (n, len(db["comments"]) + 1)}
    db["comments"].append(c); out = c
elif method == "POST" and p.endswith("/reactions"):
    db["reactions"].append([p, body]); out = {}
elif method == "GET" and "/comments" in p:
    n = p.split("/")[-2]
    out = [c for c in db["comments"] if c["issue"] == n]
elif method == "GET" and re.search(r"/commits/[^/]+/check-runs$", p):
    out = {"check_runs": db["checks"].get(p.split("/")[-2], [])}
elif method == "GET" and p.endswith("/pulls"):
    out = db["pulls"]
elif p == "graphql":
    out = {}
else:
    print("unexpected " + method + " " + path, file=sys.stderr); sys.exit(1)
json.dump(db, open("$g02db", "w"))
print(json.dumps(out))
EOF
fakegh_install "$g02/bin"   # the shared fake-gh server runs gh.py: no interpreter start-up per call
git -C "$g02/clone" init -q -b main && git -C "$g02/clone" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init &&
	git -C "$g02/clone" update-ref refs/remotes/origin/main HEAD
g02_run() { env PATH="$g02/bin:$PATH" python3 -I "$src/report.py" --repo owner/repo --state "$1" --worktrees "$g02/worktrees" --clone "$g02/clone" --owner owner 2>"$g02/err"; }
g02_q() { pyc "import json,sys; db=json.load(open('$g02db')); print(eval(sys.argv[1]))" "$1" 2>/dev/null; }
# g02_count <issue> <text>: the comments on the issue containing the text.
g02_count() { P="$2" pyc "
import json, os
db = json.load(open('$g02db'))
print(len([c for c in db['comments'] if c['issue'] == '$1' and os.environ['P'] in c['body']]))"; }
g02_comment() { # <issue> <body> <created_at> <login> <association> <type> <url>
	pyc "
import json, sys
db = json.load(open('$g02db'))
db['comments'].append({'id': len(db['comments']) + 1, 'issue': sys.argv[1], 'body': sys.argv[2], 'user': {'login': sys.argv[4], 'type': sys.argv[6]},
    'author_association': sys.argv[5], 'created_at': sys.argv[3], 'html_url': sys.argv[7]})
json.dump(db, open('$g02db', 'w'))" "$@"
}
g02_issues() { g02_q "len(db['issues'])"; }

# The question and the answer.
g02s=$g02/state1
mkdir -p "$g02s/node/N01" "$g02s/pr/77"
echo 61 >"$g02s/node/N01/issue"
echo N01 >"$g02s/pr/77/node"
: >"$g02s/status.log"
g02_run "$g02s"
g02_before=$(g02_issues)
printf 'Q1: keep both sides?\ng02-unique-pr-question-line\n' >"$g02s/pr/77/QUESTION.md"
g02_run "$g02s"; g02_rc=$?
g02_run "$g02s"; g02_run "$g02s"
ok "G02-AC-3: the report runs on a state dir with a node-PR update asking a question" test "$g02_rc" = 0 -a ! -s "$g02/err"
ok "G02-AC-3: the update's question is posted on the node's home issue (#61), whole, once over three runs" test "$(g02_count 61 "$(cat "$g02s/pr/77/QUESTION.md")")" = 1
ok "G02-AC-3: the question is not posted on any other issue (the question line is on #61 only)" test "$(g02_q "len([c for c in db['comments'] if 'g02-unique-pr-question-line' in c['body']])")" = 1
ok "G02-AC-3: the update gets no issue of its own (no new issue, no pr/77/issue file)" sh -c "[ \"\$1\" = \"\$2\" ] && [ ! -e '$g02s/pr/77/issue' ]" _ "$(g02_issues)" "$g02_before"
ok "G02-AC-3: and the node's home issue is still #61" test "$(cat "$g02s/node/N01/issue")" = 61
g02_comment 61 "early answer" 2026-01-15T00:00:00Z owner OWNER User https://x/g02-early
g02_comment 61 "stranger answer" 2026-02-02T00:00:00Z mallory NONE User https://x/g02-other
g02_run "$g02s"
ok "G02-AC-3: a comment from before the question, or from someone else, does not become ANSWER.md" test -n "$(cat "$g02s/node/N01/issue")" -a ! -e "$g02s/pr/77/ANSWER.md"
g02_comment 61 "go with both" 2026-02-02T00:00:00Z owner OWNER User https://x/g02-own
g02_run "$g02s"; g02_rc=$?
g02_run "$g02s"; g02_run "$g02s"
ok "G02-AC-3: the owner's comment after the question becomes the update's ANSWER.md (pr/77/ANSWER.md), exit 3" sh -c "[ $g02_rc = 3 ] && grep -q '^go with both\$' '$g02s/pr/77/ANSWER.md'"
ok "G02-AC-3: its ANSWER.md carries the comment's URL" grep -qF 'https://x/g02-own' "$g02s/pr/77/ANSWER.md"
ok "G02-AC-3: the answer is not the node's (no node/N01/ANSWER.md)" test ! -e "$g02s/node/N01/ANSWER.md"
ok "G02-AC-3: the question is still posted once after the answer" test "$(g02_count 61 'g02-unique-pr-question-line')" = 1

# The status issue: a running update is the section PR #N, a FAILED one an item under "Waiting on you".
g02s2=$g02/state2
mkdir -p "$g02s2/node/N02" "$g02s2/pr/78" "$g02s2/pr/79"
# the fake session: a process that must be alive (report.py finds it by its command line) until the test kills it, so its sleep waits for no condition
printf '#!/bin/sh\nwhile :; do sleep 1; done\n' >"$g02/rs/run-session.sh"
sh "$g02/rs/run-session.sh" --update 78 &
g02_pid=$!
echo "$g02_pid" >"$g02s2/pr/78/session.pid"
echo 1 >"$g02s2/pr/78/starts"
echo N02 >"$g02s2/pr/78/node"
echo N02 >"$g02s2/pr/79/node"
printf '2026-01-08T00:00:00Z second exit (rc 1) without finishing\ng02-second-line-detail-79\n' >"$g02s2/pr/79/FAILED"
: >"$g02s2/status.log"
rs_wait "$g02_pid"   # was sleep 1: until the session has exec'd, so that its command line names run-session.sh (the shared helper, at most 10 s)
g02_run "$g02s2"
g02_status=$(g02_q "[i['body'] for i in db['issues'].values() if 'noodlebot-status' in i['labels']][0]")
printf '%s\n' "$g02_status" >"$g02/body"
awk '/^## Waiting on you/ {f=1; next} /^## / {f=0} f' "$g02/body" >"$g02/waiting"
kill "$g02_pid" 2>/dev/null
ok "G02-AC-3: the report runs on node-PR update folders without error" test ! -s "$g02/err"
ok "G02-AC-3: a running node-PR update is shown as PR #78" grep -qE '^### .*PR #78' "$g02/body"
ok "G02-AC-3: it counts as a running session" grep -qF 'Sessions (1 running)' "$g02/body"
ok "G02-AC-3: its section says it is start 1 of 2" sh -c "grep -E '^### .*PR #78' '$g02/body' | grep -qF 'start 1 of 2'"
ok "G02-AC-3: a FAILED node-PR update is under Waiting on you as PR #79" sh -c "grep 'PR #79' '$g02/waiting' | grep -q FAILED"
ok "G02-AC-3: with the first line of its FAILED file" sh -c "grep 'PR #79' '$g02/waiting' | grep -qF 'second exit (rc 1) without finishing'"
ok "G02-AC-3: and the path to delete" sh -c "grep 'PR #79' '$g02/waiting' | grep -qF '$g02s2/pr/79/FAILED'"
ok "G02-AC-3: and not the file's later lines" sh -c "! grep -q g02-second-line-detail-79 '$g02/body'"
ok "G02-AC-3: the running update is not listed as waiting" sh -c "! grep -q 'PR #78' '$g02/waiting'"


if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
