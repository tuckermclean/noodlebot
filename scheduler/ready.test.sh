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
check "an answered node that is merged is printed as a follow-up" "A02 second-node followup" --merged A01 --merged A02
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

# --all: every ready node, in graph order (A02 and A03 both depend only on A01).
reset
check "--all lists every ready node in graph order" "$(printf 'A02 second-node\nA03 third-node')" --merged A01 --all
reset; mkdir -p "$tmp/m/A02"; : >"$tmp/m/A02/QUESTION.md"
check "--all still skips a held node" "A03 third-node" --merged A01 --all


# S03: a merged node with an answer to act on is printed as "<ID> <name> followup".
A2="$tmp/m/A02"
answered() { reset; mkdir -p "$A2"; : >"$A2/QUESTION.md"; : >"$A2/ANSWER.md"; }
answered
check "S03-AC-1: a merged node (--merged) with an answered question: followup, even with --open" "A02 second-node followup" --merged A01 --merged A02 --open A02
printf '%s\n' "A01 first-node: the root (#5)" "A02 second-node: the second (#6)" >"$tmp/subjects2"
answered
check "S03-AC-1: a node merged by its squash subject with an answered question: followup" "A02 second-node followup" --subjects "$tmp/subjects2"
reset; mkdir -p "$A2"; echo 12 >"$A2/WAITING-PR"
check "S03-AC-1: a merged node with a WAITING-PR in --merged-prs: followup" "A02 second-node followup" --merged A01 --merged A02 --merged-prs "$tmp/prs"
reset; mkdir -p "$A2"; echo 41 >"$A2/WAITING-PR"
check "S03-AC-1: a merged node with a WAITING-PR not in --merged-prs is not printed" "A03 third-node" --merged A01 --merged A02 --merged-prs "$tmp/prs"
reset; mkdir -p "$A2"; echo 12 >"$A2/WAITING-PR"
check "S03-AC-1: a merged node with a WAITING-PR and no --merged-prs is not printed" "A03 third-node" --merged A01 --merged A02
reset; mkdir -p "$A2"; echo 12 >"$A2/WAITING-PR"; : >"$A2/QUESTION.md"
check "S03-AC-1: a merged WAITING-PR with an unanswered QUESTION.md is not printed" "A03 third-node" --merged A01 --merged A02 --merged-prs "$tmp/prs"
reset; mkdir -p "$A2"; echo node/A02-followup-1 >"$A2/FOLLOWUP"
check "S03-AC-1: a merged node with a FOLLOWUP marker: followup" "A02 second-node followup" --merged A01 --merged A02
reset; mkdir -p "$A2"; echo node/A02-followup-1 >"$A2/FOLLOWUP"
check "S03-AC-1: a FOLLOWUP marker with --open for that node is not printed" "A03 third-node" --merged A01 --merged A02 --open A02
reset; mkdir -p "$A2"; echo node/A02-followup-1 >"$A2/FOLLOWUP"
check "S03-AC-1: a FOLLOWUP marker for a node merged by squash subject: followup" "A02 second-node followup" --subjects "$tmp/subjects2"
reset; mkdir -p "$A2"; echo node/A02-followup-1 >"$A2/FOLLOWUP"; : >"$A2/QUESTION.md"
check "S03-AC-1: a FOLLOWUP marker with an unanswered QUESTION.md is not printed" "A03 third-node" --merged A01 --merged A02
reset; mkdir -p "$A2"; echo node/A02-followup-1 >"$A2/FOLLOWUP"; : >"$A2/FAILED"
check "S03-AC-1: a FOLLOWUP marker with FAILED is not printed" "A03 third-node" --merged A01 --merged A02
reset; mkdir -p "$A2"; echo node/A02-followup-1 >"$A2/FOLLOWUP"; echo 41 >"$A2/WAITING-PR"
check "S03-AC-1: a FOLLOWUP marker with an unmerged WAITING-PR is not printed" "A03 third-node" --merged A01 --merged A02 --merged-prs "$tmp/prs"
reset
check "S03-AC-1: a merged node with no markers is not printed" "A03 third-node" --merged A01 --merged A02
reset; mkdir -p "$A2"; : >"$A2/QUESTION.md"
check "S03-AC-1: a merged node with an unanswered QUESTION.md is not printed" "A03 third-node" --merged A01 --merged A02
answered; : >"$A2/FAILED"
check "S03-AC-1: a merged answered node with FAILED is not printed" "A03 third-node" --merged A01 --merged A02
reset; mkdir -p "$A2"; : >"$A2/ANSWER.md"
check "S03-AC-1: a merged node with ANSWER.md alone is not printed" "A03 third-node" --merged A01 --merged A02
answered
check "S03-AC-1: --all orders the followup line among ready lines in graph order" "$(printf 'A02 second-node followup\nA04 fourth-node')" --merged A01 --merged A02 --merged A03 --all
mkdir -p "$tmp/m/A03"; : >"$tmp/m/A03/QUESTION.md"; : >"$tmp/m/A03/ANSWER.md"
check "S03-AC-1: --all with two followups and an ordinary node, in graph order" "$(printf 'A02 second-node followup\nA03 third-node followup\nA04 fourth-node')" --merged A01 --merged A02 --merged A03 --all
answered
check "S03-AC-1: --all with a followup before an unmerged ready node" "$(printf 'A02 second-node followup\nA03 third-node')" --merged A01 --merged A02 --all
reset; mkdir -p "$tmp/m/A03"; : >"$tmp/m/A03/QUESTION.md"; : >"$tmp/m/A03/ANSWER.md"
check "S03-AC-1: --all: an unmerged answered node keeps its plain line, before and after" "$(printf 'A02 second-node\nA03 third-node')" --merged A01 --all
answered
check "S03-AC-1: without --all only the first ready line is printed (the followup)" "A02 second-node followup" --merged A01 --merged A02 --merged A03

# G05: a spec PR closed without merging (--closed-prs) releases its WAITING-PR like a merged one; SPEC-PR-SCOPE resumes.
G05=$tmp/G05; mkdir -p "$G05"; printf '%s\n' 33 >"$G05/closed"
reset; mkdir -p "$tmp/m/A02"; echo 33 >"$tmp/m/A02/WAITING-PR"
check "G05-AC-5: an unmerged node whose WAITING-PR is in --closed-prs is printed" "A02 second-node" --merged A01 --closed-prs "$G05/closed"
reset; mkdir -p "$tmp/m/A02"; echo 33 >"$tmp/m/A02/WAITING-PR"
check "G05-AC-5: a merged node whose WAITING-PR is in --closed-prs is printed as a follow-up" "A02 second-node followup" --merged A01 --merged A02 --closed-prs "$G05/closed"
reset; mkdir -p "$tmp/m/A02"; echo 34 >"$tmp/m/A02/WAITING-PR"
check "G05-AC-5: a WAITING-PR in neither --merged-prs nor --closed-prs holds the node" "A03 third-node" --merged A01 --merged-prs "$tmp/prs" --closed-prs "$G05/closed"
reset; mkdir -p "$tmp/m/A02"; echo 34 >"$tmp/m/A02/WAITING-PR"
check "G05-AC-5: a WAITING-PR with an empty --closed-prs and no --merged-prs holds the node" "A03 third-node" --merged A01 --closed-prs "$G05/none"
: >"$G05/none"
reset; mkdir -p "$tmp/m/A02"; echo 34 >"$tmp/m/A02/WAITING-PR"
check "G05-AC-5: an empty --closed-prs file holds a WAITING-PR" "A03 third-node" --merged A01 --closed-prs "$G05/none"
reset; mkdir -p "$tmp/m/A02"; echo 12 >"$tmp/m/A02/WAITING-PR"
check "G05-AC-5: --merged-prs still releases a WAITING-PR when --closed-prs is given too" "A02 second-node" --merged A01 --merged-prs "$tmp/prs" --closed-prs "$G05/closed"
reset; mkdir -p "$tmp/m/A02"; echo 12 >"$tmp/m/A02/WAITING-PR"
check "G05-AC-5: --merged-prs alone still releases a WAITING-PR" "A02 second-node" --merged A01 --merged-prs "$tmp/prs"
reset; mkdir -p "$tmp/m/A02"; echo 33 >"$tmp/m/A02/WAITING-PR"; : >"$tmp/m/A02/FAILED"
check "G05-AC-5: FAILED still holds a node whose WAITING-PR is in --closed-prs" "A03 third-node" --merged A01 --closed-prs "$G05/closed"
reset; mkdir -p "$tmp/m/A02"; echo 34 >"$tmp/m/A02/WAITING-PR"; printf 'pr 34\nbranch spec/x\nhead abc\npath scheduler/x.test.sh\n' >"$tmp/m/A02/SPEC-PR-SCOPE"
check "G05-AC-6: a WAITING-PR with SPEC-PR-SCOPE next to it is printed (resume)" "A02 second-node" --merged A01
reset; mkdir -p "$tmp/m/A02"; echo 34 >"$tmp/m/A02/WAITING-PR"; printf 'pr 34\nbranch spec/x\nhead abc\npath scheduler/x.test.sh\n' >"$tmp/m/A02/SPEC-PR-SCOPE"
check "G05-AC-6: SPEC-PR-SCOPE resumes a merged node as a follow-up" "A02 second-node followup" --merged A01 --merged A02
reset; mkdir -p "$tmp/m/A02"; echo 34 >"$tmp/m/A02/WAITING-PR"; printf 'pr 34\nbranch spec/x\nhead abc\npath p\n' >"$tmp/m/A02/SPEC-PR-SCOPE"; : >"$tmp/m/A02/FAILED"
check "G05-AC-6: FAILED still holds a node with SPEC-PR-SCOPE" "A03 third-node" --merged A01

# A02: an imported or pinned node is done by declaration: never printed, merged for its dependants.
adopted=scheduler/testdata/graph-adopted.yaml
checka() {
	name=$1; want=$2; shift 2
	mkdir -p "$tmp/m"
	got=$(python3 -I "$ready" --graph "$adopted" --markers "$tmp/m" "$@" 2>&1); rc=$?
	if [ $rc = 0 ] && [ "$got" = "$want" ]; then echo "PASS: $name"
	else echo "FAIL: $name: want '$want' (rc 0), got '$got' (rc $rc)"; fails=$((fails + 1)); fi
}
reset
checka "A02-AC-4: nothing merged: imported and pinned are not printed, their planned dependant is ready" "A01 first-node"
checka "A02-AC-4: --all: planned nodes only, the dependant of imported and pinned nodes included" "$(printf 'A01 first-node\nA04 after-adopted')" --all
checka "A02-AC-4: --all with A01 and A04 merged: the planned dependants of both" "$(printf 'A05 after-planned\nA06 last-node')" --merged A01 --merged A04 --all
checka "A02-AC-4: --open of a planned node skips it; the dependant of adopted nodes is next" "A04 after-adopted" --open A01
reset; mkdir -p "$tmp/m/A02" "$tmp/m/A03"
: >"$tmp/m/A02/QUESTION.md"; : >"$tmp/m/A02/ANSWER.md"; echo node/A02-followup-1 >"$tmp/m/A02/FOLLOWUP"
: >"$tmp/m/A03/QUESTION.md"; : >"$tmp/m/A03/ANSWER.md"; echo node/A03-followup-1 >"$tmp/m/A03/FOLLOWUP"
checka "A02-AC-4: answers and FOLLOWUP markers on an imported or pinned node print nothing" "$(printf 'A01 first-node\nA04 after-adopted')" --all
checka "A02-AC-4: markers plus --merged of an adopted node print no follow-up line" "$(printf 'A01 first-node\nA04 after-adopted')" --merged A02 --merged A03 --all
checka "A02-AC-4: a first-ready line is never an adopted node, even with markers" "A01 first-node" --merged A02
reset; mkdir -p "$tmp/m/A02" "$tmp/m/A03"; : >"$tmp/m/A02/FAILED"; : >"$tmp/m/A03/FAILED"
checka "A02-AC-4: FAILED on an imported or pinned node does not hold its dependant" "$(printf 'A01 first-node\nA04 after-adopted')" --all
reset; mkdir -p "$tmp/m/A02" "$tmp/m/A03"; : >"$tmp/m/A02/FAILED"; echo 12 >"$tmp/m/A03/WAITING-PR"
checka "A02-AC-4: WAITING-PR on an adopted node prints nothing and holds no dependant" "$(printf 'A01 first-node\nA04 after-adopted')" --all
printf '%s\n' "A02 imported-node: adopted (#3)" "A03 pinned-node: adopted (#4)" "A01 first-node: x (#5)" >"$tmp/subjectsa"
reset; mkdir -p "$tmp/m/A02"; : >"$tmp/m/A02/QUESTION.md"; : >"$tmp/m/A02/ANSWER.md"
checka "A02-AC-4: an adopted node named by a squash subject with an answer is still not printed" "$(printf 'A04 after-adopted\nA05 after-planned')" --subjects "$tmp/subjectsa" --all
reset; mkdir -p "$tmp/m/A02" "$tmp/m/A03"; echo node/x >"$tmp/m/A02/FOLLOWUP"
checka "A02-AC-4: --open of an adopted node changes nothing" "$(printf 'A01 first-node\nA04 after-adopted')" --open A02 --open A03 --all
reset; checka "A02-AC-4: an open A04 (dependant of adopted nodes) is skipped like any ready node" "A01 first-node" --open A04

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: all scheduler-ready checks"
