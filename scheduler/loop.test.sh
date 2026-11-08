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
export NOODLEBOT_DATA=$nb   # D02: the runs below keep their layout under $nb; the D02 runs at the end set or unset it
mkdir -p "$HOME/.config/noodlebot" "$tmp/bin" "$nb/scheduler" "$nb/plugin" "$state/node/A02" "$state/node/A03"
cp "$src"/loop.sh "$src"/ready.py "$src"/release-markers.sh "$src"/run-session.sh "$src"/unattended.md \
	"$src"/issues.py "$src"/usage.py "$src"/unattended-triage.md "$nb/scheduler/"
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
A04.1) while [ ! -e "$tmp/go2" ]; do sleep 0.2; done; echo "Q1: parallel" >"$state/node/\$id/QUESTION.md" ;;
A05.1) while [ ! -e "$tmp/go2" ]; do sleep 0.2; done
	echo '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","unifiedWindows":{"five_hour":{"utilization":1.0,"resetsAt":1,"status":"rejected"}}}}'
	echo '{"type":"result","subtype":"error_during_execution","result":"You have hit your usage limit"}'; exit 1 ;;
A05.2) echo "Q1: after the limit" >"$state/node/\$id/QUESTION.md" ;;
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
# The throttle: a 5-hour window at 99% holds new sessions; a fresh window releases them.
rl() { printf '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":%s,"resetsAt":%s,"status":"allowed"},"seven_day":{"utilization":0.0,"resetsAt":%s,"status":"allowed"}}}}\n' "$1" "$2" $(($(date +%s) + 3 * 86400)) >>"$state/node/A03/session.jsonl"; }
rl 0.99 $(($(date +%s) + 3600))
ok "a 5-hour window near its limit engages the throttle" within 5 "throttle engaged, no new sessions: 5-hour window projected"
rm "$state/node/A04/FAILED" "$state/node/A05/FAILED"
sleep 2
ok "while it holds, ready nodes do not start" sh -c "! grep -q 'started A0[45]' '$state/status.log'"
rl 0.01 $(($(date +%s) + 7200))
ok "a fresh window releases the throttle" within 5 "throttle released"
ok "two ready nodes start together" within 5 "started A05 \(fifth-node\)"
ok "both run at once" within 5 "running: A04 \(pid [0-9]+\), A05 \(pid [0-9]+\)"
touch "$tmp/go2"
ok "each parallel session's end is reported" within 5 "session A04 ended \(rc 0\) with QUESTION.md"
ok "a session stopped by the usage limit is reported as such" within 5 "session A05 stopped by the usage limit \(rc 1\); start not counted"
ok "and its start is not counted: it starts again as start 1" within 5 "session A05 ended \(rc 0\) with QUESTION.md"
ok "both A05 starts were start 1 of 2" test "$(count 'started A05 .*start 1 of 2')" = 2
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

# ---- D02: the runtime root (NOODLEBOT_DATA, default $HOME/.local/share/noodlebot) ----
# A fresh scheduler checkout that looks like the real one (a Git working tree with CLAUDE.md and
# AGENTS.md), and fresh repositories; the loop clones them itself (url.insteadOf points github.com
# at the local remote). The runs above keep their layout through NOODLEBOT_DATA=$nb.
nb2=$tmp/nb2
mkdir -p "$nb2/scheduler" "$nb2/plugin" "$tmp/bin2"
git init -q "$nb2" && touch "$nb2/CLAUDE.md" "$nb2/AGENTS.md"
nb2=$(cd "$nb2" && pwd -P)
cp "$src"/loop.sh "$src"/ready.py "$src"/release-markers.sh "$src"/run-session.sh "$src"/unattended.md \
	"$src"/issues.py "$src"/unattended-triage.md "$src"/status.sh "$src"/report.py "$nb2/scheduler/"
cp "$src/usage.py" "$nb2/scheduler/"
export GIT_CONFIG_COUNT=3
export GIT_CONFIG_KEY_0="url.$tmp/remote.git.insteadOf" GIT_CONFIG_VALUE_0=https://github.com/o/pu
export GIT_CONFIG_KEY_1="url.$tmp/remote.git.insteadOf" GIT_CONFIG_VALUE_1=https://github.com/o/ps
export GIT_CONFIG_KEY_2="url.$tmp/remote.git.insteadOf" GIT_CONFIG_VALUE_2=https://github.com/o/pg
# claude: records "<node|triage> <pwd -P>" in $FAKE_LOG; a node asks a question and ends.
cat >"$tmp/bin2/claude" <<'EOF'
#!/bin/sh
case "$2" in "/noodlebot:triage "*) k=triage ;; *) k=node ;; esac
echo "$k $(pwd -P)" >>"$FAKE_LOG"
[ $k = node ] && echo "Q1: x" >"$FAKE_STATE/node/${2##* }/QUESTION.md"
exit 0
EOF
chmod +x "$tmp/bin2/claude"

# no_marker_above <file>: the file lists "<kind> <dir>" lines (at least one); no folder above any
# dir has a .git, CLAUDE.md or AGENTS.md.
no_marker_above() {
	[ -s "$1" ] || return 1
	local kind dir p f
	while read -r kind dir; do
		p=$dir
		while [ "$p" != / ]; do
			p=$(dirname "$p")
			for f in .git CLAUDE.md AGENTS.md; do
				if [ -e "$p/$f" ]; then echo "      $kind session in $dir: $p/$f"; return 1; fi
			done
		done
	done <"$1"
}
# d02_run <name> <root> <set|unset>: loop o/<name> with NOODLEBOT_DATA set to <root>, or unset
# (then <root> is the default under $HOME); checks the layout, the sessions' folders, the rendered
# prompts and status.sh while it runs, then stops it.
d02_run() {
	local name=$1 root=$2 mode=$3 lp cwd=$tmp/cwd-$1.log what="NOODLEBOT_DATA $3" f
	local st=$root/state/$name wt=$root/worktrees/$name
	state=$st
	: >"$cwd"
	echo '[{"number": 46}]' >"$tmp/issues.json"
	(
		if [ "$mode" = set ]; then export NOODLEBOT_DATA=$root; else unset NOODLEBOT_DATA; fi
		export FAKE_LOG=$cwd FAKE_STATE=$st PATH=$tmp/bin2:$PATH
		SCHED_REPORT=0 SCHED_TICK=30 SCHED_POLL=0.2 exec bash "$nb2/scheduler/loop.sh" "o/$name" >"$tmp/$name.out" 2>&1
	) &
	lp=$!; pids+=("$lp")
	timeout 15 sh -c "until grep -q '^triage' '$cwd' && [ \$(grep -c '^node' '$cwd') -ge 2 ]; do sleep 0.2; done"
	sleep 1
	ok "D02-AC-1 ($what): the loop cloned the repository under <root>/repos/<name>" test -d "$root/repos/$name/.git"
	ok "D02-AC-1 ($what): a node's worktree is under <root>/worktrees/<name>" test -e "$wt/A02/.git"
	ok "D02-AC-1 ($what): the state is under <root>/state/<name>" sh -c "[ -f '$st/status.log' ] && [ -d '$st/node/A02' ] && [ -e '$st/loop.lock' ]"
	ok "D02-AC-1 ($what): the checkout the scripts run from gains no repos/, worktrees/ or state/" sh -c "[ ! -e '$nb2/repos' ] && [ ! -e '$nb2/worktrees' ] && [ ! -e '$nb2/state' ]"
	NOODLEBOT_DATA=$root; [ "$mode" = set ] || unset NOODLEBOT_DATA
	bash "$nb2/scheduler/status.sh" "o/$name" >"$tmp/status-$name.out" 2>&1
	ok "D02-AC-1 ($what): status.sh sees the loop running" sh -c "[ -e '$st/loop.lock' ] && grep -q 'loop: *running' '$tmp/status-$name.out'"
	ok "D02-AC-1 ($what): status.sh reads that state (the node's QUESTION)" grep -q 'A02 QUESTION: Q1: x' "$tmp/status-$name.out"
	ok "D02-AC-1 ($what): status.sh reads that state (the last change)" grep -q 'last change: 20[0-9][0-9]-' "$tmp/status-$name.out"
	export NOODLEBOT_DATA=$nb
	ok "D02-AC-2 ($what): sessions of both kinds started, in worktrees under the root" sh -c "grep -q '^node $wt/A' '$cwd' && grep -q '^triage $wt/issue-46\$' '$cwd'"
	ok "D02-AC-2 ($what): no session has a Git working tree, CLAUDE.md or AGENTS.md above its folder" no_marker_above "$cwd"
	ok "D02-AC-4 ($what): the node prompt names its worktree" grep -qF "$wt/A02" "$st/node/A02/unattended.md"
	ok "D02-AC-4 ($what): the node prompt names its state folder" grep -qF "$st/node/A02" "$st/node/A02/unattended.md"
	ok "D02-AC-4 ($what): the node prompt names the loop by the path it runs from" grep -qF "$nb2/scheduler/loop.sh" "$st/node/A02/unattended.md"
	ok "D02-AC-4 ($what): the triage prompt names its worktree" grep -qF "$wt/issue-46" "$st/issue/46/unattended.md"
	ok "D02-AC-4 ($what): the triage prompt names its state folder" grep -qF "$st/issue/46" "$st/issue/46/unattended.md"
	ok "D02-AC-4 ($what): the triage prompt names the loop by the path it runs from" grep -qF "$nb2/scheduler/loop.sh" "$st/issue/46/unattended.md"
	ok "D02-AC-4 ($what): neither rendered prompt names ~/gitrepos/noodlebot" sh -c "[ -s '$st/node/A02/unattended.md' ] && [ -s '$st/issue/46/unattended.md' ] && ! grep -qF '~/gitrepos/noodlebot' '$st/node/A02/unattended.md' '$st/issue/46/unattended.md'"
	touch "$HOME/STOP-$name"
	timeout 5 sh -c "while kill -0 $lp 2>/dev/null; do sleep 0.1; done"
}
d02_run pu "$HOME/.local/share/noodlebot" unset
d02_run ps "$tmp/data2" set
# D02-AC-1: status.sh reads the session's worktree under the runtime root: a live session for A02
# and a commit ahead of origin/main in <root>/worktrees/<name>/A02 show up on a "commit" line.
d02_wt() {
	local name=$1 root=$2 mode=$3 subj="d02-wt-marker-$1" sp
	sh -c 'sleep 60' claude -p /node A02 &
	sp=$!; pids+=("$sp")
	echo "$sp" >"$root/state/$name/node/A02/session.pid"
	git -C "$root/worktrees/$name/A02" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$subj"
	(
		if [ "$mode" = set ]; then export NOODLEBOT_DATA=$root; else unset NOODLEBOT_DATA; fi
		bash "$nb2/scheduler/status.sh" "o/$name" >"$tmp/status-wt-$name.out" 2>&1
	)
	ok "D02-AC-1 (NOODLEBOT_DATA $mode): status.sh reads that worktree (the session's commit)" grep -qE "^ +commit [0-9a-f]+ $subj\$" "$tmp/status-wt-$name.out"
	kill "$sp" 2>/dev/null
}
d02_wt pu "$HOME/.local/share/noodlebot" unset
d02_wt ps "$tmp/data2" set
ok "D02-AC-4: neither template names ~/gitrepos/noodlebot" sh -c "! grep -qF '~/gitrepos/noodlebot' '$src/unattended.md' '$src/unattended-triage.md'"

# D02-AC-3: a root inside a Git working tree is refused: exit 2, no session, the working tree named.
git init -q "$tmp/gitwt" && mkdir -p "$tmp/gitwt/data"
gw=$(cd "$tmp/gitwt" && pwd -P)
echo '[]' >"$tmp/issues.json"; : >"$tmp/cwd-pg.log"
NOODLEBOT_DATA=$gw/data FAKE_LOG=$tmp/cwd-pg.log FAKE_STATE=$gw/data/state/pg PATH=$tmp/bin2:$PATH \
	SCHED_REPORT=0 SCHED_TICK=1 SCHED_POLL=0.2 timeout 10 bash "$nb2/scheduler/loop.sh" o/pg >"$tmp/pg.out" 2>&1; rc=$?
sleep 1
ok "D02-AC-3: a root inside a Git working tree exits 2" test "$rc" = 2
ok "D02-AC-3: and starts no session" test ! -s "$tmp/cwd-pg.log"
ok "D02-AC-3: and its message names that working tree" grep -qF "$gw" "$tmp/pg.out"
ok "D02-AC-3: its message names the working tree itself, not only the root" env GW="$gw" awk 'BEGIN{r=ENVIRON["GW"] "/data"; n=length(r)} {while((i=index($0,r))>0) $0=substr($0,1,i-1) substr($0,i+n); if(index($0,ENVIRON["GW"])>0) f=1} END{exit !f}' "$tmp/pg.out"

# D02-AC-3: a root that does not exist yet inside a working tree is refused too, and not created.
: >"$tmp/cwd-ny.log"
NOODLEBOT_DATA=$gw/not/yet FAKE_LOG=$tmp/cwd-ny.log FAKE_STATE=$tmp/ny-state PATH=$tmp/bin2:$PATH \
	SCHED_REPORT=0 SCHED_TICK=1 SCHED_POLL=0.2 timeout 10 bash "$nb2/scheduler/loop.sh" o/pg >"$tmp/ny.out" 2>&1; rc=$?
sleep 1
ok "D02-AC-3: a not-yet-created root inside a Git working tree exits 2" test "$rc" = 2
ok "D02-AC-3: and starts no session (not-yet-created root)" test ! -s "$tmp/cwd-ny.log"
ok "D02-AC-3: and names the working tree (not-yet-created root)" env GW="$gw" awk 'BEGIN{r=ENVIRON["GW"] "/not/yet"; n=length(r)} {while((i=index($0,r))>0) $0=substr($0,1,i-1) substr($0,i+n); if(index($0,ENVIRON["GW"])>0) f=1} END{exit !f}' "$tmp/ny.out"
ok "D02-AC-3: and does not create the root's parent (not-yet-created root)" test ! -e "$gw/not"

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: all loop checks"
