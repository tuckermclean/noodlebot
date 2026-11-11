#!/bin/sh
# S08 harness: the conformance suite for scheduler/harness.py and its backends (the Claude Code backend over the
# fake claude of testdata/lib/, and the fake harness of testdata/harness/). The contract is fixed in the header of
# testdata/harness/fake.py. Covers S08-AC-1 (the README's inventory), S08-AC-2 (start and resume, the credential),
# S08-AC-3 (the recorded raw logs and the rebuild) and S08-AC-8 (the README's table across harnesses).
# Every missing piece is a FAIL line of its own; the file runs to its end whatever is missing.
src=$(cd "$(dirname "$0")" && pwd)
. "$src/testdata/lib/common.sh"
fx=$src/testdata/harness
readme=$src/harnesses/README.md
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
unset USAGE_7D_MARGIN NOODLEBOT_DATA NOODLEBOT_VERSION SCHED_HARNESS FAKE_HARNESS_SCRIPT FAKE_HARNESS_RESUME_SCRIPT \
	FAKE_HARNESS_RC FAKE_HARNESS_RESUME_RC FAKE_HARNESS_CAPS FAKE_HARNESS_PREFLIGHT FAKE_HARNESS_LOG

tok=tok-SECRET-4711
home=$tmp/home; mkdir -p "$home/.config/noodlebot" "$tmp/wt" "$tmp/bin" "$tmp/nohome"
printf '%s\n' "$tok" >"$home/.config/noodlebot/oauth-token"
ln -s "$src/testdata/lib/fake-claude.sh" "$tmp/bin/claude"

# ck <name> <command...>: PASS when the command succeeds.
ck() { n=$1; shift; if "$@" >"$tmp/ck.out" 2>&1; then pass "$n"; else fail "$n"; head -n 4 "$tmp/ck.out" | sed 's/^/    /'; fi; }
hcli() { HOME=$home python3 -I "$src/harness.py" "$@"; }
# sub <expected events> <actual events>: the expected fields are all there, the same number of events.
sub() { python3 -I "$fx/subset.py" "$1" "$2"; }
has() { grep -qxF -- "$2" "$1"; }
# nolines <text> <file>: the file exists and does not hold the text.
nolines() { test -e "$2" && ! grep -qF -- "$1" "$2"; }
types() { python3 -I -c '
import json, sys
print(" ".join(json.loads(l)["type"] for l in open(sys.argv[1]) if l.strip()))' "$1"; }

# sess <backend> <state dir> <stream file> <exit code> [<session id>]: run-session.sh as the loop runs it (stdout to
# session.jsonl, stderr to session.stderr, appended), with the fake claude on PATH, a fake HOME and a forge token in
# the environment. $rec is the fake claude's record folder, $errf its stderr file. For the Claude Code backend
# (backend ""), the credential file is a FIFO fed once: a second read of it blocks and the run times out.
sess() {
	b=$1 d=$2 stream=$3 rc=$4 sid=${5:-}
	mkdir -p "$d" "$rec"
	echo "the system prompt" >"$d/unattended.md"; echo "the resume prompt" >"$d/resume-prompt.md"
	f=$home/.config/noodlebot/oauth-token wp=
	if [ -z "$b" ]; then rm -f "$f"; mkfifo "$f"; ( printf '%s\n' "$tok" >"$f" ) & wp=$!; fi
	env HOME="$home" PATH="$tmp/bin:$PATH" ${b:+SCHED_HARNESS=$b} FAKE_CLAUDE_REC="$rec" FAKE_CLAUDE_STREAM="$stream" \
		FAKE_CLAUDE_STDERR="${errf:-}" FAKE_CLAUDE_RC="$rc" GH_TOKEN=ghx ANTHROPIC_API_KEY=ak \
		timeout -k 1 10 bash "$src/run-session.sh" "$tmp/wt" "$d" "/node B03" $sid >>"$d/session.jsonl" 2>>"$d/session.stderr"
	SESS_RC=$?
	if [ -n "$wp" ]; then kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null; rm -f "$f"; printf '%s\n' "$tok" >"$f"; fi
}
# call <n> <argv file>: the arguments of the n-th call of the fake claude.
call() { awk -v n="$1" '/^--- call/ { i++; next } i == n' "$2"; }

echo "== S08-AC-1: the README's inventory of call sites, and the interface exporting each operation"
ck "S08-AC-1: scheduler/harnesses/README.md exists" test -s "$readme"
inv=$tmp/inventory
awk '/^## /{ on = ($0 ~ /^## Inventory/) } on && /^\|/ && NF' "$readme" 2>/dev/null >"$inv"
# rows: | Call site | What it does | What it reads | Operation |  (header and separator rows have no backticked operation)
awk -F'|' '$5 ~ /`/' "$inv" >"$tmp/inv.rows"
ck "S08-AC-1: the inventory (a '## Inventory' table) has at least 10 call sites" sh -c "[ \$(wc -l <'$tmp/inv.rows') -ge 10 ]"
ck "S08-AC-1: every inventory row says what it reads" sh -c "[ -s '$tmp/inv.rows' ] && awk -F'|' '\$4 !~ /[A-Za-z]/ { exit 1 }' '$tmp/inv.rows'"
for f in loop.sh loops.sh status.sh run-session.sh usage.py api.py report.py site.py; do
	ck "S08-AC-1: the inventory lists a call site in $f" grep -q "$f" "$tmp/inv.rows"
done
awk -F'|' '{ print $5 }' "$tmp/inv.rows" | grep -o '`[a-z_]*`' | tr -d '`' | sort -u >"$tmp/ops.listed"
for op in start resume skill_command matches preflight events capabilities; do
	ck "S08-AC-1: the inventory lists the operation $op" has "$tmp/ops.listed" "$op"
done
for op in $(cat "$tmp/ops.listed"); do
	ck "S08-AC-1: the listed operation $op is exported by harness.py (a function of that name)" \
		python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import harness; sys.exit(0 if callable(getattr(harness, sys.argv[2], None)) else 1)' "$src" "$op"
done

echo "== S08-AC-8: the README's table across harnesses"
for row in op:start op:resume op:skill_command op:matches op:preflight op:events op:capabilities \
	event:start event:usage event:tool event:tool_result event:text event:result event:task_done event:cutoff event:other event:garbled; do
	ck "S08-AC-8: row \`$row\` has Claude Code, Codex, Pi and OpenCode cells, filled and linked" sh -c "
		grep -E '^\\| *\`$row\` *\\|' '$readme' | head -n 1 |
		awk -F'|' 'NF >= 7 { ok = 1; for (i = 3; i <= 6; i++) if (\$i !~ /[A-Za-z]/ || \$i !~ /\\]\\(https?:\\/\\/[^ )]+\\)/) ok = 0 } END { exit !(NR && ok) }'"
done
ck "S08-AC-8: the table has a header naming the four harnesses" sh -c "grep -E '^\\|.*Claude Code.*\\|.*Codex.*\\|.*Pi.*\\|.*OpenCode' '$readme'"

echo "== operations through the CLI (S08-AC-2 / change 2)"
ck "S08-AC-2: skill-command (Claude Code) is /noodlebot:node B03" sh -c "[ \"\$(HOME='$home' python3 -I '$src/harness.py' skill-command node B03)\" = '/noodlebot:node B03' ]"
ck "S08-AC-2: skill-command with a shipped skill (Claude Code) is /node B03" sh -c "[ \"\$(HOME='$home' python3 -I '$src/harness.py' skill-command node B03 shipped)\" = '/node B03' ]"
ck "S08-AC-2: matches (Claude Code) a run-session.sh command line" hcli matches B03 "bash /x/scheduler/run-session.sh /w/B03 /s/node/B03 /node B03 "
ck "S08-AC-2: matches (Claude Code) a bare claude -p /node line" hcli matches B03 "claude -p /node B03"
ck "S08-AC-2: matches (Claude Code) not another unit" sh -c "! HOME='$home' python3 -I '$src/harness.py' matches B03 'bash /x/scheduler/run-session.sh /w /s /node B030' && HOME='$home' python3 -I '$src/harness.py' matches B03 'bash /x/scheduler/run-session.sh /w /s /node B03 '"
ck "S08-AC-2: preflight (Claude Code) passes with the credential file" hcli preflight
ck "S08-AC-2: preflight (Claude Code) fails with a message when there is no credential file" sh -c "HOME='$tmp/nohome' python3 -I '$src/harness.py' preflight 2>'$tmp/pf.err'; [ \$? = 1 ] && [ -s '$tmp/pf.err' ]"
caps() { c=$(env "$@" HOME="$home" python3 -I "$src/harness.py" capabilities 2>/dev/null) || { echo ERROR; return; }; echo "${c:-none}" | sort | paste -sd, -; }
ck "S08-AC-2: capabilities (Claude Code): bg-wait,resume,usage" sh -c "[ \"$(caps)\" = bg-wait,resume,usage ]"
ck "S08-AC-2: capabilities (fake, default): bg-wait,resume,usage" sh -c "[ \"$(caps SCHED_HARNESS=fake)\" = bg-wait,resume,usage ]"
ck "S08-AC-2: capabilities (fake without usage): bg-wait,resume" sh -c "[ \"$(caps SCHED_HARNESS=fake FAKE_HARNESS_CAPS=resume,bg-wait)\" = bg-wait,resume ]"
ck "S08-AC-2: capabilities (fake without resume): bg-wait,usage" sh -c "[ \"$(caps SCHED_HARNESS=fake FAKE_HARNESS_CAPS=usage,bg-wait)\" = bg-wait,usage ]"
ck "S08-AC-2: capabilities (fake without bg-wait): resume,usage" sh -c "[ \"$(caps SCHED_HARNESS=fake FAKE_HARNESS_CAPS=usage,resume)\" = resume,usage ]"
ck "S08-AC-2: capabilities (fake with none): nothing" sh -c "[ \"$(caps SCHED_HARNESS=fake FAKE_HARNESS_CAPS=)\" = none ]"
ck "S08-AC-2: skill-command (fake) names the skill and its argument" sh -c "SCHED_HARNESS=fake HOME='$home' python3 -I '$src/harness.py' skill-command node B03 | grep -q 'node.*B03'"
ck "S08-AC-2: matches (fake) a run-session.sh line, not another unit" sh -c "export SCHED_HARNESS=fake HOME='$home'; python3 -I '$src/harness.py' matches B03 'bash /x/run-session.sh /w /s /node B03' && ! python3 -I '$src/harness.py' matches B03 'bash /x/run-session.sh /w /s /node B030'"
ck "S08-AC-2: preflight (fake) passes, and fails when configured to" sh -c "export SCHED_HARNESS=fake HOME='$home'; python3 -I '$src/harness.py' preflight && ! FAKE_HARNESS_PREFLIGHT=fail python3 -I '$src/harness.py' preflight"

echo "== S08-AC-2: a start and a resume, Claude Code over the fake claude, and the fake harness"
rec=$tmp/rec-cc errf=; d=$tmp/cc
sess "" "$d" "$fx/resumed-1.jsonl" 1
ck "S08-AC-2: the start finished in time (the credential file was read once)" test "$SESS_RC" = 1
ck "S08-AC-2: Claude Code start wrote session.rc 1 (the claude exit code)" sh -c "[ \"\$(cat '$d/session.rc' 2>/dev/null)\" = 1 ]"
ck "S08-AC-2: no session.rc.tmp left behind" test ! -e "$d/session.rc.tmp"
ck "S08-AC-2: Claude Code start: events are the script's" sub "$fx/resumed-1.events" "$d/events.jsonl"
ck "S08-AC-2: Claude Code start keeps today's claude command line (-p prompt, stream-json, plugin, system prompt, no --resume)" sh -c "
	a='$tmp/cc.argv1'; awk '/^--- call/ { i++; next } i == 1' '$rec/argv' >\$a
	grep -qx -- '-p' \$a && grep -qx -- '/node B03' \$a && grep -qx -- 'stream-json' \$a && grep -qx -- '--plugin-dir' \$a &&
	grep -qx -- '--append-system-prompt' \$a && grep -qx -- 'the system prompt' \$a && ! grep -qx -- '--resume' \$a"
sess "" "$d" "$fx/resumed-2.jsonl" 0 sess-res-1
ck "S08-AC-2: the resume finished in time (the credential file was read once)" test "$SESS_RC" = 0
ck "S08-AC-2: Claude Code resume wrote session.rc 0" sh -c "[ \"\$(cat '$d/session.rc' 2>/dev/null)\" = 0 ]"
ck "S08-AC-2: Claude Code resume: claude -p <resume prompt> --resume <id>" sh -c "
	call 2 >/dev/null 2>&1; a='$tmp/cc.argv2'; awk '/^--- call/ { i++; next } i == 2' '$rec/argv' >\$a
	grep -qx -- '--resume' \$a && grep -qx -- 'sess-res-1' \$a && grep -qx -- 'the resume prompt' \$a"
ck "S08-AC-2: Claude Code start then resume: the events of both scripts" sub "$fx/resumed.events" "$d/events.jsonl"
ck "S08-AC-2: the credential reached claude's environment at each start and resume, and the ceiling defaults to 0" sh -c "
	[ \"\$(grep -c '^CLAUDE_CODE_OAUTH_TOKEN=$tok\$' '$rec/env')\" = 2 ] && [ \"\$(grep -c '^CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0\$' '$rec/env')\" = 2 ]"
ck "S08-AC-2: forge and API tokens are not in claude's environment" sh -c "! grep -E '^(GH_TOKEN|ANTHROPIC_API_KEY)=.' '$rec/env'"
for p in "$d/events.jsonl" "$d/session.jsonl" "$d/session.stderr" "$rec/argv"; do
	ck "S08-AC-2: the credential is not in $(basename "$p") (Claude Code)" nolines "$tok" "$p"
done
ck "S08-AC-2: an explicit SCHED_HARNESS=claude-code is the same backend" sh -c "[ \"\$(SCHED_HARNESS=claude-code HOME='$home' python3 -I '$src/harness.py' skill-command node B03)\" = '/noodlebot:node B03' ]"

d=$tmp/fk; rec=$tmp/rec-fk
export FAKE_HARNESS_LOG=$tmp/fake.log
FAKE_HARNESS_SCRIPT=$fx/resumed-1.events FAKE_HARNESS_RC=1 sess fake "$d" /dev/null 99
ck "S08-AC-2: fake start wrote session.rc 1 (its chosen exit code)" sh -c "[ \"\$(cat '$d/session.rc' 2>/dev/null)\" = 1 ]"
ck "S08-AC-2: fake start: events are the script's" sub "$fx/resumed-1.events" "$d/events.jsonl"
FAKE_HARNESS_SCRIPT=$fx/resumed-1.events FAKE_HARNESS_RESUME_SCRIPT=$fx/resumed-2.events FAKE_HARNESS_RC=1 FAKE_HARNESS_RESUME_RC=0 sess fake "$d" /dev/null 99 sess-res-1
ck "S08-AC-2: fake resume wrote session.rc 0" sh -c "[ \"\$(cat '$d/session.rc' 2>/dev/null)\" = 0 ]"
ck "S08-AC-2: fake start then resume: the events of both scripts" sub "$fx/resumed.events" "$d/events.jsonl"
ck "S08-AC-2: the fake was started and resumed with the session id and the resume prompt" sh -c "grep -q '^start $d /node B03' '$tmp/fake.log' && grep -q '^resume $d sess-res-1 the resume prompt' '$tmp/fake.log'"
ck "S08-AC-2: Claude Code and the fake harness give the same events for the same script (the same types in the same order)" sh -c "
	[ -s '$tmp/cc/events.jsonl' ] && [ \"\$(python3 -I -c 'import json,sys; print([json.loads(l)[\"type\"] for l in open(sys.argv[1])])' '$tmp/cc/events.jsonl')\" = \"\$(python3 -I -c 'import json,sys; print([json.loads(l)[\"type\"] for l in open(sys.argv[1])])' '$d/events.jsonl')\" ]"
for p in "$d/events.jsonl" "$d/session.jsonl" "$d/session.stderr"; do
	ck "S08-AC-2: the credential is not in $(basename "$p") (fake)" nolines "$tok" "$p"
done
unset FAKE_HARNESS_LOG

echo "== S08-AC-3: the recorded raw logs, live and rebuilt"
# live <name> <fixture events name>: run the fixture through run-session.sh, then rebuild its events from a copy of
# the raw log with no events file, and check both.
check_log() {
	f=$1; exp=$2; d=$tmp/live-$f; rec=$tmp/rec-$f; rb=$tmp/rb-$f
	hcli events "$tmp/none-$f" >/dev/null 2>&1   # (nothing to rebuild from: must not crash the suite)
	ck "S08-AC-3: $f: the raw log is the claude stream, untouched" cmp "$d/session.jsonl" "$tmp/raw-$f"
	ck "S08-AC-3: $f: the events written while the session ran" sub "$exp" "$d/events.jsonl"
	mkdir -p "$rb"; cp "$d/session.jsonl" "$rb/"; [ ! -e "$d/session.stderr" ] || cp "$d/session.stderr" "$rb/"
	hcli events "$rb" >"$tmp/rb-$f.out" 2>"$tmp/rb-$f.err"
	ck "S08-AC-3: $f: events rebuilt from the raw log alone give the same events" sub "$exp" "$rb/events.jsonl"
	ck "S08-AC-3: $f: the rebuilt events.jsonl equals the live one (whole file)" cmp "$d/events.jsonl" "$rb/events.jsonl"
	ck "S08-AC-3: $f: events() prints events.jsonl" cmp "$rb/events.jsonl" "$tmp/rb-$f.out"
}
runlog() {   # <name> <fixture> <rc> [<stderr fixture>]
	errf=${4:-}; cp "$fx/$2" "$tmp/raw-$1"; sess "" "$tmp/live-$1" "$fx/$2" "$3"
}
rec=$tmp/rec-n; runlog normal normal.jsonl 0;      check_log normal "$fx/normal.events"
rec=$tmp/rec-l; runlog limit limit.jsonl 1;        check_log limit "$fx/limit.events"
rec=$tmp/rec-i; runlog idle idle.jsonl 143;        check_log idle "$fx/idle.events"
rec=$tmp/rec-t; runlog truncated truncated.jsonl 0; check_log truncated "$fx/truncated.events"
rec=$tmp/rec-m; runlog malformed malformed.jsonl 0; check_log malformed "$fx/malformed.events"
rec=$tmp/rec-c; runlog cutoff cutoff.jsonl 0 "$fx/cutoff.stderr"; check_log cutoff "$fx/cutoff.events"
# a resumed log: a start (limit exit), then a resume appended to the same log
rec=$tmp/rec-r; errf=; cat "$fx/resumed-1.jsonl" "$fx/resumed-2.jsonl" >"$tmp/raw-resumed"
sess "" "$tmp/live-resumed" "$fx/resumed-1.jsonl" 1; sess "" "$tmp/live-resumed" "$fx/resumed-2.jsonl" 0 sess-res-1
check_log resumed "$fx/resumed.events"
ck "S08-AC-3: truncated: the cut last line is the last event (the last line is unknown)" sh -c "[ \"\$(tail -n 1 '$tmp/live-truncated/events.jsonl' | grep -c '\"garbled\"')\" = 1 ]"
ck "S08-AC-3: cutoff: no cutoff event without the stderr line (the normal log)" sh -c "[ -s '$tmp/live-normal/events.jsonl' ] && ! grep -q '\"cutoff\"' '$tmp/live-normal/events.jsonl'"

# a log over 400 KB: the init line lies before the last 400 KB, the limit at the end
python3 -I - "$tmp" <<'PYEOF'
import json, sys
tmp = sys.argv[1]
raw = [{"type": "system", "subtype": "init", "session_id": "sess-big-1", "timestamp": "2026-11-09T18:00:00Z"}]
exp = [{"t": "2026-11-09T18:00:00Z", "type": "start", "session": "sess-big-1"}]
for i in range(1200):
    t = "chunk %04d " % i + "x" * 380
    raw.append({"type": "assistant", "timestamp": "2026-11-09T18:01:00Z", "message": {"content": [{"type": "text", "text": t}]}})
    exp.append({"t": "2026-11-09T18:01:00Z", "type": "text", "text": t, "subagent": False})
raw.append({"type": "rate_limit_event", "timestamp": "2026-11-09T18:02:00Z", "rate_limit_info": {"status": "rejected", "resetsAt": 1795100000, "rateLimitType": "five_hour"}})
exp.append({"t": "2026-11-09T18:02:00Z", "type": "usage", "status": "rejected", "reset": 1795100000, "window": "five_hour"})
raw.append({"type": "result", "subtype": "success", "timestamp": "2026-11-09T18:02:01Z", "is_error": True, "result": "You've hit your limit", "total_cost_usd": 9.5, "num_turns": 40})
exp.append({"t": "2026-11-09T18:02:01Z", "type": "result", "subtype": "success", "text": "You've hit your limit", "cost": 9.5, "turns": 40, "limit": True})
open(tmp + "/big.jsonl", "w").write("".join(json.dumps(x) + "\n" for x in raw))
open(tmp + "/big.events", "w").write("".join(json.dumps(x) + "\n" for x in exp))
PYEOF
ck "S08-AC-3: (precondition) the big log is over 400 KB" sh -c "[ \$(wc -c <'$tmp/big.jsonl') -gt 400000 ]"
cp "$tmp/big.jsonl" "$tmp/raw-big"; rec=$tmp/rec-b; errf=; sess "" "$tmp/live-big" "$tmp/big.jsonl" 1; check_log big "$tmp/big.events"

# a rebuild when the events are behind the raw log (a restart, a session started before the node)
d=$tmp/live-normal; rb=$tmp/behind; mkdir -p "$rb"; cp "$d/session.jsonl" "$d/events.jsonl" "$rb/"
printf '%s\n' '{"type":"result","subtype":"success","timestamp":"2026-11-09T09:30:00Z","result":"More.","total_cost_usd":9.5,"num_turns":1}' >>"$rb/session.jsonl"
hcli events "$rb" >/dev/null 2>&1
ck "S08-AC-3: events behind the raw log are rebuilt first (the appended result is the last event)" sh -c "
	[ \"\$(wc -l <'$rb/events.jsonl')\" = \"\$(( \$(wc -l <'$d/events.jsonl') + 1 ))\" ] && tail -n 1 '$rb/events.jsonl' | grep -q '\"cost\": *9.5'"
mkdir -p "$tmp/part"; cp "$d/session.jsonl" "$tmp/part/"; head -n 3 "$d/events.jsonl" >"$tmp/part/events.jsonl"
hcli events "$tmp/part" >/dev/null 2>&1
ck "S08-AC-3: a half-written events.jsonl is rebuilt to the whole" cmp "$d/events.jsonl" "$tmp/part/events.jsonl"

echo "== S08-AC-3: lines that make a naive translator raise, and a reader looking while the session runs"
# The choice (contract: fake.py header, events): a line nested so deeply that it cannot be parsed is a "garbled" event
# (a non-blank line that is no JSON object we can read); a result whose total_cost_usd or num_turns is an integer
# too large for a float is a result event with cost null / turns null (as report.py's num() and whole() reject them).
# The raw log passes through byte-equal, the later lines are still translated, and the rebuild equals the live file.
rec=$tmp/rec-o; runlog overflow overflow.jsonl 0; check_log overflow "$fx/overflow.events"
ck "S08-AC-3: overflow: the session ran to its end (session.rc 0)" sh -c "[ \"\$(cat '$tmp/live-overflow/session.rc' 2>/dev/null)\" = 0 ]"
ck "S08-AC-3: overflow: a later line is still translated (the last event is the 2.5 result)" sh -c "tail -n 1 '$tmp/live-overflow/events.jsonl' | grep -q '\"cost\": *2.5'"
python3 -I - "$tmp" <<'PYEOF'
import json, sys
tmp = sys.argv[1]
n = 100000
raw = ['{"type":"system","subtype":"init","session_id":"sess-deep-1","timestamp":"2026-11-09T11:00:00Z"}',
       "[" * n + "]" * n,
       '{"a":' * n + '"x"' + "}" * n,
       '{"type":"assistant","timestamp":"2026-11-09T11:00:03Z","message":{"content":[{"type":"text","text":"after deep"}]}}',
       '{"type":"result","subtype":"success","timestamp":"2026-11-09T11:00:04Z","total_cost_usd":3.5,"num_turns":4}']
exp = [{"t": "2026-11-09T11:00:00Z", "type": "start", "session": "sess-deep-1"},
       {"t": None, "type": "garbled"}, {"t": None, "type": "garbled"},
       {"t": "2026-11-09T11:00:03Z", "type": "text", "text": "after deep", "subagent": False},
       {"t": "2026-11-09T11:00:04Z", "type": "result", "subtype": "success", "text": None, "cost": 3.5, "turns": 4, "limit": False}]
open(tmp + "/deep.jsonl", "w").write("".join(l + "\n" for l in raw))
open(tmp + "/deep.events", "w").write("".join(json.dumps(e) + "\n" for e in exp))
PYEOF
cp "$tmp/deep.jsonl" "$tmp/raw-deep"; rec=$tmp/rec-dp; errf=; sess "" "$tmp/live-deep" "$tmp/deep.jsonl" 0; check_log deep "$tmp/deep.events"
ck "S08-AC-3: deep: the session ran to its end (session.rc 0)" sh -c "[ \"\$(cat '$tmp/live-deep/session.rc' 2>/dev/null)\" = 0 ]"

# A reader calling events() before the agent has printed anything must not lose the events that follow, nor
# those after later calls: a slow fake claude prints the 12-line normal log in three parts when the test says so.
ln -s "$src/testdata/lib/fake-claude-slow.sh" "$tmp/slowbin-claude"; mkdir -p "$tmp/slowbin"; mv "$tmp/slowbin-claude" "$tmp/slowbin/claude"
sd=$tmp/slow; hs=$tmp/slow-hs; sdir=$tmp/slow-state
mkdir -p "$sd" "$sdir"
head -n 4 "$fx/normal.jsonl" >"$sd/p1"; sed -n 5,8p "$fx/normal.jsonl" >"$sd/p2"; tail -n +9 "$fx/normal.jsonl" >"$sd/p3"
echo "the system prompt" >"$sdir/unattended.md"
# waitfor <timeout in 0.1 s> <command...>: poll for a condition
waitfor() { w=$1; shift; while ! "$@" 2>/dev/null; do w=$((w - 1)); [ "$w" -gt 0 ] || return 1; sleep 0.1; done; }
rawsize() { [ "$(wc -c <"$sdir/session.jsonl")" -ge "$(cat "$sd/p$1.size")" ]; }
sz=0; for i in 1 2 3; do sz=$((sz + $(wc -c <"$sd/p$i"))); echo $sz >"$sd/p$i.size"; done
env HOME="$home" PATH="$tmp/slowbin:$PATH" FAKE_SLOW_DIR="$hs" FAKE_SLOW_PARTS="$sd/p1 $sd/p2 $sd/p3" \
	timeout -k 1 25 bash "$src/run-session.sh" "$tmp/wt" "$sdir" "/node B03" >>"$sdir/session.jsonl" 2>>"$sdir/session.stderr" &
slowpid=$!
ck "S08-AC-3: slow: the agent started and the recorder is up (events.jsonl exists) before anything is printed" waitfor 100 sh -c "[ -e '$hs/started' ] && [ -e '$sdir/events.jsonl' ]"
hcli events "$sdir" >"$tmp/slow-r0.out" 2>"$tmp/slow-r0.err"
: >"$hs/go-1"; waitfor 100 test -e "$hs/done-1"; waitfor 100 rawsize 1
hcli events "$sdir" >"$tmp/slow-r1.out" 2>"$tmp/slow-r1.err"
: >"$hs/go-2"; waitfor 100 test -e "$hs/done-2"; waitfor 100 rawsize 2
hcli events "$sdir" >"$tmp/slow-r2.out" 2>"$tmp/slow-r2.err"
: >"$hs/go-3"
waitfor 200 test -e "$sdir/session.rc"; wait $slowpid
hcli events "$sdir" >"$tmp/slow-r3.out" 2>"$tmp/slow-r3.err"
ck "S08-AC-3: slow: the session finished (session.rc 0)" sh -c "[ \"\$(cat '$sdir/session.rc' 2>/dev/null)\" = 0 ]"
ck "S08-AC-3: slow: the raw log is the claude stream, untouched" cmp "$sdir/session.jsonl" "$fx/normal.jsonl"
ck "S08-AC-3: slow: no event is lost (events.jsonl holds the script's events)" sub "$fx/normal.events" "$sdir/events.jsonl"
ck "S08-AC-3: slow: the last events() call printed all of them" sub "$fx/normal.events" "$tmp/slow-r3.out"
mkdir -p "$tmp/slow-rb"; cp "$sdir/session.jsonl" "$tmp/slow-rb/"; mv "$sdir/events.jsonl" "$tmp/slow-live.events"; rm -f "$sdir/events.pos"
hcli events "$sdir" >/dev/null 2>&1
ck "S08-AC-3: slow: events.jsonl equals the rebuild from the raw log (whole file)" cmp "$tmp/slow-live.events" "$sdir/events.jsonl"

echo
[ "$fails" = 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed"; exit 1
