#!/bin/bash
# S12-AC-4, S12-AC-5: an end-to-end loop run (fixture: testdata/lib/loop-g03.sh, with ~/.config/noodlebot/units, a fake
# systemd-run and a fake systemctl that reports oom-kill for the units whose session killed itself) in which sessions of the
# loop are killed with SIGKILL while their unit reports oom-kill (SCHED_MEMORY_MAX=3G, the ceiling the checks look for):
#   node X03 (twice: the second end writes FAILED; its next start is a resume), a triage of issue 46 and a feedback session of
#   X01's PR 11 (their end lines), node X04 (held by a FAILED file until X03's first end: it then starts), report.py with the
#   fake forge of testdata/lib/report-units.sh (one milestone on X03's home issue 47, none on a later run). A second loop whose
#   HOME has no units file runs a node: no unit (no session.unit, no systemd-run call).
# Scratch paths are under $tmp/S12 (records of the fakes), $tmp/data12b (the second loop).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g03.sh"
fakegh_lib=$src/testdata/lib
. "$fakegh_lib/report-fakegh.sh"
pyc_setup
. "$fakegh_lib/report-units.sh"

unset SCHED_UNITS SCHED_OOM_ADJ SCHED_MEMINFO TMPDIR
S12=$tmp/S12 S12_LOG=$tmp/S12/log S12_STATE=$state S12_BASE_CLAUDE=$tmp/bin6/claude
export S12 S12_LOG S12_STATE S12_BASE_CLAUDE
export SCHED_MEMORY_MAX=3G SCHED_SWAP_MAX=1G SCHED_THROTTLE=0
mkdir -p "$S12/log" "$S12/oom" "$tmp/bin12"
cp "$src/testdata/s12/systemd-run.sh" "$tmp/bin12/systemd-run"
cp "$src/testdata/s12/loop-claude.sh" "$tmp/bin12/claude"
# the units' systemctl: next to the s12 fake it wraps
mkdir -p "$tmp/fk12" && cp "$src/testdata/s12/systemctl.sh" "$src/testdata/s12/loop-systemctl.sh" "$tmp/fk12/"
cp "$tmp/fk12/loop-systemctl.sh" "$tmp/bin12/systemctl"
sed -i "s|\"\$(dirname \"\$0\")/systemctl.sh\"|$tmp/fk12/systemctl.sh|" "$tmp/bin12/systemctl"
chmod +x "$tmp/bin12"/*
touch "$HOME/.config/noodlebot/units"

# the nodes X03 and X04 are on main; X04 is held by a FAILED file until X03's first end (deleting it makes the node ready)
printf "${g01base}  - {id: X03, name: oom, deps: []}\n  - {id: X04, name: other, deps: []}\n" >"$tmp/work6/docs/graph.yaml"
printf 'out/\n' >"$tmp/work6/.gitignore"   # X03's out/node/X03/brief.md makes its next start a resume, and survives the reset
g6 add -A && g6 commit -q -m 'add X03' && g6 push -q "$tmp/remote6.git" main
# X03's two runs hold until the checks have what they need; the issue to triage; the report's home issue of X03
mkdir -p "$state/node/X04" && echo held >"$state/node/X04/FAILED"
touch "$S12/hold.node.X03.1" "$S12/hold.node.X03.2"
echo '[{"number": 46}]' >"$GD/issues.json"
mkspec X03 oom '#47'
git -C "$uclone" add nodes && git -C "$uclone" -c user.name=t -c user.email=t@t commit -q -m x03 && git -C "$uclone" update-ref refs/remotes/origin/main HEAD
# node X05: ready from the moment X03's first session ends, not before: it is held by a FAILED file that the fake systemctl of
# the units removes when it reports on X03's first unit (the end of the session, before the loop sees it); it then holds
printf "${g01base}  - {id: X03, name: oom, deps: []}\n  - {id: X04, name: other, deps: []}\n  - {id: X05, name: third, deps: []}\n" >"$tmp/work6/docs/graph.yaml"
g6 add -A && g6 commit -q -m 'add X05' && g6 push -q "$tmp/remote6.git" main
mkdir -p "$state/node/X05" && echo held >"$state/node/X05/FAILED"
touch "$GD/hold.other.X05"
mv "$tmp/bin12/systemctl" "$tmp/fk12/systemctl.orig"
cat >"$tmp/bin12/systemctl" <<EOF
#!/bin/sh
case " \$* " in
*" show "*)
	for a in "\$@"; do u=\$a; done
	case \$u in *X03*) [ ! -e "$state/node/X05/FAILED" ] || { date +%s%N >"$S12/x05.ready"; rm -f "$state/node/X05/FAILED"; } ;; esac ;;
esac
exec sh "$tmp/fk12/systemctl.orig" "\$@"
EOF
chmod +x "$tmp/bin12/systemctl"
urun12() { env PATH="$ubin:$PATH" python3 -I "$src/report.py" --repo owner/repo --state "$state" --worktrees "$tmp/worktrees/repo" --clone "$uclone" --owner owner 2>"$tmp/uerr"; }

# a second loop, in its own data folder with a HOME that has no units file: a node session of it gets no unit
nbb=$tmp/nb12b dtb=$tmp/data12b homeb=$tmp/home12b
mkdir -p "$nbb/scheduler" "$nbb/plugin" "$dtb/repos" "$homeb/.config/noodlebot" "$tmp/bin12b" "$S12/logb"
cp -R "$tmp/nb6/scheduler/." "$nbb/scheduler/"; cp -R "$tmp/nb6/plugin/." "$nbb/plugin/" 2>/dev/null
cp "$HOME/.config/noodlebot/token" "$HOME/.config/noodlebot/oauth-token" "$homeb/.config/noodlebot/"
git init -q -b main "$tmp/workb"; mkdir -p "$tmp/workb/docs"
printf 'nodes:\n  - {id: Z01, name: zed, deps: []}\n' >"$tmp/workb/docs/graph.yaml"
git -C "$tmp/workb" add -A && git -C "$tmp/workb" -c user.name=t -c user.email=t@t commit -q -m init
git clone -q --bare "$tmp/workb" "$tmp/remoteb.git"
git clone -q "$tmp/remoteb.git" "$dtb/repos/nounits"
cp "$src/testdata/s12/systemd-run.sh" "$tmp/bin12b/systemd-run"; cp "$tmp/bin12/systemctl" "$tmp/bin12b/systemctl"
printf '#!/bin/sh\ncase " $* " in *"/issues?labels=noodlebot"*) echo "[]" ;; esac\nexit 0\n' >"$tmp/bin12b/gh"
printf '#!/bin/sh\necho "Q1: x" >"%s/state/nounits/node/Z01/QUESTION.md"\nexit 0\n' "$dtb" >"$tmp/bin12b/claude"
chmod +x "$tmp/bin12b"/*

loop12() {
	NOODLEBOT_DATA=$data6 PATH=$tmp/bin12:$tmp/bin6:$PATH SCHED_REPORT=0 SCHED_TICK=1 SCHED_POLL=0.2 \
		fixture_start bash "$tmp/nb6/scheduler/loop.sh" o/up >>"$tmp/g01-loop.out" 2>&1 &
	pids+=("$!"); lp6=$!
}
loop12b() {
	HOME=$homeb NOODLEBOT_DATA=$dtb S12_LOG=$S12/logb PATH=$tmp/bin12b:$PATH SCHED_REPORT=0 SCHED_TICK=1 SCHED_POLL=0.2 \
		fixture_start bash "$nbb/scheduler/loop.sh" o/nounits >>"$tmp/loop12b.out" 2>&1 &
	pids+=("$!"); lpb=$!
}
r12() { [ "$(cat "$S12/runs.$1" 2>/dev/null || echo 0)" -ge "$2" ]; }
# line12 <regex>: the status.log lines of the loop that match
line12() { grep -E "$1" "$state/status.log" 2>/dev/null; }
count12() { line12 "$1" | wc -l; }
# oomline <regex>: one line matches the regex and names out of memory and the ceiling
oomline12() { [ "$(count12 "$1")" = 1 ] && line12 "$1" | grep -qi 'out of memory' && line12 "$1" | grep -qF 3G; }
# oomfirst <regex>: the first status.log line that matches names out of memory and the ceiling (a later end of the same unit may follow)
oomfirst12() { local l; l=$(line12 "$1" | head -n1); [ -n "$l" ] && grep -qi 'out of memory' <<<"$l" && grep -qF 3G <<<"$l"; }
loop_alive() { kill -0 "$lp6" 2>/dev/null; }

rl6 0.01 $(($(date +%s) + 7200))
loop12
loop12b
ok "S12-AC-4 setup: X03 starts (its first run holds)" wait_until 25 r12 node.X03 1
ok "S12-AC-4 setup: the loop handed the units on to run-session.sh: systemd-run was called for it" grep -q 'systemd-run .*--scope' "$S12/log/sd.log"
ok "S12-AC-4 setup: the second loop (no units file) ran its node" wait_until 20 test -e "$dtb/state/nounits/node/Z01/QUESTION.md"
ok "S12-AC-4 setup: the feedback record is made" g03_first
fbadd 11 conversation 121 'please rename the helper'
urun12   # the report's first run: what is in the state now was seen; the ends below are new
rm -f "$S12/hold.node.X03.1"
ok "S12-AC-4: X03's session killed with SIGKILL while its unit reports oom-kill: its end is logged" wait_until 25 sh -c "grep -qE 'session X03 ended' '$state/status.log'"
ok "S12-AC-4: the loop is still running" loop_alive
ok "S12-AC-4: its one status.log end line names out of memory and the ceiling" oomline12 'session X03 ended'
ok "S12-AC-4: the end counts as for any other end without a PR or question: it may start again, FAILED is not written yet" sh -c "[ ! -e '$state/node/X03/FAILED' ] && grep -E 'session X03 ended' '$state/status.log' | grep -q 'may start again'"
ok "S12-AC-4: the node starts again (a resume)" wait_until 25 r12 node.X03 2
ok "S12-AC-4: the resume prompt's 'The last session ended:' line names the out-of-memory kill and the ceiling" sh -c "grep 'The last session ended:' '$S12/sys.node.X03.2' | grep -qi 'out of memory' && grep 'The last session ended:' '$S12/sys.node.X03.2' | grep -qF 3G"
ok "S12-AC-4: its stopped file is one line naming out of memory and the ceiling" sh -c "[ \"\$(wc -l <'$state/node/X03/stopped')\" = 1 ] && grep -qi 'out of memory' '$state/node/X03/stopped' && grep -qF 3G '$state/node/X03/stopped'"
# another ready unit: X04 becomes ready now (its FAILED file is deleted) and must start within the loop's next tick or the one after
rm -f "$state/node/X04/FAILED"
wait_ticks 2
ok "S12-AC-4: another ready unit of the loop (X04) starts in the same or the next tick" test "$(count12 'started X04 ')" = 1
ok "S12-AC-4: the loop is still running after it" loop_alive
# X05 became ready at the end of X03's out-of-memory session (x05.ready, when run-session.sh read the unit's result): it starts
# in the same or the next tick, counted from the end line of X03's first session (log lines are to the second)
ok "S12-AC-4: a unit that became ready when the out-of-memory session ended (X05) starts" wait_until 10 sh -c "grep -q 'started X05 ' '$state/status.log'"
ok "S12-AC-4: X05 became ready at that end (the fake systemctl saw X03's unit)" test -s "$S12/x05.ready"
e12=$(line12 'session X03 ended' | head -n1); x12=$(line12 'started X05 ' | head -n1)
ok "S12-AC-4: X05's started line is within 2 ticks (SCHED_TICK=1) of X03's out-of-memory end line (${e12%% *} .. ${x12%% *})" sh -c "[ -n '$e12' ] && [ -n '$x12' ] && [ \$((\$(date -u -d '${x12%% *}' +%s) - \$(date -u -d '${e12%% *}' +%s))) -le 2 ]"
ok "S12-AC-4: the triage session killed the same way: its end line names out of memory and the ceiling" wait_until 8 oomfirst12 'triage of #46 ended'
ok "S12-AC-4: the feedback session killed the same way: its end line names out of memory and the ceiling" wait_until 8 oomfirst12 'feedback session of X01 ended'
# S12-AC-5: report.py (fake forge); X03's second run still holds, so the only end since the first report is the first one
urun12; urun12; urun12
ok "S12-AC-5: report.py posted one milestone on X03's home issue (47) naming the out-of-memory kill, over three runs" test "$(ucount 47 '(?i)out of memory')" = 1
ok "S12-AC-5: it names the ceiling" test "$(ucount 47 '(?is)(out of memory.*3G|3G.*out of memory)')" = 1
urun12
ok "S12-AC-5: a later run posts none" test "$(ucount 47 '(?i)out of memory')" = 1
rm -f "$S12/hold.node.X03.2"
ok "S12-AC-4: a second such end writes FAILED" wait_until 25 test -e "$state/node/X03/FAILED"
ok "S12-AC-4: the two ends of X03 are two end lines, both naming out of memory and the ceiling" sh -c "[ \"\$(grep -cE 'session X03 ended' '$state/status.log')\" = 2 ] && [ \"\$(grep -E 'session X03 ended' '$state/status.log' | grep -i 'out of memory' | grep -cF 3G)\" = 2 ]"
ok "S12-AC-4: the second end line says FAILED" sh -c "grep -E 'session X03 ended' '$state/status.log' | tail -n1 | grep -q 'wrote FAILED'"
wait_ticks 1
ok "S12-AC-4: X03 is held, not started a third time" test "$(cat "$S12/runs.node.X03")" = 2
ok "S12-AC-4: the loop is still running at the end" loop_alive
ok "S12-AC-1 (loop): the settings reached run-session.sh: X03's session.unit holds the unit, oom-kill and the ceiling" grep -Eq ' oom-kill 3G$' "$state/node/X03/session.unit"
ok "S12-AC-3 (loop): a loop whose HOME has no units file runs its node without a unit (no session.unit, no systemd-run call)" sh -c "[ -f '$dtb/state/nounits/node/Z01/session.rc' ] && [ ! -e '$dtb/state/nounits/node/Z01/session.unit' ] && [ ! -e '$S12/logb/sd.log' ]"

touch "$HOME/STOP-up" "$homeb/STOP-nounits"
wait_until 8 g01_gone "$lp6"; wait_until 8 g01_gone "$lpb"
for f in "$state"/node/*/session.pid "$state"/pr/*/session.pid "$state"/issue/*/session.pid "$dtb"/state/nounits/node/*/session.pid; do [ -e "$f" ] && kill -KILL -- "-$(cat "$f")" 2>/dev/null; done
loop_end
