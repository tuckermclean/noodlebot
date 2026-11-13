#!/bin/bash
# G05: spec PRs closed without merging release their node; a spec PR that changes more than the spec files is sent back.
# Part of the end-to-end test of scheduler/loop.sh. Three loops, each over its own remote (origin) with spec branches:
#   sf  nodes G01..G04, AGENTS.md has a **Spec files:** line. G01 waits on PR 101 (spec/g01: a node spec and a test file),
#       G02 on PR 102 (spec/g02: SPEC.md and a node spec only), G03 on PR 103 (closed without merging), G04 on PR 104 (merged).
#       The fake claude of G01 writes WAITING-PR 101 again at the same head; those of G03 and G04 write a QUESTION.md.
#   nl  AGENTS.md has no **Spec files:** line; G01 waits on PR 101 (spec/g01, out of scope by the default list).
#   cp  SCHED_MAX=1: G01 is a running session that holds the slot, G02 waits on PR 102 (out of scope), flagged but not started.
# The fake gh answers the PR lists from $G05D/{open,merged,closed}.tsv (open: "<number> <branch>", the head is read from the remote).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
unset USAGE_7D_MARGIN
G05=$tmp/g05 G05D=''; export G05
mkdir -p "$G05" "$tmp/bin5"
cat >"$tmp/bin5/gh" <<'EOF'
#!/bin/sh
case " $* " in
*" --state merged "*) echo >>"$G05D/polls"; cat "$G05D/merged.tsv" ;;
*" --state open "*) while read -r n b; do [ -n "$n" ] && echo "$n $b $(git --git-dir="$G05D/remote.git" rev-parse "$b") true MERGEABLE"; done <"$G05D/open.tsv" ;;
*" --state closed "*) cat "$G05D/closed.tsv" ;;
*"/issues?labels=noodlebot"*) echo '[]' ;;
esac
exit 0
EOF
cat >"$tmp/bin5/claude" <<'EOF'
#!/bin/sh
id=${2##* }; d=$G05D
n=$(( $(cat "$d/runs.$id" 2>/dev/null || echo 0) + 1 )); echo $n >"$d/runs.$id"
prev=; for a in "$@"; do [ "$prev" = --append-system-prompt ] && printf '%s\n' "$a" >"$d/sys.$id.$n"; prev=$a; done
sd=$G05D_STATE/node/$id
case $G05D_MODE.$id in
*.G01) [ "$G05D_MODE" = cp ] && { while [ -e "$d/hold.G01" ]; do sleep 0.2; done; echo "Q1: x" >"$sd/QUESTION.md"; exit 0; }
	cat "$sd"/answered/*-SPEC-PR-SCOPE >"$d/answered.$id.$n" 2>/dev/null
	echo 101 >"$sd/WAITING-PR" ;;
*.G03|*.G04|*.G02) echo "Q1: x" >"$sd/QUESTION.md" ;;
esac
exit 0
EOF
chmod +x "$tmp/bin5/gh" "$tmp/bin5/claude"

# mkrepo <name> <spec-files line or none> <nodes...>: remote, clone and state for the loop o/<name>.
mkrepo() {
	local r=$1 line=$2 w=$tmp/g05-work-$1 i; shift 2
	mkdir -p "$G05/$r" "$w/docs" "$w/nodes" "$w/scheduler" "$NOODLEBOT_DATA/repos" "$NOODLEBOT_DATA/state/$r/node"
	git init -q -b main "$w"
	{ echo nodes:; for i in "$@"; do echo "  - {id: $i, name: n${i#G}, deps: []}"; done; } >"$w/docs/graph.yaml"
	{ echo '# AGENTS'; echo; echo '## Building a node'; echo; [ "$line" = none ] || echo "- **Spec files:** $line"; } >"$w/AGENTS.md"
	echo spec >"$w/SPEC.md"; echo n01 >"$w/nodes/G01-n01.md"; echo t >"$w/scheduler/x.test.sh"
	git -C "$w" add -A && git -C "$w" -c user.name=t -c user.email=t@t commit -q -m init
	git clone -q --bare "$w" "$G05/$r/remote.git"
	git clone -q "$G05/$r/remote.git" "$NOODLEBOT_DATA/repos/$r"
	: >"$G05/$r/open.tsv"; : >"$G05/$r/merged.tsv"; : >"$G05/$r/closed.tsv"; : >"$G05/$r/polls"
}
# specbranch <repo> <branch> <file>...: a branch off main that changes those files.
specbranch() {
	local r=$1 b=$2 w=$tmp/g05-work-$1 f; shift 2
	git -C "$w" checkout -q -b "$b" main
	for f in "$@"; do mkdir -p "$w/$(dirname "$f")"; echo "$b $RANDOM" >"$w/$f"; done
	git -C "$w" add -A && git -C "$w" -c user.name=t -c user.email=t@t commit -q -m "$b"
	git -C "$w" push -q "$G05/$r/remote.git" "$b"; git -C "$w" checkout -q main
}
loop5() { # <repo> <mode> [SCHED_MAX]
	G05D=$G05/$1 G05D_STATE=$NOODLEBOT_DATA/state/$1 G05D_MODE=$2 PATH=$tmp/bin5:$PATH SCHED_REPORT=0 SCHED_THROTTLE=0 SCHED_TICK=1 SCHED_POLL=0.2 SCHED_MAX=${3:-0} \
		bash "$nb/scheduler/loop.sh" "o/$1" >>"$tmp/g05-$1-loop.out" 2>&1 &
	pids+=("$!")
}
cp_scheduler "$nb/scheduler"
[ -f "$src/harness.py" ] && { mkdir -p "$nb/scheduler/harnesses"; cp "$src"/harnesses/*.py "$nb/scheduler/harnesses/"; }
mkdir -p "$nb/plugin/skills/node"; cp "$src/../plugin/skills/node/check-spec-diff.py" "$nb/plugin/skills/node/"

sl() { echo "$NOODLEBOT_DATA/state/$1/status.log"; }
st() { echo "$NOODLEBOT_DATA/state/$1/node/$2"; }
runs() { cat "$G05/$1/runs.$2" 2>/dev/null || echo 0; }
nlog() { local n; n=$(grep -cE "$2" "$(sl "$1")" 2>/dev/null); echo "${n:-0}"; }
lg() { [ "$(nlog "$1" "$2")" = "$3" ]; }
nruns() { [ "$(runs "$1" "$2")" = "$3" ]; }
pollsn() { polls "$G05/$1/polls"; }
ticks() { wait_polls "$G05/$1/polls" "$(pollsn "$1")" "$2"; }
scopefile() { ls "$(st "$1" "$2")"/answered/*-SPEC-PR-SCOPE 2>/dev/null | head -n1; }
nscope() { ls "$(st "$1" "$2")"/answered/*-SPEC-PR-SCOPE 2>/dev/null | wc -l; }
has() { grep -qE "$2" "$(sl "$1")" 2>/dev/null; }
failed() { [ -s "$(st "$1" "$2")/FAILED" ]; }
dead=0
dump() { echo "      status.log of $1 (tail):"; tail -n 12 "$(sl "$1")" 2>/dev/null | sed 's/^/      /'; }
# chk <repo> <name> <command...>: PASS when the command succeeds now.
chk() { local r=$1 name=$2; shift 2; if "$@"; then pass "$name"; else fail "$name"; dump "$r"; fi; }
# okw <repo> <name> <seconds> <command...>: PASS when the command succeeds within three times that time (a loaded machine needs
# more; a wait that succeeds costs nothing). After the first failed wait every later wait is 1 s, so a run against a missing
# feature ends quickly.
okw() { local r=$1 name=$2 t=$3; shift 3; if [ "$dead" = 1 ]; then t=1; else t=$((t * 3)); fi
	if waitf "$t" "$@"; then pass "$name"; else fail "$name"; dump "$r"; dead=1; fi; }
# since <repo> <n>: n ticks more than now (the fake gh counts one merged-PR poll a tick).
mark() { polls "$G05/$1/polls"; }
atleast() { wait_polls "$G05/$1/polls" "$2" "$3"; }

# ---- the three repositories and loops, started together ----
mkrepo sf '`SPEC.md`, `docs/graph.yaml`, `nodes/`' G01 G02 G03 G04
specbranch sf spec/g01 nodes/G01-n01.md scheduler/x.test.sh
specbranch sf spec/g02 SPEC.md nodes/G02-n02.md
specbranch sf spec/g03 SPEC.md
specbranch sf spec/g04 SPEC.md
printf '101 spec/g01\n102 spec/g02\n' >"$G05/sf/open.tsv"
printf '104 spec/g04\n' >"$G05/sf/merged.tsv"
printf '103 spec/g03 2026-01-01T00:00:00Z false\n104 spec/g04 2026-01-01T00:00:00Z true\n' >"$G05/sf/closed.tsv"
for i in 1 2 3 4; do mkdir -p "$(st sf G0$i)"; echo "10$i" >"$(st sf G0$i)/WAITING-PR"; done
mkrepo nl none G01
specbranch nl spec/g01 nodes/G01-n01.md scheduler/x.test.sh
printf '101 spec/g01\n' >"$G05/nl/open.tsv"; mkdir -p "$(st nl G01)"; echo 101 >"$(st nl G01)/WAITING-PR"
mkrepo cp '`SPEC.md`, `docs/graph.yaml`, `nodes/`' G01 G02
specbranch cp spec/g02 nodes/G02-n02.md scheduler/x.test.sh
printf '102 spec/g02\n' >"$G05/cp/open.tsv"; mkdir -p "$(st cp G02)"; echo 102 >"$(st cp G02)/WAITING-PR"
touch "$G05/cp/hold.G01"
loop5 sf sf; loop5 nl nl; loop5 cp cp 1

# ---- sf: the Spec files line is on origin/main ----
okw sf "G05-AC-6: a node waiting on an open spec PR whose branch changes a test file is started" 6 nruns sf G01 1
okw sf "G05-AC-6: its state has answered/<ts>-SPEC-PR-SCOPE" 3 test -n "$(scopefile sf G01)"
sf_s=$(scopefile sf G01)
head1=$(git --git-dir="$G05/sf/remote.git" rev-parse spec/g01)
chk sf "G05-AC-6: SPEC-PR-SCOPE names the PR (pr 101)" grep -qxF 'pr 101' "${sf_s:-/dev/null}"
chk sf "G05-AC-6: SPEC-PR-SCOPE names the branch (branch spec/g01)" grep -qxF 'branch spec/g01' "${sf_s:-/dev/null}"
chk sf "G05-AC-6: SPEC-PR-SCOPE names the head commit (head <sha>)" grep -qxF "head $head1" "${sf_s:-/dev/null}"
chk sf "G05-AC-6: SPEC-PR-SCOPE has the path line for the test file" grep -qxF 'path scheduler/x.test.sh' "${sf_s:-/dev/null}"
chk sf "G05-AC-6: and no path line for a spec file" sh -c "[ -n '$sf_s' ] && ! grep -E '^path (SPEC.md|nodes/)' '$sf_s'"
okw sf "G05-AC-6: the node's session saw that answer (its answered/ entry holds pr 101)" 3 grep -qxF 'pr 101' "$G05/sf/answered.G01.1"
okw sf "G05-AC-6: one status-log line names the PR #101 and the path" 3 lg sf 'spec PR #101 .*scheduler/x.test.sh' 1
okw sf "G05-AC-6: the node wrote WAITING-PR again at the same head: FAILED" 8 failed sf G01
chk sf "G05-AC-6: FAILED names PR #101" grep -qE '#101([^0-9]|$)' "$(st sf G01)/FAILED"
chk sf "G05-AC-6: FAILED names the path" grep -qF 'scheduler/x.test.sh' "$(st sf G01)/FAILED"
okw sf "G05-AC-5: a node whose spec PR was closed without merging is started" 8 nruns sf G03 1
okw sf "G05-AC-5: its state has answered/<ts>-SPEC-PR-CLOSED naming PR 103" 3 grep -qxF 103 "$(ls "$(st sf G03)"/answered/*-SPEC-PR-CLOSED 2>/dev/null | head -n1 || echo /dev/null)"
okw sf "G05-AC-5: the loop's log says 'spec PR #103 closed without merging'" 3 has sf 'spec PR #103 closed without merging'
okw sf "G05-AC-5: a merged WAITING-PR still releases as before (answered/<ts>-SPEC-PR)" 5 sh -c "[ \"\$(cat '$(st sf G04)'/answered/*-SPEC-PR 2>/dev/null)\" = 104 ]"
okw sf "G05-AC-5: ... and the log says 'spec PR #104 merged'" 3 has sf 'spec PR #104 merged'
atleast sf "$(mark sf)" 2
chk sf "G05-AC-6: a spec PR that changes only spec files starts nothing (G02 never ran)" nruns sf G02 0
chk sf "G05-AC-6: ... it is not flagged (no SPEC-PR-SCOPE) and its WAITING-PR stays" sh -c "[ -z '$(scopefile sf G02)' ] && [ ! -e '$(st sf G02)/SPEC-PR-SCOPE' ] && [ -e '$(st sf G02)/WAITING-PR' ]"
chk sf "G05-AC-6: ... and nothing in the log names PR #102" lg sf '#102([^0-9]|$)' 0
chk sf "G05-AC-6: no further start of G01 after FAILED" nruns sf G01 1
chk sf "G05-AC-5: the closed-PR node started once only" nruns sf G03 1
chk sf "G05-AC-6: one status-log event names PR #101 and the paths over the whole run" lg sf 'spec PR #101 changes files outside' 1
chk sf "G05-AC-6: the node has the one SPEC-PR-SCOPE entry only" test "$(nscope sf G01)" = 1
touch "$HOME/STOP-sf"

# ---- nl: AGENTS.md has no Spec files line ----
atleast nl 0 3
chk nl "G05-AC-6: no Spec files line on origin/main: nothing started" nruns nl G01 0
chk nl "G05-AC-6: ... nothing flagged (no SPEC-PR-SCOPE)" sh -c "[ -z '$(scopefile nl G01)' ] && [ ! -e '$(st nl G01)/SPEC-PR-SCOPE' ]"
okw nl "G05-AC-6: ... one log line for the head, over at least three ticks, naming the PR and the path" 3 lg nl '#101 .*scheduler/x.test.sh' 1
specbranch nl spec/g01b nodes/G01-n01.md scheduler/x.test.sh
git --git-dir="$G05/nl/remote.git" update-ref refs/heads/spec/g01 "$(git --git-dir="$G05/nl/remote.git" rev-parse spec/g01b)"
nl_m=$(mark nl)

# ---- cp: the slot is taken, so the flagged node is not started yet ----
okw cp "G05-AC-6: (setup) the slot is taken by G01's session" 10 nruns cp G01 1
cp_m=$(mark cp)
:
okw cp "G05-AC-6: a flagged node the cap holds back is flagged (SPEC-PR-SCOPE next to WAITING-PR)" 5 test -e "$(st cp G02)/SPEC-PR-SCOPE"
cksum_a=$(cksum <"$(st cp G02)/SPEC-PR-SCOPE" 2>/dev/null)
atleast cp "$(mark cp)" 2
chk cp "G05-AC-6: the flagged head unchanged on later ticks: SPEC-PR-SCOPE is the same, no second flag" test -n "$cksum_a" -a "$(cksum <"$(st cp G02)/SPEC-PR-SCOPE" 2>/dev/null)" = "$cksum_a"
chk cp "G05-AC-6: ... and no start while the slot is taken" nruns cp G02 0
rm -f "$G05/cp/hold.G01"

# ---- nl again: the new head ----
okw nl "G05-AC-6: a new head commit gives one more line" 10 lg nl '#101 .*scheduler/x.test.sh' 2
atleast nl "$(mark nl)" 2
chk nl "G05-AC-6: ... and no more while that head stays" lg nl '#101 .*scheduler/x.test.sh' 2
chk nl "G05-AC-6: ... still nothing started" nruns nl G01 0
touch "$HOME/STOP-nl"

# ---- cp again: the slot is free ----
okw cp "G05-AC-6: when the slot is free the flagged node starts" 10 nruns cp G02 1
atleast cp "$(mark cp)" 2
chk cp "G05-AC-6: ... once only" nruns cp G02 1
chk cp "G05-AC-6: ... with one answered/<ts>-SPEC-PR-SCOPE" test "$(nscope cp G02)" = 1
chk cp "G05-AC-6: ... and one status-log event naming PR #102 and the path" lg cp 'spec PR #102 .*scheduler/x.test.sh' 1
touch "$HOME/STOP-cp"
for f in "$NOODLEBOT_DATA"/state/*/node/*/session.pid; do [ -e "$f" ] && kill -KILL -- "-$(cat "$f")" 2>/dev/null; done
loop_end
