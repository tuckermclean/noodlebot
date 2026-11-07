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

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: all release-markers checks"
