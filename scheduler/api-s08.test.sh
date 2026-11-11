#!/bin/bash
# S08-AC-4: the readers behave as before the harness seam. A stale background cut-off line on session.stderr (left by an
# earlier part, before a resume) must not hide an idle-by-limit log: api.py's at_limit and loop.sh's idle_by_limit.
#   bash scheduler/api-s08.test.sh   (make test)
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

d=$tmp/node/N01; mkdir -p "$d"
{
	echo '{"type":"system","subtype":"init","timestamp":"2026-11-09T09:01:05Z","session_id":"sess-s1"}'
	echo '{"type":"assistant","timestamp":"2026-11-09T09:30:00Z","message":{"content":[{"type":"tool_use","id":"u01","name":"Bash","input":{"command":"make test"}}]}}'
	echo '{"type":"rate_limit_event","timestamp":"2026-11-09T10:40:00Z","rate_limit_info":{"status":"rejected","resetsAt":1794236400,"rateLimitType":"five_hour"}}'
} >"$d/session.jsonl"
# left by an earlier part of the session; a resume appends to this file
echo 'Claude Code: background tasks still running after the last turn; stopping them' >"$d/session.stderr"

# (a) api.py at_limit
got=$(python3 -I -B -c '
import sys
sys.path.insert(0, sys.argv[1])
import api
print(api.at_limit(sys.argv[2]))' "$src" "$d" 2>&1 | tail -n 1)
if [ "$got" = True ]; then pass "S08-AC-4: api at_limit is true for a log ending in a rejected reading with a reset, despite a stale cut-off line on session.stderr"
else fail "S08-AC-4: api at_limit is '$got' (not True) with a stale cut-off line on session.stderr"; fi

# (b) loop.sh idle_by_limit, its functions cut out of the script
here=$src
awk '/^(hev|idle_tail|idle_by_limit)\(\) \{/ { p = 1 } p { print } p && /^}/ { p = 0 } /^idle_by_limit\(\) \{.*\}$/ { p = 0 }' "$src/loop.sh" >"$tmp/fn.sh"
out=$(export here; . "$tmp/fn.sh"; idle_by_limit "$d" 2>&1); rc=$?
if [ $rc = 0 ] && [ "$out" = "1794236400 sess-s1" ]; then pass "S08-AC-4: loop.sh idle_by_limit sees the session idle by the limit (reset and session id) despite a stale cut-off line"
else fail "S08-AC-4: loop.sh idle_by_limit gave rc $rc, '$out' (want 0, '1794236400 sess-s1') with a stale cut-off line"; fi

[ $fails = 0 ]
