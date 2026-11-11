#!/bin/sh
# Tests scheduler/api.py's control requests (node P03), part: P03-AC-1, P03-AC-2, on a third root (its own data, HOME,
# checkout and server). The block below is P03's block of the former single api.test.sh, unchanged (D03 split that file
# into parts that run at the same time); the helpers are in testdata/lib/api-common.sh.
#   sh scheduler/api-p03.test.sh   (make test)
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d)
. "$src/testdata/lib/api-common.sh"
mkdir -p "$tmp/bin"
# A fake gh that records any call (the API must make none).
printf '#!/bin/sh\necho "$0 $*" >>"%s/gh.log"\nexit 1\n' "$tmp" >"$tmp/bin/gh"
chmod +x "$tmp/bin/gh"
export NOODLEBOT_API_HEAD_CHECK=2 NOODLEBOT_API_KEEPALIVE=1
PATH=$tmp/bin:$PATH; export PATH

# ================= P03-AC-1, P03-AC-2: the control requests (a third root: its own data, HOME, checkout and server) =================
# P01-AC-2's snapshot of the first root stays as it is: the writes below go to their own copy of the fixture ("r3").
# THE CONTRACT THIS BLOCK FIXES (the implementer follows it; the shared formats are in out/node/P03/brief.md):
#  Requests (all JSON bodies are objects with "version": 1):
#    DELETE /v1/repos/<o>/<n>/nodes/<ID>/failed   removes state/<n>/node/<ID>/FAILED, record {"control":"delete-failed","target":"node/<ID>"}
#    DELETE /v1/repos/<o>/<n>/issues/<N>/failed   removes state/<n>/issue/<N>/FAILED, record target "issue/<N>"
#    PUT    /v1/repos/<o>/<n>/stop                creates ~/STOP-<n>, record control "stop", target "<o>/<n>"
#    DELETE /v1/repos/<o>/<n>/stop                removes ~/STOP-<n>, record control "unstop"
#    POST   /v1/repos/<o>/<n>/nodes/<ID>/release  writes state/<n>/node/<ID>/RELEASE, record control "release", target "node/<ID>"
#    POST   /v1/deploy/retry  {"sha": "<commit>"} writes $NOODLEBOT_DATA/deploy/retry (the 40-hex sha and a newline); no record
#    POST   /v1/deploy/rollback                   writes $NOODLEBOT_DATA/deploy/rollback-request; no record
#  A record is state/<n>/requests/<name>.json, {"control", "target", "time" (UTC ISO-8601)}, written once per request.
#  The 202 body is the resource "control" (scheduler/api-schema/v1/control.json, served at /v1/schema/control):
#    {"version":1, "control": <as in the record, "retry" and "rollback" for the deploy requests>, "target": <string>,
#     "wrote": [<absolute path of each marker written or removed, and of the record>...], "when": <a line saying when the loop
#     (deploy.sh for the deploy requests) carries it out; after an unstop it says that scheduler/loops.sh start starts the loop>}
#  A commit is known when it is a line of deploy/rejected or resolves to a commit of api.py's own checkout.
r3=$tmp/r3; r3data=$r3/data; r3home=$r3/home; r3co=$r3/co; r3sock=$r3data/api.sock; r3a=$r3data/state/alpha; r3pid=''
mkdir -p "$r3data" "$r3home" "$r3co/scheduler"
cp -R "$fix/data/." "$r3data/"; cp -R "$fix/home/." "$r3home/"
for f in "$src"/*; do case $f in "$src/testdata") ;; *) cp -R "$f" "$r3co/scheduler/" ;; esac; done
git -C "$r3co" init -q 2>/dev/null
git -C "$r3co" add -A >/dev/null 2>&1
git -C "$r3co" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m fixture >/dev/null 2>&1
r3head=$(git -C "$r3co" rev-parse HEAD 2>/dev/null)
echo "2026-11-09T09:30:00Z second exit (rc 1) without finishing" >"$r3a/issue/8/FAILED"
live "$r3a/node/N03" /w/r3/N03 /noodlebot:node N03
live "$r3a/node/N04" /w/r3/N04 /noodlebot:node N04
live "$r3a/issue/9" /w/r3/issue-9 /noodlebot:triage 9
r3live="$r3a/node/N03/session.pid $r3a/node/N04/session.pid $r3a/issue/9/session.pid"
cat >"$tmp/c3.py" <<'EOP'
import http.client, socket, sys
class C(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX); self.sock.settimeout(10); self.sock.connect(sys.argv[1])
try:
    c = C("localhost")
    body = None if sys.argv[4] == "-" else sys.argv[4].encode()
    c.request(sys.argv[2], sys.argv[3], body=body, headers={"Content-Type": "application/json"} if body else {})
    r = c.getresponse(); b = r.read()
    open(sys.argv[5], "wb").write(b); print(r.status)
except Exception:
    open(sys.argv[5], "wb").write(b""); print("000")
EOP
req3() { # req3 <METHOD> <path> [body]: $code and $tmp/resp, against the third root's server
	code=$(python3 -I "$tmp/c3.py" "$r3sock" "$1" "$2" "${3:--}" "$tmp/resp" 2>/dev/null); [ -n "$code" ] || code=000
}
snap3() {
	find "$r3data" "$r3home" ! -type s ! -name api.sock ! -name api.lock ! -name loop.lock \
		-exec sh -c 'for f; do if [ -d "$f" ]; then echo "d $f"; else echo "f $f $(stat -c "%s %Y" "$f") $(cksum <"$f")"; fi; done' sh {} + | sort
}
NOODLEBOT_DATA=$r3data HOME=$r3home python3 "$r3co/scheduler/api.py" >"$tmp/r3.out" 2>&1 &
r3pid=$!; pids="$pids $r3pid"
i=0; r3up=0
while [ $i -lt 60 ] && kill -0 "$r3pid" 2>/dev/null; do
	[ -S "$r3sock" ] && { req3 GET /v1/repos; [ "$code" = 200 ] && { r3up=1; break; }; }
	sleep 0.1; i=$((i + 1))
done
if [ $r3up = 1 ]; then pass "P03-AC-1: api.py serves on the third root (the root the controls are tested on)"; else fail "P03-AC-1: api.py did not serve on the third root: $(head -c 200 "$tmp/r3.out")"; fi

# the records' and the 202 body's checks (Python, so the JSON is read, not grepped)
cat >"$tmp/rec3.py" <<'EOP'
import json, re, sys
try:
    d = json.load(open(sys.argv[1]))
    assert isinstance(d, dict), "not an object"
    assert d.get("control") == sys.argv[2], "control is %r, not %r" % (d.get("control"), sys.argv[2])
    assert d.get("target") == sys.argv[3], "target is %r, not %r" % (d.get("target"), sys.argv[3])
    assert isinstance(d.get("time"), str) and re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", d["time"]), "time is %r" % (d.get("time"),)
    print("OK")
except Exception as e:
    print("BAD %s" % e)
EOP
cat >"$tmp/body3.py" <<'EOP'
import json, re, sys
# body3.py <resp> <control> <target or -> <when must say> <path wrote must name>...
try:
    d = json.load(open(sys.argv[1]))
    assert d.get("control") == sys.argv[2], "control is %r" % (d.get("control"),)
    if sys.argv[3] != "-": assert d.get("target") == sys.argv[3], "target is %r" % (d.get("target"),)
    w = d.get("wrote")
    assert isinstance(w, list) and all(isinstance(x, str) for x in w), "wrote is %r" % (w,)
    for p in sys.argv[5:]:
        assert p in w, "wrote %r does not name %s" % (w, p)
    assert isinstance(d.get("when"), str) and re.search(sys.argv[4], d["when"], re.I), "when is %r" % (d.get("when"),)
    print("OK")
except Exception as e:
    print("BAD %s" % e)
EOP
# ctl <what> <METHOD> <path> <body or -> <control> <target> <when regex> <record dir or -> <marker path>...
# A valid request: 202; exactly its marker(s) and one request record changed (no record for a deploy request); the record's
# content; the 202 body names the marker and the record and says when; the body is valid against the schema "control".
ctl() {
	what=$1 m=$2 path=$3 body=$4 control=$5 target=$6 whenre=$7 recdir=$8; shift 8
	snap3 >"$tmp/s3.before"; req3 "$m" "$path" "$body"; snap3 >"$tmp/s3.after"
	if [ "$code" = 202 ]; then pass "P03-AC-1: $what is answered 202"; else fail "P03-AC-1: $what answered $code, not 202: $(head -c 150 "$tmp/resp")"; fi
	got=$(diff "$tmp/s3.before" "$tmp/s3.after" | grep '^[<>] f ' | awk '{print $3}' | sed -E 's#/requests/[^/]+$#/requests/REC#' | sort -u | tr '\n' ' ')
	want=$( { for x in "$@"; do echo "$x"; done; [ "$recdir" = - ] || echo "$recdir/REC"; } | sort -u | tr '\n' ' ')
	if [ "$got" = "$want" ]; then pass "P03-AC-1: $what changes exactly its marker$([ "$recdir" = - ] || echo ' and its request record')"; else fail "P03-AC-1: $what changed [$got], not [$want]"; fi
	rec=''
	if [ "$recdir" != - ]; then
		nrec=$(diff "$tmp/s3.before" "$tmp/s3.after" | grep -c "^> f $recdir/")
		rec=$(diff "$tmp/s3.before" "$tmp/s3.after" | grep "^> f $recdir/" | awk '{print $3}' | head -n 1)
		if [ "$nrec" = 1 ] && [ -n "$rec" ]; then
			r=$(python3 -I "$tmp/rec3.py" "$rec" "$control" "$target" 2>&1)
			if [ "$r" = OK ]; then pass "P03-AC-1: $what writes one request record with its control, target and a UTC time"; else fail "P03-AC-1: $what's request record: $r"; fi
		else fail "P03-AC-1: $what wrote $nrec request records under $recdir, not 1"; fi
	fi
	r=$(python3 -I "$tmp/body3.py" "$tmp/resp" "$control" "$target" "$whenre" "$@" $rec 2>&1)
	if [ "$r" = OK ]; then pass "P03-AC-1: the 202 of $what names the marker$([ -z "$rec" ] || echo ' and the record') it wrote and says when the loop carries it out"; else fail "P03-AC-1: the 202 of $what: $r"; fi
	if [ -f "$schemas/control.json" ]; then
		if msg=$(python3 -I "$tmp/validate.py" "$schemas/control.json" "$tmp/resp" 2>&1); then pass "P03-AC-1: the 202 of $what is valid against schema control"; else fail "P03-AC-1: the 202 of $what is not valid against schema control: $msg"; fi
	else fail "P03-AC-1: the 202 of $what: no schema scheduler/api-schema/v1/control.json"; fi
}
# nochange <id> <what> <METHOD> <path> <body or -> <status>: that status, a JSON error body, and no file or directory changed.
nochange() {
	snap3 >"$tmp/s3.before"; req3 "$3" "$4" "$5"; snap3 >"$tmp/s3.after"
	if [ "$code" = "$6" ] && [ "$(jx "d['version'] == 1 and isinstance(d['error'], str)")" = True ]; then pass "$1: $2 is answered $6 with a JSON error body"; else fail "$1: $2 answered $code, not $6: $(head -c 150 "$tmp/resp")"; fi
	if cmp -s "$tmp/s3.before" "$tmp/s3.after"; then pass "$1: $2 changes no file"; else fail "$1: $2 changed: $(diff "$tmp/s3.before" "$tmp/s3.after" | head -n 4 | tr '\n' ' ')"; fi
}
R=/v1/repos/acme/alpha
rej2=2222222222222222222222222222222222222222

# --- P03-AC-2 first: what is refused changes nothing (the state is still the fixture's) ---
nochange P03-AC-2 "DELETE of a failed node of an unknown repository" DELETE /v1/repos/acme/ghost/nodes/N05/failed - 404
nochange P03-AC-2 "DELETE of the FAILED of an unknown node" DELETE $R/nodes/N99/failed - 404
nochange P03-AC-2 "DELETE of the FAILED of a node of another repository" DELETE $R/nodes/B01/failed - 404
nochange P03-AC-2 "DELETE of the FAILED of an unknown issue" DELETE $R/issues/99/failed - 404
nochange P03-AC-2 "DELETE of the FAILED of an issue of an unknown repository" DELETE /v1/repos/acme/ghost/issues/8/failed - 404
nochange P03-AC-2 "PUT stop of an unknown repository" PUT /v1/repos/acme/ghost/stop - 404
nochange P03-AC-2 "DELETE stop of an unknown repository" DELETE /v1/repos/acme/ghost/stop - 404
nochange P03-AC-2 "POST release of an unknown node" POST $R/nodes/N99/release - 404
nochange P03-AC-2 "POST release of an unknown repository" POST /v1/repos/acme/ghost/nodes/N09/release - 404
nochange P03-AC-2 "POST deploy/retry of a commit that is neither rejected nor in the checkout" POST /v1/deploy/retry '{"sha": "4444444444444444444444444444444444444444"}' 404
nochange P03-AC-2 "POST deploy/retry without a sha" POST /v1/deploy/retry '{}' 404
nochange P03-AC-2 "POST deploy/retry with a malformed sha" POST /v1/deploy/retry '{"sha": "not-a-commit"}' 404
nochange P03-AC-2 "DELETE of a FAILED that does not exist (node N09)" DELETE $R/nodes/N09/failed - 409
nochange P03-AC-2 "DELETE of a FAILED that does not exist (issue 9)" DELETE $R/issues/9/failed - 409
nochange P03-AC-2 "PUT stop while ~/STOP-beta exists" PUT /v1/repos/acme/beta/stop - 409
nochange P03-AC-2 "DELETE stop while ~/STOP-alpha does not exist" DELETE $R/stop - 409
nochange P03-AC-2 "POST deploy/retry of a commit that resolves but is not rejected" POST /v1/deploy/retry "{\"sha\": \"$r3head\"}" 409
for x in "PATCH $R/nodes/N05/failed" "PUT $R/nodes/N05/failed" "POST $R/nodes/N05/failed" "POST $R/nodes/N05" "DELETE $R/nodes/N05" "PUT $R/nodes/N05/release" "DELETE $R/nodes/N05/release" \
	"PATCH $R/stop" "POST $R/stop" "POST $R/issues/8/failed" "PUT $R/issues/8/failed" "PATCH $R/issues/8/failed" "POST $R/issues/8" "DELETE $R/issues/8" \
	"PUT /v1/deploy/retry" "DELETE /v1/deploy/retry" "PUT /v1/deploy/rollback" "PATCH /v1/deploy/rollback" "POST /v1/deploy" "POST /v1/throttle" "PUT $R/sessions" "POST /v1/schema/control"; do
	nochange P03-AC-2 "${x% *} ${x#* } (a write not among the controls)" "${x%% *}" "${x#* }" - 405
done

# --- P03-AC-1: the valid requests, each against the root as the one before left it ---
ctl "DELETE of the FAILED of node N05" DELETE $R/nodes/N05/failed - delete-failed node/N05 'loop' "$r3a/requests" "$r3a/node/N05/FAILED"
ctl "DELETE of the FAILED of issue 8" DELETE $R/issues/8/failed - delete-failed issue/8 'loop' "$r3a/requests" "$r3a/issue/8/FAILED"
ctl "PUT stop of acme/alpha" PUT $R/stop - stop acme/alpha 'loop' "$r3a/requests" "$r3home/STOP-alpha"
ctl "DELETE stop of acme/beta" DELETE /v1/repos/acme/beta/stop - unstop acme/beta 'loops\.sh start' "$r3data/state/beta/requests" "$r3home/STOP-beta"
ctl "POST release of node N09" POST $R/nodes/N09/release - release node/N09 'loop' "$r3a/requests" "$r3a/node/N09/RELEASE"
ctl "POST deploy/retry of a rejected commit" POST /v1/deploy/retry "{\"sha\": \"$rej2\"}" retry - 'deploy' - "$r3data/deploy/retry"
if [ "$(cat "$r3data/deploy/retry" 2>/dev/null)" = "$rej2" ]; then pass "P03-AC-1: deploy/retry holds the commit"; else fail "P03-AC-1: deploy/retry holds [$(cat "$r3data/deploy/retry" 2>/dev/null)], not $rej2"; fi
ctl "POST deploy/rollback" POST /v1/deploy/rollback - rollback - 'deploy' - "$r3data/deploy/rollback-request"
if [ -e "$r3a/node/N05/FAILED" ] || [ -e "$r3a/issue/8/FAILED" ] || [ -e "$r3home/STOP-beta" ] || [ ! -e "$r3home/STOP-alpha" ] || [ ! -e "$r3a/node/N09/RELEASE" ]; then fail "P03-AC-1: the markers of the requests are not as the requests left them"; else pass "P03-AC-1: after the requests, the FAILED files and ~/STOP-beta are gone and ~/STOP-alpha and RELEASE exist"; fi

# --- P03-AC-2: a STOP file already in the requested state, the other way round, and a rollback with no rollback point ---
nochange P03-AC-2 "PUT stop while ~/STOP-alpha was just created" PUT $R/stop - 409
nochange P03-AC-2 "DELETE stop while ~/STOP-beta was just removed" DELETE /v1/repos/acme/beta/stop - 409
nochange P03-AC-2 "DELETE of the FAILED of node N05 a second time" DELETE $R/nodes/N05/failed - 409
rm -f "$r3data/deploy/previous" "$r3data/deploy/rollback-request"
nochange P03-AC-2 "POST deploy/rollback with no deploy/previous" POST /v1/deploy/rollback - 409

# --- the schema, served ---
req3 GET /v1/schema/control
if [ "$code" = 200 ] && [ -f "$schemas/control.json" ] && python3 -I -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])) == json.load(open(sys.argv[2])) else 1)' "$tmp/resp" "$schemas/control.json" 2>/dev/null; then pass "P03-AC-1: /v1/schema/control serves scheduler/api-schema/v1/control.json"; else fail "P03-AC-1: /v1/schema/control answered $code or differs from the committed schema"; fi
if [ -f "$schemas/control.json" ] && python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1])); sys.exit(0 if all(k in s.get("required",[]) and k in s.get("properties",{}) for k in ("version","control","target","wrote","when")) else 1)' "$schemas/control.json" 2>/dev/null; then pass "P03-AC-1: schema control requires version, control, target, wrote and when"; else fail "P03-AC-1: schema control is missing or does not require version, control, target, wrote and when"; fi

# --- no process was signalled ---
alive3=0; n3=0
for f in $r3live; do n3=$((n3 + 1)); p=$(cat "$f" 2>/dev/null); [ -n "$p" ] && kill -0 "$p" 2>/dev/null && alive3=$((alive3 + 1)); done
if [ "$alive3" = "$n3" ] && [ "$n3" = 3 ]; then pass "P03-AC-1: after all the requests the fixture's 3 live sessions are still alive (no process signalled)"; else fail "P03-AC-1: only $alive3 of $n3 live sessions are alive after the requests"; fi
if [ ! -s "$tmp/gh.log" ] && [ ! -e "$r3home/token-was-run" ]; then pass "P03-AC-1: the requests called no gh and ran no token script"; else fail "P03-AC-1: gh was called or the token script was run by a request"; fi
kill -9 "$r3pid" 2>/dev/null; wait "$r3pid" 2>/dev/null


[ $fails = 0 ] || { echo "$fails failed"; exit 1; }
echo "all passed"
