#!/bin/sh
# Tests scheduler/api.py (node P01), part: the event stream (P01-AC-7), the cases added after the S3 and S4 reviews, and the end-of-test AC-2 and AC-9 checks that print PASS lines.
#   sh scheduler/api-events.test.sh   (make test)
# The parts api.test.sh, api-sessions.test.sh, api-events.test.sh, api-fifo.test.sh and api-root2.test.sh run at the same time, each on
# its own copy of the fixture and its own server; the helpers are in testdata/lib/api-common.sh and api-setup.sh.
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d)
. "$src/testdata/lib/api-common.sh"
. "$src/testdata/lib/api-setup.sh"
up=0
if start_server; then up=1; else fail "the server did not start: $(head -c 200 "$tmp/api.out")"; fi
record_all
# ================= P01-AC-7: the event stream =================
# S4 contract: GET /v1/events[?repo=<owner>/<name>][&since=<cursor>], optional header Last-Event-ID: <cursor>. Answers 200 with
#  Content-Type text/event-stream and keeps the connection open. Each line appended to a listed repository's status.log is sent as
#  one event: a block of lines "id: <cursor>" and "data: <one-line JSON {"repo": "owner/name", "line": "<the whole log line,
#  timestamp included, redacted>"}" ended by an empty line. Comment lines (": ...") are keep-alives. The cursor is opaque (the
#  test never looks inside; it is the id of an event of this or an earlier connection, global over all repositories).
#  With a cursor the stream first sends every line after that cursor, once and in order, then goes on with new lines; without
#  one it starts at the end (no old lines). ?repo= filters events (and the lines after a cursor) to that repository.
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
start_server || fail "P01-AC-9: api.py did not restart: $(tail -c 200 "$tmp/api.out")"
for path in /v1/repos /v1/repos/acme/alpha /v1/repos/acme/beta /v1/repos/acme/alpha/nodes /v1/repos/acme/beta/nodes /v1/repos/acme/alpha/sessions /v1/repos/acme/beta/sessions /v1/schema/repos /v1/schema/repo /v1/schema/nodes /v1/schema/node /v1/schema/sessions; do
	req GET $path
done
for id in N01 N02 N03 N04 N05 N06 N07 N08 N09 N10 N11; do req GET /v1/repos/acme/alpha/nodes/$id; done
for id in B01 B02; do req GET /v1/repos/acme/beta/nodes/$id; done
req GET /v1/nothing; req POST /v1/repos
# the event stream stays open: read it for 2 seconds from the first line of each status log (a later slice's resource)
# (the three reads, the two ?since=0 reads of the next block run at the same time: each keeps its own window)
curl_pids=''
if command -v curl >/dev/null 2>&1; then
	cq=0
	for q in 'since=0' 'repo=acme/alpha&since=0' 'repo=acme/beta&since=0'; do
		cq=$((cq + 1)); rm -f "$tmp/curl.$cq"
		curl -s --max-time 2 --unix-socket "$sock" "http://localhost/v1/events?$q" >"$tmp/curl.$cq" 2>/dev/null &
		curl_pids="$curl_pids $!"
	done
fi
rm -f "$tmp/since0" "$tmp/since0.hdr" "$tmp/since0b" "$tmp/since0b.hdr"
python3 -I "$tmp/stream.py" "$sock" "/v1/events?since=0" "$tmp/since0" 2 </dev/null >/dev/null 2>&1 &
curl_pids="$curl_pids $!"
python3 -I "$tmp/stream.py" "$sock" "/v1/events?repo=acme/beta&since=0" "$tmp/since0b" 2 </dev/null >/dev/null 2>&1 &
curl_pids="$curl_pids $!"
for p in $curl_pids; do wait "$p" 2>/dev/null; done
cat "$tmp"/curl.[1-3] 2>/dev/null >>"$tmp/allresp"
[ ! -e "$home/token-was-run" ] || fail "P01-AC-9: the token script was run"   # its PASS line is in api-fifo.test.sh
if [ -s "$tmp/allresp" ] && grep -q 'ScheduleWakeup' "$tmp/allresp" && grep -q 'Run the tests' "$tmp/allresp"; then pass "P01-AC-9: the responses were recorded ($(wc -c <"$tmp/allresp") bytes, served session events among them)"; else fail "P01-AC-9: no recorded responses to scan"; fi
while IFS= read -r tok; do
	[ -n "$tok" ] || continue
	if grep -F -q -e "$tok" "$tmp/allresp" "$tmp/api.out" "$tmp/second.out"; then fail "P01-AC-9: token ${tok%"${tok#????}"}... appears in a response or in the server's output"; else pass "P01-AC-9: token ${tok%"${tok#????}"}... appears in no response and not in the server's output"; fi
done <"$fix/tokens.txt"
# the redaction shows: the response that held the key (re-requested here) has [redacted] where it was
req GET /v1/repos/acme/alpha/sessions
if [ "$(jx "any('[redacted]' in (e.get('text') or '') for x in d['sessions'] for e in x['events'])")" = True ]; then pass "P01-AC-9: [redacted] replaces the token where a session log held one"; else fail "P01-AC-9: no [redacted] in the sessions response"; fi
# ---- P01-AC-9/7: ?since=0 streams from the first line of every status log, redacted ----
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
# (the second root of the fresh review: api-root2.test.sh, run at the same time)

# --- end of cases; the final checks follow ---
snap >"$tmp/snap.after"
if [ $up = 1 ] && cmp -s "$tmp/snap.before" "$tmp/snap.after"; then pass "P01-AC-2: no file under the runtime root or HOME changed except the socket and the locks"; else fail "P01-AC-2: files changed or no server: $(diff "$tmp/snap.before" "$tmp/snap.after" | head -n 6 | tr '\n' ' ')"; fi
if [ $up = 1 ] && [ ! -s "$tmp/gh.log" ]; then pass "P01-AC-2: the fake gh recorded no call"; else fail "P01-AC-2: gh was called: $(head -n 3 "$tmp/gh.log" | tr '\n' ' ')"; fi
if [ $up = 1 ] && [ ! -e "$home/token-was-run" ]; then pass "P01-AC-2: the token script was never run"; else fail "P01-AC-2: the token script was run"; fi

[ $fails = 0 ] || { echo "$fails failed"; exit 1; }
echo "all passed"
