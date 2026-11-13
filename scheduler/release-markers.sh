#!/bin/sh
# release-markers.sh <node-marker-dir> [<closed-prs-file>]: the loop runs this just before it starts a node that
# ready.py chose. It moves an answered question (QUESTION.md + ANSWER.md) and a WAITING-PR (whose
# spec PR ready.py saw merged, closed without merging, or flagged) into answered/<UTC timestamp>-*, where the session reads them, and
# prints one line per release. It prints nothing when there was nothing to release.
# A WAITING-PR is released as: SPEC-PR-SCOPE (the loop found the PR changing files outside the spec files; the file
# moves to answered/ and its paths are printed), else SPEC-PR-CLOSED (its number is in <closed-prs-file>, one PR number
# a line), else SPEC-PR (merged). Any release removes the loop's scope-check cache SPEC-PR-CHECKED.
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
	if [ -e "$d/SPEC-PR-SCOPE" ]; then
		paths=$(sed -n 's/^path //p' "$d/SPEC-PR-SCOPE" | paste -sd' ')
		mv "$d/SPEC-PR-SCOPE" "$d/answered/$ts-SPEC-PR-SCOPE"
		rm -f "$d/WAITING-PR"
		echo "spec PR #$pr changes files outside the spec files: $paths ($ts)"
	elif [ -n "${2:-}" ] && [ -r "$2" ] && grep -qxF "$pr" "$2"; then
		mv "$d/WAITING-PR" "$d/answered/$ts-SPEC-PR-CLOSED"
		echo "spec PR #$pr closed without merging ($ts)"
	else
		mv "$d/WAITING-PR" "$d/answered/$ts-SPEC-PR"
		echo "spec PR #$pr merged ($ts)"
	fi
	rm -f "$d/SPEC-PR-CHECKED"
fi
