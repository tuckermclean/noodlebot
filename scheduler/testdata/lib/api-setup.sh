# Shared by the parts of the P01 API test that run on the main fixture (api.test.sh, api-sessions.test.sh, api-events.test.sh,
# api-fifo.test.sh): the data, HOME and checkout copy, the fake gh, a loop lock held, the snapshot function, req, get, err,
# start_server and a few helpers. Sourced after api-common.sh; not run on its own.
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
	# one find lists the directories and the size and mtime of the other things, one more checksums the files: the same facts as
	# a stat and a cksum per file, without a process for each (no -L: like stat -c, it does not follow links; the trees hold none when the snapshots are taken).
	{
		find "$data" "$home" ! -type s ! -name api.sock ! -name api.lock ! -name loop.lock \( -type d -printf 'd %p\n' -o -printf 'f %p %s %T@\n' \)
		find "$data" "$home" -type f ! -name api.sock ! -name api.lock ! -name loop.lock -exec cksum {} +
	} | sort
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
ep() { date -u -d "$1" +%s; }
chk() { # chk <id> <what> <python expr over d>
	if [ "$(jx "$3")" = True ]; then pass "$1: $2"; else fail "$1: $2; got $(head -c 400 "$tmp/resp")"; fi
}
mt() { stat -c %Y "$1"; }
sess_is() { # sess_is <kind> <subject> <python expr over s> <what>: the session's entry satisfies the expression
	cp "$tmp/sessions.json" "$tmp/resp"
	if [ "$(jx "(lambda s: $3)(next(x for x in d['sessions'] if x['kind'] == '$1' and x['subject'] == '$2'))")" = True ]; then pass "P01-AC-5: /sessions: $1 $2 $4"; else fail "P01-AC-5: /sessions: $1 $2 $4; got $(jx "[x for x in d['sessions'] if x.get('subject') == '$2']" | head -c 500)"; fi
}
# record_all: from here every response is also appended to $tmp/allresp, which the P01-AC-9 scan of the part reads.
record_all() {
	: >"$tmp/allresp"
if command -v curl >/dev/null 2>&1; then
	req() { : >"$tmp/resp"; code=$(curl -s --max-time 10 --unix-socket "$sock" -X "$1" -o "$tmp/resp" -D "$tmp/hdr" -w '%{http_code}' "http://localhost$2" 2>/dev/null); [ -n "$code" ] || code=000; cat "$tmp/resp" >>"$tmp/allresp"; }
else
	req() { code=$(python3 -I "$tmp/client.py" "$sock" "$1" "$2" "$tmp/resp" 2>/dev/null); : >"$tmp/hdr"; cat "$tmp/resp" >>"$tmp/allresp"; }
fi
}
# quiet_final: the end-of-part checks of the AC-2 snapshot, the fake gh, the token script and the AC-9 token scan for a part
# that is not the one that prints their PASS lines (the PASS labels are printed once, by api-events.test.sh, and
# api-fifo.test.sh; passdiff compares the label counts). Each part covers its own server's run: a failure prints a FAIL
# line here, a pass prints nothing.
quiet_final() {
	snap >"$tmp/snap.after"
	cmp -s "$tmp/snap.before" "$tmp/snap.after" || fail "P01-AC-2: files changed (in this part's run): $(diff "$tmp/snap.before" "$tmp/snap.after" | head -n 6 | tr '\n' ' ')"
	[ ! -s "$tmp/gh.log" ] || fail "P01-AC-2: gh was called: $(head -n 3 "$tmp/gh.log" | tr '\n' ' ')"
	[ ! -e "$home/token-was-run" ] || fail "P01-AC-2: the token script was run"
	while IFS= read -r tok; do
		[ -n "$tok" ] || continue
		if grep -F -q -e "$tok" "$tmp"/allresp "$tmp/api.out" "$tmp/second.out" 2>/dev/null; then fail "P01-AC-9: token ${tok%"${tok#????}"}... appears in a response or in the server's output"; fi
	done <"$fix/tokens.txt"
}
: >"$tmp/second.out"   # api.test.sh's second server writes it; the other parts have none (the token scans read it)
