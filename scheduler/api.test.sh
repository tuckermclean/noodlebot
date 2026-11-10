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
	jx "[n for n in d['nodes'] if n['id'] == '$1'][0] and ($2)"
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
# --- end of cases; the final checks follow ---
snap >"$tmp/snap.after"
if [ $up = 1 ] && cmp -s "$tmp/snap.before" "$tmp/snap.after"; then pass "P01-AC-2: no file under the runtime root or HOME changed except the socket and the locks"; else fail "P01-AC-2: files changed or no server: $(diff "$tmp/snap.before" "$tmp/snap.after" | head -n 6 | tr '\n' ' ')"; fi
if [ $up = 1 ] && [ ! -s "$tmp/gh.log" ]; then pass "P01-AC-2: the fake gh recorded no call"; else fail "P01-AC-2: gh was called: $(head -n 3 "$tmp/gh.log" | tr '\n' ' ')"; fi
if [ $up = 1 ] && [ ! -e "$home/token-was-run" ]; then pass "P01-AC-2: the token script was never run"; else fail "P01-AC-2: the token script was run"; fi

[ $fails = 0 ] || { echo "$fails failed"; exit 1; }
echo "all passed"
