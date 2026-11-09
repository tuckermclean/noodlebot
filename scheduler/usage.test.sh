#!/bin/sh
# Tests scheduler/usage.py: reading the plan's windows from session logs, and when to hold new sessions.
#   sh scheduler/usage.test.sh   (make test)
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
now=1800000000
# ev <file> <5h util> <5h resetsAt> <7d util> <7d resetsAt> [5h status]: append a rate_limit_event.
ev() {
	mkdir -p "$(dirname "$1")"
	printf '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":%s,"resetsAt":%s,"status":"%s"},"seven_day":{"utilization":%s,"resetsAt":%s,"status":"allowed"}}}}\n' \
		"$2" "$3" "${6:-allowed}" "$4" "$5" >>"$1"
}
run() { out=$(python3 -I "$src/usage.py" --state-root "$tmp/s" --now "$1" 2>&1); rc=$?; }
field() { python3 -I -c "import json,sys; d=json.load(open('$tmp/s/usage.json')); print(eval(sys.argv[1]))" "$1"; }
reset() { rm -rf "$tmp/s"; mkdir -p "$tmp/s"; }
r5=$((now + 4 * 3600)) r7=$((now + 3 * 86400))   # 1 h into the 5-hour window; 4 of 7 days into the week

reset
ev "$tmp/s/a/node/X01/session.jsonl" 0.05 $r5 0.30 $r7
ev "$tmp/s/b/issue/7/session.jsonl" 0.10 $r5 0.31 $r7
echo 'not json' >>"$tmp/s/a/node/X01/session.jsonl"
ev "$tmp/s/a/node/X01/session.jsonl" 0.08 $((r5 - 5 * 3600)) 0.20 $r7
run $now
if [ $rc = 0 ] && [ "$(field "d['windows']['five_hour']['utilization']")" = 0.1 ]; then pass "the current window's highest reading wins, across repositories, older windows and bad lines ignored"; else fail "current reading: $out"; fi
if printf '%s' "$out" | grep -q '^open:'; then pass "light use is open: $out"; else fail "light use: $out"; fi

reset
ev "$tmp/s/a/node/X01/session.jsonl" 0.40 $r5 0.30 $r7
run $now
if printf '%s' "$out" | grep -q '^hold: 5-hour window projected'; then pass "40% after 1 h projects past 90%: hold"; else fail "fast burn: $out"; fi

reset
ev "$tmp/s/a/node/X01/session.jsonl" 0.40 $r5 0.30 $r7
run $now; run $((now + 600))
ev "$tmp/s/a/node/X01/session.jsonl" 0.41 $r5 0.30 $r7
run $((now + 1200))
if printf '%s' "$out" | grep -q '^open:' && [ "$(field "len(d['samples5h'])")" -ge 2 ]; then pass "once the burn slows (1% in 20 min) the recent rate opens again: $out"; else fail "slowed burn: $out"; fi

reset
ev "$tmp/s/a/node/X01/session.jsonl" 0.05 $r5 0.75 $r7
run $now
if printf '%s' "$out" | grep -q 'hold: 7-day window 75% used at 57% of the week'; then pass "7-day ahead of pace: hold"; else fail "7-day pace: $out"; fi

reset
ev "$tmp/s/a/node/X01/session.jsonl" 0.20 $r5 0.30 $r7 rejected
run $now
if printf '%s' "$out" | grep -q 'hold: five-hour window rejected'; then pass "a rejected window holds"; else fail "rejected: $out"; fi

reset
ev "$tmp/s/a/node/X01/session.jsonl" 0.99 $((now - 60)) 0.30 $r7
run $now
if printf '%s' "$out" | grep -q '^open:'; then pass "a window past its reset no longer holds"; else fail "past reset: $out"; fi

reset
run $now
if [ $rc = 0 ] && printf '%s' "$out" | grep -q 'open: no reading yet'; then pass "no readings: open"; else fail "no readings: $out"; fi

reset
ev "$tmp/s/a/issue/7/session.jsonl" 0.20 $r5 0.30 $r7 rejected
run $now
issue_out=$out
reset
ev "$tmp/s/a/pr/12/session.jsonl" 0.20 $r5 0.30 $r7 rejected
run $now
if printf '%s' "$issue_out" | grep -q '^hold:' && printf '%s' "$out" | grep -q '^hold:'; then pass "G01-AC-5: a rejected window logged only by an update session (pr/<N>) holds like an issue session's"; else fail "G01-AC-5: update session rate-limit event ignored by the throttle: $out"; fi
reset
ev "$tmp/s/a/pr/12/session.jsonl" 0.40 $r5 0.30 $r7
run $now
if printf '%s' "$out" | grep -q '^hold: 5-hour window projected'; then pass "G01-AC-5: a fast burn logged only by an update session holds"; else fail "G01-AC-5: update session burn ignored by the throttle: $out"; fi

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: all usage checks"
