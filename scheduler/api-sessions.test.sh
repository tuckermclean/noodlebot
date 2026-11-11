#!/bin/sh
# Tests scheduler/api.py (node P01), part: sessions and the throttle, deploy, PRs and issues (P01-AC-5, -6, -8).
#   sh scheduler/api-sessions.test.sh   (make test)
# The parts api.test.sh, api-sessions.test.sh, api-events.test.sh, api-fifo.test.sh and api-root2.test.sh run at the same time, each on
# its own copy of the fixture and its own server; the helpers are in testdata/lib/api-common.sh and api-setup.sh.
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d)
. "$src/testdata/lib/api-common.sh"
. "$src/testdata/lib/api-setup.sh"
up=0
if start_server; then up=1; else fail "the server did not start: $(head -c 200 "$tmp/api.out")"; fi
record_all
# ================= P01-AC-5: sessions =================
# S3 contract (fields named once here; the schema "sessions" declares them; read from the loop's session files, never from gh):
#  Resource "sessions"  GET /v1/repos/<owner>/<name>/sessions  ->  {"version":1, "sessions":[<session>...]}: every node/<ID>,
#    issue/<N> and pr/<N> folder of state/<name>/ that has a session.pid (order not specified; [] when none). An unlisted
#    repo is 404, POST is 405. There is no one-session resource.
#  <session> fields: "kind" ("node" | "triage" (issue/<N>) | "update" (pr/<N>)), "subject" (STRING: the node ID, or the
#    issue or PR number as a string, "9"), "pid" (int, session.pid), "alive" (bool, as loop.sh's alive()), "started"
#    (int epoch, session.pid's mtime), "log_size" (int bytes of session.jsonl), "log_modified" (int epoch, its mtime),
#    "events" (list, OLDEST FIRST, the last at most 10 of the log's tool uses and results, in log order; assistant text,
#    tool results, rate_limit_events and system lines are not events), "rc" (int, session.rc, once ended; null/absent while live).
#    An event: {"type": "tool_use"|"result", "time": int epoch of its line, and
#      for tool_use: "tool" (name), "text" (the first line of input.description, else input.command, else input.path or
#        input.file_path, redacted, cut to 200 chars; absent/null when the tool has none of them),
#        "subagent" (true when the line has parent_tool_use_id, i.e. it ran inside a subagent; false/absent otherwise);
#      for result: "subtype" (the result line's subtype)}.
#    "wakeup_at" (int epoch: the time of the last ScheduleWakeup tool use plus its input.delaySeconds, when no later line
#      of the log is an assistant tool use or a result; absent/null otherwise),
#    "bg_commands" and "bg_agents" (lists of {"id": the background ID from the tool result "...ID: <id>", "text": as an
#      event's text}: Bash tool uses with run_in_background, and Agent tool uses with run_in_background, whose ID has no
#      later system/task_notification line with that task_id; absent/null/[] when none),
#    "limit" ({"at": int epoch of the last rate_limit_event whose rate_limit_info.status is not "allowed", "resets_at": its
#      rate_limit_info.resetsAt}; absent/null when none, wherever in the log it sits).
#  Redaction: [redacted] replaces a token-shaped string inside any text served (P01-AC-9).
#  Size: no response carries more than the last 10 events of a log; the test checks a 2000-event log (about 450 KB) against
#    a bound of 60000 bytes for the whole response (at most 10 sessions x 10 events x about 400 bytes is 40 KB).
get P01-AC-5 /v1/repos/acme/alpha/sessions sessions; cp "$tmp/resp" "$tmp/sessions.json"
if [ "$(jx "len(d['sessions']) == 7 and sorted((x['kind'], x['subject']) for x in d['sessions'])")" = "[('node', 'N01'), ('node', 'N03'), ('node', 'N04'), ('node', 'N11'), ('triage', '8'), ('triage', '9'), ('update', '15')]" ]; then pass "P01-AC-5: /sessions gives each of the 7 sessions with a session.pid (and no node without one), by kind and subject"; else fail "P01-AC-5: /sessions kinds and subjects: $(jx "[(x.get('kind'), x.get('subject')) for x in d['sessions']]")"; fi
for k in N03:node N04:node N01:node N11:node 9:triage 8:triage 15:update; do
	sub=${k%%:*}; kind=${k##*:}
	case $kind in node) dir=node/$sub ;; triage) dir=issue/$sub ;; update) dir=pr/$sub ;; esac
	spid=$(cat "$a/$dir/session.pid"); ssize=$(stat -c %s "$a/$dir/session.jsonl"); smt=$(stat -c %Y "$a/$dir/session.jsonl")
	walive=True; [ -f "$a/$dir/session.rc" ] && walive=False
	sess_is $kind $sub "s['pid'] == $spid and s['alive'] is $walive and s['started'] == $(ep 2026-11-09T09:01:00Z)" "has its pid, alive ($walive) and start time (session.pid's mtime)"
	sess_is $kind $sub "s['log_size'] == $ssize and abs(s['log_modified'] - $smt) <= 1" "has its log's size and last write"
done
# node N03: tool uses, a pending ScheduleWakeup, an unfinished command and agent, no limit, still running
sess_is node N03 "len(s['events']) == 10 and [e['tool'] for e in s['events']] == ['Bash', 'Bash', 'Bash', 'Bash', 'Agent', 'Agent', 'Grep', 'Edit', 'Bash', 'ScheduleWakeup'] and all(e['type'] == 'tool_use' and isinstance(e['time'], int) for e in s['events'])" "has the last 10 of its 16 tool uses, oldest first, each with type, tool and time"
sess_is node N03 "[e['text'] for e in s['events'][:8]] == ['Run the tests, round 7', 'Run the tests, round 8', 'Watch CI in the background', 'tail -f build.log', 'Review the diff for style', 'Check the docs', '/w/alpha/N03/scheduler', '/w/alpha/N03/scheduler/x.py']" "gives a tool use's first line of description, else command, else path"
sess_is node N03 "[e['time'] for e in s['events'][:2]] == [$(ep 2026-11-09T09:09:00Z), $(ep 2026-11-09T09:10:00Z)]" "gives each event its time"
sess_is node N03 "[bool(e.get('subagent')) for e in s['events']] == [False] * 6 + [True] + [False] * 3" "marks the tool use that ran inside a subagent"
sess_is node N03 "'[redacted]' in s['events'][8]['text'] and 'sk-ant-api03' not in s['events'][8]['text']" "shows [redacted] where a tool use's description held an API key"
sess_is node N03 "s['wakeup_at'] == $(ep 2026-11-09T09:15:00Z) + 1800" "has the pending ScheduleWakeup time (tool use time plus delaySeconds)"
sess_is node N03 "[c['id'] for c in s['bg_commands']] == ['bg-ci-1'] and s['bg_commands'][0]['text'] == 'Watch CI in the background'" "has the unfinished background command only (bg-tail-2 completed)"
sess_is node N03 "[g['id'] for g in s['bg_agents']] == ['ag-review-1'] and s['bg_agents'][0]['text'] == 'Review the diff for style'" "has the unfinished background agent only (ag-docs-2 completed)"
sess_is node N03 "s.get('limit') is None and s.get('rc') is None" "has no limit rejection (only allowed events) and no rc"
if [ "$(cp "$tmp/sessions.json" "$tmp/resp"; jx "len(d['sessions']) == 7")" = True ] && ! grep -q 'round 2' "$tmp/sessions.json" && ! grep -q 'round 6' "$tmp/sessions.json" && ! grep -q 'N03-running-one' "$tmp/sessions.json" && [ -s "$tmp/sessions.json" ]; then pass "P01-AC-5: N03's early events (rounds 2 to 6, the first Read) appear nowhere in the response"; else fail "P01-AC-5: the response holds events older than the last 10 of N03"; fi
# node N04: live, the log ends with a rejected rate_limit_event
sess_is node N04 "s['limit'] == {'at': $(ep 2026-11-09T10:40:00Z), 'resets_at': 1794236400}" "has its limit rejection and reset time"
sess_is node N04 "[(e['type'], e['tool'], e['text']) for e in s['events']] == [('tool_use', 'Bash', 'Run the tests')] and not s.get('wakeup_at') and not s.get('bg_commands') and not s.get('bg_agents') and s.get('rc') is None" "has one event and no wakeup, background tasks or rc"
# node N01 and N11: ended
sess_is node N01 "[(e['type'], e.get('subtype'), e.get('text')) for e in s['events']] == [('tool_use', None, 'Push'), ('result', 'success', None)] and s['rc'] == 0 and s.get('limit') is None" "ended: its events end in a result with its subtype, and rc is 0"
sess_is node N11 "[(e['type'], e.get('subtype')) for e in s['events']] == [('tool_use', None), ('result', 'error_during_execution')] and s['rc'] == 1" "ended: its result's subtype and rc 1"
sess_is node N11 "s['limit'] == {'at': $(ep 2026-11-09T07:30:00Z), 'resets_at': 1794225600}" "has the last limit rejection although it is not the log's last line"
# triage and update
sess_is triage 9 "s['kind'] == 'triage' and [(e['tool'], e['text'], bool(e.get('subagent'))) for e in s['events']] == [('Bash', 'Read the issue', False), ('Agent', 'Explore the export code', False)] and s.get('rc') is None" "has its events (a token in a tool result is not served)"
sess_is triage 9 "[g['id'] for g in s['bg_agents']] == ['ag-i9-1'] and s['bg_agents'][0]['text'] == 'Explore the export code' and not s.get('bg_commands') and not s.get('wakeup_at')" "has its unfinished background agent"
sess_is triage 8 "[(e['type'], e.get('tool'), e.get('text'), e.get('subtype')) for e in s['events']] == [('tool_use', 'Write', '/w/alpha/issue-8/nodes/Z01-dark-mode.md', None), ('result', None, None, 'success')] and s['rc'] == 0" "ended: its Write path, its result and rc 0"
sess_is update 15 "s['kind'] == 'update' and [e['text'] for e in s['events']] == ['Merge main', 'Run the checker'] and s.get('limit') is None" "has its events"
get P01-AC-5 /v1/repos/acme/beta/sessions sessions
if [ "$(jx "d['sessions']")" = "[]" ]; then pass "P01-AC-5: beta, with no session.pid, has no sessions"; else fail "P01-AC-5: beta's sessions: $(head -c 200 "$tmp/resp")"; fi
err P01-AC-5 GET /v1/repos/acme/ghost/sessions 404
err P01-AC-5 POST /v1/repos/acme/alpha/sessions 405
req GET /v1/schema/sessions
if [ "$code" = 200 ] && [ -f "$schemas/sessions.json" ] && python3 -I -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])) == json.load(open(sys.argv[2])) else 1)' "$tmp/resp" "$schemas/sessions.json" 2>/dev/null; then pass "P01-AC-8: /v1/schema/sessions serves scheduler/api-schema/v1/sessions.json"; else fail "P01-AC-8: /v1/schema/sessions answered $code or differs from the committed schema"; fi

# Two more sessions, made here and removed below (the baseline of the AC-2 snapshot is not re-taken: the folders are gone again
# before the final check): update PR 16 whose ScheduleWakeup was followed by a later tool use, and triage issue 20 with a
# 2000-event log (an early marker, a last event whose first line is 300 characters).
mkdir -p "$a/pr/16" "$a/issue/20"
cat >"$a/pr/16/session.jsonl" <<'EOF'
{"type":"system","subtype":"init","timestamp":"2026-11-09T08:00:00Z"}
{"type":"assistant","timestamp":"2026-11-09T08:01:00Z","message":{"content":[{"type":"tool_use","id":"w1","name":"ScheduleWakeup","input":{"delaySeconds":600,"reason":"wait","prompt":"go on"}}]}}
{"type":"assistant","timestamp":"2026-11-09T08:11:00Z","message":{"content":[{"type":"tool_use","id":"w2","name":"Bash","input":{"command":"git status","description":"Went on after the wakeup"}}]}}
EOF
python3 -I -c '
import json, sys
out = open(sys.argv[1], "w")
out.write(json.dumps({"type": "system", "subtype": "init", "timestamp": "2026-11-09T06:00:00Z"}) + "\n")
for i in range(1, 2001):
    inp = {"command": "EARLYMARKER-%d " % i + "p" * 150 if i <= 5 else "step %d " % i + "q" * 150, "description": "late-%d" % i if i > 1990 else "early-%d" % i}
    if i == 2000:
        inp = {"command": "z" * 300 + "\nSECONDLINE"}
    out.write(json.dumps({"type": "assistant", "timestamp": "2026-11-09T07:%02d:%02dZ" % (i // 60 % 60, i % 60), "message": {"content": [{"type": "tool_use", "id": "x%d" % i, "name": "Bash", "input": inp}]}}) + "\n")
' "$a/issue/20/session.jsonl"
ended "$a/pr/16"; ended "$a/issue/20"
touch -d 2026-11-09T08:00:00Z "$a/pr/16/session.pid" "$a/issue/20/session.pid"
get P01-AC-5 /v1/repos/acme/alpha/sessions sessions; cp "$tmp/resp" "$tmp/sessions.json"
sess_is update 16 "s.get('wakeup_at') is None and [e.get('text') for e in s['events']] == [None, 'Went on after the wakeup'] and s['alive'] is False and s['started'] == $(ep 2026-11-09T08:00:00Z)" "has no pending wakeup when a later tool use shows the session went on"
sess_is triage 20 "len(s['events']) == 10 and [e['text'] for e in s['events'][:9]] == ['late-%d' % i for i in range(1991, 2000)] and s['log_size'] > 300000" "of a 2000-event log has exactly its last 10 events"
sess_is triage 20 "s['events'][9]['text'] == 'z' * 200" "gives the first line of a long command cut to 200 characters"
if [ "$(cp "$tmp/sessions.json" "$tmp/resp"; jx "len(d['sessions']) == 9")" = True ] && ! grep -q 'EARLYMARKER' "$tmp/sessions.json" && ! grep -q 'SECONDLINE' "$tmp/sessions.json" && ! grep -q 'early-' "$tmp/sessions.json"; then pass "P01-AC-5: a marker only in the early events of a long log, and a second line, appear nowhere in the response"; else fail "P01-AC-5: the response holds early events of the 2000-event log or a second line"; fi
sz=$(wc -c <"$tmp/sessions.json")
if [ "$sz" -gt 500 ] && [ "$sz" -lt 60000 ]; then pass "P01-AC-5: the response ($sz bytes) stays under 60000 bytes though a log is about 450 KB"; else fail "P01-AC-5: the response is $sz bytes (want a real answer under 60000)"; fi
rm -rf "$a/pr/16" "$a/issue/20"

# ================= P01-AC-6: throttle, deploy, PRs, issues =================
# S4 contract (fields named once here; the schemas "throttle", "deploy", "prs" and "issues" declare them). Every one of the four
# carries "modified" (int epoch: the mtime of the file it was read from). None is written by the server; none calls gh.
#  Resource "throttle"  GET /v1/throttle  ->  {"version":1, "updated" (int: usage.json's "updated"), "modified" (usage.json's mtime),
#    "five_hour" and "seven_day": {"utilization" (number, as in the file: 0.12), "resets_at" (int, the file's resetsAt), "status"
#    (string)}, "projected_5h" (number, the file's projected5h), "hold" (bool), "reason" (string)}.
#  Resource "deploy"  GET /v1/deploy  ->  {"version":1, "head" (string: the HEAD of the checkout api.py runs from), "previous" (string
#    or null: deploy/previous, trimmed: the rollback point), "rejected" (list of strings: deploy/rejected, one per line),
#    "last_deploy" and "last_failed" (null, or {"repo": "owner/name", "time" (int: the log line's timestamp), "line" (string: the
#    text after the timestamp, redacted)} of the LATEST line over all listed repositories' status.log that starts "deployed "
#    (last_deploy) or "not deployed: " (last_failed)), "modified" (the mtime of deploy/previous)}.
#  Resource "prs"  GET /v1/repos/<owner>/<name>/prs  ->  {"version":1, "prs":[{"number" (int), "branch", "head" (string), "bot"
#    (bool: the tsv's is_bot), "mergeable" (string)}...], "modified" (open-prs.tsv's mtime)}, in file order; unlisted repo 404.
#  Resource "issues"  GET /v1/repos/<owner>/<name>/issues  ->  {"version":1, "issues":[{"number" (int), "title" (string or null),
#    "labelled" (bool or null), "state" (string or null)}...], "modified" (issues.json's mtime)}. An entry exists for each issue of
#    issues.json that is labelled true, and for each state/<name>/issue/<N>/ folder (the union, once per number). title and labelled
#    come from issues.json (null when the issue is not in it); state is "done" (a done marker), else "failed" (FAILED), else
#    "question" (QUESTION.md without ANSWER.md), else "running" (a session.pid whose process is alive); null with no folder.
#    An issue that issues.json lists as labelled false (the owner did not label it) and that has no folder is not listed.
set_usage open
get P01-AC-6 /v1/throttle throttle
chk P01-AC-6 "/v1/throttle gives both windows, the projection, hold and reason (open)" "d['five_hour'] == {'utilization': 0.12, 'resets_at': 1794236400, 'status': 'allowed'} and d['seven_day'] == {'utilization': 0.3, 'resets_at': 1794441600, 'status': 'allowed'} and d['projected_5h'] == 0.3 and d['hold'] is False and d['reason'] == '' and d['updated'] == 1794222000"
chk P01-AC-6 "/v1/throttle carries the mtime of usage.json" "abs(d['modified'] - $(mt "$data/state/usage.json")) <= 1"
set_usage holding
get P01-AC-6 /v1/throttle throttle
chk P01-AC-6 "/v1/throttle follows usage.json while it holds: utilization, projection, hold and reason" "d['five_hour']['utilization'] == 0.93 and d['seven_day']['utilization'] == 0.4 and d['projected_5h'] == 1.7 and d['hold'] is True and d['reason'] == '5-hour window projected to 170% before its reset' and abs(d['modified'] - $(mt "$data/state/usage.json")) <= 1"
set_usage open
err P01-AC-6 POST /v1/throttle 405

# a later deploy line in beta's status log makes beta the repository of the last deploy
printf '2026-11-09T11:30:00Z deployed 4444444..5555555 (version v0.9.2-fixture)\n' >>"$data/state/beta/status.log"
snap >"$tmp/snap.before"   # the test appended to a status log: re-take the AC-2 baseline (as the base did after its appends)
get P01-AC-6 /v1/deploy deploy
chk P01-AC-6 "/v1/deploy gives the live checkout's head (the HEAD of the checkout api.py runs from)" "d['head'] == '$(git -C "$co" rev-parse HEAD)'"
chk P01-AC-6 "/v1/deploy gives the rollback point and the rejected commits" "d['previous'] == '1' * 40 and d['rejected'] == ['2' * 40, '3' * 40] and abs(d['modified'] - $(mt "$data/deploy/previous")) <= 1"
chk P01-AC-6 "/v1/deploy gives the last deploy as the status logs record it (the latest over all repositories)" "d['last_deploy'] == {'repo': 'acme/beta', 'time': $(ep 2026-11-09T11:30:00Z), 'line': 'deployed 4444444..5555555 (version v0.9.2-fixture)'}"
chk P01-AC-6 "/v1/deploy gives the last failed test run as the status logs record it" "d['last_failed'] == {'repo': 'acme/alpha', 'time': $(ep 2026-11-09T09:04:00Z), 'line': 'not deployed: 2222222222222222222222222222222222222222 (version v0.9.1-fixture) fails make test'}"
err P01-AC-6 PUT /v1/deploy 405

get P01-AC-6 /v1/repos/acme/alpha/prs prs
chk P01-AC-6 "alpha's /prs gives number, branch, head, bot and mergeable of each open PR, MERGEABLE and CONFLICTING" "{p['number']: (p['branch'], p['head'], p['bot'], p['mergeable']) for p in d['prs']} == {12: ('node/N02-pr-open-one', 'a' * 40, False, 'MERGEABLE'), 14: ('node/N11-pr-conflict-one', 'b' * 40, False, 'CONFLICTING'), 15: ('spec/triage-9-new-idea', 'c' * 40, True, 'CONFLICTING'), 16: ('spec/triage-8-other', 'd' * 40, True, 'MERGEABLE')} and len(d['prs']) == 4 and [p['number'] for p in d['prs']] == [12, 14, 15, 16]"
chk P01-AC-6 "alpha's /prs carries the mtime of open-prs.tsv" "abs(d['modified'] - $(mt "$data/state/alpha/open-prs.tsv")) <= 1"
get P01-AC-6 /v1/repos/acme/beta/prs prs
chk P01-AC-6 "beta's /prs is empty (its open-prs.tsv is)" "d['prs'] == []"
err P01-AC-6 GET /v1/repos/acme/ghost/prs 404
err P01-AC-6 POST /v1/repos/acme/alpha/prs 405

# two more issue folders, made here and removed below: 30 waits for an answer, 31 failed
mkdir -p "$a/issue/30" "$a/issue/31"
echo "Which format?" >"$a/issue/30/QUESTION.md"; echo "triage failed twice" >"$a/issue/31/FAILED"
get P01-AC-6 /v1/repos/acme/alpha/issues issues
chk P01-AC-6 "alpha's /issues gives the labelled issues of issues.json with title and labelled, and the state of the ones with a folder (8 done, 9 running)" "{i['number']: (i['title'], i['labelled'], i['state']) for i in d['issues'] if i['number'] in (8, 9)} == {8: ('Add a dark mode', True, 'done'), 9: ('Support export to CSV', True, 'running')}"
chk P01-AC-6 "alpha's /issues gives an issue folder with an unanswered QUESTION.md the state question, and one with FAILED the state failed" "{i['number']: i['state'] for i in d['issues'] if i['number'] in (30, 31)} == {30: 'question', 31: 'failed'}"
chk P01-AC-6 "alpha's /issues lists each issue once, and not the issue the owner did not label (10)" "sorted(i['number'] for i in d['issues']) == [8, 9, 30, 31]"
chk P01-AC-6 "alpha's /issues carries the mtime of issues.json" "abs(d['modified'] - $(mt "$data/state/alpha/issues.json")) <= 1"
rm -rf "$a/issue/30" "$a/issue/31"
get P01-AC-6 /v1/repos/acme/alpha/issues issues
chk P01-AC-6 "alpha's /issues drops a folder once it is gone" "sorted(i['number'] for i in d['issues']) == [8, 9]"
get P01-AC-6 /v1/repos/acme/beta/issues issues
chk P01-AC-6 "beta's /issues is empty" "d['issues'] == []"
err P01-AC-6 GET /v1/repos/acme/ghost/issues 404
err P01-AC-6 DELETE /v1/repos/acme/alpha/issues 405
for res in throttle deploy prs issues; do
	req GET /v1/schema/$res
	if [ "$code" = 200 ] && [ -f "$schemas/$res.json" ] && python3 -I -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])) == json.load(open(sys.argv[2])) else 1)' "$tmp/resp" "$schemas/$res.json" 2>/dev/null; then pass "P01-AC-8: /v1/schema/$res serves scheduler/api-schema/v1/$res.json"; else fail "P01-AC-8: /v1/schema/$res answered $code or differs from the committed schema"; fi
done

# ================= P02-AC-6: commits of node sessions, reason, question and issue_url of triage issues =================
# Contract (change 7 of nodes/P02-api-cli.md), fields named once here:
#  A node session in /sessions has "commits": a list of at most 3 objects {"sha": <short SHA, 7 to 12 hex characters>,
#    "subject": <string>}, newest first, from `git log origin/main..HEAD` in $NOODLEBOT_DATA/worktrees/<name>/<ID>; the subject is
#    redacted ([redacted] for a token) and cut to 200 characters. No worktree, or a failing git log: [].
#  An issue in /issues has "reason" (first line of FAILED, redacted), "question" (first line of QUESTION.md, redacted) and
#    "issue_url" (https://github.com/<owner>/<name>/issues/<N>) for a questioned one, as /nodes names them.
# The worktrees are built here at run time (a git repository cannot be a fixture) and removed again below.
wt=$data/worktrees/alpha
tokc=$(sed -n 3p "$fix/tokens.txt")
longsub=$(python3 -I -c 'print("L" * 250)')
mkdir -p "$wt/N03" "$wt/N04"
(
	cd "$wt/N03" || exit 1
	export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
		GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
	git init -q . && git config commit.gpgsign false || exit 1
	n=0
	mk() { n=$((n + 1)); export GIT_AUTHOR_DATE="2026-11-09T10:0$n:00Z" GIT_COMMITTER_DATE="2026-11-09T10:0$n:00Z"; echo "$n" >"f$n"; git add "f$n"; git commit -q -m "$1"; }
	mk "base commit"
	git update-ref refs/remotes/origin/main HEAD
	mk "first ahead"; mk "second ahead"; mk "third has $tokc inside"; mk "$longsub"; mk "fifth and newest"
) >"$tmp/wt-build.log" 2>&1
# N04: a worktree directory that is not a git repository (git log fails); N01, N11: no worktree at all.
echo "not a repository" >"$wt/N04/README"
wt_snap() { (cd "$wt/N03" && find . -type f -exec cksum {} + | sort; find . -name FETCH_HEAD; git status --porcelain 2>&1; git for-each-ref 2>&1); }
wt_snap >"$tmp/wt.before"
full=$(git -C "$wt/N03" rev-list --max-count=5 HEAD 2>/dev/null | tr '\n' ' ')
get P02-AC-6 /v1/repos/acme/alpha/sessions sessions; cp "$tmp/resp" "$tmp/sessions.json"
sessc() { # sessc <ID> <python expr over s> : checks the node session's entry
	cp "$tmp/sessions.json" "$tmp/resp"
	jx "(lambda s: $2)(next(x for x in d['sessions'] if x['kind'] == 'node' and x['subject'] == '$1'))"
}
shas="'$(echo "$full" | cut -d' ' -f1)', '$(echo "$full" | cut -d' ' -f2)', '$(echo "$full" | cut -d' ' -f3)'"
if [ -n "$full" ] && [ "$(sessc N03 "[c['sha'] for c in s['commits']] == [f[:len(c['sha'])] for c, f in zip(s['commits'], [$shas])] and len(s['commits']) == 3 and all(7 <= len(c['sha']) <= 12 for c in s['commits'])")" = True ]; then pass "P02-AC-6: node N03 (5 commits ahead of origin/main) gets 3 commits, newest first, each with a short SHA"; else fail "P02-AC-6: N03's commits are not the 3 newest with short SHAs ($shas): $(sessc N03 "s.get('commits')")"; fi
if [ "$(sessc N03 "[c['subject'] for c in s['commits']][0] == 'fifth and newest'")" = True ]; then pass "P02-AC-6: N03's newest commit comes first, with its subject"; else fail "P02-AC-6: N03's first commit subject: $(sessc N03 "s.get('commits')")"; fi
if [ "$(sessc N03 "all(set(c) >= {'sha', 'subject'} and isinstance(c['subject'], str) for c in s['commits']) and 'first ahead' not in [c['subject'] for c in s['commits']]")" = True ]; then pass "P02-AC-6: N03's commits have sha and subject strings and omit the older commits beyond 3"; else fail "P02-AC-6: N03's commit objects: $(sessc N03 "s.get('commits')")"; fi
if [ "$(sessc N03 "s['commits'][1]['subject'] == 'L' * 200")" = True ]; then pass "P02-AC-6: a commit subject of 250 characters is cut to 200"; else fail "P02-AC-6: the long subject is not cut to 200: $(sessc N03 "[len(c['subject']) for c in s.get('commits', [])]")"; fi
if [ "$(sessc N03 "s['commits'][2]['subject'] == 'third has [redacted] inside'")" = True ] && ! grep -F -q "$tokc" "$tmp/sessions.json"; then pass "P02-AC-6: a token in a commit subject is replaced by [redacted] and appears nowhere in the response"; else fail "P02-AC-6: the token in a commit subject is not redacted: $(sessc N03 "[c['subject'] for c in s.get('commits', [])]")"; fi
if [ "$(sessc N04 "s['commits'] == []")" = True ]; then pass "P02-AC-6: a node session whose worktree is not a git repository (git log fails) gets []"; else fail "P02-AC-6: N04's commits: $(sessc N04 "s.get('commits')")"; fi
if [ "$(sessc N01 "s['commits'] == []")" = True ] && [ "$(sessc N11 "s['commits'] == []")" = True ]; then pass "P02-AC-6: node sessions without a worktree get []"; else fail "P02-AC-6: N01's commits: $(sessc N01 "s.get('commits')"), N11's: $(sessc N11 "s.get('commits')")"; fi
if [ "$(jx "all('commits' not in x or x['kind'] == 'node' for x in d['sessions'])")" = True ] || [ "$(cp "$tmp/sessions.json" "$tmp/resp"; jx "all(x.get('commits', []) == [] for x in d['sessions'] if x['kind'] != 'node')")" = True ]; then pass "P02-AC-6: sessions of other kinds carry no commits"; else fail "P02-AC-6: a triage or update session carries commits"; fi
wt_snap >"$tmp/wt.after"
if cmp -s "$tmp/wt.before" "$tmp/wt.after" && [ -n "$(cat "$tmp/wt.before")" ]; then pass "P02-AC-6: the server wrote nothing in the worktree (files, refs, status unchanged, no FETCH_HEAD)"; else fail "P02-AC-6: the worktree changed: $(diff "$tmp/wt.before" "$tmp/wt.after" | head -n 4 | tr '\n' ' ')"; fi
rm -rf "$data/worktrees"
get P02-AC-6 /v1/repos/acme/alpha/sessions sessions; cp "$tmp/resp" "$tmp/sessions.json"
if [ "$(sessc N03 "s['commits'] == []")" = True ]; then pass "P02-AC-6: once the worktree is gone, N03's commits are []"; else fail "P02-AC-6: N03's commits without a worktree: $(sessc N03 "s.get('commits')")"; fi

# triage issues: 50 failed, 51 waits for an answer, 52 failed with a token on its first line, 53 a question with a token
mkdir -p "$a/issue/50" "$a/issue/51" "$a/issue/52" "$a/issue/53"
printf 'tests do not pass after 2 starts\nsecond line of the reason\n' >"$a/issue/50/FAILED"
printf 'Which format should the export use?\n\nOptions: csv or json.\n' >"$a/issue/51/QUESTION.md"
printf 'push failed with %s\nmore\n' "$tokc" >"$a/issue/52/FAILED"
printf 'Is %s the right key?\nmore\n' "$tokc" >"$a/issue/53/QUESTION.md"
get P02-AC-6 /v1/repos/acme/alpha/issues issues
cp "$tmp/resp" "$tmp/issues.json"
chk P02-AC-6 "a failed triage issue has reason = the first line of its FAILED" "{i['number']: i['reason'] for i in d['issues'] if i['number'] == 50} == {50: 'tests do not pass after 2 starts'}"
chk P02-AC-6 "a questioned triage issue has question = the first line of its QUESTION.md" "{i['number']: i['question'] for i in d['issues'] if i['number'] == 51} == {51: 'Which format should the export use?'}"
chk P02-AC-6 "a questioned triage issue has issue_url https://github.com/acme/alpha/issues/<N>" "{i['number']: i['issue_url'] for i in d['issues'] if i['number'] == 51} == {51: 'https://github.com/acme/alpha/issues/51'}"
chk P02-AC-6 "a token on the first line of FAILED is redacted in reason" "{i['number']: i['reason'] for i in d['issues'] if i['number'] == 52} == {52: 'push failed with [redacted]'}"
chk P02-AC-6 "a token on the first line of QUESTION.md is redacted in question" "{i['number']: i['question'] for i in d['issues'] if i['number'] == 53} == {53: 'Is [redacted] the right key?'}"
if ! grep -F -q "$tokc" "$tmp/issues.json"; then pass "P02-AC-6: the token appears nowhere in the /issues response"; else fail "P02-AC-6: the /issues response holds the token"; fi
chk P02-AC-6 "the state of the new issue entries stays failed / question, the old fields unchanged" "{i['number']: i['state'] for i in d['issues'] if i['number'] >= 50} == {50: 'failed', 51: 'question', 52: 'failed', 53: 'question'} and all(i['version'] == 1 if 'version' in i else True for i in d['issues']) and d['version'] == 1"
rm -rf "$a/issue/50" "$a/issue/51" "$a/issue/52" "$a/issue/53"

quiet_final

[ $fails = 0 ] || { echo "$fails failed"; exit 1; }
echo "all passed"
