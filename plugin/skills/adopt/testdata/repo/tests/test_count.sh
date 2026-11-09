#!/bin/sh
d=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
printf 'a b\nc\n' >"$t/x"
out=$("$d/bin/tallyho" "$t/x")
case "$out" in *"2       3       6"*) echo "PASS: counts";; *) echo "FAIL: counts: $out"; exit 1;; esac
