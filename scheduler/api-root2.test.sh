#!/bin/sh
# Tests scheduler/api.py (node P01), part: the cases of the fresh review that run on a second root (its own
# data, HOME and checkout): HEAD unreadable at start, idle-limit, tokens in session logs, odd logs.
#   sh scheduler/api-root2.test.sh   (make test)
# api.test.sh holds the rest; the helpers are in testdata/lib/api-common.sh. The two run at the same time.
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d)
. "$src/testdata/lib/api-common.sh"

data=$tmp/data home=$tmp/home
mkdir -p "$data" "$home" "$tmp/bin" "$tmp/procs"
# A fake gh that records any call (the API must make none).
printf '#!/bin/sh\necho "$0 $*" >>"%s/gh.log"\nexit 1\n' "$tmp" >"$tmp/bin/gh"
chmod +x "$tmp/bin/gh"
export NOODLEBOT_DATA=$data HOME=$home NOODLEBOT_API_HEAD_CHECK=2 NOODLEBOT_API_KEEPALIVE=1
PATH=$tmp/bin:$PATH; export PATH

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
# P01-AC-2: the fake gh recorded no call during this part's run (the second-root server ran with it on PATH); FAIL-only,
# the PASS line is in api-events.test.sh
[ ! -s "$tmp/gh.log" ] || fail "P01-AC-2: gh was called: $(head -n 3 "$tmp/gh.log" | tr '\n' ' ')"

[ $fails = 0 ] || { echo "$fails failed"; exit 1; }
echo "all passed"
