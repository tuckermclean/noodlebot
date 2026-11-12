#!/bin/sh
# Tests scheduler/report.py and scheduler/status.sh: what the bot says about a unit that waits in the start queue (U03).
#   U03-AC-2 the queued-for-triage milestone of a labelled issue (once; the throttle's hold or the units ahead or the
#            triage it waits behind; none for a started, unlabelled or triaged issue)
#   U03-AC-4 a node whose WAITING-PR is in merged-prs.txt: no "Waiting on you" item, one "spec PR #N merged" milestone
#            with the start clause, status.sh does not say it waits for the owner's merge
#   U03-AC-5 turn.py place failing: no timing promise, one line in report.log, the run carries on
# The answered texts (U03-AC-3) are tested elsewhere (not in this slice).
#   sh scheduler/report-queue.test.sh   (make test)
#
# Fixture: one data root per case, $tmp/qN/state/repo being the loop's state folder (report.py --repo owner/repo), with
#   state/usage.json                        {"hold": true|false, "reason": ...}
#   state/repo/{heartbeat,waiting.json}     the start queue (absent waiting.json = the queue is off)
#   state/repo/issues.json                  what issues.py next writes
# and the fake gh api of report-units.sh. A report run on the bare state folder comes first (what is on disk then is
# "seen", not new).
# How turn.py place is made to fail (U03-AC-5): report.py runs the turn.py that sits next to it, so the failing cases run
# a copy of the scheduler in $tmp/sched-fail whose turn.py is a stub (it exits 1, or prints what place never prints).
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
# qnew: a fresh data root and state folder: $qd, $qs; the throttle open; no queue file; a first run done.
qnew() {
	qn=$((qn + 1)); qd=$tmp/q$qn; qs=$qd/state/repo
	mkdir -p "$qs/node" "$qs/issue"
	: >"$qs/status.log"
	qusage 0
	date +%s >"$qs/heartbeat"
	qr "$qs" >/dev/null
}
qusage() { # <1|0>: the throttle holding or open
	if [ "$1" = 1 ]; then printf '{"hold": true, "reason": "%s"}\n' "$HOLDWHY" >"$qd/state/usage.json"
	else printf '{"hold": false, "reason": "usage ok"}\n' >"$qd/state/usage.json"; fi
}
qr() { env PATH="$ubin:$PATH" python3 -I "${QSRC:-$src}/report.py" --repo owner/repo --state "$1" --worktrees "$tmp/worktrees/repo" --clone "$uclone" --owner owner 2>"$tmp/qerr"; }
# qr3: three runs; their stderr lines are kept in $tmp/qlog, the number of lines about the queue per run in $tmp/qlines.
qr3() {
	: >"$tmp/qlog"; : >"$tmp/qlines"
	for _i in 1 2 3; do
		qr "$qs" >/dev/null
		cat "$tmp/qerr" >>"$tmp/qlog"
		grep -ciE 'turn\.py|place' "$tmp/qerr" >>"$tmp/qlines" || true
	done
}
qissues() { printf '{"updated": %s, "issues": %s}\n' "$(date +%s)" "$1" >"$qs/issues.json"; }
qlab() { printf '{"number": %s, "title": "t%s", "labelled": %s}' "$1" "$1" "${2:-true}"; }
qwaiting() { # unit specs "<key> <kind> <seconds waited>" ...: the loop's waiting.json, a live loop
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

# ---- U03-AC-2: the queued milestone
# the throttle holding, the queue on: the hold and its reason
qnew
qissues "[$(qlab 101)]"; qwaiting "#101 triage 100"; qusage 1
qr3
body=$(qfind 101 'queued for triage')
ok "U03-AC-2: a labelled issue with no triage started gets exactly one queued milestone over three runs (throttle holding)" test "$(ucount 101 'queued for triage')" = 1
ok "U03-AC-2: the queued milestone begins with a Stage line" test "$(ucount 101 '\A\*\*Stage:\*\* queued for triage')" = 1
ok "U03-AC-2: with the throttle holding it says so" has "$body" "the throttle holds new sessions"
ok "U03-AC-2: with the throttle holding it gives the hold's reason" has "$body" "$HOLDWHY"
ok "U03-AC-2: first in the queue with the hold: no count of units ahead" hasnt "$body" "ahead"
ok "U03-AC-2: it promises no start within seconds" hasnt "$body" "within seconds"
# the same with the queue off (no waiting.json): the hold is still named
qnew
qissues "[$(qlab 102)]"; qusage 1
qr3
body=$(qfind 102 'queued for triage')
ok "U03-AC-2: with the throttle holding and no waiting.json: one queued milestone naming the hold and its reason" sh -c "[ \"\$1\" = 1 ] && printf '%s' \"\$2\" | grep -qF 'the throttle holds new sessions' && printf '%s' \"\$2\" | grep -qF '$HOLDWHY'" _ "$(ucount 102 'queued for triage')" "$body"

# the throttle open, units ahead: the count
qnew
qissues "[$(qlab 103)]"; qwaiting "PR#7 update 3000" "#104 triage 2000" "#103 triage 100"
qr3
body=$(qfind 103 'queued for triage')
ok "U03-AC-2: a labelled issue gets exactly one queued milestone over three runs (throttle open)" test "$(ucount 103 'queued for triage')" = 1
ok "U03-AC-2: with the throttle open it gives the number of units ahead (2 units ahead in the start queue)" has "$body" "2 units ahead in the start queue"
ok "U03-AC-2: with units ahead it does not say the throttle holds" hasnt "$body" "the throttle holds"
ok "U03-AC-2: with units ahead it promises no start within seconds" hasnt "$body" "within seconds"
# the throttle open, first in the queue
qnew
qissues "[$(qlab 105)]"; qwaiting "#105 triage 100"
qr3
body=$(qfind 105 'queued for triage')
ok "U03-AC-2: first in the queue with the throttle open: one queued milestone that says first in the start queue" sh -c "[ \"\$1\" = 1 ] && printf '%s' \"\$2\" | grep -qF 'first in the start queue'" _ "$(ucount 105 'queued for triage')" "$body"
# none for a started, an unlabelled, a held-not-asked or a triaged issue; a control issue in the same list gets its one
qnew
qissues "[$(qlab 111), $(qlab 112 false), $(qlab 113 null), $(qlab 114), $(qlab 115)]"
mkdir -p "$qs/issue/111"; qevent "started triage of #111 in /wt, pid 4, start 1 of 2"
qevent "triage of #114 done (rc 0); its label is now noodlebot-triaged"
pyc "
import json
db = json.load(open('$udb'))
db['issues']['114'] = {'number': 114, 'title': 'triaged', 'body': '', 'labels': ['noodlebot-triaged'], 'state': 'open', 'node_id': 'I_114'}
json.dump(db, open('$udb', 'w'))"
qwaiting "#115 triage 100"
qr3
ok "U03-AC-2 (control): the labelled issue without a started triage gets its queued milestone" test "$(ucount 115 'queued for triage')" = 1
ok "U03-AC-2: no queued milestone for an issue whose triage already started (a started line in status.log)" test "$(ucount 111 'queued for triage')" = 0
ok "U03-AC-2: no queued milestone for an unlabelled issue (labelled false)" test "$(ucount 112 'queued for triage')" = 0
ok "U03-AC-2: no queued milestone for an issue not asked about (labelled null)" test "$(ucount 113 'queued for triage')" = 0
ok "U03-AC-2: no queued milestone for a triaged issue" test "$(ucount 114 'queued for triage')" = 0
ok "U03-AC-2: the started issue got its started milestone, so the check above is not vacuous" test "$(ucount 111 'started')" -ge 1

# not in the queue: it waits behind another triage or update of the repository
qnew
qissues "[$(qlab 121)]"; qwaiting "#122 triage 3000"
qr3
body=$(qfind 121 'queued for triage')
ok "U03-AC-2: behind a waiting triage of its repository it names that triage (#122): one milestone" sh -c "[ \"\$1\" = 1 ] && printf '%s' \"\$2\" | grep -qF 'waits behind the triage of #122'" _ "$(ucount 121 'queued for triage')" "$body"
qnew
qissues "[$(qlab 123)]"; qwaiting "PR#8 update 3000"
qr3
ok "U03-AC-2: behind a waiting update of a PR it names that update (PR #8)" has "$(qfind 123 'queued for triage')" "waits behind the update of PR #8"
# a running triage: a session.pid of a live process the harness recognises
mkdir -p "$tmp/qbin"
printf '#!/bin/sh\nwhile :; do sleep 1; done\n' >"$tmp/qbin/run-session.sh"
setsid sh "$tmp/qbin/run-session.sh" owner/repo 124 >/dev/null 2>&1 </dev/null &
qpids="$qpids $!"; qrunpid=$!
qnew
mkdir -p "$qs/issue/124"; echo "$qrunpid" >"$qs/issue/124/session.pid"
qissues "[$(qlab 125)]"; qwaiting "#126 triage 100"
qr3
ok "U03-AC-2: behind a running triage (a live session.pid under issue/124/) it names that triage (#124)" has "$(qfind 125 'queued for triage')" "waits behind the triage of #124"
qnew
mkdir -p "$qs/issue/124"; echo "$qrunpid" >"$qs/issue/124/session.pid"
qissues "[$(qlab 127)]"; qwaiting "#128 triage 100"; qusage 1
qr3
body=$(qfind 127 'queued for triage')
ok "U03-AC-2: behind a running triage with the throttle holding it names the triage and the hold" sh -c "printf '%s' \"\$1\" | grep -qF 'waits behind the triage of #124' && printf '%s' \"\$1\" | grep -qF 'the throttle holds new sessions'" _ "$body"

# ---- U03-AC-4: a merged spec PR
# graph for ready.py: B01 waits for spec PR 7
qnode() { # <id> <PR number> <home issue>: the node waits for the spec PR; its home issue; the graph
	mkdir -p "$qs/node/$1"; echo "$2" >"$qs/node/$1/WAITING-PR"; echo "$3" >"$qs/node/$1/issue"
	printf 'nodes:\n  - {id: %s, name: spec-thing, deps: []}\n' "$1" >"$qs/graph.yaml"
	: >"$qs/subjects.txt"
}
qmerged() { printf '%s\n' "$1" >"$qs/merged-prs.txt"; }
QITEM='waits for you to merge spec PR #7'
# the throttle open, first in the queue, ready.py names it
qnew
qnode B01 7 201; : >"$qs/merged-prs.txt"
qr "$qs" >/dev/null
ok "U03-AC-4 (precondition): before the merge the node's item says it waits for you to merge spec PR #7" has "$(statusbody)" "$QITEM"
qmerged 7; qwaiting "B01 resumed 100"
qr3
body=$(qfind 201 'spec PR #7 merged')
ok "U03-AC-4: in the first run after the merge the node has no 'Waiting on you' item" hasnt "$(statusbody)" "$QITEM"
ok "U03-AC-4: its home issue gets exactly one 'spec PR #7 merged' milestone over three runs" test "$(ucount 201 'spec PR #7 merged')" = 1
ok "U03-AC-4: the milestone is a Stage line" test "$(ucount 201 '\A\*\*Stage:\*\* spec PR #7 merged')" = 1
ok "U03-AC-4: open, first in the queue, ready.py names it: it resumes within seconds" has "$body" "within seconds"
ok "U03-AC-4: with no hold and nothing ahead it names no hold and no count" sh -c "[ -n \"\$1\" ] && ! printf '%s' \"\$1\" | grep -qF 'throttle' && ! printf '%s' \"\$1\" | grep -q 'ahead'" _ "$body"
# the queue off (no waiting.json)
qnew
qnode B01 7 202; qmerged 7
qr3
ok "U03-AC-4: with no waiting.json (the queue is off) and no hold the milestone says within seconds" has "$(qfind 202 'spec PR #7 merged')" "within seconds"
ok "U03-AC-4: with no waiting.json it is still one milestone and no item" sh -c "[ \"\$1\" = 1 ]" _ "$(ucount 202 'spec PR #7 merged')"
# units ahead
qnew
qnode B01 7 203; qmerged 7; qwaiting "#204 triage 3000" "B01 resumed 100"
qr3
body=$(qfind 203 'spec PR #7 merged')
ok "U03-AC-4: open with a unit ahead: exactly one milestone that says 1 unit ahead in the start queue" sh -c "[ \"\$1\" = 1 ] && printf '%s' \"\$2\" | grep -qF '1 unit ahead in the start queue'" _ "$(ucount 203 'spec PR #7 merged')" "$body"
ok "U03-AC-4: with a unit ahead it does not say within seconds" hasnt "$body" "within seconds"
# the throttle holding
qnew
qnode B01 7 205; qmerged 7; qwaiting "B01 resumed 100"; qusage 1
qr3
body=$(qfind 205 'spec PR #7 merged')
ok "U03-AC-4: with the throttle holding the milestone names the hold and its reason" sh -c "[ \"\$1\" = 1 ] && printf '%s' \"\$2\" | grep -qF 'the throttle holds new sessions' && printf '%s' \"\$2\" | grep -qF '$HOLDWHY'" _ "$(ucount 205 'spec PR #7 merged')" "$body"
ok "U03-AC-4: with the throttle holding it does not say within seconds" hasnt "$body" "within seconds"
ok "U03-AC-4: with the throttle holding there is no 'Waiting on you' item for the node" hasnt "$(statusbody)" "$QITEM"
# the PR still open: today's item, no milestone
qnew
qnode B01 7 206; : >"$qs/merged-prs.txt"; qwaiting "B01 resumed 100"
qr3
ok "U03-AC-4: a node whose spec PR is still open keeps today's item ($QITEM)" has "$(statusbody)" "$QITEM"
ok "U03-AC-4: and its home issue gets no 'spec PR #7 merged' milestone" test "$(ucount 206 'spec PR #7 merged')" = 0

# ---- U03-AC-5: turn.py place failing
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
for mode in fail garbage; do
	echo "$mode" >"$tmp/stubmode"
	qnew
	qissues "[$(qlab 301), $(qlab 302)]"; qwaiting "#303 triage 3000" "#301 triage 100"; qusage 0
	mkdir -p "$qs/issue/302"; qevent "started triage of #302 in /wt, pid 4, start 1 of 2"
	qr3
	body=$(qfind 301 'queued for triage')
	ok "U03-AC-5 ($mode): the queued milestone is still posted, once" test "$(ucount 301 'queued for triage')" = 1
	ok "U03-AC-5 ($mode): it promises no timing (no 'within seconds', no 'ahead')" sh -c "[ -n \"\$1\" ] && ! printf '%s' \"\$1\" | grep -q 'within seconds' && ! printf '%s' \"\$1\" | grep -q 'ahead'" _ "$body"
	ok "U03-AC-5 ($mode): it says the unit starts at its turn" has "$body" "starts at its turn"
	ok "U03-AC-5 ($mode): the failure is one line in the first run's stderr (report.log)" test "$(sed -n 1p "$tmp/qlines")" = 1
	ok "U03-AC-5 ($mode): no run says more than one line about it" test "$(sort -n "$tmp/qlines" | tail -n 1)" -le 1
	ok "U03-AC-5 ($mode): the run carries on: another unit's started milestone is posted" test "$(ucount 302 'started')" -ge 1
	ok "U03-AC-5 ($mode): the run carries on: the status issue is updated" has "$(statusbody)" "owner/repo"
	[ "$mode" = fail ] || continue   # the spec-PR milestone is run with the failing stub only (a run costs a second)
	qnew
	qnode B01 7 304; qmerged 7; qwaiting "B01 resumed 100"
	qr3
	body=$(qfind 304 'spec PR #7 merged')
	ok "U03-AC-5 ($mode): the spec-PR milestone is posted once and promises no timing though ready.py names the node" sh -c "[ \"\$1\" = 1 ] && ! printf '%s' \"\$2\" | grep -q 'within seconds' && ! printf '%s' \"\$2\" | grep -q 'ahead'" _ "$(ucount 304 'spec PR #7 merged')" "$body"
	ok "U03-AC-5 ($mode): the spec-PR milestone says the node starts at its turn" has "$body" "starts at its turn"
	ok "U03-AC-5 ($mode): the failure is one line in the first run's stderr (report.log)" test "$(sed -n 1p "$tmp/qlines")" = 1
done
QSRC=

# ---- status.sh on the same state (U03-AC-4): the spec-PR line
mkdir -p "$tmp/home/.config/noodlebot" "$tmp/sbin"
printf '#!/bin/sh\necho fake-token\n' >"$tmp/home/.config/noodlebot/token"; chmod +x "$tmp/home/.config/noodlebot/token"
printf '#!/bin/sh\nexit 1\n' >"$tmp/sbin/gh"; chmod +x "$tmp/sbin/gh"
sstatus() { # <data root>: status.sh's output
	HOME=$tmp/home NOODLEBOT_DATA=$1 PATH=$tmp/sbin:$PATH bash "$src/status.sh" owner/repo 2>&1
}
qnew
qnode B01 7 401; qmerged 7; qwaiting "B01 resumed 100"
out=$(sstatus "$qd")
ok "U03-AC-4: status.sh prints 'spec PR #7 merged; waits for its turn' for a merged spec PR" has "$out" "spec PR #7 merged; waits for its turn"
ok "U03-AC-4: status.sh does not say it waits for the owner's merge" hasnt "$out" "waits for you to merge"
qnew
qnode B01 7 402; : >"$qs/merged-prs.txt"
out=$(sstatus "$qd")
ok "U03-AC-4: status.sh keeps today's line for an unmerged spec PR" has "$out" "B01 waits for you to merge spec PR #7; restarts at the tick after"
ok "U03-AC-4: status.sh says nothing of a merge for an unmerged spec PR" hasnt "$out" "spec PR #7 merged"


# ---- the first run that sees it (U03-AC-2, U03-AC-4): one run, not three
qnew
qissues "[$(qlab 501)]"; qwaiting "#501 triage 100"; qusage 1
qr "$qs" >/dev/null
ok "U03-AC-2 (first run): the throttle holding: exactly one queued milestone after the first run that sees the issue" test "$(ucount 501 'queued for triage')" = 1
qnew
qissues "[$(qlab 502)]"; qwaiting "#503 triage 3000" "#502 triage 100"
qr "$qs" >/dev/null
ok "U03-AC-2 (first run): the throttle open: exactly one queued milestone after the first run that sees the issue" test "$(ucount 502 'queued for triage')" = 1
qnew
qnode B01 7 504; : >"$qs/merged-prs.txt"
qr "$qs" >/dev/null
qmerged 7; qwaiting "B01 resumed 100"
qr "$qs" >/dev/null
ok "U03-AC-4 (first run): exactly one 'spec PR #7 merged' milestone after the first run that sees the merge" test "$(ucount 504 'spec PR #7 merged')" = 1
ok "U03-AC-4 (first run): the node's 'Waiting on you' item is gone after the first run that sees the merge" hasnt "$(statusbody)" "$QITEM"

# ---- U03-AC-5, garbage mode again on issue and node numbers the fail mode did not use
QSRC=$tmp/sched-fail
echo garbage >"$tmp/stubmode"
qnew
qissues "[$(qlab 311), $(qlab 312)]"; qwaiting "#313 triage 3000" "#311 triage 100"; qusage 0
mkdir -p "$qs/issue/312"; qevent "started triage of #312 in /wt, pid 4, start 1 of 2"
qr3
body=$(qfind 311 'queued for triage')
ok "U03-AC-5 (garbage, fresh issue): exactly one queued milestone" test "$(ucount 311 'queued for triage')" = 1
ok "U03-AC-5 (garbage, fresh issue): it says the unit starts at its turn" has "$body" "starts at its turn"
ok "U03-AC-5 (garbage, fresh issue): it has no 'within seconds'" hasnt "$body" "within seconds"
ok "U03-AC-5 (garbage, fresh issue): it has no count of units ahead" hasnt "$body" "ahead"
ok "U03-AC-5 (garbage, fresh issue): one line naming turn.py/place in the first run's stderr" test "$(sed -n 1p "$tmp/qlines")" = 1
qnew
qnode B01 7 314; qmerged 7; qwaiting "B01 resumed 100"
qr3
body=$(qfind 314 'spec PR #7 merged')
ok "U03-AC-5 (garbage, fresh node): exactly one spec-PR milestone" test "$(ucount 314 'spec PR #7 merged')" = 1
ok "U03-AC-5 (garbage, fresh node): it says the node starts at its turn" has "$body" "starts at its turn"
ok "U03-AC-5 (garbage, fresh node): it has no 'within seconds' and no count" sh -c "[ -n \"\$1\" ] && ! printf '%s' \"\$1\" | grep -q 'within seconds' && ! printf '%s' \"\$1\" | grep -q 'ahead'" _ "$body"
ok "U03-AC-5 (garbage, fresh node): one line naming turn.py/place in the first run's stderr" test "$(sed -n 1p "$tmp/qlines")" = 1
QSRC=

# ---- U03-AC-5: several units in one run, turn.py place failing: one line, and place is asked only once in the run
mkdir -p "$tmp/sched-count/harnesses"
cp "$tmp"/sched-fail/*.* "$tmp/sched-count/" 2>/dev/null
cp "$tmp"/sched-fail/harnesses/*.py "$tmp/sched-count/harnesses/" 2>/dev/null
cat >"$tmp/sched-count/turn.py" <<EOF2
#!/usr/bin/env python3
import sys
open("$tmp/placecalls", "a").write("call\n")
print("turn.py: place failed (test stub)", file=sys.stderr)
sys.exit(1)
EOF2
QSRC=$tmp/sched-count
qnew
qissues "[$(qlab 511), $(qlab 512), $(qlab 513)]"; qwaiting "#511 triage 300" "#512 triage 200" "#513 triage 100" "B01 resumed 50"
qnode B01 7 514; qmerged 7
: >"$tmp/placecalls"
qr "$qs" >/dev/null
ok "U03-AC-5 (several units): exactly one stderr line about turn.py/place in the run" test "$(grep -ciE 'turn\.py|place' "$tmp/qerr")" = 1
ok "U03-AC-5 (several units): turn.py place is invoked only once in the run (not once per unit)" test "$(wc -l <"$tmp/placecalls")" -le 1
ok "U03-AC-5 (several units): the stub was invoked (the check above is not vacuous)" test "$(wc -l <"$tmp/placecalls")" -ge 1
ok "U03-AC-5 (several units): every unit still gets its milestone" sh -c "[ \"\$1\" = 1 ] && [ \"\$2\" = 1 ] && [ \"\$3\" = 1 ] && [ \"\$4\" = 1 ]" _ "$(ucount 511 'queued for triage')" "$(ucount 512 'queued for triage')" "$(ucount 513 'queued for triage')" "$(ucount 514 'spec PR #7 merged')"
QSRC=

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "all checks passed"
