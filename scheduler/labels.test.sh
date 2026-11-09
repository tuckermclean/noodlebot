#!/bin/sh
# Tests scheduler/labels.py ensure against a fake `gh api` serving a repository's labels (paged)
# and recording every call.
#   sh scheduler/labels.test.sh   (make test)
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
ok() { name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }

mkdir -p "$tmp/bin"
# The fake gh: $tmp/labels.json is the repository's labels, $tmp/mode is "", "fail" (every call
# fails), "failpost" (creating fails with a server error) or "reject" (every create answers 422
# already_exists). Every call is appended to $tmp/calls.jsonl as {"method", "path", "body"}.
cat >"$tmp/bin/gh" <<EOF
#!/usr/bin/env python3
import json, os, sys
from urllib.parse import urlparse, parse_qs
tmp = "$tmp"
args = sys.argv[1:]
assert args and args[0] == "api", args
method, path, fields, use_input, paginate, slurp = None, None, {}, False, False, False
i = 1
while i < len(args):
    a = args[i]
    if a in ("-X", "--method"):
        method = args[i + 1]; i += 1
    elif a in ("-f", "-F", "--field", "--raw-field"):
        k, _, v = args[i + 1].partition("="); fields[k] = v; i += 1
    elif a == "--input":
        use_input = True; i += 1
    elif a == "--paginate":
        paginate = True
    elif a == "--slurp":
        slurp = True
    elif a in ("-H", "--header", "-q", "--jq", "--cache"):
        i += 1
    elif not a.startswith("-"):
        path = a
    i += 1
body = json.load(sys.stdin) if use_input else (fields or None)
if method is None:
    method = "POST" if body is not None else "GET"
u = urlparse(path)
q = parse_qs(u.query)
for k, v in fields.items():
    if method == "GET": q[k] = [v]
with open(tmp + "/calls.jsonl", "a") as f:
    f.write(json.dumps({"method": method, "path": u.path, "body": body}) + "\n")
mode = open(tmp + "/mode").read().strip() if os.path.exists(tmp + "/mode") else ""
if mode == "fail":
    print("gh: fake-gh-boom (HTTP 500)", file=sys.stderr); sys.exit(1)
labels = json.load(open(tmp + "/labels.json"))
if method == "GET" and u.path.endswith("/labels"):
    per = min(int(q.get("per_page", ["30"])[0]), 100)
    if paginate:
        pages = [labels[j:j + per] for j in range(0, max(len(labels), 1), per)]
        print(json.dumps(pages) if slurp else "".join(json.dumps(p) for p in pages))
    else:
        page = int(q.get("page", ["1"])[0])
        print(json.dumps(labels[(page - 1) * per:page * per]))
    sys.exit(0)
if method == "POST" and u.path.endswith("/labels"):
    if mode == "failpost":
        print("gh: fake-gh-boom (HTTP 500)", file=sys.stderr); sys.exit(1)
    if mode == "invalid":
        print(json.dumps({"message": "Validation Failed", "errors": [{"resource": "Label", "code": "invalid", "field": "color"}]}))
        print("gh: Validation Failed (HTTP 422)", file=sys.stderr); sys.exit(1)
    if mode == "reject" or body["name"] in [l["name"] for l in labels]:
        print(json.dumps({"message": "Validation Failed", "errors": [{"resource": "Label", "code": "already_exists", "field": "name"}]}))
        print("gh: Validation Failed (HTTP 422)", file=sys.stderr); sys.exit(1)
    labels.append({"name": body["name"], "color": body.get("color")})
    json.dump(labels, open(tmp + "/labels.json", "w"))
    print(json.dumps({"name": body["name"]})); sys.exit(0)
print("gh: fake-gh: unexpected call " + method + " " + str(path), file=sys.stderr); sys.exit(1)
EOF
chmod +x "$tmp/bin/gh"
# Helper over the recorded calls.
cat >"$tmp/h.py" <<'EOF'
import json, re, sys
calls = [json.loads(l) for l in open(sys.argv[2]) if l.strip()]
posts = [c for c in calls if c["method"] == "POST" and c["path"] == "repos/o/proj/labels"]
cmd = sys.argv[1]
if cmd == "writes":
    print(len([c for c in calls if c["method"] != "GET"]))
elif cmd == "calls":
    print(len(calls))
elif cmd == "created":
    print(" ".join(sorted((c["body"] or {}).get("name", "?") for c in posts)))
elif cmd == "complete":
    ok = bool(posts) and all(re.fullmatch(r"[0-9a-fA-F]{6}", str((c["body"] or {}).get("color", ""))) and
                             str((c["body"] or {}).get("description", "")).strip() for c in posts)
    sys.exit(0 if ok else 1)
EOF
h() { python3 "$tmp/h.py" "$1" "$tmp/calls.jsonl" 2>/dev/null; }

ALL="noodlebot noodlebot-triaged noodlebot-status"
# setup <mode> <names...>: the repository has these labels (any colour, any description), the fake's mode.
setup() {
	mode=$1; shift
	: >"$tmp/calls.jsonl"; echo "$mode" >"$tmp/mode"
	python3 - "$tmp/labels.json" "$@" <<'EOF'
import json, sys
json.dump([{"name": n, "color": "000000", "description": "mine"} for n in sys.argv[2:]], open(sys.argv[1], "w"))
EOF
}
# ensure: run labels.py ensure; rc, stdout and stderr in $rc, $tmp/out, $tmp/err.
ensure() {
	PATH=$tmp/bin:$PATH GH_TOKEN=fake-token python3 "$src/labels.py" ensure --repo o/proj >"$tmp/out" 2>"$tmp/err"; rc=$?
}

# AC-1: none of the three labels.
setup "" other bug
ensure
ok "L01-AC-1: ensure exits 0 on a repository without the labels" test "$rc" = 0
ok "L01-AC-1: it creates noodlebot, noodlebot-triaged and noodlebot-status" test "$(h created)" = "noodlebot noodlebot-status noodlebot-triaged"
ok "L01-AC-1: each is created with a colour and a non-empty description" h complete
ok "L01-AC-1: and nothing is changed or deleted" test "$(h writes)" = 3

# AC-2: all three present, with a colour and description of their own.
setup "" bug noodlebot noodlebot-triaged noodlebot-status
ensure
ok "L01-AC-2: all three present: exit 0" test "$rc" = 0
ok "L01-AC-2: all three present: it read the labels (a fake gh was called)" test "$(h calls)" -ge 1
ok "L01-AC-2: all three present: no POST, PATCH or DELETE" test "$(h writes)" = 0 -a "$(h calls)" -ge 1

# AC-2: some present: only the missing ones.
setup "" noodlebot-triaged bug
ensure
ok "L01-AC-2: some present: exit 0" test "$rc" = 0
ok "L01-AC-2: some present: only the missing ones are created" test "$(h created)" = "noodlebot noodlebot-status"
ok "L01-AC-2: some present: the new ones have colour and description" h complete
ok "L01-AC-2: some present: no other write" test "$(h writes)" = 2

# AC-2: every page of labels is read (100 per page at most; the third label is the 101st).
setup "" $(seq -f 'filler-%g' 1 98) noodlebot noodlebot-triaged noodlebot-status
ensure
ok "L01-AC-2: labels on a later page: exit 0" test "$rc" = 0
ok "L01-AC-2: a label only on a second page counts as present: no write" test "$(h writes)" = 0 -a "$(h calls)" -ge 1
setup "" noodlebot noodlebot-triaged $(seq -f 'filler-%g' 1 130)
ensure
ok "L01-AC-2: two labels on page 1, one missing from 132 labels: exit 0" test "$rc" = 0
ok "L01-AC-2: and only the missing one is created" test "$(h created)" = noodlebot-status

# AC-3: gh fails.
setup fail
ensure
ok "L01-AC-3: gh failing: exit non-zero" test "$rc" != 0 -a "$(h calls)" -ge 1
ok "L01-AC-3: gh failing: the error is on stderr" grep -q fake-gh-boom "$tmp/err"
setup failpost bug
ensure
ok "L01-AC-3: a create that fails for another reason: exit non-zero" test "$rc" != 0 -a "$(h calls)" -ge 2
ok "L01-AC-3: a create that fails for another reason: the error is on stderr" grep -q fake-gh-boom "$tmp/err"

# AC-3: a create rejected because the label already exists (created meanwhile).
setup reject bug
ensure
ok "L01-AC-3: a create rejected as already existing is not a failure (exit 0)" test "$rc" = 0 -a "$(h created)" = "noodlebot noodlebot-status noodlebot-triaged"

# AC-3: a 422 that is not "already exists" (code invalid) is a failure.
setup invalid bug
ensure
ok "L01-AC-3: a 422 with code invalid: exit non-zero" test "$rc" != 0 -a "$(h calls)" -ge 2
ok "L01-AC-3: a 422 with code invalid: the error is on stderr" test -s "$tmp/err"
ok "L01-AC-3: a 422 with code invalid: no label is reported created" test -z "$(grep 'created label' "$tmp/out")"

# AC-3 / Change 1: a create rejected as already existing is not reported as created.
setup reject bug
ensure
ok "L01-AC-3: rejected as already existing: no 'created label' line is printed" test -z "$(grep 'created label' "$tmp/out")"

# AC-3: a failing create is a failure whatever the repository is called ("422" in its name).
setup failpost bug
PATH=$tmp/bin:$PATH GH_TOKEN=fake-token python3 "$src/labels.py" ensure --repo o/app422 >"$tmp/out" 2>"$tmp/err"; rc=$?
ok "L01-AC-3: a failing create on a repository named app422: exit non-zero" test "$rc" != 0 -a "$(h calls)" -ge 2
ok "L01-AC-3: a failing create on a repository named app422: the error is on stderr" grep -q fake-gh-boom "$tmp/err"

# AC-2: label names are case-insensitive on GitHub: differently-cased existing labels count as present.
setup "" Noodlebot NOODLEBOT-TRIAGED Noodlebot-Status
ensure
ok "L01-AC-2: differently-cased existing labels: exit 0" test "$rc" = 0
ok "L01-AC-2: differently-cased existing labels: no POST, PATCH or DELETE" test "$(h writes)" = 0 -a "$(h calls)" -ge 1

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: all labels checks"
