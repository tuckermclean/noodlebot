#!/bin/bash
# End-to-end test of scheduler/loop.sh with a fake gh, a fake claude and a local git remote.
# Loop 1 runs with a 30 s GitHub poll, so anything it does within a few seconds was woken by a
# local change: the owner's ANSWER.md, a session exiting. Then loop 1 is stopped with a session
# running, and loop 2 (1 s poll) must take that session over, not start a second one; it carries
# the start count over, writes FAILED, and resumes a node after its spec PR merges.
#   bash scheduler/loop.test.sh   (make test)
set -u
unset NOODLEBOT_VERSION   # V01: run from a clean environment, even inside a noodlebot session
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

# ---- L01: the label step (labels.py ensure) runs once when the loop starts, never on a tick ----
# A fresh scheduler checkout with labels.py (copied only when it exists, so a missing labels.py
# fails the checks below instead of the harness) and its own fakes: gh logs "merged" for every PR
# poll (one per tick) and "labels <args>" for every call on the repository's labels, in order.
# The file $L01_FAIL, when it exists, makes every labels call fail with "fake-label-failure".
nb3=$tmp/nb3
mkdir -p "$nb3/scheduler" "$nb3/plugin" "$tmp/bin3"
cp "$src"/loop.sh "$src"/ready.py "$src"/release-markers.sh "$src"/run-session.sh "$src"/unattended.md \
	"$src"/issues.py "$src"/unattended-triage.md "$src"/status.sh "$src"/report.py "$src"/usage.py "$nb3/scheduler/"
[ -f "$src/labels.py" ] && cp "$src/labels.py" "$nb3/scheduler/"
cat >"$tmp/bin3/gh" <<'EOF'
#!/bin/sh
case " $* " in
*" --state merged "*) echo merged >>"$L01_LOG"; echo "1 node/A01-first-node" ;;
*"/issues?labels=noodlebot"*) echo '[]' ;;
*" repos/"*"/labels"*)
	echo "labels $*" >>"$L01_LOG"; cat >/dev/null
	if [ -e "$L01_FAIL" ]; then echo "fake-label-failure" >&2; exit 1; fi
	echo '[{"name": "noodlebot"}, {"name": "noodlebot-triaged"}, {"name": "noodlebot-status"}]' ;;
esac
exit 0
EOF
cat >"$tmp/bin3/claude" <<'EOF'
#!/bin/sh
echo "$2" >>"$L01_CLAUDE"
echo "Q1: x" >"$L01_STATE/node/${2##* }/QUESTION.md"
exit 0
EOF
chmod +x "$tmp/bin3/gh" "$tmp/bin3/claude"
# l01_run <name> <fail|ok>: a loop for o/<name> with a 1 s tick, running until three ticks have
# polled GitHub and a ready node has started (at most 15 s).
l01_run() {
	local name=$1 mode=$2 lp root=$tmp/data3
	state=$root/state/$name
	export L01_LOG=$tmp/l01-$name.log L01_CLAUDE=$tmp/l01-claude-$name.log L01_STATE=$state L01_FAIL=$tmp/l01-fail-$name
	: >"$L01_LOG"; : >"$L01_CLAUDE"
	[ "$mode" = fail ] && : >"$L01_FAIL"
	mkdir -p "$root/repos" "$state/node/A02" "$state/node/A03" "$state/node/A04" "$state/node/A05"
	touch "$state/node/A03/FAILED" "$state/node/A04/FAILED" "$state/node/A05/FAILED"
	git clone -q "$tmp/remote.git" "$root/repos/$name"
	NOODLEBOT_DATA=$root PATH=$tmp/bin3:$PATH SCHED_REPORT=0 SCHED_TICK=1 SCHED_POLL=0.2 bash "$nb3/scheduler/loop.sh" "o/$name" >"$tmp/l01-$name.out" 2>&1 &
	lp=$!; pids+=("$lp")
	timeout 15 sh -c "until [ \$(grep -c merged '$L01_LOG') -ge 3 ] && grep -q 'node A02' '$L01_CLAUDE'; do sleep 0.1; done"
	sleep 1
}
l01_stop() {
	touch "$HOME/STOP-$1"
	timeout 5 sh -c "while pgrep -f 'nb3/scheduler/loop.sh o/$1' >/dev/null; do sleep 0.1; done"
}
l01_run pl ok
ok "L01-AC-4: the loop ticked at least three times (it polled GitHub for merged PRs)" test "$(grep -c merged "$L01_LOG")" -ge 3
ok "L01-AC-4: the label step ran once: one listing of o/pl's labels over all those ticks" test "$(grep -c '^labels .*o/pl/labels' "$L01_LOG")" = 1
ok "L01-AC-4: and it ran at the start, before the first tick" sh -c "[ \"\$(head -n1 '$L01_LOG' | cut -c1-6)\" = labels ]"
ok "L01-AC-4: with every label present, the label step wrote nothing" sh -c "grep -q '^labels' '$L01_LOG' && ! grep -E '^labels .*(POST|PATCH|DELETE)' '$L01_LOG'"
l01_stop pl
# AC-5: the label step fails (gh fails on every labels call).
l01_run pf fail
ok "L01-AC-5: the failing label step ran once, not on later ticks" test "$(grep -c '^labels .*o/pf/labels' "$L01_LOG")" = 1
ok "L01-AC-5: the loop still ticked (it polled GitHub for merged PRs)" test "$(grep -c merged "$L01_LOG")" -ge 3
ok "L01-AC-5: and started ready work" within 5 "started A02 \(second-node\)"
ok "L01-AC-5: the failure is one status-log event" test "$(grep -ci 'label' "$state/status.log")" = 1
ok "L01-AC-5: its stderr is in report.log" grep -q fake-label-failure "$state/report.log"
l01_stop pf


# --- D01: self-deploy. A loop whose own checkout ($nbd) is a clone of a fake "noodlebot" remote. ---
# C2 passes the stub make test and carries a loop.sh that logs "v2 pid <pid>" to $tmp/marker when it
# starts; C3 fails it (and would log "v3"). The loop must deploy C2 and re-exec (same pid, marker
# written) without starting its running session again, and leave C3 undeployed after one status line.
nbd=$tmp/nbd datad=$tmp/datad stated=$tmp/datad/state/dep   # the runtime root datad lies outside the clone nbd (D02)
state=$stated   # ok prints this log on a failure
nbsrc=(loop.sh ready.py release-markers.sh run-session.sh unattended.md issues.py unattended-triage.md deploy.sh)
# mkloop <tag>: the current loop.sh, logging "<tag> pid <pid>" to $tmp/marker when it starts.
mkloop() { local l; while IFS= read -r l; do printf '%s\n' "$l"; [ "$l" = "set -u -o pipefail" ] && echo "echo $1 pid \$\$ >>'$tmp/marker'"; done <"$src/loop.sh"; }
git init -q -b main "$tmp/nbwork"
mkdir -p "$tmp/nbwork/scheduler" "$tmp/nbwork/plugin"
for f in "${nbsrc[@]}"; do cp "$src/$f" "$tmp/nbwork/scheduler/" 2>/dev/null; done
chmod +x "$tmp/nbwork"/scheduler/*.sh
touch "$tmp/nbwork/plugin/.keep"
cp "$src/version.sh" "$tmp/nbwork/scheduler/" 2>/dev/null; chmod +x "$tmp/nbwork"/scheduler/version.sh 2>/dev/null
printf 'state/\nrepos/\nworktrees/\n' >"$tmp/nbwork/.gitignore"
printf 'test:\n\t@echo stub test passes\n\n.PHONY: test\n' >"$tmp/nbwork/Makefile"
git -C "$tmp/nbwork" add -A && git -C "$tmp/nbwork" -c user.name=t -c user.email=t@t commit -q -m c1
git -C "$tmp/nbwork" tag v1.0
git clone -q --bare "$tmp/nbwork" "$tmp/nbremote.git"
git clone -q "$tmp/nbremote.git" "$nbd"
# The repository the loop schedules: one ready node, B01.
git init -q -b main "$tmp/workd"
mkdir -p "$tmp/workd/docs"
printf 'nodes:\n  - {id: B01, name: only-node, deps: []}\n' >"$tmp/workd/docs/graph.yaml"
git -C "$tmp/workd" add -A && git -C "$tmp/workd" -c user.name=t -c user.email=t@t commit -q -m init
git clone -q --bare "$tmp/workd" "$tmp/remoted.git"
mkdir -p "$datad/repos" "$stated/node" "$tmp/bind"
git clone -q "$tmp/remoted.git" "$datad/repos/dep"
: >"$tmp/mergedd.tsv"
cat >"$tmp/bind/gh" <<EOFD
#!/bin/sh
case " \$* " in
*" --state merged "*) cat "$tmp/mergedd.tsv" ;;
*"/issues?labels=noodlebot"*) echo '[]' ;;
esac
exit 0
EOFD
cat >"$tmp/bind/claude" <<EOFD
#!/bin/sh
echo "start \${2##* }" >>"$tmp/claudel.log"
while [ ! -e "$tmp/go3" ]; do sleep 0.2; done
exit 0
EOFD
chmod +x "$tmp/bind/gh" "$tmp/bind/claude"
withind() { timeout "$1" sh -c "until grep -qE \"\$1\" '$stated/status.log' 2>/dev/null; do sleep 0.1; done" _ "$2"; }
countd() { grep -cE "$1" "$stated/status.log" 2>/dev/null || true; }
# afterd <seconds> <line count> <pattern>: a status.log line past that line count matches.
afterd() { timeout "$1" sh -c "until tail -n +\$(($2 + 1)) '$stated/status.log' 2>/dev/null | grep -qE \"\$3\"; do sleep 0.1; done" _ "$1" "$2" "$3"; }
headd() { git -C "$nbd" rev-parse HEAD; }
pushd() { git -C "$tmp/nbwork" -c user.name=t -c user.email=t@t commit -q -a -m "$1" && git -C "$tmp/nbwork" push -q "$tmp/nbremote.git" HEAD:main; }

NOODLEBOT_DATA=$datad PATH=$tmp/bind:$PATH SCHED_REPORT=0 SCHED_TICK=1 SCHED_POLL=0.2 bash "$nbd/scheduler/loop.sh" o/dep >"$tmp/loop3.out" 2>&1 &
loop3=$!; pids+=("$loop3")
ok "D01-AC-1: a loop running from a git checkout starts its node" withind 10 "started B01 \(only-node\).*start 1 of 2"
sp=$(cat "$stated/node/B01/session.pid" 2>/dev/null)
c1=$(headd)
sleep 1.5
ok "D01-AC-1: a tick with nothing to deploy leaves the loop and the checkout alone" sh -c "[ ! -e '$tmp/marker' ] && [ '$(headd)' = '$c1' ]"
ok "V01-AC-3: the first start wrote exactly one line 'loop started for o/dep, version v1.0' (the tag on the loop's own commit)" sh -c "[ \$(grep -c 'loop started for o/dep, version ' '$stated/status.log') = 1 ] && grep -q 'loop started for o/dep, version v1.0\$' '$stated/status.log'"
ok "V01-AC-3: and state/dep/version holds v1.0" sh -c "[ \"\$(cat '$stated/version' 2>/dev/null)\" = v1.0 ]"

# C2: passes make test, new loop.sh.
mkloop v2 >"$tmp/nbwork/scheduler/loop.sh"
echo c2 >"$tmp/nbwork/c2.txt"; git -C "$tmp/nbwork" add c2.txt
pushd c2
c2=$(git -C "$tmp/nbwork" rev-parse HEAD)
n0=$(wc -l <"$stated/status.log")
ok "D01-AC-1: the checkout moves to a passing commit within a tick or two" timeout 6 sh -c "until [ \"\$(git -C '$nbd' rev-parse HEAD)\" = '$c2' ]; do sleep 0.2; done"
ok "D01-AC-1: the loop re-execs into the new commit's loop.sh" timeout 3 sh -c "until grep -q '^v2 pid ' '$tmp/marker' 2>/dev/null; do sleep 0.2; done"
ok "D01-AC-1: the re-exec keeps the loop's pid" sh -c "kill -0 $loop3 && grep -qx 'v2 pid $loop3' '$tmp/marker'"
ok "D01-AC-1: the loop re-execs once" test "$(grep -c '^v2 pid ' "$tmp/marker" 2>/dev/null || echo 0)" = 1
v01_v2=$(git -C "$nbd" describe --tags --always)
ok "V01-AC-3: after the deploy the re-exec writes a start line naming the deployed commit's version" withind 5 "loop started for o/dep, version $v01_v2\$"
ok "V01-AC-3: the deployed version is not the first one (a commit after the tag)" test "$v01_v2" != v1.0
ok "V01-AC-3: the deploy's restart makes two start lines in all, the first naming v1.0" sh -c "[ \$(grep -c 'loop started for o/dep, version ' '$stated/status.log') = 2 ] && [ \$(grep -c 'loop started for o/dep, version v1.0\$' '$stated/status.log') = 1 ]"
ok "V01-AC-3: and state/dep/version now holds the deployed version" sh -c "[ \"\$(cat '$stated/version' 2>/dev/null)\" = '$v01_v2' ]"
ok "D01-AC-1: the deploy is one status-log event" sh -c "[ \$(grep -cE 'deployed ${c1:0:7}[0-9a-f]*\.\.${c2:0:7}' '$stated/status.log') = 1 ]"
ok "D01-AC-1: a deploy is exactly one status-log line in total (no second 're-execs' line)" sh -c "[ \$(grep -c 'deployed' '$stated/status.log') = 1 ] && [ \$(grep -cE 'deployed ${c1:0:7}[0-9a-f]*\.\.${c2:0:7}' '$stated/status.log') = 1 ]"
ok "V01-AC-4: the status log's deploy line names the deployed commit's version" withind 5 "deployed ${c1:0:7}[0-9a-f]*\.\.${c2:0:7}[0-9a-f]* \(version ${v01_v2}\)\$"
ok "D01-AC-1: the re-exec'd loop still owns the session (reported running)" afterd 4 "$n0" "running: .*B01 \(pid $sp\)"
ok "D01-AC-1: the session is alive with the same pid" kill -0 "$sp"
ok "D01-AC-1: the session was started once, not again after the re-exec" sh -c "[ \$(grep -c '^start B01' '$tmp/claudel.log') = 1 ] && [ \$(grep -c 'started B01' '$stated/status.log') = 1 ]"
touch "$tmp/go3"
ok "D01-AC-1: the re-exec'd loop reports the session's end" afterd 4 "$n0" "session B01 ended \(rc 0\)"

# C3: fails make test, would log v3.
mkloop v3 >"$tmp/nbwork/scheduler/loop.sh"
printf 'test:\n\t@echo stub test fails; false\n\n.PHONY: test\n' >"$tmp/nbwork/Makefile"
pushd c3
c3=$(git -C "$tmp/nbwork" rev-parse HEAD)
ok "D01-AC-2: a commit failing make test is one status-log event" withind 5 "not deployed: ${c3:0:7}[0-9a-f]* \(version [^)]+\) fails make test"
v01_v3=$(git -C "$nbd" describe --tags --always "$c3" 2>/dev/null)
ok "V01-AC-4: the refused commit's version is tag-based, not a bare sha (guard)" sh -c "case '$v01_v3' in v1.0-*-g*) true ;; *) false ;; esac"
ok "V01-AC-4: the status log's not-deployed line names the refused commit's version" withind 5 "not deployed: ${c3:0:7}[0-9a-f]* \(version ${v01_v3}\) fails make test\$"
sleep 4
ok "D01-AC-2: it stays one event across several ticks" test "$(countd 'not deployed')" = 1
ok "D01-AC-2: the checkout stays on the old commit" test "$(headd)" = "$c2"
ok "D01-AC-2: the loop does not re-exec into the failing commit" sh -c "! grep -q '^v3 pid ' '$tmp/marker' && [ \$(grep -c '^v2 pid ' '$tmp/marker') = 1 ] && kill -0 $loop3"

ok "D01-AC-1: the loop's deploy records the previous commit under its runtime root" sh -c "[ -s '$datad/deploy/previous' ]"
ok "D01-AC-2: the loop's deploy writes nothing into its own checkout (no state/ there)" sh -c "[ ! -e '$nbd/state' ] && [ -z \"\$(git -C '$nbd' status --porcelain --ignored)\" ]"

touch "$HOME/STOP-dep"
ok "D01: the test loop stops on STOP-dep" timeout 5 sh -c "while kill -0 $loop3 2>/dev/null; do sleep 0.1; done"


# B1: the loop only runs deploy.sh when it is executable ([ -x ]); the tests above chmod +x their copy, which hides a
# committed 100644. A checkout carries the mode of the git index, so check what the repository under test commits.
ok "D01-AC-1: scheduler/deploy.sh is committed executable (mode 100755), so a real checkout can deploy" sh -c "[ \"\$(git -C '$src' ls-files -s -- deploy.sh | cut -d' ' -f1)\" = 100755 ]"

# ---- S01: a session whose PR is done is stopped (merged, or closed without merging) ----
# Nodes B01..B07 (no deps) in their own remote. Every claude session runs until it is stopped and
# starts a child (sleep) of its own, recording the child's pid in $S01/child.<ID>.<run>; a session's
# process group id is the pid in its session.pid (sessions run under setsid). The fake gh answers
# --state merged ("<number> <branch>"), --state open (branches) and --state closed from $S01/*:
# closed.tsv holds "<number> <branch> <closed time, epoch seconds> <1 if merged>" (merged PRs are
# listed too, as on GitHub); with --json and no -q it prints the JSON array (number, headRefName,
# closedAt, mergedAt, state); with -q it applies the forms `.[] | "text \(.field) \(.field // "x")
# \(.field != null)"` and `.[].field`. closed.fail makes the closed query fail.
#   B01 merged while running (#11)             B02 closed unmerged while running (#12)
#   B03 closed (#13) before its session began  B04 closed (#14) while an open PR (#15) exists
#   B05 control; closed (#16) only in the failing-query phase
#   B06 merged (#17) while the loop is down: the next loop takes the session over
s01ok() { local name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
S01=$tmp/s01; export S01
mkdir -p "$S01" "$tmp/bin4" "$tmp/nb4/scheduler" "$tmp/nb4/plugin"
: >"$S01/merged.tsv"; : >"$S01/open.txt"; : >"$S01/closed.tsv"
cp "$src"/loop.sh "$src"/ready.py "$src"/release-markers.sh "$src"/run-session.sh "$src"/unattended.md \
	"$src"/issues.py "$src"/unattended-triage.md "$src"/status.sh "$src"/report.py "$src"/usage.py "$tmp/nb4/scheduler/"
git init -q -b main "$tmp/work4"; mkdir -p "$tmp/work4/docs"
{ echo 'nodes:'; for i in 1 2 3 4 5 6 7; do echo "  - {id: B0$i, name: n$i, deps: []}"; done; } >"$tmp/work4/docs/graph.yaml"
git -C "$tmp/work4" add -A && git -C "$tmp/work4" -c user.name=t -c user.email=t@t commit -q -m init
git clone -q --bare "$tmp/work4" "$tmp/remote4.git"
data4=$tmp/data4 state=$tmp/data4/state/sc wt4=$tmp/data4/worktrees/sc
mkdir -p "$data4/repos" "$state/node/B07"
git clone -q "$tmp/remote4.git" "$data4/repos/sc"
touch "$state/node/B07/FAILED"   # keeps B07 from starting until the failing-query phase
cat >"$tmp/bin4/gh" <<'EOF'
#!/bin/sh
case " $* " in
*" --state merged "*) cat "$S01/merged.tsv" ;;
*" --state open "*) cat "$S01/open.txt" ;;
*" --state closed "*)
	if [ -e "$S01/closed.fail" ]; then echo "fake-closed-failure" >&2; exit 1; fi
	exec python3 -I "$S01/closed.py" "$@" ;;
*"/issues?labels=noodlebot"*) echo '[]' ;;
esac
exit 0
EOF
cat >"$S01/closed.py" <<'EOF'
import datetime, json, os, re, sys
a = sys.argv[1:]
rows = []
for line in open(os.environ["S01"] + "/closed.tsv"):
    f = line.split()
    if len(f) < 4:
        continue
    iso = datetime.datetime.fromtimestamp(int(f[2]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    rows.append({"number": int(f[0]), "headRefName": f[1], "closedAt": iso,
                 "mergedAt": iso if f[3] == "1" else None, "state": "MERGED" if f[3] == "1" else "CLOSED"})
q = next((a[i + 1] for i, x in enumerate(a) if x in ("-q", "--jq") and i + 1 < len(a)), None)
if q is None:
    print(json.dumps(rows)); sys.exit(0)
def ev(e, r):
    m = re.fullmatch(r'\s*\.(\w+)\s*(?:(!=|==)\s*(null|"[^"]*")|//\s*"([^"]*)")?\s*', e)
    if not m:
        sys.exit("fake gh: unsupported jq expression: " + e)
    v = r.get(m[1])
    if m[2]:
        return str((v == (None if m[3] == "null" else m[3].strip('"'))) == (m[2] == "==")).lower()
    if m[4] is not None and v is None:
        return m[4]
    return "null" if v is None else str(v)
m = re.fullmatch(r'\s*\.\[\]\.(\w+)\s*', q)
if m:
    for r in rows: print(ev("." + m[1], r))
    sys.exit(0)
m = re.fullmatch(r'\s*\.\[\]\s*\|\s*"(.*)"\s*', q)
if not m:
    sys.exit("fake gh: unsupported jq expression: " + q)
for r in rows:
    print(re.sub(r'\\\(((?:[^()]|\([^()]*\))*)\)', lambda x: ev(x[1], r), m[1]))
EOF
cat >"$tmp/bin4/claude" <<'EOF'
#!/bin/sh
id=${2##* }
n=$(( $(cat "$S01/runs.$id" 2>/dev/null || echo 0) + 1 )); echo $n >"$S01/runs.$id"
mkdir -p "out/node/$id" && echo brief >"out/node/$id/brief.md"
sleep 300 & echo $! >"$S01/child.$id.$n"
while :; do sleep 0.2; done
EOF
chmod +x "$tmp/bin4/gh" "$tmp/bin4/claude"
s01_cleanup() {
	local f
	for f in "$state"/node/*/session.pid; do [ -e "$f" ] && kill -KILL -- "-$(cat "$f")" 2>/dev/null; done
	for f in "$S01"/child.*; do [ -e "$f" ] && kill -KILL "$(cat "$f")" 2>/dev/null; done
	return 0
}
# shellcheck disable=SC2154 # p is the trap's own loop variable
trap 'for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done; s01_cleanup; pkill -f "$tmp/" 2>/dev/null; rm -rf "$tmp"' EXIT
# grp_gone <pgid>: no live (non-zombie) process is in that group. dead <pid>: gone or a zombie.
grp_gone() { ! ps -eo pgid=,stat= | awk -v g="$1" '$1 == g && $2 !~ /^Z/ { f = 1 } END { exit !f }'; }
grp_up() { ! grp_gone "$1"; }
dead() { [ ! -d "/proc/$1" ] || grep -q ') Z' "/proc/$1/stat"; }
waitf() { local t=$1 end; shift; end=$(($(date +%s) + t)); while ! "$@"; do [ "$(date +%s)" -lt "$end" ] || return 1; sleep 0.2; done; }
# ev <node> <PR number>: status.log events that name the node and the PR and say "stop".
ev() { grep -i stop "$state/status.log" | grep -F "$1" | grep -cE "#$2([^0-9]|\$)"; }
evis() { [ "$(ev "$1" "$2")" = "$3" ]; }
countis() { [ "$(count "$1")" = "$2" ]; }
loop4() {
	NOODLEBOT_DATA=$data4 PATH=$tmp/bin4:$PATH SCHED_REPORT=0 SCHED_THROTTLE=0 SCHED_TICK=1 SCHED_POLL=0.2 \
		bash "$tmp/nb4/scheduler/loop.sh" o/sc >>"$tmp/s01-loop.out" 2>&1 &
	pids+=("$!"); lp4=$!
}
s01runs() { cat "$S01/runs.$1" 2>/dev/null || echo 0; }
pg() { cat "$state/node/$1/session.pid"; }
loop4; loop1s=$lp4
s01ok "S01 setup: six sessions run, each with a child of its own" waitf 20 sh -c "[ \$(ls '$S01'/child.B0[1-6].1 2>/dev/null | wc -l) = 6 ]"
p1=$(pg B01) p2=$(pg B02) p3=$(pg B03) p4=$(pg B04) p5=$(pg B05) p6=$(pg B06)
c1=$(cat "$S01/child.B01.1" 2>/dev/null) c2=$(cat "$S01/child.B02.1" 2>/dev/null)
s01ok "S01 setup: a session's child is in the session's process group" sh -c "[ \"\$(ps -o pgid= -p '$c1' | tr -d ' ')\" = '$p1' ]"
sleep 2
now=$(date +%s)
printf '13 node/B03-n3 %s 0\n14 node/B04-n4 %s 0\n' $((now - 3600)) "$now" >"$S01/closed.tsv"
echo node/B04-n4 >"$S01/open.txt"
sleep 3.5
s01ok "S01-AC-3: a PR closed before the session started does not stop it" grp_up "$p3"
s01ok "S01-AC-3: a closed PR does not stop the session of a node that also has an open PR" grp_up "$p4"
s01ok "S01-AC-3: nodes with no PR are untouched" grp_up "$p5"
s01ok "S01-AC-3: no stop event for them" sh -c "! grep -i stop '$state/status.log' | grep -qE 'B0[345]'"

echo "11 node/B01-n1" >>"$S01/merged.tsv"; printf '11 node/B01-n1 %s 1\n' "$(date +%s)" >>"$S01/closed.tsv"
s01ok "S01-AC-1: a session whose PR merged while it ran: its process group is gone within a tick" waitf 4 grp_gone "$p1"
s01ok "S01-AC-1: and its child with it" waitf 2 dead "$c1"
s01ok "S01-AC-1: one status-log event names the node and the merged PR" waitf 3 evis B01 11 1
s01ok "S01-AC-1: its evidence is archived to state/archive/B01-out" waitf 3 test -f "$state/archive/B01-out/brief.md"
s01ok "S01-AC-1: its worktree is removed" waitf 3 test ! -d "$wt4/B01"
sleep 3
s01ok "S01-AC-1: the event is not repeated on later ticks" test "$(ev B01 11)" = 1
s01ok "S01-AC-1: the merged node is not started again" test "$(s01runs B01)" = 1

printf '12 node/B02-n2 %s 0\n' "$(date +%s)" >>"$S01/closed.tsv"
s01ok "S01-AC-2: a session whose PR was closed unmerged while it ran: its process group is gone within a tick" waitf 4 grp_gone "$p2"
s01ok "S01-AC-2: and its child with it" waitf 2 dead "$c2"
s01ok "S01-AC-2: one status-log event names the node and the closed PR" waitf 3 evis B02 12 1
s01ok "S01-AC-2: its FAILED marker names the closed PR" waitf 3 sh -c "head -n1 '$state/node/B02/FAILED' | grep -qE '#12([^0-9]|\$)'"
s01ok "S01-AC-2: its worktree remains" test -d "$wt4/B02"
s01ok "S01-AC-2: its branch remains" git -C "$data4/repos/sc" rev-parse --verify -q node/B02-n2
sleep 3
s01ok "S01-AC-2: the event is not repeated on later ticks" test "$(ev B02 12)" = 1
s01ok "S01-AC-2: it is not started on later ticks" test "$(s01runs B02)" = 1
rm -f "$state/node/B02/FAILED"
s01ok "S01-AC-2: after FAILED is deleted it starts again, as start 1 of 2" waitf 4 countis 'started B02 .*start 1 of 2' 2
sleep 3
s01ok "S01-AC-2: the new session is not stopped for the PR closed before it began" sh -c "[ \"\$(cat '$S01/runs.B02')\" = 2 ] && kill -0 \"\$(cat '$state/node/B02/session.pid')\""
s01ok "S01-AC-2: and no second FAILED is written" test ! -e "$state/node/B02/FAILED"

# A session taken over after a restart: the loop is down while B06's PR merges.
kill "$loop1s"; wait "$loop1s" 2>/dev/null
sleep 0.5
c6=$(cat "$S01/child.B06.1" 2>/dev/null)
s01ok "S01 setup: stopping the loop leaves B06's session running" grp_up "$p6"
echo "17 node/B06-n6" >>"$S01/merged.tsv"; printf '17 node/B06-n6 %s 1\n' "$(date +%s)" >>"$S01/closed.tsv"
loop4; loop2s=$lp4
s01ok "S01-AC-1: a taken-over session whose PR merged: its process group is gone within a tick" waitf 4 grp_gone "$p6"
s01ok "S01-AC-1: (taken over) and its child with it" waitf 2 dead "$c6"
s01ok "S01-AC-1: (taken over) one status-log event names the node and the merged PR" waitf 3 evis B06 17 1
s01ok "S01-AC-1: (taken over) its evidence is archived to state/archive/B06-out" waitf 3 test -f "$state/archive/B06-out/brief.md"
s01ok "S01-AC-1: (taken over) its worktree is removed" waitf 3 test ! -d "$wt4/B06"
sleep 2
s01ok "S01-AC-1: (taken over) the event is not repeated" test "$(ev B06 17)" = 1
s01ok "S01-AC-3: after the restart the sessions of B03, B04 and B05 still run" bash -c "$(declare -f grp_gone grp_up); grp_up $p3 && grp_up $p4 && grp_up $p5"

# S01-AC-5: listing closed PRs fails.
kill "$loop2s"; wait "$loop2s" 2>/dev/null
sleep 0.5
printf '16 node/B05-n5 %s 0\n' "$(date +%s)" >>"$S01/closed.tsv"
touch "$S01/closed.fail"; rm -f "$state/node/B07/FAILED"
lines=$(wc -l <"$state/status.log")
loop4; loop3s=$lp4
sleep 4
s01ok "S01-AC-5: a failing closed-PR query stops no session (B05's PR is closed)" grp_up "$p5"
s01ok "S01-AC-5: and starts none (B07 is ready)" test "$(s01runs B07)" = 0
s01ok "S01-AC-5: and the failure is logged" sh -c "tail -n +$((lines + 1)) '$state/status.log' | grep -qiE 'list.*fail|fail.*(list|closed)'"
s01ok "S01-AC-5: and no FAILED is written for B05" test ! -e "$state/node/B05/FAILED"
kill "$loop3s"; wait "$loop3s" 2>/dev/null
s01_cleanup

# ---- S02: a session's background work is not cut off; if it still is, the start is given back ----
# Nodes C01..C05 (no deps) in their own remote, one issue (#71) for triage. The fake claude records
# CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS ("UNSET" when absent) per run in $S02/env.<key>.<run>, and per key/run:
#   C01 run 1: empty exit 0. run 2: the CLI's cut-off message on stderr, exit 0. run 3: QUESTION.md.
#   C02 run 1: empty exit 1. run 2: the cut-off message, exit 5. run 3: QUESTION.md.
#   C03 run 1: empty exit 0. run 2: other stderr text, exit 0 (no cut-off message).
#   C04 run 1: QUESTION.md (started by the second loop, which has the variable set).
#   C05 run 1: exit 1. run 2: other stderr text, exit 7 (no cut-off message).
#   #71 (triage) run 1: the cut-off message, exit 0, no QUESTION.md. run 2: QUESTION.md.
S02=$tmp/s02; export S02
mkdir -p "$S02" "$tmp/bin5" "$tmp/nb5/scheduler" "$tmp/nb5/plugin"
cp "$src"/loop.sh "$src"/ready.py "$src"/release-markers.sh "$src"/run-session.sh "$src"/unattended.md \
	"$src"/issues.py "$src"/unattended-triage.md "$src"/status.sh "$src"/report.py "$src"/usage.py "$tmp/nb5/scheduler/"
git init -q -b main "$tmp/work5"; mkdir -p "$tmp/work5/docs"
{ echo 'nodes:'; for i in 1 2 3 4 5; do echo "  - {id: C0$i, name: n$i, deps: []}"; done; } >"$tmp/work5/docs/graph.yaml"
git -C "$tmp/work5" add -A && git -C "$tmp/work5" -c user.name=t -c user.email=t@t commit -q -m init
git clone -q --bare "$tmp/work5" "$tmp/remote5.git"
data5=$tmp/data5 state=$tmp/data5/state/sd wt5=$tmp/data5/worktrees/sd
S02_STATE=$state; export S02_STATE
mkdir -p "$data5/repos" "$state/node/C04"
git clone -q "$tmp/remote5.git" "$data5/repos/sd"
touch "$state/node/C04/FAILED"   # C04 is started by the second loop
echo '[{"number": 71}]' >"$tmp/issues5.json"
printf '%s\n' 'Background tasks still running 10m after the last turn (subagent "P02 slice 6 GREEN attempt 3"); stopping them. Set CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 to wait indefinitely.' >"$S02/msg"
cat >"$tmp/bin5/gh" <<EOF
#!/bin/sh
echo "\$*" >>"$S02/gh.log"
case " \$* " in
*" --state merged "*) : ;;
*"/issues?labels=noodlebot"*) cat "$tmp/issues5.json" ;;
*"/events"*) echo '[{"event": "labeled", "label": {"name": "noodlebot"}, "actor": {"login": "o"}}]' ;;
*" DELETE "*"/labels/noodlebot"*) echo '[]' ;;
*"/labels"*) cat >/dev/null; echo '{}' ;;
esac
exit 0
EOF
cat >"$tmp/bin5/claude" <<'EOF'
#!/bin/sh
case "$2" in "/noodlebot:triage "*) k=71; q="$S02_STATE/issue/71/QUESTION.md" ;; *) k=${2##* }; q="$S02_STATE/node/$k/QUESTION.md" ;; esac
n=$(( $(cat "$S02/runs.$k" 2>/dev/null || echo 0) + 1 )); echo $n >"$S02/runs.$k"
echo "${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS-UNSET}" >"$S02/env.$k.$n"
[ "$k.$n" = 71.1 ] && touch .s02-kept
case $k.$n in
C01.1) exit 0 ;;
C01.2) cat "$S02/msg" >&2; exit 0 ;;
C01.3|C02.3|C04.1|71.2) echo "Q1: x" >"$q" ;;
C02.1) exit 1 ;;
C02.2) cat "$S02/msg" >&2; exit 5 ;;
C03.1) exit 0 ;;
C03.2) echo "warning: something else" >&2; exit 0 ;;
C05.1) exit 1 ;;
C05.2) echo "warning: something else" >&2; exit 7 ;;
71.1) cat "$S02/msg" >&2; exit 0 ;;
esac
exit 0
EOF
chmod +x "$tmp/bin5/gh" "$tmp/bin5/claude"
s02runs() { cat "$S02/runs.$1" 2>/dev/null || echo 0; }
loop5() {
	env -u CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS "$@" NOODLEBOT_DATA=$data5 PATH=$tmp/bin5:$PATH SCHED_REPORT=0 SCHED_THROTTLE=0 SCHED_TICK=1 SCHED_POLL=0.2 \
		bash "$tmp/nb5/scheduler/loop.sh" o/sd >>"$tmp/s02-loop.out" 2>&1 &
	pids+=("$!"); lp5=$!
}
loop5
timeout 12 sh -c "until [ \"\$(cat '$S02/runs.C01' 2>/dev/null)\" = 3 ] && [ \"\$(cat '$S02/runs.C02' 2>/dev/null)\" = 3 ] && [ \"\$(cat '$S02/runs.71' 2>/dev/null)\" = 2 ] && [ -e '$state/node/C03/FAILED' ] && [ -e '$state/node/C05/FAILED' ]; do sleep 0.2; done"
sleep 1
ok "S02-AC-1: by default every session (node and triage) has the variable in its environment, as 0" sh -c "[ -s '$S02/env.C01.1' ] && [ -s '$S02/env.71.1' ] && [ \"\$(cat '$S02'/env.*)\" = \"\$(for f in '$S02'/env.*; do echo 0; done)\" ]"
ok "S02-AC-2: a node cut off (rc 0) on its second start writes no FAILED" test ! -e "$state/node/C01/FAILED"
ok "S02-AC-2: and starts again (a third run)" test "$(s02runs C01)" = 3
ok "S02-AC-2: its start was given back: the second and the third run are both start 2 of 2" test "$(count 'started C01 .*start 2 of 2')" = 2
ok "S02-AC-2: the end is one status-log event: session, rc, background work cut off, start not counted" test "$(grep -i 'C01' "$state/status.log" | grep -i 'background' | grep -i 'not counted' | grep -c 'rc 0')" = 1
ok "S02-AC-2: that event is the only one for that end (no 'wrote FAILED', no 'may start again' for C01 run 2)" test "$(count 'session C01 ended \(rc 0\), no PR, no QUESTION.md')" = 1
ok "S02-AC-2: a node cut off with a non-zero rc writes no FAILED" test ! -e "$state/node/C02/FAILED"
ok "S02-AC-2: and starts again (a third run)" test "$(s02runs C02)" = 3
ok "S02-AC-2: its start was given back (rc 5): the second and third run are both start 2 of 2" test "$(count 'started C02 .*start 2 of 2')" = 2
ok "S02-AC-2: the end is one status-log event naming rc 5, background work cut off, start not counted" test "$(grep -i 'C02' "$state/status.log" | grep -i 'background' | grep -i 'not counted' | grep -c 'rc 5')" = 1
ok "S02-AC-2: a session with no such message ending empty twice is counted as before: FAILED" test -e "$state/node/C03/FAILED"
ok "S02-AC-2: (and it is not started a third time)" test "$(s02runs C03)" = 1 -o "$(s02runs C03)" = 2
ok "S02-AC-2: its end writes the old 2-starts-used event, not a background one" sh -c "grep -q 'session C03 ended (rc 0).*2 starts used: wrote FAILED' '$state/status.log' && ! grep -i 'C03' '$state/status.log' | grep -qi 'background'"
ok "S02-AC-2: a non-zero rc without the message is counted as before: FAILED" sh -c "[ -e '$state/node/C05/FAILED' ] && grep -q 'session C05 ended (rc 7).*2 starts used: wrote FAILED' '$state/status.log'"
ok "S02-AC-3: a triage cut off with rc 0 and no QUESTION.md does not swap its label (no DELETE of noodlebot)" sh -c "! grep -q 'DELETE.*issues/71/labels/noodlebot' '$S02/gh.log'"
ok "S02-AC-3: it is not reported done" sh -c "! grep -q 'triage of #71 done' '$state/status.log'"
ok "S02-AC-3: its worktree is kept" test -d "$wt5/issue-71"
ok "S02-AC-3: its worktree is kept, not removed and re-made (a file run 1 left there is still there)" test -e "$wt5/issue-71/.s02-kept"
ok "S02-AC-3: its start was given back: both runs are start 1 of 2" test "$(count 'started triage of #71 .*start 1 of 2')" = 2
ok "S02-AC-3: the end is one status-log event (rc 0, background work cut off, start not counted)" test "$(grep -i 'triage of #71' "$state/status.log" | grep -i 'background' | grep -ci 'not counted')" = 1
ok "S02-AC-3: and the triage is started again, then ends with its question" test "$(s02runs 71)" = 2
kill "$lp5"; wait "$lp5" 2>/dev/null
sleep 0.5
rm -f "$state/node/C04/FAILED"
loop5 CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=12345
timeout 10 sh -c "until [ -s '$S02/env.C04.1' ]; do sleep 0.2; done"
ok "S02-AC-1: a value set in the loop's environment reaches the session" sh -c "[ \"\$(cat '$S02/env.C04.1')\" = 12345 ]"
kill "$lp5"; wait "$lp5" 2>/dev/null
for f in "$state"/node/*/session.pid "$state"/issue/*/session.pid; do [ -e "$f" ] && kill -KILL -- "-$(cat "$f")" 2>/dev/null; done

# ---- G01: update sessions for the bot's spec PRs (state/<name>/pr/<N>/, worktrees/<name>/pr-<N>) ----
# A fresh loop (o/up, 1 s tick, the throttle on) over its own remote: main has X01 and X02 (both held by
# FAILED, so no node starts). The fake gh answers the open-PR list from $GD/prs.tsv ("<number> <branch>
# <author login> <is_bot> <mergeable>"; the JSON has number, headRefName, headRefOid, author{login,is_bot},
# mergeable) and evaluates the -q expression itself with a small jq subset (.[], .a.b, |, "\(.x)", select,
# ==, !=, and, or, //, not, startswith, if); $GD/open.fail makes the open-PR list fail.
#   101 spec/c1     bot   CONFLICTING            update
#   102 spec/human  human CONFLICTING            none
#   103 spec/clean  bot   MERGEABLE, no clash    none
#   104 spec/unk    bot   UNKNOWN                none
#   105 node/X03-foo bot  CONFLICTING            none (not a spec/* PR)
#   106 spec/clash  bot   MERGEABLE, its graph names X02 differently from main: update
# The fake claude logs "<kind> <key> run <n> <prompt> | <pwd> | <branch>" to $GD/claude.log and holds
# while $GD/hold.<key> exists (key: the PR number, or t for the triage of issue 46); $GD/limit.<key>.<run>
# makes that run exit 1 with a usage-limit event, $GD/rc.<key>.<run> sets its exit code (default 0).
GD=$tmp/g01; export GD
mkdir -p "$GD" "$tmp/bin6" "$tmp/nb6/scheduler" "$tmp/nb6/plugin" "$tmp/data6"
data6=$(cd "$tmp/data6" && pwd -P)
GD_STATE=$data6/state/up; export GD_STATE
for f in "$src"/*; do case $f in *.test.sh) ;; *) [ -f "$f" ] && cp "$f" "$tmp/nb6/scheduler/" ;; esac; done
cp -R "$src/../plugin/." "$tmp/nb6/plugin/" 2>/dev/null
g6() { git -C "$tmp/work6" -c user.name=t -c user.email=t@t "$@"; }
git init -q -b main "$tmp/work6"; mkdir -p "$tmp/work6/docs"
g01base='nodes:\n  - {id: X01, name: first, deps: []}\n  - {id: X02, name: second, deps: []}\n'
printf "$g01base" >"$tmp/work6/docs/graph.yaml"
g6 add -A && g6 commit -q -m init
git clone -q --bare "$tmp/work6" "$tmp/remote6.git"
# g01branch <branch> <graph text>: a branch off main whose graph is <graph text>.
g01branch() {
	g6 checkout -q -b "$1" main && printf "$2" >"$tmp/work6/docs/graph.yaml" && g6 commit -q -am "$1" &&
		g6 push -q "$tmp/remote6.git" "$1"; g6 checkout -q main
}
for b in spec/c1 spec/human spec/clean spec/unk node/X03-foo spec/lim spec/late; do
	g01branch "$b" "${g01base}  - {id: X03, name: new-${b##*/}, deps: []}\n"
done
g01branch spec/clash 'nodes:\n  - {id: X01, name: first, deps: []}\n  - {id: X02, name: clashing, deps: []}\n'
# mvref <branch>: a new commit on that branch of the remote, same tree (main or the PR's head moves).
mvref() {
	local t c
	t=$(git -C "$tmp/remote6.git" rev-parse "$1^{tree}") &&
		c=$(GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
			git -C "$tmp/remote6.git" commit-tree "$t" -p "$1" -m "move $1 $RANDOM") &&
		git -C "$tmp/remote6.git" update-ref "refs/heads/$1" "$c"
}
mkdir -p "$data6/repos" "$GD_STATE/node/X01" "$GD_STATE/node/X02"
touch "$GD_STATE/node/X01/FAILED" "$GD_STATE/node/X02/FAILED"
git clone -q "$tmp/remote6.git" "$data6/repos/up"
cat >"$GD/prs.tsv" <<'EOF'
101 spec/c1 app/noodlebot true CONFLICTING
102 spec/human tuckermclean false CONFLICTING
103 spec/clean app/noodlebot true MERGEABLE
104 spec/unk app/noodlebot true UNKNOWN
105 node/X03-foo app/noodlebot true CONFLICTING
106 spec/clash app/noodlebot true MERGEABLE
EOF
echo '[]' >"$GD/issues.json"
touch "$GD/hold.101" "$GD/hold.106" "$GD/hold.t" "$GD/limit.107.1"
echo 1 >"$GD/rc.107.2"; echo 1 >"$GD/rc.107.3"
cat >"$GD/gh.py" <<'EOF'
import json, os, re, subprocess, sys
GD = os.environ["GD"]
a = sys.argv[1:]
j = " ".join(a)


class P:
    def __init__(s, t): s.t, s.i = t, 0
    def ws(s):
        while s.i < len(s.t) and s.t[s.i].isspace(): s.i += 1
    def peek(s, x): s.ws(); return s.t.startswith(x, s.i)
    def eat(s, x):
        if s.peek(x): s.i += len(x); return True
        return False
    def need(s, x):
        if not s.eat(x): bad(s.t[s.i:])
    def word(s):
        s.ws(); m = re.compile(r"[A-Za-z_][A-Za-z_0-9]*").match(s.t, s.i)
        if not m: return None
        s.i = m.end(); return m[0]


def bad(rest):
    sys.exit("fake gh: unsupported jq expression near: " + rest)


def truthy(x): return x is not None and x is not False


def text(x): return x if isinstance(x, str) else json.dumps(x)


def pipe(p):
    l = alt(p)
    while p.peek("|") and not p.peek("||"):
        p.eat("|"); r = alt(p)
        l = (lambda l, r: lambda v: (y for x in l(v) for y in r(x)))(l, r)
    return l


def alt(p):
    l = orx(p)
    while p.eat("//"):
        r = orx(p)
        l = (lambda l, r: lambda v: iter([x for x in l(v) if truthy(x)] or list(r(v))))(l, r)
    return l


def kw(p, w):
    p.ws(); m = re.compile(w + r"(?![A-Za-z_0-9])").match(p.t, p.i)
    if m: p.i = m.end(); return True
    return False


def orx(p):
    l = andx(p)
    while kw(p, "or"):
        r = andx(p)
        l = (lambda l, r: lambda v: (truthy(x) or truthy(y) for x in l(v) for y in r(v)))(l, r)
    return l


def andx(p):
    l = cmp(p)
    while kw(p, "and"):
        r = cmp(p)
        l = (lambda l, r: lambda v: (truthy(x) and truthy(y) for x in l(v) for y in r(v)))(l, r)
    return l


def cmp(p):
    l = prim(p)
    for op in ("==", "!="):
        if p.eat(op):
            r = prim(p)
            return (lambda l, r, op: lambda v: ((x == y) == (op == "==") for x in l(v) for y in r(v)))(l, r, op)
    return l


def path(p):
    steps = []
    while True:
        if p.i < len(p.t) and p.t[p.i] == ".":
            m = re.compile(r"\.([A-Za-z_][A-Za-z_0-9]*)").match(p.t, p.i)
            if m: steps.append(m[1]); p.i = m.end(); continue
            if p.t.startswith(".[]", p.i): steps.append(None); p.i += 3; continue
            if len(steps) == 0: p.i += 1; continue
            break
        elif p.t.startswith("[]", p.i): steps.append(None); p.i += 2; continue
        break

    def f(v):
        cur = [v]
        for s in steps:
            nxt = []
            for x in cur:
                if s is None: nxt += list(x)
                else: nxt.append(x.get(s) if isinstance(x, dict) else None)
            cur = nxt
        return iter(cur)
    return f


def prim(p):
    p.ws()
    if p.eat("("):
        e = pipe(p); p.need(")"); return e
    if p.peek('"'):
        p.i += 1; parts = []; buf = ""
        while p.t[p.i] != '"':
            if p.t.startswith("\\(", p.i):
                p.i += 2; parts.append(buf); buf = ""; parts.append(pipe(p)); p.need(")")
            elif p.t[p.i] == "\\":
                buf += {"n": "\n", "t": "\t"}.get(p.t[p.i + 1], p.t[p.i + 1]); p.i += 2
            else: buf += p.t[p.i]; p.i += 1
        p.i += 1; parts.append(buf)
        return lambda v: iter(["".join(x if isinstance(x, str) and k % 2 == 0 else text(next(x(v), None)) if k % 2 else x
                                       for k, x in enumerate(parts))])
    m = re.compile(r"-?[0-9]+").match(p.t, p.i)
    if m: p.i = m.end(); n = int(m[0]); return lambda v: iter([n])
    if p.peek("."): return path(p)
    w = p.word()
    if w in ("null", "true", "false"):
        c = {"null": None, "true": True, "false": False}[w]; return lambda v: iter([c])
    if w == "not": return lambda v: iter([not truthy(v)])
    if w == "length": return lambda v: iter([len(v)])
    if w == "select":
        p.need("("); c = pipe(p); p.need(")")
        return lambda v: (v for x in c(v) if truthy(x))
    if w in ("startswith", "endswith", "test"):
        p.need("("); c = pipe(p); p.need(")")
        fn = {"startswith": lambda v, x: v.startswith(x), "endswith": lambda v, x: v.endswith(x),
              "test": lambda v, x: re.search(x, v) is not None}[w]
        return lambda v: (isinstance(v, str) and fn(v, x) for x in c(v))
    if w == "if":
        c = pipe(p); kw(p, "then"); t = pipe(p); e = lambda v: iter([v])
        if kw(p, "else"): e = pipe(p)
        kw(p, "end")
        return lambda v: (y for x in c(v) for y in (t(v) if truthy(x) else e(v)))
    bad(p.t[p.i:])


def jq(expr, data):
    p = P(expr); f = pipe(p); p.ws()
    if p.i != len(p.t): bad(p.t[p.i:])
    for x in f(data): print(x if isinstance(x, str) else json.dumps(x, separators=(",", ":")))


def prs():
    out = []
    for line in open(GD + "/prs.tsv"):
        f = line.split()
        if len(f) < 5: continue
        oid = subprocess.run(["git", "--git-dir", os.environ["GD"] + "/../remote6.git", "rev-parse", f[1]],
                             capture_output=True, text=True).stdout.strip()
        out.append({"number": int(f[0]), "headRefName": f[1], "headRefOid": oid, "baseRefName": "main",
                    "state": "OPEN", "title": "t", "isCrossRepository": False, "mergeable": f[4],
                    "author": {"login": f[2], "is_bot": f[3] == "true", "name": "", "id": "x"}})
    return out


if a[:2] == ["pr", "list"]:
    if "--state" in a and a[a.index("--state") + 1] == "open":
        if os.path.exists(GD + "/open.fail"):
            print("fake-open-failure", file=sys.stderr); sys.exit(1)
        q = next((a[i + 1] for i, x in enumerate(a) if x in ("-q", "--jq") and i + 1 < len(a)), None)
        if q is None: print(json.dumps(prs()))
        else: jq(q, prs())
    sys.exit(0)
if "/issues?labels=noodlebot" in j: sys.stdout.write(open(GD + "/issues.json").read())
elif "/events" in j: print('[{"event": "labeled", "label": {"name": "noodlebot"}, "actor": {"login": "o"}}]')
elif " DELETE " in " " + j + " " and "/labels/noodlebot" in j: print("[]")
elif "/labels" in j: sys.stdin.read(); print("{}")
sys.exit(0)
EOF
printf '#!/bin/sh\nexec python3 -I "$GD/gh.py" "$@"\n' >"$tmp/bin6/gh"
cat >"$tmp/bin6/claude" <<'EOF'
#!/bin/sh
case "$2" in
"/noodlebot:triage --update "*) k=${2##* }; kind=update ;;
"/noodlebot:triage "*) k=t; kind=triage ;;
*) k=other; kind=other ;;
esac
n=$(( $(cat "$GD/runs.$k" 2>/dev/null || echo 0) + 1 )); echo $n >"$GD/runs.$k"
echo "$kind $k run $n $2 | $(pwd -P) | $(git branch --show-current 2>/dev/null)" >>"$GD/claude.log"
while [ -e "$GD/hold.$k" ]; do sleep 0.2; done
[ $kind = triage ] && echo "Q1: x" >"$GD_STATE/issue/46/QUESTION.md"
if [ -e "$GD/limit.$k.$n" ]; then
	echo '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","unifiedWindows":{"five_hour":{"utilization":1.0,"resetsAt":1,"status":"rejected"}}}}'
	echo '{"type":"result","subtype":"error_during_execution","result":"You have hit your usage limit"}'
	exit 1
fi
exit "$(cat "$GD/rc.$k.$n" 2>/dev/null || echo 0)"
EOF
chmod +x "$tmp/bin6/gh" "$tmp/bin6/claude"
state=$GD_STATE wt6=$data6/worktrees/up
s6runs() { cat "$GD/runs.$1" 2>/dev/null || echo 0; }
runsis() { [ "$(s6runs "$1")" = "$2" ]; }
# pr_ev <N> <pattern>: status-log events that name PR #N and match the pattern.
pr_ev() { grep -E "PR #$1([^0-9]|\$)" "$state/status.log" 2>/dev/null | grep -cE "$2"; }
pr_evis() { [ "$(pr_ev "$1" "$2")" = "$3" ]; }
rl6() { printf '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":%s,"resetsAt":%s,"status":"allowed"},"seven_day":{"utilization":0.0,"resetsAt":%s,"status":"allowed"}}}}\n' "$1" "$2" $(($(date +%s) + 3 * 86400)) >>"$state/node/X01/session.jsonl"; }
loop6() {
	NOODLEBOT_DATA=$data6 PATH=$tmp/bin6:$PATH SCHED_REPORT=0 SCHED_TICK=1 SCHED_POLL=0.2 \
		bash "$tmp/nb6/scheduler/loop.sh" o/up >>"$tmp/g01-loop.out" 2>&1 &
	pids+=("$!"); lp6=$!
}

# AC-5: while the throttle holds, no update starts.
rl6 0.99 $(($(date +%s) + 3600))
loop6
ok "G01-AC-5 setup: the throttle engages" within 8 "throttle engaged"
sleep 2.5
ok "G01-AC-5: while the throttle holds, a bot's CONFLICTING spec PR gets no update" runsis 101 0
ok "G01-AC-5: while the throttle holds, a clashing one gets none either" runsis 106 0
rl6 0.01 $(($(date +%s) + 7200))
ok "G01-AC-5 setup: the throttle is released" within 6 "throttle released"

# AC-5: the CONFLICTING bot PR gets one update session.
ok "G01-AC-5: a bot's CONFLICTING spec PR gets an update session" waitf 8 runsis 101 1
ok "G01-AC-5: its prompt is /noodlebot:triage --update 101" grep -qF "update 101 run 1 /noodlebot:triage --update 101 |" "$GD/claude.log"
ok "G01-AC-5: it runs in worktrees/<name>/pr-101, on the PR's branch" grep -qF "| $wt6/pr-101 | spec/c1" "$GD/claude.log"
ok "G01-AC-5: its state is in state/<name>/pr/101/ (pid recorded)" test -s "$state/pr/101/session.pid"
ok "G01-AC-5: its start is start 1 of 2" waitf 3 pr_evis 101 'start 1 of 2' 1
ok "G01-AC-5: the running note shows the task as PR #101" within 5 "running: .*PR #101 \(pid [0-9]+\)"
if [ "$(s6runs 101)" = 1 ]; then
	# B: while it runs, nothing else starts: not the clashing PR's update, not a triage.
	echo '[{"number": 46}]' >"$GD/issues.json"
	sleep 3
	ok "G01-AC-5: no second update starts while one runs" runsis 106 0
	ok "G01-AC-5: the update is not started a second time" runsis 101 1
	ok "G01-AC-5: no triage starts while an update runs" runsis t 0
	ok "G01-AC-5: a human's PR, a MERGEABLE one with no clash, an UNKNOWN one and a node/* PR get no update" sh -c "! grep -qE '^update 10[2345] ' '$GD/claude.log'"
	# C: it ends with rc 0.
	rm -f "$GD/hold.101"
	ok "G01-AC-6: an update ending with rc 0 is one status-log event" waitf 6 pr_evis 101 'rc 0' 1
	ok "G01-AC-6: and its worktree is removed" test ! -d "$wt6/pr-101"
	# The triage of #46 and the update of #106 want the one slot; whichever starts first holds the other off.
	ok "G01-AC-5: after it, the triage or the clashing PR's update takes the slot" waitf 8 sh -c "[ -s '$GD/runs.t' ] || [ -s '$GD/runs.106' ]"
	if [ -s "$GD/runs.t" ]; then first=t second=106; else first=106 second=t; fi
	sleep 3
	if [ $first = t ]; then
		ok "G01-AC-5: no update starts while a triage runs" runsis 106 0
	else
		ok "G01-AC-5: no triage starts while an update runs" runsis t 0
	fi
	rm -f "$GD/hold.$first"
	ok "G01-AC-5: the other one starts when the first has ended" waitf 8 runsis $second 1
	rm -f "$GD/hold.$second"
	ok "G01-AC-5: a bot's MERGEABLE spec PR whose graph gives X02 of main to a node of another name gets an update" waitf 8 runsis 106 1
	ok "G01-AC-5: it runs in worktrees/<name>/pr-106 on spec/clash" grep -qF "| $wt6/pr-106 | spec/clash" "$GD/claude.log"
	ok "G01-AC-5: it is start 1 of 2, one event" waitf 3 pr_evis 106 'start 1 of 2' 1
	ok "G01-AC-6: its end (rc 0) is one status-log event" waitf 8 pr_evis 106 'rc 0' 1
	ok "G01-AC-6: its worktree is removed" waitf 3 test ! -d "$wt6/pr-106"
	# D: not started again until main or the PR's head moves.
	sleep 3
	ok "G01-AC-6: after rc 0 neither PR is started again while main and the heads stay" sh -c "[ \"\$(cat '$GD/runs.101')\" = 1 ] && [ \"\$(cat '$GD/runs.106')\" = 1 ]"
	sed -i 's/^101 \(.*\) CONFLICTING$/101 \1 MERGEABLE/' "$GD/prs.tsv"
	mvref main
	ok "G01-AC-6: when main moves, a PR that still needs an update is started again" waitf 8 runsis 106 2
	sleep 3
	ok "G01-AC-6: and one that no longer needs it is not (101 is MERGEABLE now)" runsis 101 1
	mvref spec/clash
	ok "G01-AC-6: when only the PR's head moves, it is started again" waitf 8 runsis 106 3
	sleep 2
	ok "G01-AC-6: and each start is one event with its own end (3 starts, 3 ends)" sh -c "[ \"\$(grep -E 'PR #106([^0-9]|\$)' '$state/status.log' | grep -cE 'start [12] of 2')\" = 3 ] && [ \"\$(grep -E 'PR #106([^0-9]|\$)' '$state/status.log' | grep -cE 'rc 0')\" = 3 ]"
else
	fail "G01-AC-5/6: no update started, so the cases that need a running update were not run"
fi

# E: a limit exit uses no start; the second end without rc 0 writes FAILED.
sed -i '/^106 /d' "$GD/prs.tsv"
echo "107 spec/lim app/noodlebot true CONFLICTING" >>"$GD/prs.tsv"
ok "G01-AC-6: a limit exit uses no start: two starts are both start 1 of 2" waitf 12 pr_evis 107 'start 1 of 2' 2
ok "G01-AC-6: the second end without rc 0 writes FAILED" waitf 12 test -e "$state/pr/107/FAILED"
ok "G01-AC-6: the third start is start 2 of 2" pr_evis 107 'start 2 of 2' 1
ok "G01-AC-6: each of the three ends is one status-log event" waitf 5 pr_evis 107 'rc 1' 3
sleep 3
ok "G01-AC-6: with FAILED there, the PR gets no update" runsis 107 3
rm -f "$state/pr/107/FAILED"
ok "G01-AC-6: after FAILED is deleted it is started again" waitf 8 runsis 107 4
ok "G01-AC-6: and that end (rc 0) is one more event" waitf 6 pr_evis 107 'rc 0' 1

# F: a failing PR list starts nothing.
touch "$GD/open.fail"
echo "108 spec/late app/noodlebot true CONFLICTING" >>"$GD/prs.tsv"
lines6=$(wc -l <"$state/status.log")
sleep 3
ok "G01-AC-5: when the PR list fails, no update starts" runsis 108 0
ok "G01-AC-5: and the failure is logged" sh -c "tail -n +$((lines6 + 1)) '$state/status.log' | grep -qi 'pr list failed'"
rm -f "$GD/open.fail"
ok "G01-AC-5: once the list works, the PR gets its update" waitf 8 runsis 108 1
ok "G01-AC-5: a human's PR, a clean MERGEABLE one, an UNKNOWN one and a node/* PR never got an update" sh -c "! grep -qE '^update 10[2345] ' '$GD/claude.log'"
touch "$HOME/STOP-up"
timeout 5 sh -c "while kill -0 $lp6 2>/dev/null; do sleep 0.1; done"
for f in "$state"/pr/*/session.pid "$state"/issue/*/session.pid; do [ -e "$f" ] && kill -KILL -- "-$(cat "$f")" 2>/dev/null; done


# (merge of G01 and S03: both blocks use the same scratch paths; clear them between the blocks)
rm -rf "$tmp/work6" "$tmp/remote6.git" "$tmp/data6" "$tmp/nb6" "$tmp/bin6"

# ---- S03: a merged node's answer starts a follow-up on node/<ID>-followup-<n> ----
# Nodes G01..G08 (no deps) in their own remote, every node's original PR merged (merged.tsv); the fake
# gh answers --state merged/open/closed from $S03/{merged.tsv,open.txt,closed.tsv} (closed.tsv as in S01).
# The fake claude records per run (key <ID>.<n>) in $S03: pwd.*, br.* (branch), head.* (HEAD at start),
# log.* (commit subjects), ans.* (what answered/ holds), sys.* (the appended prompt); and per node:
#   G01 run 1: commits, writes out/node/G01/brief.md, waits for go.G01.1, asks QUESTION.md.
#       run 2: waits for go.G01.2, then opens its PR (adds the branch to open.txt). run 3: runs until stopped.
#   G02 and G03 run 1: run until stopped (G02: its follow-up PR merges, G03: it is closed unmerged).
#   G04: every run ends empty (rc 0).   G05 run 1: opens its follow-up PR (open.txt), exits.
#   G06: no markers. G07: unanswered QUESTION.md. G08: answered; a follow-up PR (#81, followup-1) merged
#       earlier, no branch of it anywhere; its run runs until stopped.
S03=$tmp/s03; export S03
mkdir -p "$S03" "$tmp/bin6" "$tmp/nb6/scheduler" "$tmp/nb6/plugin"
cp "$S01/closed.py" "$S03/closed.py"
cp "$src"/loop.sh "$src"/ready.py "$src"/release-markers.sh "$src"/run-session.sh "$src"/unattended.md \
	"$src"/issues.py "$src"/unattended-triage.md "$src"/status.sh "$src"/report.py "$src"/usage.py "$tmp/nb6/scheduler/"
[ -f "$src/unattended-followup.md" ] && cp "$src/unattended-followup.md" "$tmp/nb6/scheduler/"
git init -q -b main "$tmp/work6"; mkdir -p "$tmp/work6/docs"
{ echo 'nodes:'; for i in 1 2 3 4 5 6 7 8; do echo "  - {id: G0$i, name: n$i, deps: []}"; done; } >"$tmp/work6/docs/graph.yaml"
git -C "$tmp/work6" add -A && git -C "$tmp/work6" -c user.name=t -c user.email=t@t commit -q -m init
git clone -q --bare "$tmp/work6" "$tmp/remote6.git"
data6=$tmp/data6 st6=$tmp/data6/state/sf wt6=$tmp/data6/worktrees/sf cl6=$tmp/data6/repos/sf
S03_STATE=$st6; export S03_STATE
mkdir -p "$data6/repos" "$st6/node" "$st6/archive/G01-out"
git clone -q "$tmp/remote6.git" "$cl6"
echo old-evidence >"$st6/archive/G01-out/brief.md"
printf '%s\n' '20 node/G01-n1' '90 node/G02-n2' '30 node/G03-n3' '40 node/G04-n4' '50 node/G05-n5' '60 node/G06-n6' '70 node/G07-n7' '80 node/G08-n8' '81 node/G08-followup-1' >"$S03/merged.tsv"
: >"$S03/open.txt"; : >"$S03/closed.tsv"
for i in 1 2 3 4 5 8; do
	mkdir -p "$st6/node/G0$i"; echo "Q1: which way?" >"$st6/node/G0$i/QUESTION.md"; echo "Q1: as recommended" >"$st6/node/G0$i/ANSWER.md"
done
mkdir -p "$st6/node/G07"; echo "Q1: still open" >"$st6/node/G07/QUESTION.md"
cat >"$tmp/bin6/gh" <<'EOF'
#!/bin/sh
case " $* " in
*" --state merged "*) cat "$S03/merged.tsv" ;;
*" --state open "*) cat "$S03/open.txt" ;;
*" --state closed "*) S01=$S03 exec python3 -I "$S03/closed.py" "$@" ;;
*"/issues?labels=noodlebot"*) echo '[]' ;;
esac
exit 0
EOF
cat >"$tmp/bin6/claude" <<'EOF'
#!/bin/sh
id=${2##* } d=$S03
n=$(( $(cat "$d/runs.$id" 2>/dev/null || echo 0) + 1 )); echo $n >"$d/runs.$id"
pwd -P >"$d/pwd.$id.$n"
git rev-parse --abbrev-ref HEAD >"$d/br.$id.$n" 2>/dev/null
git rev-parse HEAD >"$d/head.$id.$n" 2>/dev/null
git log --format=%s >"$d/log.$id.$n" 2>/dev/null
ls "$S03_STATE/node/$id/answered" 2>/dev/null | sed 's/^[0-9TZ]*-//' | sort | tr '\n' ' ' >"$d/ans.$id.$n"
prev=; for a in "$@"; do [ "$prev" = --append-system-prompt ] && printf '%s\n' "$a" >"$d/sys.$id.$n"; prev=$a; done
commit() { git -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$1"; }
wait_for() { while [ ! -e "$d/$1" ]; do sleep 0.2; done; }
hang() { sleep 300 & echo $! >"$d/child.$id.$n"; while :; do sleep 0.2; done; }
case $id.$n in
G01.1) mkdir -p out/node/G01; echo fu-evidence >out/node/G01/brief.md; commit "G01 follow-up work"
	wait_for go.G01.1; echo "Q1: more" >"$S03_STATE/node/G01/QUESTION.md" ;;
G01.2) wait_for go.G01.2; echo node/G01-followup-1 >>"$d/open.txt" ;;
G01.3|G03.1|G08.1) hang ;;
G02.1) mkdir -p out/node/G02; echo g02-evidence >out/node/G02/brief.md; hang ;;
G05.1) echo node/G05-followup-1 >>"$d/open.txt" ;;
esac
exit 0
EOF
chmod +x "$tmp/bin6/gh" "$tmp/bin6/claude"
st=$st6
s3dead=0
# s3ok <name> <seconds> <command...>: PASS when the command succeeds within that time; after the first
# failed wait every later wait is 1 s, so a run against a missing feature still ends quickly.
s3ok() { local name=$1 t=$2; shift 2; [ "$s3dead" = 1 ] && t=1; if waitf "$t" "$@"; then pass "$name"; else fail "$name"; s3dead=1; fi; }
s3chk() { local name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
s3sleep() { [ "$s3dead" = 1 ] || sleep "$1"; }
s3runs() { cat "$S03/runs.$1" 2>/dev/null || echo 0; }
s3n() { local n; n=$(grep -cE "$1" "$st6/status.log" 2>/dev/null); echo "${n:-0}"; }
s3has() { grep -qE "$1" "$st6/status.log" 2>/dev/null; }
s3cnt() { [ "$(s3n "$1")" = "$2" ]; }
s3eq() { [ "$1" = "$2" ]; }
s3f() { cat "$S03/$1" 2>/dev/null; }
s3pg() { grp_up "$(cat "$st6/node/$1/session.pid" 2>/dev/null || echo 999999)"; }
s3pgn() { ! s3pg "$1"; }
s3runsis() { [ "$(s3runs "$1")" = "$2" ]; }
s3stopev() { local n; n=$(grep -i stop "$st6/status.log" | grep -F "$1" | grep -cE "#$2([^0-9]|\$)"); [ "${n:-0}" = "$3" ]; }
s3released() { ls "$st6/node/$1/answered" 2>/dev/null | grep -q 'QUESTION.md$' && ls "$st6/node/$1/answered" | grep -q 'ANSWER.md$' &&
	[ ! -e "$st6/node/$1/QUESTION.md" ] && [ ! -e "$st6/node/$1/ANSWER.md" ]; }
s3started() { local i; for i in G01 G02 G03 G04 G05 G08; do [ "$(s3runs $i)" -ge 1 ] || return 1; done; }
s3wtown() { local w p; w=$(cd "$wt6" && pwd -P) || return 1; p=$(s3f "pwd.$1"); case $p in "$w"/*) [ -e "$p/.git" ] ;; *) return 1 ;; esac; }
s3origin() { git -C "$cl6" rev-parse origin/main; }
s3firstcommit() { [ "$(s3f "head.$1")" = "$(s3origin)" ] && [ "$(git -C "$cl6" rev-parse "$2^")" = "$(s3origin)" ]; }
s3brs() { [ "$(git -C "$cl6" branch --list "node/$1-followup-*" | wc -l)" = "$2" ]; }
s3prompt() { [ -s "$S03/sys.G01.1" ] && grep -qiE "$1" "$S03/sys.G01.1"; }
s3promptF() { [ -s "$S03/sys.G01.1" ] && grep -qF "$1" "$S03/sys.G01.1"; }
s3dumplog() { echo "      status.log (tail):"; tail -n 40 "$st6/status.log" 2>/dev/null | sed 's/^/      /'; }
s3_cleanup() {
	local f
	for f in "$st6"/node/*/session.pid; do [ -e "$f" ] && kill -KILL -- "-$(cat "$f")" 2>/dev/null; done
	for f in "$S03"/child.*; do [ -e "$f" ] && kill -KILL "$(cat "$f")" 2>/dev/null; done
	return 0
}
fails0=$fails
loop6() {
	NOODLEBOT_DATA=$data6 PATH=$tmp/bin6:$PATH SCHED_REPORT=0 SCHED_THROTTLE=0 SCHED_TICK=1 SCHED_POLL=0.2 \
		bash "$tmp/nb6/scheduler/loop.sh" o/sf >>"$tmp/s03-loop.out" 2>&1 &
	pids+=("$!"); lp6=$!
}
state=$st6
loop6
s3ok "S03-AC-2: each merged node with an answered question starts a session" 20 s3started
s3sleep 1

# AC-2: the first follow-up of G01.
s3ok "S03-AC-2: the answered question is moved into answered/ (QUESTION.md and ANSWER.md)" 5 s3released G01
s3ok "S03-AC-2: one session starts, as start 1 of 2, naming the node and branch node/G01-followup-1" 5 s3has 'started G01 .*node/G01-followup-1.*start 1 of 2'
s3chk "S03-AC-2: that start is the only status-log event that names node/G01-followup-1" s3cnt 'node/G01-followup-1' 1
s3ok "S03-AC-2: (G01) its session has recorded its branch, HEAD and worktree (run 1)" 8 sh -c "[ -s '$S03/br.G01.1' ] && [ -s '$S03/head.G01.1' ] && [ -s '$S03/pwd.G01.1' ]"
s3chk "S03-AC-2: the session ran on branch node/G01-followup-1" s3eq "$(s3f br.G01.1)" node/G01-followup-1
s3chk "S03-AC-2: in a new worktree of its own under the worktrees folder" s3wtown G01.1
s3ok "S03-AC-2: (G01) its session has made its first commit" 8 sh -c "[ \"\$(git -C '$cl6' rev-parse node/G01-followup-1)\" != \"\$(git -C '$cl6' rev-parse origin/main)\" ]"
s3chk "S03-AC-2: whose first commit is origin/main's head (HEAD at start, and the branch's first commit)" s3firstcommit G01.1 node/G01-followup-1
s3chk "S03-AC-2: the node started once" s3eq "$(s3runs G01)" 1
s3ok "S03-AC-2: G08 had a follow-up whose PR is merged (no branch of it): the next one starts on node/G08-followup-2" 5 s3has 'started G08 .*node/G08-followup-2.*start 1 of 2'
s3ok "S03-AC-2: (G08) its session has recorded its branch" 8 sh -c "[ -s '$S03/br.G08.1' ]"
s3chk "S03-AC-2: (G08) the session ran on node/G08-followup-2" s3eq "$(s3f br.G08.1)" node/G08-followup-2
s3chk "S03-AC-2: (G08) no branch node/G08-followup-1 was made" s3brs G08 1

# AC-3: the appended prompt.
s3ok "S03-AC-3: (G01) its session has recorded its appended prompt" 8 sh -c "[ -s '$S03/sys.G01.1' ]"
s3chk "S03-AC-3: the session's appended prompt is the node's unattended.md in its state folder" test -s "$S03/sys.G01.1" -a "$(cat "$st6/node/G01/unattended.md" 2>/dev/null)" = "$(s3f sys.G01.1)"
s3chk "S03-AC-3: it says the node's PR is merged" s3prompt "PR (is|was|has been|is already|was already) merged|already merged"
s3chk "S03-AC-3: it says the answer is carried out as a follow-up PR" s3prompt 'follow-?up PR'
s3chk "S03-AC-3: or as a spec PR with WAITING-PR" sh -c "grep -qi 'spec PR' '$S03/sys.G01.1' && grep -qF WAITING-PR '$S03/sys.G01.1'"
s3chk "S03-AC-3: it names the node's answered/ folder" s3promptF "$st6/node/G01/answered"
s3chk "S03-AC-3: it names state/archive/G01-out" s3promptF "state/archive/G01-out"
s3chk "S03-AC-3: it names the clone's local branches" s3prompt 'local branch'
s3chk "S03-AC-3: it keeps the rule for QUESTION.md (the node's file, and how the owner answers)" sh -c "grep -qF '$st6/node/G01/QUESTION.md' '$S03/sys.G01.1' && grep -qF 'write ANSWER.md next to this file' '$S03/sys.G01.1'"
s3chk "S03-AC-3: it keeps the rule for WAITING-PR (the node's file)" s3promptF "$st6/node/G01/WAITING-PR"
s3chk "S03-AC-3: it keeps the rules for GitHub access" sh -c "grep -qF '~/.config/noodlebot/token' '$S03/sys.G01.1' && grep -qF 'Never print, echo or log a token' '$S03/sys.G01.1'"
s3chk "S03-AC-3: it keeps the rule for closing keywords" s3prompt 'closing keyword'
s3chk "S03-AC-3: it has no unfilled placeholder" sh -c "[ -s '$S03/sys.G01.1' ] && ! grep -qE '@[A-Z]+@' '$S03/sys.G01.1'"

# AC-4: G02 and G03, running follow-ups.
s3sleep 3
s3chk "S03-AC-4: a running follow-up (G02) is not stopped while the node's earlier PR is merged" s3pg G02
s3chk "S03-AC-4: (G02) and no event says it was stopped" test "$(s3n 'stopped session G02')" = 0
s3chk "S03-AC-4: the same for G03" s3pg G03
s3chk "S03-AC-4: the same for G08" s3pg G08
s3chk "S03-AC-4: (G02, G03, G08) each ran once" s3eq "$(s3runs G02)$(s3runs G03)$(s3runs G08)" 111
now=$(date +%s)
p2=$(cat "$st6/node/G02/session.pid" 2>/dev/null || echo 999999) p3=$(cat "$st6/node/G03/session.pid" 2>/dev/null || echo 999999)
s3ok "S03-AC-4: (G02, G03) their sessions have recorded their children" 8 sh -c "[ -s '$S03/child.G02.1' ] && [ -s '$S03/child.G03.1' ]"
c2=$(s3f child.G02.1) c3=$(s3f child.G03.1)
echo "21 node/G02-followup-1" >>"$S03/merged.tsv"; printf '21 node/G02-followup-1 %s 1\n' "$now" >>"$S03/closed.tsv"
s3ok "S03-AC-4: a follow-up whose own PR is merged: its process group is gone within a tick" 4 grp_gone "$p2"
s3ok "S03-AC-4: (G02) and its child with it" 2 dead "${c2:-999999}"
s3ok "S03-AC-4: (G02) one status-log event names the node and the follow-up's PR #21" 3 s3stopev G02 21 1
s3chk "S03-AC-4: (G02) that event does not name the earlier PR #90" s3stopev G02 90 0
s3ok "S03-AC-6: (G02) its FOLLOWUP marker is moved into answered/" 3 sh -c "ls '$st6/node/G02/answered' | grep -q FOLLOWUP && [ ! -e '$st6/node/G02/FOLLOWUP' ]"
s3ok "S03-AC-6: (G02) once no session runs, its evidence is archived under state/archive/" 4 grep -rqx g02-evidence "$st6/archive"
s3ok "S03-AC-6: (G02) and its worktree is removed" 3 test ! -d "$(s3f pwd.G02.1)"
printf '22 node/G03-followup-1 %s 0\n' "$(date +%s)" >>"$S03/closed.tsv"
s3ok "S03-AC-4: a follow-up whose PR is closed unmerged after it started: its process group is gone within a tick" 4 grp_gone "$p3"
s3ok "S03-AC-4: (G03) and its child with it" 2 dead "${c3:-999999}"
s3ok "S03-AC-4: (G03) one status-log event names the node and the closed PR #22" 3 s3stopev G03 22 1
s3ok "S03-AC-4: (G03) FAILED names the closed PR #22" 3 sh -c "head -n1 '$st6/node/G03/FAILED' | grep -qE '#22([^0-9]|\$)'"
s3chk "S03-AC-4: (G03) with starts 0" s3eq "$(cat "$st6/node/G03/starts" 2>/dev/null)" 0
s3chk "S03-AC-4: (G03) its worktree remains" test -d "$(s3f pwd.G03.1)"
s3chk "S03-AC-4: (G03) its branch remains" git -C "$cl6" rev-parse --verify -q node/G03-followup-1

# AC-5: G04 ends empty twice, G05 opens its PR.
s3ok "S03-AC-5: a follow-up that ends with no PR on its branch is not logged as ended with a PR; its first end may start again" 5 s3has 'session G04 ended \(rc 0\), no PR, no QUESTION.md; may start again'
s3ok "S03-AC-5: it starts again on the same branch as start 2 of 2" 5 s3has 'started G04 .*node/G04-followup-1.*start 2 of 2'
s3ok "S03-AC-5: its second such end writes FAILED, 2 starts used" 5 s3has 'session G04 ended \(rc 0\).*2 starts used: wrote FAILED'
s3chk "S03-AC-5: FAILED is on disk with starts 0" sh -c "[ -e '$st6/node/G04/FAILED' ] && [ \"\$(cat '$st6/node/G04/starts')\" = 0 ]"
s3chk "S03-AC-5: neither end is logged as ended with a PR" s3cnt 'session G04 ended.*with a PR' 0
s3chk "S03-AC-5: both runs were on the same follow-up branch, in the same worktree" sh -c "[ '$(s3f br.G04.1)' = node/G04-followup-1 ] && [ '$(s3f br.G04.2)' = node/G04-followup-1 ] && [ '$(s3f pwd.G04.1)' = '$(s3f pwd.G04.2)' ]"
s3chk "S03-AC-5: and no second follow-up number was taken" s3brs G04 1
s3ok "S03-AC-5: a follow-up that opened its PR (G05) is logged as ended with a PR" 5 s3has 'session G05 ended \(rc 0\) with a PR'
s3sleep 3
s3chk "S03-AC-5: it does not start again while its follow-up PR is open" s3eq "$(s3runs G05)$(s3runs G04)" 12
s3chk "S03-AC-5: (G05) started once" s3cnt 'started G05 ' 1

# AC-2: a merged node with no markers, or an unanswered question, starts no session.
s3chk "S03-AC-2: a merged node with no markers starts no session" sh -c "[ '$(s3runs G06)' = 0 ] && ! grep -q 'started G06' '$st6/status.log' && [ \"\$(git -C '$cl6' branch --list 'node/G06-*' | wc -l)\" = 0 ]"
s3chk "S03-AC-2: a merged node with an unanswered QUESTION.md starts no session" sh -c "[ '$(s3runs G07)' = 0 ] && ! grep -q 'started G07' '$st6/status.log' && [ -e '$st6/node/G07/QUESTION.md' ] && [ ! -d '$st6/node/G07/answered' ]"

# AC-6 (and AC-2, AC-4, AC-5): G01 asks a question, is answered, opens its PR, merges; then a second follow-up.
touch "$S03/go.G01.1"
s3ok "S03-AC-6: a follow-up that asks a question: the session ends with QUESTION.md" 5 s3has 'session G01 ended \(rc 0\) with QUESTION.md'
s3sleep 3
w1=$(s3f pwd.G01.1)
s3chk "S03-AC-6: its worktree stays" test -d "$w1"
s3chk "S03-AC-6: its branch stays" git -C "$cl6" rev-parse --verify -q node/G01-followup-1
s3chk "S03-AC-6: its earlier commit is in the worktree" sh -c "git -C '$w1' log --format=%s | grep -qx 'G01 follow-up work'"
echo "Q1: yes" >"$st6/node/G01/ANSWER.md"
s3ok "S03-AC-6: after the answer the next session starts (run 2)" 8 s3runsis G01 2
s3ok "S03-AC-6: its second session has recorded its files (run 2)" 8 sh -c "[ -s '$S03/br.G01.2' ] && [ -s '$S03/pwd.G01.2' ]"
s3ok "S03-AC-6: (G01) its second session has recorded its log and answers (run 2)" 8 sh -c "[ -s '$S03/log.G01.2' ] && [ -s '$S03/ans.G01.2' ]"
s3chk "S03-AC-6: it runs on the same follow-up branch" s3eq "$(s3f br.G01.2)" node/G01-followup-1
s3chk "S03-AC-6: in the same worktree" s3eq "$(s3f pwd.G01.2)" "$(s3f pwd.G01.1)"
s3chk "S03-AC-6: with its earlier commit" grep -qx 'G01 follow-up work' "$S03/log.G01.2"
s3chk "S03-AC-6: and both answers in answered/" sh -c "[ \"\$(grep -o 'ANSWER.md' '$S03/ans.G01.2' | wc -l)\" = 2 ]"
s3chk "S03-AC-6: no new follow-up number is taken" sh -c "[ \"\$(git -C '$cl6' branch --list 'node/G01-followup-*' | wc -l)\" = 1 ] && ! grep -q 'node/G01-followup-2' '$st6/status.log'"
s3chk "S03-AC-6: the second start names the same branch, as start 1 of 2" s3cnt 'started G01 .*node/G01-followup-1.*start 1 of 2' 2
touch "$S03/go.G01.2"
s3ok "S03-AC-5: (G01) a follow-up whose PR is open: its end is logged as ended with a PR" 5 s3has 'session G01 ended \(rc 0\) with a PR'
s3sleep 3
s3chk "S03-AC-5: (G01) it does not start again while its follow-up PR is open" s3eq "$(s3runs G01)" 2
sed -i '/node\/G01-followup-1/d' "$S03/open.txt"
echo "31 node/G01-followup-1" >>"$S03/merged.tsv"; printf '31 node/G01-followup-1 %s 1\n' "$(date +%s)" >>"$S03/closed.tsv"
s3ok "S03-AC-6: once its PR is merged, the FOLLOWUP marker is moved into answered/" 5 sh -c "ls '$st6/node/G01/answered' | grep -q FOLLOWUP && [ ! -e '$st6/node/G01/FOLLOWUP' ]"
s3ok "S03-AC-6: and, no session running, its evidence is archived under state/archive/ (without replacing the earlier G01-out)" 5 sh -c "grep -rqx fu-evidence '$st6/archive' && grep -qx old-evidence '$st6/archive/G01-out/brief.md'"
s3ok "S03-AC-6: and its worktree is removed" 5 test ! -d "$w1"
s3sleep 3
s3chk "S03-AC-6: the node starts no session at later ticks" s3eq "$(s3runs G01)" 2
s3chk "S03-AC-6: and nothing says it was stopped" test "$(s3n 'stopped session G01')" = 0
# a later answer: the next follow-up number
echo "Q2: next?" >"$st6/node/G01/QUESTION.md"; echo "Q2: go" >"$st6/node/G01/ANSWER.md"
s3ok "S03-AC-2: after a merged follow-up, the next answered question starts node/G01-followup-2" 8 s3has 'started G01 .*node/G01-followup-2.*start 1 of 2'
s3ok "S03-AC-2: (G01) its session has started (run 3)" 8 sh -c "[ -s '$S03/br.G01.3' ] && [ -s '$S03/head.G01.3' ]"
s3chk "S03-AC-2: (G01) the session ran on node/G01-followup-2" s3eq "$(s3f br.G01.3)" node/G01-followup-2
s3chk "S03-AC-2: (G01) whose first commit is origin/main's head" sh -c "[ '$(s3f head.G01.3)' = '$(s3origin)' ] && [ \"\$(git -C '$cl6' rev-parse node/G01-followup-2)\" = '$(s3origin)' ]"
s3sleep 4
s3chk "S03-AC-4: (G01) it is not stopped while the earlier follow-up's PR #31 and the node's PR are merged" s3pg G01
s3chk "S03-AC-4: (G01) and nothing says it was stopped" test "$(s3n 'stopped session G01')" = 0
s3chk "S03-AC-4: (G01) it ran once more, not again" s3eq "$(s3runs G01)" 3

kill "$lp6"; wait "$lp6" 2>/dev/null
s3_cleanup
[ "$fails" -eq "$fails0" ] || s3dumplog

# ---- S04: a node that stopped before its PR resumes: the stop is recorded, leftover changes are saved as a patch ----
# Nodes E01..E07 (no deps) in their own remote, data dir and loop (o/s4, 1 s tick). main carries base.txt, d.txt and
# a .gitignore (out/, *.ign). The fake claude snapshots, at the start of every run, the rendered unattended.md,
# the stopped file, the leftover listing, git status --porcelain, HEAD, the branch, the brief and base.txt into
# $S04/rec/<ID>.<run>/ (done is written last), then per node and run:
#   E01 run 1: 3 commits, out/node/E01/brief.md, a modified tracked file, a staged new file, a deleted tracked
#              file, an untracked file, ignored files; usage-limit events, exit 1. run 2: QUESTION.md.
#   E02 run 1: 1 commit, brief, a modified file, then kills itself with SIGTERM (rc 143). run 2: QUESTION.md.
#   E03 run 1: 2 commits, brief, clean worktree, exit 3. run 2: QUESTION.md.
#   E04 (fresh) run 1: QUESTION.md.
#   E05 run 1: only out/node/E05/brief.md (no commit, nothing to save), exit 4. run 2: QUESTION.md.
#   E06 run 1: 1 commit, brief, a modified file, kills run-session.sh (no session.rc). run 2: QUESTION.md.
#   E07 run 1: 1 commit, brief, a modified file, makes state/node/E07/leftover a plain file (no patch can be
#              written there), exit 1.
S04=$tmp/s04; export S04
mkdir -p "$S04/rec" "$tmp/bin7" "$tmp/nb7/scheduler" "$tmp/nb7/plugin" "$tmp/data7/repos"
data7=$(cd "$tmp/data7" && pwd -P)
st4=$data7/state/s4 wt7=$data7/worktrees/s4
S04_STATE=$st4; export S04_STATE
for f in "$src"/*; do case $f in *.test.sh) ;; *) [ -f "$f" ] && cp "$f" "$tmp/nb7/scheduler/" ;; esac; done
git init -q -b main "$tmp/work7"; mkdir -p "$tmp/work7/docs"
{ echo 'nodes:'; for i in 1 2 3 4 5 6 7; do echo "  - {id: E0$i, name: n$i, deps: []}"; done; } >"$tmp/work7/docs/graph.yaml"
printf 'base\n' >"$tmp/work7/base.txt"; printf 'doomed\n' >"$tmp/work7/d.txt"; printf 'out/\n*.ign\n' >"$tmp/work7/.gitignore"
git -C "$tmp/work7" add -A && git -C "$tmp/work7" -c user.name=t -c user.email=t@t commit -q -m init
git clone -q --bare "$tmp/work7" "$tmp/remote7.git"
git clone -q "$tmp/remote7.git" "$data7/repos/s4"
cat >"$tmp/bin7/gh" <<'EOF'
#!/bin/sh
case " $* " in
*"/issues?labels=noodlebot"*) echo '[]' ;;
esac
exit 0
EOF
cat >"$tmp/bin7/claude" <<'EOF'
#!/bin/sh
id=${2##* }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
n=$(( $(cat "$S04/runs.$id" 2>/dev/null || echo 0) + 1 )); echo $n >"$S04/runs.$id"
r=$S04/rec/$id.$n; mkdir -p "$r"
cp "$S04_STATE/node/$id/unattended.md" "$r/prompt" 2>/dev/null
cp "$S04_STATE/node/$id/stopped" "$r/stopped" 2>/dev/null
ls "$S04_STATE/node/$id/leftover" >"$r/leftover" 2>/dev/null
git status --porcelain >"$r/status" 2>&1
git rev-parse HEAD >"$r/head" 2>&1; git rev-parse --abbrev-ref HEAD >"$r/branch" 2>&1
cp "out/node/$id/brief.md" "$r/brief" 2>/dev/null
cp "out/node/$id/log.txt" "$r/log" 2>/dev/null
cp cache.ign "$r/ign" 2>/dev/null
cat base.txt >"$r/base" 2>/dev/null
touch "$r/done"
commits() { i=0; while [ $i -lt $1 ]; do i=$((i + 1)); echo "$id $i" >"c$i.txt"; git add "c$i.txt"; git commit -qm "$id commit $i"; done; }
brief() { mkdir -p "out/node/$id"; echo "brief of $id v1" >"out/node/$id/brief.md"; echo "log of $id" >"out/node/$id/log.txt"; cp "out/node/$id/brief.md" "$S04/brief1.$id"; git rev-parse HEAD >"$S04/head1.$id"; }
limit() {
	echo '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","unifiedWindows":{"five_hour":{"utilization":1.0,"resetsAt":1,"status":"rejected"}}}}'
	echo '{"type":"result","subtype":"error_during_execution","result":"You have hit your usage limit"}'
}
q() { echo "Q1: x" >"$S04_STATE/node/$id/QUESTION.md"; }
case $id.$n in
E01.1) commits 3; brief; echo more >>base.txt; rm d.txt; echo staged >s.txt; git add s.txt; echo untracked >u.txt; echo cache >cache.ign; limit; exit 1 ;;
E02.1) commits 1; brief; echo more >>base.txt; git rev-parse HEAD >"$S04/head1.$id"; kill -TERM $$; sleep 5 ;;
E03.1) commits 2; brief; exit 3 ;;
E04.1) q ;;
E05.1) brief; exit 4 ;;
E06.1) commits 1; brief; echo more >>base.txt; kill -KILL $PPID; exit 0 ;;
E07.1) commits 1; brief; echo more >>base.txt; echo not-a-dir >"$S04_STATE/node/$id/leftover"; exit 1 ;;
*.2) q ;;
esac
exit 0
EOF
chmod +x "$tmp/bin7/gh" "$tmp/bin7/claude"
s4f() { cat "$S04/rec/$1/$2" 2>/dev/null; }
s4have() { [ -e "$S04/rec/$1/done" ]; }
s4runs() { cat "$S04/runs.$1" 2>/dev/null || echo 0; }
s4wait() { local t=$1; shift; timeout "$t" sh -c 'until "$@"; do sleep 0.2; done' _ "$@" 2>/dev/null; }
s4ok() { local name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
s4log() { cat "$st4/status.log" 2>/dev/null; }
s4stopped_is() { # <run> <reason regex>: the stopped file seen at that run's start is one line: UTC time and the reason
	local f="$S04/rec/$1/stopped"
	[ -f "$f" ] && [ "$(wc -l <"$f")" = 1 ] && grep -Eq "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z.*$2\$" "$f"
}
s4resume() { # <run>: the rendered prompt carries the resume section
	local f="$S04/rec/$1/prompt"
	grep -qF 'git log origin/main..HEAD' "$f" 2>/dev/null && grep -qF 'gh run list --branch' "$f"
}
s4patch() { ls "$st4/node/$1/leftover"/*.patch 2>/dev/null | head -1; }
S04_LOOP_OUT=$tmp/s04-loop.out
NOODLEBOT_DATA=$data7 PATH=$tmp/bin7:$PATH SCHED_REPORT=0 SCHED_THROTTLE=0 SCHED_TICK=1 SCHED_POLL=0.2 \
	bash "$tmp/nb7/scheduler/loop.sh" o/s4 >>"$S04_LOOP_OUT" 2>&1 &
pids+=("$!"); lp7=$!
s4wait 25 sh -c "[ -e '$S04/rec/E01.2/done' ] && [ -e '$S04/rec/E02.2/done' ] && [ -e '$S04/rec/E03.2/done' ] && [ -e '$S04/rec/E05.2/done' ] && [ -e '$S04/rec/E06.2/done' ] && [ -e '$S04/rec/E04.1/done' ]"
s4wait 5 sh -c "[ \"\$(cat '$S04/runs.E07' 2>/dev/null)\" = 1 ]"
sleep 3
w1=$wt7/E01
p1=$(s4patch E01); pb1=$(basename "$p1" 2>/dev/null)
# AC-1: the stopped file
s4ok "S04-AC-1: a limit exit: at the next start the stopped file is one line, UTC time and 'usage limit'" s4stopped_is E01.2 'usage limit'
s4ok "S04-AC-1: a session killed by SIGTERM: 'stopped (signal 15)'" s4stopped_is E02.2 'stopped \(signal 15\)'
s4ok "S04-AC-1: an exit with code 3: 'rc 3'" s4stopped_is E03.2 'rc 3'
s4ok "S04-AC-1: an exit with code 4 (no commit): 'rc 4'" s4stopped_is E05.2 'rc 4'
s4ok "S04-AC-1: run-session.sh killed, no session.rc: 'stopped (no exit code)'" s4stopped_is E06.2 'stopped \(no exit code\)'
s4ok "S04-AC-1: a fresh node has no stopped file" test ! -e "$S04/rec/E04.1/stopped"
s4ok "S04-AC-1: the stopped file is gone after the later session ends with QUESTION.md (E01)" sh -c "[ -s '$S04/rec/E01.2/stopped' ] && [ -e '$st4/node/E01/QUESTION.md' ] && [ ! -e '$st4/node/E01/stopped' ]"
s4ok "S04-AC-1: (E02, E03, E05, E06 too)" sh -c "for i in E02 E03 E05 E06; do [ -s '$S04/rec/'\$i'.2/stopped' ] && [ -e '$st4/node/'\$i'/QUESTION.md' ] && [ ! -e '$st4/node/'\$i'/stopped' ] || exit 1; done"
s4ok "S04-AC-1: a node whose first session ends in QUESTION.md has no stopped file (E04)" test ! -e "$st4/node/E04/stopped"
# AC-2: the rendered prompt
s4ok "S04-AC-2: a restarted node with commits gets the resume section (git log origin/main..HEAD, gh run list --branch)" s4resume E01.2
s4ok "S04-AC-2: it gives the reason from stopped: usage limit" grep -qF 'usage limit' "$S04/rec/E01.2/prompt"
s4ok "S04-AC-2: it gives the number of commits past origin/main (3)" grep -Eq '(^|[^0-9.])3 commits?|commits?[^0-9]*[:=(] ?3([^0-9]|$)' "$S04/rec/E01.2/prompt"
s4ok "S04-AC-2: (E02) the reason 'stopped (signal 15)' and 1 commit" sh -c "grep -qF 'stopped (signal 15)' '$S04/rec/E02.2/prompt' && grep -Eq '(^|[^0-9.])1 commit|commits?[^0-9]*[:=(] ?1([^0-9]|\$)' '$S04/rec/E02.2/prompt'"
s4ok "S04-AC-2: (E03) the reason 'rc 3', 2 commits, resume section" sh -c "grep -qF 'rc 3' '$S04/rec/E03.2/prompt' && grep -Eq '(^|[^0-9.])2 commits|commits?[^0-9]*[:=(] ?2([^0-9]|\$)' '$S04/rec/E03.2/prompt'"
s4ok "S04-AC-2: (E06) the reason 'stopped (no exit code)'" grep -qF 'stopped (no exit code)' "$S04/rec/E06.2/prompt"
s4ok "S04-AC-2: the leftover patch written for this start is named in the prompt" sh -c "[ -n '$pb1' ] && grep -qF 'leftover/$pb1' '$S04/rec/E01.2/prompt'"
s4ok "S04-AC-2: it tells the run to examine the patch, never commit it unexamined, list it under Deviations" sh -c "grep -qi 'examine' '$S04/rec/E01.2/prompt' && grep -qi 'unexamined\|never commit\|not commit' '$S04/rec/E01.2/prompt' && grep -q 'Deviations' '$S04/rec/E01.2/prompt'"
s4ok "S04-AC-2: it tells the run to keep the existing brief and not redo committed and reviewed slices" sh -c "grep -qi 'keep.*brief\|existing brief' '$S04/rec/E01.2/prompt' && grep -qi 'not redo\|never redo\|do not redo' '$S04/rec/E01.2/prompt'"
s4ok "S04-AC-2: a restarted node with a clean worktree names no leftover patch (E03)" sh -c "! grep -qE 'leftover/|\.patch' '$S04/rec/E03.2/prompt'"
s4ok "S04-AC-2: a node with out/node/<ID>/ but no commit gets the resume section (E05) with 'rc 4'" sh -c "$(declare -f s4resume); S04='$S04'; s4resume E05.2 && grep -qF 'rc 4' '$S04/rec/E05.2/prompt'"
s4ok "S04-AC-2: a fresh node gets no resume section (E04)" sh -c "s4=$S04/rec/E04.1/prompt; [ -s \$s4 ] && ! grep -qF 'git log origin/main..HEAD' \$s4 && ! grep -qF 'gh run list' \$s4"
s4ok "S04-AC-2: the first session of a node with commits made in no earlier run gets no resume section (E01 run 1)" sh -c "s4=$S04/rec/E01.1/prompt; [ -s \$s4 ] && ! grep -qF 'git log origin/main..HEAD' \$s4"
# AC-3: leftover patch, reset
s4ok "S04-AC-3: the dirty worktree's changes are in leftover/<UTC timestamp>.patch" sh -c "[ -n '$p1' ] && [ -s '$p1' ] && echo '$pb1' | grep -Eq '^[0-9]{8}T[0-9]{6}Z\.patch\$|^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.-]*Z.*\.patch\$|^[0-9TZ:-]+\.patch\$'"
s4ok "S04-AC-3: exactly one patch for the one start" test "$(ls "$st4/node/E01/leftover" 2>/dev/null | wc -l)" = 1
s4rt() {
	local p=$1 head
	[ -f "$p" ] || return 1
	head=$(cat "$S04/head1.E01") || return 1
	rm -rf "$tmp/rt7"; git clone -q "$data7/repos/s4" "$tmp/rt7" 2>/dev/null && git -C "$tmp/rt7" checkout -q "$head" 2>/dev/null || return 1
	[ -z "$(git -C "$tmp/rt7" status --porcelain)" ] || return 1
	git -C "$tmp/rt7" apply "$p" || return 1
	grep -qx more "$tmp/rt7/base.txt" && [ "$(grep -c . "$tmp/rt7/base.txt")" = 2 ] && [ -f "$tmp/rt7/s.txt" ] && grep -qx staged "$tmp/rt7/s.txt" &&
		[ -f "$tmp/rt7/u.txt" ] && grep -qx untracked "$tmp/rt7/u.txt" && [ ! -e "$tmp/rt7/d.txt" ] && [ ! -e "$tmp/rt7/cache.ign" ]
}
s4ok "S04-AC-3: git apply on the same commit restores modified, staged, deleted and untracked files, not the ignored one" s4rt "$p1"
s4ok "S04-AC-3: when the session starts, git status --porcelain in the worktree is empty" sh -c "[ -f '$S04/rec/E01.2/status' ] && [ ! -s '$S04/rec/E01.2/status' ]"
s4ok "S04-AC-3: HEAD is unchanged (E01)" sh -c "[ -s '$S04/head1.E01' ] && [ \"\$(cat '$S04/rec/E01.2/head')\" = \"\$(cat '$S04/head1.E01')\" ]"
s4ok "S04-AC-3: the branch is unchanged, with its 3 commits past origin/main" sh -c "[ \"\$(cat '$S04/rec/E01.2/branch')\" = node/E01-n1 ] && [ \"\$(git -C '$w1' rev-list --count origin/main..HEAD)\" = 3 ]"
s4ok "S04-AC-3: the tracked file is back to its committed content, the untracked file is gone" sh -c "[ \"\$(cat '$S04/rec/E01.2/base')\" = base ] && [ ! -e '$w1/u.txt' ] && [ ! -e '$w1/s.txt' ] && [ -f '$w1/d.txt' ]"
s4ok "S04-AC-3: ignored files are untouched (out/node/E01/log.txt and cache.ign)" sh -c "[ \"\$(cat '$S04/rec/E01.2/log')\" = 'log of E01' ] && [ \"\$(cat '$S04/rec/E01.2/ign')\" = cache ]"
s4ok "S04-AC-3: one status-log event names the node and the patch" sh -c "[ -n '$pb1' ] && [ \"\$(grep 'E01' '$st4/status.log' | grep -cF '$pb1')\" = 1 ]"
s4ok "S04-AC-3: a clean worktree gets no patch (E03: no leftover directory content)" sh -c "[ -z \"\$(ls '$st4/node/E03/leftover' 2>/dev/null)\" ] && [ ! -s '$S04/rec/E03.2/leftover' ]"
s4ok "S04-AC-3: (E03) its status is empty and its commits stay" sh -c "[ ! -s '$S04/rec/E03.2/status' ] && [ \"\$(cat '$S04/rec/E03.2/head')\" = \"\$(cat '$S04/head1.E03')\" ]"
s4ok "S04-AC-3: a fresh node gets no patch (E04)" sh -c "[ -z \"\$(ls '$st4/node/E04/leftover' 2>/dev/null)\" ]"
s4ok "S04-AC-3: a patch that cannot be written: the node is not started that tick (E07 stays at one run)" test "$(s4runs E07)" = 1
s4ok "S04-AC-3: (E07) the worktree is unchanged: still modified, HEAD kept" sh -c "grep -qx more '$wt7/E07/base.txt' && [ \"\$(git -C '$wt7/E07' rev-parse HEAD)\" = \"\$(cat '$S04/head1.E07')\" ] && git -C '$wt7/E07' status --porcelain | grep -q 'base.txt'"
s4ok "S04-AC-3: (E07) the failure is logged" sh -c "grep 'E07' '$st4/status.log' | grep -iE 'leftover|patch' | grep -iqE 'fail|cannot|could not|not written|unable'"
s4ok "S04-AC-3: (E07) its brief and ignored files are untouched" sh -c "[ \"\$(cat '$wt7/E07/out/node/E07/brief.md')\" = \"\$(cat '$S04/brief1.E07')\" ]"
# AC-4: end to end
s4ok "S04-AC-4: the limit-stopped node starts again with its start not counted (both runs are start 1 of 2)" sh -c "[ \"\$(grep -c 'started E01 .*start 1 of 2' '$st4/status.log')\" = 2 ] && [ \"\$(cat '$S04/runs.E01')\" = 2 ]"
s4ok "S04-AC-4: its resume prompt names usage limit and carries the resume section" sh -c "$(declare -f s4resume); S04='$S04'; s4resume E01.2 && grep -qF 'usage limit' '$S04/rec/E01.2/prompt'"
s4ok "S04-AC-4: at that start its earlier commits are on the branch, HEAD unchanged" sh -c "[ \"\$(cat '$S04/rec/E01.2/head')\" = \"\$(cat '$S04/head1.E01')\" ] && git -C '$w1' log --format=%s origin/main..HEAD | grep -qx 'E01 commit 1'"
s4ok "S04-AC-4: its brief is unchanged" sh -c "[ -s '$S04/brief1.E01' ] && cmp -s '$S04/rec/E01.2/brief' '$S04/brief1.E01'"
s4ok "S04-AC-4: the edit is in the leftover patch, not in the worktree" sh -c "[ -n '$p1' ] && grep -q '^+more' '$p1' && [ \"\$(cat '$S04/rec/E01.2/base')\" = base ]"
s4ok "S04-AC-4: the signal-killed node restarts the same way, with a reason beginning 'stopped'" sh -c "$(declare -f s4resume); S04='$S04'; s4resume E02.2 && grep -q 'stopped' '$S04/rec/E02.2/prompt' && [ \"\$(cat '$S04/runs.E02')\" = 2 ]"
p2=$(s4patch E02)
s4ok "S04-AC-4: (signal) its edit is in the leftover patch, not in the worktree, HEAD and brief unchanged" sh -c "[ -n '$p2' ] && grep -q '^+more' '$p2' && [ \"\$(cat '$S04/rec/E02.2/base')\" = base ] && [ \"\$(cat '$S04/rec/E02.2/head')\" = \"\$(cat '$S04/head1.E02')\" ] && cmp -s '$S04/rec/E02.2/brief' '$S04/brief1.E02'"
kill "$lp7"; wait "$lp7" 2>/dev/null
for f in "$st4"/node/*/session.pid; do [ -e "$f" ] && kill -KILL -- "-$(cat "$f")" 2>/dev/null; done

# ---- S04 (tracked but ignored): a tracked file matching an ignore pattern is not "ignored" by Git: its edit is in the patch ----
# Node F01 in its own remote, data dir and loop (o/s4b). main carries .gitignore (out/, *.ign), a tracked n.txt and
# the force-added keep.ign and t.ign. Run 1 edits t.ign and n.txt, leaves keep.ign alone, exits 1. Run 2 asks QUESTION.md.
S04B=$tmp/s04b; export S04B
mkdir -p "$S04B/rec" "$tmp/bin8" "$tmp/nb8/scheduler" "$tmp/nb8/plugin" "$tmp/data8/repos"
data8=$(cd "$tmp/data8" && pwd -P)
st8=$data8/state/s4b
S04B_STATE=$st8; export S04B_STATE
for f in "$src"/*; do case $f in *.test.sh) ;; *) [ -f "$f" ] && cp "$f" "$tmp/nb8/scheduler/" ;; esac; done
git init -q -b main "$tmp/work8"; mkdir -p "$tmp/work8/docs"
echo 'nodes:
  - {id: F01, name: n1, deps: []}' >"$tmp/work8/docs/graph.yaml"
printf 'n\n' >"$tmp/work8/n.txt"; printf 'out/\n*.ign\n' >"$tmp/work8/.gitignore"
printf 'keep\n' >"$tmp/work8/keep.ign"; printf 't\n' >"$tmp/work8/t.ign"
git -C "$tmp/work8" add -A && git -C "$tmp/work8" add -f keep.ign t.ign && git -C "$tmp/work8" -c user.name=t -c user.email=t@t commit -q -m init
git clone -q --bare "$tmp/work8" "$tmp/remote8.git"
git clone -q "$tmp/remote8.git" "$data8/repos/s4b"
cp "$tmp/bin7/gh" "$tmp/bin8/gh"
cat >"$tmp/bin8/claude" <<'EOF'
#!/bin/sh
id=${2##* }
n=$(( $(cat "$S04B/runs" 2>/dev/null || echo 0) + 1 )); echo $n >"$S04B/runs"
r=$S04B/rec/$n; mkdir -p "$r"
git status --porcelain >"$r/status" 2>&1
git rev-parse HEAD >"$r/head" 2>&1
cat t.ign >"$r/t" 2>/dev/null; cat keep.ign >"$r/keep" 2>/dev/null; cat n.txt >"$r/n" 2>/dev/null
touch "$r/done"
case $n in
1) git rev-parse HEAD >"$S04B/head1"; echo edited >>t.ign; echo edited >>n.txt; exit 1 ;;
*) echo "Q1: x" >"$S04B_STATE/node/$id/QUESTION.md" ;;
esac
exit 0
EOF
chmod +x "$tmp/bin8/gh" "$tmp/bin8/claude"
NOODLEBOT_DATA=$data8 PATH=$tmp/bin8:$PATH SCHED_REPORT=0 SCHED_THROTTLE=0 SCHED_TICK=1 SCHED_POLL=0.2 \
	bash "$tmp/nb8/scheduler/loop.sh" o/s4b >>"$tmp/s04b-loop.out" 2>&1 &
pids+=("$!"); lp8=$!
s4wait 25 sh -c "[ -e '$S04B/rec/2/done' ]"
sleep 2
pt=$(ls "$st8"/node/F01/leftover/*.patch 2>/dev/null | head -1)
s4bnodel() { # the patch deletes neither keep.ign nor t.ign
	awk '/^diff --git /{f=$3} /^deleted file mode/{ if (f ~ /(keep|t)\.ign$/) bad=1 } END{exit bad}' "$1"
}
s4brt() { # git apply on the same commit reproduces both edits and leaves keep.ign as committed
	[ -f "$pt" ] || return 1
	rm -rf "$tmp/rt8"; git clone -q "$data8/repos/s4b" "$tmp/rt8" 2>/dev/null && git -C "$tmp/rt8" checkout -q "$(cat "$S04B/head1")" 2>/dev/null || return 1
	git -C "$tmp/rt8" apply "$pt" || return 1
	[ "$(cat "$tmp/rt8/t.ign")" = "$(printf 't\nedited')" ] && [ "$(cat "$tmp/rt8/n.txt")" = "$(printf 'n\nedited')" ] && [ "$(cat "$tmp/rt8/keep.ign")" = keep ]
}
s4ok "S04-AC-3: (tracked but ignored) the second session started" test -e "$S04B/rec/2/done"
s4ok "S04-AC-3: (tracked but ignored) the patch carries the edit of t.ign" sh -c "[ -n '$pt' ] && awk '/^diff --git /{f=\$3} f ~ /t\\.ign\$/ && /^\\+edited\$/{ok=1} END{exit !ok}' '$pt'"
s4ok "S04-AC-3: (tracked but ignored) the patch deletes neither keep.ign nor t.ign" sh -c "[ -n '$pt' ] && $(declare -f s4bnodel) && s4bnodel '$pt'"
s4ok "S04-AC-3: (tracked but ignored) git apply on the same commit reproduces both edits and leaves keep.ign as committed" s4brt
s4ok "S04-AC-3: (tracked but ignored) at the second start git status --porcelain is empty" sh -c "[ -f '$S04B/rec/2/status' ] && [ ! -s '$S04B/rec/2/status' ]"
s4ok "S04-AC-3: (tracked but ignored) at the second start t.ign and keep.ign are at their committed content" sh -c "[ \"\$(cat '$S04B/rec/2/t' 2>/dev/null)\" = t ] && [ \"\$(cat '$S04B/rec/2/keep' 2>/dev/null)\" = keep ] && [ \"\$(cat '$S04B/rec/2/n' 2>/dev/null)\" = n ]"
kill "$lp8"; wait "$lp8" 2>/dev/null
for f in "$st8"/node/*/session.pid; do [ -e "$f" ] && kill -KILL -- "-$(cat "$f")" 2>/dev/null; done

# ---- S04 (unusual leftovers): an interrupted merge, out/ not ignored, a force-staged ignored file, a staged-only change, a follow-up ----
# Nodes H01..H05 (no deps) in their own remote, data dir and loop (o/s4c). main carries f.txt and a .gitignore with
# *.ign only (out/ is NOT ignored); branch "other" in the remote edits f.txt. H05's original PR is merged and its
# question answered, so it starts as a follow-up (node/H05-followup-1). The fake claude records at every start into
# $S04C/rec/<ID>.<run>/ (done last); run 1 per node, run 2 (and later) writes QUESTION.md:
#   H01: commits on its branch, then starts a conflicting merge of origin/other and leaves it unfinished, exit 1.
#   H02: writes out/node/H02/brief.md, edits tracked f.txt, adds untracked x.txt, exit 1.
#   H03: git add -f of a new n.ign (matches *.ign, not in HEAD), exit 1.
#   H04: edits f.txt, git add f.txt, restores the worktree copy from HEAD (staged-only change), exit 1.
#   H05: commits on its follow-up branch, exit 1.
S04C=$tmp/s04c; export S04C
mkdir -p "$S04C/rec" "$tmp/bin9" "$tmp/nb9/scheduler" "$tmp/nb9/plugin" "$tmp/data9/repos"
data9=$(cd "$tmp/data9" && pwd -P)
st9=$data9/state/s4c wt9=$data9/worktrees/s4c
S04C_STATE=$st9; export S04C_STATE
for f in "$src"/*; do case $f in *.test.sh) ;; *) [ -f "$f" ] && cp "$f" "$tmp/nb9/scheduler/" ;; esac; done
git init -q -b main "$tmp/work9"; mkdir -p "$tmp/work9/docs"
{ echo 'nodes:'; for i in 1 2 3 4 5; do echo "  - {id: H0$i, name: n$i, deps: []}"; done; } >"$tmp/work9/docs/graph.yaml"
printf 'base\n' >"$tmp/work9/f.txt"; printf '*.ign\n' >"$tmp/work9/.gitignore"
git -C "$tmp/work9" add -A && git -C "$tmp/work9" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$tmp/work9" checkout -q -b other && echo theirs >"$tmp/work9/f.txt" && git -C "$tmp/work9" -c user.name=t -c user.email=t@t commit -qam theirs
git -C "$tmp/work9" checkout -q main
git clone -q --bare "$tmp/work9" "$tmp/remote9.git"
git clone -q "$tmp/remote9.git" "$data9/repos/s4c"
mkdir -p "$st9/node/H05"; echo "Q1: which way?" >"$st9/node/H05/QUESTION.md"; echo "Q1: as recommended" >"$st9/node/H05/ANSWER.md"
cat >"$tmp/bin9/gh" <<'EOF'
#!/bin/sh
case " $* " in
*" --state merged "*) echo '50 node/H05-n5' ;;
*"/issues?labels=noodlebot"*) echo '[]' ;;
esac
exit 0
EOF
cat >"$tmp/bin9/claude" <<'EOF'
#!/bin/sh
id=${2##* }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
n=$(( $(cat "$S04C/runs.$id" 2>/dev/null || echo 0) + 1 )); echo $n >"$S04C/runs.$id"
r=$S04C/rec/$id.$n; mkdir -p "$r"
cp "$S04C_STATE/node/$id/unattended.md" "$r/prompt" 2>/dev/null
git status --porcelain >"$r/status" 2>&1
git rev-parse HEAD >"$r/head" 2>&1
git rev-parse -q --verify MERGE_HEAD >"$r/mergehead" 2>&1 && echo yes >"$r/merging"
cp "out/node/$id/brief.md" "$r/brief" 2>/dev/null
cat f.txt >"$r/f" 2>/dev/null; [ -e x.txt ] && echo yes >"$r/x"; [ -e n.ign ] && echo yes >"$r/ign"
touch "$r/done"
case $id.$n in
H01.1) echo mine >f.txt; git commit -qam mine; git rev-parse HEAD >"$S04C/head1.$id"; git fetch -q origin; git merge -q origin/other >/dev/null 2>&1; exit 1 ;;
H02.1) mkdir -p "out/node/$id"; echo "brief of $id" >"out/node/$id/brief.md"; cp "out/node/$id/brief.md" "$S04C/brief1.$id"
	git rev-parse HEAD >"$S04C/head1.$id"; echo edit >>f.txt; echo untracked >x.txt; exit 1 ;;
H03.1) git rev-parse HEAD >"$S04C/head1.$id"; echo force >n.ign; git add -f n.ign; exit 1 ;;
H04.1) git rev-parse HEAD >"$S04C/head1.$id"; echo staged >>f.txt; git add f.txt; git show HEAD:f.txt >f.txt; exit 1 ;;
H05.1) echo c >c.txt; git add c.txt; git commit -qm "H05 follow-up commit"; git rev-parse HEAD >"$S04C/head1.$id"; exit 1 ;;
*.1) exit 0 ;;
*) echo "Q1: x" >"$S04C_STATE/node/$id/QUESTION.md" ;;
esac
exit 0
EOF
chmod +x "$tmp/bin9/gh" "$tmp/bin9/claude"
s4cf() { cat "$S04C/rec/$1/$2" 2>/dev/null; }
s4cpatch() { ls "$st9/node/$1/leftover"/*.patch 2>/dev/null | head -1; }
NOODLEBOT_DATA=$data9 PATH=$tmp/bin9:$PATH SCHED_REPORT=0 SCHED_THROTTLE=0 SCHED_TICK=1 SCHED_POLL=0.2 \
	bash "$tmp/nb9/scheduler/loop.sh" o/s4c >>"$tmp/s04c-loop.out" 2>&1 &
pids+=("$!"); lp9=$!
s4wait 25 sh -c "for i in H01 H02 H03 H04 H05; do [ -e '$S04C/rec/'\$i'.2/done' ] || exit 1; done"
sleep 2
# 1: an interrupted merge
s4ok "S04-AC-3: (interrupted merge) run 1 left the merge unfinished and the second session started" sh -c "[ -s '$S04C/head1.H01' ] && [ -e '$S04C/rec/H01.2/done' ]"
s4ok "S04-AC-3: (interrupted merge) git status --porcelain is empty at the second start" sh -c "[ -f '$S04C/rec/H01.2/status' ] && [ ! -s '$S04C/rec/H01.2/status' ]"
s4ok "S04-AC-3: (interrupted merge) no merge is in progress at the second start" sh -c "[ -e '$S04C/rec/H01.2/mergehead' ] && [ ! -e '$S04C/rec/H01.2/merging' ] && ! git -C '$wt9/H01' rev-parse -q --verify MERGE_HEAD >/dev/null"
s4ok "S04-AC-3: (interrupted merge) HEAD is run 1's HEAD" sh -c "[ -s '$S04C/head1.H01' ] && [ \"\$(cat '$S04C/rec/H01.2/head')\" = \"\$(cat '$S04C/head1.H01')\" ]"
s4ok "S04-AC-3: (interrupted merge) a leftover patch exists" sh -c "[ -s '$(s4cpatch H01)' ]"
# 2: out/ not ignored
p=$(s4cpatch H02)
s4ok "S04-AC-3: (out/ not ignored) the node's brief is still there at the second start, unchanged" sh -c "[ -s '$S04C/brief1.H02' ] && cmp -s '$S04C/rec/H02.2/brief' '$S04C/brief1.H02' && cmp -s '$wt9/H02/out/node/H02/brief.md' '$S04C/brief1.H02'"
s4ok "S04-AC-3: (out/ not ignored) the tracked edit is in the patch" sh -c "[ -n '$p' ] && grep -q '^+edit' '$p'"
s4ok "S04-AC-3: (out/ not ignored) the untracked file is in the patch" sh -c "[ -n '$p' ] && grep -q '^+untracked' '$p'"
s4ok "S04-AC-3: (out/ not ignored) the tracked edit and the untracked file are gone from the worktree" sh -c "[ \"\$(cat '$S04C/rec/H02.2/f' 2>/dev/null)\" = base ] && [ ! -e '$S04C/rec/H02.2/x' ] && [ ! -e '$wt9/H02/x.txt' ]"
s4ok "S04-AC-3: (out/ not ignored) the patch does not take the brief" sh -c "[ -n '$p' ] && ! grep -q 'brief.md' '$p'"
# 3: a force-staged new file matching an ignore pattern
p3=$(s4cpatch H03)
s4c3rt() {
	[ -f "$p3" ] && [ -s "$S04C/head1.H03" ] || return 1
	rm -rf "$tmp/rt9"; git clone -q "$data9/repos/s4c" "$tmp/rt9" 2>/dev/null && git -C "$tmp/rt9" checkout -q "$(cat "$S04C/head1.H03")" 2>/dev/null || return 1
	git -C "$tmp/rt9" apply "$p3" || return 1
	[ "$(cat "$tmp/rt9/n.ign" 2>/dev/null)" = force ]
}
s4ok "S04-AC-3: (force-staged ignored file) it is in the patch" sh -c "[ -n '$p3' ] && grep -q 'n.ign' '$p3' && grep -q '^+force' '$p3'"
s4ok "S04-AC-3: (force-staged ignored file) git apply on the same commit in a scratch clone recreates it" s4c3rt
s4ok "S04-AC-3: (force-staged ignored file) at the second start the status is empty and the file is gone" sh -c "[ -e '$S04C/rec/H03.2/done' ] && [ ! -s '$S04C/rec/H03.2/status' ] && [ ! -e '$S04C/rec/H03.2/ign' ]"
# 4: a staged-only change whose worktree file equals HEAD
s4ok "S04-AC-3: (staged-only change) the node is not held: its second session starts" test -e "$S04C/rec/H04.2/done"
s4ok "S04-AC-3: (staged-only change) its worktree is clean at that start" sh -c "[ -f '$S04C/rec/H04.2/status' ] && [ ! -s '$S04C/rec/H04.2/status' ] && [ \"\$(cat '$S04C/rec/H04.2/f' 2>/dev/null)\" = base ]"
s4ok "S04-AC-3: (staged-only change) HEAD is unchanged" sh -c "[ -s '$S04C/head1.H04' ] && [ \"\$(cat '$S04C/rec/H04.2/head' 2>/dev/null)\" = \"\$(cat '$S04C/head1.H04')\" ]"
# 5: a follow-up
fp=$S04C/rec/H05.2/prompt
s4ok "S04-AC-2: (follow-up) its first start gets no resume section" sh -c "[ -s '$S04C/rec/H05.1/prompt' ] && grep -q 'FOLLOW-UP' '$S04C/rec/H05.1/prompt' && ! grep -qF 'git log origin/main..HEAD' '$S04C/rec/H05.1/prompt' && ! grep -qF 'gh run list' '$S04C/rec/H05.1/prompt'"
s4ok "S04-AC-2: (follow-up) its restart renders the follow-up prompt with the resume section (git log origin/main..HEAD, gh run list --branch)" sh -c "grep -q 'FOLLOW-UP' '$fp' && grep -qF 'git log origin/main..HEAD' '$fp' && grep -qF 'gh run list --branch' '$fp'"
s4ok "S04-AC-2: (follow-up) it gives the reason 'rc 1' and 1 commit past origin/main" sh -c "grep -qF 'rc 1' '$fp' && grep -Eq '(^|[^0-9.])1 commit|commits?[^0-9]*[:=(] ?1([^0-9]|\$)' '$fp'"
s4ok "S04-AC-2: (follow-up) it has no unfilled placeholder" sh -c "[ -s '$fp' ] && ! grep -qE '@[A-Z]+@' '$fp'"
kill "$lp9"; wait "$lp9" 2>/dev/null
for f in "$st9"/node/*/session.pid; do [ -e "$f" ] && kill -KILL -- "-$(cat "$f")" 2>/dev/null; done

# ---- S04 (more leftovers): staged content only in the index, a stale index lock, evidence under an ignored out/, a rebase in progress ----
# Nodes J01..J04 (no deps) in their own remote, data dir and loop (o/s4d). main carries f.txt and .gitignore with out/ (kept.md
# of J03 is force-added on main); branch "other" edits f.txt. The fake claude records at every start into $S04D/rec/<ID>.<run>/
# (done last); run 1 leaves the state below and exits 1, run 2 writes QUESTION.md:
#   J01: edit f.txt, git add f.txt, restore f.txt from HEAD (MM); git add n.txt, delete it (AD).
#   J02: tracked edit, then the index.lock a SIGKILLed git leaves.
#   J03: edits out/node/J03/kept.md, git add -f out/node/J03/brief.md, untracked ignored log.txt, edits f.txt.
#   J04: commits on its branch, starts a rebase onto origin/other that stops on a conflict.
S04D=$tmp/s04d; export S04D
mkdir -p "$S04D/rec" "$tmp/bin10" "$tmp/nb10/scheduler" "$tmp/nb10/plugin" "$tmp/data10/repos"
data10=$(cd "$tmp/data10" && pwd -P)
st10=$data10/state/s4d wt10=$data10/worktrees/s4d
S04D_STATE=$st10; export S04D_STATE
for f in "$src"/*; do case $f in *.test.sh) ;; *) [ -f "$f" ] && cp "$f" "$tmp/nb10/scheduler/" ;; esac; done
git init -q -b main "$tmp/work10"; mkdir -p "$tmp/work10/docs" "$tmp/work10/out/node/J03"
{ echo 'nodes:'; for i in 1 2 3 4; do echo "  - {id: J0$i, name: n$i, deps: []}"; done; } >"$tmp/work10/docs/graph.yaml"
printf 'base\n' >"$tmp/work10/f.txt"; printf 'out/\n' >"$tmp/work10/.gitignore"; printf 'kept v0\n' >"$tmp/work10/out/node/J03/kept.md"
git -C "$tmp/work10" add -A && git -C "$tmp/work10" add -f out/node/J03/kept.md && git -C "$tmp/work10" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$tmp/work10" checkout -q -b other && echo theirs >"$tmp/work10/f.txt" && git -C "$tmp/work10" -c user.name=t -c user.email=t@t commit -qam theirs
git -C "$tmp/work10" checkout -q main
git clone -q --bare "$tmp/work10" "$tmp/remote10.git"
git clone -q "$tmp/remote10.git" "$data10/repos/s4d"
cat >"$tmp/bin10/gh" <<'EOF'
#!/bin/sh
case " $* " in
*"/issues?labels=noodlebot"*) echo '[]' ;;
esac
exit 0
EOF
cat >"$tmp/bin10/claude" <<'EOF'
#!/bin/sh
id=${2##* }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
n=$(( $(cat "$S04D/runs.$id" 2>/dev/null || echo 0) + 1 )); echo $n >"$S04D/runs.$id"
r=$S04D/rec/$id.$n; mkdir -p "$r"
git status --porcelain >"$r/status" 2>&1
git rev-parse HEAD >"$r/head" 2>&1
git rev-parse --abbrev-ref HEAD >"$r/branch" 2>&1
[ -e "$(git rev-parse --git-path rebase-merge)" ] && echo yes >"$r/rebasing"
[ -e "$(git rev-parse --git-path rebase-apply)" ] && echo yes >"$r/rebasing"
git rev-parse "node/$id-n${id#J0}" >"$r/tip" 2>/dev/null
ls "$S04D_STATE/node/$id/leftover" 2>/dev/null | wc -l >"$r/npatch"
cat f.txt >"$r/f" 2>/dev/null; [ -e n.txt ] && echo yes >"$r/n"
for x in kept.md brief.md log.txt; do cp "out/node/$id/$x" "$r/$x" 2>/dev/null; done
touch "$r/done"
case $id.$n in
J01.1) git rev-parse HEAD >"$S04D/head1.$id"; echo staged >>f.txt; git add f.txt; git show HEAD:f.txt >f.txt
	echo newfile >n.txt; git add n.txt; rm n.txt; exit 1 ;;
J02.1) git rev-parse HEAD >"$S04D/head1.$id"; echo edit >>f.txt; : >"$(git rev-parse --git-path index.lock)"; exit 1 ;;
J03.1) git rev-parse HEAD >"$S04D/head1.$id"; echo "kept v1" >"out/node/$id/kept.md"; echo "brief v1" >"out/node/$id/brief.md"; git add -f "out/node/$id/brief.md"
	echo "log v1" >"out/node/$id/log.txt"; echo ordinary >>f.txt; exit 1 ;;
J04.1) echo mine >f.txt; git commit -qam mine; git rev-parse HEAD >"$S04D/head1.$id"; git fetch -q origin; git rebase origin/other >/dev/null 2>&1; exit 1 ;;
*.1) exit 0 ;;
*) echo "Q1: x" >"$S04D_STATE/node/$id/QUESTION.md" ;;
esac
exit 0
EOF
chmod +x "$tmp/bin10/gh" "$tmp/bin10/claude"
s4dpatch() { ls "$st10/node/$1/leftover"/*.patch 2>/dev/null | head -1; }
NOODLEBOT_DATA=$data10 PATH=$tmp/bin10:$PATH SCHED_REPORT=0 SCHED_THROTTLE=0 SCHED_TICK=1 SCHED_POLL=0.2 \
	bash "$tmp/nb10/scheduler/loop.sh" o/s4d >>"$tmp/s04d-loop.out" 2>&1 &
pids+=("$!"); lp10=$!
s4wait 20 sh -c "for i in J01 J02 J03 J04; do [ -e '$S04D/rec/'\$i'.2/done' ] || exit 1; done"
sleep 3
# 1: staged content only in the index
p=$(s4dpatch J01)
s4ok "S04-AC-3: (index-only content) the node started: its second session ran" test -e "$S04D/rec/J01.2/done"
s4ok "S04-AC-3: (index-only content) the patch holds the staged edit of f.txt" sh -c "[ -n '$p' ] && grep -q '^+staged' '$p'"
s4ok "S04-AC-3: (index-only content) the patch holds the staged new file n.txt" sh -c "[ -n '$p' ] && grep -q '^+newfile' '$p'"
s4ok "S04-AC-3: (index-only content) the worktree is clean at the second start" sh -c "[ -f '$S04D/rec/J01.2/status' ] && [ ! -s '$S04D/rec/J01.2/status' ] && [ ! -e '$S04D/rec/J01.2/n' ]"
# 2: a stale index lock
s4ok "S04-AC-3: (stale index lock) the node starts again within the wait" test -e "$S04D/rec/J02.2/done"
s4ok "S04-AC-3: (stale index lock) the worktree is clean at that start" sh -c "[ -f '$S04D/rec/J02.2/status' ] && [ ! -s '$S04D/rec/J02.2/status' ] && [ \"\$(cat '$S04D/rec/J02.2/f' 2>/dev/null)\" = base ]"
s4ok "S04-AC-3: (stale index lock) exactly one patch at that start, holding the edit" sh -c "[ \"\$(tr -d ' \n' <'$S04D/rec/J02.2/npatch')\" = 1 ] && grep -q '^+edit' '$(s4dpatch J02)'"
s4ok "S04-AC-3: (stale index lock) still exactly one patch after a few more ticks" test "$(ls "$st10/node/J02/leftover" 2>/dev/null | wc -l)" = 1
# 3: evidence under an ignored out/
p=$(s4dpatch J03)
s4ok "S04-AC-3: (ignored out/) kept.md, brief.md and log.txt are present at the second start with run 1's content" sh -c "[ \"\$(cat '$S04D/rec/J03.2/kept.md' 2>/dev/null)\" = 'kept v1' ] && [ \"\$(cat '$S04D/rec/J03.2/brief.md' 2>/dev/null)\" = 'brief v1' ] && [ \"\$(cat '$S04D/rec/J03.2/log.txt' 2>/dev/null)\" = 'log v1' ]"
s4ok "S04-AC-3: (ignored out/) the ordinary edit is in the patch" sh -c "[ -n '$p' ] && grep -q '^+ordinary' '$p'"
s4ok "S04-AC-3: (ignored out/) the ordinary edit is gone from the worktree" sh -c "[ \"\$(cat '$S04D/rec/J03.2/f' 2>/dev/null)\" = base ]"
s4ok "S04-AC-3: (ignored out/) the files are still in the worktree afterwards" sh -c "[ \"\$(cat '$wt10/J03/out/node/J03/kept.md' 2>/dev/null)\" = 'kept v1' ] && [ \"\$(cat '$wt10/J03/out/node/J03/brief.md' 2>/dev/null)\" = 'brief v1' ] && [ \"\$(cat '$wt10/J03/out/node/J03/log.txt' 2>/dev/null)\" = 'log v1' ]"
# 4: a rebase in progress
s4ok "S04-AC-3: (rebase) run 1 left a rebase in progress and the node started again" sh -c "[ -s '$S04D/head1.J04' ] && [ -e '$S04D/rec/J04.2/done' ]"
s4ok "S04-AC-3: (rebase) no rebase is in progress at the second start" sh -c "[ -e '$S04D/rec/J04.2/done' ] && [ ! -e '$S04D/rec/J04.2/rebasing' ]"
s4ok "S04-AC-3: (rebase) HEAD is on the node's branch" test "$(cat "$S04D/rec/J04.2/branch" 2>/dev/null)" = node/J04-n4
s4ok "S04-AC-3: (rebase) the branch tip equals run 1's commit" sh -c "[ -s '$S04D/head1.J04' ] && [ \"\$(cat '$S04D/rec/J04.2/tip' 2>/dev/null)\" = \"\$(cat '$S04D/head1.J04')\" ]"
s4ok "S04-AC-3: (rebase) the worktree is clean at the second start" sh -c "[ -f '$S04D/rec/J04.2/status' ] && [ ! -s '$S04D/rec/J04.2/status' ]"
s4ok "S04-AC-3: (rebase) a leftover patch exists" sh -c "[ -s '$(s4dpatch J04)' ]"
kill "$lp10"; wait "$lp10" 2>/dev/null
for f in "$st10"/node/*/session.pid; do [ -e "$f" ] && kill -KILL -- "-$(cat "$f")" 2>/dev/null; done

# ---- S04 (slice 5): a reset that fails partway names its patch, a patch not yet shown is named later; a rebase patch names its base ----
# Nodes K01, K02 (no deps) in their own remote, data dir and loop (o/s45). main carries f.txt and .gitignore with out/;
# branch "other" edits f.txt. The fake claude snapshots the rendered unattended.md of every start into $S45/rec/<ID>.<run>/.
#   K01 run 1: a commit, brief, an edit of f.txt, an untracked sub/u.txt in a directory without write permission
#              (git clean cannot remove it); usage limit, exit 1. run 2: another edit of f.txt, usage limit. run 3: QUESTION.md.
#   K02 run 1: a commit on its branch, a rebase onto origin/other that stops on a conflict, exit 1. run 2: QUESTION.md.
S45=$tmp/s45; export S45
mkdir -p "$S45/rec" "$tmp/bin45" "$tmp/nb45/scheduler" "$tmp/nb45/plugin" "$tmp/data45/repos"
data45=$(cd "$tmp/data45" && pwd -P)
st45=$data45/state/s45 wt45=$data45/worktrees/s45
S45_STATE=$st45; export S45_STATE
for f in "$src"/*; do case $f in *.test.sh) ;; *) [ -f "$f" ] && cp "$f" "$tmp/nb45/scheduler/" ;; esac; done
git init -q -b main "$tmp/work45"; mkdir -p "$tmp/work45/docs"
{ echo 'nodes:'; for i in 1 2; do echo "  - {id: K0$i, name: n$i, deps: []}"; done; } >"$tmp/work45/docs/graph.yaml"
printf 'base\n' >"$tmp/work45/f.txt"; printf 'out/\n' >"$tmp/work45/.gitignore"
git -C "$tmp/work45" add -A && git -C "$tmp/work45" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$tmp/work45" checkout -q -b other && echo theirs >"$tmp/work45/f.txt" && git -C "$tmp/work45" -c user.name=t -c user.email=t@t commit -qam theirs
git -C "$tmp/work45" checkout -q main
git clone -q --bare "$tmp/work45" "$tmp/remote45.git"
git clone -q "$tmp/remote45.git" "$data45/repos/s45"
cat >"$tmp/bin45/gh" <<'EOF'
#!/bin/sh
case " $* " in
*"/issues?labels=noodlebot"*) echo '[]' ;;
esac
exit 0
EOF
cat >"$tmp/bin45/claude" <<'EOF'
#!/bin/sh
id=${2##* }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
n=$(( $(cat "$S45/runs.$id" 2>/dev/null || echo 0) + 1 )); echo $n >"$S45/runs.$id"
r=$S45/rec/$id.$n; mkdir -p "$r"
cp "$S45_STATE/node/$id/unattended.md" "$r/prompt" 2>/dev/null
git status --porcelain >"$r/status" 2>&1
git rev-parse HEAD >"$r/head" 2>&1
touch "$r/done"
limit() {
	echo '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","unifiedWindows":{"five_hour":{"utilization":1.0,"resetsAt":1,"status":"rejected"}}}}'
	echo '{"type":"result","subtype":"error_during_execution","result":"You have hit your usage limit"}'
}
case $id.$n in
K01.1) echo c >c.txt; git add c.txt; git commit -qm "K01 commit"; mkdir -p "out/node/$id"; echo "brief" >"out/node/$id/brief.md"
	echo edit1 >>f.txt; mkdir sub; echo undeletable >sub/u.txt; chmod a-w sub; limit; exit 1 ;;
K01.2) echo edit2 >>f.txt; limit; exit 1 ;;
K02.1) echo mine >f.txt; git commit -qam mine; git rev-parse HEAD >"$S45/tip.$id"; git fetch -q origin; git rebase origin/other >/dev/null 2>&1
	git rev-parse HEAD >"$S45/dhead.$id"; exit 1 ;;
*) echo "Q1: x" >"$S45_STATE/node/$id/QUESTION.md" ;;
esac
exit 0
EOF
chmod +x "$tmp/bin45/gh" "$tmp/bin45/claude"
s45ps() { ls "$st45/node/$1/leftover"/*.patch 2>/dev/null | sed 's#.*/##'; }
s45p1() { local p; for p in $(s45ps K01); do grep -q '^+edit1' "$st45/node/K01/leftover/$p" && { echo "$p"; return; }; done; }
s45all() { local p; [ -s "$1" ] && [ -s "$2" ] || return 1; while read -r p; do grep -qF "$p" "$1" || return 1; done <"$2"; }
s45none() { local p; [ -s "$1" ] && [ -s "$2" ] || return 1; while read -r p; do ! grep -qF "$p" "$1" || return 1; done <"$2"; }
if [ "$(id -u)" = 0 ]; then
	fail "S04-AC-3: (partial reset, Q1) cannot run as root: a directory without write permission does not stop git clean"
else
	NOODLEBOT_DATA=$data45 PATH=$tmp/bin45:$PATH SCHED_REPORT=0 SCHED_THROTTLE=0 SCHED_TICK=1 SCHED_POLL=0.2 \
		bash "$tmp/nb45/scheduler/loop.sh" o/s45 >>"$tmp/s45-loop.out" 2>&1 &
	pids+=("$!"); lp45=$!
	s4wait 15 sh -c "[ -e '$S45/rec/K01.1/done' ] && grep K01 '$st45/status.log' | grep -qiE 'fail|cannot'"
	s4wait 8 sh -c "[ \$(ls '$st45'/node/K01/leftover/*.patch 2>/dev/null | wc -l) -ge 2 ]"
	sleep 1
	p1=$(s45p1); allp=$(s45ps K01)
	grep K01 "$st45/status.log" | grep -iE 'fail|cannot' | head -1 >"$tmp/s45-note1"; printf '%s\n' "$allp" >"$tmp/s45-allp"
	s4ok "S04-AC-3: (partial reset) the reset fails with the node held: it ran once and the undeletable file is still there" sh -c "[ \"\$(cat '$S45/runs.K01' 2>/dev/null)\" = 1 ] && [ -e '$wt45/K01/sub/u.txt' ]"
	s4ok "S04-AC-3: (partial reset) a patch holds the real edit of f.txt" test -n "$p1"
	s4ok "S04-AC-3: (partial reset) the first failure note in the status log names that patch" sh -c "[ -n '$p1' ] && grep -qF '$p1' '$tmp/s45-note1'"
	s4ok "S04-AC-3: (partial reset) the first failure note names the cause (the file or directory that cannot be removed, permission denied)" grep -qiE 'permission|denied|failed to remove|cannot remove|u\.txt|sub/' "$tmp/s45-note1"
	chmod u+w "$wt45/K01/sub"
	s4wait 20 sh -c "[ -e '$S45/rec/K01.2/done' ]"
	pr=$S45/rec/K01.2/prompt
	s4ok "S04-AC-3: (partial reset) once the file is deletable the node starts with a clean worktree" sh -c "[ -e '$S45/rec/K01.2/done' ] && [ ! -s '$S45/rec/K01.2/status' ] && [ ! -e '$wt45/K01/sub/u.txt' ]"
	s4ok "S04-AC-2: (partial reset) the rendered prompt names the patch with the real edit (P1)" sh -c "[ -n '$p1' ] && [ -s '$pr' ] && grep -qF '$p1' '$pr'"
	s4ok "S04-AC-2: (partial reset) the prompt names every patch written and not yet shown (all of leftover/)" s45all "$pr" "$tmp/s45-allp"
	s4wait 20 sh -c "[ -e '$S45/rec/K01.3/done' ]"
	p3=''; for p in $(s45ps K01); do grep -q '^+edit2' "$st45/node/K01/leftover/$p" && p3=$p; done
	pr3=$S45/rec/K01.3/prompt
	s4ok "S04-AC-2: (partial reset) the next start names the new patch (run 2's edit)" sh -c "[ -n '$p3' ] && [ -s '$pr3' ] && grep -qF '$p3' '$pr3'"
	s4ok "S04-AC-2: (partial reset) the next start does not name P1 or any patch shown to run 2 again" s45none "$pr3" "$tmp/s45-allp"
	kill "$lp45"; wait "$lp45" 2>/dev/null
	for f in "$st45"/node/*/session.pid; do [ -e "$f" ] && kill -KILL -- "-$(cat "$f")" 2>/dev/null; done
	chmod -R u+w "$wt45" 2>/dev/null
fi
# rebase base (Q2): K02 is in the same loop; it ran while the checks above waited (or, as root, not at all)
if [ "$(id -u)" = 0 ]; then
	NOODLEBOT_DATA=$data45 PATH=$tmp/bin45:$PATH SCHED_REPORT=0 SCHED_THROTTLE=0 SCHED_TICK=1 SCHED_POLL=0.2 \
		bash "$tmp/nb45/scheduler/loop.sh" o/s45 >>"$tmp/s45-loop.out" 2>&1 &
	pids+=("$!"); lp45=$!
	s4wait 20 sh -c "[ -e '$S45/rec/K02.2/done' ]"
	kill "$lp45"; wait "$lp45" 2>/dev/null
	for f in "$st45"/node/*/session.pid; do [ -e "$f" ] && kill -KILL -- "-$(cat "$f")" 2>/dev/null; done
fi
s4wait 10 sh -c "[ -e '$S45/rec/K02.2/done' ]"
dh=$(cat "$S45/dhead.K02" 2>/dev/null); tp=$(cat "$S45/tip.K02" 2>/dev/null); pr2=$S45/rec/K02.2/prompt
s4ok "S04-AC-2: (rebase base) run 1 left the rebase on a detached HEAD that is not the branch tip, and the node restarted" sh -c "[ -n '$dh' ] && [ -n '$tp' ] && [ '$dh' != '$tp' ] && [ -s '$pr2' ]"
s4ok "S04-AC-2: (rebase base) the prompt names the leftover patch" sh -c "[ -s '$pr2' ] && grep -qF 'leftover/' '$pr2'"
s4ok "S04-AC-2: (rebase base) the prompt names the commit the patch applies to (the rebase's detached HEAD)" sh -c "[ -n '$dh' ] && [ -s '$pr2' ] && grep -qF \"\$(printf %s '$dh' | cut -c1-7)\" '$pr2'"

# ---- V01: the loop's version: start line, rendered prompts, NOODLEBOT_VERSION, commit trailer ----
# The loop runs from a Git checkout $nbv (tag v7.0, one commit after it, GitHub origin), so its version is
# known: v7.0-1-g<sha>. The fake claude records NOODLEBOT_VERSION and makes commits in its worktree and in
# a second worktree of the clone, each once without and once with a Noodlebot-Version trailer of its own.
nbv=$tmp/nbv datav=$tmp/datav V01=$tmp/v01 V01_CLONE=$tmp/datav/repos/pv
statev=$datav/state/pv
state=$statev   # ok prints this log on a failure
export V01 V01_CLONE
mkdir -p "$nbv/scheduler" "$nbv/plugin" "$datav/repos" "$statev/node" "$V01" "$tmp/bin5"
cp "$src"/loop.sh "$src"/ready.py "$src"/release-markers.sh "$src"/run-session.sh "$src"/unattended.md \
	"$src"/issues.py "$src"/unattended-triage.md "$src"/status.sh "$src"/report.py "$src"/usage.py "$nbv/scheduler/"
[ -f "$src/version.sh" ] && cp "$src/version.sh" "$nbv/scheduler/"
touch "$nbv/plugin/.keep"
git init -q -b main "$nbv"
git -C "$nbv" add -A && git -C "$nbv" -c user.name=t -c user.email=t@t commit -q -m v1
git -C "$nbv" tag v7.0
git -C "$nbv" -c user.name=t -c user.email=t@t commit -q --allow-empty -m v2
git -C "$nbv" remote add origin https://github.com/o/nbv.git
v01_ver=$(git -C "$nbv" describe --tags --always)
v01_sig=$(sh "$src/version.sh" --signature "$nbv" 2>/dev/null)
git init -q -b main "$tmp/workv"; mkdir -p "$tmp/workv/docs"
printf 'nodes:\n  - {id: C01, name: only-node, deps: []}\n' >"$tmp/workv/docs/graph.yaml"
git -C "$tmp/workv" add -A && git -C "$tmp/workv" -c user.name=t -c user.email=t@t commit -q -m init
git clone -q --bare "$tmp/workv" "$tmp/remotev.git"
git clone -q "$tmp/remotev.git" "$V01_CLONE"
cat >"$tmp/bin5/claude" <<'EOF'
#!/bin/sh
case "$2" in "/noodlebot:triage "*) echo "${NOODLEBOT_VERSION-unset}" >"$V01/env.triage"; touch "$V01/done.triage"; exit 0 ;; esac
id=${2##* }
echo "${NOODLEBOT_VERSION-unset}" >"$V01/env.node"
v=${NOODLEBOT_VERSION:-}
g() { git -c user.name=t -c user.email=t@t "$@"; }
# mk <label> <file>: one commit without a trailer, one with the session's own trailer
mk() {
	echo "$2" >"$2.1"; git add "$2.1"; g commit -q -m "$1 plain"; echo "$1-plain $(git rev-parse HEAD)" >>"$V01/commits"
	echo "$2" >"$2.2"; git add "$2.2"; g commit -q -m "$1 own trailer

Noodlebot-Version: $v"; echo "$1-trailer $(git rev-parse HEAD)" >>"$V01/commits"
}
mk own a
git -C "$V01_CLONE" worktree add -q --detach "$V01/wt2" HEAD
( cd "$V01/wt2" && mk second b )
# V01-AC-6, real-world shape: the session's own trailer (the right one, then another value) followed by Co-Authored-By.
mk2() {
	echo "$2" >"$2.3"; git add "$2.3"
	g commit -q -m "$1 trailer then co-author

Noodlebot-Version: $3
Co-Authored-By: Claude <noreply@anthropic.com>"; echo "$1 $(git rev-parse HEAD)" >>"$V01/commits2"
}
mk2 own-same a "$v"
mk2 own-other a "different-value"
( cd "$V01/wt2" && mk2 second-same b "$v" && mk2 second-other b "different-value" )
echo "Q1: x" >"$V01_STATE/node/$id/QUESTION.md"
touch "$V01/done.node"
exit 0
EOF
# gh: no PRs; one issue labelled noodlebot by the owner, until the loop removes that label.
echo '[{"number": 46}]' >"$V01/issues.json"
cat >"$tmp/bin5/gh" <<'EOF'
#!/bin/sh
case " $* " in
*" --state merged "*) ;;
*"/issues?labels=noodlebot"*) cat "$V01/issues.json" ;;
*"/events"*) echo '[{"event": "labeled", "label": {"name": "noodlebot"}, "actor": {"login": "o"}}]' ;;
*" DELETE "*"/labels/noodlebot"*) echo '[]' >"$V01/issues.json"; echo '[]' ;;
*"/labels"*) cat >/dev/null; echo '{}' ;;
esac
exit 0
EOF
chmod +x "$tmp/bin5/claude" "$tmp/bin5/gh"
export V01_STATE=$statev
NOODLEBOT_DATA=$datav PATH=$tmp/bin5:$PATH SCHED_REPORT=0 SCHED_TICK=1 SCHED_POLL=0.2 bash "$nbv/scheduler/loop.sh" o/pv >"$tmp/pv.out" 2>&1 &
lpv=$!; pids+=("$lpv")
timeout 20 sh -c "until [ -e '$V01/done.node' ] && [ -e '$V01/done.triage' ]; do sleep 0.2; done"
sleep 1.5
touch "$HOME/STOP-pv"
timeout 5 sh -c "while kill -0 $lpv 2>/dev/null; do sleep 0.1; done"

ok "V01 (harness): the loop's checkout has a known version after a tag" sh -c "case '$v01_ver' in v7.0-1-g*) true ;; *) false ;; esac"
ok "V01-AC-3: a first start writes exactly one line 'loop started for o/pv, version <version>'" sh -c "[ \$(grep -c 'loop started for o/pv, version ' '$statev/status.log') = 1 ] && grep -q 'loop started for o/pv, version $v01_ver\$' '$statev/status.log'"
ok "V01-AC-3: and state/pv/version holds that version" sh -c "[ \"\$(cat '$statev/version' 2>/dev/null)\" = '$v01_ver' ]"
for t in "$src"/unattended*.md; do
	ok "V01-AC-5: the template $(basename "$t") contains @VERSION@" grep -qF @VERSION@ "$t"
done
for k in "node:$statev/node/C01/unattended.md" "triage:$statev/issue/46/unattended.md"; do
	f=${k#*:}
	ok "V01-AC-5: the rendered ${k%%:*} prompt exists" test -s "$f"
	ok "V01-AC-5: the rendered ${k%%:*} prompt has no @VERSION@ left" sh -c "[ -s '$f' ] && ! grep -qF @VERSION@ '$f'"
	ok "V01-AC-5: the rendered ${k%%:*} prompt contains the loop's version" grep -qF "$v01_ver" "$f"
	ok "V01-AC-5: the rendered ${k%%:*} prompt contains the signature line" grep -qF -- "$v01_sig" "$f"
	ok "V01-AC-5: the rendered ${k%%:*} prompt tells the session to end PR bodies and comments with the signature line" sh -c "grep -qiE 'pr body|pr bodies' '$f' && grep -qi 'comment' '$f' && grep -qF -- '$v01_sig' '$f'"
	ok "V01-AC-5: the rendered ${k%%:*} prompt, in one instruction, says to end every PR body and every comment with the signature line" sh -c "grep -qi 'end every PR body and every comment' '$f' && grep -i -A3 'end every PR body and every comment' '$f' | grep -qF -- '$v01_sig'"
done
ok "V01-AC-5: the node session's environment has NOODLEBOT_VERSION equal to the version" sh -c "[ \"\$(cat '$V01/env.node' 2>/dev/null)\" = '$v01_ver' ]"
ok "V01-AC-5: the triage session's environment has NOODLEBOT_VERSION equal to the version" sh -c "[ \"\$(cat '$V01/env.triage' 2>/dev/null)\" = '$v01_ver' ]"
# AC-6: each commit ends with exactly one trailer.
ok "V01-AC-6: the fake session made its four commits" sh -c "[ \$(wc -l <'$V01/commits' 2>/dev/null || echo 0) = 4 ]"
while read -r lbl sha; do
	where=worktree; case $lbl in second-*) where="second worktree of the clone" ;; esac
	case $lbl in *plain) how="without a trailer of its own" ;; *) how="with a trailer of its own" ;; esac
	ok "V01-AC-6: a commit in the session's $where, $how, ends with exactly one Noodlebot-Version trailer for the session's version" sh -c "[ \"\$(git -C '$V01_CLONE' log -1 --format=%B '$sha' | git interpret-trailers --parse | grep -c '^Noodlebot-Version:')\" = 1 ] && git -C '$V01_CLONE' log -1 --format=%B '$sha' | git interpret-trailers --parse | grep -qx 'Noodlebot-Version: $v01_ver'"
done <"$V01/commits"
ok "V01-AC-6: the fake session made its four commits with a Co-Authored-By after the trailer" sh -c "[ \$(wc -l <'$V01/commits2' 2>/dev/null || echo 0) = 4 ]"
while read -r lbl sha; do
	ok "V01-AC-6: a session commit '$lbl' (its own trailer, then Co-Authored-By) ends with exactly one Noodlebot-Version trailer, the session's version" sh -c "[ \"\$(git -C '$V01_CLONE' log -1 --format=%B '$sha' | git interpret-trailers --parse | grep -c '^Noodlebot-Version:')\" = 1 ] && git -C '$V01_CLONE' log -1 --format=%B '$sha' | git interpret-trailers --parse | grep -qx 'Noodlebot-Version: $v01_ver'"
done <"$V01/commits2"
git -C "$V01_CLONE" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "outside any session" 2>/dev/null
ok "V01-AC-6: a commit in the clone outside any session gets no Noodlebot-Version trailer" sh -c "[ -x '$V01_CLONE/.git/hooks/commit-msg' ] && ! git -C '$V01_CLONE' log -1 --format=%B | git interpret-trailers --parse | grep -q '^Noodlebot-Version:'"
NOODLEBOT_VERSION=probe git -C "$V01_CLONE" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "inside a session" 2>/dev/null
ok "V01-AC-6: the same clone's hook adds the trailer when NOODLEBOT_VERSION is set" sh -c "[ \"\$(git -C '$V01_CLONE' log -1 --format=%B | git interpret-trailers --parse | grep -c '^Noodlebot-Version: probe\$')\" = 1 ]"
if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: all loop checks"
