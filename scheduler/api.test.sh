#!/bin/sh
# Tests scheduler/api.py, the read-only HTTP API on $NOODLEBOT_DATA/api.sock (node P01).
#   sh scheduler/api.test.sh   (make test)
# Slice S1 (P01-AC-1, -2, -3, -8): the server, the repositories, the schemas. Later slices only append cases.
#
# THE CONTRACT THIS TEST FIXES (the implementer follows it)
#  Environment overrides read by api.py (defaults as the spec says; the test sets small values):
#    NOODLEBOT_API_HEAD_CHECK   seconds between checks of the checkout's HEAD (default 60); the test uses 2
#    NOODLEBOT_API_KEEPALIVE    seconds between the event stream's comment lines (default 15); the test uses 1
#  The checkout is the one api.py sits in (scheduler/api.py -> its parent's parent). Runtime root:
#  $NOODLEBOT_DATA (absolute), repository list: $HOME/.config/noodlebot/repos, STOP files: $HOME/STOP{,-<name>}.
#  Every JSON response is an object with "version": 1. Times are integer epoch seconds. Errors are
#  {"version": 1, "error": "<text>"}. Lists are wrapped in a named key. Schemas are served verbatim
#  (the file's bytes' JSON) at /v1/schema/<resource>; they live in scheduler/api-schema/v1/<resource>.json,
#  must declare "version" in properties and required, and use only type, properties, required, items, enum,
#  additionalProperties (and const) for validation.
#  Resource "repos"  GET /v1/repos  ->  {"version":1, "repos":[<repo>...]}, in the order of the list, each once.
#  Resource "repo"   GET /v1/repos/<owner>/<name>  ->  {"version":1, <repo fields flat>}; an unlisted repo is 404.
#  <repo> fields: "repo" (owner/name), "running" (bool: loop.lock held, read from /proc/locks), "stop" (bool:
#    ~/STOP-<name> exists), "stop_all" (bool: ~/STOP exists), "heartbeat" (epoch or null), "heartbeat_age"
#    (seconds since it, int, or null), "status_issue" (int or null, report.json "issue").
#  Later slices' names (documented here so they are chosen once): "started" is a session's start (session.pid's
#    mtime, epoch), "alive" a bool, "pid" an int, "kind" is "node", "triage" or "update".
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
fix=$src/testdata/api
schemas=$src/api-schema/v1
tmp=$(mktemp -d)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
pids=''
cleanup() {
	for p in $pids $srv_pid; do kill -9 "$p" 2>/dev/null; done
	for p in $pids $srv_pid; do wait "$p" 2>/dev/null; done
	rm -rf "$tmp"
}
srv_pid=''
trap cleanup EXIT
trap 'exit 1' INT TERM

data=$tmp/data home=$tmp/home co=$tmp/co sock=$data/api.sock
mkdir -p "$data" "$home" "$co" "$tmp/bin" "$tmp/procs"
cp -R "$fix/data/." "$data/"
cp -R "$fix/home/." "$home/"
cp "$fix/usage-holding.json" "$tmp/usage-holding.json"
cp "$data/state/usage.json" "$tmp/usage-open.json"

# A fake gh that records any call (the API must make none), and a copy of the checkout in a git repository.
printf '#!/bin/sh\necho "$0 $*" >>"%s/gh.log"\nexit 1\n' "$tmp" >"$tmp/bin/gh"
chmod +x "$tmp/bin/gh"
mkdir -p "$co/scheduler"
for f in "$src"/*; do case $f in "$src/testdata") ;; *) cp -R "$f" "$co/scheduler/" ;; esac; done
git -C "$co" init -q 2>/dev/null
git -C "$co" add -A >/dev/null 2>&1
git -C "$co" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m fixture >/dev/null 2>&1

# Live things are processes started now: sessions whose command line is what loop.sh's alive() matches,
# and a process holding alpha's loop.lock. Ended sessions get the pid of a process that exited.
cat >"$tmp/procs/run-session.sh" <<'EOS'
#!/bin/sh
while :; do sleep 1; done
EOS
live() { # live <state dir> <worktree> <prompt words...>: session.pid of a running session
	d=$1 wt=$2; shift 2
	sh "$tmp/procs/run-session.sh" "$wt" "$d" "$@" </dev/null >/dev/null 2>&1 &
	pids="$pids $!"; echo $! >"$d/session.pid"
}
ended() { sh -c 'exit 0' & p=$!; wait "$p"; echo "$p" >"$1/session.pid"; }
a=$data/state/alpha
live "$a/node/N03" /w/alpha/N03 /noodlebot:node N03
live "$a/node/N04" /w/alpha/N04 /noodlebot:node N04
live "$a/issue/9" /w/alpha/issue-9 /noodlebot:triage 9
live "$a/pr/15" /w/alpha/pr-15 /noodlebot:triage --update 15
ended "$a/node/N01"; ended "$a/node/N11"; ended "$a/issue/8"
for s in node/N03 node/N04 node/N01 node/N11 issue/9 issue/8 pr/15; do
	touch -d 2026-11-09T09:01:00Z "$a/$s/session.pid"   # the session's start time
done
: >"$a/loop.lock"; : >"$data/state/beta/loop.lock"
flock "$a/loop.lock" sh -c 'while :; do sleep 1; done' </dev/null >/dev/null 2>&1 &
pids="$pids $!"
ino=$(stat -c %i "$a/loop.lock")
i=0; while [ $i -lt 50 ] && ! grep -q ":$ino " /proc/locks; do sleep 0.1; i=$((i + 1)); done
now=$(date +%s)
echo $((now - 30)) >"$a/heartbeat"
echo $((now - 3600)) >"$data/state/beta/heartbeat"

# --- the machinery later slices use ---
export NOODLEBOT_DATA=$data HOME=$home NOODLEBOT_API_HEAD_CHECK=2 NOODLEBOT_API_KEEPALIVE=1
PATH=$tmp/bin:$PATH; export PATH

# snapshot: every file and directory under the runtime root and HOME with size, mtime and checksum,
# except the socket and the locks. Taken after the fixture is set up; compared at the end (P01-AC-2).
snap() {
	find "$data" "$home" ! -type s ! -name api.sock ! -name api.lock ! -name loop.lock \
		-exec sh -c 'for f; do if [ -d "$f" ]; then echo "d $f"; else echo "f $f $(stat -c "%s %Y" "$f") $(cksum <"$f")"; fi; done' sh {} + | sort
}
snap >"$tmp/snap.before"
# set_usage open|holding: swap usage.json (the test, not the server, changes it) and re-take the baseline.
set_usage() { cp "$tmp/usage-$1.json" "$data/state/usage.json"; snap >"$tmp/snap.before"; }

# req <METHOD> <path>: sets $code, writes the body to $tmp/resp and the headers to $tmp/hdr.
if command -v curl >/dev/null 2>&1; then
	req() { : >"$tmp/resp"; code=$(curl -s --max-time 10 --unix-socket "$sock" -X "$1" -o "$tmp/resp" -D "$tmp/hdr" -w '%{http_code}' "http://localhost$2" 2>/dev/null); [ -n "$code" ] || code=000; }
else
	cat >"$tmp/client.py" <<'EOP'
import http.client, socket, sys
class C(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX); self.sock.settimeout(10); self.sock.connect(sys.argv[1])
try:
    c = C("localhost"); c.request(sys.argv[2], sys.argv[3]); r = c.getresponse(); b = r.read()
    open(sys.argv[4], "wb").write(b); print(r.status)
except Exception:
    open(sys.argv[4], "wb").write(b""); print("000")
EOP
	req() { code=$(python3 -I "$tmp/client.py" "$sock" "$1" "$2" "$tmp/resp" 2>/dev/null); : >"$tmp/hdr"; }
fi

# validate.py <schema> <instance>: a small JSON-schema validator (type, properties, required, items, enum,
# additionalProperties, const). Prints the first error and exits 1; "version" must be 1.
cat >"$tmp/validate.py" <<'EOP'
import json, sys
def check(s, v, p):
    if s is True or s is None: return
    if s is False: raise ValueError("%s: nothing is allowed" % p)
    if "type" in s:
        ts = s["type"] if isinstance(s["type"], list) else [s["type"]]
        def ok(t):
            if t == "null": return v is None
            if t == "boolean": return isinstance(v, bool)
            if t == "integer": return isinstance(v, int) and not isinstance(v, bool)
            if t == "number": return isinstance(v, (int, float)) and not isinstance(v, bool)
            if t == "string": return isinstance(v, str)
            if t == "array": return isinstance(v, list)
            if t == "object": return isinstance(v, dict)
            raise ValueError("unknown type %r" % t)
        if not any(ok(t) for t in ts): raise ValueError("%s: %r is not of type %s" % (p, v, "/".join(ts)))
    if "enum" in s and v not in s["enum"]: raise ValueError("%s: %r not in enum" % (p, v))
    if "const" in s and v != s["const"]: raise ValueError("%s: %r is not %r" % (p, v, s["const"]))
    if isinstance(v, dict):
        for k in s.get("required", []):
            if k not in v: raise ValueError("%s: missing %s" % (p, k))
        props = s.get("properties", {})
        for k, x in v.items():
            if k in props: check(props[k], x, p + "." + k)
            elif s.get("additionalProperties") is False: raise ValueError("%s: unexpected %s" % (p, k))
            elif isinstance(s.get("additionalProperties"), dict): check(s["additionalProperties"], x, p + "." + k)
    if isinstance(v, list) and "items" in s:
        for i, x in enumerate(v): check(s["items"], x, "%s[%d]" % (p, i))
schema = json.load(open(sys.argv[1])); inst = json.load(open(sys.argv[2]))
try:
    if not isinstance(inst, dict) or inst.get("version") != 1 or isinstance(inst.get("version"), bool): raise ValueError('"version": 1 is missing')
    check(schema, inst, "$")
except ValueError as e:
    print(e); sys.exit(1)
EOP

# jx <expr>: evaluate a Python expression over the last body as d; prints the result, "ERR" if not JSON.
jx() { python3 -I -c 'import json,sys
try: d = json.load(open(sys.argv[1]))
except Exception: print("ERR"); sys.exit(0)
try: print(eval(sys.argv[2]))
except Exception as e: print("ERR", e)' "$tmp/resp" "$1"; }

# get <id> <path> <resource>: GET path; passes when 200, JSON, "version": 1 and valid against
# scheduler/api-schema/v1/<resource>.json. The body stays in $tmp/resp for further checks.
get() {
	req GET "$2"
	if [ "$code" != 200 ]; then fail "$1: GET $2 answered $code, not 200"; return 1; fi
	if [ ! -f "$schemas/$3.json" ]; then fail "$1: GET $2: no schema scheduler/api-schema/v1/$3.json"; return 1; fi
	if msg=$(python3 -I "$tmp/validate.py" "$schemas/$3.json" "$tmp/resp" 2>&1); then pass "$1: GET $2 is valid against schema $3 and has version 1"; else fail "$1: GET $2 is not valid against schema $3: $msg"; return 1; fi
}
# err <id> <METHOD> <path> <status>: the answer has that status and a JSON error body with version 1.
err() {
	req "$2" "$3"
	if [ "$code" = "$4" ] && [ "$(jx "d['version'] == 1 and isinstance(d['error'], str)")" = True ]; then pass "$1: $2 $3 is answered $4 with a JSON error body"; else fail "$1: $2 $3 answered $code, body: $(head -c 100 "$tmp/resp" 2>/dev/null)"; fi
}

start_server() {
	python3 "$co/scheduler/api.py" >>"$tmp/api.out" 2>&1 &
	srv_pid=$!
	i=0
	while [ $i -lt 60 ] && kill -0 "$srv_pid" 2>/dev/null; do
		[ -S "$sock" ] && { req GET /v1/repos; [ "$code" = 200 ] && return 0; }
		sleep 0.1; i=$((i + 1))
	done
	return 1
}

# ================= P01-AC-1: the server =================
up=0
if start_server; then up=1; pass "P01-AC-1: api.py serves on \$NOODLEBOT_DATA/api.sock"; else fail "P01-AC-1: api.py did not serve on \$NOODLEBOT_DATA/api.sock: $(head -c 200 "$tmp/api.out")"; fi
if [ -S "$sock" ] && [ "$(stat -c %a "$sock" 2>/dev/null)" = 600 ]; then pass "P01-AC-1: the socket has mode 0600"; else fail "P01-AC-1: the socket is missing or its mode is $(stat -c %a "$sock" 2>/dev/null)"; fi

timeout 15 python3 "$co/scheduler/api.py" >"$tmp/second.out" 2>&1 </dev/null; rc=$?
if [ $rc = 2 ] && [ $up = 1 ]; then pass "P01-AC-1: a second api.py on the same root exits 2"; else fail "P01-AC-1: a second api.py exited $rc, not 2"; fi
req GET /v1/repos
if [ "$code" = 200 ]; then pass "P01-AC-1: the first server still serves after the second exited"; else fail "P01-AC-1: the first server answered $code after a second one started"; fi

kill -9 "$srv_pid" 2>/dev/null; wait "$srv_pid" 2>/dev/null; srv_pid=''
[ -S "$sock" ] || python3 -I -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$sock"   # a socket file left by a killed server
if [ -S "$sock" ] && start_server; then pass "P01-AC-1: a socket file left by a killed server does not stop a new one"; else fail "P01-AC-1: no new server after a killed one left its socket file: $(tail -c 200 "$tmp/api.out")"; fi

if [ -f "$co/scheduler/api.py" ] && python3 -I - "$co/scheduler/api.py" >"$tmp/imports.out" 2>&1 <<'EOP'
import ast, sys
mods = set(); bad = []
for n in ast.walk(ast.parse(open(sys.argv[1]).read())):
    if isinstance(n, ast.Import):
        mods |= {a.name.split(".")[0] for a in n.names}
    elif isinstance(n, ast.ImportFrom):
        if n.level: bad.append("relative import")
        else: mods.add((n.module or "").split(".")[0])
bad += sorted(m for m in mods if m not in sys.stdlib_module_names)
if bad: print("non-standard imports: " + ", ".join(bad)); sys.exit(1)
EOP
then pass "P01-AC-1: api.py imports only the standard library"; else fail "P01-AC-1: api.py imports: $(cat "$tmp/imports.out" 2>/dev/null || echo 'no api.py')"; fi

# ================= P01-AC-3 and P01-AC-8: repositories =================
get P01-AC-3 /v1/repos repos
n=$(jx "len(d['repos'])"); names=$(jx "[r['repo'] for r in d['repos']]")
if [ "$names" = "['acme/alpha', 'acme/beta']" ]; then pass "P01-AC-3: /v1/repos lists each listed repository once, in list order"; else fail "P01-AC-3: /v1/repos lists $names"; fi
if [ "$(jx "{r['repo']: r['running'] for r in d['repos']}")" = "{'acme/alpha': True, 'acme/beta': False}" ]; then pass "P01-AC-3: running is true for the repository whose loop.lock is held, false for the other"; else fail "P01-AC-3: running: $(jx "{r['repo']: r.get('running') for r in d['repos']}")"; fi
if [ "$(jx "{r['repo']: r['stop'] for r in d['repos']}")" = "{'acme/alpha': False, 'acme/beta': True}" ]; then pass "P01-AC-3: stop shows ~/STOP-<name> for beta only"; else fail "P01-AC-3: stop: $(jx "{r['repo']: r.get('stop') for r in d['repos']}")"; fi
if [ "$(jx "[r['stop_all'] for r in d['repos']]")" = "[False, False]" ]; then pass "P01-AC-3: stop_all is false without ~/STOP"; else fail "P01-AC-3: stop_all without ~/STOP: $(jx "[r.get('stop_all') for r in d['repos']]")"; fi
if [ "$(jx "{r['repo']: 25 <= r['heartbeat_age'] <= 120 if r['repo'] == 'acme/alpha' else 3590 <= r['heartbeat_age'] <= 3800 for r in d['repos']}")" = "{'acme/alpha': True, 'acme/beta': True}" ]; then pass "P01-AC-3: heartbeat_age is the heartbeat's age in seconds"; else fail "P01-AC-3: heartbeat_age: $(jx "[r.get('heartbeat_age') for r in d['repos']]")"; fi
if [ "$(jx "{r['repo']: r['status_issue'] for r in d['repos']}")" = "{'acme/alpha': 41, 'acme/beta': 52}" ]; then pass "P01-AC-3: status_issue is report.json's issue"; else fail "P01-AC-3: status_issue: $(jx "[r.get('status_issue') for r in d['repos']]")"; fi
touch "$home/STOP"
req GET /v1/repos
if [ "$(jx "[r['stop_all'] for r in d['repos']]")" = "[True, True]" ]; then pass "P01-AC-3: stop_all is true for every repository while ~/STOP exists"; else fail "P01-AC-3: stop_all with ~/STOP: $(jx "[r.get('stop_all') for r in d['repos']]")"; fi
rm -f "$home/STOP"

for r in alpha beta; do
	get P01-AC-3 /v1/repos/acme/$r repo
	want_run=True; [ $r = beta ] && want_run=False
	want_issue=41; [ $r = beta ] && want_issue=52
	if [ "$(jx "d['repo'] == 'acme/$r' and d['running'] is $want_run and d['status_issue'] == $want_issue and d['stop'] is (d['repo'] == 'acme/beta')")" = True ]; then pass "P01-AC-3: /v1/repos/acme/$r gives that repository"; else fail "P01-AC-3: /v1/repos/acme/$r: $(head -c 200 "$tmp/resp")"; fi
done
err P01-AC-3 GET /v1/repos/acme/ghost 404

# every served schema is the committed file, and declares version
for res in repos repo; do
	req GET /v1/schema/$res
	if [ "$code" = 200 ] && [ -f "$schemas/$res.json" ] && python3 -I -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])) == json.load(open(sys.argv[2])) else 1)' "$tmp/resp" "$schemas/$res.json" 2>/dev/null; then pass "P01-AC-8: /v1/schema/$res serves scheduler/api-schema/v1/$res.json"; else fail "P01-AC-8: /v1/schema/$res answered $code or differs from the committed schema"; fi
	if [ -f "$schemas/$res.json" ] && python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1])); sys.exit(0 if "version" in s.get("properties",{}) and "version" in s.get("required",[]) else 1)' "$schemas/$res.json" 2>/dev/null; then pass "P01-AC-8: schema $res requires version"; else fail "P01-AC-8: schema $res is missing or does not require version"; fi
done
err P01-AC-8 GET /v1/schema/nothing 404
# the validator rejects what it should (it is the test's own machinery)
echo '{"version":1,"x":"s"}' >"$tmp/v.json"
echo '{"type":"object","required":["version","x"],"properties":{"version":{"const":1},"x":{"type":"integer"}},"additionalProperties":false}' >"$tmp/v.schema"
if python3 -I "$tmp/validate.py" "$tmp/v.schema" "$tmp/v.json" >/dev/null 2>&1; then fail "P01-AC-8: the test's validator accepts a string where the schema says integer"; else pass "P01-AC-8: the test's validator rejects a wrongly typed field"; fi

# ================= P01-AC-1: HEAD moves =================
# A new commit in the checkout (a changed schema file); the server (HEAD check every 2 s here) serves from it.
mkdir -p "$co/scheduler/api-schema/v1"
python3 -I -c 'import json,os,sys
p = sys.argv[1]
s = json.load(open(p)) if os.path.exists(p) else {"type": "object"}
s["description"] = "moved with HEAD"
json.dump(s, open(p, "w"), indent=1)' "$co/scheduler/api-schema/v1/repos.json"
git -C "$co" add -A >/dev/null 2>&1
git -C "$co" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m moved >/dev/null 2>&1
moved=0; i=0
while [ $i -lt 100 ] && [ $up = 1 ]; do   # up to 20 s; the criterion allows 2 minutes with the default 60 s check
	req GET /v1/schema/repos
	if [ "$code" = 200 ] && [ "$(jx "d.get('description')")" = "moved with HEAD" ]; then moved=1; break; fi
	sleep 0.2; i=$((i + 1))
done
if [ $moved = 1 ]; then pass "P01-AC-1: after HEAD moved, the server serves from the new commit"; else fail "P01-AC-1: the server did not serve from the new commit after HEAD moved"; fi
if [ -S "$sock" ] && [ "$(stat -c %a "$sock" 2>/dev/null)" = 600 ]; then pass "P01-AC-1: the socket still has mode 0600 after the server moved to the new commit"; else fail "P01-AC-1: socket mode after the move: $(stat -c %a "$sock" 2>/dev/null)"; fi
timeout 15 python3 "$co/scheduler/api.py" >/dev/null 2>&1 </dev/null; rc=$?
if [ $rc = 2 ] && [ $moved = 1 ]; then pass "P01-AC-1: after the move the server still holds the lock (a second one exits 2)"; else fail "P01-AC-1: after the move a second api.py exited $rc, not 2"; fi

# ================= P01-AC-2: the API changes nothing =================
for m in POST PUT PATCH DELETE; do err P01-AC-2 $m /v1/repos 405; done
err P01-AC-2 POST /v1/repos/acme/alpha 405
err P01-AC-2 GET /v1/nothing 404
err P01-AC-2 GET /nothing 404
err P01-AC-2 GET /v1/repos/acme/alpha/nothing 404

# ================= P01-AC-4: nodes =================
# S2 contract (fields named once here; the schemas "nodes" and "node" declare them):
#  Resource "nodes"  GET /v1/repos/<owner>/<name>/nodes  ->  {"version":1, "nodes":[<node>...]}, in graph order.
#  Resource "node"   GET /v1/repos/<owner>/<name>/nodes/<ID>  ->  {"version":1, <node fields flat>}; unknown ID is 404.
#  <node> fields: "id", "name", "deps" (list of IDs), "track" ("now"|"later"), "starts" (int, starts used, 0 if none),
#    "state" (merged|pr-open|running|idle-limit|failed|question|answered|waiting-pr|held|ready|waiting), and always:
#    "pr" (int or null: the open PR's number, pr-open only), "mergeable" (string or null: MERGEABLE, CONFLICTING...,
#    pr-open only), "reason" (string or null: first line of FAILED, failed only), "question" (string or null: first
#    line of QUESTION.md, question only), "issue_url" (string or null: https://github.com/<owner>/<name>/issues/<N>,
#    the home issue from node/<ID>/issue else the status issue, question only), "spec_pr" (int or null: WAITING-PR's
#    number, waiting-pr only), "waiting_on" (list of dep IDs not yet merged; [] unless state is waiting).
get P01-AC-4 /v1/repos/acme/alpha/nodes nodes
cp "$tmp/resp" "$tmp/nodes.json"
if [ "$(jx "[n['id'] for n in d['nodes']]")" = "['N01', 'N02', 'N03', 'N04', 'N05', 'N06', 'N07', 'N08', 'N09', 'N10', 'N11']" ]; then pass "P01-AC-4: /nodes gives each node of the graph once, in graph order"; else fail "P01-AC-4: /nodes ids: $(jx "[n.get('id') for n in d['nodes']]")"; fi
if [ "$(jx "[(n['name'], n['deps'], n['track']) for n in d['nodes'] if n['id'] in ('N10', 'N02')]")" = "[('pr-open-one', ['N01'], 'now'), ('waiting-one', ['N09', 'N03'], 'later')]" ]; then pass "P01-AC-4: nodes give name, deps and track"; else fail "P01-AC-4: name, deps, track: $(jx "[(n.get('name'), n.get('deps'), n.get('track')) for n in d['nodes']]")"; fi
nodefield() { # nodefield <ID> <python expr over n, the node>: true when the node's entry in the list satisfies it
	jx "(lambda n: $2)([n for n in d['nodes'] if n['id'] == '$1'][0])"
}
node_is() { # node_is <ID> <python expr over n> <what>: checks the list entry and GET .../nodes/<ID>
	cp "$tmp/nodes.json" "$tmp/resp"
	if [ "$(nodefield "$1" "$2")" = True ]; then pass "P01-AC-4: /nodes: $1 $3"; else fail "P01-AC-4: /nodes: $1 $3; got $(jx "[n for n in d['nodes'] if n.get('id') == '$1']")"; fi
	if get P01-AC-4 /v1/repos/acme/alpha/nodes/$1 node; then
		if [ "$(jx "(lambda n: $2)(d)")" = True ]; then pass "P01-AC-4: /nodes/$1: $3"; else fail "P01-AC-4: /nodes/$1: $3; got $(head -c 300 "$tmp/resp")"; fi
	fi
}
set_usage open
get P01-AC-4 /v1/repos/acme/alpha/nodes nodes; cp "$tmp/resp" "$tmp/nodes.json"
node_is N01 "n['state'] == 'merged' and n['starts'] == 1 and n['pr'] is None" "is merged, 1 start"
node_is N02 "n['state'] == 'pr-open' and n['pr'] == 12 and n['mergeable'] == 'MERGEABLE' and n['starts'] == 1" "is pr-open, PR 12 MERGEABLE"
node_is N11 "n['state'] == 'pr-open' and n['pr'] == 14 and n['mergeable'] == 'CONFLICTING' and n['starts'] == 2" "is pr-open, PR 14 CONFLICTING, 2 starts"
node_is N03 "n['state'] == 'running' and n['starts'] == 1" "is running (a live session)"
node_is N04 "n['state'] == 'idle-limit' and n['starts'] == 1" "is idle-limit (a live session whose log ends at the usage limit)"
node_is N05 "n['state'] == 'failed' and n['reason'] == 'tests do not pass after 2 starts' and n['starts'] == 2" "is failed with the first line of FAILED"
node_is N06 "n['state'] == 'question' and n['question'] == 'Which database should the cache use?' and n['issue_url'] == 'https://github.com/acme/alpha/issues/77'" "is a question with the first line of QUESTION.md and its home issue's URL"
node_is N07 "n['state'] == 'answered'" "is answered"
node_is N08 "n['state'] == 'waiting-pr' and n['spec_pr'] == 90" "is waiting-pr with spec PR 90"
node_is N09 "n['state'] == 'ready' and n['starts'] == 0" "is ready with 0 starts while the throttle is open"
node_is N10 "n['state'] == 'waiting' and sorted(n['waiting_on']) == ['N03', 'N09']" "is waiting on N03 and N09"
node_is N01 "n['waiting_on'] == [] and n['reason'] is None and n['question'] is None and n['issue_url'] is None and n['spec_pr'] is None" "has the state-specific fields empty"
set_usage holding
get P01-AC-4 /v1/repos/acme/alpha/nodes nodes; cp "$tmp/resp" "$tmp/nodes.json"
node_is N09 "n['state'] == 'held'" "is held while usage.json holds"
node_is N10 "n['state'] == 'waiting'" "stays waiting while usage.json holds"
node_is N02 "n['state'] == 'pr-open'" "stays pr-open while usage.json holds"
set_usage open
get P01-AC-4 /v1/repos/acme/alpha/nodes nodes; cp "$tmp/resp" "$tmp/nodes.json"
node_is N09 "n['state'] == 'ready'" "is ready again once usage.json is open"
# beta
get P01-AC-4 /v1/repos/acme/beta/nodes nodes
if [ "$(jx "[(n['id'], n['state'], n['starts'], n['waiting_on']) for n in d['nodes']]")" = "[('B01', 'ready', 0, []), ('B02', 'waiting', 0, ['B01'])]" ]; then pass "P01-AC-4: beta's nodes are B01 ready and B02 waiting on B01"; else fail "P01-AC-4: beta's nodes: $(jx "d.get('nodes')")"; fi
get P01-AC-4 /v1/repos/acme/beta/nodes/B02 node
err P01-AC-4 GET /v1/repos/acme/alpha/nodes/N99 404
err P01-AC-4 GET /v1/repos/acme/alpha/nodes/B01 404
err P01-AC-4 GET /v1/repos/acme/ghost/nodes 404
err P01-AC-4 POST /v1/repos/acme/alpha/nodes 405
for res in nodes node; do
	req GET /v1/schema/$res
	if [ "$code" = 200 ] && [ -f "$schemas/$res.json" ] && python3 -I -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])) == json.load(open(sys.argv[2])) else 1)' "$tmp/resp" "$schemas/$res.json" 2>/dev/null; then pass "P01-AC-8: /v1/schema/$res serves scheduler/api-schema/v1/$res.json"; else fail "P01-AC-8: /v1/schema/$res answered $code or differs from the committed schema"; fi
done
# Not encoded: the question URL falling back to the status issue (no fixture node has a QUESTION.md without node/<ID>/issue).


# ================= P01-AC-1: HEAD moves, the server's own code changes (a second move) =================
# A schema file is read from disk per request, so the first move above cannot tell a re-exec from no re-exec.
# Here api.py itself changes: the text of the 404 for an unknown path gets a marker, which only a server that
# re-executed the new api.py can show. The anchor is the literal "not found: " in api.py; if it is missing the
# case fails (it does not crash and it does not pass).
srv_before=$srv_pid
if grep -q '"not found: "' "$co/scheduler/api.py" && sed -i 's/"not found: "/"not found [head-moved-marker]: "/' "$co/scheduler/api.py" && grep -q 'head-moved-marker' "$co/scheduler/api.py"; then
	git -C "$co" add -A >/dev/null 2>&1
	git -C "$co" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m "moved api.py" >/dev/null 2>&1
	moved2=0; i=0
	while [ $i -lt 100 ] && [ $up = 1 ]; do   # up to 20 s
		req GET /v1/head-moved-probe
		if [ "$code" = 404 ] && [ "$(jx "'head-moved-marker' in d.get('error', '')")" = True ]; then moved2=1; break; fi
		sleep 0.2; i=$((i + 1))
	done
	if [ $moved2 = 1 ]; then pass "P01-AC-1: after HEAD moved with a new api.py, the server answers with the new code"; else fail "P01-AC-1: the server still runs the old api.py after HEAD moved (no marker in the 404 text)"; fi
else
	moved2=0
	fail "P01-AC-1: could not change api.py in the checkout copy (anchor \"not found: \" missing); the HEAD-move code test did not run"
fi
if [ -n "$srv_before" ] && kill -0 "$srv_before" 2>/dev/null && [ "$srv_pid" = "$srv_before" ] && [ $moved2 = 1 ]; then pass "P01-AC-1: the server process is the same (re-executed in place) after the move"; else fail "P01-AC-1: the server process $srv_before is gone or the move did not happen"; fi
if [ -S "$sock" ] && [ "$(stat -c %a "$sock" 2>/dev/null)" = 600 ]; then pass "P01-AC-1: the socket has mode 0600 after the code move"; else fail "P01-AC-1: socket mode after the code move: $(stat -c %a "$sock" 2>/dev/null)"; fi
timeout 15 python3 "$co/scheduler/api.py" >/dev/null 2>&1 </dev/null; rc=$?
if [ $rc = 2 ] && [ $moved2 = 1 ]; then pass "P01-AC-1: after the code move a second api.py exits 2"; else fail "P01-AC-1: after the code move a second api.py exited $rc (want 2; move seen: $moved2)"; fi
req GET /v1/repos
if [ "$code" = 200 ] && [ $moved2 = 1 ]; then pass "P01-AC-1: after the code move the server answers 200"; else fail "P01-AC-1: after the code move GET /v1/repos answered $code (want 200; move seen: $moved2)"; fi
# ================= P01-AC-5: sessions =================
# S3 contract (fields named once here; the schema "sessions" declares them; read from the loop's session files, never from gh):
#  Resource "sessions"  GET /v1/repos/<owner>/<name>/sessions  ->  {"version":1, "sessions":[<session>...]}: every node/<ID>,
#    issue/<N> and pr/<N> folder of state/<name>/ that has a session.pid (order not specified; [] when none). An unlisted
#    repo is 404, POST is 405. There is no one-session resource.
#  <session> fields: "kind" ("node" | "triage" (issue/<N>) | "update" (pr/<N>)), "subject" (STRING: the node ID, or the
#    issue or PR number as a string, "9"), "pid" (int, session.pid), "alive" (bool, as loop.sh's alive()), "started"
#    (int epoch, session.pid's mtime), "log_size" (int bytes of session.jsonl), "log_modified" (int epoch, its mtime),
#    "events" (list, OLDEST FIRST, the last at most 10 of the log's tool uses and results, in log order; assistant text,
#    tool results, rate_limit_events and system lines are not events), "rc" (int, session.rc, once ended; null/absent while live).
#    An event: {"type": "tool_use"|"result", "time": int epoch of its line, and
#      for tool_use: "tool" (name), "text" (the first line of input.description, else input.command, else input.path or
#        input.file_path, redacted, cut to 200 chars; absent/null when the tool has none of them),
#        "subagent" (true when the line has parent_tool_use_id, i.e. it ran inside a subagent; false/absent otherwise);
#      for result: "subtype" (the result line's subtype)}.
#    "wakeup_at" (int epoch: the time of the last ScheduleWakeup tool use plus its input.delaySeconds, when no later line
#      of the log is an assistant tool use or a result; absent/null otherwise),
#    "bg_commands" and "bg_agents" (lists of {"id": the background ID from the tool result "...ID: <id>", "text": as an
#      event's text}: Bash tool uses with run_in_background, and Agent tool uses with run_in_background, whose ID has no
#      later system/task_notification line with that task_id; absent/null/[] when none),
#    "limit" ({"at": int epoch of the last rate_limit_event whose rate_limit_info.status is not "allowed", "resets_at": its
#      rate_limit_info.resetsAt}; absent/null when none, wherever in the log it sits).
#  Redaction: [redacted] replaces a token-shaped string inside any text served (P01-AC-9).
#  Size: no response carries more than the last 10 events of a log; the test checks a 2000-event log (about 450 KB) against
#    a bound of 60000 bytes for the whole response (at most 10 sessions x 10 events x about 400 bytes is 40 KB).
ep() { date -u -d "$1" +%s; }
# From here every response is also appended to $tmp/allresp, which the P01-AC-9 final check below scans.
: >"$tmp/allresp"
if command -v curl >/dev/null 2>&1; then
	req() { : >"$tmp/resp"; code=$(curl -s --max-time 10 --unix-socket "$sock" -X "$1" -o "$tmp/resp" -D "$tmp/hdr" -w '%{http_code}' "http://localhost$2" 2>/dev/null); [ -n "$code" ] || code=000; cat "$tmp/resp" >>"$tmp/allresp"; }
else
	req() { code=$(python3 -I "$tmp/client.py" "$sock" "$1" "$2" "$tmp/resp" 2>/dev/null); : >"$tmp/hdr"; cat "$tmp/resp" >>"$tmp/allresp"; }
fi
get P01-AC-5 /v1/repos/acme/alpha/sessions sessions; cp "$tmp/resp" "$tmp/sessions.json"
sess_is() { # sess_is <kind> <subject> <python expr over s> <what>: the session's entry satisfies the expression
	cp "$tmp/sessions.json" "$tmp/resp"
	if [ "$(jx "(lambda s: $3)(next(x for x in d['sessions'] if x['kind'] == '$1' and x['subject'] == '$2'))")" = True ]; then pass "P01-AC-5: /sessions: $1 $2 $4"; else fail "P01-AC-5: /sessions: $1 $2 $4; got $(jx "[x for x in d['sessions'] if x.get('subject') == '$2']" | head -c 500)"; fi
}
if [ "$(jx "len(d['sessions']) == 7 and sorted((x['kind'], x['subject']) for x in d['sessions'])")" = "[('node', 'N01'), ('node', 'N03'), ('node', 'N04'), ('node', 'N11'), ('triage', '8'), ('triage', '9'), ('update', '15')]" ]; then pass "P01-AC-5: /sessions gives each of the 7 sessions with a session.pid (and no node without one), by kind and subject"; else fail "P01-AC-5: /sessions kinds and subjects: $(jx "[(x.get('kind'), x.get('subject')) for x in d['sessions']]")"; fi
for k in N03:node N04:node N01:node N11:node 9:triage 8:triage 15:update; do
	sub=${k%%:*}; kind=${k##*:}
	case $kind in node) dir=node/$sub ;; triage) dir=issue/$sub ;; update) dir=pr/$sub ;; esac
	spid=$(cat "$a/$dir/session.pid"); ssize=$(stat -c %s "$a/$dir/session.jsonl"); smt=$(stat -c %Y "$a/$dir/session.jsonl")
	walive=True; [ -f "$a/$dir/session.rc" ] && walive=False
	sess_is $kind $sub "s['pid'] == $spid and s['alive'] is $walive and s['started'] == $(ep 2026-11-09T09:01:00Z)" "has its pid, alive ($walive) and start time (session.pid's mtime)"
	sess_is $kind $sub "s['log_size'] == $ssize and abs(s['log_modified'] - $smt) <= 1" "has its log's size and last write"
done
# node N03: tool uses, a pending ScheduleWakeup, an unfinished command and agent, no limit, still running
sess_is node N03 "len(s['events']) == 10 and [e['tool'] for e in s['events']] == ['Bash', 'Bash', 'Bash', 'Bash', 'Agent', 'Agent', 'Grep', 'Edit', 'Bash', 'ScheduleWakeup'] and all(e['type'] == 'tool_use' and isinstance(e['time'], int) for e in s['events'])" "has the last 10 of its 16 tool uses, oldest first, each with type, tool and time"
sess_is node N03 "[e['text'] for e in s['events'][:8]] == ['Run the tests, round 7', 'Run the tests, round 8', 'Watch CI in the background', 'tail -f build.log', 'Review the diff for style', 'Check the docs', '/w/alpha/N03/scheduler', '/w/alpha/N03/scheduler/x.py']" "gives a tool use's first line of description, else command, else path"
sess_is node N03 "[e['time'] for e in s['events'][:2]] == [$(ep 2026-11-09T09:09:00Z), $(ep 2026-11-09T09:10:00Z)]" "gives each event its time"
sess_is node N03 "[bool(e.get('subagent')) for e in s['events']] == [False] * 6 + [True] + [False] * 3" "marks the tool use that ran inside a subagent"
sess_is node N03 "'[redacted]' in s['events'][8]['text'] and 'sk-ant-api03' not in s['events'][8]['text']" "shows [redacted] where a tool use's description held an API key"
sess_is node N03 "s['wakeup_at'] == $(ep 2026-11-09T09:15:00Z) + 1800" "has the pending ScheduleWakeup time (tool use time plus delaySeconds)"
sess_is node N03 "[c['id'] for c in s['bg_commands']] == ['bg-ci-1'] and s['bg_commands'][0]['text'] == 'Watch CI in the background'" "has the unfinished background command only (bg-tail-2 completed)"
sess_is node N03 "[g['id'] for g in s['bg_agents']] == ['ag-review-1'] and s['bg_agents'][0]['text'] == 'Review the diff for style'" "has the unfinished background agent only (ag-docs-2 completed)"
sess_is node N03 "s.get('limit') is None and s.get('rc') is None" "has no limit rejection (only allowed events) and no rc"
if [ "$(cp "$tmp/sessions.json" "$tmp/resp"; jx "len(d['sessions']) == 7")" = True ] && ! grep -q 'round 2' "$tmp/sessions.json" && ! grep -q 'round 6' "$tmp/sessions.json" && ! grep -q 'N03-running-one' "$tmp/sessions.json" && [ -s "$tmp/sessions.json" ]; then pass "P01-AC-5: N03's early events (rounds 2 to 6, the first Read) appear nowhere in the response"; else fail "P01-AC-5: the response holds events older than the last 10 of N03"; fi
# node N04: live, the log ends with a rejected rate_limit_event
sess_is node N04 "s['limit'] == {'at': $(ep 2026-11-09T10:40:00Z), 'resets_at': 1794236400}" "has its limit rejection and reset time"
sess_is node N04 "[(e['type'], e['tool'], e['text']) for e in s['events']] == [('tool_use', 'Bash', 'Run the tests')] and not s.get('wakeup_at') and not s.get('bg_commands') and not s.get('bg_agents') and s.get('rc') is None" "has one event and no wakeup, background tasks or rc"
# node N01 and N11: ended
sess_is node N01 "[(e['type'], e.get('subtype'), e.get('text')) for e in s['events']] == [('tool_use', None, 'Push'), ('result', 'success', None)] and s['rc'] == 0 and s.get('limit') is None" "ended: its events end in a result with its subtype, and rc is 0"
sess_is node N11 "[(e['type'], e.get('subtype')) for e in s['events']] == [('tool_use', None), ('result', 'error_during_execution')] and s['rc'] == 1" "ended: its result's subtype and rc 1"
sess_is node N11 "s['limit'] == {'at': $(ep 2026-11-09T07:30:00Z), 'resets_at': 1794225600}" "has the last limit rejection although it is not the log's last line"
# triage and update
sess_is triage 9 "s['kind'] == 'triage' and [(e['tool'], e['text'], bool(e.get('subagent'))) for e in s['events']] == [('Bash', 'Read the issue', False), ('Agent', 'Explore the export code', False)] and s.get('rc') is None" "has its events (a token in a tool result is not served)"
sess_is triage 9 "[g['id'] for g in s['bg_agents']] == ['ag-i9-1'] and s['bg_agents'][0]['text'] == 'Explore the export code' and not s.get('bg_commands') and not s.get('wakeup_at')" "has its unfinished background agent"
sess_is triage 8 "[(e['type'], e.get('tool'), e.get('text'), e.get('subtype')) for e in s['events']] == [('tool_use', 'Write', '/w/alpha/issue-8/nodes/Z01-dark-mode.md', None), ('result', None, None, 'success')] and s['rc'] == 0" "ended: its Write path, its result and rc 0"
sess_is update 15 "s['kind'] == 'update' and [e['text'] for e in s['events']] == ['Merge main', 'Run the checker'] and s.get('limit') is None" "has its events"
get P01-AC-5 /v1/repos/acme/beta/sessions sessions
if [ "$(jx "d['sessions']")" = "[]" ]; then pass "P01-AC-5: beta, with no session.pid, has no sessions"; else fail "P01-AC-5: beta's sessions: $(head -c 200 "$tmp/resp")"; fi
err P01-AC-5 GET /v1/repos/acme/ghost/sessions 404
err P01-AC-5 POST /v1/repos/acme/alpha/sessions 405
req GET /v1/schema/sessions
if [ "$code" = 200 ] && [ -f "$schemas/sessions.json" ] && python3 -I -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])) == json.load(open(sys.argv[2])) else 1)' "$tmp/resp" "$schemas/sessions.json" 2>/dev/null; then pass "P01-AC-8: /v1/schema/sessions serves scheduler/api-schema/v1/sessions.json"; else fail "P01-AC-8: /v1/schema/sessions answered $code or differs from the committed schema"; fi

# Two more sessions, made here and removed below (the baseline of the AC-2 snapshot is not re-taken: the folders are gone again
# before the final check): update PR 16 whose ScheduleWakeup was followed by a later tool use, and triage issue 20 with a
# 2000-event log (an early marker, a last event whose first line is 300 characters).
mkdir -p "$a/pr/16" "$a/issue/20"
cat >"$a/pr/16/session.jsonl" <<'EOF'
{"type":"system","subtype":"init","timestamp":"2026-11-09T08:00:00Z"}
{"type":"assistant","timestamp":"2026-11-09T08:01:00Z","message":{"content":[{"type":"tool_use","id":"w1","name":"ScheduleWakeup","input":{"delaySeconds":600,"reason":"wait","prompt":"go on"}}]}}
{"type":"assistant","timestamp":"2026-11-09T08:11:00Z","message":{"content":[{"type":"tool_use","id":"w2","name":"Bash","input":{"command":"git status","description":"Went on after the wakeup"}}]}}
EOF
python3 -I -c '
import json, sys
out = open(sys.argv[1], "w")
out.write(json.dumps({"type": "system", "subtype": "init", "timestamp": "2026-11-09T06:00:00Z"}) + "\n")
for i in range(1, 2001):
    inp = {"command": "EARLYMARKER-%d " % i + "p" * 150 if i <= 5 else "step %d " % i + "q" * 150, "description": "late-%d" % i if i > 1990 else "early-%d" % i}
    if i == 2000:
        inp = {"command": "z" * 300 + "\nSECONDLINE"}
    out.write(json.dumps({"type": "assistant", "timestamp": "2026-11-09T07:%02d:%02dZ" % (i // 60 % 60, i % 60), "message": {"content": [{"type": "tool_use", "id": "x%d" % i, "name": "Bash", "input": inp}]}}) + "\n")
' "$a/issue/20/session.jsonl"
ended "$a/pr/16"; ended "$a/issue/20"
touch -d 2026-11-09T08:00:00Z "$a/pr/16/session.pid" "$a/issue/20/session.pid"
get P01-AC-5 /v1/repos/acme/alpha/sessions sessions; cp "$tmp/resp" "$tmp/sessions.json"
sess_is update 16 "s.get('wakeup_at') is None and [e.get('text') for e in s['events']] == [None, 'Went on after the wakeup'] and s['alive'] is False and s['started'] == $(ep 2026-11-09T08:00:00Z)" "has no pending wakeup when a later tool use shows the session went on"
sess_is triage 20 "len(s['events']) == 10 and [e['text'] for e in s['events'][:9]] == ['late-%d' % i for i in range(1991, 2000)] and s['log_size'] > 300000" "of a 2000-event log has exactly its last 10 events"
sess_is triage 20 "s['events'][9]['text'] == 'z' * 200" "gives the first line of a long command cut to 200 characters"
if [ "$(cp "$tmp/sessions.json" "$tmp/resp"; jx "len(d['sessions']) == 9")" = True ] && ! grep -q 'EARLYMARKER' "$tmp/sessions.json" && ! grep -q 'SECONDLINE' "$tmp/sessions.json" && ! grep -q 'early-' "$tmp/sessions.json"; then pass "P01-AC-5: a marker only in the early events of a long log, and a second line, appear nowhere in the response"; else fail "P01-AC-5: the response holds early events of the 2000-event log or a second line"; fi
sz=$(wc -c <"$tmp/sessions.json")
if [ "$sz" -gt 500 ] && [ "$sz" -lt 60000 ]; then pass "P01-AC-5: the response ($sz bytes) stays under 60000 bytes though a log is about 450 KB"; else fail "P01-AC-5: the response is $sz bytes (want a real answer under 60000)"; fi
rm -rf "$a/pr/16" "$a/issue/20"

# ================= P01-AC-6: throttle, deploy, PRs, issues =================
# S4 contract (fields named once here; the schemas "throttle", "deploy", "prs" and "issues" declare them). Every one of the four
# carries "modified" (int epoch: the mtime of the file it was read from). None is written by the server; none calls gh.
#  Resource "throttle"  GET /v1/throttle  ->  {"version":1, "updated" (int: usage.json's "updated"), "modified" (usage.json's mtime),
#    "five_hour" and "seven_day": {"utilization" (number, as in the file: 0.12), "resets_at" (int, the file's resetsAt), "status"
#    (string)}, "projected_5h" (number, the file's projected5h), "hold" (bool), "reason" (string)}.
#  Resource "deploy"  GET /v1/deploy  ->  {"version":1, "head" (string: the HEAD of the checkout api.py runs from), "previous" (string
#    or null: deploy/previous, trimmed: the rollback point), "rejected" (list of strings: deploy/rejected, one per line),
#    "last_deploy" and "last_failed" (null, or {"repo": "owner/name", "time" (int: the log line's timestamp), "line" (string: the
#    text after the timestamp, redacted)} of the LATEST line over all listed repositories' status.log that starts "deployed "
#    (last_deploy) or "not deployed: " (last_failed)), "modified" (the mtime of deploy/previous)}.
#  Resource "prs"  GET /v1/repos/<owner>/<name>/prs  ->  {"version":1, "prs":[{"number" (int), "branch", "head" (string), "bot"
#    (bool: the tsv's is_bot), "mergeable" (string)}...], "modified" (open-prs.tsv's mtime)}, in file order; unlisted repo 404.
#  Resource "issues"  GET /v1/repos/<owner>/<name>/issues  ->  {"version":1, "issues":[{"number" (int), "title" (string or null),
#    "labelled" (bool or null), "state" (string or null)}...], "modified" (issues.json's mtime)}. An entry exists for each issue of
#    issues.json that is labelled true, and for each state/<name>/issue/<N>/ folder (the union, once per number). title and labelled
#    come from issues.json (null when the issue is not in it); state is "done" (a done marker), else "failed" (FAILED), else
#    "question" (QUESTION.md without ANSWER.md), else "running" (a session.pid whose process is alive); null with no folder.
#    An issue that issues.json lists as labelled false (the owner did not label it) and that has no folder is not listed.
chk() { # chk <id> <what> <python expr over d>
	if [ "$(jx "$3")" = True ]; then pass "$1: $2"; else fail "$1: $2; got $(head -c 400 "$tmp/resp")"; fi
}
mt() { stat -c %Y "$1"; }
set_usage open
get P01-AC-6 /v1/throttle throttle
chk P01-AC-6 "/v1/throttle gives both windows, the projection, hold and reason (open)" "d['five_hour'] == {'utilization': 0.12, 'resets_at': 1794236400, 'status': 'allowed'} and d['seven_day'] == {'utilization': 0.3, 'resets_at': 1794441600, 'status': 'allowed'} and d['projected_5h'] == 0.3 and d['hold'] is False and d['reason'] == '' and d['updated'] == 1794222000"
chk P01-AC-6 "/v1/throttle carries the mtime of usage.json" "abs(d['modified'] - $(mt "$data/state/usage.json")) <= 1"
set_usage holding
get P01-AC-6 /v1/throttle throttle
chk P01-AC-6 "/v1/throttle follows usage.json while it holds: utilization, projection, hold and reason" "d['five_hour']['utilization'] == 0.93 and d['seven_day']['utilization'] == 0.4 and d['projected_5h'] == 1.7 and d['hold'] is True and d['reason'] == '5-hour window projected to 170% before its reset' and abs(d['modified'] - $(mt "$data/state/usage.json")) <= 1"
set_usage open
err P01-AC-6 POST /v1/throttle 405

# a later deploy line in beta's status log makes beta the repository of the last deploy
printf '2026-11-09T11:30:00Z deployed 4444444..5555555 (version v0.9.2-fixture)\n' >>"$data/state/beta/status.log"
get P01-AC-6 /v1/deploy deploy
chk P01-AC-6 "/v1/deploy gives the live checkout's head (the HEAD of the checkout api.py runs from)" "d['head'] == '$(git -C "$co" rev-parse HEAD)'"
chk P01-AC-6 "/v1/deploy gives the rollback point and the rejected commits" "d['previous'] == '1' * 40 and d['rejected'] == ['2' * 40, '3' * 40] and abs(d['modified'] - $(mt "$data/deploy/previous")) <= 1"
chk P01-AC-6 "/v1/deploy gives the last deploy as the status logs record it (the latest over all repositories)" "d['last_deploy'] == {'repo': 'acme/beta', 'time': $(ep 2026-11-09T11:30:00Z), 'line': 'deployed 4444444..5555555 (version v0.9.2-fixture)'}"
chk P01-AC-6 "/v1/deploy gives the last failed test run as the status logs record it" "d['last_failed'] == {'repo': 'acme/alpha', 'time': $(ep 2026-11-09T09:04:00Z), 'line': 'not deployed: 2222222222222222222222222222222222222222 (version v0.9.1-fixture) fails make test'}"
err P01-AC-6 PUT /v1/deploy 405

get P01-AC-6 /v1/repos/acme/alpha/prs prs
chk P01-AC-6 "alpha's /prs gives number, branch, head, bot and mergeable of each open PR, MERGEABLE and CONFLICTING" "{p['number']: (p['branch'], p['head'], p['bot'], p['mergeable']) for p in d['prs']} == {12: ('node/N02-pr-open-one', 'a' * 40, False, 'MERGEABLE'), 14: ('node/N11-pr-conflict-one', 'b' * 40, False, 'CONFLICTING'), 15: ('spec/triage-9-new-idea', 'c' * 40, True, 'CONFLICTING'), 16: ('spec/triage-8-other', 'd' * 40, True, 'MERGEABLE')} and len(d['prs']) == 4 and [p['number'] for p in d['prs']] == [12, 14, 15, 16]"
chk P01-AC-6 "alpha's /prs carries the mtime of open-prs.tsv" "abs(d['modified'] - $(mt "$data/state/alpha/open-prs.tsv")) <= 1"
get P01-AC-6 /v1/repos/acme/beta/prs prs
chk P01-AC-6 "beta's /prs is empty (its open-prs.tsv is)" "d['prs'] == []"
err P01-AC-6 GET /v1/repos/acme/ghost/prs 404
err P01-AC-6 POST /v1/repos/acme/alpha/prs 405

# two more issue folders, made here and removed below: 30 waits for an answer, 31 failed
mkdir -p "$a/issue/30" "$a/issue/31"
echo "Which format?" >"$a/issue/30/QUESTION.md"; echo "triage failed twice" >"$a/issue/31/FAILED"
get P01-AC-6 /v1/repos/acme/alpha/issues issues
chk P01-AC-6 "alpha's /issues gives the labelled issues of issues.json with title and labelled, and the state of the ones with a folder (8 done, 9 running)" "{i['number']: (i['title'], i['labelled'], i['state']) for i in d['issues'] if i['number'] in (8, 9)} == {8: ('Add a dark mode', True, 'done'), 9: ('Support export to CSV', True, 'running')}"
chk P01-AC-6 "alpha's /issues gives an issue folder with an unanswered QUESTION.md the state question, and one with FAILED the state failed" "{i['number']: i['state'] for i in d['issues'] if i['number'] in (30, 31)} == {30: 'question', 31: 'failed'}"
chk P01-AC-6 "alpha's /issues lists each issue once, and not the issue the owner did not label (10)" "sorted(i['number'] for i in d['issues']) == [8, 9, 30, 31]"
chk P01-AC-6 "alpha's /issues carries the mtime of issues.json" "abs(d['modified'] - $(mt "$data/state/alpha/issues.json")) <= 1"
rm -rf "$a/issue/30" "$a/issue/31"
get P01-AC-6 /v1/repos/acme/alpha/issues issues
chk P01-AC-6 "alpha's /issues drops a folder once it is gone" "sorted(i['number'] for i in d['issues']) == [8, 9]"
get P01-AC-6 /v1/repos/acme/beta/issues issues
chk P01-AC-6 "beta's /issues is empty" "d['issues'] == []"
err P01-AC-6 GET /v1/repos/acme/ghost/issues 404
err P01-AC-6 DELETE /v1/repos/acme/alpha/issues 405
for res in throttle deploy prs issues; do
	req GET /v1/schema/$res
	if [ "$code" = 200 ] && [ -f "$schemas/$res.json" ] && python3 -I -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])) == json.load(open(sys.argv[2])) else 1)' "$tmp/resp" "$schemas/$res.json" 2>/dev/null; then pass "P01-AC-8: /v1/schema/$res serves scheduler/api-schema/v1/$res.json"; else fail "P01-AC-8: /v1/schema/$res answered $code or differs from the committed schema"; fi
done

# ================= P01-AC-7: the event stream =================
# S4 contract: GET /v1/events[?repo=<owner>/<name>][&since=<cursor>], optional header Last-Event-ID: <cursor>. Answers 200 with
#  Content-Type text/event-stream and keeps the connection open. Each line appended to a listed repository's status.log is sent as
#  one event: a block of lines "id: <cursor>" and "data: <one-line JSON {"repo": "owner/name", "line": "<the whole log line,
#  timestamp included, redacted>"}" ended by an empty line. Comment lines (": ...") are keep-alives. The cursor is opaque (the
#  test never looks inside; it is the id of an event of this or an earlier connection, global over all repositories).
#  With a cursor the stream first sends every line after that cursor, once and in order, then goes on with new lines; without
#  one it starts at the end (no old lines). ?repo= filters events (and the lines after a cursor) to that repository.
cat >"$tmp/stream.py" <<'EOP'
import http.client, signal, socket, sys
sk, path, out, secs = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
class Stop(Exception): pass
def h(*a): raise Stop()
class C(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX); self.sock.connect(sk)
signal.signal(signal.SIGALRM, h); signal.alarm(secs)
f = open(out, "wb", buffering=0)
try:
    c = C("localhost")
    c.request("GET", path, headers={"Last-Event-ID": sys.argv[5]} if len(sys.argv) > 5 else {})
    r = c.getresponse()
    open(out + ".hdr", "w").write("%d\n%s\n" % (r.status, r.getheader("Content-Type")))
    while True:
        l = r.readline()
        if not l: break
        f.write(l)
except Exception:
    pass
EOP
cat >"$tmp/sse.py" <<'EOP'
import json, sys
ev, cur = [], {}
for l in open(sys.argv[1], encoding="utf-8", errors="replace").read().split("\n"):
    if l == "":
        if cur.get("id") is not None or cur.get("data") is not None:
            try: dd = json.loads(cur.get("data", ""))
            except Exception: dd = {}
            ev.append({"id": cur.get("id"), "repo": dd.get("repo"), "line": dd.get("line")})
        cur = {}
    elif l.startswith(":"): pass
    elif ":" in l:
        k, v = l.split(":", 1); cur[k] = v[1:] if v.startswith(" ") else v
print(json.dumps(ev))
EOP
evx() { python3 -I -c 'import json,sys
e = json.loads(sys.argv[1])
try: print(eval(sys.argv[2]))
except Exception as x: print("ERR", x)' "$(python3 -I "$tmp/sse.py" "$1")" "$2"; }
evn() { python3 -I "$tmp/sse.py" "$1" | python3 -I -c 'import json,sys; print(len(json.load(sys.stdin)))'; }
ev_open() { # ev_open <name> <path> [last-event-id]: a client in the background writing $tmp/ev.<name>; waits for the response head
	f=$tmp/ev.$1; : >"$f"; rm -f "$f.hdr"
	python3 -I "$tmp/stream.py" "$sock" "$2" "$f" 12 ${3:+"$3"} </dev/null >/dev/null 2>&1 &
	pids="$pids $!"; eval "ev_pid_$1=\$!"; i=0
	while [ $i -lt 30 ] && [ ! -s "$f.hdr" ]; do sleep 0.1; i=$((i + 1)); done
}
ev_wait() { # ev_wait <name> <count> <seconds>: until the client has that many events
	i=0; n=$(( $3 * 5 ))
	while [ $i -lt $n ] && [ "$(evn "$tmp/ev.$1")" -lt "$2" ]; do sleep 0.2; i=$((i + 1)); done
}
tok=$(sed -n 2p "$fix/tokens.txt")
A0="2026-11-09T11:00:00Z ev-test alpha before the client connects"
A1="2026-11-09T11:00:01Z ev-test alpha one" B1="2026-11-09T11:00:02Z ev-test beta one"
A2="2026-11-09T11:00:03Z ev-test alpha two $tok" A2r="2026-11-09T11:00:03Z ev-test alpha two [redacted]"
A3="2026-11-09T11:00:04Z ev-test alpha three" B2="2026-11-09T11:00:05Z ev-test beta two" A4="2026-11-09T11:00:06Z ev-test alpha four"
A5="2026-11-09T11:00:07Z ev-test alpha five" B3="2026-11-09T11:00:08Z ev-test beta three"
sl_a=$data/state/alpha/status.log sl_b=$data/state/beta/status.log
printf '%s\n' "$A0" >>"$sl_a"
ev_open c1 /v1/events
sleep 0.5
if [ "$(sed -n 1p "$tmp/ev.c1.hdr" 2>/dev/null)" = 200 ] && sed -n 2p "$tmp/ev.c1.hdr" | grep -qi '^text/event-stream'; then pass "P01-AC-7: GET /v1/events answers 200 text/event-stream"; else fail "P01-AC-7: GET /v1/events head: $(tr '\n' ' ' <"$tmp/ev.c1.hdr" 2>/dev/null)"; fi
printf '%s\n' "$A1" >>"$sl_a"; printf '%s\n' "$B1" >>"$sl_b"; printf '%s\n' "$A2" >>"$sl_a"
ev_wait c1 3 5
if [ "$(evx "$tmp/ev.c1" "[(x['repo'], x['line']) for x in e]")" = "[('acme/alpha', '$A1'), ('acme/beta', '$B1'), ('acme/alpha', '$A2r')]" ]; then pass "P01-AC-7: a connected client gets each appended line within 5 s, in order, as one event with its repository and the (redacted) line"; else fail "P01-AC-7: events of the connected client: $(evx "$tmp/ev.c1" "[(x['repo'], x['line']) for x in e]")"; fi
if [ "$(evx "$tmp/ev.c1" "len(e) == 3 and all(isinstance(x['id'], str) and x['id'] != '' for x in e) and len(set(x['id'] for x in e)) == 3")" = True ]; then pass "P01-AC-7: each event has its own non-empty id"; else fail "P01-AC-7: ids: $(evx "$tmp/ev.c1" "[x['id'] for x in e]")"; fi
if ! grep -q 'before the client connects' "$tmp/ev.c1" && ! grep -q 'loop started' "$tmp/ev.c1"; then pass "P01-AC-7: without a cursor the stream starts at the end (no old lines)"; else fail "P01-AC-7: the stream without a cursor sent old lines"; fi
id_b1=$(evx "$tmp/ev.c1" "e[1]['id']"); id_a2=$(evx "$tmp/ev.c1" "e[2]['id']")
kill "$ev_pid_c1" 2>/dev/null; wait "$ev_pid_c1" 2>/dev/null
# while away: A3 B2 A4. Then three clients reconnect with the ids, and a fourth filters by repository.
printf '%s\n' "$A3" >>"$sl_a"; printf '%s\n' "$B2" >>"$sl_b"; printf '%s\n' "$A4" >>"$sl_a"
q_a2=$(python3 -I -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$id_a2")
q_b1=$(python3 -I -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$id_b1")
ev_open c2 "/v1/events?since=$q_a2"
ev_open c3 /v1/events "$id_b1"
ev_open c4 "/v1/events?repo=acme/beta"
ev_open c5 "/v1/events?repo=acme/beta&since=$q_b1"
sleep 0.5
printf '%s\n' "$A5" >>"$sl_a"; printf '%s\n' "$B3" >>"$sl_b"
ev_wait c2 5 5; ev_wait c3 6 5; ev_wait c5 2 5; ev_wait c4 1 5
sleep 1.2
if [ "$(evx "$tmp/ev.c2" "[(x['repo'], x['line']) for x in e]")" = "[('acme/alpha', '$A3'), ('acme/beta', '$B2'), ('acme/alpha', '$A4'), ('acme/alpha', '$A5'), ('acme/beta', '$B3')]" ]; then pass "P01-AC-7: reconnecting with ?since= gets the lines appended while away, then the new ones, each once and in order (none lost, none repeated)"; else fail "P01-AC-7: ?since= events: $(evx "$tmp/ev.c2" "[(x['repo'], x['line'][-22:]) for x in e]")"; fi
if [ "$(evx "$tmp/ev.c3" "[(x['repo'], x['line']) for x in e]")" = "[('acme/alpha', '$A2r'), ('acme/alpha', '$A3'), ('acme/beta', '$B2'), ('acme/alpha', '$A4'), ('acme/alpha', '$A5'), ('acme/beta', '$B3')]" ]; then pass "P01-AC-7: reconnecting with a Last-Event-ID header gets every later line, each once and in order"; else fail "P01-AC-7: Last-Event-ID events: $(evx "$tmp/ev.c3" "[(x['repo'], x['line'][-22:]) for x in e]")"; fi
if [ "$(evx "$tmp/ev.c4" "[(x['repo'], x['line']) for x in e]")" = "[('acme/beta', '$B3')]" ]; then pass "P01-AC-7: ?repo=acme/beta sends beta's lines only (and starts at the end)"; else fail "P01-AC-7: ?repo= events: $(evx "$tmp/ev.c4" "[(x['repo'], x['line'][-22:]) for x in e]")"; fi
if [ "$(evx "$tmp/ev.c5" "[(x['repo'], x['line']) for x in e]")" = "[('acme/beta', '$B2'), ('acme/beta', '$B3')]" ]; then pass "P01-AC-7: ?repo= with ?since= sends beta's lines after the cursor only"; else fail "P01-AC-7: ?repo=&since= events: $(evx "$tmp/ev.c5" "[(x['repo'], x['line'][-22:]) for x in e]")"; fi
for c in c2 c3 c4 c5; do eval "p=\$ev_pid_$c"; kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; cat "$tmp/ev.$c" >>"$tmp/allresp"; done
cat "$tmp/ev.c1" >>"$tmp/allresp"
err P01-AC-7 POST /v1/events 405
# ---- P01-AC-5, real CLI stream-json shapes (added after the S3 review): background tasks and usage-limit warnings ----
# Session logs here use the shapes of the real Claude Code CLI: a Bash background start answers "Command running in background with
# ID: <id>. Output is being written to: <path>" (the id is followed by a period; the content is a plain string); an Agent background
# start answers a list of text blocks whose text ends with a line "agentId: <id> (use SendMessage ...)" (no "ID:"); the end of a
# task is {"type":"system","subtype":"task_notification","task_id":...,"tool_use_id":...,"status":"completed"}. The id of a
# Bash task equals its task_id; an Agent task's notification may carry only the tool_use_id of the Agent call (task_id differs).
# A rate_limit_event with status "allowed_warning" is a warning, not a rejection: it is no "limit". Made here, removed below.
mkdir -p "$a/pr/17" "$a/issue/21" "$a/issue/22"
cat >"$a/pr/17/session.jsonl" <<'EOT'
{"type":"system","subtype":"init","timestamp":"2026-11-09T10:00:00Z"}
{"type":"assistant","timestamp":"2026-11-09T10:01:00Z","message":{"content":[{"type":"tool_use","id":"toolu_bgrun","name":"Bash","input":{"command":"sleep 900","description":"Watch the slow build","run_in_background":true}}]}}
{"type":"user","timestamp":"2026-11-09T10:01:01Z","message":{"role":"user","content":[{"tool_use_id":"toolu_bgrun","type":"tool_result","content":"Command running in background with ID: bqx7run01. Output is being written to: /tmp/x/tasks/bqx7run01.output If it exits while you are still working you will be notified.","is_error":false}]}}
{"type":"assistant","timestamp":"2026-11-09T10:02:00Z","message":{"content":[{"type":"tool_use","id":"toolu_bgfin","name":"Bash","input":{"command":"make lint","description":"Lint in the background","run_in_background":true}}]}}
{"type":"user","timestamp":"2026-11-09T10:02:01Z","message":{"role":"user","content":[{"tool_use_id":"toolu_bgfin","type":"tool_result","content":"Command running in background with ID: bqx7fin02. Output is being written to: /tmp/x/tasks/bqx7fin02.output If it exits while you are still working you will be notified.","is_error":false}]}}
{"type":"assistant","timestamp":"2026-11-09T10:03:00Z","message":{"content":[{"type":"tool_use","id":"toolu_agrun","name":"Agent","input":{"description":"Review the running slice","prompt":"look","run_in_background":true}}]}}
{"type":"user","timestamp":"2026-11-09T10:03:01Z","message":{"role":"user","content":[{"tool_use_id":"toolu_agrun","type":"tool_result","content":[{"type":"text","text":"Async agent launched successfully.\nagentId: aqx7run03 (use SendMessage with to: 'aqx7run03' to continue this agent)\nThe agent is working in the background."}]}]}}
{"type":"assistant","timestamp":"2026-11-09T10:04:00Z","message":{"content":[{"type":"tool_use","id":"toolu_agfin","name":"Agent","input":{"description":"Review the finished slice","prompt":"look","run_in_background":true}}]}}
{"type":"user","timestamp":"2026-11-09T10:04:01Z","message":{"role":"user","content":[{"tool_use_id":"toolu_agfin","type":"tool_result","content":[{"type":"text","text":"Async agent launched successfully.\nagentId: aqx7fin04 (use SendMessage with to: 'aqx7fin04' to continue this agent)\nThe agent is working in the background."}]}]}}
{"type":"system","subtype":"task_notification","task_id":"bqx7fin02","run_id":"r1","tool_use_id":"toolu_other","status":"completed","output_file":"","summary":"Lint"}
{"type":"system","subtype":"task_notification","task_id":"tsk-differs","run_id":"r2","tool_use_id":"toolu_agfin","status":"completed","output_file":"","summary":"Review"}
EOT
cat >"$a/issue/21/session.jsonl" <<'EOT'
{"type":"system","subtype":"init","timestamp":"2026-11-09T11:00:00Z"}
{"type":"assistant","timestamp":"2026-11-09T11:01:00Z","message":{"content":[{"type":"tool_use","id":"w21","name":"Bash","input":{"command":"ls","description":"List"}}]}}
{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":1794228000,"rateLimitType":"five_hour","utilization":0.9}}
EOT
cat >"$a/issue/22/session.jsonl" <<'EOT'
{"type":"system","subtype":"init","timestamp":"2026-11-09T12:00:00Z"}
{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1794200000,"rateLimitType":"five_hour"}}
{"type":"assistant","timestamp":"2026-11-09T12:01:00Z","message":{"content":[{"type":"tool_use","id":"w22","name":"Bash","input":{"command":"ls","description":"List"}}]}}
{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":1794228000,"rateLimitType":"five_hour"}}
EOT
ended "$a/pr/17"; ended "$a/issue/21"; ended "$a/issue/22"
touch -d 2026-11-09T10:00:00Z "$a/pr/17/session.pid" "$a/issue/21/session.pid" "$a/issue/22/session.pid"
get P01-AC-5 /v1/repos/acme/alpha/sessions sessions; cp "$tmp/resp" "$tmp/sessions.json"
sess_is update 17 "sorted((b.get('id'), b.get('text')) for b in (s.get('bg_commands') or [])) == [('bqx7run01', 'Watch the slow build')]" "lists the running Bash background command by its id without the period, and not the one ended by task_id"
sess_is update 17 "sorted((b.get('id'), b.get('text')) for b in (s.get('bg_agents') or [])) == [('aqx7run03', 'Review the running slice')]" "lists the running background Agent by its agentId, and not the one ended by tool_use_id alone"
sess_is triage 21 "not s.get('limit')" "ending with an allowed_warning rate_limit_event has no limit"
sess_is triage 22 "(s.get('limit') or {}).get('resets_at') == 1794200000" "gives as limit its last rejection (not a later allowed_warning)"
rm -rf "$a/pr/17" "$a/issue/21" "$a/issue/22"

# ---- P01-AC-6/7 cases added after the S4 review ----
# (1) /issues: an issue/<N>/ folder as the loop leaves a finished triage (triage_ended): an ended session, session.rc 0, no done marker
# (the loop writes none for issues), no QUESTION.md and no FAILED is "done"; the same with a non-zero session.rc is not "done".
mkdir -p "$a/issue/40" "$a/issue/41"
ended "$a/issue/40"; ended "$a/issue/41"
echo 0 >"$a/issue/40/session.rc"; echo 1 >"$a/issue/41/session.rc"
touch -d 2026-11-09T10:00:00Z "$a/issue/40/session.pid" "$a/issue/41/session.pid"
get P01-AC-6 /v1/repos/acme/alpha/issues issues
chk P01-AC-6 "alpha's /issues gives a finished triage (ended session, session.rc 0, no markers, no done file) the state done" "{i['number']: i['state'] for i in d['issues'] if i['number'] == 40} == {40: 'done'}"
chk P01-AC-6 "alpha's /issues does not give an ended session with a non-zero session.rc and no markers the state done" "{i['number']: i['state'] for i in d['issues'] if i['number'] == 41}.get(41) != 'done' and 41 in [i['number'] for i in d['issues']]"
rm -rf "$a/issue/40" "$a/issue/41"
# (6) a triage whose question the owner has answered (QUESTION.md and ANSWER.md, the loop has not restarted it yet) with session.rc 0
# is not a finished triage: not "done" (triage_ended), and still listed.
mkdir -p "$a/issue/42"
ended "$a/issue/42"; echo 0 >"$a/issue/42/session.rc"
printf 'Which one?\n' >"$a/issue/42/QUESTION.md"; printf 'This one.\n' >"$a/issue/42/ANSWER.md"
touch -d 2026-11-09T10:00:00Z "$a/issue/42/session.pid"
get P01-AC-6 /v1/repos/acme/alpha/issues issues
chk P01-AC-6 "alpha's /issues does not give an answered question (QUESTION.md and ANSWER.md, session.rc 0) the state done, and lists it" "{i['number']: i['state'] for i in d['issues'] if i['number'] == 42}.get(42) not in (None, 'done')"
rm -rf "$a/issue/42"
# (5) /deploy: deploy.sh's "not deployed: <sha> (version <v>) cannot fast-forward <live> (will retry ...)" line is no failed test run
printf '2026-11-09T11:40:00Z not deployed: 6666666666666666666666666666666666666666 (version v0.9.3-fixture) cannot fast-forward 7777777777777777777777777777777777777777 (will retry the fast-forward)\n' >>"$data/state/alpha/status.log"
get P01-AC-6 /v1/deploy deploy
chk P01-AC-6 "/v1/deploy does not take a 'cannot fast-forward' line as the last failed test run (last_failed stays the 'fails make test' line)" "d['last_failed'] == {'repo': 'acme/alpha', 'time': $(ep 2026-11-09T09:04:00Z), 'line': 'not deployed: 2222222222222222222222222222222222222222 (version v0.9.1-fixture) fails make test'}"
# (3) AC-7 race: a line appended the moment the client has the response head is delivered (the server takes its start positions
# before it sends the head). race.py appends the line itself right after getresponse(), with no pause, and waits up to 3 s for it.
cat >"$tmp/race.py" <<'EOP'
import http.client, socket, sys, time
sk, log, line = sys.argv[1], sys.argv[2], sys.argv[3]
class C(http.client.HTTPConnection):
    def connect(self):
        self.sock = S = socket.socket(socket.AF_UNIX); self.sock.connect(sk)
S = None
try:
    c = C("localhost"); c.request("GET", "/v1/events"); S = c.sock; r = c.getresponse()
    with open(log, "a") as f: f.write(line + "\n")
    S.settimeout(3); end = time.time() + 3; buf = b""
    while time.time() < end and line.encode() not in buf:
        l = r.readline()
        if not l: break
        buf += l
    print("OK" if line.encode() in buf else "MISS")
except Exception as e:
    print("ERR", e)
EOP
race_ok=0
for n in 1 2 3 4 5; do
	r=$(python3 -I "$tmp/race.py" "$sock" "$sl_a" "2026-11-09T11:5$n:00Z ev-test alpha race $n" 2>&1)
	[ "$r" = OK ] && race_ok=$((race_ok + 1))
done
if [ $race_ok = 5 ]; then pass "P01-AC-7: a line appended right after the response head is delivered (5 of 5 connects)"; else fail "P01-AC-7: a line appended right after the response head was lost ($race_ok of 5 connects delivered it)"; fi

snap >"$tmp/snap.before"   # the test appended to the status logs: re-take the AC-2 baseline

# AC-2 end-of-test checks: later slices append their cases ABOVE this block (marked by the line below).
# ================= P01-AC-9: no tokens (FINAL CHECK: later slices put their cases ABOVE this block) =================
# What it fixes: the tokens of scheduler/testdata/api/tokens.txt (planted in session logs and status logs) appear in no
# response of the whole test (every response made since the sessions cases is in $tmp/allresp; the block re-requests every
# resource of the slices so far, and probes /v1/events, the status-log-backed resource a later slice adds) and not in the
# server's output; [redacted] shows where a token was; the token script was never run; and the server never reads a file
# under ~/.config/noodlebot/ other than repos. Slices that add resources append their requests to the list below.
# How "never reads" is checked: the server is restarted, and two FIFOs (credentials, github-token) are created next to
# repos in ~/.config/noodlebot/. A process opening a FIFO for reading releases a writer that waits on it; the writer then
# creates a marker file. So any open() of those files, at start or while serving, shows. (A mode 000 file would only make
# a read fail quietly; and a FIFO may not be left for the AC-2 snapshot, whose cksum would block on it: the FIFOs are
# removed again before the snapshot below.) The fixture's token script is checked by its never-run marker.
kill -9 "$srv_pid" 2>/dev/null; wait "$srv_pid" 2>/dev/null; srv_pid=''
cfg=$home/.config/noodlebot; fifo_pids=''
for f in credentials github-token; do
	mkfifo "$cfg/$f"
	( : >"$cfg/$f"; : >"$tmp/fifo-read-$f" ) </dev/null >/dev/null 2>&1 &
	fifo_pids="$fifo_pids $!"
done
if start_server; then pass "P01-AC-9: api.py starts with unreadable-by-blocking files next to repos"; else fail "P01-AC-9: api.py did not start (or blocked) with the FIFOs in ~/.config/noodlebot: $(tail -c 200 "$tmp/api.out")"; fi
for path in /v1/repos /v1/repos/acme/alpha /v1/repos/acme/beta /v1/repos/acme/alpha/nodes /v1/repos/acme/beta/nodes /v1/repos/acme/alpha/sessions /v1/repos/acme/beta/sessions /v1/schema/repos /v1/schema/repo /v1/schema/nodes /v1/schema/node /v1/schema/sessions; do
	req GET $path
done
for id in N01 N02 N03 N04 N05 N06 N07 N08 N09 N10 N11; do req GET /v1/repos/acme/alpha/nodes/$id; done
for id in B01 B02; do req GET /v1/repos/acme/beta/nodes/$id; done
req GET /v1/nothing; req POST /v1/repos
# the event stream stays open: read it for 2 seconds from the first line of each status log (a later slice's resource)
if command -v curl >/dev/null 2>&1; then
	for q in 'since=0' 'repo=acme/alpha&since=0' 'repo=acme/beta&since=0'; do
		curl -s --max-time 2 --unix-socket "$sock" "http://localhost/v1/events?$q" >>"$tmp/allresp" 2>/dev/null
	done
fi
sleep 1
for f in credentials github-token; do
	if [ ! -e "$tmp/fifo-read-$f" ]; then pass "P01-AC-9: the server never opened ~/.config/noodlebot/$f"; else fail "P01-AC-9: the server opened ~/.config/noodlebot/$f"; fi
done
for p in $fifo_pids; do kill -9 "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
rm -f "$cfg/credentials" "$cfg/github-token"
if [ ! -e "$home/token-was-run" ]; then pass "P01-AC-9: the token script ~/.config/noodlebot/token was never run"; else fail "P01-AC-9: the token script was run"; fi
if [ -s "$tmp/allresp" ] && grep -q 'ScheduleWakeup' "$tmp/allresp" && grep -q 'Run the tests' "$tmp/allresp"; then pass "P01-AC-9: the responses were recorded ($(wc -c <"$tmp/allresp") bytes, served session events among them)"; else fail "P01-AC-9: no recorded responses to scan"; fi
while IFS= read -r tok; do
	[ -n "$tok" ] || continue
	if grep -F -q -e "$tok" "$tmp/allresp" "$tmp/api.out" "$tmp/second.out"; then fail "P01-AC-9: token ${tok%"${tok#????}"}... appears in a response or in the server's output"; else pass "P01-AC-9: token ${tok%"${tok#????}"}... appears in no response and not in the server's output"; fi
done <"$fix/tokens.txt"
# the redaction shows: the response that held the key (re-requested here) has [redacted] where it was
req GET /v1/repos/acme/alpha/sessions
if [ "$(jx "any('[redacted]' in (e.get('text') or '') for x in d['sessions'] for e in x['events'])")" = True ]; then pass "P01-AC-9: [redacted] replaces the token where a session log held one"; else fail "P01-AC-9: no [redacted] in the sessions response"; fi
# ---- P01-AC-9/7: ?since=0 streams from the first line of every status log, redacted ----
rm -f "$tmp/since0" "$tmp/since0.hdr" "$tmp/since0b" "$tmp/since0b.hdr"
python3 -I "$tmp/stream.py" "$sock" "/v1/events?since=0" "$tmp/since0" 2 </dev/null >/dev/null 2>&1
python3 -I "$tmp/stream.py" "$sock" "/v1/events?repo=acme/beta&since=0" "$tmp/since0b" 2 </dev/null >/dev/null 2>&1
cat "$tmp/since0" "$tmp/since0b" >>"$tmp/allresp"
if [ "$(evx "$tmp/since0" "any(x['repo'] == 'acme/alpha' and x['line'] == '$(sed -n 1p "$fix/data/state/alpha/status.log")' for x in e)")" = True ]; then pass "P01-AC-7: ?since=0 streams from the first line of a status log (alpha's loop-started line arrives)"; else fail "P01-AC-7: ?since=0 did not stream alpha's first status line (head $(sed -n 1p "$tmp/since0.hdr" 2>/dev/null), $(evn "$tmp/since0") events)"; fi
if [ "$(evx "$tmp/since0b" "len(e) > 0 and all(x['repo'] == 'acme/beta' for x in e) and any(x['line'] == '$(sed -n 1p "$fix/data/state/beta/status.log")' for x in e)")" = True ]; then pass "P01-AC-7: ?repo=acme/beta&since=0 streams beta's lines from the first, and only beta's"; else fail "P01-AC-7: ?repo=&since=0 events: $(evn "$tmp/since0b") (head $(sed -n 1p "$tmp/since0b.hdr" 2>/dev/null))"; fi
if [ "$(evx "$tmp/since0" "any('[redacted]' in x['line'] for x in e)")" = True ]; then pass "P01-AC-9: the token-shaped strings in the status logs are served redacted in a ?since=0 event"; else fail "P01-AC-9: no [redacted] in a ?since=0 event (the stream gave $(evn "$tmp/since0") events)"; fi
while IFS= read -r tok; do
	[ -n "$tok" ] || continue
	if [ "$(evn "$tmp/since0")" -gt 0 ] && ! grep -F -q -e "$tok" "$tmp/since0"; then pass "P01-AC-9: token ${tok%"${tok#????}"}... is in no ?since=0 event"; else fail "P01-AC-9: token ${tok%"${tok#????}"}... appears in a ?since=0 event, or the stream gave no events"; fi
done <"$fix/tokens.txt"
# ---- P01-AC-2: the read-only resources of S4 are requested after the last baseline re-take, so "changes nothing" covers them ----
req GET /v1/throttle; req GET /v1/deploy; req GET /v1/repos/acme/alpha/prs; req GET /v1/repos/acme/alpha/issues
if [ "$code" = 200 ]; then pass "P01-AC-2: throttle, deploy, prs and issues were requested after the last baseline (the snapshot below covers them)"; else fail "P01-AC-2: GET /v1/repos/acme/alpha/issues answered $code"; fi
# ================= P01 fresh review 1: a second root (its own data, HOME and checkout) =================
# Cases for the review findings; a separate root so the fixture, its node list and the AC-2 snapshot stay as they are.
#  A  P01-AC-1: api.py started on a checkout that is no git repository (HEAD unreadable); later the checkout becomes a
#     repository with a commit: the server serves from it within the check interval and its watcher does not crash.
#  B  P01-AC-4: idle-limit as S06's idle_tail reads it (scheduler/loop.sh).
#  C  P01-AC-9 / AC-8: a token in a tool_use name or a result subtype never shows; a tool_use without a name and a
#     string or float resetsAt still give a /sessions response valid against its schema.
#  D  P01-AC-4: a question without node/<ID>/issue links to the status issue of report.json.
r2=$tmp/r2; r2data=$r2/data; r2home=$r2/home; r2co=$r2/co; r2sock=$r2data/api.sock; r2pid=''
mkdir -p "$r2data" "$r2home" "$r2co/scheduler"
cp -R "$fix/data/." "$r2data/"; cp -R "$fix/home/." "$r2home/"
for f in "$src"/*; do case $f in "$src/testdata") ;; *) cp -R "$f" "$r2co/scheduler/" ;; esac; done
cat >"$tmp/c2.py" <<'EOP'
import http.client, socket, sys
class C(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX); self.sock.settimeout(10); self.sock.connect(sys.argv[1])
try:
    c = C("localhost"); c.request("GET", sys.argv[2]); r = c.getresponse(); b = r.read()
    open(sys.argv[3], "wb").write(b); print(r.status)
except Exception:
    open(sys.argv[3], "wb").write(b""); print("000")
EOP
req2() { code=$(python3 -I "$tmp/c2.py" "$r2sock" "$1" "$tmp/resp" 2>/dev/null); [ -n "$code" ] || code=000; }
r2a=$r2data/state/alpha
rm -rf "$r2a/node" "$r2a/issue" "$r2a/pr"; mkdir -p "$r2a/node" "$r2a/issue" "$r2a/pr"
{
	echo "template: {headings: [Purpose, Tests, Changes, Gate, Risks]}"; echo "nodes:"
	for id in L01 L02 L03 L05 L06 L07 L08 Q01; do echo "  - {id: $id, track: now, name: fr1-$id, deps: [], summary: \"fr1\"}"; done
} >"$r2a/graph.yaml"
sinit='{"type":"system","subtype":"init","timestamp":"2026-11-09T09:01:05Z","session_id":"sess-fr1"}'
tooluse='{"type":"assistant","timestamp":"2026-11-09T09:30:00Z","message":{"content":[{"type":"tool_use","id":"u01","name":"Bash","input":{"command":"make test","description":"Run the tests"}}]}}'
rl() { # rl <status> <resetsAt json or ->: a rate_limit_event line
	if [ "$2" = - ]; then printf '{"type":"rate_limit_event","timestamp":"2026-11-09T10:40:00Z","rate_limit_info":{"status":"%s","rateLimitType":"five_hour"}}\n' "$1"
	else printf '{"type":"rate_limit_event","timestamp":"2026-11-09T10:40:00Z","rate_limit_info":{"status":"%s","rateLimitType":"five_hour","resetsAt":%s}}\n' "$1" "$2"; fi
}
mk() { mkdir -p "$r2a/node/$1"; echo 1 >"$r2a/node/$1/starts"; }
# B: live sessions
for id in L01 L02 L03; do mk $id; done
{ echo "$sinit"; echo "$tooluse"; rl allowed_warning 1794236400; } >"$r2a/node/L01/session.jsonl"
{ echo "$sinit"; rl allowed 1794236400; echo "$tooluse"; rl rejected -; } >"$r2a/node/L02/session.jsonl"
{ echo "$sinit"; rl rejected 1794236400; echo "$tooluse"
  echo '{"type":"result","subtype":"success","timestamp":"2026-11-09T10:45:00Z","result":"You have hit your usage limit; it resets at 5pm","is_error":true}'; } >"$r2a/node/L03/session.jsonl"
for id in L01 L02 L03; do live "$r2a/node/$id" /w/r2/$id /noodlebot:node $id; done
# C: ended sessions with odd logs
tok1=$(sed -n 2p "$fix/tokens.txt"); tok2=$(sed -n 6p "$fix/tokens.txt")
for id in L05 L06 L07 L08; do mk $id; done
{ echo "$sinit"
  printf '{"type":"assistant","timestamp":"2026-11-09T09:30:00Z","message":{"content":[{"type":"tool_use","id":"u01","name":"%s","input":{"command":"x"}}]}}\n' "$tok1"
  printf '{"type":"result","subtype":"%s","timestamp":"2026-11-09T09:40:00Z","result":"done"}\n' "$tok2"; } >"$r2a/node/L05/session.jsonl"
{ echo "$sinit"
  echo '{"type":"assistant","timestamp":"2026-11-09T09:30:00Z","message":{"content":[{"type":"tool_use","id":"u01","input":{"command":"x"}}]}}'; } >"$r2a/node/L06/session.jsonl"
{ echo "$sinit"; echo '{"type":"assistant","timestamp":"2026-11-09T09:30:00Z","message":{"content":[{"type":"tool_use","id":"u01","input":{"command":"x"}}]}}'
  rl rejected '"1794236400"'; } >"$r2a/node/L07/session.jsonl"
{ echo "$sinit"; rl rejected 1794236400.5; } >"$r2a/node/L08/session.jsonl"
for id in L05 L06 L07 L08; do ended "$r2a/node/$id"; done
# D: a question with no node/<ID>/issue
mk Q01; echo 'Which cache?' >"$r2a/node/Q01/QUESTION.md"

# A: start on a checkout that is no git repository
GIT_CEILING_DIRECTORIES=$r2; export GIT_CEILING_DIRECTORIES
NOODLEBOT_DATA=$r2data HOME=$r2home python3 "$r2co/scheduler/api.py" >"$tmp/r2.out" 2>&1 &
r2pid=$!; pids="$pids $r2pid"
i=0; r2up=0
while [ $i -lt 60 ] && kill -0 "$r2pid" 2>/dev/null; do
	[ -S "$r2sock" ] && { req2 /v1/repos; [ "$code" = 200 ] && { r2up=1; break; }; }
	sleep 0.1; i=$((i + 1))
done
if [ $r2up = 1 ]; then pass "P01-AC-1: api.py serves on a checkout that is no git repository (HEAD unreadable)"; else fail "P01-AC-1: api.py did not serve on a checkout without a git repository: $(head -c 200 "$tmp/r2.out")"; fi
sleep 3   # more than one check interval with HEAD still unreadable
mkdir -p "$r2co/scheduler/api-schema/v1"
python3 -I -c 'import json,os,sys
p = sys.argv[1]
s = json.load(open(p)) if os.path.exists(p) else {"type": "object"}
s["description"] = "moved from unreadable"
json.dump(s, open(p, "w"), indent=1)' "$r2co/scheduler/api-schema/v1/repos.json"
# a schema file is read per request: api.py's own 404 text gets a marker that only a re-exec can show
sed -i 's/"not found: "/"not found [unreadable-head-marker]: "/' "$r2co/scheduler/api.py"
git -C "$r2co" init -q 2>/dev/null
git -C "$r2co" add -A >/dev/null 2>&1
git -C "$r2co" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m first >/dev/null 2>&1
moved3=0; i=0
while [ $i -lt 100 ] && [ $r2up = 1 ]; do
	req2 /v1/head-moved-probe
	if [ "$code" = 404 ] && [ "$(jx "'unreadable-head-marker' in d.get('error', '')")" = True ]; then moved3=1; break; fi
	sleep 0.2; i=$((i + 1))
done
if [ $moved3 = 1 ]; then pass "P01-AC-1: a server started with HEAD unreadable serves from the commit once HEAD is readable"; else fail "P01-AC-1: a server started with HEAD unreadable did not serve from the first commit of the checkout"; fi
sleep 3   # past another check interval: a crashed watcher has printed its traceback by now
if [ $r2up = 1 ] && ! grep -q 'Traceback' "$tmp/r2.out"; then pass "P01-AC-1: the HEAD watcher did not crash when HEAD was unreadable at start"; else fail "P01-AC-1: the server's output holds a Traceback: $(grep -m1 -A0 -E 'Error|Traceback' "$tmp/r2.out" | head -c 200)"; fi

# B: idle-limit as S06 reads it
req2 /v1/repos/acme/alpha/nodes; cp "$tmp/resp" "$tmp/r2nodes.json"
r2node() { # r2node <ID> <expr over n>
	cp "$tmp/r2nodes.json" "$tmp/resp"; nodefield "$1" "$2"
}
st() { r2node "$1" "n['state']"; }
if [ "$(st L01)" = idle-limit ]; then pass "P01-AC-4: a live session whose log ends at an allowed_warning event with a numeric resetsAt is idle-limit (as S06 reads it)"; else fail "P01-AC-4: allowed_warning with resetsAt as the last line: state is $(st L01), not idle-limit"; fi
if [ "$(st L02)" = running ]; then pass "P01-AC-4: a live session whose log ends at a rejected event without resetsAt is running, not idle-limit"; else fail "P01-AC-4: rejected without resetsAt as the last line: state is $(st L02), not running"; fi
if [ "$(st L03)" = idle-limit ]; then pass "P01-AC-4: a live session whose log ends at a result naming the usage limit, after a rejected event with resetsAt, is idle-limit"; else fail "P01-AC-4: result naming the usage limit as the last line: state is $(st L03), not idle-limit"; fi
# D
if [ "$(r2node Q01 "n['state'] == 'question' and n['issue_url'] == 'https://github.com/acme/alpha/issues/41'")" = True ]; then pass "P01-AC-4: a question without node/<ID>/issue links to the status issue of report.json"; else fail "P01-AC-4: question without its own issue: $(jx "[n for n in d['nodes'] if n.get('id') == 'Q01']")"; fi

# C: sessions
req2 /v1/repos/acme/alpha/sessions; cp "$tmp/resp" "$tmp/r2sessions.json"
if [ "$code" = 200 ] && [ -s "$tmp/r2sessions.json" ]; then
	if ! grep -F -q -e "$tok1" -e "$tok2" "$tmp/r2sessions.json"; then pass "P01-AC-9: a token in a tool_use name or a result subtype is in no /sessions response"; else fail "P01-AC-9: a token from a tool_use name or a result subtype appears in /sessions"; fi
	if python3 -I "$tmp/validate.py" "$schemas/sessions.json" "$tmp/r2sessions.json" >"$tmp/r2val" 2>&1; then pass "P01-AC-8: /sessions is valid against its schema with a nameless tool_use and a string or float resetsAt"; else fail "P01-AC-8: /sessions with a nameless tool_use or a string/float resetsAt is not valid against its schema: $(cat "$tmp/r2val")"; fi
	cp "$tmp/r2sessions.json" "$tmp/resp"
	if [ "$(jx "all('tool' not in e or isinstance(e['tool'], str) for x in d['sessions'] if x['subject'] == 'L06' for e in x['events'])")" = True ]; then pass "P01-AC-8: a tool_use without a name has no null tool"; else fail "P01-AC-8: a tool_use without a name gives a tool that is not a string"; fi
	if [ "$(jx "all(x['limit'] is None or (isinstance(x['limit']['resets_at'], int) and not isinstance(x['limit']['resets_at'], bool)) or x['limit']['resets_at'] is None for x in d['sessions'] if x['subject'] in ('L07', 'L08'))")" = True ]; then pass "P01-AC-8: limit.resets_at is an integer or null whatever the log's resetsAt was"; else fail "P01-AC-8: limit.resets_at is neither integer nor null: $(jx "[x['limit'] for x in d['sessions'] if x['subject'] in ('L07', 'L08')]")"; fi
else
	fail "P01-AC-9: GET /sessions of the second root answered $code"; fail "P01-AC-8: GET /sessions of the second root answered $code"
fi
kill -9 "$r2pid" 2>/dev/null; wait "$r2pid" 2>/dev/null
unset GIT_CEILING_DIRECTORIES

# --- end of cases; the final checks follow ---
snap >"$tmp/snap.after"
if [ $up = 1 ] && cmp -s "$tmp/snap.before" "$tmp/snap.after"; then pass "P01-AC-2: no file under the runtime root or HOME changed except the socket and the locks"; else fail "P01-AC-2: files changed or no server: $(diff "$tmp/snap.before" "$tmp/snap.after" | head -n 6 | tr '\n' ' ')"; fi
if [ $up = 1 ] && [ ! -s "$tmp/gh.log" ]; then pass "P01-AC-2: the fake gh recorded no call"; else fail "P01-AC-2: gh was called: $(head -n 3 "$tmp/gh.log" | tr '\n' ' ')"; fi
if [ $up = 1 ] && [ ! -e "$home/token-was-run" ]; then pass "P01-AC-2: the token script was never run"; else fail "P01-AC-2: the token script was run"; fi

[ $fails = 0 ] || { echo "$fails failed"; exit 1; }
echo "all passed"
