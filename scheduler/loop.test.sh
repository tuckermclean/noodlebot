#!/bin/bash
# End-to-end test of scheduler/loop.sh with a fake gh, a fake claude and a local git remote:
# an answered QUESTION.md restarts the node, the session's WAITING-PR holds it until that PR is
# merged, then the node starts again and its session sees the archived answer and spec PR.
#   bash scheduler/loop.test.sh   (make test)
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d)
loop_pid=''
trap '[ -n "$loop_pid" ] && kill "$loop_pid" 2>/dev/null; rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

export HOME=$tmp/home
nb=$tmp/nb state=$tmp/nb/state/themonolith
mkdir -p "$HOME/.config/noodlebot" "$tmp/bin" "$nb/scheduler" "$state/node/A02"
cp "$src"/loop.sh "$src"/ready.py "$src"/release-markers.sh "$src"/unattended.md "$nb/scheduler/"
printf '#!/bin/sh\necho fake-token\n' >"$HOME/.config/noodlebot/token"
echo fake-oauth >"$HOME/.config/noodlebot/oauth-token"
chmod +x "$HOME/.config/noodlebot/token"

# The remote: main carries a two-node graph.
git init -q -b main "$tmp/work"
mkdir -p "$tmp/work/docs"
printf 'nodes:\n  - {id: A01, name: first-node, deps: []}\n  - {id: A02, name: second-node, deps: [A01]}\n' >"$tmp/work/docs/graph.yaml"
git -C "$tmp/work" add -A && git -C "$tmp/work" -c user.name=t -c user.email=t@t commit -q -m init
git clone -q --bare "$tmp/work" "$tmp/remote.git"
git clone -q "$tmp/remote.git" "$nb/repos/themonolith"

# gh: merged PRs come from $tmp/merged.tsv ("<number> <head branch>"), no open PRs.
cat >"$tmp/bin/gh" <<EOF
#!/bin/sh
case " \$* " in *" --state merged "*) cat "$tmp/merged.tsv" ;; esac
exit 0
EOF
# claude: logs what answered/ holds; the first run opens "spec PR #55", later runs do nothing.
cat >"$tmp/bin/claude" <<EOF
#!/bin/sh
n=\$(( \$(cat "$tmp/runs" 2>/dev/null || echo 0) + 1 )); echo \$n >"$tmp/runs"
echo "run \$n: \$(ls "$state/node/A02/answered" 2>/dev/null | sed 's/^[0-9TZ]*-//' | sort | tr '\n' ' ')" >>"$tmp/claude.log"
[ \$n = 1 ] && echo 55 >"$state/node/A02/WAITING-PR"
exit 0
EOF
chmod +x "$tmp/bin/gh" "$tmp/bin/claude"
export PATH=$tmp/bin:$PATH
echo "1 node/A01-first-node" >"$tmp/merged.tsv"
echo "Q1: which way?" >"$state/node/A02/QUESTION.md"
echo "Q1: as recommended" >"$state/node/A02/ANSWER.md"

SCHED_TICK=1 bash "$nb/scheduler/loop.sh" >"$tmp/loop.out" 2>&1 &
loop_pid=$!
# wait_for <pattern>: up to 20 s for a status.log line.
wait_for() { timeout 20 sh -c "until grep -q \"\$1\" '$state/status.log' 2>/dev/null; do sleep 0.2; done" _ "$1"; }

wait_for "A02: released the owner's answer" && pass "an answered question releases the node" || fail "no release: $(cat "$state/status.log" "$tmp/loop.out")"
[ -e "$state/node/A02/answered" ] && [ ! -e "$state/node/A02/QUESTION.md" ] && pass "the pair moved to answered/" || fail "markers: $(ls -R "$state/node/A02")"
wait_for "started A02 (second-node).*start 1 of 2" && pass "it starts the answered node" || fail "no start: $(cat "$state/status.log")"
wait_for "session A02 ended (rc 0) waiting for spec PR #55" && pass "a WAITING-PR end is reported" || fail "no WAITING-PR end: $(cat "$state/status.log")"
sleep 3
[ "$(cat "$tmp/runs")" = 1 ] && pass "an unmerged spec PR holds the node" || fail "ran $(cat "$tmp/runs") times while PR #55 was open"
echo "55 spec/A02-topic" >>"$tmp/merged.tsv"
wait_for "A02: spec PR #55 merged" && pass "a merged spec PR releases the node" || fail "no spec release: $(cat "$state/status.log")"
wait_for "started A02 (second-node).*start 1 of 2.*" && [ "$(grep -c 'started A02.*start 1 of 2' "$state/status.log")" = 2 ] &&
	pass "the restart gets fresh starts" || fail "starts: $(grep started "$state/status.log")"
timeout 20 sh -c "until grep -q '^run 2' '$tmp/claude.log'; do sleep 0.2; done"
grep -q '^run 1: ANSWER.md QUESTION.md $' "$tmp/claude.log" && grep -q '^run 2: ANSWER.md QUESTION.md SPEC-PR $' "$tmp/claude.log" &&
	pass "each session sees the archived answer, and later the spec PR" || fail "claude saw: $(cat "$tmp/claude.log")"
[ "$(cat "$state/node/A02/answered/"*-SPEC-PR)" = 55 ] && pass "SPEC-PR holds the PR number" || fail "SPEC-PR: $(ls "$state/node/A02/answered")"
! grep -rq fake-oauth "$state" && pass "the OAuth token is in no state file" || fail "token leaked into $state"

touch "$HOME/STOP"
timeout 10 sh -c "while kill -0 $loop_pid 2>/dev/null; do sleep 0.2; done" && pass "~/STOP ends the loop" || fail "loop still running"

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: all loop checks"
