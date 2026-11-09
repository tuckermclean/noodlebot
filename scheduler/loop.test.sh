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
printf 'state/\nrepos/\nworktrees/\n' >"$tmp/nbwork/.gitignore"
printf 'test:\n\t@echo stub test passes\n\n.PHONY: test\n' >"$tmp/nbwork/Makefile"
git -C "$tmp/nbwork" add -A && git -C "$tmp/nbwork" -c user.name=t -c user.email=t@t commit -q -m c1
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
ok "D01-AC-1: the deploy is one status-log event" sh -c "[ \$(grep -cE 'deployed ${c1:0:7}[0-9a-f]*\.\.${c2:0:7}' '$stated/status.log') = 1 ]"
ok "D01-AC-1: a deploy is exactly one status-log line in total (no second 're-execs' line)" sh -c "[ \$(grep -c 'deployed' '$stated/status.log') = 1 ] && [ \$(grep -cE 'deployed ${c1:0:7}[0-9a-f]*\.\.${c2:0:7}' '$stated/status.log') = 1 ]"
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
ok "D01-AC-2: a commit failing make test is one status-log event" withind 5 "not deployed: ${c3:0:7}[0-9a-f]* fails make test"
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


if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: all loop checks"
