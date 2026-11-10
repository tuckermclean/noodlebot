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

# AC-2 end-of-test checks: later slices append their cases ABOVE this block (marked by the line below).
# --- end of cases; the final checks follow ---
snap >"$tmp/snap.after"
if [ $up = 1 ] && cmp -s "$tmp/snap.before" "$tmp/snap.after"; then pass "P01-AC-2: no file under the runtime root or HOME changed except the socket and the locks"; else fail "P01-AC-2: files changed or no server: $(diff "$tmp/snap.before" "$tmp/snap.after" | head -n 6 | tr '\n' ' ')"; fi
if [ $up = 1 ] && [ ! -s "$tmp/gh.log" ]; then pass "P01-AC-2: the fake gh recorded no call"; else fail "P01-AC-2: gh was called: $(head -n 3 "$tmp/gh.log" | tr '\n' ' ')"; fi
if [ $up = 1 ] && [ ! -e "$home/token-was-run" ]; then pass "P01-AC-2: the token script was never run"; else fail "P01-AC-2: the token script was run"; fi

[ $fails = 0 ] || { echo "$fails failed"; exit 1; }
echo "all passed"
