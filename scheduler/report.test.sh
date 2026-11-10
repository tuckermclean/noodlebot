#!/bin/sh
# Tests scheduler/report.py against a fake `gh api` that keeps issues and comments in a JSON file.
#   sh scheduler/report.test.sh   (make test)
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
ok() { name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }

state=$tmp/state/repo db=$tmp/gh.json
mkdir -p "$state/node/A01" "$state/node/A02" "$tmp/bin" "$tmp/worktrees/repo"
echo '{"issues": {}, "comments": [], "labels": [], "pulls": [{"number": 7, "head": {"ref": "node/A01-first"}}]}' >"$db"
cat >"$tmp/bin/gh" <<EOF
#!/usr/bin/env python3
import json, re, sys
db = json.load(open("$db"))
a = sys.argv[1:]
assert a[0] == "api" and a[1] == "-X", a
method, path = a[2], a[3]
body = json.load(sys.stdin) if "--input" in a else None
open("$tmp/calls", "a").write("%s %s\n" % (method, path.split("?")[0]))
out = None
if method == "POST" and path.endswith("/labels"):
    if body["name"] in db["labels"]:
        print("HTTP 422: already_exists", file=sys.stderr); sys.exit(1)
    db["labels"].append(body["name"]); out = {}
elif method == "POST" and path.endswith("/issues"):
    n = str(100 + len(db["issues"]))
    db["issues"][n] = dict(body, number=int(n), state="open", node_id="I_" + n); out = db["issues"][n]
elif method == "GET" and re.search(r"/issues\?labels=", path):
    lab = re.search(r"labels=([^&]+)", path).group(1)
    out = [i for i in db["issues"].values() if i["state"] == "open" and lab in [l if isinstance(l, str) else l.get("name") for l in i.get("labels", [])]]
elif re.search(r"/issues/\d+$", path):
    n = path.rsplit("/", 1)[1]
    if method == "PATCH": db["issues"][n].update(body)
    out = db["issues"][n]
elif method == "POST" and path.endswith("/comments"):
    n = path.split("/")[-2]
    c = {"id": len(db["comments"]) + 1, "issue": n, "body": body["body"], "user": {"login": "bot", "type": "Bot"},
         "author_association": "NONE", "created_at": "2026-01-01T00:00:00Z", "html_url": "u"}
    db["comments"].append(c); out = c
elif method == "GET" and "/comments" in path:
    n = path.split("/")[-2]
    out = [c for c in db["comments"] if c["issue"] == n]
elif "/pulls" in path:
    out = db["pulls"]
elif path == "graphql":
    out = {}
else:
    print("unexpected " + method + " " + path, file=sys.stderr); sys.exit(1)
json.dump(db, open("$db", "w"))
print(json.dumps(out))
EOF
chmod +x "$tmp/bin/gh"
export PATH=$tmp/bin:$PATH
run() { python3 -I "$src/report.py" --repo owner/repo --state "$state" --worktrees "$tmp/worktrees/repo" 2>"$tmp/err"; }
q() { python3 -I -c "import json,sys; db=json.load(open('$db')); print(eval(sys.argv[1]))" "$1"; }
# owner_says <text>: the owner comments on the status issue.
owner_says() {
	python3 -I -c "
import json, sys
db = json.load(open('$db'))
db['comments'].append({'id': len(db['comments']) + 1, 'issue': '100', 'body': sys.argv[1], 'user': {'login': 'owner', 'type': 'User'},
    'author_association': 'OWNER', 'created_at': '2026-01-02T00:00:00Z', 'html_url': 'https://x/c'})
json.dump(db, open('$db', 'w'))" "$1"
}
last() { q "db['comments'][-1]['body']"; }
# sopen: a python expression (over `db`) for the open issues labelled noodlebot-status, as GitHub's label query finds them.
sopen="[i for i in db['issues'].values() if i['state'] == 'open' and 'noodlebot-status' in [l if isinstance(l, str) else l.get('name') for l in i.get('labels', [])]]"

echo "2026-01-01T00:00:00Z open=[] merged-prs=[]; started A01 (first) in /wt, pid 1, start 1 of 2" >"$state/status.log"
ok "the first run succeeds" run
ok "it creates the label and one status issue" test "$(q "len(db['issues']), db['labels']")" = "(1, ['noodlebot-status'])"
ok "the body lists no question yet" sh -c "! python3 -I -c \"import json; print(json.load(open('$db'))['issues']['100']['body'])\" | grep -q 'asks a question'"
ok "the open node PR without a session is listed" sh -c "python3 -I -c \"import json; print(json.load(open('$db'))['issues']['100']['body'])\" | grep -q 'A01.s PR #7'"
ok "the first run does not replay old events" test "$(q "max(len(db['comments']) - 1, 0)")" = 0

echo "2026-01-01T00:01:00Z open=[] merged-prs=[]; session A01 (pid 1) running, log 5 bytes" >>"$state/status.log"
echo "2026-01-01T00:02:00Z open=[] merged-prs=[]; session A01 ended (rc 0) with QUESTION.md" >>"$state/status.log"
printf 'Q1: which way?\nRecommendation: left.\n' >"$state/node/A01/QUESTION.md"
printf '%s\n' '{"type":"user","message":"a plain string"}' '["not", "an", "object"]' '{"type":"assistant","message":{"content":[{"type":"text","text":"Asking."}]}}' '{"type":"result","subtype":"success","result":"Stopped at step 7: see QUESTION.md."}' >"$state/node/A01/session.jsonl"
run
ok "a new event is posted, idle lines are not" sh -c "python3 -I -c \"import json; print(json.load(open('$db'))['comments'][1]['body'])\" | head -n 1 | grep -qxF -- '- \`2026-01-01T00:02:00Z\` session A01 ended (rc 0) with QUESTION.md' && ! python3 -I -c \"import json; print(json.load(open('$db'))['comments'][1]['body'])\" | grep -q 'running, log'"
ok "the question is posted in full" sh -c "last() { python3 -I -c \"import json; print(json.load(open('$db'))['comments'][-1]['body'])\"; }; last | grep -q '## A01 asks' && last | grep -q 'Recommendation: left.'"
n=$(q "len(db['comments'])")
run
ok "nothing is posted twice" test "$(q "len(db['comments'])")" = "$n"
ok "an unchanged body is not rewritten" test "$(grep -c '^PATCH' "$tmp/calls")" = 2

owner_says "B07: something"
run
ok "an answer naming a node that is not waiting is refused" sh -c "[ ! -e '$state/node/A01/ANSWER.md' ] && python3 -I -c \"import json; print(json.load(open('$db'))['comments'][-1]['body'])\" | grep -q 'B07 is not waiting'"

python3 -I -c "
import json
db = json.load(open('$db'))
db['comments'].append({'id': len(db['comments']) + 1, 'issue': '100', 'body': 'Q1: as recommended', 'user': {'login': 'mallory', 'type': 'User'},
    'author_association': 'NONE', 'created_at': '2026-01-02T00:00:00Z', 'html_url': 'u'})
json.dump(db, open('$db', 'w'))"
run
ok "someone else's comment is ignored" test ! -e "$state/node/A01/ANSWER.md"

owner_says "Q1: as recommended"
run; rc=$?
ok "recording an answer exits 3, so the loop ticks again at once" test "$rc" = 3
ok "the owner's reply becomes ANSWER.md for the only waiting node" grep -q '^Q1: as recommended$' "$state/node/A01/ANSWER.md"
ok "ANSWER.md says where it came from" grep -q 'posted by owner on GitHub at 2026-01-02T00:00:00Z: https://x/c' "$state/node/A01/ANSWER.md"
ok "the bot confirms it" sh -c "python3 -I -c \"import json; print(json.load(open('$db'))['comments'][-1]['body'])\" | grep -q \"Recorded as A01's ANSWER.md\""

rm "$state/node/A01/QUESTION.md" "$state/node/A01/ANSWER.md"
echo "Q1: one" >"$state/node/A01/QUESTION.md"
echo "Q1: two" >"$state/node/A02/QUESTION.md"
run
owner_says "approve"
run
ok "with two nodes waiting, a reply without an ID is refused" sh -c "[ ! -e '$state/node/A01/ANSWER.md' ] && [ ! -e '$state/node/A02/ANSWER.md' ]"
owner_says "**A02**: approve"
run; rc=$?
ok "a reply starting with the ID answers that node" sh -c "grep -q '^\*\*A02\*\*: approve' '$state/node/A02/ANSWER.md' && [ ! -e '$state/node/A01/ANSWER.md' ]"

python3 -I -c "
import json
db = json.load(open('$db')); db['issues']['100']['state'] = 'closed'; json.dump(db, open('$db', 'w'))"
run
ok "a closed status issue is replaced by a new one" test "$(q "$sopen[0]['state']")" = open

printf '{"windows": {"five_hour": {"utilization": 0.62, "resetsAt": 1800000000, "status": "allowed"}, "seven_day": {"utilization": 0.4, "resetsAt": 1800500000, "status": "allowed"}}, "projected5h": 1.3, "weekElapsed": 0.5, "hold": true, "reason": "5-hour window projected to reach 130%% before it resets (limit 90%%)"}' >"$tmp/state/usage.json"
run
ok "the body shows both windows and the throttle holding" sh -c "python3 -I -c \"import json; db = json.load(open('$db')); print($sopen[0]['body'])\" | grep -q '5-hour.* 62%, resets' && python3 -I -c \"import json; db = json.load(open('$db')); print($sopen[0]['body'])\" | grep -q 'Throttle:\*\* \*\*holding new sessions\*\*: 5-hour window projected to reach 130%'"
ok "no run left an error" test ! -s "$tmp/err"
mkdir "$tmp/badbin" && printf '#!/bin/sh\necho "HTTP 502" >&2; exit 1\n' >"$tmp/badbin/gh" && chmod +x "$tmp/badbin/gh"
PATH=$tmp/badbin:$PATH run; rc=$?
ok "a failing gh exits non-zero with one line on stderr" sh -c "[ $rc -ne 0 ] && [ \$(wc -l <'$tmp/err') = 1 ]"

# C01: cost and turns of each session, from its stream-json `result` events. A fresh state dir: its status issue is 101.
state2=$tmp/state/repo2
mkdir -p "$tmp/rs" "$state2/node/A03" "$state2/node/A04" "$state2/node/A05" "$state2/node/A06" "$state2/node/A07"
printf '#!/bin/sh\nwhile :; do sleep 1; done\n' >"$tmp/rs/run-session.sh"
pids=
for n in A03 A04 A05 A06; do
	sh "$tmp/rs/run-session.sh" --node $n &
	echo $! >"$state2/node/$n/session.pid"
	pids="$pids $!"
done
trap 'kill $pids 2>/dev/null; rm -rf "$tmp"' EXIT
sleep 1
run2() { python3 -I "$src/report.py" --repo owner/repo --state "$state2" --worktrees "$tmp/worktrees/repo" 2>"$tmp/err2"; }
dump() {
	python3 -I -c "
import json
db = json.load(open('$db'))
st = $sopen[0]
open('$tmp/body2', 'w').write(st['body'])
open('$tmp/comments2', 'w').write('\n'.join(c['body'] for c in db['comments'] if c['issue'] == str(st['number'])))"
}
# section <ID>: the session's header line and the lines under it, up to the next heading.
section() { awk -v id="$1" 'f && /^##/ {f=0} index($0, "### " id ",") == 1 {f=1} f' "$tmp/body2"; }
sec_has() { section "$1" | grep -qF -- "$2"; }
sec_turns() { section "$1" | grep -qE "(^|[^0-9])$2 turns"; }
sec_lacks() { ! section "$1" | grep -qF -- "$2"; }
sec_nodollar() { ! section "$1" | grep -qE '\$[0-9]'; }
r() { printf '{"type":"result","subtype":"success","total_cost_usd":%s,"num_turns":%s,"result":"x"}\n' "$1" "$2"; }
{ r 1.25 3; r 3.5 4; r 4.75 5; } >"$state2/node/A03/session.jsonl"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Working."}]}}' >"$state2/node/A04/session.jsonl"
printf '%s\n' 'garbage {' '[1, 2]' \
	'{"type":"result","total_cost_usd":"3.00","num_turns":2}' \
	'{"type":"result","num_turns":2}' \
	'{"type":"result","total_cost_usd":3.0}' >"$state2/node/A05/session.jsonl"
{ r 1.0 1; r '"99"' 2; echo 'garbage {'; r 2.5 3; r null 1; } >"$state2/node/A06/session.jsonl"
{ r 2.5 2; r 7.25 6; } >"$state2/node/A07/session.jsonl"
: >"$state2/status.log"
run2; rc1=$?
dump
echo "2026-01-03T00:00:00Z open=[] merged-prs=[]; session A07 ended (rc 0)" >>"$state2/status.log"
run2; rc2=$?
dump

ok "C01-AC-1: the running session shows its latest total_cost_usd in dollars" sec_has A03 '$4.75'
ok "C01-AC-1: the running session shows the turns summed over its results" sec_turns A03 12
ok "C01-AC-1: the cost is the running total, not the sum of the totals" sh -c "! grep -F '\$9.50' '$tmp/body2'"
ok "C01-AC-3: a session with no result event shows no cost yet" sec_has A04 'no cost yet'
ok "C01-AC-3: a session with no result event shows no dollar figure" sec_nodollar A04
ok "C01-AC-3: a session with only malformed lines shows no cost yet" sec_has A05 'no cost yet'
ok "C01-AC-3: a session with only malformed lines shows no dollar figure" sec_nodollar A05
ok "C01-AC-3: well-formed results among malformed lines give the cost" sec_has A06 '$2.50'
ok "C01-AC-3: such a session does not show no cost yet" sec_lacks A06 'no cost yet'
ok "C01-AC-3: a malformed cost is not shown" sh -c "! grep -F '\$99' '$tmp/body2'"
ok "C01-AC-3: the report exits 0 and the body is written" sh -c "[ $rc1 -eq 0 ] && [ $rc2 -eq 0 ] && grep -qF 'Sessions (4 running)' '$tmp/body2'"
ok "C01-AC-3: the report leaves nothing on stderr" test ! -s "$tmp/err2"
ok "C01-AC-2: the end of A07 is posted as a comment" grep -qF 'session A07 ended' "$tmp/comments2"
ok "C01-AC-2: the end comment carries the latest total, in dollars" grep -qF '$7.25' "$tmp/comments2"
ok "C01-AC-2: the end comment carries the turns summed over results" grep -qE '(^|[^0-9])8 turns' "$tmp/comments2"
ok "C01-AC-2: the end comment does not carry the sum of the totals" sh -c "! grep -F '\$9.75' '$tmp/comments2'"
# D02-AC-1: without --worktrees, report.py finds a node's worktree under the runtime root
# ($NOODLEBOT_DATA, else $HOME/.local/share/noodlebot), whatever folder --state is in.
# mkwt <root> <subject>: <root>/worktrees/repo/A01, a clone-less repository one commit ahead of origin/main.
mkwt() {
	w=$1/worktrees/repo/A01
	mkdir -p "$w" && git init -q -b main "$w" &&
		git -C "$w" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base &&
		git -C "$w" update-ref refs/remotes/origin/main HEAD &&
		git -C "$w" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$2"
}
# live_session <state>: a process whose command line looks like A01's session; its pid is recorded.
live_session() {
	sh -c 'sleep 60' claude -p /node A01 &
	echo $! >"$1/node/A01/session.pid"; sess="$sess $!"
}
sess=''
trap 'kill $sess 2>/dev/null; rm -rf "$tmp"' EXIT
bodies="import json; print(' '.join(i['body'] for i in json.load(open('$db'))['issues'].values()))"
# The state folders are not <root>/state/repo, so only the runtime-root rule can find the worktrees.
sdata=$tmp/elsewhere/data-state sunset=$tmp/elsewhere/unset-state
mkdir -p "$sdata/node/A01" "$sunset/node/A01"
echo "2026-01-01T00:00:00Z open=[] merged-prs=[]; started A01 (first) in /wt, pid 1, start 1 of 2" | tee "$sdata/status.log" >"$sunset/status.log"
mkwt "$tmp/root-data" commit-in-data-root && live_session "$sdata"
mkwt "$tmp/home2/.local/share/noodlebot" commit-in-home-root && live_session "$sunset"
NOODLEBOT_DATA=$tmp/root-data python3 -I "$src/report.py" --repo owner/repo --state "$sdata" 2>"$tmp/err2"
ok "D02-AC-1: NOODLEBOT_DATA set, report.py finds the worktree under \$NOODLEBOT_DATA/worktrees/<name>" sh -c "python3 -I -c \"$bodies\" | grep -q commit-in-data-root"
env -u NOODLEBOT_DATA HOME="$tmp/home2" python3 -I "$src/report.py" --repo owner/repo --state "$sunset" 2>>"$tmp/err2"
ok "D02-AC-1: NOODLEBOT_DATA unset, report.py finds the worktree under \$HOME/.local/share/noodlebot/worktrees/<name>" sh -c "python3 -I -c \"$bodies\" | grep -q commit-in-home-root"
trap 'kill $pids $sess 2>/dev/null; rm -rf "$tmp"' EXIT

# C01-AC-3 again: non-finite numbers (NaN, Infinity, 1e400) and truncated result lines are malformed lines, skipped.
state3=$tmp/state/repo3
mkdir -p "$state3/node/E01" "$state3/node/E02" "$state3/node/E03"
pids3=
for n in E01 E02; do
	sh "$tmp/rs/run-session.sh" --node $n &
	echo $! >"$state3/node/$n/session.pid"
	pids3="$pids3 $!"
done
trap 'kill $pids $sess $pids3 2>/dev/null; rm -rf "$tmp"' EXIT
sleep 1
run3() { python3 -I "$src/report.py" --repo owner/repo --state "$state3" --worktrees "$tmp/worktrees/repo" 2>"$tmp/err3"; }
dump3() {
	python3 -I -c "
import json
db = json.load(open('$db'))
open('$tmp/body3', 'w').write('\n'.join(x['body'] for x in db['issues'].values() if 'E01' in x['body']))
open('$tmp/endcomment3', 'w').write('\n'.join(c['body'] for c in db['comments'] if 'session E03 ended' in c['body']))"
}
section3() { awk -v id="$1" 'f && /^##/ {f=0} index($0, "### " id ",") == 1 {f=1} f' "$tmp/body3"; }
nf='{"type":"result","total_cost_usd":%s,"num_turns":%s}\n'
nonfinite() {
	printf "$nf" 1.5 NaN
	printf "$nf" 1.5 Infinity
	printf "$nf" 1.5 1e400
	printf "$nf" 1.5 -Infinity
	printf "$nf" NaN 2
	printf "$nf" Infinity 2
	printf "$nf" 1e400 2
	printf "$nf" -Infinity 2
}
{ nonfinite; printf '%s\n' '{"type":"result","total_cost_usd":1.5,"num_tu'; } >"$state3/node/E01/session.jsonl"
{ nonfinite; r 1.0 1; printf '%s\n' '{"type":"result","total_cost_usd":9.9,"num_tu'; r 2.5 3; nonfinite; printf '%s\n' '{"type":"result","total_cost_usd":8.8,"num_tu'; } >"$state3/node/E02/session.jsonl"
{ r 1.0 1; nonfinite; r 6.5 4; printf '%s\n' '{"type":"result","total_cost_usd":9.9,"num_tu'; } >"$state3/node/E03/session.jsonl"
: >"$state3/status.log"
run3; rc3=$?
dump3
echo "2026-01-04T00:00:00Z open=[] merged-prs=[]; session E03 ended (rc 0)" >>"$state3/status.log"
run3; rc4=$?
dump3
sec3_has() { section3 "$1" | grep -qF -- "$2"; }
sec3_nodollar() { ! section3 "$1" | grep -qE '\$[0-9]'; }
sec3_turns() { section3 "$1" | grep -qE "(^|[^0-9])$2 turns"; }
sec3_lacks() { ! section3 "$1" | grep -qF -- "$2"; }
nonfin='\$-?(inf|nan)|(inf|nan) turns|\$[0-9]{6,}'
ok "C01-AC-3: non-finite and truncated results only: the session shows no cost yet" sec3_has E01 'no cost yet'
ok "C01-AC-3: non-finite and truncated results only: no dollar figure" sec3_nodollar E01
ok "C01-AC-3: the status body shows no non-finite cost or turns" sh -c "! grep -qiE '$nonfin' '$tmp/body3'"
ok "C01-AC-3: well-formed result among non-finite and truncated lines gives the latest cost" sec3_has E02 '$2.50'
ok "C01-AC-3: such a session shows its summed turns" sec3_turns E02 4
ok "C01-AC-3: such a session does not show no cost yet" sec3_lacks E02 'no cost yet'
ok "C01-AC-3: a truncated cost is not shown" sh -c "! grep -qE '9[.]90|8[.]80' '$tmp/body3'"
ok "C01-AC-3: the end of E03 is posted despite non-finite and truncated lines" test -s "$tmp/endcomment3"
ok "C01-AC-3: the end comment (whole body) carries the well-formed total" grep -qF '$6.50' "$tmp/endcomment3"
ok "C01-AC-3: the end comment (whole body) carries the well-formed turns" grep -qE '(^|[^0-9])5 turns' "$tmp/endcomment3"
ok "C01-AC-3: the end comment shows no non-finite cost or turns" sh -c "! grep -qiE '$nonfin' '$tmp/endcomment3'"
ok "C01-AC-3: the report exits 0 on both runs" sh -c "[ $rc3 -eq 0 ] && [ $rc4 -eq 0 ]"
ok "C01-AC-3: the status body is the normal one, not a fallback" grep -qF 'Sessions (2 running)' "$tmp/body3"
ok "C01-AC-3: the report leaves nothing on stderr" test ! -s "$tmp/err3"
trap 'kill $pids $sess $pids3 2>/dev/null; rm -rf "$tmp"' EXIT

# C01-AC-3 once more: an integer too large for a float is valid JSON, but the line is malformed and skipped.
state4=$tmp/state/repo4
mkdir -p "$state4/node/F01" "$state4/node/F02" "$state4/node/F03"
pids4=
for n in F01 F02; do
	sh "$tmp/rs/run-session.sh" --node $n &
	echo $! >"$state4/node/$n/session.pid"
	pids4="$pids4 $!"
done
trap 'kill $pids $sess $pids3 $pids4 2>/dev/null; rm -rf "$tmp"' EXIT
sleep 1
run4() { python3 -I "$src/report.py" --repo owner/repo --state "$state4" --worktrees "$tmp/worktrees/repo" 2>"$tmp/err4"; }
dump4() {
	python3 -I -c "
import json
db = json.load(open('$db'))
open('$tmp/body4', 'w').write('\n'.join(x['body'] for x in db['issues'].values() if 'F01' in x['body']))
open('$tmp/endcomment4', 'w').write('\n'.join(c['body'] for c in db['comments'] if 'session F03 ended' in c['body']))"
}
section4() { awk -v id="$1" 'f && /^##/ {f=0} index($0, "### " id ",") == 1 {f=1} f' "$tmp/body4"; }
big=1$(awk 'BEGIN { for (i = 0; i < 400; i++) printf "0" }')
bigint() {
	printf "$nf" "$big" 2
	printf "$nf" 1.5 "$big"
	printf "$nf" "-$big" 2
	printf "$nf" 1.5 "-$big"
}
bigint >"$state4/node/F01/session.jsonl"
{ bigint; r 1.0 1; bigint; r 2.5 3; bigint; } >"$state4/node/F02/session.jsonl"
{ r 1.0 1; bigint; r 6.5 4; bigint; } >"$state4/node/F03/session.jsonl"
: >"$state4/status.log"
run4; rc5=$?
dump4
echo "2026-01-05T00:00:00Z open=[] merged-prs=[]; session F03 ended (rc 0)" >>"$state4/status.log"
run4; rc6=$?
dump4
sec4_has() { section4 "$1" | grep -qF -- "$2"; }
sec4_nodollar() { ! section4 "$1" | grep -qE '\$[0-9]'; }
sec4_turns() { section4 "$1" | grep -qE "(^|[^0-9])$2 turns"; }
sec4_lacks() { ! section4 "$1" | grep -qF -- "$2"; }
ok "C01-AC-3: huge-integer results only: the session shows no cost yet" sec4_has F01 'no cost yet'
ok "C01-AC-3: huge-integer results only: no dollar figure" sec4_nodollar F01
ok "C01-AC-3: well-formed result among huge-integer lines gives the latest cost" sec4_has F02 '$2.50'
ok "C01-AC-3: such a session shows its summed turns" sec4_turns F02 4
ok "C01-AC-3: such a session does not show no cost yet" sec4_lacks F02 'no cost yet'
ok "C01-AC-3: the end of F03 is posted despite huge-integer lines" test -s "$tmp/endcomment4"
ok "C01-AC-3: the end comment (whole body) carries the well-formed total despite huge integers" grep -qF '$6.50' "$tmp/endcomment4"
ok "C01-AC-3: the end comment (whole body) carries the well-formed turns despite huge integers" grep -qE '(^|[^0-9])5 turns' "$tmp/endcomment4"
ok "C01-AC-3: the report exits 0 on both huge-integer runs" sh -c "[ $rc5 -eq 0 ] && [ $rc6 -eq 0 ]"
ok "C01-AC-3: the huge-integer status body is the normal one, not a fallback" grep -qF 'Sessions (2 running)' "$tmp/body4"
ok "C01-AC-3: the huge-integer runs leave nothing on stderr" test ! -s "$tmp/err4"
trap 'kill $pids $sess $pids3 $pids4 2>/dev/null; rm -rf "$tmp"' EXIT

# C01-AC-3 once more: finite turns that overflow when summed must not stop the report.
state5=$tmp/state/repo5
mkdir -p "$state5/node/G01" "$state5/node/G02"
pids5=
sh "$tmp/rs/run-session.sh" --node G01 &
echo $! >"$state5/node/G01/session.pid"
pids5="$pids5 $!"
trap 'kill $pids $sess $pids3 $pids4 $pids5 2>/dev/null; rm -rf "$tmp"' EXIT
sleep 1
run5() { python3 -I "$src/report.py" --repo owner/repo --state "$state5" --worktrees "$tmp/worktrees/repo" 2>"$tmp/err5"; }
dump5() {
	python3 -I -c "
import json
db = json.load(open('$db'))
open('$tmp/body5', 'w').write('\n'.join(x['body'] for x in db['issues'].values() if 'G01' in x['body']))
open('$tmp/endcomment5', 'w').write('\n'.join(c['body'] for c in db['comments'] if 'session G02 ended' in c['body']))"
}
ovf() {
	printf "$nf" 1.0 1e308
	printf "$nf" 1.0 1e308
	printf "$nf" 1.0 1e308
}
{ r 2.5 3; ovf; } >"$state5/node/G01/session.jsonl"
{ r 6.5 4; ovf; } >"$state5/node/G02/session.jsonl"
: >"$state5/status.log"
run5; rc7=$?
dump5
echo "2026-01-06T00:00:00Z open=[] merged-prs=[]; session G02 ended (rc 0)" >>"$state5/status.log"
run5; rc8=$?
dump5
ok "C01-AC-3: the report exits 0 on both overflowing-turns runs" sh -c "[ $rc7 -eq 0 ] && [ $rc8 -eq 0 ]"
ok "C01-AC-3: the overflowing-turns runs leave nothing on stderr" test ! -s "$tmp/err5"
ok "C01-AC-3: the overflowing-turns status body is the normal one" grep -qF 'Sessions (1 running)' "$tmp/body5"
ok "C01-AC-3: the overflowing-turns status body has the G01 section" grep -qF '### G01,' "$tmp/body5"
ok "C01-AC-3: the end of G02 is posted despite overflowing turns" grep -qF 'session G02 ended' "$tmp/endcomment5"
ok "C01-AC-3: no inf or nan in the overflowing-turns status body" sh -c "! grep -qiE '\\\$-?(inf|nan)|(inf|nan) turns' '$tmp/body5'"
ok "C01-AC-3: no inf or nan in the overflowing-turns end comment" sh -c "! grep -qiE '\\\$-?(inf|nan)|(inf|nan) turns' '$tmp/endcomment5'"
trap 'kill $pids $sess $pids3 $pids4 $pids5 2>/dev/null; rm -rf "$tmp"' EXIT

# C01-AC-3 once more: a log line nested too deeply to parse must not stop the report.
# The deep line sits more than 1 MiB before the end, so only the whole-log cost path reads it.
state6=$tmp/state/repo6
mkdir -p "$state6/node/H01" "$state6/node/H02"
pids6=
sh "$tmp/rs/run-session.sh" --node H01 &
echo $! >"$state6/node/H01/session.pid"
pids6="$pids6 $!"
trap 'kill $pids $sess $pids3 $pids4 $pids5 $pids6 2>/dev/null; rm -rf "$tmp"' EXIT
sleep 1
run6() { python3 -I "$src/report.py" --repo owner/repo --state "$state6" --worktrees "$tmp/worktrees/repo" 2>"$tmp/err6"; }
dump6() {
	python3 -I -c "
import json
db = json.load(open('$db'))
open('$tmp/body6', 'w').write('\n'.join(x['body'] for x in db['issues'].values() if 'H01' in x['body']))
open('$tmp/endcomment6', 'w').write('\n'.join(c['body'] for c in db['comments'] if 'session H02 ended' in c['body']))"
}
deep() { awk 'BEGIN { for (i = 0; i < 100000; i++) printf "{\"a\":"; printf "\"result\"\n" }'; }
filler() { awk 'BEGIN { for (i = 0; i < 12000; i++) printf "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"filler line %d padding padding padding padding padding padding padding padding\"}]}}\n", i }'; }
filler >"$tmp/filler6"
{ r 1.0 1; deep; cat "$tmp/filler6"; r 2.5 3; } >"$state6/node/H01/session.jsonl"
{ r 1.0 1; deep; cat "$tmp/filler6"; r 6.5 4; } >"$state6/node/H02/session.jsonl"
: >"$state6/status.log"
run6; rc9=$?
dump6
echo "2026-01-07T00:00:00Z open=[] merged-prs=[]; session H02 ended (rc 0)" >>"$state6/status.log"
run6; rc10=$?
dump6
ok "C01-AC-3: the report exits 0 on both deeply-nested-line runs" sh -c "[ $rc9 -eq 0 ] && [ $rc10 -eq 0 ]"
ok "C01-AC-3: the deeply-nested-line runs leave nothing on stderr" test ! -s "$tmp/err6"
ok "C01-AC-3: the deeply-nested-line status body is the normal one" grep -qF 'Sessions (1 running)' "$tmp/body6"
ok "C01-AC-3: the deeply-nested-line status body has the H01 section" grep -qF '### H01,' "$tmp/body6"
ok "C01-AC-3: H01 shows the latest well-formed total despite a deeply nested line" grep -qF '$2.50' "$tmp/body6"
ok "C01-AC-3: H01 shows its summed turns despite a deeply nested line" grep -qE '(^|[^0-9])4 turns' "$tmp/body6"
ok "C01-AC-3: the end of H02 is posted despite a deeply nested line" grep -qF 'session H02 ended' "$tmp/endcomment6"
ok "C01-AC-3: the H02 end comment (whole body) carries the well-formed total" grep -qF '$6.50' "$tmp/endcomment6"
ok "C01-AC-3: the H02 end comment (whole body) carries the well-formed turns" grep -qE '(^|[^0-9])5 turns' "$tmp/endcomment6"
trap 'kill $pids $sess $pids3 $pids4 $pids5 $pids6 2>/dev/null; rm -rf "$tmp"' EXIT


# S01-AC-4: the item for a FAILED node gives the reason from the first line of its FAILED file (not
# its other lines) and the path to delete.
mkdir -p "$state/node/C05"
printf '2026-01-03T00:00:00Z PR #12 was closed without merging; delete this file to start the node again\nsecond-line-detail\n' >"$state/node/C05/FAILED"
run
s01body=$(q "$sopen[0]['body']")
ok "S01-AC-4: the FAILED item gives the first line of the FAILED file as the reason" sh -c "printf '%s\n' \"\$1\" | grep -qF 'PR #12 was closed without merging; delete this file to start the node again'" _ "$s01body"
ok "S01-AC-4: and the path to delete" sh -c "printf '%s\n' \"\$1\" | grep 'C05 FAILED' | grep -qF '$state/node/C05/FAILED'" _ "$s01body"
ok "S01-AC-4: and not the fixed text" sh -c "! printf '%s\n' \"\$1\" | grep 'C05 FAILED' | grep -q '2 starts with no PR'" _ "$s01body"
ok "S01-AC-4: and not the file's later lines" sh -c "! printf '%s\n' \"\$1\" | grep -q second-line-detail" _ "$s01body"

# G01-AC-7: a spec PR's update session is the task "PR #N" (state/pr/<N>/): running, it is a section of
# the status issue; FAILED, it is an item under "Waiting on you" with the first line of its FAILED file
# and the path to delete.
state7=$tmp/state/repo7
mkdir -p "$state7/pr/12" "$state7/pr/13"
sh "$tmp/rs/run-session.sh" --update 12 &
pids7=$!
echo "$pids7" >"$state7/pr/12/session.pid"
echo 1 >"$state7/pr/12/starts"
trap 'kill $pids $sess $pids3 $pids4 $pids5 $pids6 $pids7 2>/dev/null; rm -rf "$tmp"' EXIT
sleep 1
printf '2026-01-08T00:00:00Z second exit (rc 1) without finishing\nsecond-line-detail-13\n' >"$state7/pr/13/FAILED"
: >"$state7/status.log"
python3 -I "$src/report.py" --repo owner/repo --state "$state7" --worktrees "$tmp/worktrees/repo" 2>"$tmp/err7"
body7=$(q "$sopen[0]['body']")
printf '%s\n' "$body7" >"$tmp/body7"
awk '/^## Waiting on you/ {f=1; next} /^## / {f=0} f' "$tmp/body7" >"$tmp/waiting7"
ok "G01-AC-7: the report runs on a state dir with pr/<N> folders without error" test ! -s "$tmp/err7"
ok "G01-AC-7: a running update is shown as PR #12" grep -qE '^### .*PR #12' "$tmp/body7"
ok "G01-AC-7: it counts as a running session" grep -qF 'Sessions (1 running)' "$tmp/body7"
ok "G01-AC-7: its section says it is start 1 of 2" sh -c "grep -E '^### .*PR #12' '$tmp/body7' | grep -qF 'start 1 of 2'"
ok "G01-AC-7: a FAILED update is under Waiting on you as PR #13" sh -c "grep 'PR #13' '$tmp/waiting7' | grep -q FAILED"
ok "G01-AC-7: with the first line of its FAILED file" sh -c "grep 'PR #13' '$tmp/waiting7' | grep -qF 'second exit (rc 1) without finishing'"
ok "G01-AC-7: and the path to delete" sh -c "grep 'PR #13' '$tmp/waiting7' | grep -qF '$state7/pr/13/FAILED'"
ok "G01-AC-7: and not the file's later lines" sh -c "! grep -q second-line-detail-13 '$tmp/body7'"
ok "G01-AC-7: the running update is not listed as waiting" sh -c "! grep -q 'PR #12' '$tmp/waiting7'"
# (merge of G01 and S03: both cases use state7; clear it between them)
rm -rf "$tmp/state/repo7"
# S03-AC-7, S03-AC-8: "Waiting on you" and the reply to an answer say "within seconds" only when ready.py, run on the
# state folder's inputs (graph.yaml, subjects.txt, merged-prs.txt, merged-prs.tsv), names the node.
state7=$tmp/state/repo7
mkdir -p "$state7/node"
cat >"$state7/graph.yaml" <<'GRAPH'
nodes:
  - {id: K01, name: kay-one, deps: []}
  - {id: K02, name: kay-two, deps: [K01]}
  - {id: M01, name: merged-one, deps: []}
  - {id: M02, name: merged-two, deps: []}
  - {id: F01, name: failed-one, deps: []}
  - {id: W01, name: waiting-one, deps: []}
GRAPH
echo "31 node/M01-merged-one" >"$state7/merged-prs.tsv"
echo 31 >"$state7/merged-prs.txt"
echo "M02 merged-two: the squash subject of its PR (#40)" >"$state7/subjects.txt"
: >"$state7/status.log"
for n in K01 K02 M01 M02 F01 W01 Z09; do
	mkdir -p "$state7/node/$n"
	printf 'Q1: which way for %s?\n' "$n" >"$state7/node/$n/QUESTION.md"
done
printf '2026-01-08T00:00:00Z 2 starts with no PR\nmore detail\n' >"$state7/node/F01/FAILED"
echo 55 >"$state7/node/W01/WAITING-PR"
run7() { python3 -I "$src/report.py" --repo owner/repo --state "$state7" --worktrees "$tmp/worktrees/repo" 2>"$tmp/err7"; }
# owner7 <text>: the owner comments on the open status issue.
owner7() {
	python3 -I -c "
import json, sys
db = json.load(open('$db'))
n = $sopen[0]['number']
db['comments'].append({'id': len(db['comments']) + 1, 'issue': str(n), 'body': sys.argv[1], 'user': {'login': 'owner', 'type': 'User'},
    'author_association': 'OWNER', 'created_at': '2026-01-09T00:00:00Z', 'html_url': 'https://x/c7'})
json.dump(db, open('$db', 'w'))" "$1"
}
# dump7: the open status issue's body, and every comment of that issue, to files.
dump7() {
	python3 -I -c "
import json
db = json.load(open('$db'))
i = $sopen[0]
open('$tmp/body7', 'w').write(i['body'])
open('$tmp/comments7', 'w').write('\n====\n'.join(c['body'] for c in db['comments'] if c['issue'] == str(i['number'])))"
}
# item7 <ID>: the node's line under "Waiting on you"; reply7 <ID>: the bot's reply recording its answer.
item7() { awk '/^## Waiting on you/ {f=1; next} /^## / {f=0} f' "$tmp/body7" | grep -E -- "^- .{0,4}$1([^0-9A-Za-z]|\$)" | head -n 1; }
reply7() { awk -v RS='\n====\n' -v k="Recorded as $1's ANSWER.md" 'index($0, k) { print; exit }' "$tmp/comments7"; }
says() { printf '%s\n' "$2" | grep -qiE -- "$1"; }
lacks_seconds() { ! printf '%s\n' "$1" | grep -qi 'within seconds'; }
lacks() { ! printf '%s\n' "$2" | grep -qiE -- "$1"; }
nonempty() { [ -n "$1" ]; }
run7; rc7a=$?
dump7
ok "S03-AC-7: the first run exits 0 and leaves nothing on stderr" sh -c "[ $rc7a -eq 0 ] && [ ! -s '$tmp/err7' ]"
ok "S03-AC-7: a merged node's question is posted as for any node" grep -qF '## M02 asks' "$tmp/comments7"
ok "S03-AC-7: a merged node's unanswered question is listed under Waiting on you" nonempty "$(item7 M02)"
ok "S03-AC-7: its item says the node's PR is merged" says "M02's PR is merged" "$(item7 M02)"
ok "S03-AC-7: its item says its question is still open, and an answer starts a follow-up" says "its question is still open, and an answer starts a follow-up" "$(item7 M02)"
ok "S03-AC-7: a node merged by merged-prs.tsv gets the same item" says "M01's PR is merged; its question is still open, and an answer starts a follow-up" "$(item7 M01)"
ok "S03-AC-7: an unmerged node's open question is not said to be merged" lacks "is merged" "$(item7 K01)"

for n in K01 K02 M01 M02 F01 W01 Z09; do owner7 "$n: as recommended"; done
run7; rc7b=$?
dump7
ok "S03-AC-7: an answer to a merged node's question is recorded as for any node (exit 3)" test "$rc7b" = 3
ok "S03-AC-7: its ANSWER.md is written" grep -q '^M02: as recommended$' "$state7/node/M02/ANSWER.md"
ok "S03-AC-7: and the bot confirms it" nonempty "$(reply7 M02)"

ok "S03-AC-8: an answered unmerged node that ready.py names: the item says it resumes within seconds" says "resumes within seconds" "$(item7 K01)"
ok "S03-AC-8: and the reply says it resumes within seconds" says "K01 resumes within seconds" "$(reply7 K01)"
ok "S03-AC-8: an answered merged node (merged-prs.tsv) that ready.py names: the item says a follow-up starts within seconds" says "follow-up starts within seconds" "$(item7 M01)"
ok "S03-AC-8: and the reply says a follow-up starts within seconds" says "follow-up starts within seconds" "$(reply7 M01)"
ok "S03-AC-8: the same for a node merged by its squash subject (item)" says "follow-up starts within seconds" "$(item7 M02)"
ok "S03-AC-8: the same for a node merged by its squash subject (reply)" says "follow-up starts within seconds" "$(reply7 M02)"
ok "S03-AC-8: the merged node's item does not say it resumes within seconds" lacks "resumes within seconds" "$(item7 M01)"

ok "S03-AC-8: a FAILED node's item gives its reason" says "2 starts with no PR" "$(item7 F01)"
ok "S03-AC-8: a FAILED node's item does not say within seconds" lacks_seconds "$(item7 F01)"
ok "S03-AC-8: the reply for a FAILED node says it is held by FAILED" says "FAILED" "$(reply7 F01)"
ok "S03-AC-8: and gives the FAILED reason" says "2 starts with no PR" "$(reply7 F01)"
ok "S03-AC-8: the F01 reply does not say within seconds" lacks_seconds "$(reply7 F01)"

ok "S03-AC-8: a node with a WAITING-PR not in the merged PRs: the item names the spec PR it waits for" says "spec PR #55" "$(item7 W01)"
ok "S03-AC-8: the W01 item does not say within seconds" lacks_seconds "$(item7 W01)"
ok "S03-AC-8: its reply names the spec PR it waits for" says "spec PR #55" "$(reply7 W01)"
ok "S03-AC-8: the W01 reply does not say within seconds" lacks_seconds "$(reply7 W01)"

ok "S03-AC-8: a node with an unmerged dep: the item names the dep" says "K01" "$(item7 K02 | sed 's/K02//')"
ok "S03-AC-8: the K02 item does not say within seconds" lacks_seconds "$(item7 K02)"
ok "S03-AC-8: its reply names the dep it waits for" says "K01" "$(reply7 K02 | sed 's/K02//g')"
ok "S03-AC-8: the K02 reply does not say within seconds" lacks_seconds "$(reply7 K02)"

ok "S03-AC-8: a node absent from the graph: the item says it is not in the graph" says "not in the graph" "$(item7 Z09)"
ok "S03-AC-8: the Z09 item does not say within seconds" lacks_seconds "$(item7 Z09)"
ok "S03-AC-8: its reply says it is not in the graph" says "not in the graph" "$(reply7 Z09)"
ok "S03-AC-8: the Z09 reply does not say within seconds" lacks_seconds "$(reply7 Z09)"
ok "S03-AC-8: the S03 runs leave nothing on stderr" test ! -s "$tmp/err7"

# S03-AC-8 (Change 7): when ready.py cannot be run (no graph.yaml), the answer is recorded and no timing is claimed.
state8=$tmp/state/repo8
mkdir -p "$state8/node/R01"
: >"$state8/status.log"
printf 'Q1: which way?\n' >"$state8/node/R01/QUESTION.md"
run8() { python3 -I "$src/report.py" --repo owner/repo --state "$state8" --worktrees "$tmp/worktrees/repo" 2>"$tmp/err8"; }
run8
owner7 "R01: go"
run8; rc8=$?
dump7
ok "S03-AC-8: with no graph.yaml the answer is still recorded" sh -c "[ $rc8 -eq 3 ] && grep -q '^R01: go\$' '$state8/node/R01/ANSWER.md'"
ok "S03-AC-8: with no graph.yaml the reply says it is recorded" nonempty "$(reply7 R01)"
ok "S03-AC-8: with no graph.yaml the reply claims no timing" lacks_seconds "$(reply7 R01)"
ok "S03-AC-8: with no graph.yaml the item exists and claims no timing" sh -c "[ -n \"\$1\" ] && ! printf '%s\n' \"\$1\" | grep -qi 'within seconds'" _ "$(item7 R01)"

# U01-AC-1, U01-AC-2, U01-AC-9: each unit's home issue and its milestones. Own database, own fake gh (it keeps issue
# labels, honours the label query, and fails a call on demand: $tmp/ufail holds a regex matched against
# "METHOD path title-or-first-body-line"), and a fixture clone whose origin/main has node specs with zero, one and two
# issues on their **Resolves:** line.
ubin=$tmp/ubin udb=$tmp/ugh.json uclone=$tmp/uclone
mkdir -p "$ubin" "$uclone/nodes"
python3 -I -c "
import json
issues = {str(n): {'number': n, 'title': 'Seeded %d' % n, 'body': '', 'labels': [], 'state': 'open', 'node_id': 'I_%d' % n} for n in range(41, 51)}
json.dump({'issues': issues, 'comments': [], 'labels': [], 'pulls': [], 'checks': {}, 'reactions': [], 'next': 200}, open('$udb', 'w'))"
cat >"$ubin/gh" <<EOF
#!/usr/bin/env python3
import json, os, re, sys
db = json.load(open("$udb"))
a = sys.argv[1:]
assert a[0] == "api" and a[1] == "-X", a
method, path = a[2], a[3]
body = json.load(sys.stdin) if "--input" in a else None
p = path.split("?")[0]
open("$tmp/ucalls", "a").write("%s %s\n" % (method, p))
mode = open("$tmp/ufail").read().strip() if os.path.exists("$tmp/ufail") else ""
desc = "%s %s" % (method, p)
if body and "title" in body: desc += " " + body["title"]
elif body and "body" in body: desc += " " + body["body"].split("\n")[0]
if mode and re.search(mode, desc):
    print("HTTP 502: injected failure for " + desc, file=sys.stderr); sys.exit(1)
out = None
if method == "POST" and p.endswith("/labels"):
    if body["name"] in db["labels"]:
        print("HTTP 422: already_exists", file=sys.stderr); sys.exit(1)
    db["labels"].append(body["name"]); out = {}
elif method == "POST" and p.endswith("/issues"):
    n = str(db["next"]); db["next"] += 1
    db["issues"][n] = dict(body, number=int(n), state="open", node_id="I_" + n)
    db["issues"][n].setdefault("labels", []); out = db["issues"][n]
elif method == "GET" and re.search(r"/issues\?labels=", path):
    lab = re.search(r"labels=([^&]+)", path).group(1)
    out = [i for i in db["issues"].values() if i["state"] == "open" and lab in i["labels"]]
elif re.search(r"/issues/\d+$", p):
    n = p.rsplit("/", 1)[1]
    if n not in db["issues"]:
        print("HTTP 404: no issue " + n, file=sys.stderr); sys.exit(1)
    if method == "PATCH": db["issues"][n].update(body)
    out = db["issues"][n]
elif method == "POST" and p.endswith("/comments"):
    n = p.split("/")[-2]
    c = {"id": len(db["comments"]) + 1, "issue": n, "body": body["body"], "user": {"login": "bot", "type": "Bot"},
         "author_association": "NONE", "created_at": "2026-02-01T00:00:00Z", "html_url": "https://x/%s/%d" % (n, len(db["comments"]) + 1)}
    db["comments"].append(c); out = c
elif method == "POST" and p.endswith("/reactions"):
    db["reactions"].append([p, body]); out = {}
elif method == "GET" and "/comments" in p:
    n = p.split("/")[-2]
    out = [c for c in db["comments"] if c["issue"] == n]
elif method == "GET" and re.search(r"/commits/[^/]+/check-runs$", p):
    out = {"check_runs": db["checks"].get(p.split("/")[-2], [])}
elif method == "GET" and p.endswith("/pulls"):
    out = db["pulls"]
elif p == "graphql":
    out = {}
else:
    print("unexpected " + method + " " + path, file=sys.stderr); sys.exit(1)
json.dump(db, open("$udb", "w"))
print(json.dumps(out))
EOF
chmod +x "$ubin/gh"
mkspec() { # <ID> <name> <resolves text or empty>
	{
		printf '# %s - %s\n\n| Track | Deps | Unlocks | Size |\n|---|---|---|---|\n| now | none | none | S |\n\n**Owns:** nothing\n' "$1" "$2"
		if [ -n "$3" ]; then printf '**Resolves:** %s\n' "$3"; fi
		printf '\n## Purpose\nx\n'
	} >"$uclone/nodes/$1-$2.md"
}
mkspec T01 zero-issues ''
mkspec T02 one-issue '#41'
mkspec T03 two-issues '#42, #43'
mkspec T05 zero-again ''
mkspec T06 six-one '#46'
mkspec T07 seven-one '#47'
mkspec T08 eight-one '#48'
mkspec T09 nine-one '#50'
git -C "$uclone" init -q -b main && git -C "$uclone" add nodes &&
	git -C "$uclone" -c user.name=t -c user.email=t@t commit -q -m specs &&
	git -C "$uclone" update-ref refs/remotes/origin/main HEAD
urun() { env PATH="$ubin:$PATH" python3 -I "$src/report.py" --repo owner/repo --state "$1" --worktrees "$tmp/worktrees/repo" --clone "$uclone" --owner owner 2>"$tmp/uerr"; }
uq() { python3 -I -c "import json,sys; db=json.load(open('$udb')); print(eval(sys.argv[1]))" "$1" 2>/dev/null; }
# ucount <issue> <regex>: the comments on the issue matching the regex (re.search, no flags; \A is the start of the body).
ucount() { P="$2" python3 -I -c "
import json, os, re
db = json.load(open('$udb'))
print(len([c for c in db['comments'] if c['issue'] == '$1' and re.search(os.environ['P'], c['body'])]))"; }
# ucontains <issue> <file>: the comments on the issue holding the file's whole text.
ucontains() { P=$(cat "$2") python3 -I -c "
import json, os
db = json.load(open('$udb'))
print(len([c for c in db['comments'] if c['issue'] == '$1' and os.environ['P'].strip() in c['body']]))"; }
unum() { ucount "$1" ''; }
ulast() { uq "[c['body'] for c in db['comments'] if c['issue'] == '$1'][-1]"; }
ufirst() { uq "[c['body'] for c in db['comments'] if c['issue'] == '$1'][0]"; }
ubuilds() { uq "len([i for i in db['issues'].values() if i['title'] == '$1'])"; }
ustage_all() { [ -n "$1" ] && [ "$(unum "$1")" -gt 0 ] && [ "$(unum "$1")" = "$(ucount "$1" '\A\*\*Stage:\*\*')" ]; }
uowner() {
	python3 -I -c "
import json, sys
db = json.load(open('$udb'))
db['comments'].append({'id': len(db['comments']) + 1, 'issue': sys.argv[1], 'body': sys.argv[2], 'user': {'login': 'owner', 'type': 'User'},
    'author_association': 'OWNER', 'created_at': '2026-02-02T00:00:00Z', 'html_url': 'https://x/u'})
json.dump(db, open('$udb', 'w'))" "$1" "$2"
}
ev() { echo "2026-02-01T00:00:00Z open=[] merged-prs=[]; $1" >>"$2/status.log"; }

ustate=$tmp/ustate
mkdir -p "$ustate/node/T01" "$ustate/node/T02" "$ustate/node/T03" "$ustate/issue/45"
: >"$ustate/status.log"
urun "$ustate"
ustatus=$(uq "[i['number'] for i in db['issues'].values() if 'noodlebot-status' in i['labels']][0]"); ustatus=${ustatus:-200}
ev "started T01 (zero-issues) in /wt, pid 1, start 1 of 2" "$ustate"
ev "started T02 (one-issue) in /wt, pid 2, start 1 of 2" "$ustate"
ev "started T03 (two-issues) in /wt, pid 3, start 1 of 2" "$ustate"
ev "started triage of #45 in /wt, pid 4, start 1 of 2" "$ustate"
ev "session T01 (pid 1) running, log 5 bytes" "$ustate"
ev "usage ok, nothing to do" "$ustate"
ev "stopped session T04 (pid 9)" "$ustate"
ev "released T04 (answered)" "$ustate"
ev "throttle hold: 5-hour window projected high" "$ustate"
urun "$ustate"; rc1=$?
urun "$ustate"; urun "$ustate"
build1=$(cat "$ustate/node/T01/issue" 2>/dev/null)
ok "U01-AC-1: the runs succeed" test "$rc1" = 0
ok "U01-AC-1: a triage's home issue is the issue it triages (issue/45/issue holds 45)" test "$(cat "$ustate/issue/45/issue" 2>/dev/null)" = 45
ok "U01-AC-1: a node with one Resolves issue has it as home (node/T02/issue holds 41)" test "$(cat "$ustate/node/T02/issue" 2>/dev/null)" = 41
ok "U01-AC-1: a node with two Resolves issues has the first as home (node/T03/issue holds 42)" test "$(cat "$ustate/node/T03/issue" 2>/dev/null)" = 42
ok "U01-AC-1: the other issue on the line is linked in the first milestone comment" sh -c "printf '%s\n' \"\$1\" | grep -qF '#43'" _ "$(ufirst 42)"
ok "U01-AC-1: a node with no Resolves line gets one Build issue, over three runs" test "$(ubuilds 'Build T01 zero-issues')" = 1
ok "U01-AC-1: the Build issue is labelled noodlebot-unit" test "$(uq "[i['labels'] for i in db['issues'].values() if i['title'] == 'Build T01 zero-issues'][0]")" = "['noodlebot-unit']"
ok "U01-AC-1: the Build issue is the node's home (node/T01/issue)" test -n "$build1" -a "$build1" = "$(uq "[i['number'] for i in db['issues'].values() if i['title'] == 'Build T01 zero-issues'][0]")"
ok "U01-AC-1: no Build issue for a node that has a Resolves issue" test "$(uq "len([i for i in db['issues'].values() if i['title'].startswith('Build T02') or i['title'].startswith('Build T03')])")" = 0
ok "U01-AC-2: a start is one comment on the node's home issue (one Resolves issue)" test "$(unum 41)" = 1
ok "U01-AC-2: a start is one comment on the home issue (two Resolves issues)" test "$(unum 42)" = 1
ok "U01-AC-2: a start is one comment on the Build issue" test "$(unum "$build1")" = 1
ok "U01-AC-2: a triage's start is one comment on the triaged issue" test "$(unum 45)" = 1
ok "U01-AC-2: each start comment begins with a Stage line" test "$(ucount 41 '\A\*\*Stage:\*\*')" = 1
ok "U01-AC-2: the start comment says its start count" test "$(ucount 41 '1 of 2')" = 1
ok "U01-AC-2: ticks, notes and other units' events add no other comment (all home issues, three runs)" test "$(unum 41)$(unum 42)$(unum 45)$(unum "$build1")" = "1111"
for i in 41 42 45 "$build1"; do ok "U01-AC-2: every comment on issue $i starts with a Stage line" ustage_all "$i"; done

printf 'Q1: which way?\nRecommendation: left.\nQ2: unique-t02-line\n' >"$ustate/node/T02/QUESTION.md"
printf 'Q1: triage question?\nq-unique-triage-line\n' >"$ustate/issue/45/QUESTION.md"
ev "session T02 ended (rc 0) with QUESTION.md" "$ustate"
ev "triage of #45 ended (rc 0) with QUESTION.md" "$ustate"
urun "$ustate"; urun "$ustate"; urun "$ustate"
ok "U01-AC-2: the question is one comment on the home issue holding the whole QUESTION.md, over three runs" test "$(ucontains 41 "$ustate/node/T02/QUESTION.md")" = 1
ok "U01-AC-2: the question comment begins with a Stage line" test "$(ucount 41 '\A\*\*Stage:\*\*(?s:.*)Q2: unique-t02-line')" = 1
ok "U01-AC-2: the question comment has the heading '## T02 asks'" test "$(ucount 41 '(?m)^## T02 asks$')" = 1
ok "U01-AC-2: the node's issue holds the start and the question, nothing else" test "$(unum 41)" = 2
ok "U01-AC-2: a triage's question is one comment on the triaged issue with the whole QUESTION.md" test "$(ucontains 45 "$ustate/issue/45/QUESTION.md")" = 1
ok "U01-AC-2: a triage's question has the heading '## #45 asks'" test "$(ucount 45 '(?m)^## #45 asks$')" = 1
ok "U01-AC-2: the triaged issue holds the start and the question, nothing else" test "$(unum 45)" = 2
for i in 41 45; do ok "U01-AC-2: every comment on issue $i starts with a Stage line (question)" ustage_all "$i"; done

uowner "$ustatus" "T02: go ahead"
urun "$ustate"; rc2=$?
urun "$ustate"; urun "$ustate"
ok "U01-AC-2: an answer on the status issue is recorded (exit 3)" sh -c "[ $rc2 = 3 ] && [ -e '$ustate/node/T02/ANSWER.md' ]"
ok "U01-AC-2: answer received is one comment on the home issue, over three runs" test "$(unum 41)" = 3
ok "U01-AC-2: the answer-received comment begins with a Stage line and is not the question" sh -c "printf '%s\n' \"\$1\" | head -n 1 | grep -q '^\*\*Stage:\*\*' && ! printf '%s\n' \"\$1\" | grep -q unique-t02-line" _ "$(ulast 41)"

rm "$ustate/node/T02/QUESTION.md" "$ustate/node/T02/ANSWER.md"; mkdir "$ustate/node/T02/answered"
ev "started T02 (one-issue) in /wt, pid 5, start 2 of 2" "$ustate"
urun "$ustate"; urun "$ustate"; urun "$ustate"
ok "U01-AC-2: a resume is one comment on the home issue, over three runs" test "$(unum 41)" = 4
ok "U01-AC-2: the resume comment begins with a Stage line, says resumed and its start count" sh -c "printf '%s\n' \"\$1\" | head -n 1 | grep -q '^\*\*Stage:\*\*' && printf '%s\n' \"\$1\" | grep -qi resum && printf '%s\n' \"\$1\" | grep -q '2 of 2'" _ "$(ulast 41)"
ok "U01-AC-2: the first start comment still says 1 of 2 and is not repeated" test "$(ucount 41 '1 of 2')" = 1

printf '2026-02-03T00:00:00Z 2 starts with no PR\nsecond-line-detail-two\n' >"$ustate/node/T03/FAILED"
ev "session T03 ended (rc 0), no PR, no QUESTION.md, 2 starts used: wrote FAILED" "$ustate"
urun "$ustate"; urun "$ustate"; urun "$ustate"
ok "U01-AC-2: FAILED is one comment on the home issue, over three runs" test "$(unum 42)" = 2
ok "U01-AC-2: the FAILED comment begins with a Stage line and holds the first line of FAILED, not the others" sh -c "printf '%s\n' \"\$1\" | head -n 1 | grep -q '^\*\*Stage:\*\*' && printf '%s\n' \"\$1\" | grep -qF '2 starts with no PR' && ! printf '%s\n' \"\$1\" | grep -q second-line-detail-two" _ "$(ulast 42)"
ok "U01-AC-2: the other homes got nothing from the FAILED event or the ticks" test "$(unum 41)$(unum 45)$(unum "$build1")" = "421"
ok "U01-AC-1: the recorded homes are kept after all the runs" test "$(cat "$ustate/node/T02/issue")$(cat "$ustate/node/T03/issue")$(cat "$ustate/issue/45/issue")$(cat "$ustate/node/T01/issue")" = "414245$build1"
ok "U01-AC-1: still one Build issue after all the runs" test "$(ubuilds 'Build T01 zero-issues')" = 1
for i in 41 42 45 "$build1"; do ok "U01-AC-2: every comment on issue $i starts with a Stage line (all milestones)" ustage_all "$i"; done

# U01-AC-9: a failed GitHub call while creating a Build issue or posting a milestone: logged, non-zero, retried once.
ustate2=$tmp/ustate2
mkdir -p "$ustate2/node/T05" "$ustate2/node/T06" "$ustate2/node/T07"
: >"$ustate2/status.log"
rm -f "$tmp/ufail"
urun "$ustate2"
ev "started T05 (zero-again) in /wt, pid 1, start 1 of 2" "$ustate2"
ev "started T06 (six-one) in /wt, pid 2, start 1 of 2" "$ustate2"
echo '/issues Build T05' >"$tmp/ufail"
urun "$ustate2"; rcb=$?
ok "U01-AC-9: a failing Build issue creation exits non-zero" test "$rcb" != 0
ok "U01-AC-9: and logs the error on stderr" test -s "$tmp/uerr"
ok "U01-AC-9: and no Build issue exists yet" test "$(ubuilds 'Build T05 zero-again')" = 0
rm -f "$tmp/ufail"
urun "$ustate2"; rcb2=$?
urun "$ustate2"
ok "U01-AC-9: the next run succeeds and creates the Build issue once" sh -c "[ $rcb2 = 0 ] && [ \"\$1\" = 1 ]" _ "$(ubuilds 'Build T05 zero-again')"
b5=$(cat "$ustate2/node/T05/issue" 2>/dev/null)
ok "U01-AC-9: its start milestone is posted once, over the runs" test "$(unum "$b5")" = 1
ok "U01-AC-9: the other node's start milestone is posted once, over the runs" test "$(unum 46)" = 1

printf 'Q1: retry me?\nretry-unique-line\n' >"$ustate2/node/T06/QUESTION.md"
ev "session T06 ended (rc 0) with QUESTION.md" "$ustate2"
echo 'issues/46/comments' >"$tmp/ufail"
urun "$ustate2"; rcq=$?
ok "U01-AC-9: a failing question post exits non-zero with the error on stderr" sh -c "[ $rcq != 0 ] && [ -s '$tmp/uerr' ]"
ok "U01-AC-9: the question is not on the issue yet" test "$(ucontains 46 "$ustate2/node/T06/QUESTION.md")" = 0
rm -f "$tmp/ufail"
urun "$ustate2"; rcq2=$?
urun "$ustate2"
ok "U01-AC-9: the next run posts the question once" sh -c "[ $rcq2 = 0 ] && [ \"\$1\" = 1 ]" _ "$(ucontains 46 "$ustate2/node/T06/QUESTION.md")"

ev "started T07 (seven-one) in /wt, pid 3, start 1 of 2" "$ustate2"
echo 'issues/47/comments' >"$tmp/ufail"
urun "$ustate2"; rcm=$?
ok "U01-AC-9: a failing start post exits non-zero with the error on stderr" sh -c "[ $rcm != 0 ] && [ -s '$tmp/uerr' ]"
ok "U01-AC-9: the start milestone is not on the issue yet" test "$(unum 47)" = 0
rm -f "$tmp/ufail"
urun "$ustate2"; rcm2=$?
urun "$ustate2"; urun "$ustate2"
ok "U01-AC-9: the next run posts the start once, over three runs" sh -c "[ $rcm2 = 0 ] && [ \"\$1\" = 1 ]" _ "$(unum 47)"

# U01-AC-9: the first run after the change, from a report.json of the old version, posts no milestone for what came before.
ustate3=$tmp/ustate3
mkdir -p "$ustate3/node/T08" "$ustate3/node/T09"
ev "started T08 (eight-one) in /wt, pid 1, start 1 of 2" "$ustate3"
ev "session T08 ended (rc 0) with QUESTION.md" "$ustate3"
printf 'Q1: from before?\nbefore-unique-line\n' >"$ustate3/node/T08/QUESTION.md"
qkey=$(stat -c %Y "$ustate3/node/T08/QUESTION.md")
maxid=$(uq "max([c['id'] for c in db['comments']] or [0])")
printf '{"issue": %s, "comment_id": %s, "log_offset": %s, "questions": {"T08": "%s"}, "body_hash": "x", "body_time": 0}\n' \
	"$ustatus" "$maxid" "$(wc -c <"$ustate3/status.log")" "$qkey" >"$ustate3/report.json"
python3 -I -c "
import json
db = json.load(open('$udb'))
db['pulls'] = [{'number': 9, 'head': {'ref': 'node/T08-eight-one', 'sha': 'abc123'}}]
db['checks'] = {'abc123': [{'name': 'test', 'status': 'completed', 'conclusion': 'failure'}]}
db['comments'].append({'id': len(db['comments']) + 1, 'issue': '9', 'body': 'Fresh review (approve)\nfine', 'user': {'login': 'bot', 'type': 'Bot'},
    'author_association': 'NONE', 'created_at': '2026-01-01T00:00:00Z', 'html_url': 'u'})
json.dump(db, open('$udb', 'w'))"
urun "$ustate3"; rc3=$?
urun "$ustate3"
ok "U01-AC-9: the first run after the change succeeds" test "$rc3" = 0
ok "U01-AC-9: it posts no milestone for a start, a question or an open PR from before (nothing on #48)" test "$(unum 48)" = 0
ok "U01-AC-9: and nothing on the PR (its one earlier comment only)" test "$(unum 9)" = 1
ev "started T09 (nine-one) in /wt, pid 2, start 1 of 2" "$ustate3"
urun "$ustate3"
ok "U01-AC-9: a start after the change is posted on its home issue" test "$(unum 50)" = 1
rm -f "$tmp/ufail"

# U01-AC-4, U01-AC-5, U01-AC-7: answers on home issues, answers on the status issue, the status issue linking questions.
python3 -I -c "
import json
db = json.load(open('$udb'))
for n in range(51, 55):
    db['issues'][str(n)] = {'number': n, 'title': 'Seeded %d' % n, 'body': '', 'labels': [], 'state': 'open', 'node_id': 'I_%d' % n}
json.dump(db, open('$udb', 'w'))"
mkspec V04 share-a '#51'
mkspec V05 share-b '#51'
mkspec V06 share-triage '#52'
git -C "$uclone" add nodes && git -C "$uclone" -c user.name=t -c user.email=t@t commit -q -m specs2 &&
	git -C "$uclone" update-ref refs/remotes/origin/main HEAD
# ubcount <issue> <regex>: the comments by the bot (not the owner or others) on the issue matching the regex.
ubcount() { P="$2" python3 -I -c "
import json, os, re
db = json.load(open('$udb'))
print(len([c for c in db['comments'] if c['issue'] == '$1' and c['user']['login'] == 'bot' and re.search(os.environ['P'], c['body'])]))"; }
ubn() { ubcount "$1" ''; }
# ucomment <issue> <body> <created_at> <login> <association> <type> <url>: a comment by anyone.
ucomment() {
	python3 -I -c "
import json, sys
db = json.load(open('$udb'))
db['comments'].append({'id': len(db['comments']) + 1, 'issue': sys.argv[1], 'body': sys.argv[2], 'user': {'login': sys.argv[4], 'type': sys.argv[6]},
    'author_association': sys.argv[5], 'created_at': sys.argv[3], 'html_url': sys.argv[7]})
json.dump(db, open('$udb', 'w'))" "$@"
}
# ureact <url>: the +1 reactions on the comment with that URL.
ureact() { uq "len([r for r in db['reactions'] if r[0].endswith('/issues/comments/%d/reactions' % [c['id'] for c in db['comments'] if c['html_url'] == '$1'][0]) and r[1].get('content') == '+1'])"; }
uowned() { # <issue> <body> <url>: the owner's comment, after every question
	ucomment "$1" "$2" 2026-02-02T00:00:00Z owner OWNER User "$3"
}

ustate4=$tmp/ustate4
mkdir -p "$ustate4/node/V01" "$ustate4/node/V02" "$ustate4/node/V04" "$ustate4/node/V05" "$ustate4/node/V06" "$ustate4/issue/52" \
	"$ustate4/node/V07" "$ustate4/node/V08" "$ustate4/node/V09" "$ustate4/issue/53"
: >"$ustate4/status.log"
rm -f "$tmp/ufail"
urun "$ustate4"
printf 'Q1: which way?\nv01-unique-q-line\n' >"$ustate4/node/V01/QUESTION.md"
ev "session V01 ended (rc 0) with QUESTION.md" "$ustate4"
urun "$ustate4"; urun "$ustate4"
h1=$(cat "$ustate4/node/V01/issue" 2>/dev/null)
ucomment "$h1" "early answer" 2026-01-15T00:00:00Z owner OWNER User https://x/v01-early
ucomment "$h1" "stranger answer" 2026-02-02T00:00:00Z mallory NONE User https://x/v01-other
ucomment "$h1" "member answer" 2026-02-02T00:00:00Z owner MEMBER User https://x/v01-member
ucomment "$h1" "bot answer" 2026-02-02T00:00:00Z owner OWNER Bot https://x/v01-bot
urun "$ustate4"; urun "$ustate4"; rcv=$?
ok "U01-AC-4: a comment from before the question, or by someone else (login, association, Bot), is not recorded" test -n "$h1" -a ! -e "$ustate4/node/V01/ANSWER.md"
ok "U01-AC-4: and gets no reply and no reaction (the home issue holds only the question)" sh -c "[ \"\$1\" = 1 ] && [ \"\$2\" = 0 ]" _ "$(ubn "$h1")" "$(uq "len(db['reactions'])")"
uowned "$h1" "go left" https://x/v01-own
urun "$ustate4"; rcv=$?
urun "$ustate4"; urun "$ustate4"
ok "U01-AC-4: an owner comment after the question becomes ANSWER.md without an ID prefix, exit 3" sh -c "[ $rcv = 3 ] && grep -q '^go left\$' '$ustate4/node/V01/ANSWER.md'"
ok "U01-AC-4: ANSWER.md carries the comment's URL" grep -qF 'https://x/v01-own' "$ustate4/node/V01/ANSWER.md"
ok "U01-AC-4: the comment gets one +1 reaction over three runs" test "$(ureact https://x/v01-own)" = 1
ok "U01-AC-4: and nothing else gets a reaction" test "$(uq "len(db['reactions'])")" = 1
ok "U01-AC-4: the answer-received milestone is one comment (with the URL), and there is no other reply" sh -c "[ \"\$1\" = 1 ] && [ \"\$2\" = 2 ]" _ "$(ubcount "$h1" 'https://x/v01-own')" "$(ubn "$h1")"
ok "U01-AC-4: the answer-received milestone begins with a Stage line" test "$(ubcount "$h1" '\A\*\*Stage:\*\*(?s:.*)https://x/v01-own')" = 1

ev "started V02 (no-question) in /wt, pid 1, start 1 of 2" "$ustate4"
urun "$ustate4"
h2=$(cat "$ustate4/node/V02/issue" 2>/dev/null)
uowned "$h2" "answer to nothing" https://x/v02-own
urun "$ustate4"; urun "$ustate4"; urun "$ustate4"
ok "U01-AC-4: with no question open, an owner comment is not recorded" test -n "$h2" -a ! -e "$ustate4/node/V02/ANSWER.md"
ok "U01-AC-4: and gets exactly one reply saying so (start + one reply), over three runs" sh -c "[ \"\$1\" = 2 ] && [ \"\$2\" = 1 ]" _ "$(ubn "$h2")" "$(ubcount "$h2" '\A(?!\*\*Stage:)(?i:(?s:.*)(not recorded|no question|not waiting|nothing))')"
ok "U01-AC-4: and gets no reaction" test "$(ureact https://x/v02-own)" = 0

printf 'Q1: share a?\nv04-unique-q-line\n' >"$ustate4/node/V04/QUESTION.md"
printf 'Q1: share b?\nv05-unique-q-line\n' >"$ustate4/node/V05/QUESTION.md"
ev "session V04 ended (rc 0) with QUESTION.md" "$ustate4"
ev "session V05 ended (rc 0) with QUESTION.md" "$ustate4"
urun "$ustate4"; urun "$ustate4"
uowned 51 "approve" https://x/share-plain
urun "$ustate4"; urun "$ustate4"; urun "$ustate4"
ok "U01-AC-4: two units share issue 51 (the first Resolves issue)" test "$(cat "$ustate4/node/V04/issue" 2>/dev/null)$(cat "$ustate4/node/V05/issue" 2>/dev/null)" = 5151
ok "U01-AC-4: two waiting units: an unprefixed comment is not recorded for either" sh -c "[ ! -e '$ustate4/node/V04/ANSWER.md' ] && [ ! -e '$ustate4/node/V05/ANSWER.md' ]"
ok "U01-AC-4: and gets one reply naming both units, over three runs" test "$(ubcount 51 '\A(?!\*\*Stage:)(?s:.*V04.*V05|.*V05.*V04)')" = 1
ok "U01-AC-4: and no reaction" test "$(ureact https://x/share-plain)" = 0
uowned 51 "V05: yes" https://x/share-v05
urun "$ustate4"; rcs=$?
urun "$ustate4"; urun "$ustate4"
ok "U01-AC-4: a comment starting with an ID is that unit's answer (V05), exit 3" sh -c "[ $rcs = 3 ] && grep -q '^V05: yes\$' '$ustate4/node/V05/ANSWER.md' && [ ! -e '$ustate4/node/V04/ANSWER.md' ]"
ok "U01-AC-4: it gets one +1 reaction and the URL in ANSWER.md" sh -c "[ \"\$1\" = 1 ] && grep -qF https://x/share-v05 '$ustate4/node/V05/ANSWER.md'" _ "$(ureact https://x/share-v05)"
ok "U01-AC-4: no second reply was posted (2 questions, 1 reply, 1 answer milestone)" test "$(ubn 51)" = 4

printf 'Q1: triage shared?\nt52-unique-q-line\n' >"$ustate4/issue/52/QUESTION.md"
printf 'Q1: node shared?\nv06-unique-q-line\n' >"$ustate4/node/V06/QUESTION.md"
ev "triage of #52 ended (rc 0) with QUESTION.md" "$ustate4"
ev "session V06 ended (rc 0) with QUESTION.md" "$ustate4"
urun "$ustate4"; urun "$ustate4"
uowned 52 "looks fine" https://x/tri-plain
urun "$ustate4"; urun "$ustate4"
ok "U01-AC-4: a triage of 52 and a node resolving 52: an unprefixed comment is not recorded" sh -c "[ ! -e '$ustate4/issue/52/ANSWER.md' ] && [ ! -e '$ustate4/node/V06/ANSWER.md' ]"
ok "U01-AC-4: and gets one reply naming both, over repeated runs" test "$(ubcount 52 '\A(?!\*\*Stage:)(?s:.*V06.*#52|.*#52.*V06)')" = 1
uowned 52 "**V06**: go" https://x/tri-v06
urun "$ustate4"; rct=$?
urun "$ustate4"
ok "U01-AC-4: a comment starting with **V06** is V06's answer and not the triage's, exit 3" sh -c "[ $rct = 3 ] && grep -qF '**V06**: go' '$ustate4/node/V06/ANSWER.md' && [ ! -e '$ustate4/issue/52/ANSWER.md' ]"
ok "U01-AC-4: it gets one +1 reaction" test "$(ureact https://x/tri-v06)" = 1

# U01-AC-5
printf 'Q1: status first?\n' >"$ustate4/node/V07/QUESTION.md"
printf 'Q1: home first?\n' >"$ustate4/node/V08/QUESTION.md"
ev "session V07 ended (rc 0) with QUESTION.md" "$ustate4"
ev "session V08 ended (rc 0) with QUESTION.md" "$ustate4"
urun "$ustate4"; urun "$ustate4"
h7=$(cat "$ustate4/node/V07/issue" 2>/dev/null); h8=$(cat "$ustate4/node/V08/issue" 2>/dev/null)
uowner "$ustatus" "V07: via status"
urun "$ustate4"; rc7=$?
cp "$ustate4/node/V07/ANSWER.md" "$tmp/v07.answer" 2>/dev/null
ok "U01-AC-5: a prefixed answer on the status issue is still recorded (exit 3)" sh -c "[ $rc7 = 3 ] && grep -q '^V07: via status\$' '$ustate4/node/V07/ANSWER.md'"
uowned "$h7" "later on home" https://x/v07-later
urun "$ustate4"; urun "$ustate4"
ok "U01-AC-5: answered on the status issue, a later comment on the home issue is not recorded" sh -c "cmp -s '$tmp/v07.answer' '$ustate4/node/V07/ANSWER.md' && ! grep -q 'later on home' '$ustate4/node/V07/ANSWER.md'"
uowned "$h8" "home answer" https://x/v08-home
urun "$ustate4"; rc8h=$?
cp "$ustate4/node/V08/ANSWER.md" "$tmp/v08.answer" 2>/dev/null
uowner "$ustatus" "V08: later on status"
urun "$ustate4"; urun "$ustate4"
ok "U01-AC-5: answered on the home issue (exit 3), a later prefixed comment on the status issue is not written over ANSWER.md" sh -c "[ $rc8h = 3 ] && cmp -s '$tmp/v08.answer' '$ustate4/node/V08/ANSWER.md' && grep -q '^home answer\$' '$ustate4/node/V08/ANSWER.md'"

# U01-AC-7
printf 'Q1: status link?\nv09-unique-q-line\n' >"$ustate4/node/V09/QUESTION.md"
printf 'Q1: triage link?\nt53-unique-q-line\n' >"$ustate4/issue/53/QUESTION.md"
ev "session V09 ended (rc 0) with QUESTION.md" "$ustate4"
ev "triage of #53 ended (rc 0) with QUESTION.md" "$ustate4"
urun "$ustate4"; urun "$ustate4"
h9=$(cat "$ustate4/node/V09/issue" 2>/dev/null)
sbody=$(uq "db['issues']['$ustatus']['body']")
url9=$(uq "[c['html_url'] for c in db['comments'] if c['issue'] == '$h9' and '## V09 asks' in c['body']][0]")
url53=$(uq "[c['html_url'] for c in db['comments'] if c['issue'] == '53' and '## #53 asks' in c['body']][0]")
ok "U01-AC-7: the node's question is on its home issue (precondition)" test -n "$url9" -a -n "$h9"
ok "U01-AC-7: the status issue has no comment with the node's QUESTION.md in full (nor its text)" test "$(ucontains "$ustatus" "$ustate4/node/V09/QUESTION.md")$(ucount "$ustatus" 'v09-unique-q-line')" = 00
ok "U01-AC-7: nor the triage's" test "$(ucontains "$ustatus" "$ustate4/issue/53/QUESTION.md")$(ucount "$ustatus" 't53-unique-q-line')" = 00
ok "U01-AC-7: nor any earlier question (T02, V01)" test "$(ucount "$ustatus" 'unique-t02-line|v01-unique-q-line|v04-unique-q-line')" = 0
ok "U01-AC-7: the Waiting on you item for the node's question links its comment on the home issue" sh -c "printf '%s\n' \"\$1\" | grep V09 | grep -qF \"\$2\"" _ "$sbody" "$url9"
ok "U01-AC-7: the item for the triage's question links its comment on the triaged issue" sh -c "printf '%s\n' \"\$1\" | grep '#53' | grep -qF \"\$2\"" _ "$sbody" "$url53"
ok "U01-AC-7: the status issue's events are still posted (session V09 ended, once)" test "$(ucount "$ustatus" 'session V09 ended')" = 1
ok "U01-AC-7: the footer says to answer on the unit's issue" sh -c "printf '%s\n' \"\$1\" | grep -qi \"unit's issue\"" _ "$sbody"
ok "U01-AC-7: the footer says a prefixed reply on the status issue still works" sh -c "printf '%s\n' \"\$1\" | grep -qi 'prefix'" _ "$sbody"
rm -f "$tmp/ufail"

# U01-AC-3, U01-AC-6: the PR milestones on a node's home issue, a triage's done, and the loop closing (and reopening) the
# issues a merged node resolves.
python3 -I -c "
import json
db = json.load(open('$udb'))
for n in range(55, 71):
    db['issues'][str(n)] = {'number': n, 'title': 'Seeded %d' % n, 'body': '', 'labels': [], 'state': 'open', 'node_id': 'I_%d' % n}
json.dump(db, open('$udb', 'w'))"
mkspec W01 pr-one '#55'
mkspec W02 pr-two '#55'
mkspec W03 closer '#56'
mkspec X01 solo '#58'
mkspec X02 pair '#59, #60'
mkspec X03 build-me ''
mkspec X06 asks '#62'
mkspec X07 follows '#63'
git -C "$uclone" add nodes && git -C "$uclone" -c user.name=t -c user.email=t@t commit -q -m specs3 &&
	git -C "$uclone" update-ref refs/remotes/origin/main HEAD
# usetpulls <json list>: the open PRs the fake lists. usetchecks <sha> <json list>: the check runs of that head commit.
usetpulls() { python3 -I -c "
import json, sys
db = json.load(open('$udb')); db['pulls'] = json.loads(sys.argv[1]); json.dump(db, open('$udb', 'w'))" "$1"; }
usetchecks() { python3 -I -c "
import json, sys
db = json.load(open('$udb')); db['checks'][sys.argv[1]] = json.loads(sys.argv[2]); json.dump(db, open('$udb', 'w'))" "$1" "$2"; }
upull() { # <number> <branch> <sha>: one open PR as JSON
	printf '{"number": %s, "html_url": "https://github.com/owner/repo/pull/%s", "state": "open", "head": {"ref": "%s", "sha": "%s"}}' "$1" "$1" "$2" "$3"
}
ustateof() { uq "db['issues']['$1']['state']"; }
# umatch <regex> <text>: re.search (flags inline) of the text; used on the last comment of an issue.
umatch() { P="$1" python3 -I -c "
import os, re, sys
sys.exit(0 if re.search(os.environ['P'], sys.argv[1]) else 1)" "$2"; }
ur3() { urun "$ustate5"; urun "$ustate5"; urun "$ustate5"; }
# self-check of the patterns used below against the text they are meant to match
ok "U01-AC-3: (self-check) the Stage pattern matches a stage line" umatch '\A\*\*Stage:\*\*' '**Stage:** PR #312 open, final review running'
ok "U01-AC-3: (self-check) the PR-naming pattern matches '#312' and a pull URL" sh -c "P='(#|pull/)312\\b'; python3 -I -c \"import re,sys; sys.exit(0 if re.search(sys.argv[1], '#312') and re.search(sys.argv[1], 'https://github.com/owner/repo/pull/312.') and not re.search(sys.argv[1], '#3120') else 1)\" \"\$P\""

ustate5=$tmp/ustate5
mkdir -p "$ustate5/node/W01" "$ustate5/node/W02" "$ustate5/node/W03" "$ustate5/issue/57" "$ustate5/issue/69" \
	"$ustate5/node/X01" "$ustate5/node/X02" "$ustate5/node/X03" "$ustate5/node/X06" "$ustate5/node/X07"
: >"$ustate5/status.log"
rm -f "$tmp/ufail"
usetpulls '[]'
urun "$ustate5"
ev "started W01 (pr-one) in /wt, pid 1, start 1 of 2" "$ustate5"
ev "started W03 (closer) in /wt, pid 2, start 1 of 2" "$ustate5"
ur3
ok "U01-AC-3: (precondition) W01's start is the one comment on its home issue (55)" test "$(unum 55)" = 1
ok "U01-AC-3: (precondition) W03's start is the one comment on its home issue (56)" test "$(unum 56)" = 1

# the PR opened, with its link, once; no CI result while a check run is still running
usetchecks s1 '[{"name": "test", "status": "completed", "conclusion": "success"}, {"name": "build", "status": "in_progress", "conclusion": null}]'
usetpulls "[$(upull 312 node/W01-pr-one s1), $(upull 314 node/W03-closer s3)]"
usetchecks s3 '[{"name": "test", "status": "completed", "conclusion": "success"}]'
ur3
ok "U01-AC-3: the PR opened is one comment on the home issue, over three runs (CI still running adds none)" test "$(unum 55)" = 2
ok "U01-AC-3: the PR-opened comment has the PR's link" test "$(ucount 55 'github\.com/owner/repo/pull/312\b')" = 1
ok "U01-AC-3: the PR-opened comment begins with a Stage line" test "$(ucount 55 '\A\*\*Stage:\*\*(?s:.*)pull/312\b')" = 1
ok "U01-AC-3: the other node's PR opened is on its own home issue (56), with its CI result (all check runs complete)" test "$(ucount 56 'pull/314\b')" = 1 -a "$(unum 56)" = 3

# the CI result once all check runs are complete: passed
usetchecks s1 '[{"name": "test", "status": "completed", "conclusion": "success"}, {"name": "build", "status": "completed", "conclusion": "success"}]'
ur3
ok "U01-AC-3: the CI result is posted once all check runs are complete, once over three runs" test "$(unum 55)" = 3
ok "U01-AC-3: it says the checks passed and begins with a Stage line" umatch '(?is)\A\*\*Stage:\*\*.*(pass|success|green)' "$(ulast 55)"
ok "U01-AC-3: the other node's CI result says passed" test "$(ucount 56 '(?is)\A\*\*Stage:\*\*.*(pass|success|green)')" = 1

# a new head commit: one more CI result, with the failing checks' names, after all its check runs complete
usetchecks s2 '[{"name": "test", "status": "completed", "conclusion": "success"}, {"name": "lint", "status": "completed", "conclusion": "failure"}, {"name": "unit", "status": "queued", "conclusion": null}]'
usetpulls "[$(upull 312 node/W01-pr-one s2), $(upull 314 node/W03-closer s3)]"
ur3
ok "U01-AC-3: a new head commit with a check run still queued adds no CI result" test "$(unum 55)" = 3
usetchecks s2 '[{"name": "test", "status": "completed", "conclusion": "success"}, {"name": "lint", "status": "completed", "conclusion": "failure"}, {"name": "unit", "status": "completed", "conclusion": "failure"}]'
ur3
ok "U01-AC-3: once the new head's check runs are complete its CI result is posted once (a CI result per head commit)" test "$(unum 55)" = 4
ok "U01-AC-3: the failed CI result names the failing checks (lint, unit)" sh -c "printf '%s\n' \"\$1\" | grep -q 'lint' && printf '%s\n' \"\$1\" | grep -q 'unit' && printf '%s\n' \"\$1\" | head -n 1 | grep -q '^\*\*Stage:\*\*'" _ "$(ulast 55)"
ok "U01-AC-3: the earlier head's CI result is not repeated" test "$(ucount 55 '(?is)\A\*\*Stage:\*\*.*(pass|success|green)')" = 1

# each Fresh review verdict once
ucomment 312 $'Fresh review (approve)\nlooks fine' 2026-02-03T00:00:00Z bot NONE Bot https://x/312/1
ucomment 312 $'Thanks, will look later' 2026-02-03T00:01:00Z owner OWNER User https://x/312/2
ur3
ok "U01-AC-3: a Fresh review (approve) PR comment gives one milestone with its verdict, once over three runs" test "$(unum 55)" = 5 -a "$(ucount 55 '(?i)approve')" = 1
ok "U01-AC-3: another PR comment adds nothing (the owner's thanks)" test "$(ucount 55 'Thanks, will look later|will look later')" = 0
ucomment 312 $'Fresh review (request_changes)\nthe lint failure' 2026-02-03T00:02:00Z bot NONE Bot https://x/312/3
ur3
ok "U01-AC-3: a second Fresh review (request_changes) gives one more milestone with its verdict, once" test "$(unum 55)" = 6 -a "$(ucount 55 '(?i)request.changes')" = 1
ok "U01-AC-3: the verdict milestone begins with a Stage line" umatch '(?is)\A\*\*Stage:\*\*.*request.changes' "$(ulast 55)"
ok "U01-AC-3: every milestone comment on W01's home issue begins with a Stage line" ustage_all 55
ok "U01-AC-3: every milestone comment on W03's home issue begins with a Stage line" ustage_all 56

# merged once (the issue is also on W02's Resolves line, so it stays open: no closing comment mixes in)
usetpulls "[$(upull 314 node/W03-closer s3)]"
echo "312 node/W01-pr-one" >"$ustate5/merged-prs.tsv"
echo "312 node/W01-pr-one 2026-02-04T00:00:00Z true" >"$ustate5/closed-prs.tsv"
ur3
ok "U01-AC-3: a merged PR gives one merged milestone naming the PR, once over three runs" test "$(unum 55)" = 7 -a "$(ucount 55 '(?i)merged')" -ge 1
ok "U01-AC-3: the merged milestone names the PR and begins with a Stage line" umatch '(?is)\A\*\*Stage:\*\*.*(#|pull/)312\b' "$(ulast 55)"
ok "U01-AC-3: a merged PR is not reported as closed without merging" test "$(ucount 55 '(?i)closed without')" = 0
ok "U01-AC-6: the issue stays open while another node resolving it (W02) is not merged" test "$(ustateof 55)" = open

# closed without merging once (the issue is not closed: the node is not merged)
usetpulls '[]'
echo "314 node/W03-closer 2026-02-04T00:00:00Z false" >>"$ustate5/closed-prs.tsv"
ur3
ok "U01-AC-3: a PR closed without merging gives one milestone, once over three runs" test "$(unum 56)" = 4
ok "U01-AC-3: the closed milestone says closed and names the PR, with a Stage line" umatch '(?is)\A\*\*Stage:\*\*.*clos.*' "$(ulast 56)"
ok "U01-AC-3: and names the PR number" umatch '(#|pull/)314\b' "$(ulast 56)"
ok "U01-AC-6: a PR closed without merging does not close its home issue" test "$(ustateof 56)" = open

# a triage that ends done: done once, with its spec PR when there is one
ev "started triage of #57 in /wt, pid 9, start 1 of 2" "$ustate5"
ev "started triage of #69 in /wt, pid 10, start 1 of 2" "$ustate5"
ur3
usetpulls "[$(upull 320 spec/triage-57-foo s9)]"
ev "triage of #57 done (rc 0); its label is now noodlebot-triaged" "$ustate5"
ev "triage of #69 done (rc 0); its label is now noodlebot-triaged" "$ustate5"
ur3
ok "U01-AC-3: a triage that ends done posts done once, with its spec PR (over three runs)" test "$(ucount 57 '(?is)\A(?=.*pull/320\b)(?=.*\bdone\b)')" = 1
ok "U01-AC-3: that comment begins with a Stage line" test "$(ucount 57 '(?is)\A\*\*Stage:\*\*(?=.*pull/320\b)(?=.*\bdone\b)')" = 1
ok "U01-AC-3: a triage that ends done with no spec PR posts done once, without a PR link" test "$(ucount 69 '(?i)\bdone\b')" = 1 -a "$(ucount 69 'pull/')" = 0
ok "U01-AC-3: its comment begins with a Stage line" test "$(ucount 69 '(?is)\A\*\*Stage:\*\*(?=.*\bdone\b)')" = 1
ok "U01-AC-6: a triage never closes its issue (57 and 69 stay open, nothing else closes them)" test "$(ustateof 57)$(ustateof 69)" = openopen
usetpulls '[]'

# U01-AC-6: closing. A node's last issue closes after the merge, with one comment naming the PR.
# The shared issue (55): W02 merged too -> closed at the first run after that holds.
echo "313 node/W02-pr-two" >>"$ustate5/merged-prs.tsv"
urun "$ustate5"
ok "U01-AC-6: when the last node resolving the issue is merged, the next run closes it" test "$(ustateof 55)" = closed
ok "U01-AC-6: and the closing comment names the merged PR (313)" test "$(ucount 55 '(#|pull/)313\b')" -ge 1
n55=$(unum 55)
urun "$ustate5"; urun "$ustate5"
ok "U01-AC-6: the close is not repeated (no further comment, still closed)" test "$(unum 55)" = "$n55" -a "$(ustateof 55)" = closed

# a node with one Resolves issue
ev "started X01 (solo) in /wt, pid 3, start 1 of 2" "$ustate5"
ev "started X02 (pair) in /wt, pid 4, start 1 of 2" "$ustate5"
ev "started X03 (build-me) in /wt, pid 5, start 1 of 2" "$ustate5"
ev "started X06 (asks) in /wt, pid 6, start 1 of 2" "$ustate5"
ev "started X07 (follows) in /wt, pid 7, start 1 of 2" "$ustate5"
ur3
xb=$(cat "$ustate5/node/X03/issue" 2>/dev/null)
ok "U01-AC-6: (precondition) the homes exist and are open before any merge" test "$(ustateof 58)$(ustateof 59)$(ustateof 60)" = openopenopen -a -n "$xb" -a "$(ustateof "${xb:-0}")" = open
printf 'Q1: hold the issue?\nx06-unique-q-line\n' >"$ustate5/node/X06/QUESTION.md"
ev "session X06 ended (rc 0) with QUESTION.md" "$ustate5"
mkdir "$ustate5/node/X07/answered"
echo node/X07-followup-1 >"$ustate5/node/X07/FOLLOWUP"
ur3
ok "U01-AC-6: (precondition) X06's question is posted on its home issue" test "$(ucontains 62 "$ustate5/node/X06/QUESTION.md")" = 1
printf '%s\n' "331 node/X01-solo" "332 node/X02-pair" "333 node/X03-build-me" "336 node/X06-asks" "337 node/X07-follows" >>"$ustate5/merged-prs.tsv"
urun "$ustate5"
ok "U01-AC-6: a merged node's home issue (the only Resolves issue) is closed" test "$(ustateof 58)" = closed
ok "U01-AC-6: it has a comment naming the merged PR (331)" test "$(ucount 58 '(#|pull/)331\b')" -ge 1
ok "U01-AC-6: both issues on a Resolves line are closed (home 59)" test "$(ustateof 59)" = closed
ok "U01-AC-6: and the other issue on the line (60)" test "$(ustateof 60)" = closed
ok "U01-AC-6: each of them has a comment naming the PR (332)" test "$(ucount 59 '(#|pull/)332\b')" -ge 1 -a "$(ucount 60 '(#|pull/)332\b')" -ge 1
ok "U01-AC-6: a merged node's Build issue is closed" test "$(ustateof "${xb:-0}")" = closed
ok "U01-AC-6: and has a comment naming the PR (333)" test "$(ucount "${xb:-0}" '(#|pull/)333\b')" -ge 1
ok "U01-AC-6: an issue whose unit has an open question stays open" test "$(ustateof 62)" = open
ok "U01-AC-6: an issue whose unit has a follow-up in progress (FOLLOWUP marker) stays open" test "$(ustateof 63)" = open
urun "$ustate5"; urun "$ustate5"
c58=$(ucount 58 '(#|pull/)331\b')
ok "U01-AC-6: over more runs the held issues stay open and the closed ones get no further comments" test "$(ustateof 62)$(ustateof 63)" = openopen -a "$(ucount 58 '(#|pull/)331\b')" = "$c58" -a "$(ucount 60 '(#|pull/)332\b')" = 1

# the question is answered but not released: still held
echo "Q1: go" >"$ustate5/node/X06/ANSWER.md"
urun "$ustate5"
ok "U01-AC-6: an answered question not yet released (QUESTION.md and ANSWER.md both there) still holds the issue open" test "$(ustateof 62)" = open
# released: QUESTION.md and ANSWER.md moved into answered/
mkdir "$ustate5/node/X06/answered" && rm "$ustate5/node/X06/QUESTION.md" "$ustate5/node/X06/ANSWER.md"
urun "$ustate5"
ok "U01-AC-6: once the answer is released, the first run after closes the issue" test "$(ustateof 62)" = closed
ok "U01-AC-6: with a comment naming the PR (336)" test "$(ucount 62 '(#|pull/)336\b')" -ge 1
# follow-up done: FOLLOWUP marker moved into answered/
mv "$ustate5/node/X07/FOLLOWUP" "$ustate5/node/X07/answered/FOLLOWUP"
urun "$ustate5"
ok "U01-AC-6: once the follow-up is done (no FOLLOWUP marker), the first run after closes the issue" test "$(ustateof 63)" = closed
ok "U01-AC-6: with a comment naming the PR (337)" test "$(ucount 63 '(#|pull/)337\b')" -ge 1

# a new QUESTION.md of a unit whose home issue is closed reopens the issue and posts the question there
printf 'Q1: one more thing?\nreopen-unique-line\n' >"$ustate5/node/X01/QUESTION.md"
ev "session X01 ended (rc 0) with QUESTION.md" "$ustate5"
urun "$ustate5"; urun "$ustate5"; urun "$ustate5"
ok "U01-AC-6: a new question on a closed home issue reopens it" test "$(ustateof 58)" = open
ok "U01-AC-6: and the question is posted there once, whole, with its heading" test "$(ucontains 58 "$ustate5/node/X01/QUESTION.md")" = 1 -a "$(ucount 58 '(?m)^## X01 asks$')" = 1
ok "U01-AC-6: the reopened issue is not closed again while the question is open" test "$(ustateof 58)" = open
rm "$ustate5/node/X01/QUESTION.md"; mkdir "$ustate5/node/X01/answered"
urun "$ustate5"
ok "U01-AC-6: and it closes again at the first run after the question is released" test "$(ustateof 58)" = closed
ok "U01-AC-6: no node or triage issue other than the resolved ones was closed (triage issues 57 and 69 stay open)" test "$(ustateof 57)$(ustateof 69)" = openopen
ok "U01-AC-6: the status issue is still open" test "$(ustateof "$ustatus")" = open

# U01-AC-4 (S2b): an owner comment led by the ID of a unit that is not waiting is not the waiting unit's answer.
mkspec V10 share-wait '#54'
mkspec V11 share-done '#54'
mkspec V12 lone-asker ''
git -C "$uclone" add nodes && git -C "$uclone" -c user.name=t -c user.email=t@t commit -q -m specs3 &&
	git -C "$uclone" update-ref refs/remotes/origin/main HEAD
ustate6=$tmp/ustate6
mkdir -p "$ustate6/node/V10" "$ustate6/node/V11" "$ustate6/node/V12"
: >"$ustate6/status.log"
urun "$ustate6"
printf 'Q1: wait?\nv10-unique-q-line\n' >"$ustate6/node/V10/QUESTION.md"
printf 'Q1: done?\nv11-unique-q-line\n' >"$ustate6/node/V11/QUESTION.md"
printf 'Q1: lone?\nv12-unique-q-line\n' >"$ustate6/node/V12/QUESTION.md"
ev "session V10 ended (rc 0) with QUESTION.md" "$ustate6"
ev "session V11 ended (rc 0) with QUESTION.md" "$ustate6"
ev "session V12 ended (rc 0) with QUESTION.md" "$ustate6"
urun "$ustate6"; urun "$ustate6"
uowned 54 "V11: yes" https://x/s6-v11
urun "$ustate6"; urun "$ustate6"
ok "U01-AC-4: (precondition) V10 and V11 share issue 54 and V11 is answered by its ID prefix, V10 still waits" sh -c "[ \"\$(cat '$ustate6/node/V10/issue' 2>/dev/null)\$(cat '$ustate6/node/V11/issue' 2>/dev/null)\" = 5454 ] && grep -q '^V11: yes\$' '$ustate6/node/V11/ANSWER.md' && [ ! -e '$ustate6/node/V10/ANSWER.md' ]"
uowned 54 "V11: actually no" https://x/s6-v11-again
urun "$ustate6"; urun "$ustate6"; urun "$ustate6"
ok "U01-AC-4: a comment led by the ID of a unit that is not waiting (V11, answered) is not recorded as the waiting unit's (V10) answer" sh -c "[ ! -e '$ustate6/node/V10/ANSWER.md' ] && ! grep -q 'actually no' '$ustate6/node/V11/ANSWER.md'"
ok "U01-AC-4: and gets one reply over repeated runs, saying it is not recorded" test "$(ubcount 54 '\A(?!\*\*Stage:)Not recorded')" = 1
ok "U01-AC-4: and no reaction" test "$(ureact https://x/s6-v11-again)" = 0
h12=$(cat "$ustate6/node/V12/issue" 2>/dev/null)
uowned "$h12" "Q12: go ahead" https://x/s6-q12
urun "$ustate6"; urun "$ustate6"
ok "U01-AC-4: a leading token that only looks like an ID (Q12:, no such unit) with one waiting unit is that unit's answer" sh -c "grep -q '^Q12: go ahead\$' '$ustate6/node/V12/ANSWER.md'"
ok "U01-AC-4: and it gets one +1 reaction" test -n "$h12" -a "$(ureact https://x/s6-q12)" = 1

# Risks (S2b): a spec-PR update task (state pr/<N>/) is not a unit and has no home issue.
nis6=$(uq "len(db['issues'])")
mkdir -p "$ustate6/pr/77"
printf '2026-02-04T00:00:00Z second exit (rc 1) without finishing\npr77-detail\n' >"$ustate6/pr/77/FAILED"
printf 'Q1: update?\npr77-unique-q-line\n' >"$ustate6/pr/77/QUESTION.md"
urun "$ustate6"; urun "$ustate6"; urun "$ustate6"
ok "Risks: a pr/<N> folder with FAILED and QUESTION.md creates no issue (no Build PR issue, issue count unchanged)" test "$(uq "len(db['issues'])")" = "$nis6" -a "$(uq "len([i for i in db['issues'].values() if 'PR #' in i['title']])")" = 0
ok "Risks: and no pr/<N>/issue file is written" test ! -e "$ustate6/pr/77/issue"
ok "Risks: and no comment (milestone or question) names PR #77 or its question" test "$(uq "len([c for c in db['comments'] if 'PR #77' in c['body'] or 'pr77-unique-q-line' in c['body']])")" = 0

# U01-AC-9 + U01-AC-6 (S3b): the first run of this version on a report.json of the old version closes nothing that was
# merged before it, comments on nothing, and still closes a candidate held at that run once the hold ends.
python3 -I -c "
import json
db = json.load(open('$udb'))
for n in range(71, 77):
    db['issues'][str(n)] = {'number': n, 'title': 'Seeded %d' % n, 'body': '', 'labels': [], 'state': 'open', 'node_id': 'I_%d' % n}
db['issues']['71']['state'] = 'closed'
json.dump(db, open('$udb', 'w'))"
mkspec Y01 old-merged '#71, #72'
mkspec Y02 old-asking '#73'
mkspec Y03 old-shared-a '#74'
mkspec Y04 old-shared-b '#74'
mkspec Z01 reopened ''
git -C "$uclone" add nodes && git -C "$uclone" -c user.name=t -c user.email=t@t commit -q -m specs4 &&
	git -C "$uclone" update-ref refs/remotes/origin/main HEAD
# upatches <issue>: the PATCH calls on the issue since $tmp/ucalls was last emptied.
upatches() { grep -c "^PATCH repos/owner/repo/issues/$1\$" "$tmp/ucalls" || true; }
ok "U01-AC-6: (self-check) the PATCH pattern matches a logged call and not another issue's" sh -c "printf 'PATCH repos/owner/repo/issues/73\nPATCH repos/owner/repo/issues/730\n' | grep -c '^PATCH repos/owner/repo/issues/73\$' | grep -qx 1"

ustate7=$tmp/ustate7
mkdir -p "$ustate7/node/Y01" "$ustate7/node/Y02" "$ustate7/node/Y03" "$ustate7/node/Y04"
: >"$ustate7/status.log"
usetpulls '[]'
printf 'Q1: asking when merged?\ny02-unique-q-line\n' >"$ustate7/node/Y02/QUESTION.md"
printf '401 node/Y01-old-merged\n402 node/Y02-old-asking\n403 node/Y03-old-shared-a\n' >"$ustate7/merged-prs.tsv"
yqkey=$(stat -c %Y "$ustate7/node/Y02/QUESTION.md")
ymax=$(uq "max([c['id'] for c in db['comments']] or [0])")
printf '{"issue": %s, "comment_id": %s, "log_offset": 0, "questions": {"Y02": "%s"}, "body_hash": "x", "body_time": 0}\n' \
	"$ustatus" "$ymax" "$yqkey" >"$ustate7/report.json"
: >"$tmp/ucalls"
urun "$ustate7"; rcy=$?
ok "U01-AC-9: the first run on an old report.json succeeds" test "$rcy" = 0
ok "U01-AC-9: it posts no comment on an already-closed Resolves issue of a node merged before (71)" test "$(unum 71)" = 0
ok "U01-AC-9: nor on the still-open one (72)" test "$(unum 72)" = 0
ok "U01-AC-9: it makes no PATCH of the closed Resolves issue (71)" test "$(upatches 71)" = 0
ok "U01-AC-9: nor of the open one (72)" test "$(upatches 72)" = 0
ok "U01-AC-9: and 72 is still open, 71 still closed" test "$(ustateof 72)$(ustateof 71)" = openclosed
urun "$ustate7"; urun "$ustate7"; urun "$ustate7"
ok "U01-AC-9: over further runs nothing is posted on 71 or 72" test "$(unum 71)$(unum 72)" = 00
ok "U01-AC-9: over further runs nothing is closed or changed for them (no PATCH of 71 or 72, 72 open)" test "$(upatches 71)$(upatches 72)" = 00 -a "$(ustateof 72)" = open
ok "U01-AC-6: a candidate held at that first run (73: its unit's question is open) is not closed and has no comment" test "$(ustateof 73)" = open -a "$(unum 73)" = 0 -a "$(upatches 73)" = 0
ok "U01-AC-6: a candidate held by another node not merged (74: Y04) is not closed and has no comment" test "$(ustateof 74)" = open -a "$(unum 74)" = 0 -a "$(upatches 74)" = 0
rm "$ustate7/node/Y02/QUESTION.md"; mkdir "$ustate7/node/Y02/answered"
urun "$ustate7"; urun "$ustate7"; urun "$ustate7"
ok "U01-AC-6: at the first run after the question is released, the held candidate (73) is closed" test "$(ustateof 73)" = closed
ok "U01-AC-6: with one comment naming the PR (402), once over three runs" test "$(ucount 73 '(#|pull/)402\b')" = 1
ok "U01-AC-6: and one PATCH closing it" test "$(upatches 73)" = 1
ok "U01-AC-6: the other held candidate (74) still waits for Y04" test "$(ustateof 74)" = open -a "$(unum 74)" = 0
echo "404 node/Y04-old-shared-b" >>"$ustate7/merged-prs.tsv"
urun "$ustate7"
ok "U01-AC-6: at the first run after the other node is merged, 74 is closed" test "$(ustateof 74)" = closed
n74=$(unum 74)
urun "$ustate7"; urun "$ustate7"
ok "U01-AC-6: with a comment naming a merged PR (403 or 404), none added over further runs" test "$(ucount 74 '(#|pull/)40[34]\b')" -ge 1 -a "$(unum 74)" = "$n74"
ok "U01-AC-6: the closing is one comment (the merged milestone of Y04 and the closing comment: two at most)" test "$n74" -ge 1 -a "$n74" -le 2
ok "U01-AC-6: and one PATCH closing it" test "$(upatches 74)" = 1
ok "U01-AC-9: and still nothing for the issues of the node merged before (71, 72)" test "$(unum 71)$(unum 72)$(upatches 71)$(upatches 72)" = 0000

# U01-AC-6 (S3b): a home issue closed by someone else is reopened by the unit's new QUESTION.md, which is posted there once.
ustate8=$tmp/ustate8
mkdir -p "$ustate8/node/Z01"
: >"$ustate8/status.log"
urun "$ustate8"
ev "started Z01 (reopened) in /wt, pid 1, start 1 of 2" "$ustate8"
urun "$ustate8"; urun "$ustate8"
z1=$(cat "$ustate8/node/Z01/issue" 2>/dev/null)
ok "U01-AC-6: (precondition) Z01 has a Build issue as home with its start posted" test -n "$z1" -a "$(unum "$z1")" = 1
python3 -I -c "
import json
db = json.load(open('$udb')); db['issues']['$z1']['state'] = 'closed'; json.dump(db, open('$udb', 'w'))"
printf 'Q1: reopen me?\nz01-unique-q-line\n' >"$ustate8/node/Z01/QUESTION.md"
ev "session Z01 ended (rc 0) with QUESTION.md" "$ustate8"
urun "$ustate8"; urun "$ustate8"; urun "$ustate8"
ok "U01-AC-6: a new QUESTION.md of a unit whose home issue was closed by someone else reopens that issue" test "$(ustateof "$z1")" = open
ok "U01-AC-6: and the question is posted there once, in full" test "$(ucontains "$z1" "$ustate8/node/Z01/QUESTION.md")" = 1
ok "U01-AC-6: the reopened issue is not closed again by the loop and holds the start and the question only" test "$(unum "$z1")" = 2

# U01-AC-3 "merged once" + U01-AC-9 (S3c, G1): a failed `gh pr list` leaves merged-prs.tsv empty (the loop truncates it first)
# while subjects.txt + graph.yaml still show the merges; the node's merged milestone is not posted again, no issue is created,
# nothing is closed or commented, once the file is back.
python3 -I -c "
import json
db = json.load(open('$udb'))
db['issues']['81'] = {'number': 81, 'title': 'Seeded 81', 'body': '', 'labels': [], 'state': 'open', 'node_id': 'I_81'}
json.dump(db, open('$udb', 'w'))"
mkspec P01 p-one '#81'
mkspec P02 p-two ''
mkspec P03 p-three ''
git -C "$uclone" add nodes && git -C "$uclone" -c user.name=t -c user.email=t@t commit -q -m specs5 &&
	git -C "$uclone" update-ref refs/remotes/origin/main HEAD
ustate9=$tmp/ustate9
mkdir -p "$ustate9/node/P01" "$ustate9/node/P02" "$ustate9/node/P03"
cat >"$ustate9/graph.yaml" <<'GRAPH'
nodes:
  - {id: P01, name: p-one, deps: []}
  - {id: P02, name: p-two, deps: []}
  - {id: P03, name: p-three, deps: []}
GRAPH
: >"$ustate9/status.log"
usetpulls '[]'
rm -f "$tmp/ufail"
# P03 was merged long ago: known from both sources at the seed run, no home issue
echo "703 node/P03-p-three" >"$ustate9/merged-prs.tsv"
echo "P03 p-three: long ago (#703)" >"$ustate9/subjects.txt"
: >"$ustate9/closed-prs.tsv"
urun "$ustate9"
ev "started P01 (p-one) in /wt, pid 1, start 1 of 2" "$ustate9"
ev "started P02 (p-two) in /wt, pid 2, start 1 of 2" "$ustate9"
urun "$ustate9"; urun "$ustate9"; urun "$ustate9"
p1=$(cat "$ustate9/node/P01/issue" 2>/dev/null); p2=$(cat "$ustate9/node/P02/issue" 2>/dev/null)
printf '701 node/P01-p-one\n702 node/P02-p-two\n703 node/P03-p-three\n' >"$ustate9/merged-prs.tsv"
printf 'P01 p-one: it (#701)\nP02 p-two: it (#702)\nP03 p-three: long ago (#703)\n' >"$ustate9/subjects.txt"
urun "$ustate9"; urun "$ustate9"; urun "$ustate9"
ok "U01-AC-3: (precondition G1) P01 (Resolves #81) and P02 (no Resolves line) each have one merged milestone naming their PR" test "$p1" = 81 -a -n "$p2" -a "$(ucount 81 '(?i)merged.*701|701.*merged')" -ge 1 -a "$(ucount "${p2:-0}" '(?i)merged.*702|702.*merged')" -ge 1
ok "U01-AC-6: (precondition G1) P01's issue 81 is closed" test "$(ustateof 81)" = closed
g1c=$(uq "len(db['comments'])"); g1i=$(uq "len(db['issues'])")
g1m1=$(ucount 81 '(?i)\bmerged\b'); g1m2=$(ucount "${p2:-0}" '(?i)\bmerged\b')
: >"$tmp/ucalls"
: >"$ustate9/merged-prs.tsv"; : >"$ustate9/closed-prs.tsv"
urun "$ustate9"; urun "$ustate9"; urun "$ustate9"
printf '701 node/P01-p-one\n702 node/P02-p-two\n703 node/P03-p-three\n' >"$ustate9/merged-prs.tsv"
urun "$ustate9"; urun "$ustate9"; urun "$ustate9"
ok "U01-AC-3: a run with merged-prs.tsv empty (failed gh pr list) and the file restored post no second merged milestone for P01 (Resolves line)" test "$(ucount 81 '(?i)\bmerged\b')" = "$g1m1"
ok "U01-AC-3: nor for P02 (no Resolves line)" test "$(ucount "${p2:-0}" '(?i)\bmerged\b')" = "$g1m2"
ok "U01-AC-9: no issue is created (no Build issue for P03, merged long ago with no home issue)" test "$(uq "len(db['issues'])")" = "$g1i" -a "$(ubuilds 'Build P03 p-three')" = 0 -a ! -e "$ustate9/node/P03/issue"
ok "U01-AC-9: no comment of any kind is added anywhere" test "$(uq "len(db['comments'])")" = "$g1c"
ok "U01-AC-6: nothing is closed or reopened again (no PATCH of 81, of P02's home or of any issue but the status body)" test "$(upatches 81)" = 0 -a "$(upatches "${p2:-0}")" = 0 -a "$(grep -c '^PATCH' "$tmp/ucalls" || true)" -le 3

# U01-AC-3 "the CI result once per PR head commit" (S3c, G2): a transient failure of the check-runs call (its message names the
# path, and so the sha, which here holds 404 / 403) is retried; the CI result is posted once after it succeeds.
mkspec Q01 q-one ''
mkspec Q02 q-two ''
git -C "$uclone" add nodes && git -C "$uclone" -c user.name=t -c user.email=t@t commit -q -m specs6 &&
	git -C "$uclone" update-ref refs/remotes/origin/main HEAD
ustate10=$tmp/ustate10
mkdir -p "$ustate10/node/Q01" "$ustate10/node/Q02"
: >"$ustate10/status.log"
usetpulls '[]'
urun "$ustate10"
ev "started Q01 (q-one) in /wt, pid 1, start 1 of 2" "$ustate10"
ev "started Q02 (q-two) in /wt, pid 2, start 1 of 2" "$ustate10"
urun "$ustate10"; urun "$ustate10"
q1=$(cat "$ustate10/node/Q01/issue" 2>/dev/null); q2=$(cat "$ustate10/node/Q02/issue" 2>/dev/null)
usetchecks c0404de '[{"name": "test", "status": "completed", "conclusion": "success"}]'
usetchecks c0403de '[{"name": "test", "status": "completed", "conclusion": "failure"}]'
usetpulls "[$(upull 604 node/Q01-q-one c0404de), $(upull 603 node/Q02-q-two c0403de)]"
echo 'GET .*check-runs' >"$tmp/ufail"
urun "$ustate10"
urun "$ustate10"
ok "U01-AC-3: (precondition G2) while the check-runs call fails no CI result is posted" test "$(ucount "${q1:-0}" '(?i)CI (passed|failed)')" = 0
rm -f "$tmp/ufail"
urun "$ustate10"; urun "$ustate10"; urun "$ustate10"
ok "U01-AC-3: after a transient HTTP 502 on the check-runs call of a head commit whose sha holds 404, its CI result is posted once" test -n "$q1" -a "$(ucount "$q1" '(?i)CI passed')" = 1
ok "U01-AC-3: likewise for a sha holding 403 (a failed result naming its failing check), once" test -n "$q2" -a "$(ucount "$q2" '(?is)CI failed.*test')" = 1
ok "U01-AC-3: and the PR opened is still posted once on each" test "$(ucount "${q1:-0}" 'pull/604\b')" = 1 -a "$(ucount "${q2:-0}" 'pull/603\b')" = 1

# U01-AC-9 (S3c, G3): the first run on an old report.json happens while the clone cannot be read; the issue of a node merged
# before, already closed, is never commented on or patched by later runs with the clone readable.
python3 -I -c "
import json
db = json.load(open('$udb'))
db['issues']['85'] = {'number': 85, 'title': 'Seeded 85', 'body': '', 'labels': [], 'state': 'closed', 'node_id': 'I_85'}
json.dump(db, open('$udb', 'w'))"
mkspec R01 r-one '#85'
git -C "$uclone" add nodes && git -C "$uclone" -c user.name=t -c user.email=t@t commit -q -m specs7 &&
	git -C "$uclone" update-ref refs/remotes/origin/main HEAD
urun_noclone() { env PATH="$ubin:$PATH" python3 -I "$src/report.py" --repo owner/repo --state "$1" --worktrees "$tmp/worktrees/repo" --clone "$tmp/no-such-clone" --owner owner 2>"$tmp/uerr"; }
ustate11=$tmp/ustate11
mkdir -p "$ustate11/node/R01"
: >"$ustate11/status.log"
usetpulls '[]'
echo "801 node/R01-r-one" >"$ustate11/merged-prs.tsv"
rmax=$(uq "max([c['id'] for c in db['comments']] or [0])")
printf '{"issue": %s, "comment_id": %s, "log_offset": 0, "questions": {}, "body_hash": "x", "body_time": 0}\n' \
	"$ustatus" "$rmax" >"$ustate11/report.json"
: >"$tmp/ucalls"
urun_noclone "$ustate11"
urun_noclone "$ustate11"
urun "$ustate11"; urun "$ustate11"; urun "$ustate11"; urun "$ustate11"
ok "U01-AC-9: with the clone unreadable at the first run, a node merged before and its closed Resolves issue (85) get no comment later" test "$(unum 85)" = 0
ok "U01-AC-9: and no PATCH of it ever, and it stays closed" test "$(upatches 85)" = 0 -a "$(ustateof 85)" = closed

# U01-AC-9 + U01-AC-3 (S3d, H1a): the seed run (first run with this bookkeeping) coincides with a failed `gh pr list`
# (merged-prs.tsv and closed-prs.tsv empty) while subjects.txt + graph.yaml show nodes merged long ago; once the files are
# back, those nodes get no merged milestone, no Build issue, no comment on their closed Resolves issue and no PATCH.
# Two cases: an old report.json (no pr_seed) and no report.json at all.
python3 -I -c "
import json
db = json.load(open('$udb'))
for n in (91, 92, 93, 94):
    db['issues'][str(n)] = {'number': n, 'title': 'Seeded %d' % n, 'body': '', 'labels': [], 'state': 'closed', 'node_id': 'I_%d' % n}
json.dump(db, open('$udb', 'w'))"
mkspec M01 m-one '#91'
mkspec M02 m-two ''
mkspec N01 n-one '#92'
mkspec N02 n-two ''
mkspec K01 k-one '#93'
mkspec K02 k-two ''
mkspec K03 k-three ''
mkspec H01 h-one '#95, #96'
git -C "$uclone" add nodes && git -C "$uclone" -c user.name=t -c user.email=t@t commit -q -m specs8 &&
	git -C "$uclone" update-ref refs/remotes/origin/main HEAD
# uanypatch: the PATCH calls since $tmp/ucalls was emptied, other than on the status issue.
uanypatch() { grep '^PATCH' "$tmp/ucalls" | grep -vc "issues/$ustatus\$" || true; }
ok "U01-AC-9: (self-check) uanypatch ignores the status issue and counts another" sh -c "printf 'PATCH repos/o/r/issues/$ustatus\nPATCH repos/o/r/issues/9\n' | grep '^PATCH' | grep -vc 'issues/$ustatus\$' | grep -qx 1"
usetpulls '[]'
rm -f "$tmp/ufail"
h1mk() { # <state> <A> <B> <issue of A>: nodes A (Resolves issue) and B (none), merged long ago per the subjects, graph and folders
	mkdir -p "$1/node/$2" "$1/node/$3"
	printf 'nodes:\n  - {id: %s, name: x-a, deps: []}\n  - {id: %s, name: x-b, deps: []}\n' "$2" "$3" >"$1/graph.yaml"
	: >"$1/status.log"; : >"$1/merged-prs.tsv"; : >"$1/closed-prs.tsv"
	printf '%s x-a: it (#%s)\n%s x-b: it (#%s)\n' "$2" "$4" "$3" "$(($4 + 1))" >"$1/subjects.txt"
}
h1back() { # <state> <A> <B> <PR of A>
	printf '%s node/%s-x-a\n%s node/%s-x-b\n' "$4" "$2" "$(($4 + 1))" "$3" >"$1/merged-prs.tsv"
	printf '%s node/%s-x-a 2026-01-01T00:00:00Z true\n%s node/%s-x-b 2026-01-01T00:00:00Z true\n' "$4" "$2" "$(($4 + 1))" "$3" >"$1/closed-prs.tsv"
}
# old report.json
ustate12=$tmp/ustate12
h1mk "$ustate12" M01 M02 911
sed -i 's/x-a/m-one/g; s/x-b/m-two/g' "$ustate12/graph.yaml" "$ustate12/subjects.txt"
h1max=$(uq "max([c['id'] for c in db['comments']] or [0])")
printf '{"issue": %s, "comment_id": %s, "log_offset": 0, "questions": {}, "body_hash": "x", "body_time": 0}\n' \
	"$ustatus" "$h1max" >"$ustate12/report.json"
h1c=$(uq "len(db['comments'])"); h1i=$(uq "len(db['issues'])")
: >"$tmp/ucalls"
urun "$ustate12"; urun "$ustate12"
printf '911 node/M01-m-one\n912 node/M02-m-two\n' >"$ustate12/merged-prs.tsv"
printf '911 node/M01-m-one 2026-01-01T00:00:00Z true\n912 node/M02-m-two 2026-01-01T00:00:00Z true\n' >"$ustate12/closed-prs.tsv"
urun "$ustate12"; urun "$ustate12"; urun "$ustate12"; urun "$ustate12"
ok "U01-AC-9: (H1a, old report.json) a seed run with merged-prs.tsv empty, then the file restored: no merged milestone on the closed Resolves issue (91)" test "$(ucount 91 '(?i)merged')" = 0
ok "U01-AC-9: (H1a, old report.json) no Build issue for the node without a Resolves line (M02)" test "$(ubuilds 'Build M02 m-two')" = 0 -a ! -e "$ustate12/node/M02/issue" -a "$(uq "len(db['issues'])")" = "$h1i"
ok "U01-AC-9: (H1a, old report.json) no comment of any kind is added anywhere" test "$(uq "len(db['comments'])")" = "$h1c"
ok "U01-AC-9: (H1a, old report.json) no PATCH of the closed Resolves issue (91) or of any issue but the status issue, and 91 stays closed" test "$(upatches 91)" = 0 -a "$(uanypatch)" = 0 -a "$(ustateof 91)" = closed
# no report.json at all
ustate13=$tmp/ustate13
h1mk "$ustate13" N01 N02 921
sed -i 's/x-a/n-one/g; s/x-b/n-two/g' "$ustate13/graph.yaml" "$ustate13/subjects.txt"
h1c=$(uq "len(db['comments'])"); h1i=$(uq "len(db['issues'])")
: >"$tmp/ucalls"
urun "$ustate13"; urun "$ustate13"
printf '921 node/N01-n-one\n922 node/N02-n-two\n' >"$ustate13/merged-prs.tsv"
printf '921 node/N01-n-one 2026-01-01T00:00:00Z true\n922 node/N02-n-two 2026-01-01T00:00:00Z true\n' >"$ustate13/closed-prs.tsv"
urun "$ustate13"; urun "$ustate13"; urun "$ustate13"; urun "$ustate13"
h1c2=$(uq "len(db['comments'])")
ok "U01-AC-9: (H1a, no report.json) no merged milestone on the closed Resolves issue (92)" test "$(ucount 92 '(?i)merged')" = 0
ok "U01-AC-9: (H1a, no report.json) no Build issue for the node without a Resolves line (N02)" test "$(ubuilds 'Build N02 n-two')" = 0 -a ! -e "$ustate13/node/N02/issue"
ok "U01-AC-9: (H1a, no report.json) no PATCH of 92 or of any issue but the status issue, and no comment added by the later runs" test "$(upatches 92)" = 0 -a "$(uanypatch)" = 0 -a "$h1c2" = "$h1c" -a "$(ustateof 92)" = closed

# U01-AC-9 + U01-AC-3 (S3d, H1b): the seed run happens with merged-prs.tsv filled but closed-prs.tsv empty (its call failed);
# once it is back, with an old PR closed without merging and the merged ones, nothing is posted for them.
ustate14=$tmp/ustate14
mkdir -p "$ustate14/node/K01" "$ustate14/node/K02" "$ustate14/node/K03"
printf 'nodes:\n  - {id: K01, name: k-one, deps: []}\n  - {id: K02, name: k-two, deps: []}\n  - {id: K03, name: k-three, deps: []}\n' >"$ustate14/graph.yaml"
: >"$ustate14/status.log"
printf 'K01 k-one: it (#931)\nK02 k-two: it (#932)\n' >"$ustate14/subjects.txt"
printf '931 node/K01-k-one\n932 node/K02-k-two\n' >"$ustate14/merged-prs.tsv"
: >"$ustate14/closed-prs.tsv"
printf '{"issue": %s, "comment_id": %s, "log_offset": 0, "questions": {}, "body_hash": "x", "body_time": 0}\n' \
	"$ustatus" "$h1max" >"$ustate14/report.json"
h1c=$(uq "len(db['comments'])"); h1i=$(uq "len(db['issues'])")
: >"$tmp/ucalls"
urun "$ustate14"; urun "$ustate14"
printf '931 node/K01-k-one 2026-01-02T00:00:00Z true\n932 node/K02-k-two 2026-01-02T00:00:00Z true\n930 node/K03-k-three 2026-01-01T00:00:00Z false\n' >"$ustate14/closed-prs.tsv"
urun "$ustate14"; urun "$ustate14"; urun "$ustate14"; urun "$ustate14"
ok "U01-AC-3: (H1b) a seed run with closed-prs.tsv empty, then restored: no closed-without-merging milestone for the old closed PR (930)" test "$(uq "len([c for c in db['comments'] if 'closed without' in c['body'].lower() and '#930' in c['body']])")" = 0
ok "U01-AC-9: (H1b) nothing else is new: no Build issue (K03), no comment anywhere, no PATCH but the status issue's" test "$(uq "len(db['issues'])")" = "$h1i" -a "$(ubuilds 'Build K03 k-three')" = 0 -a ! -e "$ustate14/node/K03/issue" -a "$(uq "len(db['comments'])")" = "$h1c" -a "$(uanypatch)" = 0
ok "U01-AC-9: (H1b) no merged milestone for K01 (Resolves 93, closed) either" test "$(ucount 93 '(?i)merged')" = 0 -a "$(ustateof 93)" = closed

# U01-AC-6 (S3d, H2): a Resolves issue of a merged node that the owner closed as "not planned" before the loop's rule holds
# is not patched, commented on or touched later; a sibling Resolves issue (95) still gets closed by the rule.
python3 -I -c "
import json
db = json.load(open('$udb'))
for n in (95, 96):
    db['issues'][str(n)] = {'number': n, 'title': 'Seeded %d' % n, 'body': '', 'labels': [], 'state': 'open', 'node_id': 'I_%d' % n}
json.dump(db, open('$udb', 'w'))"
ustate15=$tmp/ustate15
mkdir -p "$ustate15/node/H01"
: >"$ustate15/status.log"
usetpulls '[]'
printf 'Q1: asking while merged?\nh01-unique-q-line\n' >"$ustate15/node/H01/QUESTION.md"
echo "941 node/H01-h-one" >"$ustate15/merged-prs.tsv"
hkey=$(stat -c %Y "$ustate15/node/H01/QUESTION.md")
hmax=$(uq "max([c['id'] for c in db['comments']] or [0])")
printf '{"issue": %s, "comment_id": %s, "log_offset": 0, "questions": {"H01": "%s"}, "body_hash": "x", "body_time": 0}\n' \
	"$ustatus" "$hmax" "$hkey" >"$ustate15/report.json"
urun "$ustate15"; urun "$ustate15"
ok "U01-AC-6: (H2 precondition) both Resolves issues of the merged node H01 are held by its open question and untouched" test "$(ustateof 95)$(ustateof 96)" = openopen -a "$(unum 95)$(unum 96)" = 00
python3 -I -c "
import json
db = json.load(open('$udb'))
db['issues']['96'].update(state='closed', state_reason='not_planned')
json.dump(db, open('$udb', 'w'))"
: >"$tmp/ucalls"
rm "$ustate15/node/H01/QUESTION.md"; mkdir "$ustate15/node/H01/answered"
urun "$ustate15"; urun "$ustate15"; urun "$ustate15"; urun "$ustate15"
ok "U01-AC-6: (H2) the sibling Resolves issue (95) is closed by the rule with one comment naming the PR and one PATCH" test "$(ustateof 95)" = closed -a "$(ucount 95 '(#|pull/)941\b')" = 1 -a "$(upatches 95)" = 1
ok "U01-AC-6: (H2) the issue the owner closed as not planned (96) is not patched" test "$(upatches 96)" = 0
ok "U01-AC-6: (H2) and its state_reason is still not_planned and it is closed" test "$(uq "db['issues']['96']['state']+db['issues']['96'].get('state_reason','')")" = closednot_planned
ok "U01-AC-6: (H2) and it gets no comment, now or over later runs" test "$(unum 96)" = 0

# V01-AC-7: with --version and --signature, every comment report.py posts and the status issue body end with the
# signature line (after any cut), and the body's header names the version. Without them, nothing is signed.
# Each part starts from an empty fake database, so its status issue is number 100.
v7=v1.2.3-4-gabcdef0
sig7='— n00dl3b0t [v1.2.3-4-gabcdef0](https://github.com/acme-co/widget-kit/commit/0123456789abcdef0123456789abcdef01234567)'
printf '%s\n' "$sig7" >"$tmp/sig7"
cat >"$tmp/chk7.py" <<'PY'
import json, sys
db = json.load(open(sys.argv[1]))
sig = open(sys.argv[2], encoding="utf-8").read().strip()
mode = sys.argv[3]
arg = sys.argv[4] if len(sys.argv) > 4 else ""
bots = [c["body"] for c in db["comments"] if c["user"]["login"] == "bot"]
issues = db["issues"]
body = issues["100"]["body"] if "100" in issues else None
if mode == "ends":      # at least one bot comment holds arg, and each of them ends with the signature
    hit = [b for b in bots if arg in b]
    ok = bool(hit) and all(b.rstrip().endswith(sig) for b in hit)
elif mode == "all":     # at least 5 bot comments, each ends with the signature
    ok = len(bots) >= 5 and all(b.rstrip().endswith(sig) for b in bots)
elif mode == "cut":     # the cut comment: marker, then the signature at the very end, within GitHub's 65536
    hit = [b for b in bots if "(cut here" in b]
    ok = bool(hit) and all(b.rstrip().endswith(sig) and b.index("(cut here") < b.rindex(sig) and len(b) <= 65536 for b in hit)
elif mode == "body":
    ok = body is not None and body.rstrip().endswith(sig)
elif mode == "header":  # what precedes the first "## " heading names the version
    ok = body is not None and arg in body.split("\n## ")[0]
elif mode == "fallback":
    ok = body is not None and "status failed" in body and body.rstrip().endswith(sig) and arg in body.split("\n")[0:4].__str__()
elif mode == "unsigned":
    ok = len(bots) >= 3 and body is not None and not any("n00dl3b0t" in b for b in bots + [body])
else:
    ok = False
sys.exit(0 if ok else 1)
PY
chk7() { python3 -I "$tmp/chk7.py" "$db" "$tmp/sig7" "$@"; }
resetdb7() { echo '{"issues": {}, "comments": [], "labels": [], "pulls": []}' >"$db"; }
own7() {
	python3 -I -c "
import json, sys
db = json.load(open('$db'))
db['comments'].append({'id': len(db['comments']) + 1, 'issue': '100', 'body': sys.argv[1], 'user': {'login': 'owner', 'type': 'User'},
    'author_association': 'OWNER', 'created_at': '2026-01-09T00:00:00Z', 'html_url': 'https://x/c9'})
json.dump(db, open('$db', 'w'))" "$1"
}

state9=$tmp/state/repo9
mkdir -p "$state9/node/A01" "$state9/node/A02" "$state9/node/A03"
: >"$state9/status.log"
resetdb7
run9() { python3 -I "$src/report.py" --repo owner/repo --state "$state9" --worktrees "$tmp/worktrees/repo" --version "$v7" --signature "$sig7" 2>"$tmp/err9"; }
run9
printf 'Q1: which way?\n' >"$state9/node/A01/QUESTION.md"
{ printf 'Q1: a very long one\n'; awk 'BEGIN { for (i = 0; i < 1000; i++) printf "0123456789012345678901234567890123456789012345678901234567890123456789\n" }'; } >"$state9/node/A02/QUESTION.md"
printf 'Q1: short one\n' >"$state9/node/A03/QUESTION.md"
echo "2026-01-09T00:02:00Z open=[] merged-prs=[]; session A01 ended (rc 0) with QUESTION.md" >>"$state9/status.log"
own7 "B07: something"
own7 "A01: go"
run9; rc9a=$?
ok "V01-AC-7: the run with --version and --signature succeeds (answer recorded: exit 3)" test "$rc9a" = 3
ok "V01-AC-7: an event comment ends with the signature line" chk7 ends "session A01 ended"
ok "V01-AC-7: a question comment ends with the signature line" chk7 ends "## A03 asks"
ok "V01-AC-7: an answer reply (Recorded as ...) ends with the signature line" chk7 ends "Recorded as A01's ANSWER.md"
ok "V01-AC-7: a not-recorded reply ends with the signature line" chk7 ends "Not recorded as an answer"
ok "V01-AC-7: an over-long comment is cut, then the signature comes last, within GitHub's limit" chk7 cut
ok "V01-AC-7: every comment posted ends with the signature line" chk7 all
ok "V01-AC-7: the status issue body ends with the signature line" chk7 body
ok "V01-AC-7: the body's header names the version" chk7 header "$v7"
ok "V01-AC-7: the signed run leaves nothing on stderr" test ! -s "$tmp/err9"

# The fallback body (building the body fails: a FAILED that is a folder cannot be read) is signed too.
state10=$tmp/state/repo10
mkdir -p "$state10/node/X01/FAILED"
: >"$state10/status.log"
resetdb7
python3 -I "$src/report.py" --repo owner/repo --state "$state10" --worktrees "$tmp/worktrees/repo" --version "$v7" --signature "$sig7" 2>"$tmp/err10"
ok "V01-AC-7: the fallback status body ends with the signature line and names the version" chk7 fallback "$v7"

# Without the options nothing is signed.
state11=$tmp/state/repo11
mkdir -p "$state11/node/A01" "$state11/node/A02"
: >"$state11/status.log"
resetdb7
run11() { python3 -I "$src/report.py" --repo owner/repo --state "$state11" --worktrees "$tmp/worktrees/repo" 2>"$tmp/err11"; }
run11
printf 'Q1: which way?\n' >"$state11/node/A01/QUESTION.md"
echo "2026-01-09T00:02:00Z open=[] merged-prs=[]; session A02 ended (rc 0)" >>"$state11/status.log"
own7 "B07: something"
run11
ok "V01-AC-7: without the options no comment or body carries a signature" chk7 unsigned

# U01 fresh review (S6): the Build issue body is signed; a comment before the question is not its answer; a Build issue
# whose creating POST failed late is not created twice. Own units (T10..T13), appended to the fixture clone's specs.
mkspec T10 signed-build ''
mkspec T11 plain-build ''
mkspec T12 early-q '#51'
mkspec T13 late-fail ''
git -C "$uclone" add nodes && git -C "$uclone" -c user.name=t -c user.email=t@t commit -q -m specs3 &&
	git -C "$uclone" update-ref refs/remotes/origin/main HEAD
rm -f "$tmp/ufail"

# U01-AC-1 with V01-AC-7: the Build issue body ends with the signature line when --version and --signature are given.
ubody() { SIG=$(cat "$tmp/sig7") python3 -I -c "
import json, os, sys
db = json.load(open('$udb'))
b = [i['body'] for i in db['issues'].values() if i['title'] == sys.argv[1]]
if len(b) != 1: sys.exit(2)
if sys.argv[2] == 'ends': sys.exit(0 if b[0].rstrip().endswith(os.environ['SIG'].strip()) else 1)
sys.exit(0 if 'n00dl3b0t' not in b[0] else 1)" "$1" "$2"; }
ustate5=$tmp/ustate5 ustate6=$tmp/ustate6
mkdir -p "$ustate5/node/T10" "$ustate6/node/T11"
: >"$ustate5/status.log"; : >"$ustate6/status.log"
usigned() { env PATH="$ubin:$PATH" python3 -I "$src/report.py" --repo owner/repo --state "$ustate5" --worktrees "$tmp/worktrees/repo" --clone "$uclone" --owner owner --version "$v7" --signature "$sig7" 2>"$tmp/uerr"; }
usigned
ev "started T10 (signed-build) in /wt, pid 1, start 1 of 2" "$ustate5"
ev "started T11 (plain-build) in /wt, pid 2, start 1 of 2" "$ustate6"
usigned; rcs=$?; usigned
urun "$ustate6"; urun "$ustate6"
ok "U01-AC-1: (signature) the signed runs succeed and create the Build issue once" sh -c "[ $rcs = 0 ] && [ \"\$1\" = 1 ]" _ "$(ubuilds 'Build T10 signed-build')"
ok "U01-AC-1: (signature) with --version and --signature the Build issue body ends with the signature line (V01-AC-7)" ubody 'Build T10 signed-build' ends
ok "U01-AC-1: (signature) without the options the Build issue body carries no signature" ubody 'Build T11 plain-build' none

# U01-AC-4: an owner comment posted after the unit's start milestone (after the floor) but before its question comment
# is not the answer; one posted after the question is.
ustate7=$tmp/ustate7
mkdir -p "$ustate7/node/T12"
: >"$ustate7/status.log"
urun "$ustate7"
ev "started T12 (early-q) in /wt, pid 1, start 1 of 2" "$ustate7"
urun "$ustate7"; urun "$ustate7"
ucomment 51 "too early, before the question" 2026-02-02T00:00:00Z owner OWNER User https://x/t12-early
printf 'Q1: ask late?\nt12-unique-q-line\n' >"$ustate7/node/T12/QUESTION.md"
ev "session T12 ended (rc 0) with QUESTION.md" "$ustate7"
# the run that posts the question cannot read the issue's comments (a failed GET), so the owner's earlier comment is
# first seen by a later run, when the question is already open: only the question's position can tell it is no answer
echo 'GET .*issues/51/comments' >"$tmp/ufail"
urun "$ustate7"
rm -f "$tmp/ufail"
urun "$ustate7"; urun "$ustate7"; urun "$ustate7"
ok "U01-AC-4: (cut-off) the question was posted on the home issue after the owner's comment" test "$(ucount 51 't12-unique-q-line')" = 1
ok "U01-AC-4: (cut-off) an owner comment after the start but before the question is not recorded as ANSWER.md" test ! -e "$ustate7/node/T12/ANSWER.md"
ok "U01-AC-4: (cut-off) and gets no reaction" test "$(ureact https://x/t12-early)" = 0
uowned 51 "t12 real answer" https://x/t12-late
urun "$ustate7"; rct=$?
urun "$ustate7"
ok "U01-AC-4: (cut-off) an owner comment after the question becomes ANSWER.md (exit 3)" sh -c "[ $rct = 3 ] && grep -q '^t12 real answer\$' '$ustate7/node/T12/ANSWER.md'"

# U01-AC-1, U01-AC-9: the creating POST makes the Build issue, then fails (a timeout after GitHub made it). The next run
# finds it by title: one issue with that title, and the unit's issue file holds its number.
ubin2=$tmp/ubin2
mkdir -p "$ubin2"
cat >"$ubin2/gh" <<EOF
#!/bin/sh
# the fake gh; a POST .../issues while $tmp/ucreatefail exists is made, then fails once
if [ "\$3 \${4##*/}" = "POST issues" ] && [ -e "$tmp/ucreatefail" ]; then
	rm -f "$tmp/ucreatefail"; "$ubin/gh" "\$@" >/dev/null; echo "HTTP 504: timeout after the issue was created" >&2; exit 1
fi
exec "$ubin/gh" "\$@"
EOF
chmod +x "$ubin2/gh"
ustate8=$tmp/ustate8
mkdir -p "$ustate8/node/T13"
: >"$ustate8/status.log"
urun2() { env PATH="$ubin2:$PATH" python3 -I "$src/report.py" --repo owner/repo --state "$1" --worktrees "$tmp/worktrees/repo" --clone "$uclone" --owner owner 2>"$tmp/uerr"; }
urun2 "$ustate8"
ev "started T13 (late-fail) in /wt, pid 1, start 1 of 2" "$ustate8"
: >"$tmp/ucreatefail"
urun2 "$ustate8"; rcl=$?
ok "U01-AC-9: (late failure) the run whose creating POST failed after the issue was made exits non-zero" test "$rcl" != 0
ok "U01-AC-9: (late failure) the issue exists once, the unit has no issue file yet" sh -c "[ \"\$1\" = 1 ] && [ ! -e '$ustate8/node/T13/issue' ]" _ "$(ubuilds 'Build T13 late-fail')"
urun2 "$ustate8"; rcl2=$?
urun2 "$ustate8"
ok "U01-AC-1: (late failure) the next runs succeed" test "$rcl2" = 0
ok "U01-AC-1: (late failure) still exactly one Build issue with that title" test "$(ubuilds 'Build T13 late-fail')" = 1
ok "U01-AC-1: (late failure) the unit's issue file holds that issue's number" test "$(cat "$ustate8/node/T13/issue" 2>/dev/null)" = "$(uq "[i['number'] for i in db['issues'].values() if i['title'] == 'Build T13 late-fail'][0]")"
ok "U01-AC-2: (late failure) its start milestone is on that issue once" test "$(unum "$(cat "$ustate8/node/T13/issue" 2>/dev/null)")" = 1

# U02-AC-1, U02-AC-2, U02-AC-3: the day's log issue, its morning overview and body, its event comments.
# report.py reads the local "now" from NOODLEBOT_NOW (an ISO local datetime, e.g. 2026-03-10T09:00:00) and the
# deployed commit from the git checkout at NOODLEBOT_LIVE (HEAD), in place of the live checkout it runs from.
# Own database and fake gh (the U01 fake on its own file), TZ=UTC so the status.log stamps (Z) and the local date agree.
vroot=$tmp/vroot vbin=$tmp/vbin vdb=$tmp/vgh.json vlive=$tmp/vlive
vstate=$vroot/state
mkdir -p "$vbin" "$vstate/node/V03" "$vstate/node/V04" "$vstate/node/V05" "$vstate/node/V06" "$vlive"
python3 -I -c "
import json
mk = lambda n, t, lab: {'number': n, 'title': t, 'body': '', 'labels': lab, 'state': 'open', 'node_id': 'I_%d' % n}
issues = {'47': mk(47, 'Unit V03', []), '48': mk(48, 'Unit V06', []),
          '150': mk(150, 'noodlebot log 2026-03-09', ['noodlebot-status'])}
json.dump({'issues': issues, 'comments': [], 'labels': ['noodlebot-status'], 'pulls': [], 'checks': {}, 'reactions': [], 'next': 200}, open('$vdb', 'w'))"
sed "s#$udb#$vdb#g; s#$tmp/ufail#$tmp/vfail#g; s#$tmp/ucalls#$tmp/vcalls#g" "$ubin/gh" >"$vbin/gh"
chmod +x "$vbin/gh"
git -C "$vlive" init -q -b main && git -C "$vlive" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "live one"
vsha1=$(git -C "$vlive" rev-parse HEAD)
vrun() { env PATH="$vbin:$PATH" TZ=UTC NOODLEBOT_NOW="$1" NOODLEBOT_LIVE="$vlive" python3 -I "$src/report.py" --repo owner/repo --state "$vstate" --worktrees "$tmp/worktrees/repo" --clone "$uclone" --owner owner 2>"$tmp/verr"; }
# vq <python expr>: evaluated with db, n (number of today's log issue, "" if none), logs (issues titled for 2026-03-10),
# cs (the comments on that issue, in order) and body.
vq() {
	python3 -I -c "
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
trap 'kill $pids $sess $pids3 $pids4 $pids5 $pids6 $pids7 $pidsv 2>/dev/null; rm -rf "$tmp"' EXIT
sleep 1
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
	python3 -I -c "
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

# U02-AC-4, U02-AC-5: the daily rollover, the old status issue's closing and the answers it still takes. Own database and
# fake gh (the U01 fake, patched: it logs each PATCH as "PATCH <n> state=<s> keys=<k,...>" and each GraphQL body, can fail a
# GraphQL call whose body matches $tmp/xgqlfail, and fails the calls matching $tmp/xfail only while the python expression
# in $tmp/xcond (over `db`) is true; each injected failure is logged as "INJECTED ..." in $tmp/xlog).
xroot=$tmp/x xbin=$tmp/xbin xdb=$tmp/xgh.json
mkdir -p "$xbin" "$xroot"
cat >"$tmp/xpatch.py" <<'PY'
import sys
src, dst, udb, ucalls, ufail, xdb, xcalls, xfail, xcond, xlog, xgql, xgqlfail = sys.argv[1:]
t = open(src).read().replace(udb, xdb).replace(ucalls, xcalls).replace(ufail, xfail)
def sub(old, new):
    global t
    if old not in t:
        sys.exit("xpatch: not found: " + old)
    t = t.replace(old, new)
sub('if mode and re.search(mode, desc):',
    'if mode and re.search(mode, desc) and eval(open(%r).read() if os.path.exists(%r) else "True"):' % (xcond, xcond))
sub('print("HTTP 502: injected failure for " + desc, file=sys.stderr)',
    'open(%r, "a").write("INJECTED " + desc + "\\n"); print("HTTP 502: injected failure for " + desc, file=sys.stderr)' % xlog)
sub('    if method == "PATCH": db["issues"][n].update(body)',
    '    if method == "PATCH":\n        open(%r, "a").write("PATCH %%s state=%%s keys=%%s\\n" %% (n, body.get("state"), ",".join(sorted(body))))\n        db["issues"][n].update(body)' % xlog)
sub('elif p == "graphql":',
    'elif p == "graphql":\n    open(%r, "a").write(json.dumps(body) + "\\n")\n    if os.path.exists(%r) and re.search(open(%r).read().strip(), json.dumps(body)):\n        print("HTTP 403: injected graphql failure", file=sys.stderr); sys.exit(1)' % (xgql, xgqlfail, xgqlfail))
open(dst, "w").write(t)
PY
python3 -I "$tmp/xpatch.py" "$ubin/gh" "$xbin/gh" "$udb" "$tmp/ucalls" "$tmp/ufail" "$xdb" "$tmp/xcalls" "$tmp/xfail" "$tmp/xcond" "$tmp/xlog" "$tmp/xgql" "$tmp/xgqlfail" 2>"$tmp/xpatch.err"
chmod +x "$xbin/gh"
ok "U02-AC-4: (harness) the patched fake gh was written" test -s "$xbin/gh" -a ! -s "$tmp/xpatch.err"
xrun() { env PATH="$xbin:$PATH" TZ=UTC NOODLEBOT_NOW="$1" NOODLEBOT_LIVE="$vlive" python3 -I "$src/report.py" --repo owner/repo --state "$xs" --worktrees "$tmp/worktrees/repo" --clone "$uclone" --owner owner 2>"$tmp/xerr"; }
# xq <python expr>: evaluated with db, L(<date>) (the issues titled 'noodlebot log <date>') and C(<issue>) (its comments).
xq() {
	python3 -I -c "
import json, re, sys
db = json.load(open('$xdb'))
def L(d): return [i for i in db['issues'].values() if i['title'] == 'noodlebot log ' + d]
def C(n): return [c for c in db['comments'] if c['issue'] == str(n)]
print(eval(sys.argv[1]))" "$1" 2>/dev/null
}
# xlinks <from> <to>: True when issue <from> (its body or one of its comments) links issue <to>.
xlinks() { xq "any(re.search(r'#%s\b|/issues/%s\b' % ($2, $2), s) for s in [db['issues']['$1']['body']] + [c['body'] for c in C($1)])"; }
xowner() {
	python3 -I -c "
import json, sys
db = json.load(open('$xdb'))
db['comments'].append({'id': len(db['comments']) + 1, 'issue': sys.argv[1], 'body': sys.argv[2], 'user': {'login': 'owner', 'type': 'User'},
    'author_association': 'OWNER', 'created_at': '2026-04-10T10:00:00Z', 'html_url': 'https://x/x%s' % (len(db['comments']) + 1)})
json.dump(db, open('$xdb', 'w'))" "$1" "$2"
}
xpins() { grep -cE '(^|[^n])pinIssue' "$tmp/xgql"; }
xunpins() { grep -c unpinIssue "$tmp/xgql"; }
# xcore: the old issue's comment count, the number of issues for 2026-04-11, the closes of the old issue, the new issue's comment count.
xcore() { printf '%s %s %s %s' "$(xq "len(C($xold))")" "$(xq "len(L('2026-04-11'))")" "$(grep -c "^PATCH $xold state=closed" "$tmp/xlog")" "$(xq "len(C($xnew))")"; }
xclean() { rm -f "$tmp/xfail" "$tmp/xcond" "$tmp/xgqlfail"; : >"$tmp/xlog"; : >"$tmp/xgql"; }

# xinit <name>: a fresh database and state folder for the day 2026-04-10, and two runs that day (so today's log issue is
# $xold, number 200). The day's events: X01 ended (cost $2.50) and its PR #501 merged; X02 ended (cost $1.25) and wrote
# FAILED; X03's PR #502 was opened; X04 ended the day before (cost $9.99) and PR #499 was merged the day before.
xinit() {
	xs=$xroot/$1 xnew=''
	rm -rf "$xs"; mkdir -p "$xs/node/X01" "$xs/node/X02" "$xs/node/X03" "$xs/node/X04"
	xclean
	python3 -I -c "
import json
mk = lambda n, t: {'number': n, 'title': t, 'body': '', 'labels': [], 'state': 'open', 'node_id': 'I_%d' % n}
issues = {str(n): mk(n, 'Unit X0%d' % (n - 60)) for n in range(61, 65)}
pr = {'number': 502, 'head': {'ref': 'node/X03-three', 'sha': 'x3sha'}, 'created_at': '2026-04-10T10:00:00Z', 'html_url': 'https://github.com/owner/repo/pull/502'}
json.dump({'issues': issues, 'comments': [], 'labels': ['noodlebot-status'], 'pulls': [pr], 'checks': {}, 'reactions': [], 'next': 200}, open('$xdb', 'w'))"
	r 2.5 3 >"$xs/node/X01/session.jsonl"
	r 1.25 2 >"$xs/node/X02/session.jsonl"
	r 9.99 9 >"$xs/node/X04/session.jsonl"
	printf '2026-04-10T15:00:00Z second exit (rc 1) with no PR and no QUESTION.md\n' >"$xs/node/X02/FAILED"
	for n in 1 2 3 4; do echo "6$n" >"$xs/node/X0$n/issue"; done
	printf '499 node/X00-old\n501 node/X01-one\n' >"$xs/merged-prs.tsv"
	printf '499\n501\n' >"$xs/merged-prs.txt"
	printf '499 node/X00-old 2026-04-09T12:00:00Z true\n501 node/X01-one 2026-04-10T12:00:00Z true\n' >"$xs/closed-prs.tsv"
	printf '502 node/X03-three x3sha false MERGEABLE\n' >"$xs/open-prs.tsv"
	{
		echo "2026-04-09T22:00:00Z open=[] merged-prs=[X00]; session X04 ended (rc 0)"
		echo "2026-04-10T10:00:00Z open=[X03] merged-prs=[X00]; started X03 (three) in /wt, pid 3, start 1 of 2"
		echo "2026-04-10T12:00:00Z open=[X03] merged-prs=[X00 X01]; session X01 ended (rc 0)"
		echo "2026-04-10T15:00:00Z open=[X03] merged-prs=[X00 X01]; session X02 ended (rc 1), no PR, no QUESTION.md, 2 starts used: wrote FAILED"
	} >"$xs/status.log"
	xrun 2026-04-10T09:00:00; xrun 2026-04-10T09:30:00
	xold=$(xq "L('2026-04-10')[0]['number']")
	xclean
}

# The rollover, clean: the first run on 2026-04-11 and two more.
xinit rollover
ok "U02-AC-4: (before the new date) today's log issue is open and holds no closing summary" test "$(xq "db['issues']['$xold']['state']")$(xq "len([c for c in C($xold) if '3.75' in c['body']])")" = open0
xrun 2026-04-11T00:05:00; xrc=$?
xnew=$(xq "L('2026-04-11')[0]['number']")
xrun 2026-04-11T00:10:00; xrun 2026-04-11T09:00:00; xrc3=$?
xq "'\n----\n'.join(c['body'] for c in C($xold) if '3.75' in c['body'])" >"$tmp/xsum"
xq "C($xnew)[0]['body']" >"$tmp/xfirst"
ok "U02-AC-4: (rollover) the runs on the new date succeed" test "$xrc$xrc3" = 00
ok "U02-AC-4: (rollover) exactly one closing summary is posted on the old log issue (one comment holds the day's cost \$3.75)" test "$(xq "len([c for c in C($xold) if '3.75' in c['body']])")" = 1
ok "U02-AC-4: (rollover) the summary has the day's summed cost of ended sessions (X01 2.50 + X02 1.25)" grep -qF '$3.75' "$tmp/xsum"
ok "U02-AC-4: (rollover) the summary does not count a session that ended the day before (X04 \$9.99)" sh -c "! grep -qF '9.99' '$tmp/xsum'"
ok "U02-AC-4: (rollover) the summary has the PR merged that day (#501) and not the one merged the day before (#499)" sh -c "grep -q '501' '$tmp/xsum' && ! grep -q '499' '$tmp/xsum'"
ok "U02-AC-4: (rollover) the summary has the PR opened that day (#502)" grep -q '502' "$tmp/xsum"
ok "U02-AC-4: (rollover) the summary names the unit that wrote FAILED (X02) on a FAILED line" sh -c "grep FAILED '$tmp/xsum' | grep -q X02"
ok "U02-AC-4: (rollover) the old log issue is closed, once" test "$(xq "db['issues']['$xold']['state']")$(grep -c "^PATCH $xold state=closed" "$tmp/xlog")" = closed1
ok "U02-AC-4: (rollover) the new day's issue is opened once, titled 'noodlebot log 2026-04-11', open and labelled noodlebot-status" test "$(xq "len(L('2026-04-11'))")$(xq "L('2026-04-11')[0]['state']")$(xq "'noodlebot-status' in L('2026-04-11')[0]['labels']")" = 1openTrue
ok "U02-AC-4: (rollover) the new issue links the old one (body or a comment)" test "$(xlinks "$xnew" "$xold")" = True
ok "U02-AC-4: (rollover) a link to the new issue is put on the old one (body or a comment)" test "$(xlinks "$xold" "$xnew")" = True
ok "U02-AC-4: (rollover) pinIssue is tried on the new issue (a GraphQL mutation naming its node id)" sh -c "grep -E '(^|[^n])pinIssue' '$tmp/xgql' | grep -q 'I_$xnew[^0-9]'"
ok "U02-AC-4: (rollover) unpinIssue is tried on the old issue (a GraphQL mutation naming its node id)" sh -c "grep unpinIssue '$tmp/xgql' | grep -q 'I_$xold[^0-9]'"
ok "U02-AC-4: (rollover) over the three runs: one new issue, one close, one pin, one unpin" test "$(xcore | cut -d' ' -f2-3) $(xpins) $(xunpins)" = "1 1 1 1"
ok "U02-AC-4: (rollover) the runs leave nothing on stderr" test ! -s "$tmp/xerr"
ok "U02-AC-4: (F3) the new day's overview (its first comment) is the same summary: the cost \$3.75" grep -qF '$3.75' "$tmp/xfirst"
ok "U02-AC-4: (F3) the overview has the previous day's merged PR (#501) and opened PR (#502)" sh -c "grep -q '501' '$tmp/xfirst' && grep -q '502' '$tmp/xfirst'"
ok "U02-AC-4: (F3) the overview names the unit that wrote FAILED (X02) on a FAILED line" sh -c "grep FAILED '$tmp/xfirst' | grep -q X02"
ok "U02-AC-4: (F3) the overview does not have the merge of the day before (#499) or the cost \$9.99" sh -c "! grep -q '499' '$tmp/xfirst' && ! grep -qF '9.99' '$tmp/xfirst'"
xref=$(xcore)
ok "U02-AC-4: (rollover) (precondition) the reference counts are real (old issue comments, one new issue, one close, new issue comments)" test "$(echo "$xref" | cut -d' ' -f2-3)" = "1 1"

# A failing pin or unpin changes nothing else: everything else is as in the clean rollover.
xcase_gql() { # <name> <regex on the GraphQL body that fails> <what fails>
	xinit "$1"
	printf '%s' "$2" >"$tmp/xgqlfail"
	xrun 2026-04-11T00:05:00
	xnew=$(xq "L('2026-04-11')[0]['number']")
	xrun 2026-04-11T00:10:00; xrun 2026-04-11T09:00:00
	ok "U02-AC-4: ($3 fails) the rest happens as usual: the old issue's comments, the new issue, the close and the new issue's comments are as in the clean rollover" test "$(xcore)" = "$xref"
	ok "U02-AC-4: ($3 fails) the summary is posted once, the old issue is closed, the links are both there" sh -c "[ \"\$1\" = 1 ] && [ \"\$2\" = closed ] && [ \"\$3\" = True ] && [ \"\$4\" = True ]" _ "$(xq "len([c for c in C($xold) if '3.75' in c['body']])")" "$(xq "db['issues']['$xold']['state']")" "$(xlinks "$xnew" "$xold")" "$(xlinks "$xold" "$xnew")"
}
xcase_gql pinfails '(^|[^n])pinIssue' 'pin'
ok "U02-AC-4: (pin fails) pinIssue was tried on the new issue" sh -c "grep -E '(^|[^n])pinIssue' '$tmp/xgql' | grep -q 'I_$xnew[^0-9]'"
ok "U02-AC-4: (pin fails) unpinIssue was still tried on the old issue, once" test "$(xunpins)" = 1
xcase_gql unpinfails 'unpinIssue' 'unpin'
ok "U02-AC-4: (unpin fails) unpinIssue was tried on the old issue" sh -c "grep unpinIssue '$tmp/xgql' | grep -q 'I_$xold[^0-9]'"
ok "U02-AC-4: (unpin fails) pinIssue was still tried on the new issue, once" test "$(xpins)" = 1
xcase_gql bothfail 'pinIssue' 'pin and unpin'
ok "U02-AC-4: (pin and unpin fail) both were tried" test "$(xpins)" -ge 1 -a "$(xunpins)" -ge 1

# A run that fails after a step finishes the rest on the next run, no step repeated: one summary, one close, one new issue,
# one link each way (the pin and the unpin are tried once, and so not again). The run is cut by failing every call from the
# step on; the failure is then removed and three runs follow.
xcase_cut() { # <name> <python condition for the failure to start> <what was done>
	xinit "$1"
	printf '%s' '.' >"$tmp/xfail"
	printf '%s' "$2" >"$tmp/xcond"
	xrun 2026-04-11T00:05:00; xrcc=$?
	ok "U02-AC-4: (cut after $3) (precondition) the first run on the new date fails" test "$xrcc" != 0 -a "$(grep -c '^INJECTED' "$tmp/xlog")" -ge 1
	rm -f "$tmp/xfail" "$tmp/xcond"
	xrun 2026-04-11T00:10:00; xrun 2026-04-11T00:15:00; xrun 2026-04-11T09:00:00
	xnew=$(xq "L('2026-04-11')[0]['number']")
	ok "U02-AC-4: (cut after $3) the next runs finish it: the counts are those of the uninterrupted rollover" test "$(xcore)" = "$xref"
	ok "U02-AC-4: (cut after $3) one closing summary, one close, the old issue closed" test "$(xq "len([c for c in C($xold) if '3.75' in c['body']])")$(grep -c "^PATCH $xold state=closed" "$tmp/xlog")$(xq "db['issues']['$xold']['state']")" = 11closed
	ok "U02-AC-4: (cut after $3) the links both ways are there" sh -c "[ \"\$1\" = True ] && [ \"\$2\" = True ]" _ "$(xlinks "$xnew" "$xold")" "$(xlinks "$xold" "$xnew")"
	ok "U02-AC-4: (cut after $3) pin and unpin were each done once over the runs" test "$(xpins) $(xunpins)" = "1 1"
}
xcase_cut cutsummary "any('3.75' in c['body'] for c in db['comments'] if c['issue'] == '200')" "the summary post"
xcase_cut cutclose "db['issues']['200']['state'] == 'closed'" "the close"
xcase_cut cutnew "any(i['title'] == 'noodlebot log 2026-04-11' for i in db['issues'].values())" "the new issue opens"
xcase_cut cutlink "any(re.search(r'#201\b|/issues/201\b', s) for s in [db['issues']['200']['body']] + [c['body'] for c in db['comments'] if c['issue'] == '200'])" "the link on the old issue"

# The owner closes today's issue: the next run opens a new one for the same day, linked from the closed one.
xinit ownerclose
python3 -I -c "
import json
db = json.load(open('$xdb')); db['issues']['$xold']['state'] = 'closed'; json.dump(db, open('$xdb', 'w'))"
xrun 2026-04-10T10:00:00; xrc=$?
xrun 2026-04-10T10:10:00; xrun 2026-04-10T10:20:00
xnew=$(xq "[i['number'] for i in L('2026-04-10') if i['state'] == 'open'][0]")
ok "U02-AC-4: (owner closes today's issue) the runs succeed" test "$xrc" = 0
ok "U02-AC-4: (owner closes today's issue) a new issue is opened for the same day: two issues for 2026-04-10, one open, one closed" test "$(xq "len(L('2026-04-10'))")$(xq "len([i for i in L('2026-04-10') if i['state'] == 'open'])")" = 21
ok "U02-AC-4: (owner closes today's issue) the new one is not the closed one" test -n "$xnew" -a "$xnew" != "$xold"
ok "U02-AC-4: (owner closes today's issue) the closed issue links the new one (body or a comment)" test "$(xlinks "$xold" "$xnew")" = True
ok "U02-AC-4: (owner closes today's issue) later runs open no third issue" test "$(xq "len(L('2026-04-10'))")" = 2

# U02-AC-5, first deploy (review F2): an open noodlebot-status issue titled like the old sticky one, no log issue. It had
# questions asked on it before the switch (A01 open, A03 answered, A04 closed); A02 and A06 ask on their unit issues.
xdeploy() {
	xs=$xroot/deploy xnew=''
	rm -rf "$xs"; mkdir -p "$xs/node/A01" "$xs/node/A02" "$xs/node/A03" "$xs/node/A04" "$xs/node/A05" "$xs/node/A06"
	xclean
	printf 'Q1: unique-a01-question\n' >"$xs/node/A01/QUESTION.md"
	printf 'Q1: unique-a02-question\n' >"$xs/node/A02/QUESTION.md"
	printf 'Q1: unique-a03-question\n' >"$xs/node/A03/QUESTION.md"
	printf 'A03 first answer\n' >"$xs/node/A03/ANSWER.md"
	printf 'Q1: unique-a06-question\n' >"$xs/node/A06/QUESTION.md"
	for n in 1 2 3 4 5 6; do echo "8$n" >"$xs/node/A0$n/issue"; done
	echo "2026-04-09T20:00:00Z open=[] merged-prs=[]; session A04 ended (rc 0)" >"$xs/status.log"
	python3 -I -c "
import json
mk = lambda n, t, lab: {'number': n, 'title': t, 'body': '', 'labels': lab, 'state': 'open', 'node_id': 'I_%d' % n}
issues = {str(n): mk(n, 'Unit A0%d' % (n - 80), []) for n in range(81, 87)}
issues['70'] = dict(mk(70, 'noodlebot status', ['noodlebot-status']), body='OLD STICKY BODY')
bot = lambda i, n: {'id': i, 'issue': '70', 'body': '## %s asks\n\nQ1: x\n\n---\nTo answer, reply to this issue in plain words. Only owner\'s replies count.\n' % n,
    'user': {'login': 'bot', 'type': 'Bot'}, 'author_association': 'NONE', 'created_at': '2026-04-09T08:00:00Z', 'html_url': 'https://x/old%d' % i}
json.dump({'issues': issues, 'comments': [bot(1, 'A01'), bot(2, 'A03'), bot(3, 'A04')], 'labels': ['noodlebot-status'], 'pulls': [], 'checks': {},
           'reactions': [], 'next': 200}, open('$xdb', 'w'))"
	printf '{"issue": 70, "comment_id": 3, "log_offset": %s, "questions": {"A01": "%s", "A03": "%s", "A04": "1"}, "body_hash": "x", "body_time": 0}\n' \
		"$(wc -c <"$xs/status.log")" "$(stat -c %Y "$xs/node/A01/QUESTION.md")" "$(stat -c %Y "$xs/node/A03/QUESTION.md")" >"$xs/report.json"
}
xdeploy
xrun 2026-04-10T09:00:00; xrc=$?
dc1=$(xq "len(C(70))")
xrun 2026-04-10T09:10:00
echo "2026-04-10T09:15:00Z open=[] merged-prs=[]; session A05 ended (rc 0)" >>"$xs/status.log"
xrun 2026-04-10T09:20:00; xrun 2026-04-10T09:30:00
xlog=$(xq "L('2026-04-10')[0]['number']")
ok "U02-AC-5: (first deploy) the runs succeed" test "$xrc" = 0
ok "U02-AC-5: (first deploy) with the old status issue open, a new 'noodlebot log 2026-04-10' issue is opened, once, open and labelled noodlebot-status" test "$(xq "len(L('2026-04-10'))")$(xq "L('2026-04-10')[0]['state']")$(xq "'noodlebot-status' in L('2026-04-10')[0]['labels']")" = 1openTrue
ok "U02-AC-5: (first deploy) the old status issue (#70) is closed" test "$(xq "db['issues']['70']['state']")" = closed
ok "U02-AC-5: (first deploy) it is closed with exactly one comment linking today's log issue" test "$(xq "len([c for c in C(70) if re.search(r'#%s\b|/issues/%s\b' % ($xlog, $xlog), c['body'])])")" = 1
ok "U02-AC-5: (first deploy) that is the one comment the loop added to it (3 earlier ones, then 4), and the second run added none" test "$dc1 $(xq "len(C(70))")" = "4 4"
ok "U02-AC-5: (first deploy) the old issue's body is not edited" test "$(xq "db['issues']['70']['body']")" = "OLD STICKY BODY" -a "$(grep -c '^PATCH 70 .*keys=.*body' "$tmp/xlog")" = 0
ok "U02-AC-5: (first deploy) the old issue is closed once" test "$(grep -c '^PATCH 70 state=closed' "$tmp/xlog")" = 1
ok "U02-AC-5: (first deploy) an event (A05 ended) is not a comment on the old issue" test "$(xq "len([c for c in C(70) if 'session A05 ended' in c['body']])")" = 0
ok "U02-AC-5: (first deploy) the event is on the log issue instead" test "$(xq "len([c for c in C($xlog) if 'session A05 ended' in c['body']])")" = 1

# A prefixed owner answer on the closed old issue: recorded only while the question it names was posted there and is open.
xowner 70 "A02: not asked here"
xowner 70 "A03: answered already"
xowner 70 "A04: question closed"
xowner 70 "A05: no question"
xrun 2026-04-10T10:05:00; xrc=$?
ok "U02-AC-5: (old issue) answers naming a question not posted there (A02), answered (A03), closed (A04) or absent (A05) are not recorded (exit not 3)" test "$xrc" != 3
ok "U02-AC-5: (old issue) no ANSWER.md for A02, A04, A05, and A03's is unchanged" sh -c "[ ! -e '$xs/node/A02/ANSWER.md' ] && [ ! -e '$xs/node/A04/ANSWER.md' ] && [ ! -e '$xs/node/A05/ANSWER.md' ] && [ \"\$(cat '$xs/node/A03/ANSWER.md')\" = 'A03 first answer' ]"
ok "U02-AC-5: (old issue) A01 is not answered yet" test ! -e "$xs/node/A01/ANSWER.md"
xowner 70 "A01: go left"
xrun 2026-04-10T10:10:00; xrc=$?
ok "U02-AC-5: (old issue) an answer naming A01, whose question was posted there and is open, is recorded: exit 3" test "$xrc" = 3
ok "U02-AC-5: (old issue) A01's ANSWER.md holds the answer" grep -q '^A01: go left$' "$xs/node/A01/ANSWER.md" 2>/dev/null
ok "U02-AC-5: (old issue) the bot replies that it recorded A01's answer" test "$(xq "len([c for c in db['comments'] if \"Recorded as A01\" in c['body']])")" -ge 1
ok "U02-AC-5: (old issue) the earlier refused answers are still not recorded" sh -c "[ ! -e '$xs/node/A02/ANSWER.md' ] && [ ! -e '$xs/node/A04/ANSWER.md' ] && [ ! -e '$xs/node/A05/ANSWER.md' ] && [ \"\$(cat '$xs/node/A03/ANSWER.md')\" = 'A03 first answer' ]"

# A prefixed owner answer on the log issue is recorded as on the status issue before.
xowner "$xlog" "A06: from the log issue"
xrun 2026-04-10T10:15:00; xrc=$?
ok "U02-AC-5: (log issue) a prefixed answer on today's log issue is recorded: exit 3" test "$xrc" = 3
ok "U02-AC-5: (log issue) A06's ANSWER.md holds the answer, with where it came from" sh -c "grep -q '^A06: from the log issue\$' '$xs/node/A06/ANSWER.md' && grep -q 'posted by owner on GitHub at 2026-04-10T10:00:00Z' '$xs/node/A06/ANSWER.md'"
ok "U02-AC-5: (log issue) the bot replies that it recorded A06's answer" test "$(xq "len([c for c in db['comments'] if \"Recorded as A06\" in c['body']])")" -ge 1

# U02-AC-6, the README part: "Watching it" links the repository's open noodlebot-status issues, as a stable search URL.
readme=$(cd "$src/.." && pwd -P)/README.md
watching() { awk '/^## Watching it/ { f = 1; next } f && /^## / { f = 0 } f' "$readme"; }
ok "U02-AC-6: README.md has a 'Watching it' section" test -n "$(watching)"
ok "U02-AC-6: it links the open noodlebot-status issues (an issues search URL with label:noodlebot-status and is:open)" sh -c "$(printf '%s' "watching() { awk '/^## Watching it/ { f = 1; next } f && /^## / { f = 0 } f' '$readme'; }; watching | grep -oE 'https://github\\.com/[^ )>]*/issues\\?[^ )>]*' | grep -E 'label(:|%3A)noodlebot-status' | grep -Eq 'is(:|%3A)open'")"

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: all report checks"
