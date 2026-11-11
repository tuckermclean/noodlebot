#!/bin/bash
# P03: the loop logs and removes the API's request records, and consumes node/<ID>/RELEASE. Part of the end-to-end test of
# scheduler/loop.sh; the block below is P03's block of the former single loop.test.sh, unchanged (D03 split that file into parts).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"

# the fake gh of the P03 loops reads its stdin on a /labels call; a foreground loop must not inherit the caller's open stdin
exec </dev/null
# ---- P03: the loop logs and removes the API's request records, and consumes node/<ID>/RELEASE ----
# A loop run of its own (o/pthree, 1 s tick, the real throttle) over its own remote and fixture. Nodes: R0 (FAILED), R1 (ready),
# R2 (dep R0 unmerged), R3 (FAILED), R4 (ready), R5 (FAILED). The fake claude counts its runs per worktree in $P3/runs.<key>;
# R1's exits 0 with nothing (so a second start would show), every other node's writes QUESTION.md. Another repository's log
# holds the throttle: a rejected five_hour window (hold), later an allowed window with a later reset (open).
#   loop A (throttle holding, running): records written while it runs; RELEASE for R1 (ready), R2 (deps unmerged), R3 (FAILED).
#   loop B (~/STOP-pthree present at its start): records present before it starts, created in reverse name order.
#   loop C (throttle open, running): RELEASE for R4 (ready; starts anyway), then R5's FAILED removed with its record.
P3=$tmp/p3; export P3
dp3=$tmp/data-p3; mkdir -p "$P3" "$tmp/bin-p3" "$tmp/nb-p3/scheduler" "$tmp/nb-p3/plugin" "$dp3/repos" "$dp3/state/other/node/Z01"
st3=$dp3/state/pthree; P3_STATE=$st3; export P3_STATE
for f in "$src"/*; do case $f in *.test.sh) ;; *) [ -f "$f" ] && cp "$f" "$tmp/nb-p3/scheduler/" ;; esac; done
[ -f "$src/harness.py" ] && { mkdir -p "$tmp/nb-p3/scheduler/harnesses"; cp "$src/harness.py" "$tmp/nb-p3/scheduler/"; cp "$src"/harnesses/*.py "$tmp/nb-p3/scheduler/harnesses/"; }
git init -q -b main "$tmp/work-p3"; mkdir -p "$tmp/work-p3/docs"
printf 'nodes:\n  - {id: R0, name: r0, deps: []}\n  - {id: R1, name: r1, deps: []}\n  - {id: R2, name: r2, deps: [R0]}\n  - {id: R3, name: r3, deps: []}\n  - {id: R4, name: r4, deps: []}\n  - {id: R5, name: r5, deps: []}\n' >"$tmp/work-p3/docs/graph.yaml"
git -C "$tmp/work-p3" add -A && git -C "$tmp/work-p3" -c user.name=t -c user.email=t@t commit -q -m init
git clone -q --bare "$tmp/work-p3" "$tmp/remote-p3.git"
git clone -q "$tmp/remote-p3.git" "$dp3/repos/pthree"
cat >"$tmp/bin-p3/gh" <<'EOF'
#!/bin/sh
case " $* " in
*"/issues?labels=noodlebot"*) echo '[]' ;;
*"/labels"*) cat >/dev/null; echo '{}' ;;
esac
exit 0
EOF
cat >"$tmp/bin-p3/claude" <<'EOF'
#!/bin/sh
key=$(basename "$(pwd -P)")
n=$(( $(cat "$P3/runs.$key" 2>/dev/null || echo 0) + 1 )); echo $n >"$P3/runs.$key"
case $key in R1) ;; *) echo "Q1: held" >"$P3_STATE/node/$key/QUESTION.md" ;; esac
exit 0
EOF
chmod +x "$tmp/bin-p3/gh" "$tmp/bin-p3/claude"
for i in R0 R1 R2 R3 R4 R5; do mkdir -p "$st3/node/$i"; done
for i in R0 R3 R5; do echo held >"$st3/node/$i/FAILED"; done
mkdir -p "$st3/requests"
p3ok() { local name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
p3wait() { local t=$1 end; shift; end=$(($(date +%s) + t)); while ! "$@"; do [ "$(date +%s)" -lt "$end" ] || return 1; sleep 0.2; done; }
p3runs() { cat "$P3/runs.$1" 2>/dev/null || echo 0; }
p3starts() { cat "$st3/node/$1/starts" 2>/dev/null || echo 0; }
# p3ev <control> <target>: status.log lines naming the control (as a word) and the target
p3ev() { grep -w -- "$1" "$st3/status.log" 2>/dev/null | grep -cF -- "$2"; }
p3evline() { grep -nw -- "$1" "$st3/status.log" 2>/dev/null | grep -F -- "$2" | head -n1 | cut -d: -f1; }
p3has() { [ "$(p3ev "$1" "$2")" -ge 1 ]; }
p3gone() { [ -z "$(ls -A "$st3/requests" 2>/dev/null)" ]; }
# p3rel <ID> <pattern>: status.log lines naming the node and a release (any case) that match <pattern>
p3rel() { grep -F -- "$1" "$st3/status.log" 2>/dev/null | grep -i 'releas' | grep -ciE -- "$2"; }
# p3rec <name> <control> <target>: a request record, written as the API does (temp file, then rename)
p3rec() { printf '{"control": "%s", "target": "%s", "time": "2030-01-01T00:00:00Z"}\n' "$2" "$3" >"$st3/requests/.tmp.$1" && mv "$st3/requests/.tmp.$1" "$st3/requests/$1.json"; }
p3loop() { env -u USAGE_7D_MARGIN -u USAGE_5H_LIMIT NOODLEBOT_DATA=$dp3 PATH=$tmp/bin-p3:$PATH SCHED_REPORT=0 SCHED_TICK=1 SCHED_POLL=0.2 \
	bash "$tmp/nb-p3/scheduler/loop.sh" o/pthree; }
p3win() { printf '{"type":"rate_limit_event","rate_limit_info":{"status":"%s","unifiedWindows":{"five_hour":{"utilization":%s,"resetsAt":%s,"status":"%s"},"seven_day":{"utilization":0.0,"resetsAt":%s,"status":"allowed"}}}}\n' "$1" "$2" "$3" "$1" $(($(date +%s) + 3 * 86400)) >"$dp3/state/other/node/Z01/session.jsonl"; }

# loop A: the throttle holds
p3win rejected 1.0 $(($(date +%s) + 3600))
p3loop >"$tmp/p3-a.out" 2>&1 &
loopa=$!; pids+=("$loopa")
p3wait 10 grep -q 'throttle engaged' "$st3/status.log"
p3ok "P03 (harness): the throttle engages" grep -q 'throttle engaged' "$st3/status.log"
sleep 2
p3ok "P03 (harness): while it holds, the ready R1 and R4 are not started" sh -c "[ '$(p3runs R1)' = 0 ] && [ '$(p3runs R4)' = 0 ]"
# P03-AC-3: five records written while the loop runs, one per control (names in order)
p3rec 20300101T000001Z-000001 delete-failed node/R6
p3rec 20300101T000001Z-000002 delete-failed issue/7
p3rec 20300101T000002Z-000003 stop o/pthree
p3rec 20300101T000002Z-000004 unstop o/pthree
p3rec 20300101T000003Z-000005 release node/R9
p3wait 6 p3gone
p3ok "P03-AC-3: a record written while the loop runs is removed within a few iterations (all five)" p3gone
p3ok "P03-AC-3: delete-failed node/R6 is one status-log event naming the control and the target" test "$(p3ev delete-failed node/R6)" = 1
p3ok "P03-AC-3: delete-failed issue/7 is one status-log event" test "$(p3ev delete-failed issue/7)" = 1
p3ok "P03-AC-3: stop o/pthree is one status-log event" test "$(p3ev stop o/pthree)" = 1
p3ok "P03-AC-3: unstop o/pthree is one status-log event" test "$(p3ev unstop o/pthree)" = 1
p3ok "P03-AC-3: release node/R9 is one status-log event" test "$(p3ev release node/R9)" = 1
p3ok "P03-AC-3: the events come in the records' name order" sh -c "$(declare -f p3evline); st3='$st3'
	a=\$(p3evline delete-failed node/R6); b=\$(p3evline delete-failed issue/7); c=\$(p3evline stop o/pthree); d=\$(p3evline unstop o/pthree); e=\$(p3evline release node/R9)
	[ -n \"\$a\" ] && [ -n \"\$b\" ] && [ -n \"\$c\" ] && [ -n \"\$d\" ] && [ -n \"\$e\" ] && [ \"\$a\" -lt \"\$b\" ] && [ \"\$b\" -lt \"\$c\" ] && [ \"\$c\" -lt \"\$d\" ] && [ \"\$d\" -lt \"\$e\" ]"
p3ok "P03-AC-3: a request record changes no marker: the loop is still running, nothing started" sh -c "kill -0 $loopa && [ '$(p3runs R1)' = 0 ] && [ '$(p3runs R4)' = 0 ]"
# P03-AC-4: RELEASE with the throttle holding: R1 (ready), R2 (a dep unmerged), R3 (FAILED)
date -u +%FT%TZ >"$st3/node/R1/RELEASE"; date -u +%FT%TZ >"$st3/node/R2/RELEASE"; date -u +%FT%TZ >"$st3/node/R3/RELEASE"
p3wait 8 test -e "$P3/runs.R1"
p3ok "P03-AC-4: a RELEASE for a ready node the throttle holds starts it despite the hold" test "$(p3runs R1)" = 1
sleep 4   # several ticks: the throttle still holds, so a second start could only come from the RELEASE
p3ok "P03-AC-4: it starts once: its claude ran once, after three more ticks too" test "$(p3runs R1)" = 1
p3ok "P03-AC-4: the start is counted: starts is 1" test "$(p3starts R1)" = 1
p3ok "P03-AC-4: one status-log event says R1 was released past the throttle" test "$(p3rel R1 'past the throttle')" = 1
p3ok "P03-AC-4: R1's session ended and the next tick started nothing more (one 'started R1' event)" sh -c "[ \"\$(grep -c 'started R1 ' '$st3/status.log')\" = 1 ] && grep -q 'session R1 ended' '$st3/status.log'"
p3ok "P03-AC-4: the RELEASE of the started node is removed" test ! -e "$st3/node/R1/RELEASE"
p3ok "P03-AC-4: a RELEASE for a node with an unmerged dep starts nothing" sh -c "[ '$(p3runs R2)' = 0 ] && [ '$(p3starts R2)' = 0 ]"
p3ok "P03-AC-4: it is logged with its reason (not ready), not as released past the throttle" sh -c "[ \"$(p3rel R2 '.')\" -ge 1 ] && [ \"$(p3rel R2 'past the throttle')\" = 0 ] && [ \"$(p3rel R2 'not ready|dep|merged|state|held|hold|wait|nothing')\" -ge 1 ]"
p3ok "P03-AC-4: a RELEASE for a FAILED node starts nothing" sh -c "[ '$(p3runs R3)' = 0 ] && [ '$(p3starts R3)' = 0 ]"
p3ok "P03-AC-4: it is logged with its reason (FAILED), not as released past the throttle" sh -c "[ \"$(p3rel R3 '.')\" -ge 1 ] && [ \"$(p3rel R3 'past the throttle')\" = 0 ] && [ \"$(p3rel R3 'FAILED|not ready|state|held|hold|nothing')\" -ge 1 ]"
p3ok "P03-AC-4: the RELEASE of the nodes that are not ready are removed at that tick" sh -c "[ ! -e '$st3/node/R2/RELEASE' ] && [ ! -e '$st3/node/R3/RELEASE' ] && [ -e '$st3/node/R3/FAILED' ]"
p3ok "P03-AC-4: the ready node nobody released (R4) is still held by the throttle" test "$(p3runs R4)" = 0
p3ok "P03-AC-3: each record was logged once, still, after all those ticks" sh -c "[ '$(p3ev delete-failed node/R6)' = 1 ] && [ '$(p3ev release node/R9)' = 1 ]"
kill "$loopa"; wait "$loopa" 2>/dev/null
# the harness kill above reaches only the p3loop subshell: end the real loop.sh and wait for it to release loop.lock
p3reap() { pkill -f "$tmp/nb-p3/scheduler/loop.sh" 2>/dev/null; n=0
	while pgrep -f "$tmp/nb-p3/scheduler/loop.sh" >/dev/null 2>&1 && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n+1)); done
	if pgrep -f "$tmp/nb-p3/scheduler/loop.sh" >/dev/null 2>&1; then pkill -9 -f "$tmp/nb-p3/scheduler/loop.sh" 2>/dev/null; sleep 0.3
		pgrep -f "$tmp/nb-p3/scheduler/loop.sh" >/dev/null 2>&1 && { echo "FAIL: P03 harness: $1 loop.sh is still running after kill"; fails=$((fails+1)); }; fi; }
p3reap "loop A"
p3free() { n=0; while ! flock -n "$st3/loop.lock" true 2>/dev/null && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n+1)); done
	flock -n "$st3/loop.lock" true 2>/dev/null || { echo "FAIL: P03 harness: $1 loop.lock still held"; fails=$((fails+1)); }; }
p3free "loop A's"

# loop B: ~/STOP-pthree present at the start; the records made while it was stopped (created in reverse name order)
p3rec 20300101T000003Z-000003 release node/R8
p3rec 20300101T000002Z-000002 unstop o/pthree
p3rec 20300101T000001Z-000001 delete-failed node/R7
touch "$HOME/STOP-pthree"
env -u USAGE_7D_MARGIN -u USAGE_5H_LIMIT NOODLEBOT_DATA=$dp3 PATH=$tmp/bin-p3:$PATH SCHED_REPORT=0 SCHED_TICK=1 SCHED_POLL=0.2 \
	timeout 15 bash "$tmp/nb-p3/scheduler/loop.sh" o/pthree >"$tmp/p3-b.out" 2>&1; rcb=$?
rm -f "$HOME/STOP-pthree"
p3ok "P03-AC-3: a stopped loop (~/STOP-pthree) still exits, rc 0, after the records" sh -c "[ $rcb = 0 ] && [ \"\$(grep -c 'found ~/STOP' '$st3/status.log')\" = 1 ]"
p3ok "P03-AC-3: at the start of a stopped loop each record is logged once (delete-failed node/R7)" test "$(p3ev delete-failed node/R7)" = 1
p3ok "P03-AC-3: at the start of a stopped loop each record is logged once (unstop o/pthree, second time)" test "$(p3ev unstop o/pthree)" = 2
p3ok "P03-AC-3: at the start of a stopped loop each record is logged once (release node/R8)" test "$(p3ev release node/R8)" = 1
p3ok "P03-AC-3: at the start of a stopped loop the records are removed" p3gone
p3ok "P03-AC-3: they are logged in name order, before the loop looks for ~/STOP" sh -c "$(declare -f p3evline); st3='$st3'
	a=\$(p3evline delete-failed node/R7); b=\$(p3evline release node/R8); s=\$(grep -n 'found ~/STOP' '$st3/status.log' | head -n1 | cut -d: -f1)
	u=\$(grep -nw unstop '$st3/status.log' | tail -n1 | cut -d: -f1)
	[ -n \"\$a\" ] && [ -n \"\$b\" ] && [ -n \"\$u\" ] && [ -n \"\$s\" ] && [ \"\$a\" -lt \"\$u\" ] && [ \"\$u\" -lt \"\$b\" ] && [ \"\$b\" -lt \"\$s\" ]"

# loop C: the throttle is open; R4 (ready, nothing started it yet) has a RELEASE; R1 is held again
p3win allowed 0.01 $(($(date +%s) + 7200))
[ "$rcb" -eq 0 ] || head -n 5 "$tmp/p3-b.out" | sed "s/^/  loop B: /"
echo held >"$st3/node/R1/FAILED"
date -u +%FT%TZ >"$st3/node/R4/RELEASE"
p3loop >"$tmp/p3-c.out" 2>&1 &
loopc=$!; pids+=("$loopc")
p3wait 10 test -e "$P3/runs.R4"
sleep 2
p3ok "P03-AC-4: with the throttle open a RELEASE of a ready node starts it once, as the loop would anyway" sh -c "[ '$(p3runs R4)' = 1 ] && [ '$(p3starts R4)' = 1 ] && [ \"\$(grep -c 'started R4 ' '$st3/status.log')\" = 1 ]"
p3ok "P03-AC-4: it is logged with its reason: the throttle was open, not past the throttle" sh -c "[ \"$(p3rel R4 'open')\" = 1 ] && [ \"$(p3rel R4 'past the throttle')\" = 0 ]"
p3ok "P03-AC-4: the RELEASE is removed at that tick" test ! -e "$st3/node/R4/RELEASE"
p3ok "P03-AC-4: R1 (FAILED again) and R2, R3 start nothing: no new session" sh -c "[ '$(p3runs R1)' = 1 ] && [ '$(p3runs R2)' = 0 ] && [ '$(p3runs R3)' = 0 ]"
# P03-AC-3: a node whose FAILED a request removed starts at the next tick
rm "$st3/node/R5/FAILED"; p3rec 20300101T000004Z-000004 delete-failed node/R5
p3wait 8 test -e "$P3/runs.R5"
sleep 2
p3ok "P03-AC-3: the node whose FAILED the request removed starts at the next tick (once, start 1)" sh -c "[ '$(p3runs R5)' = 1 ] && [ '$(p3starts R5)' = 1 ] && [ \"\$(grep -c 'started R5 ' '$st3/status.log')\" = 1 ]"
p3ok "P03-AC-3: its request is one event, logged before the node started" sh -c "$(declare -f p3evline); st3='$st3'
	a=\$(p3evline delete-failed node/R5); b=\$(grep -n 'started R5 ' '$st3/status.log' | head -n1 | cut -d: -f1)
	[ \"\$(grep -w delete-failed '$st3/status.log' | grep -cF node/R5)\" = 1 ] && [ -n \"\$a\" ] && [ -n \"\$b\" ] && [ \"\$a\" -lt \"\$b\" ]"
p3ok "P03-AC-3: that record is removed" p3gone
kill "$loopc"; wait "$loopc" 2>/dev/null
p3reap "loop C"
p3free "loop C's"
# P03-AC-4, round 4: the checks above start with the status line's "open=[..] merged-prs=[..]" prefix, which holds the words
# "open" and "merged"; these look at the release line's own text (everything after the first "; ")
p3own() { grep -F -- "$1" "$st3/status.log" 2>/dev/null | grep -i 'releas' | sed 's/^[^;]*; //'; }
p3ownc() { p3own "$1" | grep -ciE -- "$2"; }
p3ok "P03-AC-4: with the throttle open, one release line names R4 and says the throttle was open (own text, not the status prefix)" test "$(p3ownc R4 'throttle (is |was )?open')" = 1
p3ok "P03-AC-4: that line does not claim nothing was started, a running session, or a release past the throttle" sh -c "[ \"$(p3ownc R4 'throttle (is |was )?open')\" = 1 ] && [ \"$(p3own R4 | grep -iE 'throttle (is |was )?open' | grep -ciE 'nothing started|running session|past the throttle')\" = 0 ]"
p3ok "P03-AC-4: R2's release line gives a not-ready reason in its own text" test "$(p3ownc R2 'not ready|dep')" -ge 1
p3ok "P03-AC-4: R3's release line gives a FAILED / not-ready reason in its own text" test "$(p3ownc R3 'FAILED|not ready')" -ge 1
# SCHED_MAX 1 reached by D1's running session; D2 is ready and released, the throttle is open
dp4=$tmp/data-p4; st4=$dp4/state/pfour; mkdir -p "$tmp/bin-p4" "$dp4/repos" "$st4/node/D1" "$st4/node/D2"
git init -q -b main "$tmp/work-p4"; mkdir -p "$tmp/work-p4/docs"
printf 'nodes:\n  - {id: D1, name: d1, deps: []}\n  - {id: D2, name: d2, deps: []}\n' >"$tmp/work-p4/docs/graph.yaml"
git -C "$tmp/work-p4" add -A && git -C "$tmp/work-p4" -c user.name=t -c user.email=t@t commit -q -m init
git clone -q --bare "$tmp/work-p4" "$tmp/remote-p4.git"
git clone -q "$tmp/remote-p4.git" "$dp4/repos/pfour"
cp "$tmp/bin-p3/gh" "$tmp/bin-p4/gh"
cat >"$tmp/bin-p4/claude" <<'EOF'
#!/bin/sh
key=$(basename "$(pwd -P)")
n=$(( $(cat "$P3/runs4.$key" 2>/dev/null || echo 0) + 1 )); echo $n >"$P3/runs4.$key"
case $key in D1) sleep 12 ;; *) echo "Q1: held" >"$P3/q4.$key" ;; esac
exit 0
EOF
chmod +x "$tmp/bin-p4/gh" "$tmp/bin-p4/claude"
date -u +%FT%TZ >"$st4/node/D2/RELEASE"
env -u USAGE_7D_MARGIN -u USAGE_5H_LIMIT NOODLEBOT_DATA=$dp4 PATH=$tmp/bin-p4:$PATH SCHED_REPORT=0 SCHED_TICK=1 SCHED_POLL=0.2 SCHED_MAX=1 \
	bash "$tmp/nb-p3/scheduler/loop.sh" o/pfour >"$tmp/p4.out" 2>&1 &
loopd=$!; pids+=("$loopd")
p3wait 10 test -e "$P3/runs4.D1"
p3wait 8 test ! -e "$st4/node/D2/RELEASE"
sleep 2
p3ok "P03-AC-4 (SCHED_MAX): D1 holds the only session and D2 (ready, released) is not started" sh -c "[ \"\$(cat '$P3/runs4.D1' 2>/dev/null)\" = 1 ] && [ ! -e '$P3/runs4.D2' ]"
p3ok "P03-AC-4 (SCHED_MAX): the RELEASE of D2 is removed" test ! -e "$st4/node/D2/RELEASE"
p3ok "P03-AC-4 (SCHED_MAX): D2's release line gives the session cap as its reason, not 'not ready'" sh -c "l=\$(grep -F D2 '$st4/status.log' | grep -i releas | sed 's/^[^;]*; //'); [ -n \"\$l\" ] && printf '%s\n' \"\$l\" | grep -qiE 'SCHED_MAX|cap|max' && ! printf '%s\n' \"\$l\" | grep -qi 'not ready'"
kill "$loopd"; wait "$loopd" 2>/dev/null
p3reap "loop D"
n=0; while ! flock -n "$st4/loop.lock" true 2>/dev/null && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n+1)); done

loop_end
