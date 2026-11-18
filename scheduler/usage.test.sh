#!/bin/sh
# Tests scheduler/usage.py: reading the plan's windows from session logs, and when to hold new sessions.
#   sh scheduler/usage.test.sh   (make test)
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d) && [ -d "$tmp" ] || exit 1
trap 'rm -rf "$tmp"' EXIT
fails=0
unset USAGE_7D_PACE USAGE_7D_MARGIN USAGE_5H_LIMIT   # T03-AC-7: results do not depend on the caller's settings
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
USAGE_7D_PACE=1; export USAGE_7D_PACE   # T03-AC-2: the pace hold is opt-in
run $now
if printf '%s' "$out" | grep -q 'hold: 7-day window 75% used at 57% of the week'; then pass "7-day ahead of pace: hold"; else fail "7-day pace: $out"; fi
unset USAGE_7D_PACE

# T03: the 7-day pace hold is opt-in (USAGE_7D_PACE=1); a rejected 7-day window always holds.
# ev7 <file> <5h util> <5h resetsAt> <7d util> <7d resetsAt> <7d status>: a rate_limit_event with a 7-day status.
ev7() {
	mkdir -p "$(dirname "$1")"
	printf '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":%s,"resetsAt":%s,"status":"allowed"},"seven_day":{"utilization":%s,"resetsAt":%s,"status":"%s"}}}}\n' \
		"$2" "$3" "$4" "$5" "$6" >>"$1"
}
for p in unset 0; do
	if [ $p = unset ]; then unset USAGE_7D_PACE; else USAGE_7D_PACE=0; export USAGE_7D_PACE; fi
	reset
	ev "$tmp/s/a/node/X01/session.jsonl" 0.05 $r5 0.75 $r7
	run $now
	if printf '%s' "$out" | grep -q '^open:.*7-day 75% at 57% of the week'; then pass "T03-AC-1: USAGE_7D_PACE=$p, 75% used at 57% of the week is open with its reading: $out"; else fail "T03-AC-1: USAGE_7D_PACE=$p: $out"; fi
	if [ "$(field "d['windows']['seven_day']['utilization']")" = 0.75 ] && [ "$(field "round(d['weekElapsed'], 2)")" = 0.57 ] && [ "$(field "d['limits'].get('seven_day_pace')")" = False ]; then pass "T03-AC-1: USAGE_7D_PACE=$p, usage.json keeps the window and weekElapsed, seven_day_pace false"; else fail "T03-AC-1: USAGE_7D_PACE=$p usage.json: $(cat "$tmp/s/usage.json" 2>&1 | tr -d '\n ')"; fi
	reset
	ev7 "$tmp/s/a/node/X01/session.jsonl" 0.05 $r5 0.30 $r7 rejected
	run $now
	if printf '%s' "$out" | grep -q '^hold: seven-day window rejected'; then pass "T03-AC-3: USAGE_7D_PACE=$p, a rejected 7-day window holds"; else fail "T03-AC-3: USAGE_7D_PACE=$p rejected 7-day: $out"; fi
done
# The weekly warning is not a hold: a 7-day window that is only allowed_warning leaves the throttle open
# (pace hold off), and a 5-hour window that is allowed_warning still holds.
reset
ev7 "$tmp/s/a/node/X01/session.jsonl" 0.05 $r5 0.77 $r7 allowed_warning
run $now
if printf '%s' "$out" | grep -q '^open:.*7-day 77% at 57% of the week'; then pass "a 7-day window that is only allowed_warning is open: $out"; else fail "7-day allowed_warning: $out"; fi
reset
ev "$tmp/s/a/node/X01/session.jsonl" 0.05 $r5 0.30 $r7 allowed_warning
run $now
if printf '%s' "$out" | grep -q '^hold: five-hour window allowed_warning'; then pass "a 5-hour window that is allowed_warning still holds"; else fail "5-hour allowed_warning: $out"; fi
USAGE_7D_PACE=1; export USAGE_7D_PACE
reset
ev7 "$tmp/s/a/node/X01/session.jsonl" 0.05 $r5 0.30 $r7 rejected
run $now
if printf '%s' "$out" | grep -q '^hold: seven-day window rejected'; then pass "T03-AC-3: USAGE_7D_PACE=1, a rejected 7-day window holds"; else fail "T03-AC-3: USAGE_7D_PACE=1 rejected 7-day: $out"; fi
reset
ev "$tmp/s/a/node/X01/session.jsonl" 0.05 $r5 0.65 $r7
run $now
if printf '%s' "$out" | grep -q '^open:.*7-day 65% at 57% of the week'; then pass "T03-AC-2: USAGE_7D_PACE=1, a window within the margin is open: $out"; else fail "T03-AC-2: within margin: $out"; fi
if [ "$(field "d['limits'].get('seven_day_pace')")" = True ]; then pass "T03-AC-2: USAGE_7D_PACE=1, limits.seven_day_pace is true"; else fail "T03-AC-2: seven_day_pace: $(cat "$tmp/s/usage.json" 2>&1 | tr -d '\n ')"; fi
reset
ev "$tmp/s/a/node/X01/session.jsonl" 0.05 $r5 0.75 $r7
USAGE_7D_MARGIN=0.25; export USAGE_7D_MARGIN
run $now
unset USAGE_7D_MARGIN
if printf '%s' "$out" | grep -q '^open:.*7-day 75% at 57% of the week'; then pass "T03-AC-2: USAGE_7D_MARGIN=0.25 opens the 75%-at-57% window: $out"; else fail "T03-AC-2: margin 0.25: $out"; fi
unset USAGE_7D_PACE

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

# S09-AC-2: a pickup run's usage readings (DIR/<repo>/pickup/<ts>/session.jsonl, as events.jsonl is rebuilt from it) count in
# the windows like a session's. A non-session entry under pickup/ (the `handled` file, the `pending/` folder, which has no
# session log) is skipped without error. Scratch: $tmp/S09.
unset USAGE_7D_PACE USAGE_7D_MARGIN USAGE_5H_LIMIT
s9=$tmp/S09
run9() { out=$(python3 -I "$src/usage.py" --state-root "$s9" --now "$1" 2>&1); rc=$?; }
reset9() { rm -rf "$s9"; mkdir -p "$s9"; }
reset9
ev "$s9/a/pickup/20261114T100000Z/session.jsonl" 0.20 $r5 0.30 $r7 rejected
run9 $now
if [ $rc = 0 ] && printf '%s' "$out" | grep -q '^hold: five-hour window rejected'; then pass "S09-AC-2: a rejected window logged only by a pickup run holds like a session's"; else fail "S09-AC-2: pickup rejected reading ignored (rc $rc): $out"; fi
reset9
ev "$s9/a/pickup/20261114T100000Z/session.jsonl" 0.40 $r5 0.30 $r7
run9 $now
if printf '%s' "$out" | grep -q '^hold: 5-hour window projected'; then pass "S09-AC-2: a fast burn logged only by a pickup run is projected"; else fail "S09-AC-2: pickup burn ignored: $out"; fi
reset9
ev "$s9/a/node/X01/session.jsonl" 0.05 $r5 0.30 $r7
ev "$s9/b/pickup/20261114T100000Z/session.jsonl" 0.12 $r5 0.33 $r7
run9 $now
if [ $rc = 0 ] && [ "$(python3 -I -c "import json; d=json.load(open('$s9/usage.json')); print(d['windows']['five_hour']['utilization'], d['windows']['seven_day']['utilization'])")" = "0.12 0.33" ]; then pass "S09-AC-2: a pickup run's reading is merged with a session's across repositories (the highest wins, both windows)"; else fail "S09-AC-2: merged pickup reading: $out $(tr -d '\n ' <"$s9/usage.json" 2>&1)"; fi
reset9
ev "$s9/a/pickup/20261114T100000Z/session.jsonl" 0.15 $r5 0.30 $r7
printf '%s\n' 1799999000.1 >"$s9/a/pickup/handled"
mkdir -p "$s9/a/pickup/pending"; echo '{"id": 7}' >"$s9/a/pickup/pending/7.json"
mkdir -p "$s9/a/pickup/20261114T110000Z"; echo 'notes' >"$s9/a/pickup/20261114T110000Z/run.txt"
run9 $now
if [ $rc = 0 ] && ! printf '%s' "$out" | grep -qi 'traceback\|error' && [ "$(python3 -I -c "import json; print(json.load(open('$s9/usage.json'))['windows']['five_hour']['utilization'])")" = 0.15 ]; then pass "S09-AC-2: a handled file, a pending/ folder and a run folder without a log are skipped without error, the run's reading still counts"; else fail "S09-AC-2: non-session entries under pickup/ (rc $rc): $out"; fi
reset9
ev "$s9/a/pickup/20261114T100000Z/session.jsonl" 0.20 $((now - 60)) 0.30 $r7 rejected
run9 $now
if printf '%s' "$out" | grep -q '^open:'; then pass "S09-AC-2: a pickup reading past its reset no longer holds"; else fail "S09-AC-2: pickup reading past reset: $out"; fi


# A07-AC-4: a running adoption session's usage readings (DIR/<repo>/adopt/<key>/session.jsonl: the scaffold, an area or the plan
# unit) count in the windows like a node's or an issue's session. Scratch: $tmp/A07.
unset USAGE_7D_PACE USAGE_7D_MARGIN USAGE_5H_LIMIT
sa=$tmp/A07
runa() { out=$(python3 -I "$src/usage.py" --state-root "$sa" --now "$1" 2>&1); rc=$?; }
resa() { rm -rf "$sa"; mkdir -p "$sa"; }
resa
ev "$sa/a/adopt/scaffold/session.jsonl" 0.20 $r5 0.30 $r7 rejected
runa $now
if [ $rc = 0 ] && printf '%s' "$out" | grep -q '^hold: five-hour window rejected'; then pass "A07-AC-4: a rejected window logged only by an adoption session holds like a node's"; else fail "A07-AC-4: adoption rejected reading ignored (rc $rc): $out"; fi
resa
ev "$sa/a/adopt/one/session.jsonl" 0.40 $r5 0.30 $r7
runa $now
if printf '%s' "$out" | grep -q '^hold: 5-hour window projected'; then pass "A07-AC-4: a fast burn logged only by an area's adoption session is projected"; else fail "A07-AC-4: adoption burn ignored: $out"; fi
resa
ev "$sa/a/node/X01/session.jsonl" 0.05 $r5 0.30 $r7
ev "$sa/b/adopt/plan/session.jsonl" 0.12 $r5 0.33 $r7
runa $now
if [ $rc = 0 ] && [ "$(python3 -I -c "import json; d=json.load(open('$sa/usage.json')); print(d['windows']['five_hour']['utilization'], d['windows']['seven_day']['utilization'])")" = "0.12 0.33" ]; then pass "A07-AC-4: an adoption session's reading is merged with a node session's across repositories (the highest wins, both windows)"; else fail "A07-AC-4: merged adoption reading: $out $(tr -d '\n ' <"$sa/usage.json" 2>&1)"; fi

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: all usage checks"
