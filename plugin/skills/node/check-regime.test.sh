#!/bin/sh
# Tests check-regime.py: a valid two-node repository passes; each kind of mistake is reported.
#   sh plugin/skills/node/check-regime.test.sh   (make test)
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
# fixture: X01 (no deps) and X02 (deps X01)
fixture() {
	rm -rf "$tmp/r" && mkdir -p "$tmp/r/docs" "$tmp/r/nodes"
	printf 'template: {headings: [Purpose, Gate]}\nnodes:\n  - {id: X01, name: first, track: now, deps: []}\n  - {id: X02, name: second, track: later, deps: [X01]}\n' >"$tmp/r/docs/graph.yaml"
	printf '# X01 — first\n\n| Track | Deps | Unlocks | Size |\n|---|---|---|---|\n| now | none | X02 | S |\n\n## Purpose\nP.\n\n## Gate\n- **X01-AC-1** — one. *Verify:* t.\n- **X01-AC-2** — two. *Verify:* t.\n' >"$tmp/r/nodes/X01-first.md"
	printf '# X02 — second\n\n## Purpose\nP.\n\n## Gate\n- **X02-AC-1** — one. *Verify:* t.\n' >"$tmp/r/nodes/X02-second.md"
}
check() {  # check <name> <expected output fragment> : run after mutating the fixture
	out=$(python3 -I "$src/check-regime.py" --root "$tmp/r" 2>&1)
	if printf '%s' "$out" | grep -qF -- "$2"; then echo "PASS: $1"; else echo "FAIL: $1: want '$2' in: $out"; fails=$((fails + 1)); fi
}
fixture; check "a valid repository has no problems" "PROBLEMS 0"
fixture; sed -i 's/deps: \[X01\]/deps: [X09]/' "$tmp/r/docs/graph.yaml"; check "an unknown dep" "X02: unknown dep X09"
fixture; sed -i 's/name: first, track: now, deps: \[\]/name: first, track: now, deps: [X02]/' "$tmp/r/docs/graph.yaml"; check "a cycle" "cycle:"
fixture; rm "$tmp/r/nodes/X02-second.md"; check "a missing spec" "X02: no spec nodes/X02-second.md"
fixture; sed -i 's/| now | none | X02 | S |/| now | none | none | S |/' "$tmp/r/nodes/X01-first.md"; check "a header row that disagrees with the graph" "X01: header row"
fixture; sed -i 's/X01-AC-2/X01-AC-3/' "$tmp/r/nodes/X01-first.md"; check "a gap in the criteria" "X01: criteria numbered [1, 3]"
fixture; sed -i 's/two. \*Verify:\* t./two./' "$tmp/r/nodes/X01-first.md"; check "a criterion without Verify" "X01-AC-2: no *Verify:*"
fixture; sed -i 's/## Purpose/## Aim/' "$tmp/r/nodes/X02-second.md"; check "a missing template heading" "X02: missing headings ['Purpose']"
fixture; sed -i '1s/.*/# X02 — other/' "$tmp/r/nodes/X02-second.md"; check "a wrong title" "X02: the title is not"
if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: all check-regime checks"
