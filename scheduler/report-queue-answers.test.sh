#!/bin/sh
# Tests scheduler/report.py and scheduler/status.sh: what the bot says about an answered unit, and about a node whose spec
# PR is merged and that the start queue does not list yet (U03, slice 3).
#   U03-AC-3 the answer-received milestone, the "Waiting on you" item, the reply to a prefixed answer and status.sh's
#            answered line say "within seconds" only when the unit would be first (or the queue is off) and no window
#            holds; otherwise the throttle with its reason and/or the units ahead, or for an answered triage the triage
#            or update of its repository it waits behind. A node or triage, each three ways (throttle open and first;
#            throttle holding; two units ahead), with the unit not yet in its loop's waiting list (the run that writes
#            its ANSWER.md) and already in it. No waiting.json and no hold: node texts exactly as before.
#   U03-AC-4 a spec-PR-merged node that is not in the waiting list yet: one milestone with the start clause
#   U03-AC-5 turn.py place failing: no timing promise for the answered texts, one line in report.log, the run carries on
# The queued milestone, the listed spec-PR-merged node and the spec-PR line of status.sh are in report-queue.test.sh.
#   sh scheduler/report-queue-answers.test.sh   (make test)
#
# Fixture as report-queue.test.sh: one data root per case ($qd, its state folder $qs, report.py --repo owner/repo), the
# fake gh api of report-units.sh. An answer is a prefixed owner comment ("K11: go", "#611: go") on the status issue: the
# run that sees it writes ANSWER.md, posts the answer-received milestone on the unit's home issue, and replies on the
# status issue; the same run renders "Waiting on you". The unit is in the loop's waiting.json or not (it was held until
# its answer, so the loop has not listed it).
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
fakegh_lib=$src/testdata/lib
. "$fakegh_lib/report-fakegh.sh"
tmp=$(mktemp -d)
qpids=
trap 'for p in $qpids; do kill "$p" 2>/dev/null; done; rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
ok() { name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
pyc_setup
. "$fakegh_lib/report-units.sh"
ustatus_init

HOLDWHY="5-hour window projected high"
qn=0
qnew() {
	qn=$((qn + 1)); qd=$tmp/q$qn; qs=$qd/state/repo
	mkdir -p "$qs/node" "$qs/issue"
	: >"$qs/status.log"
	qusage 0
	date +%s >"$qs/heartbeat"
	qr "$qs" >/dev/null
}
qusage() {
	if [ "$1" = 1 ]; then printf '{"hold": true, "reason": "%s"}\n' "$HOLDWHY" >"$qd/state/usage.json"
	else printf '{"hold": false, "reason": "usage ok"}\n' >"$qd/state/usage.json"; fi
}
qr() { env PATH="$ubin:$PATH" python3 -I "${QSRC:-$src}/report.py" --repo owner/repo --state "$1" --worktrees "$tmp/worktrees/repo" --clone "$uclone" --owner owner 2>"$tmp/qerr"; }
qwaiting() { # unit specs "<key> <kind> <seconds waited>" ...: the loop's waiting.json, a live loop (no spec: an empty list)
	python3 -I -c '
import json, sys, time
now = int(time.time())
units = []
for s in sys.argv[2:]:
    k, kind, ago = s.split()
    units.append({"key": k, "kind": kind, "size": "-", "since": now - int(ago)})
json.dump({"tick": 60, "units": units, "gaveback": []}, open(sys.argv[1] + "/waiting.json", "w"))' "$qs" "$@"
	date +%s >"$qs/heartbeat"
}
qfind() { P="$2" pyc "
import json, os, re
db = json.load(open('$udb'))
print(next((c['body'] for c in db['comments'] if c['issue'] == '$1' and re.search(os.environ['P'], c['body'])), ''))"; }
has() { printf '%s' "$1" | grep -qF -- "$2"; }
hasnt() { [ -n "$1" ] && ! printf '%s' "$1" | grep -qF -- "$2"; }   # the text exists and lacks the phrase
statusbody() { uq "db['issues']['$ustatus']['body']"; }
qevent() { ev "$1" "$qs"; }
# aclean: the status issue's comments go (the owner's earlier answers would be read again by the next fresh state)
aclean() { pyc "
import json
db = json.load(open('$udb'))
db['comments'] = [c for c in db['comments'] if c['issue'] != '$ustatus']
json.dump(db, open('$udb', 'w'))"; }

# aunit <node|followup|triage>: a fresh state with one unit that asks a question (sets uid, uhome, ukind)
an=10 astat=1
aunit() {
	an=$((an + 1)); aclean; qnew
	case $1 in
	triage)
		uid="#$((600 + an))" uhome=$((600 + an)) ukind=triage
		mkdir -p "$qs/issue/$uhome"; printf 'Q1: which way for the triage?\n' >"$qs/issue/$uhome/QUESTION.md" ;;
	node)
		uid=K$an uhome=$((700 + an)) ukind=resumed
		mkdir -p "$qs/node/$uid"; printf 'Q1: which way for %s?\n' "$uid" >"$qs/node/$uid/QUESTION.md"; echo "$uhome" >"$qs/node/$uid/issue"
		printf 'nodes:\n  - {id: %s, name: kay-thing, deps: []}\n' "$uid" >"$qs/graph.yaml"; : >"$qs/subjects.txt"; : >"$qs/merged-prs.txt" ;;
	followup)
		uid=M$an uhome=$((700 + an)) ukind=followup
		mkdir -p "$qs/node/$uid"; printf 'Q1: which way for %s?\n' "$uid" >"$qs/node/$uid/QUESTION.md"; echo "$uhome" >"$qs/node/$uid/issue"
		printf 'nodes:\n  - {id: %s, name: merged-thing, deps: []}\n' "$uid" >"$qs/graph.yaml"; : >"$qs/subjects.txt"
		echo "31 node/$uid-merged-thing" >"$qs/merged-prs.tsv"; echo 31 >"$qs/merged-prs.txt" ;;
	esac
}
# await <first|hold|two|off|behind...> <listed 0|1>: the throttle and the loop's waiting list for the unit
await() {
	self=; [ "$2" = 1 ] && self="$uid $ukind 100"
	case $1 in
	first) qusage 0; qwaiting "Z01 fresh 100" ${self:+"$self"} ;;
	hold) qusage 1; qwaiting ${self:+"$self"} ;;
	two) qusage 0; qwaiting "B91 resumed 3000" "B92 followup 2000" ${self:+"$self"} ;;
	off) qusage 0; rm -f "$qs/waiting.json" ;;
	esac
}
# aanswer: the owner answers on the status issue; one run; then the three texts (amile, areply, aitem), the exit code, stderr
aanswer() {
	uowner "$ustatus" "$uid: go"
	qr "$qs" >/dev/null; arc=$?
	cp "$tmp/qerr" "$tmp/aerr"
	amile=$(qfind "$uhome" 'answer received')
	areply=$(qfind "$ustatus" "Recorded as $uid's ANSWER")
	aitem=$(statusbody | awk '/^## Waiting on you/ {f=1; next} /^## / {f=0} f' | grep -F -- "$uid" | head -n 1)
}
# astatus: status.sh's answered line for the unit
mkdir -p "$tmp/home/.config/noodlebot" "$tmp/sbin"
printf '#!/bin/sh\necho fake-token\n' >"$tmp/home/.config/noodlebot/token"; chmod +x "$tmp/home/.config/noodlebot/token"
printf '#!/bin/sh\nexit 1\n' >"$tmp/sbin/gh"; chmod +x "$tmp/sbin/gh"
astatus() { HOME=$tmp/home NOODLEBOT_DATA=$qd PATH=$tmp/sbin:$PATH bash "$src/status.sh" owner/repo 2>&1 | grep -F -- "$uid answered" | head -n 1; }

# achk <label> <way> <text>: the text says what the way says
achk() {
	case $2 in
	first)
		ok "U03-AC-3: $1: throttle open and first in the queue: says within seconds" has "$3" "within seconds"
		ok "U03-AC-3: $1: first in the queue: no count of units ahead" hasnt "$3" "ahead"
		ok "U03-AC-3: $1: throttle open: it does not say the throttle holds" hasnt "$3" "the throttle holds" ;;
	hold)
		ok "U03-AC-3: $1: throttle holding: names the hold" has "$3" "the throttle holds new sessions"
		ok "U03-AC-3: $1: throttle holding: gives its reason" has "$3" "$HOLDWHY"
		ok "U03-AC-3: $1: throttle holding: no 'within seconds'" hasnt "$3" "within seconds" ;;
	two)
		ok "U03-AC-3: $1: two units ahead: says 2 units ahead in the start queue" has "$3" "2 units ahead in the start queue"
		ok "U03-AC-3: $1: two units ahead: no 'within seconds'" hasnt "$3" "within seconds"
		ok "U03-AC-3: $1: throttle open: it does not say the throttle holds" hasnt "$3" "the throttle holds" ;;
	esac
}
# the three texts of the last aanswer, and status.sh's line, for one way
afour() { # <label> <way>
	ok "U03-AC-3: $1: the answer is recorded (exit 3)" test "$arc" = 3
	achk "$1, answer-received milestone" "$2" "$amile"
	achk "$1, Waiting-on-you item" "$2" "$aitem"
	achk "$1, reply to the prefixed answer" "$2" "$areply"
	if [ "$astat" = 1 ]; then achk "$1, status.sh answered line" "$2" "$(astatus)"; fi   # (not repeated for the listed unit: a run costs a second)
}

# ---- U03-AC-3: an answered node, three ways, the unit not in the waiting list and in it
for listed in 0 1; do
	astat=$((1 - listed))
	lab="answered node, $([ $listed = 1 ] && echo listed || echo 'not yet listed')"
	for way in first hold two; do
		aunit node; await $way $listed; aanswer
		afour "$lab, $way" $way
	done
done
astat=1
# a merged node's answer starts a follow-up: the same, "a follow-up starts within seconds"
aunit followup; await first 0; aanswer
afour "answered merged node, not yet listed, first" first
ok "U03-AC-3: answered merged node, first: it says a follow-up starts within seconds (milestone, item, reply)" sh -c "printf '%s\n' \"\$1\" | grep -qF 'a follow-up starts within seconds' && printf '%s\n' \"\$2\" | grep -qF 'a follow-up starts within seconds' && printf '%s\n' \"\$3\" | grep -qF 'a follow-up starts within seconds'" _ "$amile" "$aitem" "$areply"
aunit followup; await two 0; aanswer
afour "answered merged node, not yet listed, two ahead" two

# ---- U03-AC-3: an answered triage, three ways, the unit not in the waiting list and in it
for listed in 0 1; do
	astat=$((1 - listed))
	lab="answered triage, $([ $listed = 1 ] && echo listed || echo 'not yet listed')"
	for way in first hold two; do
		aunit triage; await $way $listed; aanswer
		afour "$lab, $way" $way
	done
done

astat=1
# ---- U03-AC-3: an answered triage behind another triage or update of its repository
qbin=$tmp/qbin; mkdir -p "$qbin"
printf '#!/bin/sh\nwhile :; do sleep 1; done\n' >"$qbin/run-session.sh"
setsid sh "$qbin/run-session.sh" owner/repo 624 >/dev/null 2>&1 </dev/null &
qpids="$qpids $!"; run624=$!
setsid sh "$qbin/run-session.sh" owner/repo 8 >/dev/null 2>&1 </dev/null &
qpids="$qpids $!"; run8=$!
# abehind <label> <what it waits behind: phrase> <hold 0|1> <how: run624|run8|wait-triage|wait-update>
abehind() {
	aunit triage
	case $4 in
	run624) mkdir -p "$qs/issue/624"; echo "$run624" >"$qs/issue/624/session.pid"; qwaiting "Z01 fresh 100" ;;
	run8) mkdir -p "$qs/pr/8"; echo "$run8" >"$qs/pr/8/session.pid"; qwaiting "Z01 fresh 100" ;;
	wait-triage) qwaiting "#625 triage 3000" ;;
	wait-update) qwaiting "PR#9 update 3000" ;;
	esac
	qusage "$3"
	aanswer
	for t in "milestone:$amile" "item:$aitem" "reply:$areply" "status.sh line:$(astatus)"; do
		ok "U03-AC-3: $1, ${t%%:*}: names what it waits behind ($2)" has "${t#*:}" "$2"
		ok "U03-AC-3: $1, ${t%%:*}: no 'within seconds'" hasnt "${t#*:}" "within seconds"
		if [ "$3" = 1 ]; then
			ok "U03-AC-3: $1, ${t%%:*}: the hold is named too" sh -c "printf '%s' \"\$1\" | grep -qF 'the throttle holds new sessions' && printf '%s' \"\$1\" | grep -qF '$HOLDWHY'" _ "${t#*:}"
		else
			ok "U03-AC-3: $1, ${t%%:*}: throttle open, nothing ahead to count" hasnt "${t#*:}" "the throttle holds"
		fi
	done
}
abehind "answered triage behind a running triage" "waits behind the triage of #624" 0 run624
abehind "answered triage behind a running update" "waits behind the update of PR #8" 0 run8
abehind "answered triage behind a waiting triage" "waits behind the triage of #625" 0 wait-triage
abehind "answered triage behind a waiting update" "waits behind the update of PR #9" 0 wait-update
abehind "answered triage behind a running triage, throttle holding" "waits behind the triage of #624" 1 run624
abehind "answered triage behind a waiting update, throttle holding" "waits behind the update of PR #9" 1 wait-update

# ---- U03-AC-3: no waiting.json and no hold: node texts exactly as before this node
aunit node; await off 0; aanswer
ok "U03-AC-3 (as before): node, no waiting.json, no hold: the milestone is 'answer received, resumes within seconds'" sh -c "printf '%s\n' \"\$1\" | grep -q '^\*\*Stage:\*\* answer received, resumes within seconds\$'" _ "$amile"
ok "U03-AC-3 (as before): node: the item is '- <ID>: resumes within seconds.'" sh -c "printf '%s\n' \"\$2\" | grep -Eq \"^- .{0,4}\$1.{0,4}: resumes within seconds\\.\"" _ "$uid" "$aitem"
ok "U03-AC-3 (as before): node: the reply is \"Recorded as <ID>'s ANSWER.md; <ID> resumes within seconds.\"" sh -c "printf '%s\n' \"\$2\" | grep -qF \"Recorded as \$1's ANSWER.md; \$1 resumes within seconds.\"" _ "$uid" "$areply"
ok "U03-AC-3 (as before): node, queue off: status.sh's answered line says within seconds too" has "$(astatus)" "within seconds"
aunit followup; await off 0; aanswer
ok "U03-AC-3 (as before): merged node, no waiting.json, no hold: the milestone says a follow-up starts within seconds" has "$amile" "answer received, a follow-up starts within seconds"
ok "U03-AC-3 (as before): merged node: the reply is \"Recorded as <ID>'s ANSWER.md; a follow-up starts within seconds.\"" sh -c "printf '%s\n' \"\$2\" | grep -qF \"Recorded as \$1's ANSWER.md; a follow-up starts within seconds.\"" _ "$uid" "$areply"
ok "U03-AC-3 (as before): merged node: the item says a follow-up starts within seconds" has "$aitem" "a follow-up starts within seconds"
aunit triage; await off 0; aanswer
ok "U03-AC-3: triage, no waiting.json, no hold: the milestone says within seconds" has "$amile" "within seconds"
ok "U03-AC-3: triage, no waiting.json, no hold: the item says within seconds" has "$aitem" "within seconds"
ok "U03-AC-3: triage, no waiting.json, no hold: the reply says within seconds" has "$areply" "within seconds"
ok "U03-AC-3: triage, no waiting.json, no hold: status.sh's line says within seconds" has "$(astatus)" "within seconds"
ok "U03-AC-3: triage, no waiting.json, no hold: no count, no hold" sh -c "! printf '%s\n' \"\$1\" | grep -qE 'ahead|throttle'" _ "$amile$aitem$areply"
# the hold with the queue off: the hold alone
aunit node; qusage 1; rm -f "$qs/waiting.json"; aanswer
achk "answered node, no waiting.json, throttle holding, milestone" hold "$amile"
achk "answered node, no waiting.json, throttle holding, item" hold "$aitem"
achk "answered node, no waiting.json, throttle holding, reply" hold "$areply"
achk "answered node, no waiting.json, throttle holding, status.sh line" hold "$(astatus)"
# the answer of a node ready.py does not name keeps its text (S03), with the queue on
aunit node; qusage 0; qwaiting "B91 resumed 3000"; echo 77 >"$qs/node/$uid/WAITING-PR"; : >"$qs/merged-prs.txt"; aanswer
ok "U03-AC-3: a node ready.py does not name (waits for its spec PR): the item says it is answered, but it waits (no 'within seconds', no count)" sh -c "printf '%s\n' \"\$1\" | grep -q 'answered, but' && ! printf '%s\n' \"\$1\" | grep -qE 'within seconds|ahead'" _ "$aitem"

# ---- U03-AC-4: a node whose spec PR is merged and that the waiting list does not hold yet
qnode() { # <id> <PR number> <home issue>
	mkdir -p "$qs/node/$1"; echo "$2" >"$qs/node/$1/WAITING-PR"; echo "$3" >"$qs/node/$1/issue"
	printf 'nodes:\n  - {id: %s, name: spec-thing, deps: []}\n' "$1" >"$qs/graph.yaml"
	: >"$qs/subjects.txt"
}
QITEM='waits for you to merge spec PR #7'
aspec() { # <way> <home issue>: the node B01 is not in waiting.json; three runs
	aclean; qnew; qnode B01 7 "$2"; : >"$qs/merged-prs.txt"
	await "$1" 0
	printf '7\n' >"$qs/merged-prs.txt"
	for _i in 1 2 3; do qr "$qs" >/dev/null; done
	smile=$(qfind "$2" 'spec PR #7 merged')
	ok "U03-AC-4: $1, not yet listed: exactly one 'spec PR #7 merged' milestone over three runs" test "$(ucount "$2" 'spec PR #7 merged')" = 1
	ok "U03-AC-4: $1, not yet listed: no 'Waiting on you' item for the node" hasnt "$(statusbody)" "$QITEM"
}
aspec first 801
ok "U03-AC-4: not yet listed, first in the queue (it would be first if it joined): says within seconds" has "$smile" "within seconds"
ok "U03-AC-4: not yet listed, first: it does not say it starts at its turn" hasnt "$smile" "starts at its turn"
ok "U03-AC-4: not yet listed, first: no count, no hold" sh -c "! printf '%s' \"\$1\" | grep -qE 'ahead|throttle'" _ "$smile"
aspec hold 802
ok "U03-AC-4: not yet listed, throttle holding: names the hold" has "$smile" "the throttle holds new sessions"
ok "U03-AC-4: not yet listed, throttle holding: gives its reason" has "$smile" "$HOLDWHY"
ok "U03-AC-4: not yet listed, throttle holding: no 'within seconds'" hasnt "$smile" "within seconds"
aspec two 803
ok "U03-AC-4: not yet listed, two units ahead: says 2 units ahead in the start queue" has "$smile" "2 units ahead in the start queue"
ok "U03-AC-4: not yet listed, two units ahead: no 'within seconds'" hasnt "$smile" "within seconds"
ok "U03-AC-4: not yet listed, two units ahead: the milestone is a Stage line" test "$(ucount 803 '\A\*\*Stage:\*\* spec PR #7 merged')" = 1
# the PR still open and the node not listed: today's item, no milestone
aclean; qnew; qnode B01 7 804; : >"$qs/merged-prs.txt"; await two 0
for _i in 1 2; do qr "$qs" >/dev/null; done
ok "U03-AC-4: not yet listed, spec PR still open: today's item stays" has "$(statusbody)" "$QITEM"
ok "U03-AC-4: not yet listed, spec PR still open: no 'spec PR #7 merged' milestone" test "$(ucount 804 'spec PR #7 merged')" = 0
# status.sh on the unlisted merged node
aclean; qnew; qnode B01 7 805; printf '7\n' >"$qs/merged-prs.txt"; await two 0
out=$(HOME=$tmp/home NOODLEBOT_DATA=$qd PATH=$tmp/sbin:$PATH bash "$src/status.sh" owner/repo 2>&1)
ok "U03-AC-4: status.sh says 'spec PR #7 merged; waits for its turn' for the unlisted merged node" has "$out" "spec PR #7 merged; waits for its turn"
ok "U03-AC-4: status.sh does not say it waits for your merge" hasnt "$out" "waits for you to merge"

# ---- U03-AC-5: turn.py place failing, for the answered texts
# A copy of the scheduler whose turn.py is a stub ($tmp/stubmode: fail = exit 1, garbage = exit 0 with a line place never prints).
mkdir -p "$tmp/sched-fail/harnesses"
for f in "$src"/*; do case $f in *.test.sh) ;; *) [ -f "$f" ] && cp "$f" "$tmp/sched-fail/" ;; esac; done
cp "$src"/harnesses/*.py "$tmp/sched-fail/harnesses/" 2>/dev/null
cat >"$tmp/sched-fail/turn.py" <<EOF
#!/usr/bin/env python3
import sys
if open("$tmp/stubmode").read().strip() == "garbage":
    print("no idea where it stands")
    sys.exit(0)
print("turn.py: place failed (test stub)", file=sys.stderr)
sys.exit(1)
EOF
QSRC=$tmp/sched-fail
# afail <label> <unit kind> <way> <mode>: place fails; the unit is in the waiting list
afail() {
	echo "$4" >"$tmp/stubmode"
	aunit "$2"; await "$3" 1; aanswer
	if [ "$2" = triage ]; then af=$qs/issue/$uhome/ANSWER.md; else af=$qs/node/$uid/ANSWER.md; fi
	ok "U03-AC-5 ($1): the run carries on: the answer is recorded (exit 3, ANSWER.md written)" sh -c "[ '$arc' = 3 ] && [ -e \"\$1\" ]" _ "$af"
	ok "U03-AC-5 ($1): the run carries on: the status issue is updated" has "$(statusbody)" "owner/repo"
	for t in "milestone:$amile" "item:$aitem" "reply:$areply"; do
		ok "U03-AC-5 ($1), ${t%%:*}: no 'within seconds' and no count" sh -c "[ -n \"\$1\" ] && ! printf '%s' \"\$1\" | grep -qE 'within seconds|ahead'" _ "${t#*:}"
		ok "U03-AC-5 ($1), ${t%%:*}: says it starts at its turn" has "${t#*:}" "starts at its turn"
		if [ "$3" = hold ]; then ok "U03-AC-5 ($1), ${t%%:*}: the hold is still named" has "${t#*:}" "the throttle holds new sessions"; fi
	done
	ok "U03-AC-5 ($1): the failure is one line in the run's stderr (report.log)" test "$(grep -ciE 'turn\.py|place' "$tmp/aerr")" = 1
}
afail "node, place exits 1" node first fail
afail "triage, place exits 1" triage first fail
afail "node, place exits 1, throttle holding" node hold fail
afail "triage, place prints garbage" triage first garbage
QSRC=

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "all checks passed"
