#!/bin/sh
# release-markers.sh <node-marker-dir>: the loop runs this just before it starts a node that
# ready.py chose. It moves an answered question (QUESTION.md + ANSWER.md) and a WAITING-PR (whose
# spec PR ready.py saw merged) into answered/<UTC timestamp>-*, where the session reads them, and
# prints one line per release. It prints nothing when there was nothing to release.
set -eu
d=$1
ts=$(date -u +%Y%m%dT%H%M%SZ)
if [ -e "$d/QUESTION.md" ] && [ -e "$d/ANSWER.md" ]; then
	mkdir -p "$d/answered"
	mv "$d/QUESTION.md" "$d/answered/$ts-QUESTION.md"
	mv "$d/ANSWER.md" "$d/answered/$ts-ANSWER.md"
	echo "released the owner's answer ($ts)"
fi
if [ -e "$d/WAITING-PR" ]; then
	mkdir -p "$d/answered"
	pr=$(cat "$d/WAITING-PR")
	mv "$d/WAITING-PR" "$d/answered/$ts-SPEC-PR"
	echo "spec PR #$pr merged ($ts)"
fi
