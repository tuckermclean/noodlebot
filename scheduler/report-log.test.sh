#!/bin/sh
# Tests scheduler/report.py: the day's log issue, its overview and its event comments (U02-AC-1, U02-AC-2, U02-AC-3).
#   sh scheduler/report-log.test.sh   (make test)
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
fakegh_lib=$src/testdata/lib
. "$fakegh_lib/report-fakegh.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
ok() { name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
pyc_setup
. "$fakegh_lib/report-units.sh"
. "$fakegh_lib/report-sessions.sh"
rs_script
# U02-AC-1, U02-AC-2, U02-AC-3: the day's log issue, its morning overview and body, its event comments.
# report.py reads the local "now" from NOODLEBOT_NOW (an ISO local datetime, e.g. 2026-03-10T09:00:00) and the
# deployed commit from the git checkout at NOODLEBOT_LIVE (HEAD), in place of the live checkout it runs from.
# Own database and fake gh (the U01 fake on its own file), TZ=UTC so the status.log stamps (Z) and the local date agree.
vroot=$tmp/vroot vbin=$tmp/vbin vdb=$tmp/vgh.json vlive=$tmp/vlive
vstate=$vroot/state
mkdir -p "$vbin" "$vstate/node/V03" "$vstate/node/V04" "$vstate/node/V05" "$vstate/node/V06" "$vlive"
pyc "
import json
mk = lambda n, t, lab: {'number': n, 'title': t, 'body': '', 'labels': lab, 'state': 'open', 'node_id': 'I_%d' % n}
issues = {'47': mk(47, 'Unit V03', []), '48': mk(48, 'Unit V06', []),
          '150': mk(150, 'noodlebot log 2026-03-09', ['noodlebot-status'])}
json.dump({'issues': issues, 'comments': [], 'labels': ['noodlebot-status'], 'pulls': [], 'checks': {}, 'reactions': [], 'next': 200}, open('$vdb', 'w'))"
sed "s#$udb#$vdb#g; s#$tmp/ufail#$tmp/vfail#g; s#$tmp/ucalls#$tmp/vcalls#g" "$ubin/gh.py" >"$vbin/gh.py"
fakegh_install "$vbin"
git -C "$vlive" init -q -b main && git -C "$vlive" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "live one"
vsha1=$(git -C "$vlive" rev-parse HEAD)
vrun() { env PATH="$vbin:$PATH" TZ=UTC NOODLEBOT_NOW="$1" NOODLEBOT_LIVE="$vlive" python3 -I "$src/report.py" --repo owner/repo --state "$vstate" --worktrees "$tmp/worktrees/repo" --clone "$uclone" --owner owner 2>"$tmp/verr"; }
# vq <python expr>: evaluated with db, n (number of today's log issue, "" if none), logs (issues titled for 2026-03-10),
# cs (the comments on that issue, in order) and body.
vq() {
	pyc "
import json, re, sys
db = json.load(open('$vdb'))
logs = [i for i in db['issues'].values() if i['title'] == 'noodlebot log 2026-03-10']
n = str(logs[0]['number']) if logs else ''
body = logs[0]['body'] if logs else ''
cs = [c for c in db['comments'] if c['issue'] == n]
print(eval(sys.argv[1]))" "$1" 2>/dev/null
}
vdump() { vq "body" >"$tmp/vbody"; vq "cs[0]['body']" >"$tmp/vfirst"; vq "'\n====\n'.join(c['body'] for c in cs)" >"$tmp/vall"; }

# The graph: V01 is ready, V02 waits for V01, V03 holds a question. V03 and V06 wait on the owner, each with a unit issue.
cat >"$vstate/graph.yaml" <<'GRAPH'
nodes:
  - {id: V01, name: vee-one, deps: []}
  - {id: V02, name: vee-two, deps: [V01]}
  - {id: V03, name: vee-three, deps: []}
GRAPH
: >"$vstate/merged-prs.txt"
printf 'vq-unique-question-line: which way?\nRecommendation: left.\n' >"$vstate/node/V03/QUESTION.md"
echo 47 >"$vstate/node/V03/issue"
printf '2026-03-08T00:00:00Z 2 starts with no PR\n' >"$vstate/node/V06/FAILED"
echo 48 >"$vstate/node/V06/issue"
# V04 ended on the previous day with a cost of $3.25; V05 runs now.
r 3.25 4 >"$vstate/node/V04/session.jsonl"
r 0.5 1 >"$vstate/node/V05/session.jsonl"
sh "$tmp/rs/run-session.sh" --node V05 &
echo $! >"$vstate/node/V05/session.pid"
pidsv=$!
trap 'kill $pidsv 2>/dev/null; rm -rf "$tmp"' EXIT
rs_wait $pidsv
printf '{"windows": {"five_hour": {"utilization": 0.62, "resetsAt": 1800000000, "status": "allowed"}, "seven_day": {"utilization": 0.4, "resetsAt": 1800500000, "status": "allowed"}}, "projected5h": 1.3, "weekElapsed": 0.5, "hold": true, "reason": "vthrottle-reason"}' >"$vroot/usage.json"
{
	echo "2026-03-09T21:00:00Z open=[] merged-prs=[]; started V04 (vee-four) in /wt, pid 1, start 1 of 2"
	echo "2026-03-09T22:00:00Z open=[] merged-prs=[]; session V04 ended (rc 0)"
} >"$vstate/status.log"

vrun 2026-03-10T09:00:00; vrc1=$?
vdump
ok "U02-AC-1: the first run of the day succeeds" test "$vrc1" = 0
ok "U02-AC-1: with no log issue for today it opens one titled 'noodlebot log 2026-03-10'" test "$(vq "len(logs)")" = 1
ok "U02-AC-1: labelled noodlebot-status" test "$(vq "'noodlebot-status' in logs[0]['labels']")" = True
ok "U02-AC-1: it links the previous day's issue (#150) in its body or its first comment" sh -c "grep -qE '(#150|/issues/150)([^0-9]|\$)' '$tmp/vbody' '$tmp/vfirst'"
vrun 2026-03-10T09:05:00; vrun 2026-03-10T09:10:00; vrc3=$?
vdump
ok "U02-AC-1: later runs that day succeed" test "$vrc3" = 0
ok "U02-AC-1: later runs that day use it and open no other (one log issue for today, two issues titled 'noodlebot log')" test "$(vq "len(logs)")$(vq "len([i for i in db['issues'].values() if i['title'].startswith('noodlebot log')])")" = 12

ok "U02-AC-2: the log issue has comments, the first being the morning overview, not a question pointer" sh -c "[ -s '$tmp/vfirst' ] && ! grep -q '^## V03 asks' '$tmp/vfirst'"
ok "U02-AC-2: the overview carries the previous day's summary (V04's cost on the previous day, \$3.25)" grep -qF '$3.25' "$tmp/vfirst"
ok "U02-AC-2: the overview names what waits on the owner (V03's question and V06's FAILED)" sh -c "grep -q V03 '$tmp/vfirst' && grep -q V06 '$tmp/vfirst'"
ok "U02-AC-2: the overview names the node ready next (V01)" grep -q V01 "$tmp/vfirst"
ok "U02-AC-2: and not a node that is not ready (V02 waits for V01)" sh -c "! grep -q V02 '$tmp/vfirst'"
ok "U02-AC-2: the overview is posted once, over three runs" test "$(vq "len([c for c in cs if 'V01' in c['body']])")" = 1
ok "U02-AC-2: and before any other comment (the question pointer follows it)" test "$(vq "[c['id'] for c in cs if '## V03 asks' in c['body']][0] > cs[0]['id']")" = True

ok "U02-AC-2: the body lists the running session V05 with its cost" sh -c "grep -q '^### V05,' '$tmp/vbody' && awk '/^### V05,/ {f=1} f' '$tmp/vbody' | head -n 1 | grep -qF '\$0.50'"
ok "U02-AC-2: the body lists the waiting unit V03 with a link to its unit issue (47)" sh -c "grep V03 '$tmp/vbody' | grep -qE '#47([^0-9]|\$)|/issues/47([^0-9]|\$)|/47/'"
ok "U02-AC-2: the body lists the waiting unit V06 (FAILED) with a link to its unit issue (#48)" sh -c "grep V06 '$tmp/vbody' | grep -qE '#48([^0-9]|\$)|/issues/48([^0-9]|\$)'"
ok "U02-AC-2: the body shows the throttle and the usage" sh -c "grep -q '5-hour.* 62%' '$tmp/vbody' && grep -q 'Throttle:.*vthrottle-reason' '$tmp/vbody'"
ok "U02-AC-2: the body has a deployed-commit line with the live checkout's HEAD" sh -c "grep -i 'deployed' '$tmp/vbody' | grep -qF '$(printf %s "$vsha1" | cut -c1-7)'"
ok "U02-AC-2: the body no longer has a 'Recent events' section" sh -c "! grep -q 'Recent events' '$tmp/vbody'"

# A later run edits the body (a new deployed commit) and posts no second overview; events are appended meanwhile.
git -C "$vlive" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "live two"
vsha2=$(git -C "$vlive" rev-parse HEAD)
mkdir -p "$vstate/node/V07" "$vstate/node/V08"
{ r 7.25 6; printf '%s\n' '{"type":"result","subtype":"success","result":"vsummary-unique-closing-text: all done, here is what I did."}'; } >"$vstate/node/V07/session.jsonl"
{ r 2.0 2; printf '%s\n' '{"type":"result","subtype":"success","result":"vsummary-unique-closing-text two"}'; } >"$vstate/node/V08/session.jsonl"
{
	echo "2026-03-10T09:11:00Z open=[] merged-prs=[]; started V05 (vee-five) in /wt, pid 1, start 1 of 2"
	echo "2026-03-10T09:12:00Z open=[] merged-prs=[]; session V05 (pid 1) running, log 5 bytes"
	echo "2026-03-10T09:13:00Z open=[] merged-prs=[]; session V07 ended (rc 0) with QUESTION.md"
	echo "2026-03-10T09:14:00Z open=[] merged-prs=[]; session V08 ended (rc 0)"
} >>"$vstate/status.log"
vrun 2026-03-10T09:20:00; vrc4=$?
vdump
ok "U02-AC-2: the run with new events succeeds" test "$vrc4" = 0
ok "U02-AC-2: a later run edits the body in place (the new deployed commit)" sh -c "grep -i 'deployed' '$tmp/vbody' | grep -qF '$(printf %s "$vsha2" | cut -c1-7)' && ! grep -i 'deployed' '$tmp/vbody' | grep -qF '$(printf %s "$vsha1" | cut -c1-7)'"
ok "U02-AC-2: the later run posts no second overview" test "$(vq "len([c for c in cs if 'V01' in c['body']])")" = 1
ok "U02-AC-2: the overview is still the first comment" grep -qF '$3.25' "$tmp/vfirst"

ev_re='started V05|session V07 ended|session V08 ended'
ok "U02-AC-3: each new event is posted (V05 started, V07 ended, V08 ended)" test "$(vq "len([l for c in cs for l in c['body'].splitlines() if re.search(r'$ev_re', l)])")" = 3
ok "U02-AC-3: the idle 'running, log' line is not posted" sh -c "! grep -q 'running, log' '$tmp/vall'"
ok "U02-AC-3: an event comment holds event lines only, one per line (no blank lines, no total or summary blocks)" test "$(vq "len([c for c in cs if re.search(r'$ev_re', c['body'])]) > 0 and all(l.startswith('- \`') for c in cs if re.search(r'$ev_re', c['body']) for l in c['body'].splitlines())")" = True
ok "U02-AC-3: an ended session's line carries its total cost (V07 \$7.25)" test "$(vq "len([l for c in cs for l in c['body'].splitlines() if 'session V07 ended' in l and '\$7.25' in l])")" = 1
ok "U02-AC-3: and another's (V08 \$2.00)" test "$(vq "len([l for c in cs for l in c['body'].splitlines() if 'session V08 ended' in l and '\$2.00' in l])")" = 1
ok "U02-AC-3: no comment holds a session's closing summary" sh -c "! grep -q 'vsummary-unique-closing-text' '$tmp/vall'"
ok "U02-AC-3: no comment holds the QUESTION.md's text" sh -c "! grep -q 'vq-unique-question-line' '$tmp/vall' && ! grep -q 'Recommendation: left' '$tmp/vall'"
vn=$(vq "len(cs)")
vrun 2026-03-10T09:25:00
ok "U02-AC-3: nothing is posted twice on a further run" test "$(vq "len(cs)")" = "$vn"
ok "U02-AC-3: the runs leave nothing on stderr" test ! -s "$tmp/verr"

# U02-AC-2 (a failed post, then a failed read): the next day's log issue is opened, its overview POST fails (run 1), then
# the GET of the recorded issue fails once (run 2); the clean runs after still post the overview first, once, and open no
# second log issue, with an event pending that an event comment would be posted for.
wq() {
	pyc "
import json, sys
db = json.load(open('$vdb'))
logs = [i for i in db['issues'].values() if i['title'] == 'noodlebot log 2026-03-11']
n = str(logs[0]['number']) if logs else ''
cs = [c for c in db['comments'] if c['issue'] == n]
print(eval(sys.argv[1]))" "$1" 2>/dev/null
}
echo "2026-03-11T08:00:00Z open=[] merged-prs=[]; started V09 (vee-nine) in /wt, pid 1, start 1 of 2" >>"$vstate/status.log"
echo 'POST .*/issues/[0-9]+/comments' >"$tmp/vfail"
vrun 2026-03-11T09:00:00
wn=$(wq "n")
echo "GET .*/issues/$wn\$" >"$tmp/vfail"
vrun 2026-03-11T09:05:00
rm -f "$tmp/vfail"
vrun 2026-03-11T09:10:00
echo "2026-03-11T09:12:00Z open=[] merged-prs=[]; session V09 ended (rc 0)" >>"$vstate/status.log"
vrun 2026-03-11T09:15:00
ok "U02-AC-2: after the failed post and the failed read, the log issue has exactly one overview comment (it names V01)" test "$(wq "len([c for c in cs if 'V01' in c['body']])")" = 1
ok "U02-AC-2: the overview is the issue's first comment, before any event line" test "$(wq "len(cs) > 0 and 'V01' in cs[0]['body'] and not any(l.startswith('- \`') for l in cs[0]['body'].splitlines())")" = True
ok "U02-AC-2: an event comment was posted after it (V09 ended)" test "$(wq "len([c for c in cs[1:] if 'session V09 ended' in c['body']])")" = 1
ok "U02-AC-2: no second log issue was opened for the day" test "$(wq "len(logs)")" = 1


if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
