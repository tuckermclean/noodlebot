#!/bin/sh
# Tests scheduler/api.py (node P01), part: P01-AC-9, the server never opens ~/.config/noodlebot/{credentials,github-token}.
#   sh scheduler/api-fifo.test.sh   (make test)
# The other parts (api.test.sh and the rest) run at the same time on their own fixture copy; helpers in testdata/lib/api-common.sh
# and api-setup.sh. This part takes its own AC-2 snapshot over its server's run and scans its own responses for the tokens
# (a FAIL line on a finding; the PASS lines of those are printed by api-events.test.sh).
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d)
. "$src/testdata/lib/api-common.sh"
. "$src/testdata/lib/api-setup.sh"
up=0
record_all
# How "never reads" is checked: the server is restarted, and two FIFOs (credentials, github-token) are created next to
# repos in ~/.config/noodlebot/. A process opening a FIFO for reading releases a writer that waits on it; the writer then
# creates a marker file. So any open() of those files, at start or while serving, shows. (A mode 000 file would only make
# a read fail quietly; and a FIFO may not be left for the AC-2 snapshot, whose cksum would block on it: the FIFOs are
# removed again before the snapshot below.) The fixture's token script is checked by its never-run marker.
cfg=$home/.config/noodlebot; fifo_pids=''
for f in credentials github-token; do
	mkfifo "$cfg/$f"
	( : >"$cfg/$f"; : >"$tmp/fifo-read-$f" ) </dev/null >/dev/null 2>&1 &
	fifo_pids="$fifo_pids $!"
done
if start_server; then up=1; pass "P01-AC-9: api.py starts with unreadable-by-blocking files next to repos"; else fail "P01-AC-9: api.py did not start (or blocked) with the FIFOs in ~/.config/noodlebot: $(tail -c 200 "$tmp/api.out")"; fi
for path in /v1/repos /v1/repos/acme/alpha /v1/repos/acme/beta /v1/repos/acme/alpha/nodes /v1/repos/acme/beta/nodes /v1/repos/acme/alpha/sessions /v1/repos/acme/beta/sessions /v1/schema/repos /v1/schema/repo /v1/schema/nodes /v1/schema/node /v1/schema/sessions; do
	req GET $path
done
for id in N01 N02 N03 N04 N05 N06 N07 N08 N09 N10 N11; do req GET /v1/repos/acme/alpha/nodes/$id; done
for id in B01 B02; do req GET /v1/repos/acme/beta/nodes/$id; done
req GET /v1/nothing; req POST /v1/repos
t0=$(date +%s%N)   # the requests are done: the serving time of the window below counts from here
# the event stream stays open: read it for 2 seconds from the first line of each status log
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
cat "$tmp"/curl.[1-3] "$tmp/since0" "$tmp/since0b" 2>/dev/null >>"$tmp/allresp"
# The window of the "never opened" check: as long as the one this check had before the reads ran at the same time (three
# 2-second reads in a row, then a second: about 7 s of serving after the requests, three and more runs of the HEAD watcher,
# NOODLEBOT_API_HEAD_CHECK=2), and a full second after the last read for a released writer to create its marker. The
# watcher's runs are not observable (api.py logs the HEAD only when it moved, and touches no file), so the time is fixed.
sleep 1
while [ $(( ($(date +%s%N) - t0) / 1000000 )) -lt 7000 ]; do sleep 0.2; done
for f in credentials github-token; do
	if [ ! -e "$tmp/fifo-read-$f" ]; then pass "P01-AC-9: the server never opened ~/.config/noodlebot/$f"; else fail "P01-AC-9: the server opened ~/.config/noodlebot/$f"; fi
done
for p in $fifo_pids; do kill -9 "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
rm -f "$cfg/credentials" "$cfg/github-token"
if [ ! -e "$home/token-was-run" ]; then pass "P01-AC-9: the token script ~/.config/noodlebot/token was never run"; else fail "P01-AC-9: the token script was run"; fi
quiet_final
[ $up = 1 ] || fail "P01-AC-9: the server did not run"

[ $fails = 0 ] || { echo "$fails failed"; exit 1; }
echo "all passed"
