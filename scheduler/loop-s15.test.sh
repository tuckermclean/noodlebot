#!/bin/bash
# S15-AC-1 .. S15-AC-4 (and the budget and wait rules of S15-AC-5, S15-AC-7): a node session's end is judged only against
# PR lists fetched after it ended. End-to-end loop of scheduler/loop.sh, one loop for all cases, with a fake forge (gh) that
# reproduces the race without depending on timing, and fake sessions (claude), nodes N01..N07 (no deps) in their own remote:
#   N01 fresh node: opens its PR (open.txt) and exits (rc 0) while the tick fetches its lists      (S15-AC-1)
#   N02 follow-up (FOLLOWUP marker, its node's PR merged): opens its PR on node/N02-followup-1 and exits the same way (S15-AC-2)
#   N03 exits (rc 0) the same way with no PR, no QUESTION.md, no WAITING-PR; its second run runs until stopped (S15-AC-3)
#   N04 / N05 end before the tick's fetch begins, N04 with a PR, N05 without (judged by the tick that finds them gone)
#   N06 runs until its PR is merged in a tick's lists: that tick stops it (stop_done) and judges its end    (S15-AC-3)
#   N07 opens its PR, which is merged at once (merged.tsv), and exits the same way: with a merged PR its worktree is the
#       first thing cleanup_merged removes, so it shows that the end waits (S15-AC-4)
# The fake forge, armed by the test for one tick (its number K: the tick's n-th merged and open list calls):
#   - the open list call of tick K reads open.txt at once (no PR of N01, N02, N03 yet) and returns that list only when
#     the session.rc of N01, N02, N03 and N07 exist; the merged list call of tick K returns merged.tsv after the same wait
#     (N07's PR is in it); so those sessions open their PRs and end while tick K fetches its lists;
#   - an `issues` call (the tick's triage step, which follows its check of its sessions) can be held the same way until the
#     session.rc of N04 and N05 exist: they end after that tick's check of its sessions and before the next tick's fetch.
# Every open list call writes snap.<call number>: the status log's end lines, the starts, the worktree, the archive and the
# pid file of each node as the call began, i.e. what the tick before it left. So "while its end waits" is read at the start
# of the next tick's fetch, not after a sleep. Each wait of the fake forge gives up after 60 s (file "gaveup": a FAIL).
# Waits in this file wait for the condition they check; "did not happen" checks read after ticks (wait_ticks) have passed.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-fakes.sh"

S15=$tmp/s15; export S15
mkdir -p "$S15" "$tmp/bin15" "$tmp/nb15/scheduler" "$tmp/nb15/plugin"
write_closed_py "$S15/closed.py"
cp "$src"/loop.sh "$src"/ready.py "$src"/release-markers.sh "$src"/run-session.sh "$src"/unattended.md \
	"$src"/issues.py "$src"/unattended-triage.md "$src"/status.sh "$src"/report.py "$src"/usage.py "$tmp/nb15/scheduler/"
[ -f "$src/harness.py" ] && { mkdir -p "$tmp/nb15/scheduler/harnesses"; cp "$src/harness.py" "$tmp/nb15/scheduler/"; cp "$src"/harnesses/*.py "$tmp/nb15/scheduler/harnesses/"; }
[ -f "$src/forge.py" ] && { mkdir -p "$tmp/nb15/scheduler/forges"; cp "$src/forge.py" "$tmp/nb15/scheduler/"; cp "$src"/forges/*.py "$tmp/nb15/scheduler/forges/"; }
[ -f "$src/unattended-followup.md" ] && cp "$src/unattended-followup.md" "$tmp/nb15/scheduler/"
git init -q -b main "$tmp/work15"; mkdir -p "$tmp/work15/docs"
{ echo 'nodes:'; for i in 1 2 3 4 5 6 7; do echo "  - {id: N0$i, name: n$i, deps: []}"; done; } >"$tmp/work15/docs/graph.yaml"
git -C "$tmp/work15" add -A && git -C "$tmp/work15" -c user.name=t -c user.email=t@t commit -q -m init
git clone -q --bare "$tmp/work15" "$tmp/remote15.git"
data15=$tmp/data15 st15=$tmp/data15/state/sf wt15=$tmp/data15/worktrees/sf cl15=$tmp/data15/repos/sf
S15_STATE=$st15 S15_WT=$wt15; export S15_STATE S15_WT
mkdir -p "$data15/repos" "$st15/node"
git clone -q "$tmp/remote15.git" "$cl15"
# N02's node PR is merged and its question answered: a follow-up starts on node/N02-followup-1 (as S03's G01)
echo '20 node/N02-n2' >"$S15/merged.tsv"
: >"$S15/open.txt"; : >"$S15/closed.tsv"; : >"$S15/polls"
mkdir -p "$st15/node/N02"; echo "Q1: which way?" >"$st15/node/N02/QUESTION.md"; echo "Q1: as recommended" >"$st15/node/N02/ANSWER.md"

cat >"$tmp/bin15/gh" <<'EOF'
#!/bin/sh
d=$S15 st=$S15_STATE
bump() { n=$(cat "$d/n.$1" 2>/dev/null); echo $(( ${n:-0} + 1 )) >"$d/n.$1"; }
# settle <file>: the clock is two whole seconds past the newest of the listed files' times: a tick that begins after this has
# begun more than one second after those files were written, whatever resolution the file times have (a condition on the clock)
settle() {
	m=0
	for p in $(cat "$1" 2>/dev/null); do t=$(stat -c %Y "$p" 2>/dev/null); [ "${t:-0}" -le "$m" ] || m=$t; done
	while [ "$(date +%s)" -lt $((m + 2)) ]; do sleep 0.1; done
}
# waitrc <file>: wait until every path listed in the file exists (then settle); gives up after 60 s (the file "gaveup" says so)
waitrc() {
	i=0
	while :; do
		ok=1
		for p in $(cat "$1" 2>/dev/null); do [ -e "$p" ] || ok=0; done
		[ "$ok" = 1 ] && { settle "$1"; return 0; }
		i=$((i + 1))
		[ "$i" -le 600 ] || { echo "$1" >>"$d/gaveup"; return 1; }
		sleep 0.1
	done
}
# snap <n>: the state the tick before this call left, one line per node: id, ends with a PR, ends with no PR, all ends,
# stopped events, starts, worktree (1: there), archive entries, pid file (1: there)
snap() {
	{
		for id in N01 N02 N03 N04 N05 N06 N07; do
			ewp=$(grep -cE "session $id ended .*with a PR" "$st/status.log" 2>/dev/null)
			enp=$(grep -cE "session $id ended .*no PR" "$st/status.log" 2>/dev/null)
			eall=$(grep -cE "session $id ended" "$st/status.log" 2>/dev/null)
			stp=$(grep -c "stopped session $id" "$st/status.log" 2>/dev/null)
			sts=$(cat "$st/node/$id/starts" 2>/dev/null)
			w=0; [ -d "$S15_WT/$id" ] && w=1
			a=$(ls -d "$st/archive/$id-out"* 2>/dev/null | wc -l)
			pf=0; [ -e "$st/node/$id/session.pid" ] && pf=1
			echo "$id ${ewp:-0} ${enp:-0} ${eall:-0} ${stp:-0} ${sts:--} $w $a $pf"
		done
		echo "polls $(wc -l <"$d/polls")"
	} >"$d/new.$1"
	mv "$d/new.$1" "$d/snap.$1"
}
case " $* " in
*" --state merged "*)
	bump merged; echo >>"$d/polls"; n=$(cat "$d/n.merged"); k=$(cat "$d/arm.k" 2>/dev/null)
	[ "$k" = "$n" ] && waitrc "$d/arm.paths"
	cat "$d/merged.tsv" ;;
*" --state open "*)
	bump open; n=$(cat "$d/n.open"); k=$(cat "$d/arm.k" 2>/dev/null)
	snap "$n"
	if [ "$k" = "$n" ]; then
		cat "$d/open.txt" >"$d/stale.$n"   # read now; returned when the sessions have ended
		touch "$d/open.in"
		waitrc "$d/arm.paths" && touch "$d/released"
		cat "$d/stale.$n"
	else cat "$d/open.txt"; fi ;;
*" --state closed "*) S01=$S15 exec python3 -I "$S15/closed.py" "$@" ;;
*"/issues?labels=noodlebot"*)
	if mv "$d/arm.issues" "$d/arm.issues.used" 2>/dev/null; then
		touch "$d/issues.in"; waitrc "$d/arm.issues.used"
	fi
	echo '[]' ;;
esac
exit 0
EOF
cat >"$tmp/bin15/claude" <<'EOF'
#!/bin/sh
id=${2##* } d=$S15
n=$(( $(cat "$d/runs.$id" 2>/dev/null || echo 0) + 1 )); echo $n >"$d/runs.$id"
mkdir -p "out/node/$id"; echo evidence >"out/node/$id/brief.md"
wait_for() { i=0; while [ ! -e "$d/$1" ]; do i=$((i + 1)); [ "$i" -le 1500 ] || exit 9; sleep 0.2; done; }
hang() { while :; do sleep 0.2; done; }
case $id.$n in
N01.1) wait_for go.N01; echo node/N01-n1 >>"$d/open.txt" ;;
N02.1) wait_for go.N02; echo node/N02-followup-1 >>"$d/open.txt" ;;
N03.1|N05.1) wait_for "go.$id" ;;
N04.1) wait_for go.N04; echo node/N04-n4 >>"$d/open.txt" ;;
N07.1) wait_for go.N07; echo '707 node/N07-n7' >>"$d/merged.tsv" ;;
*) hang ;;
esac
exit 0
EOF
chmod +x "$tmp/bin15/gh" "$tmp/bin15/claude"
st=$st15 state=$st15

d15=0   # 1 after a wait failed: every later wait is short, so a broken run ends quickly
# w15 <name> <seconds> <command...>: PASS when the command succeeds within that time (a give-up bound: the wait is the condition)
w15() { local name=$1 t=$2; shift 2; [ "$d15" = 1 ] && t=1; if waitf "$t" "$@"; then pass "$name"; else fail "$name"; d15=1; fi; }
# wn15: w15 that does not stop the later waits (a check of its own)
wn15() { local name=$1 t=$2; shift 2; if waitf "$t" "$@"; then pass "$name"; else fail "$name"; fi; }
c15() { local name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
n15() { local n; n=$(grep -cE "$1" "$st15/status.log" 2>/dev/null); echo "${n:-0}"; }
has15() { grep -qE "$1" "$st15/status.log" 2>/dev/null; }
cnt15() { [ "$(n15 "$1")" = "$2" ]; }
eq15() { [ "$1" = "$2" ]; }
runs15() { cat "$S15/runs.$1" 2>/dev/null || echo 0; }
starts15() { cat "$st15/node/$1/starts" 2>/dev/null || echo -; }
# sn15 <call number> <node> <field>: a field of snap.<n> (2 ends with a PR, 3 no PR, 4 all ends, 5 stopped, 6 starts, 7 worktree, 8 archive, 9 pid file)
sn15() { awk -v i="$2" -v c="$3" '$1 == i { print $c }' "$S15/snap.$1" 2>/dev/null; }
runs_ge15() { [ "$(runs15 "$1")" -ge "$2" ]; }
# stopsnap15: some snapshot shows N06's stop event (a list call began after the tick that stopped it)
stopsnap15() { cat "$S15"/snap.* 2>/dev/null | awk '$1 == "N06" && $5 >= 1 { f = 1 } END { exit !f }'; }
allstarted() { local i; for i in 1 2 3 4 5 6 7; do [ "$(runs15 N0$i)" -ge 1 ] || return 1; done; }
dump15() {
	echo "      snapshots (the list calls' view of N06 and N07, in call order):"
	for f in $(ls "$S15"/snap.* 2>/dev/null | sort -t. -k2 -n); do echo "      $(basename "$f"): $(grep -E '^N0[67] |^polls' "$f" | tr '\n' '|')"; done
	echo "      status.log (tail):"; tail -n 50 "$st15/status.log" 2>/dev/null | sed 's/^/      /'; }
s15_cleanup() {
	local f
	for f in "$st15"/node/*/session.pid; do [ -e "$f" ] && kill -KILL -- "-$(cat "$f")" 2>/dev/null; done
	return 0
}
extra_cleanup() { s15_cleanup; }
fails0=$fails

# N08: a node's feedback session already running when the loop starts (picked up by its pid file, as after a restart)
mkdir -p "$st15/node/N08" "$tmp/bin15n8" "$tmp/wt15n8"
printf '%s\n' '#!/bin/sh' 'd=$S15; echo 1 >"$d/runs.8"; i=0' 'while [ ! -e "$d/go.N08" ]; do i=$((i + 1)); [ "$i" -le 1500 ] || exit 9; sleep 0.2; done' 'exit 0' >"$tmp/bin15n8/claude"
chmod +x "$tmp/bin15n8/claude"
# a wrapper in front of the fake forge: each open list call first writes snap8.<call number>, N08's end lines and its files as that call began
mv "$tmp/bin15/gh" "$tmp/bin15/gh.real"
cat >"$tmp/bin15/gh" <<'EOF8'
#!/bin/sh
d=$S15 st=$S15_STATE
case " $* " in
*" --state open "*)
	n=$(( $(cat "$d/n.open" 2>/dev/null || echo 0) + 1 ))
	{ echo "$(grep -c 'feedback session of N08 ended' "$st/status.log" 2>/dev/null)"
	  ls "$st"/node/N08/answered/*-FEEDBACK.md 2>/dev/null | wc -l
	  [ -e "$st/node/N08/FEEDBACK.md" ] && echo 1 || echo 0; } | tr '\n' ' ' >"$d/new8.$n"
	mv "$d/new8.$n" "$d/snap8.$n" ;;
esac
exec "$(dirname "$0")/gh.real" "$@"
EOF8
chmod +x "$tmp/bin15/gh"
printf 'url: https://example.test/pull/8#c1\nkind: conversation\nplease fix\n' >"$st15/node/N08/FEEDBACK.md"
echo feedback >"$st15/node/N08/session.kind"; echo 1 >"$st15/node/N08/starts"
PATH=$tmp/bin15n8:$PATH S15=$S15 setsid "$src/run-session.sh" "$tmp/wt15n8" "$st15/node/N08" "/noodlebot:node --feedback 8" \
	</dev/null >"$st15/node/N08/session.jsonl" 2>"$st15/node/N08/session.stderr" &
echo $! >"$st15/node/N08/session.pid"; pids+=("$!")

NOODLEBOT_DATA=$data15 PATH=$tmp/bin15:$PATH SCHED_REPORT=0 SCHED_THROTTLE=0 SCHED_TICK=1 SCHED_POLL=0.2 \
	bash "$tmp/nb15/scheduler/loop.sh" o/sf >>"$tmp/s15-loop.out" 2>&1 &
pids+=("$!"); lp15=$!
w15 "S15: every node's first session has started (N01..N07 each in a tick of the loop)" 60 allstarted
c15 "S15: (setup) N02 started as a follow-up on node/N02-followup-1, start 1 of 2" has15 'started N02 .*node/N02-followup-1.*start 1 of 2'

# ---- phase 1: N04 and N05 end after a tick's check of its sessions and before the next tick's fetch ----
printf '%s\n' "$st15/node/N04/session.rc" "$st15/node/N05/session.rc" >"$S15/arm.issues.tmp" && mv "$S15/arm.issues.tmp" "$S15/arm.issues"
w15 "S15: a tick is held in its triage step (after its check of its sessions)" 30 test -e "$S15/issues.in"
# ---- phase 2: the next tick, K, fetches its lists while N01, N02, N03 and N07 open their PRs and end ----
no=$(cat "$S15/n.open") nm=$(cat "$S15/n.merged")
K=$(( (no > nm ? no : nm) + 1 ))
printf '%s\n' "$st15/node/N01/session.rc" "$st15/node/N02/session.rc" "$st15/node/N03/session.rc" "$st15/node/N07/session.rc" >"$S15/arm.paths"
echo "$st15/node/N08/session.rc" >>"$S15/arm.paths"
echo "$K" >"$S15/arm.k.tmp" && mv "$S15/arm.k.tmp" "$S15/arm.k"
touch "$S15/go.N04" "$S15/go.N05"
w15 "S15: the stale tick's fetch began and the fake forge read its open list" 40 test -e "$S15/open.in"
touch "$S15/go.N01" "$S15/go.N02" "$S15/go.N03" "$S15/go.N07"
touch "$S15/go.N08"
w15 "S15: the four sessions ended while the fake forge held the lists (their session.rc exist)" 40 test -e "$S15/released"
w15 "S15: the tick after the stale tick began its fetch" 40 test -e "$S15/snap.$((K + 1))"
c15 "S15: (setup) the stale list read had no PR of N01, N02, N03; it had N04's" sh -c "! grep -qE 'N01|N02|N03' '$S15/stale.$K' && grep -qx node/N04-n4 '$S15/stale.$K'"
c15 "S15: (setup) the PRs of N01 and N02 were opened by then" sh -c "grep -qx node/N01-n1 '$S15/open.txt' && grep -qx node/N02-followup-1 '$S15/open.txt'"

# ---- AC-4: what the tick that fetched while the sessions ended left, read as the next tick's fetch began ----
k1=$((K + 1))
for id in N01 N02 N03 N07; do
	c15 "S15-AC-4: $id: its end waits, the status log has no end line for it" eq15 "$(sn15 "$k1" $id 4)" 0
	c15 "S15-AC-4: $id: it is not started again (starts 1)" eq15 "$(sn15 "$k1" $id 6)" 1
	c15 "S15-AC-4: $id: its worktree is not removed" eq15 "$(sn15 "$k1" $id 7)" 1
	c15 "S15-AC-4: $id: its evidence is not archived" eq15 "$(sn15 "$k1" $id 8)" 0
done
c15 "S15-AC-4: N07: its pid file stays (the session is left for the next tick)" eq15 "$(sn15 "$k1" N07 9)" 1
# AC-3: ended before the fetch began: judged by the tick that finds them gone, as before
c15 "S15-AC-3: N04 (ended before the fetch, with a PR): judged in the stale tick, 'with a PR'" eq15 "$(sn15 "$k1" N04 2)$(sn15 "$k1" N04 4)" 11
c15 "S15-AC-3: N05 (ended before the fetch, no PR): judged in the stale tick, 'no PR' ... may start again" eq15 "$(sn15 "$k1" N05 3)$(sn15 "$k1" N05 4)" 11
c15 "S15-AC-3: N05 started again in the stale tick (starts 2)" eq15 "$(sn15 "$k1" N05 6)" 2

# ---- later ticks: the ends are judged against lists fetched after them. The tick after K logs them; the call after that one
# (snap K+2) began once that tick was over, so what it shows is what tick K+1 did. ----
k2=$((K + 2))
w15 "S15: two ticks after the stale tick began its fetch" 40 test -e "$S15/snap.$k2"
c15 "S15-AC-1: N01's end is logged 'with a PR' at a later tick (not in the stale tick, in the next)" sh -c "[ '$(sn15 "$k1" N01 4)' = 0 ] && [ '$(sn15 "$k2" N01 2)' = 1 ]"
c15 "S15-AC-2: N02's end is logged 'with a PR' at a later tick" sh -c "[ '$(sn15 "$k1" N02 4)' = 0 ] && [ '$(sn15 "$k2" N02 2)' = 1 ]"
c15 "S15-AC-3: N03's end is logged 'no PR, no QUESTION.md; may start again' at a later tick" sh -c "[ '$(sn15 "$k1" N03 4)' = 0 ] && [ '$(sn15 "$k2" N03 3)' = 1 ]"
c15 "S15-AC-3: N03 starts again at that tick, start 2 of 2" has15 'started N03 .*start 2 of 2'
c15 "S15-AC-4: N07's end is judged at the next tick: 'with a PR'" eq15 "$(sn15 "$k2" N07 2)" 1
c15 "S15-AC-4: N07: then its merged node's worktree goes, evidence archived, as before" sh -c "[ '$(sn15 "$k2" N07 7)' = 0 ] && [ '$(sn15 "$k2" N07 8)' = 1 ]"

# ---- N08: a node's feedback session (session.kind feedback, its prompt "node --feedback 8" on node/N08) ends (rc 0) during the held
# fetch of tick K too. A feedback session's end reads no PR list: it is judged in the tick that found it gone (K), as before. The
# status log lists the files' nodes in order, so tick K's lines come before the end lines of N01 and N02, which are judged in K+1. ----
# snap8 <call number>: "<N08 end lines> <answered/ FEEDBACK.md files> <FEEDBACK.md there>" as that open list call began
s15_snap8() { cat "$S15/snap8.$1" 2>/dev/null; }
c15 "S15-AC-3: N08 (a node's feedback session, ended during the held fetch): its end is logged by the tick that found it gone (once, as the next tick's fetch began)" sh -c "[ \"\$(cat '$S15/snap8.$k1' | cut -d' ' -f1)\" = 1 ]"
c15 "S15-AC-3: N08: the end is logged once" cnt15 'feedback session of N08 ended' 1
c15 "S15-AC-3: N08: FEEDBACK.md is moved to answered/ by then (as the next tick's fetch began: moved, one file in answered/)" sh -c "[ \"\$(cat '$S15/snap8.$k1')\" = '1 1 0 ' ]"
c15 "S15-AC-3: N08: its pid file is gone and it ran once, not started again" sh -c "[ ! -e '$st15/node/N08/session.pid' ] && [ \"\$(cat '$S15/runs.8')\" = 1 ]"
wn15 "S15: N03's second session has started (run 2)" 40 runs_ge15 N03 2
wait_ticks 2 || { fail "S15: the loop's ticks pass"; d15=1; }
for id in N01 N02; do
	ac=1; [ $id = N02 ] && ac=2
	c15 "S15-AC-$ac: $id: the end is logged once" cnt15 "session $id ended" 1
	c15 "S15-AC-$ac: $id: 'with a PR' once" cnt15 "session $id ended \(rc 0\) with a PR" 1
	c15 "S15-AC-$ac: $id: never 'no PR'" cnt15 "session $id ended .*no PR" 0
	c15 "S15-AC-$ac: $id: starts is 1, the end did not change it" eq15 "$(starts15 $id)" 1
	c15 "S15-AC-$ac: $id: one run, not started again while its PR is open" eq15 "$(runs15 $id)" 1
	c15 "S15-AC-$ac: $id: one 'started' line" cnt15 "started $id " 1
	c15 "S15-AC-$ac: $id: its worktree is still there" test -d "$wt15/$id"
done
c15 "S15-AC-2: N02: its follow-up start names node/N02-followup-1 (the PR is on that branch)" cnt15 'started N02 .*node/N02-followup-1' 1
c15 "S15-AC-3: N03: 'no PR, no QUESTION.md; may start again' exactly once" cnt15 'session N03 ended \(rc 0\), no PR, no QUESTION.md; may start again' 1
c15 "S15-AC-3: N03: no other end line" cnt15 'session N03 ended' 1
c15 "S15-AC-3: N03: the end used one start, the next start is start 2 of 2 (once; start 1 of 2 once)" sh -c "[ \"\$(grep -cE 'started N03 .*start 2 of 2' '$st15/status.log')\" = 1 ] && [ \"\$(grep -cE 'started N03 .*start 1 of 2' '$st15/status.log')\" = 1 ]"
c15 "S15-AC-3: N03: starts 2, two runs" eq15 "$(starts15 N03)$(runs15 N03)" 22
c15 "S15-AC-3: N04 (ended before the fetch): 'with a PR' once, never 'no PR', one run" sh -c "[ \"\$(grep -cE 'session N04 ended' '$st15/status.log')\" = 1 ] && [ \"\$(grep -cE 'session N04 ended .*with a PR' '$st15/status.log')\" = 1 ] && [ '$(runs15 N04)' = 1 ]"
c15 "S15-AC-3: N05 (ended before the fetch): 'no PR ... may start again' once, two runs, starts 2" sh -c "[ \"\$(grep -cE 'session N05 ended .*no PR, no QUESTION.md; may start again' '$st15/status.log')\" = 1 ] && [ '$(runs15 N05)' = 2 ] && [ '$(starts15 N05)' = 2 ]"
c15 "S15-AC-3: N07: 'with a PR' once, never 'no PR', one run" sh -c "[ \"\$(grep -cE 'session N07 ended' '$st15/status.log')\" = 1 ] && [ \"\$(grep -cE 'session N07 ended .*with a PR' '$st15/status.log')\" = 1 ] && [ '$(runs15 N07)' = 1 ]"

# ---- stop_done: N06's PR is merged in a tick's lists; that tick stops it and judges its end ----
c15 "S15-AC-3: (setup) N06 runs and has not been stopped" sh -c "[ '$(runs15 N06)' = 1 ] && [ \"\$(grep -c 'stopped session N06' '$st15/status.log')\" = 0 ]"
n_before=$(cat "$S15/n.open")
echo '606 node/N06-n6' >>"$S15/merged.tsv"
wn15 "S15-AC-3: N06: the tick that finds its PR merged stops it" 40 has15 'stopped session N06: its PR #606 is merged'
wn15 "S15-AC-3: N06: its end is judged, 'with a PR'" 40 has15 'session N06 ended \(rc [0-9?]+\) with a PR'
wn15 "S15-AC-3: (setup) a tick began after the tick that stopped N06" 40 stopsnap15
# the first call whose snapshot shows the stop event shows the end line too: both lines were written between two list calls
first=''
for ((i = n_before; i <= $(cat "$S15/n.open"); i++)); do
	[ "$(sn15 "$i" N06 5)" = 1 ] && { first=$i; break; }
done
c15 "S15-AC-3: N06: the end line follows the stop line within one tick (no list call between them)" sh -c "[ -n '$first' ] && [ \"\$(awk -v i=N06 '\$1 == i { print \$2 }' '$S15/snap.$first')\" = 1 ] && [ \"\$(awk -v i=N06 '\$1 == i { print \$5 }' '$S15/snap.$((first - 1))')\" = 0 ]"
c15 "S15-AC-3: N06: the end line is the line after the stop line" sh -c "a=\$(grep -n 'stopped session N06' '$st15/status.log' | cut -d: -f1) && b=\$(grep -nE 'session N06 ended .*with a PR' '$st15/status.log' | cut -d: -f1) && [ \"\$b\" = \"\$((a + 1))\" ]"
c15 "S15-AC-3: N06: one end line, not 'no PR'" sh -c "[ \"\$(grep -cE 'session N06 ended' '$st15/status.log')\" = 1 ]"

c15 "S15: the fake forge never gave up waiting for a session.rc" test ! -e "$S15/gaveup"
kill "$lp15"; wait "$lp15" 2>/dev/null
s15_cleanup
[ "$fails" -eq "$fails0" ] || dump15

loop_end
