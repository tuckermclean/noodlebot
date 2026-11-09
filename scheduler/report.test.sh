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
    out = [i for i in db["issues"].values() if i["state"] == "open"]
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

echo "2026-01-01T00:00:00Z open=[] merged-prs=[]; started A01 (first) in /wt, pid 1, start 1 of 2" >"$state/status.log"
ok "the first run succeeds" run
ok "it creates the label and one status issue" test "$(q "len(db['issues']), db['labels']")" = "(1, ['noodlebot-status'])"
ok "the body lists no question yet" sh -c "! python3 -I -c \"import json; print(json.load(open('$db'))['issues']['100']['body'])\" | grep -q 'asks a question'"
ok "the open node PR without a session is listed" sh -c "python3 -I -c \"import json; print(json.load(open('$db'))['issues']['100']['body'])\" | grep -q 'A01.s PR #7'"
ok "the first run does not replay old events" test "$(q "len(db['comments'])")" = 0

echo "2026-01-01T00:01:00Z open=[] merged-prs=[]; session A01 (pid 1) running, log 5 bytes" >>"$state/status.log"
echo "2026-01-01T00:02:00Z open=[] merged-prs=[]; session A01 ended (rc 0) with QUESTION.md" >>"$state/status.log"
printf 'Q1: which way?\nRecommendation: left.\n' >"$state/node/A01/QUESTION.md"
printf '%s\n' '{"type":"user","message":"a plain string"}' '["not", "an", "object"]' '{"type":"assistant","message":{"content":[{"type":"text","text":"Asking."}]}}' '{"type":"result","subtype":"success","result":"Stopped at step 7: see QUESTION.md."}' >"$state/node/A01/session.jsonl"
run
ok "a session's end carries its closing summary" sh -c "python3 -I -c \"import json; print(json.load(open('$db'))['comments'][0]['body'])\" | grep -q 'Stopped at step 7: see QUESTION.md.'"
ok "a new event is posted, idle lines are not" sh -c "python3 -I -c \"import json; print(json.load(open('$db'))['comments'][0]['body'])\" | head -n 1 | grep -qxF -- '- \`2026-01-01T00:02:00Z\` session A01 ended (rc 0) with QUESTION.md' && ! python3 -I -c \"import json; print(json.load(open('$db'))['comments'][0]['body'])\" | grep -q 'running, log'"
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
ok "a closed status issue is replaced by a new one" test "$(q "db['issues']['101']['state']")" = open

printf '{"windows": {"five_hour": {"utilization": 0.62, "resetsAt": 1800000000, "status": "allowed"}, "seven_day": {"utilization": 0.4, "resetsAt": 1800500000, "status": "allowed"}}, "projected5h": 1.3, "weekElapsed": 0.5, "hold": true, "reason": "5-hour window projected to reach 130%% before it resets (limit 90%%)"}' >"$tmp/state/usage.json"
run
ok "the body shows both windows and the throttle holding" sh -c "python3 -I -c \"import json; print(json.load(open('$db'))['issues']['101']['body'])\" | grep -q '5-hour.* 62%, resets' && python3 -I -c \"import json; print(json.load(open('$db'))['issues']['101']['body'])\" | grep -q 'Throttle:\*\* \*\*holding new sessions\*\*: 5-hour window projected to reach 130%'"
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
open('$tmp/body2', 'w').write(db['issues']['101']['body'])
open('$tmp/comments2', 'w').write('\n'.join(c['body'] for c in db['comments'] if c['issue'] == '101'))"
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
s01body=$(q "[i['body'] for i in db['issues'].values() if i['state'] == 'open'][0]")
ok "S01-AC-4: the FAILED item gives the first line of the FAILED file as the reason" sh -c "printf '%s\n' \"\$1\" | grep -qF 'PR #12 was closed without merging; delete this file to start the node again'" _ "$s01body"
ok "S01-AC-4: and the path to delete" sh -c "printf '%s\n' \"\$1\" | grep 'C05 FAILED' | grep -qF '$state/node/C05/FAILED'" _ "$s01body"
ok "S01-AC-4: and not the fixed text" sh -c "! printf '%s\n' \"\$1\" | grep 'C05 FAILED' | grep -q '2 starts with no PR'" _ "$s01body"
ok "S01-AC-4: and not the file's later lines" sh -c "! printf '%s\n' \"\$1\" | grep -q second-line-detail" _ "$s01body"

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: all report checks"
