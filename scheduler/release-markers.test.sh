#!/bin/sh
# shellcheck disable=SC2015 # pass only echoes, so "A && pass || fail" never runs both
# Tests scheduler/release-markers.sh: it archives an answered question and a merged WAITING-PR.
#   sh scheduler/release-markers.test.sh   (make test)
set -u
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root" || exit 2
rel=scheduler/release-markers.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

d=$tmp/n1; mkdir -p "$d"; echo q >"$d/QUESTION.md"; echo a >"$d/ANSWER.md"
out=$(sh "$rel" "$d"); rc=$?
[ $rc = 0 ] && [ ! -e "$d/QUESTION.md" ] && [ ! -e "$d/ANSWER.md" ] && pass "an answered question leaves the node directory" || fail "answered: rc $rc, $(ls "$d")"
q=$(ls "$d"/answered/*-QUESTION.md 2>/dev/null); a=$(ls "$d"/answered/*-ANSWER.md 2>/dev/null)
[ -n "$q" ] && [ -n "$a" ] && [ "$(cat "$q")" = q ] && [ "$(cat "$a")" = a ] && [ "${q%-QUESTION.md}" = "${a%-ANSWER.md}" ] &&
	pass "the pair is kept under answered/ with one shared prefix" || fail "archive: q='$q' a='$a'"
case $out in *answer*) pass "it says it released an answer" ;; *) fail "output '$out'" ;; esac

d=$tmp/n2; mkdir -p "$d/answered"; echo old >"$d/answered/20260101T000000Z-QUESTION.md"; echo 12 >"$d/WAITING-PR"
out=$(sh "$rel" "$d"); rc=$?
[ $rc = 0 ] && [ ! -e "$d/WAITING-PR" ] && [ "$(cat "$d"/answered/*-SPEC-PR 2>/dev/null)" = 12 ] &&
	[ -e "$d/answered/20260101T000000Z-QUESTION.md" ] && pass "a WAITING-PR moves to answered/<ts>-SPEC-PR; older entries stay" || fail "waiting-pr: rc $rc, $(ls -R "$d")"
case $out in *12*) pass "it names the merged spec PR" ;; *) fail "output '$out'" ;; esac

d=$tmp/n3; mkdir -p "$d"; echo q >"$d/QUESTION.md"
out=$(sh "$rel" "$d"); rc=$?
[ $rc = 0 ] && [ -e "$d/QUESTION.md" ] && [ -z "$out" ] && pass "an unanswered question stays and nothing is printed" || fail "unanswered: rc $rc, out '$out'"

d=$tmp/n4; mkdir -p "$d"
out=$(sh "$rel" "$d"); rc=$?
[ $rc = 0 ] && [ -z "$out" ] && [ ! -e "$d/answered" ] && pass "no markers: nothing happens" || fail "empty: rc $rc, out '$out'"

# G05: a WAITING-PR whose spec PR was closed without merging, one with SPEC-PR-SCOPE, a merged one with the file argument.
G05=$tmp/G05; mkdir -p "$G05"; printf '%s\n' 7 33 >"$G05/closed"
d=$G05/n1; mkdir -p "$d"; echo 33 >"$d/WAITING-PR"; echo cached >"$d/SPEC-PR-CHECKED"
out=$(sh "$rel" "$d" "$G05/closed"); rc=$?
[ $rc = 0 ] && [ ! -e "$d/WAITING-PR" ] && [ "$(cat "$d"/answered/*-SPEC-PR-CLOSED 2>/dev/null)" = 33 ] && [ ! -e "$d/answered/"*-SPEC-PR ] &&
	pass "G05-AC-5: a WAITING-PR in the closed PRs moves to answered/<ts>-SPEC-PR-CLOSED" || fail "G05-AC-5: closed: rc $rc, $(ls -R "$d" 2>&1)"
case $out in *"spec PR #33 closed without merging"*) pass "G05-AC-5: it prints 'spec PR #33 closed without merging'" ;; *) fail "G05-AC-5: closed output '$out'" ;; esac
[ ! -e "$d/SPEC-PR-CHECKED" ] && pass "G05-AC-5: the scope-check cache SPEC-PR-CHECKED is removed on release" || fail "G05-AC-5: SPEC-PR-CHECKED still there"

d=$G05/n2; mkdir -p "$d"; echo 41 >"$d/WAITING-PR"; echo cached >"$d/SPEC-PR-CHECKED"
printf 'pr 41\nbranch spec/g05\nhead 0123abc\npath scheduler/x.test.sh\npath tools/y.sh\n' >"$d/SPEC-PR-SCOPE"
cp "$d/SPEC-PR-SCOPE" "$G05/scope.orig"
out=$(sh "$rel" "$d" "$G05/closed"); rc=$?
s=$(ls "$d"/answered/*-SPEC-PR-SCOPE 2>/dev/null)
[ $rc = 0 ] && [ -n "$s" ] && cmp -s "$s" "$G05/scope.orig" && [ ! -e "$d/SPEC-PR-SCOPE" ] && [ ! -e "$d/WAITING-PR" ] &&
	pass "G05-AC-6: SPEC-PR-SCOPE moves to answered/<ts>-SPEC-PR-SCOPE with its content; WAITING-PR is removed" || fail "G05-AC-6: scope: rc $rc, $(ls -R "$d" 2>&1)"
[ -z "$(ls "$d"/answered/*-SPEC-PR 2>/dev/null)" ] && [ -z "$(ls "$d"/answered/*-SPEC-PR-CLOSED 2>/dev/null)" ] &&
	pass "G05-AC-6: no SPEC-PR or SPEC-PR-CLOSED entry is made for it" || fail "G05-AC-6: extra entries: $(ls "$d/answered" 2>&1)"
case $out in *"#41"*"scheduler/x.test.sh"*"tools/y.sh"*) pass "G05-AC-6: the printed line names the PR and the paths" ;; *) fail "G05-AC-6: scope output '$out'" ;; esac
[ "$(printf '%s\n' "$out" | wc -l)" = 1 ] && pass "G05-AC-6: one line is printed" || fail "G05-AC-6: lines: '$out'"
[ ! -e "$d/SPEC-PR-CHECKED" ] && pass "G05-AC-6: SPEC-PR-CHECKED is removed on release" || fail "G05-AC-6: SPEC-PR-CHECKED still there"

d=$G05/n3; mkdir -p "$d"; echo 12 >"$d/WAITING-PR"; echo cached >"$d/SPEC-PR-CHECKED"
out=$(sh "$rel" "$d" "$G05/closed"); rc=$?
[ $rc = 0 ] && [ ! -e "$d/WAITING-PR" ] && [ "$(cat "$d"/answered/*-SPEC-PR 2>/dev/null)" = 12 ] && [ -z "$(ls "$d"/answered/*-CLOSED 2>/dev/null)" ] &&
	pass "G05-AC-5: a merged WAITING-PR (not listed as closed) still moves to answered/<ts>-SPEC-PR with the file argument given" || fail "G05-AC-5: merged: rc $rc, $(ls -R "$d" 2>&1)"
case $out in *"spec PR #12 merged"*) pass "G05-AC-5: it still prints 'spec PR #12 merged'" ;; *) fail "G05-AC-5: merged output '$out'" ;; esac
[ ! -e "$d/SPEC-PR-CHECKED" ] && pass "G05-AC-5: SPEC-PR-CHECKED is removed when a merged WAITING-PR is released" || fail "G05-AC-5: SPEC-PR-CHECKED still there (merged)"

d=$G05/n4; mkdir -p "$d"; echo 12 >"$d/WAITING-PR"
out=$(sh "$rel" "$d"); rc=$?
[ $rc = 0 ] && [ "$(cat "$d"/answered/*-SPEC-PR 2>/dev/null)" = 12 ] && case $out in *"spec PR #12 merged"*) true ;; *) false ;; esac &&
	pass "G05-AC-5: with no file argument a WAITING-PR is released as merged, as before" || fail "G05-AC-5: no-arg: rc $rc out '$out'"

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: all release-markers checks"
