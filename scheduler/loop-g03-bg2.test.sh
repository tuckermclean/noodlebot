#!/bin/bash
# G03: feedback.py in the background, findings of the review of its first version: a failed open-PR list runs no feedback.py on the emptied list, a run that printed one PR's line and then failed hands nothing over, an owner's answer recorded by report is never handed over as feedback, and a unit waiting for its turn keeps its place while a run is in flight. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g03.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g03.sh"

# The fake gh also: fails the api calls of PR 12 while $GD/fb.fail.12 exists (a run that prints PR 11's line, then fails), and
# sleeps 0.5 s in each api call while $GD/fb.slow2 exists (a run of feedback.py is then in flight for a while).
cat >"$tmp/g03b-sed" <<'EOS'
	[ -e "$GD/fb.slow2" ] && sleep 0.5
EOS
sed -i '/^\t*echo "\$3" >>"\$GD\/fbcalls"/r '"$tmp/g03b-sed" "$tmp/bin6/gh"
cat >"$tmp/g03b-sed" <<'EOS'
	case "$3" in */12/*) [ -e "$GD/fb.fail.12" ] && { echo "gh: HTTP 502" >&2; exit 1; } ;; esac
EOS
sed -i '/^\t\[ -e "\$GD\/fb\.fail" \]/r '"$tmp/g03b-sed" "$tmp/bin6/gh"
# The loop's own copy of report.py is a stub: it records an answer for PR 13 when $GD/ans.go exists, after the feedback run ended.
cat >"$tmp/nb6/scheduler/report.py" <<'EOS'
import os, subprocess, sys, time
GD = os.environ["GD"]
if not os.path.exists(GD + "/ans.go"):
    sys.exit(0)
st = sys.argv[sys.argv.index("--state") + 1]
end = time.time() + 10
while time.time() < end:
    ps = subprocess.run(["ps", "-eo", "args="], capture_output=True, text=True).stdout.splitlines()
    if not [l for l in ps if "feedback.py" in l and "--state " + st in l and " mark" not in l]:
        break
    time.sleep(0.05)
os.makedirs(st + "/pr/13", exist_ok=True)
with open(st + "/pr/13/ANSWER.md", "w") as f:
    f.write("# Answer\n\nThe owner's answer, posted by o on GitHub at 2026-11-10T10:00:00Z: "
            "https://github.com/o/up/pull/13#issuecomment-323\n\nok\n")
os.remove(GD + "/ans.go")
sys.exit(3)
EOS
# loopq: the loop with the start queue and the report on (the fixture's loop6 forces SCHED_REPORT=0).
loopq() {
	NOODLEBOT_DATA=$data6 PATH=$tmp/bin6:$PATH SCHED_REPORT=1 SCHED_RAMP=1 SCHED_START_GAP=2 SCHED_TICK=1 SCHED_POLL=0.2 \
		bash "$tmp/nb6/scheduler/loop.sh" o/up >>"$tmp/g01-loop.out" 2>&1 &
	pids+=("$!"); lp6=$!
}
g03b_failed() { grep -c 'feedback.py failed' "$state/status.log"; }
g03b_failedis() { [ "$(g03b_failed)" = "$1" ]; }
g03b_calls() { wc -l <"$GD/fbcalls" 2>/dev/null || echo 0; }
g03b_callsge() { [ "$(g03b_calls)" -ge "$1" ]; }
g03b_seen() { grep -qF "$(fburl "$1" "$2" "$3")" "$GD/fbseen.$4" 2>/dev/null; }
g03b_recn() { cat "$state/feedback/$1" 2>/dev/null | cksum; ls "$state/feedback/$1" 2>&1 | cksum; }

rl6 0.01 $(($(date +%s) + 7200))
loopq
ok "G03 setup: the first tick records the open PRs' feedback" g03_first
x=$state/node/X01 y=$state/node/X02

# U-3, finding 4: a run that prints PR 11's line and then fails (PR 12's api calls fail) hands nothing over.
ok "U-3 setup (finding 4): no session of X01 or X02 runs" sh -c "[ ! -e '$x/session.pid' ] && [ ! -e '$y/session.pid' ]"
r11=$(g03b_recn 11); n11=$(s6runs fbnode.11); f0=$(g03b_failed)
fbadd 11 conversation 141 'node point (a run that fails for PR 12)'
touch "$GD/fb.fail.12"
ok "U-3 setup (finding 4): the run that fails is one status-log line" waitf 20 g03b_failedis $((f0 + 1))
wait_ticks 2
ok "U-3 (finding 4): a run that printed PR 11's line and failed hands nothing over: no new session of X01" runsis fbnode.11 "$n11"
ok "U-3 (finding 4): no FEEDBACK.md in X01's folder" test ! -e "$x/FEEDBACK.md"
ok "U-3 (finding 4): state/feedback/11 is unchanged" test "$(g03b_recn 11)" = "$r11"
rm -f "$GD/fb.fail.12"
ok "U-3 (finding 4): after the failure is cleared PR 11's feedback is handed over" waitf 20 runsis fbnode.11 $((n11 + 1))
ok "U-3 (finding 4): with the item" g03b_seen 11 conversation 141 fbnode.11.$((n11 + 1))
ok "U-3 setup (finding 4): that session ended" waitf 10 g03_idle "$x"
wait_ticks 1
ok "U-3 (finding 4): and handed over once" runsis fbnode.11 $((n11 + 1))

# A second loop, started while the open-PR list fails.
kill "$lp6"
ok "G03 setup: the first loop is gone" waitf 20 g01_gone "$lp6"
r11=$(g03b_recn 11); r12=$(g03b_recn 12); n11=$(s6runs fbnode.11); n12=$(s6runs fbnode.12)
touch "$GD/open.fail"
loopq
# U-3, finding 1: this loop starts while the open-PR list fails; its feedback.py must not run on the emptied list (it would
# delete the records of the open PRs, and the next good run would hand over all of their old feedback again).
wait_ticks 2
ok "U-3 (finding 1): ticks with a failed open-PR list leave PR 11's record unchanged" test "$(g03b_recn 11)" = "$r11"
ok "U-3 (finding 1): and PR 12's" test "$(g03b_recn 12)" = "$r12"
rm -f "$GD/open.fail"
c0=$(g03b_calls)
ok "U-3 setup (finding 1): a run of feedback.py has read the list again" waitf 20 g03b_callsge $((c0 + 9))
wait_ticks 2
ok "U-3 (finding 1): after the list works again no session starts for X01's old, recorded feedback" runsis fbnode.11 "$n11"
ok "U-3 (finding 1): nor for X02's" runsis fbnode.12 "$n12"
ok "U-3 setup (finding 1): no session of X01, X02 or PR 13 runs" waitf 20 sh -c "[ ! -e '$x/session.pid' ] && [ ! -e '$y/session.pid' ] && [ ! -e '$state/pr/13/session.pid' ]"

# U-3, finding 3: an owner's answer recorded on the PR (the loop's report writes ANSWER.md) is never handed over as feedback,
# also with a feedback run in flight (or finished and unread) when the answer is recorded.
touch "$GD/fb.slow2"
p=$state/pr/13
mkdir -p "$p"; echo "Q1: which one?" >"$p/QUESTION.md"
fbadd 13 conversation 323 'the owner answers the question'
ok "U-3 setup (finding 3): a run of feedback.py has listed the comment (as new feedback; the unit's QUESTION.md holds it back)" waitf 20 test -s "$state/feedback/13.md"
touch "$GD/ans.go"
ok "U-3 setup (finding 3): the answer is recorded as ANSWER.md" waitf 20 test -e "$p/ANSWER.md"
wait_ticks 3
ok "U-3 (finding 3): the owner's recorded answer is not handed over as feedback: no session of PR 13 starts" runsis fbspec.13 0
ok "U-3 (finding 3): and no FEEDBACK.md in the PR's unit" test ! -e "$p/FEEDBACK.md"

# U-2, finding 2: with the start queue on, a unit with new feedback that waits for its turn keeps its place while a run is in flight.
g03_hold fbnode.11; g03_hold fbnode.12
n11=$(s6runs fbnode.11); n12=$(s6runs fbnode.12)
( declare -A seen=(); while :; do
	for k in 11 12; do
		d=$state/node/X0$((k - 10))
		if [ -e "$d/waiting" ]; then seen[$k]=1
		elif [ "${seen[$k]:-0}" = 1 ] && [ ! -e "$d/session.pid" ]; then echo "$k at $(date +%s)" >>"$tmp/wdrop"; seen[$k]=0; fi
	done; sleep 0.05; done ) &
pids+=("$!")
fbadd 11 conversation 151 'node point (queue)'
fbadd 12 conversation 251 'node point (queue)'
ok "U-2 (finding 2): the feedback session of X01 starts" waitf 40 runsis fbnode.11 $((n11 + 1))
ok "U-2 (finding 2): the feedback session of X02 starts" waitf 40 runsis fbnode.12 $((n12 + 1))
ok "U-2 (finding 2): a unit waiting for its turn kept its waiting file while a run was in flight (not dropped and re-created)" test ! -s "$tmp/wdrop"
g03_release fbnode.11; g03_release fbnode.12

g03_stop
loop_end
