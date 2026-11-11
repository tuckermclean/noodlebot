#!/bin/bash
# S03: follow-ups (with the U01-AC-8 checks of the follow-up prompt). Part of the end-to-end test of scheduler/loop.sh.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-fakes.sh"
. "$src/testdata/lib/loop-u01.sh"

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
write_closed_py "$S03/closed.py"
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
s3ticks() { [ "$s3dead" = 1 ] || wait_ticks "$1"; }
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
s3ticks 1

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
s3ticks 3
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
s3ticks 3
s3chk "S03-AC-5: it does not start again while its follow-up PR is open" s3eq "$(s3runs G05)$(s3runs G04)" 12
s3chk "S03-AC-5: (G05) started once" s3cnt 'started G05 ' 1

# AC-2: a merged node with no markers, or an unanswered question, starts no session.
s3chk "S03-AC-2: a merged node with no markers starts no session" sh -c "[ '$(s3runs G06)' = 0 ] && ! grep -q 'started G06' '$st6/status.log' && [ \"\$(git -C '$cl6' branch --list 'node/G06-*' | wc -l)\" = 0 ]"
s3chk "S03-AC-2: a merged node with an unanswered QUESTION.md starts no session" sh -c "[ '$(s3runs G07)' = 0 ] && ! grep -q 'started G07' '$st6/status.log' && [ -e '$st6/node/G07/QUESTION.md' ] && [ ! -d '$st6/node/G07/answered' ]"

# AC-6 (and AC-2, AC-4, AC-5): G01 asks a question, is answered, opens its PR, merges; then a second follow-up.
touch "$S03/go.G01.1"
s3ok "S03-AC-6: a follow-up that asks a question: the session ends with QUESTION.md" 5 s3has 'session G01 ended \(rc 0\) with QUESTION.md'
s3ticks 3
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
s3ticks 3
s3chk "S03-AC-5: (G01) it does not start again while its follow-up PR is open" s3eq "$(s3runs G01)" 2
sed -i '/node\/G01-followup-1/d' "$S03/open.txt"
echo "31 node/G01-followup-1" >>"$S03/merged.tsv"; printf '31 node/G01-followup-1 %s 1\n' "$(date +%s)" >>"$S03/closed.tsv"
s3ok "S03-AC-6: once its PR is merged, the FOLLOWUP marker is moved into answered/" 5 sh -c "ls '$st6/node/G01/answered' | grep -q FOLLOWUP && [ ! -e '$st6/node/G01/FOLLOWUP' ]"
s3ok "S03-AC-6: and, no session running, its evidence is archived under state/archive/ (without replacing the earlier G01-out)" 5 sh -c "grep -rqx fu-evidence '$st6/archive' && grep -qx old-evidence '$st6/archive/G01-out/brief.md'"
s3ok "S03-AC-6: and its worktree is removed" 5 test ! -d "$w1"
s3ticks 3
s3chk "S03-AC-6: the node starts no session at later ticks" s3eq "$(s3runs G01)" 2
s3chk "S03-AC-6: and nothing says it was stopped" test "$(s3n 'stopped session G01')" = 0
# a later answer: the next follow-up number
echo "Q2: next?" >"$st6/node/G01/QUESTION.md"; echo "Q2: go" >"$st6/node/G01/ANSWER.md"
s3ok "S03-AC-2: after a merged follow-up, the next answered question starts node/G01-followup-2" 8 s3has 'started G01 .*node/G01-followup-2.*start 1 of 2'
s3ok "S03-AC-2: (G01) its session has started (run 3)" 8 sh -c "[ -s '$S03/br.G01.3' ] && [ -s '$S03/head.G01.3' ]"
s3chk "S03-AC-2: (G01) the session ran on node/G01-followup-2" s3eq "$(s3f br.G01.3)" node/G01-followup-2
s3chk "S03-AC-2: (G01) whose first commit is origin/main's head" sh -c "[ '$(s3f head.G01.3)' = '$(s3origin)' ] && [ \"\$(git -C '$cl6' rev-parse node/G01-followup-2)\" = '$(s3origin)' ]"
s3ticks 4
s3chk "S03-AC-4: (G01) it is not stopped while the earlier follow-up's PR #31 and the node's PR are merged" s3pg G01
s3chk "S03-AC-4: (G01) and nothing says it was stopped" test "$(s3n 'stopped session G01')" = 0
s3chk "S03-AC-4: (G01) it ran once more, not again" s3eq "$(s3runs G01)" 3

# ---- U01-AC-8: the rendered follow-up prompt ----
u01_prompt_checks followup "$st6/node/G01/unattended.md"
u01_pr_checks followup "$st6/node/G01/unattended.md"

kill "$lp6"; wait "$lp6" 2>/dev/null
s3_cleanup
[ "$fails" -eq "$fails0" ] || s3dumplog

loop_end
