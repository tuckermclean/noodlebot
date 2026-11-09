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


# T02: usage.py --escalate. One line, "escalate: <reason>" or "no escalation: <summary>", exit 0 either way.
# The 5-hour window here is 1 h old (fallback rate u/3600 s), 4 h from its reset; with the default 30-minute
# margin it escalates when it is projected to reach 100% within 12600 s, i.e. from about 22% used.
runesc() { out=$(python3 -I "$src/usage.py" --state-root "$tmp/s" --now "$1" --escalate 2>&1); rc=$?; }
runesc_m() { out=$(USAGE_ESCALATE_MARGIN=$2 python3 -I "$src/usage.py" --state-root "$tmp/s" --now "$1" --escalate 2>&1); rc=$?; }
is_esc() { [ $rc = 0 ] && printf '%s' "$out" | grep -q '^escalate: '; }
is_no() { [ $rc = 0 ] && printf '%s' "$out" | grep -q '^no escalation: '; }

reset
ev "$tmp/s/a/node/X01/session.jsonl" 0.40 $r5 0.30 $r7
runesc $now
if is_esc; then pass "T02-AC-1: 40% after 1 h reaches 100% 90 min in, far more than the margin before the reset: escalate ($out)"; else fail "T02-AC-1 escalate: rc=$rc $out"; fi

reset
ev "$tmp/s/a/node/X01/session.jsonl" 0.21 $r5 0.30 $r7
runesc $now
if is_no; then pass "T02-AC-1: 21% after 1 h reaches 100% less than 30 minutes before the reset: no escalation ($out)"; else fail "T02-AC-1 within the margin: rc=$rc $out"; fi

reset
ev "$tmp/s/a/node/X01/session.jsonl" 0.21 $r5 0.30 $r7
runesc_m $now 10
if is_esc; then pass "T02-AC-1: USAGE_ESCALATE_MARGIN=10 lets the 21% projection escalate ($out)"; else fail "T02-AC-1 margin 10: rc=$rc $out"; fi
reset
ev "$tmp/s/a/node/X01/session.jsonl" 0.30 $r5 0.30 $r7
runesc $now
d_esc=$out d_rc=$rc
runesc_m $now 120
if is_no && printf '%s' "$d_esc" | grep -q '^escalate: ' && [ "$d_rc" = 0 ]; then pass "T02-AC-1: 30% escalates by default but not with USAGE_ESCALATE_MARGIN=120 ($out)"; else fail "T02-AC-1 margin 120: default=[$d_esc] rc=$rc $out"; fi

reset
ev "$tmp/s/a/node/X01/session.jsonl" 0.40 $r5 0.30 $r7
run $now; run $((now + 600))
ev "$tmp/s/a/node/X01/session.jsonl" 0.41 $r5 0.30 $r7
runesc $((now + 1200))
if is_no; then pass "T02-AC-1: once the burn slows (1% in 20 min) there is no escalation ($out)"; else fail "T02-AC-1 slowed burn: rc=$rc $out"; fi

reset
ev "$tmp/s/a/node/X01/session.jsonl" 0.99 $((now - 60)) 0.30 $r7
runesc $now
if is_no; then pass "T02-AC-1: a window past its reset does not escalate ($out)"; else fail "T02-AC-1 past reset: rc=$rc $out"; fi

reset
runesc $now
if is_no; then pass "T02-AC-1: no readings, no escalation ($out)"; else fail "T02-AC-1 no readings: rc=$rc $out"; fi

reset
ev "$tmp/s/a/node/X01/session.jsonl" 0.05 $r5 0.75 $r7
run $now; plain=$out
runesc $now
if is_no && printf '%s' "$plain" | grep -q 'hold: 7-day window'; then pass "T02-AC-1: a 7-day window ahead of pace alone does not escalate, though it holds ($out)"; else fail "T02-AC-1 7-day: plain=[$plain] rc=$rc $out"; fi

reset
ev "$tmp/s/a/node/X01/session.jsonl" 0.40 $r5 0.30 $r7
run $now; before=$out
runesc $now
run $now
if [ "$before" = "$out" ] && printf '%s' "$out" | grep -q '^hold: 5-hour window projected' && [ "$(field "len(d['samples5h'])")" = 1 ]; then pass "T02-AC-1: without --escalate the output is unchanged, and an --escalate run adds no sample"; else fail "T02-AC-1 unchanged: before=[$before] after=[$out]"; fi

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: all usage checks"
