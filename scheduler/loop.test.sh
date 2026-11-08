#!/bin/bash
# End-to-end test of scheduler/loop.sh with a fake gh, a fake claude and a local git remote.
# Loop 1 runs with a 30 s GitHub poll, so anything it does within a few seconds was woken by a
# local change: the owner's ANSWER.md, a session exiting. Then loop 1 is stopped with a session
# running, and loop 2 (1 s poll) must take that session over, not start a second one; it carries
# the start count over, writes FAILED, and resumes a node after its spec PR merges.
#   bash scheduler/loop.test.sh   (make test)
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d)
pids=()
# shellcheck disable=SC2154 # p is the trap's own loop variable
trap 'for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done; pkill -f "$tmp/" 2>/dev/null; rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
# ok <name> <command...>: PASS when the command succeeds.
ok() { local name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; echo "      status.log:"; sed 's/^/      /' "$state/status.log" 2>/dev/null; fi; }

export HOME=$tmp/home
nb=$tmp/nb state=$tmp/nb/state/proj
mkdir -p "$HOME/.config/noodlebot" "$tmp/bin" "$nb/scheduler" "$nb/plugin" "$state/node/A02" "$state/node/A03"
cp "$src"/loop.sh "$src"/ready.py "$src"/release-markers.sh "$src"/run-session.sh "$src"/unattended.md \
	"$src"/issues.py "$src"/unattended-triage.md "$nb/scheduler/"
printf '#!/bin/sh\necho fake-token\n' >"$HOME/.config/noodlebot/token"
echo fake-oauth >"$HOME/.config/noodlebot/oauth-token"
chmod +x "$HOME/.config/noodlebot/token"

# The remote: main carries A01 -> (A02, A03).
git init -q -b main "$tmp/work"
mkdir -p "$tmp/work/docs"
printf 'nodes:\n  - {id: A01, name: first-node, deps: []}\n  - {id: A02, name: second-node, deps: [A01]}\n  - {id: A03, name: third-node, deps: [A01]}\n  - {id: A04, name: fourth-node, deps: [A01]}\n  - {id: A05, name: fifth-node, deps: [A01]}\n' >"$tmp/work/docs/graph.yaml"
git -C "$tmp/work" add -A && git -C "$tmp/work" -c user.name=t -c user.email=t@t commit -q -m init
git clone -q --bare "$tmp/work" "$tmp/remote.git"
git clone -q "$tmp/remote.git" "$nb/repos/proj"

# gh: merged PRs come from $tmp/merged.tsv ("<number> <head branch>"), no open PRs. Issues
# labelled noodlebot come from $tmp/issues.json, each labelled by the owner (tuckermclean); label calls are logged
# to $tmp/labels.log, and removing noodlebot empties the list.
echo '[]' >"$tmp/issues.json"
cat >"$tmp/bin/gh" <<EOF
#!/bin/sh
case " \$* " in
*" --state merged "*) cat "$tmp/merged.tsv" ;;
*"/issues?labels=noodlebot"*) cat "$tmp/issues.json" ;;
*"/events"*) echo '[{"event": "labeled", "label": {"name": "noodlebot"}, "actor": {"login": "o"}}]' ;;
*" DELETE "*"/labels/noodlebot"*) echo "\$*" >>"$tmp/labels.log"; echo '[]' >"$tmp/issues.json"; echo '[]' ;;
*"/labels"*) echo "\$*" >>"$tmp/labels.log"; cat >/dev/null; echo '{}' ;;
esac
exit 0
EOF
# claude, per node and run:
#   A02 run 1: opens "spec PR #55" (WAITING-PR). A02 run 2: asks a new question.
#   A03 run 1: runs until $tmp/go exists, exits 3. A03 run 2: exits 0 with nothing.
# Each run logs "<ID> run <n>: <what answered/ holds>" to $tmp/claude.log.
cat >"$tmp/bin/claude" <<EOF
#!/bin/sh
case "\$2" in "/noodlebot:triage "*) echo "triage \${2#/noodlebot:triage }" >>"$tmp/claude.log"; exit 0 ;; esac
id=\${2##* }
n=\$(( \$(cat "$tmp/runs.\$id" 2>/dev/null || echo 0) + 1 )); echo \$n >"$tmp/runs.\$id"
echo "\$id run \$n: \$(ls "$state/node/\$id/answered" 2>/dev/null | sed 's/^[0-9TZ]*-//' | sort | tr '\n' ' ')" >>"$tmp/claude.log"
case \$id.\$n in
A02.1) echo 55 >"$state/node/A02/WAITING-PR" ;;
A02.2) echo "Q1: still open" >"$state/node/A02/QUESTION.md" ;;
A03.1) while [ ! -e "$tmp/go" ]; do sleep 0.2; done; exit 3 ;;
A04.1|A05.1) while [ ! -e "$tmp/go2" ]; do sleep 0.2; done; echo "Q1: parallel" >"$state/node/\$id/QUESTION.md" ;;
esac
exit 0
EOF
chmod +x "$tmp/bin/gh" "$tmp/bin/claude"
export PATH=$tmp/bin:$PATH
echo "1 node/A01-first-node" >"$tmp/merged.tsv"
echo "Q1: which way?" >"$state/node/A02/QUESTION.md"
echo "Q1: as recommended" >"$state/node/A02/ANSWER.md"
echo "Q1: and this?" >"$state/node/A03/QUESTION.md"
mkdir -p "$state/node/A04" "$state/node/A05"; touch "$state/node/A04/FAILED" "$state/node/A05/FAILED"

# within <seconds> <pattern>: a status.log line matches within that time.
within() { timeout "$1" sh -c "until grep -qE \"\$1\" '$state/status.log' 2>/dev/null; do sleep 0.1; done" _ "$2"; }
count() { grep -cE "$1" "$state/status.log"; }
runs() { cat "$tmp/runs.$1" 2>/dev/null || echo 0; }

# A01 is merged and still has a worktree with its evidence.
mkdir -p "$nb/worktrees/proj/A01/out/node/A01" && echo brief >"$nb/worktrees/proj/A01/out/node/A01/brief.md"
SCHED_REPORT=0 SCHED_TICK=30 SCHED_POLL=0.2 bash "$nb/scheduler/loop.sh" o/proj >"$tmp/loop1.out" 2>&1 &
loop1=$!; pids+=("$loop1")
ok "a merged node's worktree is removed" within 10 "A01 merged: removed its worktree, evidence kept in state/archive/A01-out"
ok "its evidence is kept" grep -qx brief "$state/archive/A01-out/brief.md"
ok "an answered question releases the node" within 10 "A02: released the owner's answer"
ok "it starts the answered node" within 5 "started A02 \(second-node\).*start 1 of 2"
ok "a session's exit wakes the loop (well inside the 30 s poll)" within 5 "session A02 ended \(rc 0\) waiting for spec PR #55"
sleep 1
ok "an unmerged spec PR holds the node" test "$(runs A02)" = 1
echo "Q1: yes" >"$state/node/A03/ANSWER.md"
ok "the owner's ANSWER.md wakes the loop" within 5 "A03: released the owner's answer"
ok "the answered node starts" within 5 "started A03 \(third-node\).*start 1 of 2"
a03=$(cat "$state/node/A03/session.pid" 2>/dev/null)
ok "the session's pid is recorded" test -n "$a03"

SCHED_REPORT=0 SCHED_TICK=1 SCHED_POLL=0.2 timeout 10 bash "$nb/scheduler/loop.sh" o/proj >"$tmp/second.out" 2>&1; rc=$?
ok "a second loop refuses to run" sh -c "[ $rc = 1 ] && grep -q 'already running' '$tmp/second.out'"

kill "$loop1"; wait "$loop1" 2>/dev/null
sleep 0.5
ok "stopping the loop leaves the session running" kill -0 "$a03"

SCHED_REPORT=0 SCHED_TICK=1 SCHED_POLL=0.2 bash "$nb/scheduler/loop.sh" o/proj >"$tmp/loop2.out" 2>&1 &
loop2=$!; pids+=("$loop2")
ok "a restarted loop takes over the running session" within 5 "running: .*A03 \(pid $a03\)"
sleep 2
ok "and does not start it a second time" test "$(runs A03)" = 1
touch "$tmp/go"
ok "the taken-over session's end and exit code are reported" within 5 "session A03 ended \(rc 3\), no PR, no QUESTION.md; may start again"
ok "the start count survives the restart" within 5 "started A03 \(third-node\).*start 2 of 2"
ok "a second empty exit writes FAILED" within 5 "session A03 ended \(rc 0\).*2 starts used: wrote FAILED"
ok "FAILED is on disk" test -e "$state/node/A03/FAILED"

git -C "$tmp/work" -c user.name=t -c user.email=t@t commit -q --allow-empty -m later && git -C "$tmp/work" push -q "$tmp/remote.git" HEAD:main
ok "the clone's own checkout follows origin/main" timeout 5 sh -c "until [ \"\$(git -C '$nb/repos/proj' rev-parse HEAD)\" = \"\$(git -C '$tmp/remote.git' rev-parse main)\" ]; do sleep 0.2; done"
echo "55 spec/A02-topic" >>"$tmp/merged.tsv"
ok "a merged spec PR releases the node" within 5 "A02: spec PR #55 merged"
ok "the resumed node gets fresh starts" within 5 "started A02 .*start 1 of 2.*"
ok "the resumed session ends with its new question" within 5 "session A02 ended \(rc 0\) with QUESTION.md"
ok "each A02 session saw the archived answer, and later the spec PR" grep -qxF "A02 run 2: ANSWER.md QUESTION.md SPEC-PR " "$tmp/claude.log"
grep -qxF "A02 run 1: ANSWER.md QUESTION.md " "$tmp/claude.log" || fail "A02 run 1 saw: $(cat "$tmp/claude.log")"
rm "$state/node/A04/FAILED" "$state/node/A05/FAILED"
ok "two ready nodes start together" within 5 "started A05 \(fifth-node\)"
ok "both run at once" within 5 "running: A04 \(pid [0-9]+\), A05 \(pid [0-9]+\)"
touch "$tmp/go2"
ok "each parallel session's end is reported" within 5 "session A05 ended \(rc 0\) with QUESTION.md"
grep -q "session A04 ended (rc 0) with QUESTION.md" "$state/status.log" || fail "A04's end is reported"
echo '[{"number": 46}]' >"$tmp/issues.json"
ok "an issue the owner labelled noodlebot is triaged" within 5 "started triage of #46 in .*issue-46, pid [0-9]+, start 1 of 2"
ok "the triage session gets the triage prompt" sh -c "grep -qx 'triage 46' '$tmp/claude.log'"
ok "a finished triage swaps the label" within 5 "triage of #46 done \(rc 0\); its label is now noodlebot-triaged"
ok "the label calls add noodlebot-triaged and remove noodlebot" grep -q 'DELETE repos/o/proj/issues/46/labels/noodlebot' "$tmp/labels.log"
ok "the triage worktree is removed" test ! -d "$nb/worktrees/proj/issue-46"
idle0=$(count 'nothing ready')
sleep 4
ok "an idle loop logs 'nothing ready' once, not every poll" test $(($(count 'nothing ready') - idle0)) -le 1
ok "the heartbeat is fresh" test "$(($(date +%s) - $(cat "$state/heartbeat" 2>/dev/null || echo 0)))" -le 3
ok "the OAuth token is in no state file" sh -c "! grep -rq fake-oauth '$state'"

touch "$HOME/STOP-proj"
ok "the per-repository STOP-proj file ends the loop within seconds" timeout 3 sh -c "while kill -0 $loop2 2>/dev/null; do sleep 0.1; done"


# --- D01: self-deploy. A loop whose own checkout ($nb2) is a clone of a fake "noodlebot" remote. ---
# C2 passes the stub make test and carries a loop.sh that logs "v2 pid <pid>" to $tmp/marker when it
# starts; C3 fails it (and would log "v3"). The loop must deploy C2 and re-exec (same pid, marker
# written) without starting its running session again, and leave C3 undeployed after one status line.
nb2=$tmp/nb2 state2=$tmp/nb2/state/dep
state=$state2   # ok prints this log on a failure
nbsrc=(loop.sh ready.py release-markers.sh run-session.sh unattended.md issues.py unattended-triage.md deploy.sh)
# mkloop <tag>: the current loop.sh, logging "<tag> pid <pid>" to $tmp/marker when it starts.
mkloop() { local l; while IFS= read -r l; do printf '%s\n' "$l"; [ "$l" = "set -u -o pipefail" ] && echo "echo $1 pid \$\$ >>'$tmp/marker'"; done <"$src/loop.sh"; }
git init -q -b main "$tmp/nbwork"
mkdir -p "$tmp/nbwork/scheduler" "$tmp/nbwork/plugin"
for f in "${nbsrc[@]}"; do cp "$src/$f" "$tmp/nbwork/scheduler/" 2>/dev/null; done
chmod +x "$tmp/nbwork"/scheduler/*.sh
touch "$tmp/nbwork/plugin/.keep"
printf 'state/\nrepos/\nworktrees/\n' >"$tmp/nbwork/.gitignore"
printf 'test:\n\t@echo stub test passes\n\n.PHONY: test\n' >"$tmp/nbwork/Makefile"
git -C "$tmp/nbwork" add -A && git -C "$tmp/nbwork" -c user.name=t -c user.email=t@t commit -q -m c1
git clone -q --bare "$tmp/nbwork" "$tmp/nbremote.git"
git clone -q "$tmp/nbremote.git" "$nb2"
# The repository the loop schedules: one ready node, B01.
git init -q -b main "$tmp/work2"
mkdir -p "$tmp/work2/docs"
printf 'nodes:\n  - {id: B01, name: only-node, deps: []}\n' >"$tmp/work2/docs/graph.yaml"
git -C "$tmp/work2" add -A && git -C "$tmp/work2" -c user.name=t -c user.email=t@t commit -q -m init
git clone -q --bare "$tmp/work2" "$tmp/remote2.git"
mkdir -p "$nb2/repos" "$state2/node" "$tmp/bin2"
git clone -q "$tmp/remote2.git" "$nb2/repos/dep"
: >"$tmp/merged2.tsv"
cat >"$tmp/bin2/gh" <<EOF2
#!/bin/sh
case " \$* " in
*" --state merged "*) cat "$tmp/merged2.tsv" ;;
*"/issues?labels=noodlebot"*) echo '[]' ;;
esac
exit 0
EOF2
cat >"$tmp/bin2/claude" <<EOF2
#!/bin/sh
echo "start \${2##* }" >>"$tmp/claude2.log"
while [ ! -e "$tmp/go3" ]; do sleep 0.2; done
exit 0
EOF2
chmod +x "$tmp/bin2/gh" "$tmp/bin2/claude"
within2() { timeout "$1" sh -c "until grep -qE \"\$1\" '$state2/status.log' 2>/dev/null; do sleep 0.1; done" _ "$2"; }
count2() { grep -cE "$1" "$state2/status.log" 2>/dev/null || true; }
# after2 <seconds> <line count> <pattern>: a status.log line past that line count matches.
after2() { timeout "$1" sh -c "until tail -n +\$(($2 + 1)) '$state2/status.log' 2>/dev/null | grep -qE \"\$3\"; do sleep 0.1; done" _ "$1" "$2" "$3"; }
head2() { git -C "$nb2" rev-parse HEAD; }
push2() { git -C "$tmp/nbwork" -c user.name=t -c user.email=t@t commit -q -a -m "$1" && git -C "$tmp/nbwork" push -q "$tmp/nbremote.git" HEAD:main; }

PATH=$tmp/bin2:$PATH SCHED_REPORT=0 SCHED_TICK=1 SCHED_POLL=0.2 bash "$nb2/scheduler/loop.sh" o/dep >"$tmp/loop3.out" 2>&1 &
loop3=$!; pids+=("$loop3")
ok "D01-AC-1: a loop running from a git checkout starts its node" within2 10 "started B01 \(only-node\).*start 1 of 2"
sp=$(cat "$state2/node/B01/session.pid" 2>/dev/null)
c1=$(head2)
sleep 1.5
ok "D01-AC-1: a tick with nothing to deploy leaves the loop and the checkout alone" sh -c "[ ! -e '$tmp/marker' ] && [ '$(head2)' = '$c1' ]"

# C2: passes make test, new loop.sh.
mkloop v2 >"$tmp/nbwork/scheduler/loop.sh"
echo c2 >"$tmp/nbwork/c2.txt"; git -C "$tmp/nbwork" add c2.txt
push2 c2
c2=$(git -C "$tmp/nbwork" rev-parse HEAD)
n0=$(wc -l <"$state2/status.log")
ok "D01-AC-1: the checkout moves to a passing commit within a tick or two" timeout 6 sh -c "until [ \"\$(git -C '$nb2' rev-parse HEAD)\" = '$c2' ]; do sleep 0.2; done"
ok "D01-AC-1: the loop re-execs into the new commit's loop.sh" timeout 3 sh -c "until grep -q '^v2 pid ' '$tmp/marker' 2>/dev/null; do sleep 0.2; done"
ok "D01-AC-1: the re-exec keeps the loop's pid" sh -c "kill -0 $loop3 && grep -qx 'v2 pid $loop3' '$tmp/marker'"
ok "D01-AC-1: the loop re-execs once" test "$(grep -c '^v2 pid ' "$tmp/marker" 2>/dev/null || echo 0)" = 1
ok "D01-AC-1: the deploy is one status-log event" sh -c "[ \$(grep -cE 'deployed ${c1:0:7}[0-9a-f]*\.\.${c2:0:7}' '$state2/status.log') = 1 ]"
ok "D01-AC-1: the re-exec'd loop still owns the session (reported running)" after2 4 "$n0" "running: .*B01 \(pid $sp\)"
ok "D01-AC-1: the session is alive with the same pid" kill -0 "$sp"
ok "D01-AC-1: the session was started once, not again after the re-exec" sh -c "[ \$(grep -c '^start B01' '$tmp/claude2.log') = 1 ] && [ \$(grep -c 'started B01' '$state2/status.log') = 1 ]"
touch "$tmp/go3"
ok "D01-AC-1: the re-exec'd loop reports the session's end" after2 4 "$n0" "session B01 ended \(rc 0\)"

# C3: fails make test, would log v3.
mkloop v3 >"$tmp/nbwork/scheduler/loop.sh"
printf 'test:\n\t@echo stub test fails; false\n\n.PHONY: test\n' >"$tmp/nbwork/Makefile"
push2 c3
c3=$(git -C "$tmp/nbwork" rev-parse HEAD)
ok "D01-AC-2: a commit failing make test is one status-log event" within2 5 "not deployed: ${c3:0:7}[0-9a-f]* fails make test"
sleep 4
ok "D01-AC-2: it stays one event across several ticks" test "$(count2 'not deployed')" = 1
ok "D01-AC-2: the checkout stays on the old commit" test "$(head2)" = "$c2"
ok "D01-AC-2: the loop does not re-exec into the failing commit" sh -c "! grep -q '^v3 pid ' '$tmp/marker' && [ \$(grep -c '^v2 pid ' '$tmp/marker') = 1 ] && kill -0 $loop3"

touch "$HOME/STOP-dep"
ok "D01: the test loop stops on STOP-dep" timeout 5 sh -c "while kill -0 $loop3 2>/dev/null; do sleep 0.1; done"

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: all loop checks"
