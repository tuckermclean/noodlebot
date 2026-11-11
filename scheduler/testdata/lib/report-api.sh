# Sourced by scheduler/report*.test.sh: the first fake `gh api` (issues and comments in $db, number 100 for the status
# issue), the state folder and the helpers that run report.py against it. Needs $src, $tmp and report-fakegh.sh.
state=$tmp/state/repo db=$tmp/gh.json
mkdir -p "$state/node/A01" "$state/node/A02" "$tmp/bin" "$tmp/worktrees/repo"
echo '{"issues": {}, "comments": [], "labels": [], "pulls": [{"number": 7, "head": {"ref": "node/A01-first"}}]}' >"$db"
cat >"$tmp/bin/gh.py" <<EOF
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
    lab = re.search(r"labels=([^&]+)", path).group(1)
    out = [i for i in db["issues"].values() if i["state"] == "open" and lab in [l if isinstance(l, str) else l.get("name") for l in i.get("labels", [])]]
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
fakegh_install "$tmp/bin"
export PATH=$tmp/bin:$PATH
run() { python3 -I "$src/report.py" --repo owner/repo --state "$state" --worktrees "$tmp/worktrees/repo" 2>"$tmp/err"; }
q() { pyc "import json,sys; db=json.load(open('$db')); print(eval(sys.argv[1]))" "$1"; }
