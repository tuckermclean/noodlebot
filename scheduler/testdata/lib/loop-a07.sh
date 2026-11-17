# Shared by loop-a07-*.test.sh (source after loop-prelude.sh): the fixture of the A07 (adopt loop) runs. It builds on the
# G04 fixture (testdata/lib/loop-g04.sh: the fake forge `fake:<path>`, the loop's runtime root $g04data, g04_run, g04_stop)
# and copies every file of the scheduler (also those a later node adds) into the scratch checkout, so unattended-adopt.md
# is there once the node has written it (a07_no_template removes it: a checkout without it).
#   a07_fork <name>            a fake forge $G04/fk/<name> whose main has no graph (the remote's own graph is removed)
#   a07_main <name> <kind>     commit the graph of <kind> on the fake forge's main: none (no docs/graph.yaml), two (adoption
#                              with the areas one and two), one (only the area two left), plan (adoption, no area), done
#                              (no adoption), x (areas "wrap"); every graph has nodes: [] (nothing but adoption starts)
#   a07_run <name> [env...]    start the loop on fake:<fk> with SCHED_TICK=${A07_TICK:-1}, the fake claude on PATH
#   a07_pr <name> <n> <head>   a bot's open PR n on <head> in the fake forge; a07_merge / a07_close <name> <n>
#   a07_issue <name> <n>       an open issue n the owner labelled noodlebot (events: labelled by the owner acme)
#   a07_break_fetch <name> / a07_fix_fetch <name>   the loop's clone cannot / can fetch origin (a failed fetch)
# The fake claude ($G04/bin/claude) logs "<key> run <n> <prompt> | <pwd> | <branch>" to $A07/claude.log and the rendered
# prompt to $A07/sys.<key>.<n>; key is scaffold (/noodlebot:adopt <repo>), the area (--area <name>), plan (--plan) or
# triage.<N> (/noodlebot:triage <N>), other for any other prompt. It holds while $A07/hold.<key> exists, writes the unit's
# QUESTION.md when $A07/question.<key>.<n> exists, else (an adoption key) opens the unit's PR (the number in $A07/pr.<key>,
# default scaffold 21, one 22, two 23, plan 24; head spec/adopt, spec/adopt-<key>) and writes WAITING-PR; exit 0.
# Assumed names (the spec leaves them open): the unit's state folder is $st/adopt/<key>, its worktree
# $g04data/worktrees/<name>/adopt-<key>, its branch spec/adopt (scaffold) or spec/adopt-<key>.
A07=$tmp/A07
mkdir -p "$A07"
. "$src/testdata/lib/loop-g04.sh"
cp_scheduler "$G04/nb/scheduler"
export A07_DIR=$A07
cat >"$G04/bin/claude" <<'EOF2'
#!/bin/sh
p=$2
case "$p" in
"/noodlebot:adopt --area "*) k=${p#/noodlebot:adopt --area }; k=${k%% *}; ad=1 ;;
"/noodlebot:adopt --plan"*) k=plan ad=1 ;;
"/noodlebot:adopt --update "*|"/noodlebot:adopt --feedback "*) k=pr.${p##* } ad= ;;
"/noodlebot:adopt "*) k=scaffold ad=1 ;;
"/noodlebot:triage --"*) k=other ad= ;;
"/noodlebot:triage "*) k=triage.${p##* } ad= ;;
*) k=other ad= ;;
esac
n=$(( $(cat "$A07_DIR/runs.$k" 2>/dev/null || echo 0) + 1 ))
while [ $# -gt 0 ]; do
	[ "$1" = --append-system-prompt ] && { printf '%s\n' "$2" >"$A07_DIR/sys.$k.$n"; break; }
	shift
done
echo "$k run $n $p | $(pwd -P) | $(git branch --show-current 2>/dev/null)" >>"$A07_DIR/claude.log"
echo $n >"$A07_DIR/runs.$k"
while [ -e "$A07_DIR/hold.$k" ]; do sleep 0.2; done
[ -n "$ad" ] || exit 0
d=$A07_STATE/adopt/$k
if [ -e "$A07_DIR/question.$k.$n" ]; then echo "Q1: which one? Recommendation: a." >"$d/QUESTION.md"; exit 0; fi
case $k in scaffold) head=spec/adopt ;; *) head=spec/adopt-$k ;; esac
num=$(cat "$A07_DIR/pr.$k" 2>/dev/null || case $k in scaffold) echo 21 ;; one) echo 22 ;; two) echo 23 ;; *) echo 24 ;; esac)
python3 "$A07_DIR/forge.py" pr "$A07_FK" "$num" "$head"
echo "$num" >"$d/WAITING-PR"
exit 0
EOF2
chmod +x "$G04/bin/claude"
cat >"$A07/forge.py" <<'EOF2'
import json, os, sys
a = sys.argv[1:]
cmd, fk = a[0], a[1]
def load(n):
    try:
        return json.load(open(os.path.join(fk, n + ".json")))
    except OSError:
        return [] if n in ("prs", "issues") else {}
def save(n, d):
    p = os.path.join(fk, n + ".json")
    json.dump(d, open(p + ".tmp", "w")); os.replace(p + ".tmp", p)
if cmd == "pr":
    num, head = int(a[2]), a[3]
    prs = [p for p in load("prs") if p["number"] != num]
    prs.append({"number": num, "title": head, "body": "", "state": "open", "head": head, "head_sha": "a" * 40, "base": "main",
                "author": {"login": "noodlebot[bot]", "is_bot": True, "is_owner": False}, "mergeable": "UNKNOWN",
                "created_at": "2026-06-01T12:00:00Z", "merged_at": None, "closed_at": None})
    save("prs", prs)
elif cmd in ("merge", "close"):
    prs = load("prs")
    for p in prs:
        if p["number"] == int(a[2]):
            p.update(state="merged" if cmd == "merge" else "closed", closed_at="2026-06-01T13:00:00Z",
                     merged_at="2026-06-01T13:00:00Z" if cmd == "merge" else None)
    save("prs", prs)
elif cmd == "issue":
    num = int(a[2])
    iss = load("issues")
    iss.append({"number": num, "title": "issue %d" % num, "body": "x", "state": "open", "labels": ["noodlebot"], "is_pr": False,
                "author": {"login": "acme", "is_bot": False, "is_owner": True}, "created_at": "2026-06-01T10:00:00Z"})
    save("issues", iss)
    ev = load("events")
    ev[str(num)] = [{"event": "labeled", "label": "noodlebot", "actor": "acme", "created_at": "2026-06-01T10:01:00Z"}]
    save("events", ev)
EOF2
# the real issues.py, behind a recorder: $A07/issues.called gets one line per call (the loop asks issues.py once a tick)
mv "$G04/nb/scheduler/issues.py" "$G04/nb/scheduler/issues-real.py"
cat >"$G04/nb/scheduler/issues.py" <<'EOF2'
import os, runpy, sys
open(os.path.join(os.environ["A07_DIR"], "issues.called"), "a").write(" ".join(sys.argv[1:]) + "\n")
sys.argv[0] = os.path.join(os.path.dirname(os.path.realpath(__file__)), "issues-real.py")
runpy.run_path(sys.argv[0], run_name="__main__")
EOF2
a07_fork() {
	g04_fake "$1"
	a07_main "$1" none
}
a07_graph() {
	local head='apiVersion: themonolith/v1\nkind: DependencyGraph\ngate: {command: make test, fail_pattern: "^FAIL", known_red: []}\n'
	case $1 in
	two) printf "${head}adoption:\n  areas:\n    - {name: one, globs: [\"src/one/\"]}\n    - {name: two, globs: [\"src/two/\"]}\nnodes: []\n" ;;
	one) printf "${head}adoption:\n  areas:\n    - {name: two, globs: [\"src/two/\"]}\nnodes: []\n" ;;
	x) printf "${head}adoption:\n  areas:\n    - {name: wrap, globs: [\"bin/\", \"lib/\"]}\nnodes: []\n" ;;
	plan) printf "${head}adoption:\n  areas: []\nnodes: []\n" ;;
	done) printf "${head}nodes: []\n" ;;
	esac
}
a07_main() {
	local fk=$G04/fk/$1 w=$A07/w.$1
	rm -rf "$w"; git clone -q "$fk/repo.git" "$w" 2>/dev/null
	mkdir -p "$w/docs"
	if [ "$2" = none ]; then rm -f "$w/docs/graph.yaml"; else a07_graph "$2" >"$w/docs/graph.yaml"; fi
	git -C "$w" add -A
	git -C "$w" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "graph $2"
	git -C "$w" push -q origin HEAD:main
	rm -rf "$w"
}
a07_run() {
	local name=$1; shift
	a07_name=$name st=$g04data/state/$name
	g04_run "fake:$G04/fk/$name" "$name" A07_FK="$G04/fk/$name" A07_STATE="$g04data/state/$name" SCHED_TICK="${A07_TICK:-1}" "$@"
}
a07_pr() { python3 "$A07/forge.py" pr "$G04/fk/$1" "$2" "$3"; }
a07_merge() { python3 "$A07/forge.py" merge "$G04/fk/$1" "$2"; }
a07_close() { python3 "$A07/forge.py" close "$G04/fk/$1" "$2"; }
a07_issue() { python3 "$A07/forge.py" issue "$G04/fk/$1" "$2"; }
a07_break_fetch() { git -C "$g04data/repos/$1" remote set-url origin "$A07/nowhere.git"; }
a07_fix_fetch() { git -C "$g04data/repos/$1" remote set-url origin "$G04/fk/$1/repo.git"; }
a07_no_template() { rm -f "$G04/nb/scheduler/unattended-adopt.md"; }
# a07_runs <key>: how many starts the fake claude logged for the key; a07_runis <key> <n>.
a07_runs() { cat "$A07/runs.$1" 2>/dev/null || echo 0; }
a07_runis() { [ "$(a07_runs "$1")" = "$2" ]; }
# a07_msgs: the status log without its "<time> open=[..] merged-prs=[..]; " prefix.
a07_msgs() { sed -e 's/^[^ ]* open=\[[^]]*\] merged-prs=\[[^]]*\]; //' "$st/status.log" 2>/dev/null; }
# a07_nlines <extended regex>: how many status-log messages match (case-insensitive).
a07_nlines() { a07_msgs | grep -ciE -- "$1"; true; }
a07_ud() { echo "$st/adopt/$1"; }
a07_wt() { echo "$g04data/worktrees/$a07_name/adopt-$1"; }
# a07_idle <key>: the unit's session is over and its worktree gone (the unit wrote WAITING-PR or FAILED).
a07_waiting() { [ -s "$(a07_ud "$1")/WAITING-PR" ] && [ ! -e "$(a07_ud "$1")/session.pid" ] && [ ! -d "$(a07_wt "$1")" ]; }
a07_failed() { [ -s "$(a07_ud "$1")/FAILED" ]; }
a07_logged() { grep -qE -- "$1" "$A07/claude.log" 2>/dev/null; }
a07_cleanup() {
	local f
	for f in "$g04data"/state/*/adopt/*/session.pid "$g04data"/state/*/issue/*/session.pid; do [ -e "$f" ] && kill -KILL -- "-$(cat "$f")" 2>/dev/null; done
	rm -f "$A07"/hold.*
	return 0
}
extra_cleanup() { g04_cleanup; a07_cleanup; }
a07_stop() { rm -f "$A07"/hold.*; g04_stop; a07_cleanup; }
# Checks that stop waiting once an earlier one failed (RED: the loop does nothing, one timeout, then a FAIL line per check):
#   need <name> <seconds> <cmd...>   wait for the condition; a failure sets a07_skip, which fails every later check at once
#   chk <name> <cmd...>              the condition holds now (FAIL at once when a07_skip is set)
#   ticks <n>                        n more ticks of the loop (st) went by; fails and sets a07_skip when the loop is not ticking
a07_skip=0
need() {
	local name=$1 t=$2; shift 2
	if [ "$a07_skip" = 1 ]; then fail "$name (an earlier check failed)"; return 1; fi
	if wait_until "$t" "$@"; then pass "$name"; else fail "$name"; a07_skip=1; echo "      status.log:"; sed 's/^/      /' "$st/status.log" 2>/dev/null | tail -n 12; return 1; fi
}
chk() {
	local name=$1; shift
	if [ "$a07_skip" = 1 ]; then fail "$name (an earlier check failed)"; return 1; fi
	if "$@"; then pass "$name"; else fail "$name"; echo "      status.log:"; sed 's/^/      /' "$st/status.log" 2>/dev/null | tail -n 12; return 1; fi
}
ticks() { wait_ticks "$1" "$st"; }
# a07_nmerge <key> <pr>: status-log messages that name the unit key and PR #<pr> and say merged (the line the tick that first
# sees a merge the fetched graph does not show writes). Assumed wording: "...<key>...#<pr>...merged...".
a07_nmerge() { a07_msgs | grep -iE -- "$1" | grep -E -- "#$2([^0-9]|\$)" | grep -ciE 'merged'; true; }
a07_nmergeis() { [ "$(a07_nmerge "$1" "$2")" = "$3" ]; }
a07_ge1() { [ "$(a07_nmerge "$1" "$2")" -ge 1 ]; }
# a07_late <graph kind> <key> <pr> <label>: A07-AC-2, a unit whose PR merged after the fetch. Needs A07_TICK=2 (a tick of 2 s
# is slack enough to look between the tick that first sees the merge and the next one). The unit's session ends with
# WAITING-PR <pr>; the fetch is broken, the PR is merged in the forge (main stays as it is: the fetched graph does not show
# it), then the fetch works again.
a07_late() {
	local kind=$1 key=$2 pr=$3 label=$4 r first=0
	a07_fork a07
	a07_main a07 "$kind"
	a07_run a07
	need "A07-AC-2: $label: the unit's session ends with WAITING-PR $pr" 15 a07_waiting "$key"
	r=$(a07_runs "$key")
	a07_break_fetch a07
	ticks 3
	chk "A07-AC-2: $label: a tick whose fetch failed writes no FAILED (PR $pr not merged yet)" test ! -e "$(a07_ud "$key")/FAILED"
	a07_merge a07 "$pr"
	ticks 3
	chk "A07-AC-2: $label: the PR is merged but the fetch fails: no FAILED" test ! -e "$(a07_ud "$key")/FAILED"
	chk "A07-AC-2: $label: the fetch fails: no merge line yet (nothing is seen)" a07_nmergeis "$key" "$pr" 0
	chk "A07-AC-2: $label: the fetch fails: no second session" a07_runis "$key" "$r"
	a07_fix_fetch a07
	need "A07-AC-2: $label: the tick that first sees the merge logs a line naming the unit and PR #$pr" 20 a07_ge1 "$key" "$pr"
	chk "A07-AC-2: $label: that tick logs one line" a07_nmergeis "$key" "$pr" 1
	chk "A07-AC-2: $label: the unit is only held in that tick (no FAILED yet)" test ! -e "$(a07_ud "$key")/FAILED"
	chk "A07-AC-2: $label: no second session in that tick" a07_runis "$key" "$r"
	need "A07-AC-2: $label: a later tick whose fetch succeeded and still does not show the merge writes FAILED" 20 a07_failed "$key"
	chk "A07-AC-2: $label: FAILED names the PR (#$pr)" grep -qE "#?$pr([^0-9]|\$)" "$(a07_ud "$key")/FAILED"
	ticks 3
	chk "A07-AC-2: $label: held by FAILED: no second session" a07_runis "$key" "$r"
	chk "A07-AC-2: $label: no other adoption session ran" test "$(grep -c . "$A07/claude.log")" = "$r"
	a07_stop
}
