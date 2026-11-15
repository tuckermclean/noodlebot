#!/bin/sh
# Tests the window of pickup.py's budget (S09-AC-5: "No more than PICKUP_RUNS runs start in one 5-hour window across all
# loops"), over the fake forge. Added after the review of the slice 3 code: runs counted in the stand-in window used while
# usage.json has no future five_hour reset must still count when a known reset appears.
#   sh scheduler/pickup-window.test.sh   (make test)
#
# THE CONTRACT these cases fix (the rest of the budget is the contract of scheduler/pickup.test.sh, block 3):
#   A run counts in every five-hour window whose span holds its start time. The span of a known window is
#   (resetsAt - 5 h) .. resetsAt, resetsAt being the five_hour window's reset in $NOODLEBOT_DATA/state/usage.json. Without a
#   future five_hour reset (no usage.json, no five_hour window, or one already past its reset) the window is a stand-in, the
#   five hours from the first run counted. So:
#     - runs counted while no reset was known are counted again by a known window whose span holds their start time, whatever
#       the window's reset (the probe: PICKUP_RUNS=3, three runs, then a reset 4 h ahead: no further run);
#     - runs that started before the span of a known window (resetsAt - 5 h later than they) do not count in it (a new
#       window: a count of 0), whether they were counted in a stand-in window or in an earlier known one.
#   With the budget spent the items get the deterministic reply, are handled, and the first such tick of a window prints
#   "pickup: no run: budget ..." (the other contract lines of scheduler/pickup.test.sh). The cases read nothing from the
#   record's file: only the runs that start (the fake harness's `small` calls) and what pickup.py prints. No fixed sleep:
#   the windows are set by the offsets of usage.json from the wall clock (runs start "now").
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
for v in $(env | cut -d= -f1 | grep -E '^(SCHED_|FAKE_|PICKUP|NOODLEBOT_|USAGE_)'); do unset "$v"; done
unset GH_TOKEN
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
ok() { name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
T=$src/testdata/pickup
S5=$tmp/S09/WIN
mkdir -p "$S5"
tool() { python3 -I "$T/tool.py" "$@"; }
B5ENV="PICKUP_RUNS=3"
export B5ENV
# b5world <root> <name>: a state folder state/<name> under $S5/<root>/, its fake forge
b5world() {
	mkdir -p "$S5/$1/state" "$S5/$1/cwd-$2" "$S5/$1/wt" "$S5/$1/clone"
	cp -R "$T/state" "$S5/$1/state/$2"; cp -R "$T/forge" "$S5/$1/fk-$2"
	mkdir -p "$S5/$1/state/$2/pickup/pending"
}
b5pk() {
	r=$1; n=$2; shift 2
	(cd "$S5/$r/cwd-$n" && env NOODLEBOT_DATA="$S5/$r" SCHED_HARNESS=fake FAKE_HARNESS_SMALL_SCRIPT="$S5/$r/ev-$n" FAKE_HARNESS_LOG="$S5/$r/h.log" $B5ENV \
		python3 -I "$src/pickup.py" --repo "fake:$S5/$r/fk-$n" --state "$S5/$r/state/$n" --owner owner --clone "$S5/$r/clone" \
		--worktrees "$S5/$r/wt" --version 9.9 --signature SIG-9 "$@")
}
pend9() { # pend9 <state> <id>
	python3 -I -c '
import json, sys
i = int(sys.argv[1])
json.dump({"id": i, "url": "https://github.com/owner/repo/issues/13#issuecomment-%d" % i, "issue": 13, "where": "home", "created_at": "2026-06-02T11:00:00Z",
           "author": {"login": "owner", "is_bot": False, "is_owner": True}, "body": "pending %d" % i,
           "reply": "Not recorded as an answer: no question is waiting on this issue."}, open(sys.argv[2], "w"))' "$2" "$1/pickup/pending/$2.json"
}
# b5tick <root> <name> <id>: one owner comment becomes pending, the session would answer it with a note; one tick
b5tick() {
	pend9 "$S5/$1/state/$2" "$3"
	tool script "$S5/$1/ev-$2" "$(printf '[{"item": %s, "action": "note", "reason": "r"}]' "$3")"
	b5pk "$1" "$2" run >"$S5/$1/$2.$3.out" 2>"$S5/$1/$2.$3.err"
}
# b5usage <root> <five reset in s>: a usage.json with an allowed five_hour window resetting that many seconds from now
b5usage() {
	python3 -I - "$S5/$1/state/usage.json" "$2" <<'PY'
import json, sys, time
now = int(time.time())
json.dump({"windows": {"five_hour": {"resetsAt": now + int(sys.argv[2]), "utilization": 0.2, "status": "allowed"},
                       "seven_day": {"resetsAt": now + 6 * 86400, "utilization": 0.1, "status": "allowed"}},
           "hold": False, "reason": ""}, open(sys.argv[1], "w"))
PY
}
b5small() { n=$(grep -c '^small ' "$S5/$1/h.log" 2>/dev/null); echo "${n:-0}"; }
b5handled() { grep -qx "$3" "$S5/$1/state/$2/pickup/handled" 2>/dev/null; }
b5said() { n=$(grep -ci '^pickup: no run' "$S5/$1/$2.$3.out" 2>/dev/null); echo "${n:-0}"; }
b5replies() { tool count "$S5/$1/fk-$2" 13 "Not recorded as an answer"; }
ticks() { r=$1; shift; for i in "$@"; do b5tick "$r" w "$i"; done; }

# P (the probe): three runs with no usage.json, then a five_hour reset 4 h ahead (span: 1 h ago .. +4 h holds them): no more
( b5world P w; ticks P 9101 9102 9103; b5usage P 14400; ticks P 9104 9105 ) &
# N (control): three runs with no usage.json, then a reset 6 h ahead (span +1 h .. +6 h starts after them): a new window, 3 more
( b5world N w; ticks N 9101 9102 9103; b5usage N 21600; ticks N 9104 9105 9106 9107 ) &
# K (known then later): three runs in a known window (reset +1 h), then a reading with reset +6 h: a new window, 3 more
( b5world K w; b5usage K 3600; ticks K 9101 9102 9103 9104; b5usage K 21600; ticks K 9105 9106 9107 9108 ) &
# H (held): three runs in a known window (reset +4 h), the file unchanged: still no more
( b5world H w; b5usage H 14400; ticks H 9101 9102 9103 9104 9105 ) &
wait

echo "== S09-AC-5: runs counted without a known reset count in the known window that holds them"
ok "S09-AC-5: P: three runs without a known reset, then a window (reset +4 h) holding them: no further run (3 runs in all)" test "$(b5small P)" = 3
ok "S09-AC-5: P: the 4th and 5th items get the deterministic reply, one each, and are handled" \
	sh -c '[ "$1" = 2 ]' _ "$(b5replies P w)"
ok "S09-AC-5: P: ... both handled" sh -c 'grep -qx 9104 "$1" && grep -qx 9105 "$1"' _ "$S5/P/state/w/pickup/handled"
ok "S09-AC-5: P: the 4th tick says \"pickup: no run: budget\" once, the 5th says nothing (one line in the window)" \
	sh -c '[ "$1" = 1 ] && [ "$2" = 0 ] && grep -qi "^pickup: no run.*budget" "$3"' _ "$(b5said P w 9104)" "$(b5said P w 9105)" "$S5/P/w.9104.out"
ok "S09-AC-5: P: the first three runs said nothing" test "$(b5said P w 9101)" = 0 -a "$(b5said P w 9103)" = 0

echo "== S09-AC-5: runs before the span of a known window do not count in it"
ok "S09-AC-5: N: runs counted before the start of the new window (reset +6 h) do not count: its three runs start (6 in all)" test "$(b5small N)" = 6
ok "S09-AC-5: N: the 4th run of the new window (the 7th item) does not start and gets the deterministic reply, handled" \
	sh -c '[ "$1" = 1 ] && grep -qx 9107 "$2"' _ "$(b5replies N w)" "$S5/N/state/w/pickup/handled"
ok "S09-AC-5: N: the budget line comes with the 7th item, not with the runs of the new window" \
	test "$(b5said N w 9107)" = 1 -a "$(b5said N w 9104)" = 0 -a "$(b5said N w 9106)" = 0
ok "S09-AC-5: K: runs in a known window, then a reading with a later reset (+6 h): the count starts from 0 (3+3 runs)" test "$(b5small K)" = 6
ok "S09-AC-5: K: the 4th item of each window gets the reply, one line each" \
	sh -c '[ "$1" = 2 ] && [ "$2" = 1 ] && [ "$3" = 1 ]' _ "$(b5replies K w)" "$(b5said K w 9104)" "$(b5said K w 9108)"
ok "S09-AC-5: H: the same known window, unchanged: 3 runs in all, the 4th and 5th items get the reply" \
	sh -c '[ "$1" = 3 ] && [ "$2" = 2 ]' _ "$(b5small H)" "$(b5replies H w)"

[ "$fails" -eq 0 ] || { echo "FAIL: $fails check(s) failed"; exit 1; }
echo "all passed"
