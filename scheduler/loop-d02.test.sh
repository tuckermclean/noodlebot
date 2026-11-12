#!/bin/bash
# D02: the runtime root (see the section below). Part of the end-to-end test of scheduler/loop.sh (testdata/lib/loop-prelude.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-fakes.sh"
# The gh of the main run, as it answers when this section starts: A01's PR and A02's spec PR are merged.
fake_main_gh
printf '1 node/A01-first-node\n55 spec/A02-topic\n' >"$tmp/merged.tsv"
export PATH=$tmp/bin:$PATH

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
[ -f "$src/harness.py" ] && { mkdir -p "$nb2/scheduler/harnesses"; cp "$src/harness.py" "$nb2/scheduler/"; cp "$src"/harnesses/*.py "$nb2/scheduler/harnesses/"; }
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
# d02_started <cwd log>: the triage session and two node sessions have started.
d02_started() { grep -q '^triage' "$1" && [ "$(grep -c '^node' "$1")" -ge 2 ]; }
# d02_written <root> <name>: the files the checks of d02_run read exist (a tick has run: heartbeat).
d02_written() {
	local st=$1/state/$2 wt=$1/worktrees/$2
	[ -e "$st/heartbeat" ] && [ -e "$st/loop.lock" ] && [ -e "$st/status.log" ] && [ -d "$1/repos/$2/.git" ] && [ -e "$wt/A02/.git" ] &&
		[ -s "$st/node/A02/unattended.md" ] && [ -s "$st/issue/46/unattended.md" ] && [ -e "$st/node/A02/QUESTION.md" ]
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
	wait_until 15 d02_started "$cwd"
	# the loop has ticked and has written what the checks below read (the old fixed sleep of 1 s)
	wait_until 5 d02_written "$root" "$name"
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
	wait_until 5 d02_gone "$lp"
}
d02_gone() { ! kill -0 "$1" 2>/dev/null; }
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
	pkill -P "$sp" 2>/dev/null; kill "$sp" 2>/dev/null
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
sleep 1   # nothing to observe: the loop has exited; a session it had started would log at once, so wait the same moment as before
ok "D02-AC-3: a root inside a Git working tree exits 2" test "$rc" = 2
ok "D02-AC-3: and starts no session" test ! -s "$tmp/cwd-pg.log"
ok "D02-AC-3: and its message names that working tree" grep -qF "$gw" "$tmp/pg.out"
ok "D02-AC-3: its message names the working tree itself, not only the root" env GW="$gw" awk 'BEGIN{r=ENVIRON["GW"] "/data"; n=length(r)} {while((i=index($0,r))>0) $0=substr($0,1,i-1) substr($0,i+n); if(index($0,ENVIRON["GW"])>0) f=1} END{exit !f}' "$tmp/pg.out"

# D02-AC-3: a root that does not exist yet inside a working tree is refused too, and not created.
: >"$tmp/cwd-ny.log"
NOODLEBOT_DATA=$gw/not/yet FAKE_LOG=$tmp/cwd-ny.log FAKE_STATE=$tmp/ny-state PATH=$tmp/bin2:$PATH \
	SCHED_REPORT=0 SCHED_TICK=1 SCHED_POLL=0.2 timeout 10 bash "$nb2/scheduler/loop.sh" o/pg >"$tmp/ny.out" 2>&1; rc=$?
sleep 1   # nothing to observe: the loop has exited; a session it had started would log at once, so wait the same moment as before
ok "D02-AC-3: a not-yet-created root inside a Git working tree exits 2" test "$rc" = 2
ok "D02-AC-3: and starts no session (not-yet-created root)" test ! -s "$tmp/cwd-ny.log"
ok "D02-AC-3: and names the working tree (not-yet-created root)" env GW="$gw" awk 'BEGIN{r=ENVIRON["GW"] "/not/yet"; n=length(r)} {while((i=index($0,r))>0) $0=substr($0,1,i-1) substr($0,i+n); if(index($0,ENVIRON["GW"])>0) f=1} END{exit !f}' "$tmp/ny.out"
ok "D02-AC-3: and does not create the root's parent (not-yet-created root)" test ! -e "$gw/not"

# ---- U01-AC-8: the rendered node and triage prompts (the follow-up prompt is checked in loop-s03.test.sh), and the skills ----
. "$src/testdata/lib/loop-u01.sh"
u01_selftest
u01_prompt_checks node "$tmp/data2/state/ps/node/A02/unattended.md"
u01_prompt_checks triage "$tmp/data2/state/ps/issue/46/unattended.md"
u01_pr_checks node "$tmp/data2/state/ps/node/A02/unattended.md"
u01_skill_checks

loop_end
