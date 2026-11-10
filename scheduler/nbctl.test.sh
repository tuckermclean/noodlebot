#!/bin/sh
# Tests scheduler/nbctl.py, the command-line client of the API (node P02): P02-AC-1 .. P02-AC-5.
#   sh scheduler/nbctl.test.sh   (make test)
# It runs `python3 scheduler/nbctl.py` against a fake API (scheduler/testdata/nbctl/fakeapi.py) on a temporary Unix socket,
# serving the canned responses of scheduler/testdata/nbctl/v1/ (validated here against P01's schemas) and recording
# each request. HOME is a temporary folder with no ~/.config/noodlebot/, PATH holds a fake gh that records any call.
#
# THE CONTRACT THIS TEST FIXES (the implementer follows it)
#  Usage: nbctl.py [--socket <path>] status | status <owner/name> | events [--repo <o/n>] [--since <cursor>] | get <path>
#   (--socket comes before the command). The socket defaults to $NOODLEBOT_DATA/api.sock. get <path> requests /v1/<path>.
#  Not running / not a known version: one line (stdout and stderr together) naming scheduler/loops.sh start, exit 2; a
#   response of another version: the output names that version, exit 2.
#  status: first a line with "throttle" (the five-hour and seven-day utilization as N%, the hold reason), a line with
#   "deploy" (the head), neither starting with a repository name; then one line per repository, starting with its
#   owner/name, containing "running" or "stopped" (and STOP-<name> or STOP when a stop file exists), the heartbeat age
#   (<N>s for under 120 s, "never" when null), the subjects of the running (alive) sessions, and "<N> waiting"
#   (FAILED + QUESTION + waiting-pr nodes, and failed/question triage issues; answered ones are not counted).
#  status <owner/name>: lines as status.sh's. Node states are printed as the API gives them (pr-open, waiting-pr...)
#   on the line with the node's id; a triage issue on a line with its number; "GitHub" line with the heartbeat age; a
#   "loop" line; ages as <N>s (<120 s), <N>m (<120 min), else <N>h; sizes with M for mebibytes (7.0M or 7340032);
#   a session's last 4 events in the API's order; "wakeup", "limit ... resets" words.
#  events: each event on one line, flushed at once, containing its repository and its line; a dropped connection is
#   reconnected within 2 s with the cursor (Last-Event-ID header or ?since=) of the last event received.
#  get: the body as the API sent it (stdout equals it, or it plus one newline when it had none); exit 0 for 200, 1 for 404, 2 else.
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
fix=$src/testdata/nbctl
schemas=$src/api-schema/v1
tmp=$(mktemp -d)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
pids=''
cleanup() {
	for p in $pids; do kill -9 "$p" 2>/dev/null; done
	for p in $pids; do wait "$p" 2>/dev/null; done
	rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

home=$tmp/home data=$tmp/data bin=$tmp/bin cwd=$tmp/cwd
mkdir -p "$home" "$data" "$bin" "$cwd" "$tmp/empty"
printf '#!/bin/sh\necho "$0 $*" >>"%s/gh.log"\nexit 1\n' "$tmp" >"$bin/gh"
chmod +x "$bin/gh"
python3 -I "$fix/materialize.py" "$fix/v1" "$tmp/fx/v1"
nbctl=$src/nbctl.py

# nb <args>: nbctl.py with the temporary HOME and PATH, NOODLEBOT_DATA=${NBDATA:-$data}, under a timeout.
nb() { ( cd "$cwd" && HOME=$home NOODLEBOT_DATA=${NBDATA:-$data} PATH=$bin:$PATH timeout 30 python3 "$nbctl" "$@" ); }

# start_fake <name> <socket> <mode>: the fake API; requests go to $tmp/<name>.req
start_fake() {
	python3 -I "$fix/fakeapi.py" "$2" "$tmp/fx" "$tmp/$1.req" "$3" >"$tmp/$1.fakeout" 2>&1 &
	pids="$pids $!"
	i=0
	while [ ! -e "$tmp/$1.req.ready" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
	[ -e "$tmp/$1.req.ready" ] || echo "note: the fake $1 did not start: $(cat "$tmp/$1.fakeout")"
}

# lw <file> <text>...: a line of the file contains every text (case-insensitive, fixed strings)
lw() {
	f=$1; shift
	cp "$f" "$tmp/lw"
	for p in "$@"; do grep -iF -e "$p" "$tmp/lw" >"$tmp/lw2"; mv "$tmp/lw2" "$tmp/lw"; done
	[ -s "$tmp/lw" ]
}
# lines <n> <file>: number of lines
nlines() { awk 'END{print NR+0}' "$1"; }
# req_count <name> <path>: how many requests the fake recorded for the path
req_count() { n=$(grep -cF "\"path\": \"$2\"" "$tmp/$1.req" 2>/dev/null); echo "${n:-0}"; }

if [ -f "$nbctl" ]; then pass "P02-AC-1: scheduler/nbctl.py exists"; else fail "P02-AC-1: scheduler/nbctl.py does not exist"; fi

# ---- the fake's canned responses are valid against P01's schemas ----
bad=0
for pair in repos:repos repos/acme/alpha:repo repos/acme/beta:repo repos/acme/gamma:repo throttle:throttle deploy:deploy; do
	f=$tmp/fx/v1/${pair%%:*}.json
	if msg=$(python3 -I "$fix/validate.py" "$schemas/${pair##*:}.json" "$f" 2>&1); then :; else bad=1; echo "  $f: $msg"; fi
done
for r in alpha beta gamma; do
	for res in sessions nodes issues prs; do
		f=$tmp/fx/v1/repos/acme/$r/$res.json
		if msg=$(python3 -I "$fix/validate.py" "$schemas/$res.json" "$f" 2>&1); then :; else bad=1; echo "  $f: $msg"; fi
	done
done
if [ $bad = 0 ]; then pass "P02-AC-3: the fake's canned responses are valid against P01's schemas, version 1"; else fail "P02-AC-3: the fake's canned responses are not valid against P01's schemas"; fi

start_fake main "$data/api.sock" normal

# ---- P02-AC-1: no listener, unknown version, --socket ----
mkdir -p "$tmp/stale"
python3 -I -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$tmp/stale/api.sock"
for c in "status" "status acme/alpha" "events" "get repos"; do
	NBDATA=$tmp/empty nb $c >"$tmp/out" 2>&1; rc=$?
	n=$(nlines "$tmp/out")
	if [ $rc = 2 ] && [ "$n" = 1 ] && grep -qF 'scheduler/loops.sh start' "$tmp/out"; then
		pass "P02-AC-1: '$c' with nothing on the socket: one line naming scheduler/loops.sh start, exit 2"
	else fail "P02-AC-1: '$c' with nothing on the socket: exit $rc, $n line(s): $(head -c 300 "$tmp/out" | tr '\n' '|')"; fi
done
NBDATA=$tmp/stale nb status >"$tmp/out" 2>&1; rc=$?
if [ $rc = 2 ] && [ "$(nlines "$tmp/out")" = 1 ] && grep -qF 'scheduler/loops.sh start' "$tmp/out"; then
	pass "P02-AC-1: a socket file nobody listens on: one line naming scheduler/loops.sh start, exit 2"
else fail "P02-AC-1: a socket file nobody listens on: exit $rc: $(head -c 300 "$tmp/out" | tr '\n' '|')"; fi
nb --socket "$tmp/nowhere.sock" status >"$tmp/out" 2>&1; rc=$?
if [ $rc = 2 ] && [ "$(nlines "$tmp/out")" = 1 ] && grep -qF 'scheduler/loops.sh start' "$tmp/out"; then
	pass "P02-AC-1: --socket to a path with no listener overrides the working default: one line, exit 2"
else fail "P02-AC-1: --socket to a path with no listener (the default works): exit $rc: $(head -c 300 "$tmp/out" | tr '\n' '|')"; fi

start_fake v99 "$tmp/v99.sock" v99
for c in "status" "status acme/alpha"; do
	nb --socket "$tmp/v99.sock" $c >"$tmp/out" 2>&1; rc=$?
	if [ $rc = 2 ] && grep -qF 99 "$tmp/out" && [ "$(req_count v99 /v1/repos)" -ge 1 ] 2>/dev/null; then
		pass "P02-AC-1: '$c' against responses of version 99: exit 2, the output names 99"
	else fail "P02-AC-1: '$c' against responses of version 99: exit $rc, output: $(head -c 300 "$tmp/out" | tr '\n' '|')"; fi
done

before=$(req_count main /v1/repos)
nb status >"$tmp/out" 2>&1; rc=$?
after=$(req_count main /v1/repos)
if [ $rc = 0 ] && [ "$after" -gt "$before" ]; then pass "P02-AC-1: without --socket the default \$NOODLEBOT_DATA/api.sock is used"
else fail "P02-AC-1: without --socket the default \$NOODLEBOT_DATA/api.sock is not used (exit $rc, requests $before -> $after)"; fi
mkdir -p "$tmp/data2"
start_fake alt "$tmp/alt.sock" normal
NBDATA=$tmp/data2 nb --socket "$tmp/alt.sock" status >"$tmp/out" 2>&1; rc=$?
if [ $rc = 0 ] && [ "$(req_count alt /v1/repos)" -ge 1 ]; then pass "P02-AC-1: --socket <path> is used instead of the default"
else fail "P02-AC-1: --socket <path> is not used (exit $rc, requests to it: $(req_count alt /v1/repos))"; fi
NBDATA=$tmp/data2 nb status >"$tmp/out" 2>&1; rc=$?
if [ $rc = 2 ] && grep -qF 'scheduler/loops.sh start' "$tmp/out"; then pass "P02-AC-1: the default follows NOODLEBOT_DATA (a socket elsewhere is not found)"
else fail "P02-AC-1: the default does not follow NOODLEBOT_DATA (exit $rc)"; fi

# ---- P02-AC-2: status ----
nb status >"$tmp/status.out" 2>"$tmp/status.err"; rc=$?
if [ $rc = 0 ]; then pass "P02-AC-2: status exits 0"; else fail "P02-AC-2: status exits $rc: $(head -c 300 "$tmp/status.err")"; fi
ln() { grep -n -iE -e "$1" "$tmp/status.out" | grep -vE '^[0-9]+:[[:space:]]*acme/' | head -n 1 | cut -d: -f1; }
firstrepo=$(grep -nE '^[[:space:]]*acme/(alpha|beta|gamma)' "$tmp/status.out" | head -n 1 | cut -d: -f1)
for r in alpha beta gamma; do
	c=$(grep -cE "^[[:space:]]*acme/$r( |\$|:)" "$tmp/status.out")
	if [ "$c" = 1 ]; then pass "P02-AC-2: status has one line for acme/$r"; else fail "P02-AC-2: status has $c lines for acme/$r, not 1"; fi
done
rl() { grep -E "^[[:space:]]*acme/$1( |\$|:)" "$tmp/status.out" | head -n 1 >"$tmp/rl"; }
rl alpha
if grep -qw running "$tmp/rl" && ! grep -qi stopped "$tmp/rl" && grep -qF 42s "$tmp/rl" && grep -qF N04 "$tmp/rl" && grep -qF 104 "$tmp/rl" && grep -qF '5 waiting' "$tmp/rl"; then
	pass "P02-AC-2: acme/alpha's line: running, heartbeat 42s, sessions N04 and 104, 5 waiting"
else fail "P02-AC-2: acme/alpha's line lacks running / 42s / N04 / 104 / '5 waiting': $(cat "$tmp/rl")"; fi
rl beta
if grep -qi stopped "$tmp/rl" && grep -qF STOP-beta "$tmp/rl" && grep -qF 95s "$tmp/rl" && grep -qF '0 waiting' "$tmp/rl"; then
	pass "P02-AC-2: acme/beta's line: stopped, STOP-beta, heartbeat 95s, 0 waiting"
else fail "P02-AC-2: acme/beta's line lacks stopped / STOP-beta / 95s / '0 waiting': $(cat "$tmp/rl")"; fi
rl gamma
if grep -qi stopped "$tmp/rl" && grep -qF STOP "$tmp/rl" && grep -qi never "$tmp/rl" && grep -qF '0 waiting' "$tmp/rl"; then
	pass "P02-AC-2: acme/gamma's line: stopped, STOP, heartbeat never, 0 waiting"
else fail "P02-AC-2: acme/gamma's line lacks stopped / STOP / never / '0 waiting': $(cat "$tmp/rl")"; fi
tl=$(ln 'throttle'); dl=$(ln 'deploy')
if [ -n "$tl" ] && [ -n "${firstrepo:-}" ] && [ "$tl" -lt "$firstrepo" ] && grep -iF throttle "$tmp/status.out" | head -n 1 | grep -qF 63% \
	&& grep -iF throttle "$tmp/status.out" | head -n 1 | grep -qF 28% && grep -iF throttle "$tmp/status.out" | head -n 1 | grep -qF projected-five-hour-over-cap; then
	pass "P02-AC-2: the throttle line (63%, 28%, the hold reason) comes above the repository lines"
else fail "P02-AC-2: no throttle line with 63%, 28% and the hold reason above the repository lines (throttle line ${tl:-none}, first repository line ${firstrepo:-none})"; fi
if [ -n "$dl" ] && [ -n "${firstrepo:-}" ] && [ "$dl" -lt "$firstrepo" ] && grep -iF deploy "$tmp/status.out" | grep -vE '^[[:space:]]*acme/' | head -n 1 | grep -qF 9f3c2ab; then
	pass "P02-AC-2: the deploy line (head 9f3c2ab) comes above the repository lines"
else fail "P02-AC-2: no deploy line with the head 9f3c2ab above the repository lines (deploy line ${dl:-none}, first repository line ${firstrepo:-none})"; fi

# ---- P02-AC-3: status <owner/name> ----
nb status acme/alpha >"$tmp/d.out" 2>"$tmp/d.err"; rc=$?
if [ $rc = 0 ]; then pass "P02-AC-3: status acme/alpha exits 0"; else fail "P02-AC-3: status acme/alpha exits $rc: $(head -c 300 "$tmp/d.err")"; fi
d() { lw "$tmp/d.out" "$@"; }
ck() { desc=$1; shift; if "$@"; then pass "P02-AC-3: $desc"; else fail "P02-AC-3: $desc"; fi; }
ck "the loop line says running" d loop running
ck "the last GitHub check, 42s" d github 42s
ck "the status issue is acme/alpha/issues/77" d acme/alpha/issues/77
ck "the throttle: 63% and 28%" d 63% 28%
ck "the throttle's hold reason" d projected-five-hour-over-cap
ck "a running node session: pid 424242 on the N04 line" d N04 424242
ck "a running triage session: pid 515151" d 515151
ck "a session's age 5m (started 300 s ago)" grep -qE '(^|[^0-9.])(5m|5 min|30[0-9]s|5\.[0-9]m)' "$tmp/d.out"
ck "a session's log size 7.0M" grep -qE '(7\.0 ?M|7 ?M(iB|B)|7340032|7168 ?K)' "$tmp/d.out"
ck "a session's last write 2h ago" grep -qE '(^|[^0-9.])(2h|2\.0h|12[0-9]m|72[6-9][0-9]s|7[3-9][0-9]{2}s|2 hours)' "$tmp/d.out"
for t in act-07 act-08 act-09 sub-ten; do ck "the last 4 actions include $t" d "$t"; done
for t in act-01 act-02 act-03 act-04 act-05 act-06; do
	if d "$t"; then fail "P02-AC-3: only the last 4 actions: $t is shown"
	elif d act-09; then pass "P02-AC-3: only the last 4 actions: $t is not shown"; else fail "P02-AC-3: only the last 4 actions: $t is not shown, but no action is shown at all"; fi
done
for t in commit-subject-one commit-subject-two commit-subject-three abc1234; do ck "a node's commits include $t" d "$t"; done
ck "a pending wakeup" d wake
ck "background command sleep-bg-token" d sleep-bg-token
ck "background agent agent-bg-token" d agent-bg-token
ck "a limit rejection with its reset" grep -qiE 'limit.*reset|reset.*limit' "$tmp/d.out"
ck "FAILED node N01 with its reason" d N01 reason-token-failed-node
ck "FAILED triage 101 with its reason" d 101 reason-token-failed-triage
ck "QUESTION node N02 with its first line" d N02 question-first-line-node
ck "QUESTION node N02's issue URL" d https://github.com/acme/alpha/issues/501
ck "QUESTION triage 102 with its first line" d 102 question-first-line-triage
ck "QUESTION triage 102's issue URL" d https://github.com/acme/alpha/issues/102
ck "answered node N05" d N05 answered
ck "answered triage 103" d 103 answered
ck "the spec PR #321 waited for by N03" d N03 321
for pair in N01:failed N02:question N03:waiting-pr N04:running N05:answered N06:pr-open N07:merged N08:ready N09:held; do
	ck "node ${pair%%:*}'s state ${pair##*:}" d "${pair%%:*}" "${pair##*:}"
done
ck "open PR #88 with its branch and MERGEABLE" d 88 N06-branch-token MERGEABLE
ck "open PR #89 with its branch and CONFLICTING" d 89 branch-token-89 CONFLICTING
ck "open PR #90 with its branch and UNKNOWN" d 90 branch-token-90 UNKNOWN
nb status acme/beta >"$tmp/b.out" 2>&1
if grep -qF STOP-beta "$tmp/b.out" && lw "$tmp/b.out" loop stopped; then pass "P02-AC-3: acme/beta's loop is stopped and ~/STOP-beta shown"; else fail "P02-AC-3: acme/beta: no 'loop ... stopped' line and STOP-beta"; fi
nb status acme/gamma >"$tmp/g.out" 2>&1
if grep -qF STOP "$tmp/g.out" && ! grep -qF STOP-gamma "$tmp/g.out" && grep -qi never "$tmp/g.out"; then pass "P02-AC-3: acme/gamma: ~/STOP shown, no STOP-gamma, last check never"; else fail "P02-AC-3: acme/gamma: expected STOP, no STOP-gamma, never"; fi
nb status acme/unlisted >"$tmp/u.out" 2>&1; rc=$?
if [ -f "$nbctl" ] && [ $rc -ne 0 ] && [ $rc -ne 124 ]; then pass "P02-AC-3: an unlisted repository exits non-zero"; else fail "P02-AC-3: an unlisted repository exits $rc, expected non-zero"; fi

# nothing but the socket is read, nothing is run: an audit hook around nbctl.py (and a check that it sees what it must)
: >"$tmp/audit.self"
printf 'x' >"$home/probe-file"
cat >"$tmp/probe.py" <<'EOP'
import os, subprocess
open(os.path.join(os.environ["HOME"], "probe-file")).read()
os.listdir(os.environ["NOODLEBOT_DATA"])
subprocess.run(["true"])
EOP
(cd "$cwd" && HOME=$home NOODLEBOT_DATA=$data python3 -I "$fix/audit-run.py" "$tmp/audit.self" "$tmp/probe.py") >/dev/null 2>&1
if grep -q "^open $home/probe-file" "$tmp/audit.self" && grep -q '^os.listdir' "$tmp/audit.self" && grep -q '^subprocess.Popen' "$tmp/audit.self"; then
	pass "P02-AC-3: the audit hook records a read under HOME, a listing of the runtime root and a subprocess"
else fail "P02-AC-3: the test's audit hook misses a deliberate read or run: $(tr '\n' '|' <"$tmp/audit.self")"; fi
rm -f "$home/probe-file"
for c in "status acme/alpha" "status" "get repos/acme/alpha/prs"; do
	: >"$tmp/audit.log"
	(cd "$cwd" && HOME=$home NOODLEBOT_DATA=$data PATH=$bin:$PATH timeout 30 python3 -I "$fix/audit-run.py" "$tmp/audit.log" "$nbctl" $c) >"$tmp/audit.out" 2>&1; rc=$?
	if [ $rc = 0 ] && [ -s "$tmp/audit.out" ] && [ ! -s "$tmp/audit.log" ]; then pass "P02-AC-3: '$c' reads nothing under HOME or the runtime root but the socket and runs no program"
	else fail "P02-AC-3: '$c' (exit $rc, output $(wc -c <"$tmp/audit.out") bytes) read or ran: $(tr '\n' '|' <"$tmp/audit.log")"; fi
done
if [ ! -s "$tmp/gh.log" ]; then
	if [ -f "$nbctl" ]; then pass "P02-AC-3: the fake gh recorded no call"; else fail "P02-AC-3: the fake gh recorded no call, but nbctl.py does not exist"; fi
else fail "P02-AC-3: the fake gh recorded a call: $(head -c 200 "$tmp/gh.log")"; fi
bad=$(python3 -I -c '
import json, sys
bad = [r["path"] for r in map(json.loads, open(sys.argv[1])) if not r["path"].startswith("/v1/") or r["method"] != "GET"]
print(" ".join(bad))' "$tmp/main.req" 2>&1)
if [ -z "$bad" ] && [ "$(req_count main /v1/repos/acme/alpha/sessions)" -ge 1 ]; then pass "P02-AC-3: every request is a GET under /v1/ (and the sessions were requested)"
else fail "P02-AC-3: requests outside GET /v1/ or no sessions request: $bad"; fi

# ---- P02-AC-4: events ----
ev_cursor() { # <name> <n>: the cursor of the n-th /v1/events request ("" when none)
	python3 -I -c '
import json, sys
rs = [r for r in map(json.loads, open(sys.argv[1])) if r["path"] == "/v1/events"]
n = int(sys.argv[2])
if len(rs) >= n:
    r = rs[n - 1]; print(r["last_event_id"] or (r["query"].get("since") or [""])[0])' "$tmp/$1.req" "$2" 2>/dev/null
}
ev_query() { # <name> <n> <key>: value of a query parameter of the n-th /v1/events request
	python3 -I -c '
import json, sys
rs = [r for r in map(json.loads, open(sys.argv[1])) if r["path"] == "/v1/events"]
n = int(sys.argv[2])
if len(rs) >= n: print((rs[n - 1]["query"].get(sys.argv[3]) or [""])[0])' "$tmp/$1.req" "$2" "$3" 2>/dev/null
}
# run_events <name> <args...>: nbctl.py events against a fresh fake; stops it once the last event (evtok-5) is printed
# and the reconnect had time to repeat (or after 40 s); output in $tmp/<name>.stdout / .stderr
run_events() {
	n=$1; shift
	start_fake "$n" "$tmp/$n.sock" normal
	( cd "$cwd" && HOME=$home NOODLEBOT_DATA=$data PATH=$bin:$PATH exec timeout 60 python3 "$nbctl" --socket "$tmp/$n.sock" events "$@" ) >"$tmp/$n.stdout" 2>"$tmp/$n.stderr" &
	ep=$!
	i=0
	while [ $i -lt 400 ] && kill -0 $ep 2>/dev/null && ! grep -qF evtok-5 "$tmp/$n.stdout"; do sleep 0.1; i=$((i + 1)); done
	if kill -0 $ep 2>/dev/null; then sleep 3; fi   # a second delivery of anything would show by now
	kill $ep 2>/dev/null; wait $ep 2>/dev/null
}
ids=$tmp/ev1.req.ids
run_events ev1
id3=$(sed -n 3p "$ids" 2>/dev/null)
for pair in 1:acme/alpha 2:acme/beta 3:acme/alpha 4:acme/beta 5:acme/alpha; do
	k=${pair%%:*} repo=${pair##*:}
	c=$(grep -cF "evtok-$k" "$tmp/ev1.stdout")
	if [ "$c" = 1 ] && grep -F "evtok-$k" "$tmp/ev1.stdout" | grep -qF "$repo"; then pass "P02-AC-4: event $k printed once, on a line with $repo"
	else fail "P02-AC-4: event $k printed $c time(s), or not on a line with $repo (stdout: $(head -c 400 "$tmp/ev1.stdout" | tr '\n' '|'))"; fi
done
if [ -s "$tmp/ev1.stdout" ] && [ -z "$(sort "$tmp/ev1.stdout" | uniq -d)" ]; then pass "P02-AC-4: no line is printed twice"; else fail "P02-AC-4: a line is printed twice or nothing was printed"; fi
rc1=$(ev_cursor ev1 1); rc2=$(ev_cursor ev1 2)
if [ -n "$id3" ] && [ -z "$rc1" ] && [ "$rc2" = "$id3" ]; then pass "P02-AC-4: the first request has no cursor; the reconnect carries the id of the last event (Last-Event-ID or since)"
else fail "P02-AC-4: first request cursor '$rc1' (want none), reconnect cursor '$rc2' (want '$id3')"; fi
if [ -n "$(ev_cursor ev1 2)" ] && [ -z "$(ev_query ev1 1 repo)" ] && [ -z "$(ev_query ev1 1 since)" ]; then pass "P02-AC-4: without options, no repo or since parameter is sent"; else fail "P02-AC-4: without options a repo or since parameter was sent"; fi

run_events ev2 --repo acme/alpha --since startcursor-xyz
id3=$(sed -n 3p "$tmp/ev2.req.ids" 2>/dev/null)
if [ "$(ev_query ev2 1 repo)" = acme/alpha ]; then pass "P02-AC-4: --repo is passed as the repo query parameter"; else fail "P02-AC-4: --repo was not passed as repo=acme/alpha (got '$(ev_query ev2 1 repo)')"; fi
c1=$(ev_cursor ev2 1)
if [ "$c1" = startcursor-xyz ]; then pass "P02-AC-4: --since is passed as since (or Last-Event-ID)"; else fail "P02-AC-4: --since was not passed (first request cursor '$c1')"; fi
for k in 1 3 5; do
	c=$(grep -cF "evtok-$k" "$tmp/ev2.stdout")
	if [ "$c" = 1 ]; then pass "P02-AC-4: with --repo, event $k printed once"; else fail "P02-AC-4: with --repo, event $k printed $c time(s)"; fi
done
if [ "$(ev_cursor ev2 2)" = "$id3" ] && [ -n "$id3" ]; then pass "P02-AC-4: with --since, the reconnect carries the last event's id, not the --since cursor"; else fail "P02-AC-4: with --since, the reconnect cursor is '$(ev_cursor ev2 2)', want '$id3'"; fi
if grep -qF -e evtok-2 -e evtok-4 "$tmp/ev2.stdout"; then fail "P02-AC-4: with --repo acme/alpha, another repository's event is printed"; else
	if [ -s "$tmp/ev2.stdout" ]; then pass "P02-AC-4: with --repo acme/alpha, no other repository's event is printed"; else fail "P02-AC-4: with --repo, nothing was printed"; fi
fi

# ---- P02-AC-5: get ----
nb get repos >"$tmp/get.out" 2>/dev/null; rc=$?
if [ $rc = 0 ] && cmp -s "$tmp/get.out" "$tmp/fx/v1/repos.json"; then pass "P02-AC-5: get repos prints the JSON unchanged, exit 0"; else fail "P02-AC-5: get repos: exit $rc, output differs from the API's body"; fi
nb get repos/acme/alpha/prs >"$tmp/get.out" 2>/dev/null; rc=$?
if [ $rc = 0 ] && cmp -s "$tmp/get.out" "$tmp/fx/v1/repos/acme/alpha/prs.json" && [ "$(req_count main /v1/repos/acme/alpha/prs)" -ge 1 ]; then
	pass "P02-AC-5: get repos/acme/alpha/prs requests /v1/repos/acme/alpha/prs and prints its body byte for byte (odd spacing and key order kept)"
else fail "P02-AC-5: get repos/acme/alpha/prs: exit $rc, or the body was reformatted, or the path was not /v1/repos/acme/alpha/prs"; fi
nb get rawbody >"$tmp/get.out" 2>/dev/null; rc=$?
if [ $rc = 0 ] && { cmp -s "$tmp/get.out" "$tmp/fx/v1/rawbody.json" || { cp "$tmp/fx/v1/rawbody.json" "$tmp/raw.nl" && echo >>"$tmp/raw.nl" && cmp -s "$tmp/get.out" "$tmp/raw.nl"; }; }; then
	pass "P02-AC-5: get prints a body without a final newline and with non-ASCII text unchanged (at most a final newline added)"
else fail "P02-AC-5: get rawbody: exit $rc, the body was changed"; fi
nb get repos/acme/nosuch >"$tmp/get.out" 2>/dev/null; rc=$?
if [ $rc = 1 ] && [ "$(req_count main /v1/repos/acme/nosuch)" -ge 1 ]; then pass "P02-AC-5: a 404 exits 1"; else fail "P02-AC-5: a 404 exits $rc, expected 1 (or the request was not made)"; fi
nb get boom >"$tmp/get.out" 2>/dev/null; rc=$?
if [ $rc = 2 ] && [ "$(req_count main /v1/boom)" -ge 1 ]; then pass "P02-AC-5: a 500 exits 2"; else fail "P02-AC-5: a 500 exits $rc, expected 2 (or the request was not made)"; fi
nb get teapot >"$tmp/get.out" 2>/dev/null; rc=$?
if [ $rc = 2 ] && [ "$(req_count main /v1/teapot)" -ge 1 ]; then pass "P02-AC-5: a 418 exits 2 (anything but 200 and 404)"; else fail "P02-AC-5: a 418 exits $rc, expected 2 (or the request was not made)"; fi

[ $fails = 0 ] || { echo "FAILED: $fails"; exit 1; }
echo "OK"
