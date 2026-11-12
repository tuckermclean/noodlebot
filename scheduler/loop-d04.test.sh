#!/bin/bash
# D04: a loop given a commit that changes no runtime path moves its checkout and does not re-exec; a runtime commit
# after that re-execs it (D01). Part of the end-to-end test of scheduler/loop.sh; the fixture is that of loop-d01.test.sh.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"

# The loop's own checkout ($nbd) is a clone of a fake "noodlebot" remote; the loop runs one session (B01) that stays
# alive until $tmp/go. N1 changes only SPEC.md and docs/ (non-runtime), R2 carries a loop.sh that logs "v2 pid <pid>".
nbd=$tmp/nbd datad=$tmp/datad stated=$tmp/datad/state/dep
state=$stated   # ok prints this log on a failure
nbsrc=(loop.sh ready.py release-markers.sh run-session.sh unattended.md issues.py unattended-triage.md deploy.sh)
mkloop() { local l; while IFS= read -r l; do printf '%s\n' "$l"; [ "$l" = "set -u -o pipefail" ] && echo "echo $1 pid \$\$ >>'$tmp/marker'"; done <"$src/loop.sh"; }
git init -q -b main "$tmp/nbwork"
mkdir -p "$tmp/nbwork/scheduler" "$tmp/nbwork/plugin"
for f in "${nbsrc[@]}"; do cp "$src/$f" "$tmp/nbwork/scheduler/" 2>/dev/null; done
chmod +x "$tmp/nbwork"/scheduler/*.sh
touch "$tmp/nbwork/plugin/.keep"
cp "$src/version.sh" "$tmp/nbwork/scheduler/" 2>/dev/null; chmod +x "$tmp/nbwork"/scheduler/version.sh 2>/dev/null
printf 'state/\nrepos/\nworktrees/\n' >"$tmp/nbwork/.gitignore"
printf 'test:\n\t@echo "make test ran" >>%s\n\n.PHONY: test\n' "$tmp/maketest.log" >"$tmp/nbwork/Makefile"
mkdir -p "$tmp/nbwork/docs" "$tmp/nbwork/nodes"
echo spec >"$tmp/nbwork/SPEC.md"; echo g >"$tmp/nbwork/docs/graph.yaml"; echo n >"$tmp/nbwork/nodes/N.md"
git -C "$tmp/nbwork" add -A && git -C "$tmp/nbwork" -c user.name=t -c user.email=t@t commit -q -m c1
git -C "$tmp/nbwork" tag v1.0
git clone -q --bare "$tmp/nbwork" "$tmp/nbremote.git"
git clone -q "$tmp/nbremote.git" "$nbd"
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
while [ ! -e "$tmp/go" ]; do sleep 0.2; done
exit 0
EOFD
chmod +x "$tmp/bind/gh" "$tmp/bind/claude"
withind() { timeout "$1" sh -c "until grep -qE \"\$1\" '$stated/status.log' 2>/dev/null; do sleep 0.1; done" _ "$2"; }
headd() { git -C "$nbd" rev-parse HEAD; }
pushd() { git -C "$tmp/nbwork" -c user.name=t -c user.email=t@t commit -q -a -m "$1" && git -C "$tmp/nbwork" push -q "$tmp/nbremote.git" HEAD:main; }
nstarts() { grep -c 'loop started for o/dep, version ' "$stated/status.log" 2>/dev/null || true; }

NOODLEBOT_DATA=$datad PATH=$tmp/bind:$PATH SCHED_REPORT=0 SCHED_TICK=1 SCHED_POLL=0.2 bash "$nbd/scheduler/loop.sh" o/dep >"$tmp/loop.out" 2>&1 &
loop=$!; pids+=("$loop")
ok "D04-AC-3: the loop starts its node's session" withind 10 "started B01 \(only-node\).*start 1 of 2"
sp=$(cat "$stated/node/B01/session.pid" 2>/dev/null)
c1=$(headd)
starts0=$(nstarts)
ok "D04-AC-3: setup: one 'loop started' line so far and a live session (guard)" sh -c "[ '$starts0' = 1 ] && kill -0 '$sp'"

# N1: SPEC.md, docs/ and nodes/ only.
echo more >>"$tmp/nbwork/SPEC.md"; echo more >>"$tmp/nbwork/docs/graph.yaml"; echo more >>"$tmp/nbwork/nodes/N.md"
pushd n1
n1=$(git -C "$tmp/nbwork" rev-parse HEAD)
n0=$(wc -l <"$stated/status.log")
ok "D04-AC-3: the checkout moves to a non-runtime commit within a tick or two" timeout 6 sh -c "until [ \"\$(git -C '$nbd' rev-parse HEAD)\" = '$n1' ]; do sleep 0.2; done"
ok "D04-AC-3: the deploy is one status-log line, without make test" withind 5 "deployed ${c1:0:7}[0-9a-f]*\.\.${n1:0:7}[0-9a-f]* \(version [^)]+\) without make test: no runtime change\$"
wait_ticks 3
ok "D04-AC-3: the loop keeps its pid (still running)" kill -0 "$loop"
ok "D04-AC-3: the loop did not re-exec: no new 'loop started' line" test "$(nstarts)" = "$starts0"
ok "D04-AC-3: the loop did not re-exec: no 'v2' marker, the loop's own pid is unchanged" sh -c "[ ! -e '$tmp/marker' ] && kill -0 $loop"
ok "D04-AC-3: the session is still owned: alive, started once, reported running after the deploy" sh -c "kill -0 '$sp' && [ \$(grep -c '^start B01' '$tmp/claudel.log') = 1 ] && tail -n +$((n0 + 1)) '$stated/status.log' | grep -qE 'running: .*B01 \(pid $sp\)'"
ok "D04-AC-3: make test was not run for the non-runtime commit" sh -c "[ ! -e '$tmp/maketest.log' ]"

# R2: a runtime commit (a new loop.sh): the loop re-execs within one tick as D01 says.
mkloop v2 >"$tmp/nbwork/scheduler/loop.sh"
pushd r2
r2=$(git -C "$tmp/nbwork" rev-parse HEAD)
n0=$(wc -l <"$stated/status.log")
ok "D04-AC-3: the checkout moves to the runtime commit" timeout 6 sh -c "until [ \"\$(git -C '$nbd' rev-parse HEAD)\" = '$r2' ]; do sleep 0.2; done"
ok "D04-AC-3: the loop re-execs into the runtime commit's loop.sh" timeout 4 sh -c "until grep -q '^v2 pid ' '$tmp/marker' 2>/dev/null; do sleep 0.2; done"
ok "D04-AC-3: the re-exec keeps the loop's pid" sh -c "kill -0 $loop && grep -qx 'v2 pid $loop' '$tmp/marker'"
ok "D04-AC-3: the re-exec writes a second 'loop started' line" withind 5 "loop started for o/dep, version"
ok "D04-AC-3: now two 'loop started' lines" test "$(nstarts)" = $((starts0 + 1))
ok "D04-AC-3: make test ran for the runtime commit" sh -c "[ \$(grep -c 'make test ran' '$tmp/maketest.log') = 1 ]"
ok "D04-AC-3: the re-exec'd loop still owns the session" sh -c "kill -0 '$sp' && [ \$(grep -c '^start B01' '$tmp/claudel.log') = 1 ]"
touch "$tmp/go"

touch "$HOME/STOP-dep"
ok "D04: the test loop stops on STOP-dep" timeout 5 sh -c "while kill -0 $loop 2>/dev/null; do sleep 0.1; done"

loop_end
