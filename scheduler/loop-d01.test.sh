#!/bin/bash
# D01: self-deploy (with its V01 and T03 checks). Part of the end-to-end test of scheduler/loop.sh.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"

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
[ -f "$src/harness.py" ] && { mkdir -p "$tmp/nbwork/scheduler/harnesses"; cp "$src/harness.py" "$tmp/nbwork/scheduler/"; cp "$src"/harnesses/*.py "$tmp/nbwork/scheduler/harnesses/"; }
[ -f "$src/forge.py" ] && { mkdir -p "$tmp/nbwork/scheduler/forges"; cp "$src/forge.py" "$tmp/nbwork/scheduler/"; cp "$src"/forges/*.py "$tmp/nbwork/scheduler/forges/"; }
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
wait_ticks 2
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
ok "T03-AC-5: after the re-exec the loop's environment still holds SCHED_TICK=1 it was started with" sh -c "kill -0 $loop3 && grep -qx 'v2 pid $loop3' '$tmp/marker' && tr '\\0' '\\n' <'/proc/$loop3/environ' | grep -qx 'SCHED_TICK=1'"
ok "T03-AC-5: after the re-exec the loop's environment still holds SCHED_POLL=0.2 and SCHED_REPORT=0" sh -c "kill -0 $loop3 && grep -qx 'v2 pid $loop3' '$tmp/marker' && tr '\\0' '\\n' <'/proc/$loop3/environ' | grep -qx 'SCHED_POLL=0.2' && tr '\\0' '\\n' <'/proc/$loop3/environ' | grep -qx 'SCHED_REPORT=0'"
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
wait_ticks 4
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

loop_end
