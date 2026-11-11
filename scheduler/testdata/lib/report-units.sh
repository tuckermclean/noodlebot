# Sourced by scheduler/report*.test.sh that run the unit-issue cases: the fake gh of the units' database ($udb), the fixture
# clone ($uclone) with its node specs, and the helpers that read and write them. Needs $src, $tmp, $ubin's directory
# creation and report-fakegh.sh.
# U01-AC-1, U01-AC-2, U01-AC-9: each unit's home issue and its milestones. Own database, own fake gh (it keeps issue
# labels, honours the label query, and fails a call on demand: $tmp/ufail holds a regex matched against
# "METHOD path title-or-first-body-line"), and a fixture clone whose origin/main has node specs with zero, one and two
# issues on their **Resolves:** line.
ubin=$tmp/ubin udb=$tmp/ugh.json uclone=$tmp/uclone
mkdir -p "$ubin" "$uclone/nodes"
pyc "
import json
issues = {str(n): {'number': n, 'title': 'Seeded %d' % n, 'body': '', 'labels': [], 'state': 'open', 'node_id': 'I_%d' % n} for n in range(41, 51)}
json.dump({'issues': issues, 'comments': [], 'labels': [], 'pulls': [], 'checks': {}, 'reactions': [], 'next': 200}, open('$udb', 'w'))"
cat >"$ubin/gh.py" <<EOF
#!/usr/bin/env python3
import json, os, re, sys
db = json.load(open("$udb"))
a = sys.argv[1:]
assert a[0] == "api" and a[1] == "-X", a
method, path = a[2], a[3]
body = json.load(sys.stdin) if "--input" in a else None
p = path.split("?")[0]
open("$tmp/ucalls", "a").write("%s %s\n" % (method, p))
mode = open("$tmp/ufail").read().strip() if os.path.exists("$tmp/ufail") else ""
desc = "%s %s" % (method, p)
if body and "title" in body: desc += " " + body["title"]
elif body and "body" in body: desc += " " + body["body"].split("\n")[0]
if mode and re.search(mode, desc):
    print("HTTP 502: injected failure for " + desc, file=sys.stderr); sys.exit(1)
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
json.dump(db, open("$udb", "w"))
print(json.dumps(out))
EOF
fakegh_install "$ubin"
mkspec() { # <ID> <name> <resolves text or empty>
	{
		printf '# %s - %s\n\n| Track | Deps | Unlocks | Size |\n|---|---|---|---|\n| now | none | none | S |\n\n**Owns:** nothing\n' "$1" "$2"
		if [ -n "$3" ]; then printf '**Resolves:** %s\n' "$3"; fi
		printf '\n## Purpose\nx\n'
	} >"$uclone/nodes/$1-$2.md"
}
mkspec T01 zero-issues ''
mkspec T02 one-issue '#41'
mkspec T03 two-issues '#42, #43'
mkspec T05 zero-again ''
mkspec T06 six-one '#46'
mkspec T07 seven-one '#47'
mkspec T08 eight-one '#48'
mkspec T09 nine-one '#50'
git -C "$uclone" init -q -b main && git -C "$uclone" add nodes &&
	git -C "$uclone" -c user.name=t -c user.email=t@t commit -q -m specs &&
	git -C "$uclone" update-ref refs/remotes/origin/main HEAD
urun() { env PATH="$ubin:$PATH" python3 -I "$src/report.py" --repo owner/repo --state "$1" --worktrees "$tmp/worktrees/repo" --clone "$uclone" --owner owner 2>"$tmp/uerr"; }
uq() { pyc "import json,sys; db=json.load(open('$udb')); print(eval(sys.argv[1]))" "$1" 2>/dev/null; }
# ucount <issue> <regex>: the comments on the issue matching the regex (re.search, no flags; \A is the start of the body).
ucount() { P="$2" pyc "
import json, os, re
db = json.load(open('$udb'))
print(len([c for c in db['comments'] if c['issue'] == '$1' and re.search(os.environ['P'], c['body'])]))"; }
# ucontains <issue> <file>: the comments on the issue holding the file's whole text.
ucontains() { P=$(cat "$2") pyc "
import json, os
db = json.load(open('$udb'))
print(len([c for c in db['comments'] if c['issue'] == '$1' and os.environ['P'].strip() in c['body']]))"; }
unum() { ucount "$1" ''; }
ulast() { uq "[c['body'] for c in db['comments'] if c['issue'] == '$1'][-1]"; }
ufirst() { uq "[c['body'] for c in db['comments'] if c['issue'] == '$1'][0]"; }
ubuilds() { uq "len([i for i in db['issues'].values() if i['title'] == '$1'])"; }
ustage_all() { [ -n "$1" ] && [ "$(unum "$1")" -gt 0 ] && [ "$(unum "$1")" = "$(ucount "$1" '\A\*\*Stage:\*\*')" ]; }
uowner() {
	pyc "
import json, sys
db = json.load(open('$udb'))
db['comments'].append({'id': len(db['comments']) + 1, 'issue': sys.argv[1], 'body': sys.argv[2], 'user': {'login': 'owner', 'type': 'User'},
    'author_association': 'OWNER', 'created_at': '2026-02-02T00:00:00Z', 'html_url': 'https://x/u'})
json.dump(db, open('$udb', 'w'))" "$1" "$2"
}
ev() { echo "2026-02-01T00:00:00Z open=[] merged-prs=[]; $1" >>"$2/status.log"; }
# ubcount <issue> <regex>: the comments by the bot (not the owner or others) on the issue matching the regex.
ubcount() { P="$2" pyc "
import json, os, re
db = json.load(open('$udb'))
print(len([c for c in db['comments'] if c['issue'] == '$1' and c['user']['login'] == 'bot' and re.search(os.environ['P'], c['body'])]))"; }
ubn() { ubcount "$1" ''; }
# ucomment <issue> <body> <created_at> <login> <association> <type> <url>: a comment by anyone.
ucomment() {
	pyc "
import json, sys
db = json.load(open('$udb'))
db['comments'].append({'id': len(db['comments']) + 1, 'issue': sys.argv[1], 'body': sys.argv[2], 'user': {'login': sys.argv[4], 'type': sys.argv[6]},
    'author_association': sys.argv[5], 'created_at': sys.argv[3], 'html_url': sys.argv[7]})
json.dump(db, open('$udb', 'w'))" "$@"
}
# ureact <url>: the +1 reactions on the comment with that URL.
ureact() { uq "len([r for r in db['reactions'] if r[0].endswith('/issues/comments/%d/reactions' % [c['id'] for c in db['comments'] if c['html_url'] == '$1'][0]) and r[1].get('content') == '+1'])"; }
uowned() { # <issue> <body> <url>: the owner's comment, after every question
	ucomment "$1" "$2" 2026-02-02T00:00:00Z owner OWNER User "$3"
}
# usetpulls <json list>: the open PRs the fake lists. usetchecks <sha> <json list>: the check runs of that head commit.
usetpulls() { pyc "
import json, sys
db = json.load(open('$udb')); db['pulls'] = json.loads(sys.argv[1]); json.dump(db, open('$udb', 'w'))" "$1"; }
usetchecks() { pyc "
import json, sys
db = json.load(open('$udb')); db['checks'][sys.argv[1]] = json.loads(sys.argv[2]); json.dump(db, open('$udb', 'w'))" "$1" "$2"; }
upull() { # <number> <branch> <sha>: one open PR as JSON
	printf '{"number": %s, "html_url": "https://github.com/owner/repo/pull/%s", "state": "open", "head": {"ref": "%s", "sha": "%s"}}' "$1" "$1" "$2" "$3"
}
ustateof() { uq "db['issues']['$1']['state']"; }
# umatch <regex> <text>: re.search (flags inline) of the text; used on the last comment of an issue.
umatch() { P="$1" pyc "
import os, re, sys
sys.exit(0 if re.search(os.environ['P'], sys.argv[1]) else 1)" "$2"; }
ur3() { urun "$ustate5"; urun "$ustate5"; urun "$ustate5"; }
# upatches <issue>: the PATCH calls on the issue since $tmp/ucalls was last emptied.
upatches() { grep -c "^PATCH repos/owner/repo/issues/$1\$" "$tmp/ucalls" || true; }
# ustatus_init: for a part that starts from the fixture: one run on an empty state folder makes the status issue; ustatus is its number.
ustatus_init() {
	mkdir -p "$tmp/ustate0"
	: >"$tmp/ustate0/status.log"
	urun "$tmp/ustate0"
	ustatus=$(uq "[i['number'] for i in db['issues'].values() if 'noodlebot-status' in i['labels']][0]"); ustatus=${ustatus:-200}
}
