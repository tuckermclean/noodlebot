#!/bin/sh
# Tests A10 (gate-strip), A10-AC-1: the strip step of the gate's pass condition wherever it stands: escape codes and a
# fetched job log's timestamp prefix are stripped from a line before it is matched against fail_pattern and checked
# for a known_red entry, for the CI run and local output alike, and the evidence lists the failing lines as stripped.
# Checked in each place separately (SKILL.md step 3, step 5's pass condition paragraph, the --update step that stops
# on a failing test, feedback step 3; the tester, implementer and reviewer agents; unattended-node-update.md), one
# statement within one sentence per case. (A10-AC-2 and A10-AC-3 are in plugin/skills/adopt/adopt.test.sh.)
#   sh plugin/skills/node/skill-a10.test.sh   (make test)
# A10_ROOT (default: this checkout) names the tree whose files are read; the test only reads.
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
root=${A10_ROOT:-$(cd "$src/../../.." && pwd -P)}
sk="$root/plugin/skills/node/SKILL.md"
tmp=$(mktemp -d) && [ -d "$tmp" ] || exit 1
trap 'rm -rf "$tmp"' EXIT
d="$tmp/A10"; mkdir -p "$d"
fails=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

# a10_sen <label> <file> <ere>...: one sentence of the file (joined, split at ". ", emphasis and backticks removed,
# lower-cased) matches every ERE. An empty or missing file fails.
a10_sen() {
	s_l=$1; s_f=$2; shift 2
	s_pats=$(printf '%s\n' "$@")
	if [ -s "$s_f" ] && awk -v pats="$s_pats" '
		BEGIN { k = split(pats, P, "\n") }
		{ gsub(/[*`]/, ""); t = t " " tolower($0) }
		END {
			gsub(/e[.]g[.]/, "for example", t); gsub(/i[.]e[.]/, "that is", t)
			n = split(t, S, /[.] /)
			for (i = 1; i <= n; i++) {
				s = S[i]
				good = 1; for (p = 1; p <= k; p++) if (s !~ P[p]) { good = 0; break }
				if (good) exit 0
			}
			exit 1 }' "$s_f"; then ok "$s_l"; else bad "$s_l"; fi
}
# a10_sec <heading-regex> <out>: the "## " section of SKILL.md whose heading (lower-cased) matches.
a10_sec() { awk -v re="$1" '/^## / { if (on) exit; if (tolower($0) ~ re) on = 1 } on { print }' "$sk" >"$2"; }
# a10_unit <file> <start-ere> <stop-ere> <out>: from the first line matching the start up to (not including) the next
# line matching the stop.
a10_unit() { awk -v re="$2" -v stop="$3" '!on && $0 ~ re { on = 1; print; next } on && $0 ~ stop { exit } on { print }' "$1" >"$4"; }

if [ ! -f "$sk" ]; then bad "A10-AC-1: plugin/skills/node/SKILL.md is missing"; echo "$fails failed"; exit 1; fi

a10_sec '^## 3[.]' "$d/sec3.md"
a10_sec '^## 5[.]' "$d/sec5.md"
a10_sec '^## update a node pr' "$d/secu.md"
a10_sec '^## 8[.]' "$d/sec8.md"
a10_unit "$d/sec5.md" "The gate's pass condition" '^$|^#' "$d/s5.md"
a10_unit "$d/secu.md" '^4[.] ' '^[0-9]+[.] |^#' "$d/upd.md"
a10_unit "$d/sec8.md" '^3[.] ' '^[0-9]+[.] |^#' "$d/fb.md"
cp "$d/sec3.md" "$d/s3.md"
cp "$root/plugin/agents/tester.md" "$d/tester.md" 2>/dev/null || : >"$d/tester.md"
cp "$root/plugin/agents/implementer.md" "$d/implementer.md" 2>/dev/null || : >"$d/implementer.md"
cp "$root/plugin/agents/reviewer.md" "$d/reviewer.md" 2>/dev/null || : >"$d/reviewer.md"
cp "$root/scheduler/unattended-node-update.md" "$d/nu.md" 2>/dev/null || : >"$d/nu.md"

for p in "skill step 3 (GREEN)|s3" "skill step 5 (the gate's pass condition paragraph)|s5" "skill --update step 4 (a failing test)|upd" \
	"skill step 8 item 3 (feedback)|fb" "the tester agent|tester" "the implementer agent|implementer" "the reviewer agent|reviewer" \
	"unattended-node-update.md|nu"; do
	who=${p%%|*}; f="$d/${p#*|}.md"
	if [ -s "$f" ]; then ok "A10-AC-1: $who: the text is found"; else bad "A10-AC-1: $who: the text is not found"; fi
	a10_sen "A10-AC-1: $who: escape codes are stripped from a line" "$f" \
		'escape code' 'strip'
	a10_sen "A10-AC-1: $who: a fetched job log's timestamp prefix is stripped from a line" "$f" \
		'job log' 'timestamp prefix' 'strip'
	a10_sen "A10-AC-1: $who: the strip comes before a line is matched against fail_pattern and checked for a known_red entry" "$f" \
		'(strip[a-z]* .*before .*(match|check).*fail_pattern.*known_red|^ *before .*(match|check).*fail_pattern.*known_red.*strip)'
	a10_sen "A10-AC-1: $who: the strip holds for the CI run and local output alike" "$f" \
		'strip' 'ci run' 'local output' 'alike|both|same'
	a10_sen "A10-AC-1: $who: the evidence lists the failing lines as stripped" "$f" \
		'evidence' 'failing lines? as stripped'
done

if [ "$fails" -gt 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"
