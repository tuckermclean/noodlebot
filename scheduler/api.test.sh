#!/bin/sh
# Tests scheduler/api.py, the read-only HTTP API on $NOODLEBOT_DATA/api.sock (node P01).
#   sh scheduler/api.test.sh   (make test)
# This part: the server, the repositories, HEAD moves, the nodes. The other parts run at the same time on their own fixture copy:
# api-sessions.test.sh (sessions, throttle, deploy, PRs, issues), api-events.test.sh (event stream, final AC-2/AC-9 checks),
# api-fifo.test.sh (AC-9: the files in ~/.config/noodlebot never opened), api-root2.test.sh (a second root).
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
tmp=$(mktemp -d)
. "$src/testdata/lib/api-common.sh"
. "$src/testdata/lib/api-setup.sh"

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
# the end-of-part checks. The PASS lines of the AC-2 snapshot, the fake gh and the token script, and of the AC-9 scan, are
# printed once, by api-events.test.sh (passdiff compares label counts); this part only prints a FAIL line, over its own run.
quiet_final

[ $fails = 0 ] || { echo "$fails failed"; exit 1; }
echo "all passed"
