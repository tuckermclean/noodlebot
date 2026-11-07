#!/bin/sh
# Tests the scheduler's ready-node choice (scheduler/ready.py) against a fixture graph.
#   sh scheduler/ready.test.sh   (make test)
set -u
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root" || exit 2
ready=scheduler/ready.py
graph=scheduler/testdata/graph.yaml
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0

# check <name> <expected stdout> <args...>: ready.py exits 0 and prints exactly the expected line.
check() {
	name=$1; want=$2; shift 2
	mkdir -p "$tmp/m"
	got=$(python3 -I "$ready" --graph "$graph" --markers "$tmp/m" "$@" 2>&1); rc=$?
	if [ $rc = 0 ] && [ "$got" = "$want" ]; then echo "PASS: $name"
	else echo "FAIL: $name: want '$want' (rc 0), got '$got' (rc $rc)"; fails=$((fails + 1)); fi
}
reset() { rm -rf "$tmp/m"; }

reset; check "nothing merged: the root node" "A01 first-node"
reset; check "A01 merged: the next node in graph order" "A02 second-node" --merged A01
reset; check "an open PR skips the node" "A03 third-node" --merged A01 --open A02
reset; mkdir -p "$tmp/m/A02"; : >"$tmp/m/A02/QUESTION.md"
check "QUESTION.md skips the node" "A03 third-node" --merged A01
reset; mkdir -p "$tmp/m/A02"; : >"$tmp/m/A02/FAILED"
check "FAILED skips the node; nothing else ready" "" --merged A01 --open A03
reset; check "a node waits for every dep" "" --merged A01 --merged A02 --open A03
reset; check "everything merged: nothing" "" --merged A01 --merged A02 --merged A03 --merged A04

# Merged by the squash commit on main: "<ID> <name>: ..." only, the name must match the graph.
printf '%s\n' "A01 first-node: the root (#5)" "Spec: A02 second-node is amended (#6)" "A03 wrong-name: x (#7)" >"$tmp/subjects"
reset; check "a squash subject '<ID> <name>:' counts as merged; others do not" "A02 second-node" --subjects "$tmp/subjects"

# Answers: QUESTION.md plus ANSWER.md makes the node ready again, even with its PR open.
reset; mkdir -p "$tmp/m/A02"; : >"$tmp/m/A02/QUESTION.md"; : >"$tmp/m/A02/ANSWER.md"
check "QUESTION.md with ANSWER.md: the node is ready again" "A02 second-node" --merged A01
reset; mkdir -p "$tmp/m/A02"; : >"$tmp/m/A02/QUESTION.md"; : >"$tmp/m/A02/ANSWER.md"
check "an answered node with an open PR is ready" "A02 second-node" --merged A01 --open A02
reset; mkdir -p "$tmp/m/A02"; : >"$tmp/m/A02/QUESTION.md"; : >"$tmp/m/A02/ANSWER.md"
check "an answered node that is merged is not ready" "A03 third-node" --merged A01 --merged A02
reset; mkdir -p "$tmp/m/A02"; : >"$tmp/m/A02/ANSWER.md"
check "ANSWER.md alone changes nothing" "A02 second-node" --merged A01
reset; mkdir -p "$tmp/m/A02"; : >"$tmp/m/A02/QUESTION.md"; : >"$tmp/m/A02/ANSWER.md"; : >"$tmp/m/A02/FAILED"
check "FAILED holds even an answered node" "A03 third-node" --merged A01

# WAITING-PR: holds the node until that PR number is merged.
printf '%s\n' 7 12 >"$tmp/prs"
reset; mkdir -p "$tmp/m/A02"; echo 41 >"$tmp/m/A02/WAITING-PR"
check "WAITING-PR on an unmerged PR holds the node" "A03 third-node" --merged A01 --merged-prs "$tmp/prs"
reset; mkdir -p "$tmp/m/A02"; echo 12 >"$tmp/m/A02/WAITING-PR"
check "WAITING-PR on a merged PR: the node is ready again, even with its PR open" "A02 second-node" --merged A01 --open A02 --merged-prs "$tmp/prs"
reset; mkdir -p "$tmp/m/A02"; echo 12 >"$tmp/m/A02/WAITING-PR"
check "WAITING-PR without --merged-prs holds the node" "A03 third-node" --merged A01
reset; mkdir -p "$tmp/m/A02"; echo "#12 maybe" >"$tmp/m/A02/WAITING-PR"
check "a WAITING-PR that is not a bare number holds the node" "A03 third-node" --merged A01 --merged-prs "$tmp/prs"
reset; mkdir -p "$tmp/m/A02"; echo 12 >"$tmp/m/A02/WAITING-PR"; : >"$tmp/m/A02/QUESTION.md"
check "a merged WAITING-PR with an unanswered QUESTION.md holds the node" "A03 third-node" --merged A01 --merged-prs "$tmp/prs"

out=$(python3 -I "$ready" --graph "$tmp/missing.yaml" --markers "$tmp" 2>&1); rc=$?
if [ $rc != 0 ] && [ -z "$(printf '%s' "$out" | grep -E '^A0[0-9] ')" ]; then echo "PASS: an unreadable graph fails and names no node"
else echo "FAIL: an unreadable graph: rc $rc, output '$out'"; fails=$((fails + 1)); fi

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: all scheduler-ready checks"
