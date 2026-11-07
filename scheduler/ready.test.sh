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

out=$(python3 -I "$ready" --graph "$tmp/missing.yaml" --markers "$tmp" 2>&1); rc=$?
if [ $rc != 0 ] && [ -z "$(printf '%s' "$out" | grep -E '^A0[0-9] ')" ]; then echo "PASS: an unreadable graph fails and names no node"
else echo "FAIL: an unreadable graph: rc $rc, output '$out'"; fails=$((fails + 1)); fi

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: all scheduler-ready checks"
