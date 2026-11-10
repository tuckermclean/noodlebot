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
body7=$(q "[i['body'] for i in db['issues'].values() if i['state'] == 'open'][0]")
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
n = [i['number'] for i in db['issues'].values() if i['state'] == 'open'][0]
db['comments'].append({'id': len(db['comments']) + 1, 'issue': str(n), 'body': sys.argv[1], 'user': {'login': 'owner', 'type': 'User'},
    'author_association': 'OWNER', 'created_at': '2026-01-09T00:00:00Z', 'html_url': 'https://x/c7'})
json.dump(db, open('$db', 'w'))" "$1"
}
# dump7: the open status issue's body, and every comment of that issue, to files.
dump7() {
	python3 -I -c "
import json
db = json.load(open('$db'))
i = [i for i in db['issues'].values() if i['state'] == 'open'][0]
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

# S05-AC-5: the removed-node events (wording as scheduler/loop.sh writes them: wind_down) are posted in the event comment.
state12=$tmp/state/repo12
mkdir -p "$state12/node/A01"
run12() { python3 -I "$src/report.py" --repo owner/repo --state "$state12" --worktrees "$tmp/worktrees/repo" 2>"$tmp/err12"; }
echo "2026-02-01T00:00:00Z open=[] merged-prs=[]; started A01 (first) in /wt, pid 1, start 1 of 2" >"$state12/status.log"
run12
n12=$(q "len(db['comments'])")
cat >>"$state12/status.log" <<'EOF'
2026-02-01T00:01:00Z R01 removed by #77: closed its PR #21 without merging
2026-02-01T00:01:01Z R01 removed by #77: marked issue #101 not planned
2026-02-01T00:01:02Z R01 removed by #77: removed its worktree and state, evidence kept in state/archive/R01-out
2026-02-01T00:02:00Z R02 removed by 1a2b3c4: closed its PR #22 without merging
2026-02-01T00:02:01Z R03 removed by #77: removed its worktree and state
2026-02-01T00:03:00Z R04 removed by #77: commenting on its PR #23 failed; tried again next tick
2026-02-01T00:03:01Z R04 removed by #77: closing its PR #23 failed; tried again next tick
2026-02-01T00:03:02Z R04 removed by #77: reading issue #5 failed; tried again next tick
2026-02-01T00:03:03Z R04 removed by #77: commenting on issue #5 failed; tried again next tick
2026-02-01T00:03:04Z R04 removed by #77: closing issue #5 failed; tried again next tick
2026-02-01T00:03:05Z R04 removed by #77: its deleted spec could not be read; tried again next tick
2026-02-01T00:03:06Z R04 removed by #77: its session (pid 9) survived SIGKILL; tried again next tick
2026-02-01T00:03:07Z R04 removed by #77: archiving its evidence failed; worktree and state kept, tried again next tick
2026-02-01T00:03:08Z R04 removed by #77: removing its worktree and state failed; tried again next tick
EOF
run12
body12=$(python3 -I -c "
import json
db = json.load(open('$db'))
print('\n'.join(c['body'] for c in db['comments'][$n12:]))")
has12() { printf '%s\n' "$body12" | grep -qF -- "$1"; }
ok "S05-AC-5: the event comment includes 'PR closed' (#N form)" has12 '`2026-02-01T00:01:00Z` R01 removed by #77: closed its PR #21 without merging'
ok "S05-AC-5: the event comment includes 'issues marked not planned'" has12 '`2026-02-01T00:01:01Z` R01 removed by #77: marked issue #101 not planned'
ok "S05-AC-5: the event comment includes 'worktree and state removed'" has12 '`2026-02-01T00:01:02Z` R01 removed by #77: removed its worktree and state, evidence kept in state/archive/R01-out'
ok "S05-AC-5: the PR-closed event of a commit without (#N) is included" has12 '`2026-02-01T00:02:00Z` R02 removed by 1a2b3c4: closed its PR #22 without merging'
ok "S05-AC-5: the worktree-removed event without evidence is included" has12 '`2026-02-01T00:02:01Z` R03 removed by #77: removed its worktree and state'
ok "S05-AC-5: the retry lines of the removed-node step are not posted as events" sh -c "! printf '%s\n' \"\$1\" | grep -qE 'tried again next tick'" _ "$body12"
ok "S05-AC-5: the removed-node events are posted once" sh -c "[ \"\$(printf '%s\n' \"\$1\" | grep -c 'R01 removed by #77')\" = 3 ]" _ "$body12"
ok "S05-AC-5: the removed-node run leaves nothing on stderr" test ! -s "$tmp/err12"

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: all report checks"
