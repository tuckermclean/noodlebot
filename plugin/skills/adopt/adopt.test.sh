#!/bin/sh
# Tests the /noodlebot:adopt skill's text (A01-AC-1, static part of A01-AC-3).
#   sh plugin/skills/adopt/adopt.test.sh   (make test)
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }
skill="$src/SKILL.md"
have=0
[ -f "$skill" ] && have=1
[ "$have" -eq 1 ] || : >"$tmp/empty"
f="$skill"
[ "$have" -eq 1 ] || f="$tmp/empty"

# ---------- A01-AC-1: the skill exists and names no repository ----------
if [ "$have" -eq 1 ]; then ok "A01-AC-1: plugin/skills/adopt/SKILL.md exists"; else bad "A01-AC-1: plugin/skills/adopt/SKILL.md does not exist"; fi
fm=$(awk 'NR==1&&/^---$/{inf=1;next} inf&&/^---$/{exit} inf{print}' "$f")
if printf '%s\n' "$fm" | grep -q '^name: adopt$'; then ok "A01-AC-1: frontmatter has name: adopt (/noodlebot:adopt)"; else bad "A01-AC-1: frontmatter has no 'name: adopt' line"; fi
if [ "$have" -eq 1 ]; then
	hit=$(sed -e 's#/\{0,1\}noodlebot:[a-z]*##g' -e 's#\.noodlebot/##g' "$f" | grep -in -e themonolith -e monolith -e strange-company -e qa-lab -e linux-live-iso-factory -e 'tuckermclean/' -e noodlebot | head -n 3)
	if [ -z "$hit" ]; then ok "A01-AC-1: SKILL.md names no repository"; else bad "A01-AC-1: SKILL.md names a repository: $hit"; fi
	hit=$(grep -in 'github\.com/[A-Za-z0-9_.-]*/[A-Za-z0-9_.-]' "$f" | head -n 3)
	if [ -z "$hit" ]; then ok "A01-AC-1: SKILL.md has no github.com/<owner>/<name> URL"; else bad "A01-AC-1: SKILL.md has a concrete GitHub slug: $hit"; fi
else
	bad "A01-AC-1: SKILL.md names no repository (cannot check: no SKILL.md)"
	bad "A01-AC-1: SKILL.md has no github.com/<owner>/<name> URL (cannot check: no SKILL.md)"
fi

# ---------- A01-AC-3 (static): QUESTION.md before drafts, one PR on spec/adopt ----------
if grep -q 'QUESTION\.md' "$f"; then ok "A01-AC-3: SKILL.md mentions QUESTION.md"; else bad "A01-AC-3: SKILL.md does not mention QUESTION.md"; fi
if grep -q 'ANSWER\.md' "$f"; then ok "A01-AC-3: SKILL.md mentions ANSWER.md"; else bad "A01-AC-3: SKILL.md does not mention ANSWER.md"; fi
if grep -q 'spec/adopt' "$f"; then ok "A01-AC-3: SKILL.md names the branch spec/adopt"; else bad "A01-AC-3: SKILL.md does not name the branch spec/adopt"; fi
if grep -Fq '<forge> pr create' "$f"; then ok "A01-AC-3: SKILL.md opens the PR with the forge CLI (<forge> pr create)"; else bad "A01-AC-3: SKILL.md does not say '<forge> pr create'"; fi
q=$(grep -n 'QUESTION\.md' "$f" | head -n 1 | cut -d: -f1)
d=$(grep -in '^#.*draft' "$f" | head -n 1 | cut -d: -f1)
[ -n "$d" ] || d=$(grep -n 'nodes/<' "$f" | head -n 1 | cut -d: -f1)
if [ -z "$q" ]; then bad "A01-AC-3: QUESTION.md comes before the drafts (no mention of QUESTION.md)"
elif [ -z "$d" ]; then bad "A01-AC-3: QUESTION.md comes before the drafts (no draft heading or nodes/<ID> mention found)"
elif [ "$q" -lt "$d" ]; then ok "A01-AC-3: QUESTION.md (line $q) comes before the drafts (line $d)"
else bad "A01-AC-3: QUESTION.md (line $q) does not come before the drafts (line $d)"; fi

# ---------- A01-AC-2: the fixture repository and the recorded dry run on it ----------
fx="$src/testdata/repo"
ex="$src/example"
if [ -d "$fx" ] && [ ! -e "$fx/docs/graph.yaml" ] && [ ! -e "$fx/nodes" ]; then ok "A01-AC-2: testdata/repo is a repository without a graph"; else bad "A01-AC-2: testdata/repo is missing or already has docs/graph.yaml or nodes/"; fi
if [ -f "$fx/README.md" ] && [ -f "$fx/issues.json" ]; then ok "A01-AC-2: testdata/repo has README.md and issues.json"; else bad "A01-AC-2: testdata/repo lacks README.md or issues.json"; fi
if [ -f "$fx/issues.json" ] && python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$fx/issues.json" 2>/dev/null; then ok "A01-AC-2: issues.json is valid JSON"; else bad "A01-AC-2: issues.json is missing or not valid JSON"; fi
if [ -f "$src/testdata/ANSWER.md" ]; then ok "A01-AC-2: testdata/ANSWER.md exists"; else bad "A01-AC-2: testdata/ANSWER.md does not exist"; fi
if [ -f "$ex/SPEC.md" ] && [ -f "$ex/docs/graph.yaml" ]; then ok "A01-AC-2: example/ holds SPEC.md and docs/graph.yaml"; else bad "A01-AC-2: example/ lacks SPEC.md or docs/graph.yaml"; fi
if [ -d "$ex/nodes" ] && ls "$ex"/nodes/*.md >/dev/null 2>&1; then ok "A01-AC-2: example/ holds at least one nodes/*.md"; else bad "A01-AC-2: example/ has no nodes/*.md"; fi
if [ -f "$ex/AGENTS.md" ] && grep -q '^#\{1,\} .*Building a node' "$ex/AGENTS.md"; then ok "A01-AC-2: example/AGENTS.md has a Building a node section"; else bad "A01-AC-2: example/AGENTS.md is missing or has no Building a node heading"; fi
if [ -d "$ex" ]; then
	rep=$(python3 -I "$src/../node/check-regime.py" --root "$ex" 2>&1)
else
	rep="no example directory"
fi
if printf '%s\n' "$rep" | grep -q 'PROBLEMS 0$'; then ok "A01-AC-2: check-regime.py reports PROBLEMS 0 on example/"; else bad "A01-AC-2: check-regime.py does not report PROBLEMS 0 on example/: $(printf '%s\n' "$rep" | tail -n 1)"; fi
if printf '%s\n' "$rep" | grep -Eq '[1-9][0-9]* criteria'; then ok "A01-AC-2: the checker counts at least one criterion"; else bad "A01-AC-2: the checker counts no criterion on example/"; fi
if [ -d "$ex" ]; then
	hit=$(find "$ex" -type f -exec cat {} + | sed -e 's#/\{0,1\}noodlebot:[a-z]*##g' -e 's#\.noodlebot/##g' | grep -in -e themonolith -e monolith -e strange-company -e qa-lab -e linux-live-iso-factory -e 'tuckermclean/' -e noodlebot | head -n 3)
	if [ -z "$hit" ]; then ok "A01-AC-2: example/ names no repository"; else bad "A01-AC-2: example/ names a repository: $hit"; fi
else
	bad "A01-AC-2: example/ names no repository (cannot check: no example/)"
fi

# A01-AC-3 (stronger): order by headings, the stop for ANSWER.md, one PR
ac3_check() { # $1 = SKILL.md path, $2 = label suffix
	_f=$1
	_h=$(awk 'NR==1&&/^---$/{fm=1;next} fm&&/^---$/{fm=0;next} fm{next} /^#+ /{print NR": "$0}' "$_f")
	_q=$(printf '%s\n' "$_h" | grep 'QUESTION\.md' | head -n 1 | cut -d: -f1)
	_d=$(printf '%s\n' "$_h" | grep -i 'draft' | head -n 1 | cut -d: -f1)
	if [ -n "$_q" ]; then ok "A01-AC-3: a heading mentions QUESTION.md$2"; else bad "A01-AC-3: no heading mentions QUESTION.md$2"; fi
	if [ -n "$_d" ]; then ok "A01-AC-3: a heading mentions drafts$2"; else bad "A01-AC-3: no heading mentions drafts$2"; fi
	if [ -n "$_q" ] && [ -n "$_d" ]; then
		if [ "$_q" -lt "$_d" ]; then ok "A01-AC-3: the QUESTION.md heading comes before the drafts heading$2"; else bad "A01-AC-3: the drafts heading (line $_d) comes before the QUESTION.md heading (line $_q)$2"; fi
	fi
	if [ -n "$_q" ]; then
		_sec=$(awk -v s="$_q" 'NR<s{next} NR>s&&/^## /{exit} {print}' "$_f")
		if printf '%s\n' "$_sec" | grep -qi 'stop' && printf '%s\n' "$_sec" | grep -q 'ANSWER\.md'; then ok "A01-AC-3: the QUESTION.md section stops until ANSWER.md exists$2"; else bad "A01-AC-3: the QUESTION.md section does not say to stop until ANSWER.md exists$2"; fi
	else
		bad "A01-AC-3: no QUESTION.md section to check for the stop$2"
	fi
	if grep -Eqi 'one (PR|pull request)' "$_f"; then ok "A01-AC-3: the skill opens one PR$2"; else bad "A01-AC-3: the skill does not say it opens one PR$2"; fi
}
if [ -f "$skill" ]; then ac3_check "$skill" ""; else bad "A01-AC-3: stronger checks cannot run: no SKILL.md"; fi

# ---------- A01 S3 (Q2): name the node skill and the guard config directly ----------
if [ "$have" -eq 1 ] && grep -qF '/noodlebot:node <ID>' "$f"; then ok "A01-AC-1: SKILL.md tells drafts to name the node skill as /noodlebot:node <ID>"; else bad "A01-AC-1: SKILL.md does not contain the literal text /noodlebot:node <ID>"; fi
if [ "$have" -eq 1 ] && grep -qF '.noodlebot/roles.yaml' "$f"; then ok "A01-AC-1: SKILL.md names the guard config .noodlebot/roles.yaml"; else bad "A01-AC-1: SKILL.md does not name the guard config .noodlebot/roles.yaml"; fi
if [ -f "$ex/AGENTS.md" ] && grep -qF '/noodlebot:node' "$ex/AGENTS.md"; then ok "A01-AC-2: example/AGENTS.md mentions /noodlebot:node"; else bad "A01-AC-2: example/AGENTS.md does not mention /noodlebot:node"; fi
# the relaxed filter (same sed+grep as above) still catches a repository mention
for line in 'see tuckermclean/noodlebot' 'the noodlebot repository' 'run /noodlebot:node and see noodlebot'; do
	hit=$(printf '%s\n' "$line" | sed -e 's#/\{0,1\}noodlebot:[a-z]*##g' -e 's#\.noodlebot/##g' | grep -in -e themonolith -e monolith -e strange-company -e qa-lab -e linux-live-iso-factory -e 'tuckermclean/' -e noodlebot | head -n 3)
	if [ -n "$hit" ]; then ok "A01-AC-1/2: relaxed filter still catches: $line"; else bad "A01-AC-1/2: relaxed filter misses a repository mention: $line"; fi
done
hit=$(printf '%s\n' 'use /noodlebot:node <ID> and .noodlebot/roles.yaml' | sed -e 's#/\{0,1\}noodlebot:[a-z]*##g' -e 's#\.noodlebot/##g' | grep -in -e tuckermclean/ -e noodlebot | head -n 3)
if [ -z "$hit" ]; then ok "A01-AC-1/2: relaxed filter lets the skill and config names through"; else bad "A01-AC-1/2: relaxed filter rejects the skill/config names: $hit"; fi

# ---------- G05 slice 2: adopt runs the spec checker before its push; its AGENTS.md draft has a Spec files line (G05-AC-4) ----------
g05d="$tmp/G05"; mkdir -p "$g05d"
# g05_win <file> <n> <ere>...: some window of <n> consecutive lines matches every ERE (case-insensitive, asterisks dropped).
g05_win() {
	g05_f=$1; g05_n=$2; shift 2
	g05_pats=$(printf '%s\n' "$@")
	awk -v n="$g05_n" -v pats="$g05_pats" '
		BEGIN { k = split(pats, P, "\n") }
		{ gsub(/\*/, ""); L[NR] = tolower($0) }
		END {
			for (i = 1; i <= NR; i++) {
				w = ""; for (j = i; j < i + n && j <= NR; j++) w = w " " L[j]
				good = 1; for (p = 1; p <= k; p++) if (w !~ P[p]) { good = 0; break }
				if (good) exit 0
			}
			exit 1 }' "$g05_f"
}
# g05_sec <skill> <heading-regex> <out>: the lines from the first "## " heading matching the regex to the next "## " heading.
g05_sec() { awk -v re="$2" '/^## / { if (on) exit; if (tolower($0) ~ re) on = 1 } on { print }' "$1" >"$3"; }
if [ "$have" -eq 1 ]; then
	if g05_win "$f" 6 'check-spec-diff' 'origin/main' 'before' 'push'; then ok "G05-AC-4: adopt runs check-spec-diff.py against origin/main before its push"; else bad "G05-AC-4: adopt does not run check-spec-diff.py against origin/main before its push"; fi
	if g05_win "$f" 6 'check-spec-diff' '--allow agents[.]md'; then ok "G05-AC-4: adopt runs the checker with --allow AGENTS.md"; else bad "G05-AC-4: adopt does not run the checker with --allow AGENTS.md"; fi
	if g05_win "$f" 6 'check-spec-diff' 'exit(s)? (code )?1|exit 1|non-zero' 'stop'; then ok "G05-AC-4: adopt stops when the checker exits 1"; else bad "G05-AC-4: adopt does not stop when the checker exits 1"; fi
	if g05_win "$f" 40 'building a node' 'spec files:'; then ok "G05-AC-4: the Building a node section adopt drafts has a Spec files: line"; else bad "G05-AC-4: adopt's drafting instructions for Building a node give no Spec files: line"; fi
else
	bad "G05-AC-4: adopt checks cannot run: no SKILL.md"
fi

# R02-AC-1 (review 1): with no environment naming a forge CLI, the skill says how to reach one: scheduler/forge-cli.sh and --repo, close together
r02_forge_win() { # <file> <label>
	if awk '{ L[NR] = $0 } END { for (i = 1; i <= NR; i++) { w = ""; for (j = i; j < i + 6 && j <= NR; j++) w = w " " L[j]; if (w ~ /scheduler\/forge-cli\.sh/ && w ~ /--repo/) exit 0 } exit 1 }' "$1"; then ok "R02-AC-1: $2 SKILL.md says how to reach the forge CLI with no environment naming one (scheduler/forge-cli.sh, --repo)"; else bad "R02-AC-1: $2 SKILL.md does not say how to reach the forge CLI with no environment naming one (needs scheduler/forge-cli.sh and --repo within a few lines)"; fi
}
r02_forge_win "$f" adopt

# ---------- A06: the baseline (AC-1 questions and what runs before the gate is confirmed, AC-2 baseline and drafts, AC-3 recorded dry run, AC-4 quick gate) ----------
a06d="$tmp/A06"; mkdir -p "$a06d"
bfx="$src/testdata/baseline/repo"
bex="$src/example-baseline"
# a06_mkfix <dir>: the dry run's input. Copies testdata/baseline/repo/, creates the vendored folder (never committed in
# this repository) and commits everything with git add -f, so the copy is a git repository with vendor/ tracked.
a06_mkfix() {
	mkdir -p "$1"
	cp -R "$bfx/." "$1/"
	mkdir -p "$1/vendor/shunit"
	printf '# vendored third-party shell helpers\nshunit_version=2\n' >"$1/vendor/shunit/shunit.sh"
	printf 'vendored helpers, not ours\n' >"$1/vendor/README"
	(cd "$1" && git init -q && git add -f -A && git -c user.name=t -c user.email=t@t commit -q -m fixture)
}
# a06_sec <heading-regex> <out>: one "## " section of the skill, as g05_sec
a06_sec() { g05_sec "$f" "$1" "$2"; }
a06_sec 'facts' "$a06d/s1"
a06_sec 'ask the owner' "$a06d/s2"
a06_sec 'drafts' "$a06d/s3"
a06_sec 'dry run' "$a06d/sdry"
# a06_win <name> <section file> <n> <label> <ere>...: a window of <n> lines of the section matches every ERE
a06_win() {
	_nm=$1; _sf=$2; _n=$3; _lb=$4; shift 4
	if [ -s "$_sf" ] && g05_win "$_sf" "$_n" "$@"; then ok "$_nm: $_lb"; else bad "$_nm: $_lb"; fi
}

# ----- A06-AC-1: the inventory instead of every file; three questions with recommendations; what runs before the gate is confirmed -----
a06_win A06-AC-1 "$a06d/s1" 6 "section 1 reads inventory.py's output (--json --areas)" 'inventory[.]py' '--areas'
a06_win A06-AC-1 "$a06d/s1" 8 "section 1 reads the inventory instead of every source file" 'inventory' 'instead|rather than|beyond|not read|does not read|no need to read'
a06_win A06-AC-1 "$a06d/s2" 5 "section 2 asks for the gate command, with a recommendation" 'gate' 'command' 'recommend|propos'
a06_win A06-AC-1 "$a06d/s2" 5 "section 2 asks for the out-of-scope paths, with a recommendation" 'out[- _]of[- _]scope|leave out|leave them out' 'recommend|propos'
a06_win A06-AC-1 "$a06d/s2" 5 "section 2 asks for the areas, with a recommendation" 'areas' 'recommend|propos'
a06_win A06-AC-1 "$a06d/s1" 8 "before the owner confirms the gate, section 1 runs only a command the CI, Makefile or package scripts already run" 'before' 'confirm' 'only' 'makefile' 'package' 'already'
a06_win A06-AC-1 "$a06d/s1" 8 "that command runs in the clone or worktree (a dry run: its temporary copy)" 'before' 'confirm' 'clone|worktree' 'temporary copy'
a06_win A06-AC-1 "$a06d/s1" 8 "any other command waits for the owner's confirmation" 'other command|no other|nothing else|any other' 'wait|not run|never run|only after|until'

# ----- A06-AC-2: the baseline run, known_red, the stop, the AGENTS.md section and the graph -----
a06_win A06-AC-2 "$a06d/s3" 8 "section 3 runs the confirmed gate once" 'run|runs' 'confirmed' 'gate' 'once'
a06_win A06-AC-2 "$a06d/s3" 8 "it records a fail_pattern and each failing test's full name in known_red" 'fail_pattern' 'known_red' 'full name'
a06_win A06-AC-2 "$a06d/s3" 8 "a gate that cannot run stops the run with a question" 'cannot run|can not run|does not run|fails to run|will not run' 'stop' 'question'
a06_win A06-AC-2 "$a06d/s3" 14 "the AGENTS.md Building a node section names the gate command, run in CI" 'agents[.]md' 'building a node' 'gate command' 'ci'
a06_win A06-AC-2 "$a06d/s3" 14 "it also names a quick gate that a session runs locally" 'building a node' 'quick gate' 'local'
a06_win A06-AC-2 "$a06d/s3" 10 "the graph draft has the gate, out_of_scope, the adoption areas and nodes: []" 'docs/graph[.]yaml' 'gate' 'out_of_scope' 'adoption' 'nodes: [[]]'
if g05_win "$f" 6 'check-regime' 'check-coverage' 'problems 0'; then ok "A06-AC-2: check-regime.py and check-coverage.py must report PROBLEMS 0"; else bad "A06-AC-2: check-regime.py and check-coverage.py must report PROBLEMS 0"; fi
if g05_win "$f" 8 'check-coverage' 'before' 'push'; then ok "A06-AC-2: check-coverage.py runs before the push"; else bad "A06-AC-2: check-coverage.py runs before the push"; fi

# ----- A06-AC-4: a quick gate only through the gate's own runner -----
a06_win A06-AC-4 "$f" 10 "a quick gate is drafted only through the gate's own runner, whose output fail_pattern reads" 'quick gate' 'runner' 'fail_pattern' 'only|unless'
a06_win A06-AC-4 "$f" 10 "a quick gate that would run another command is a question to the owner, not a draft" 'quick gate' 'another command|other command|different command' 'question' 'not (a )?draft|does not draft|never draft|instead of draft|no draft'
a06_win A06-AC-4 "$f" 10 "a quick gate that would print another output format is a question too" 'quick gate' 'output format' 'question'
a06_win A06-AC-4 "$f" 10 "that question carries a recommendation" 'quick gate' 'question' 'recommend'

# ----- A06-AC-3: the fixture, the answers, the recorded dry run and its checks -----
if [ -d "$bfx" ] && [ ! -e "$bfx/docs/graph.yaml" ] && [ ! -e "$bfx/nodes" ] && [ ! -e "$bfx/vendor" ]; then ok "A06-AC-3: testdata/baseline/repo is a repository without a graph and without the vendored folder"; else bad "A06-AC-3: testdata/baseline/repo is missing, has a graph, or has vendor/ committed"; fi
if [ -f "$src/testdata/baseline/ANSWER.md" ] && grep -qi 'gate' "$src/testdata/baseline/ANSWER.md" && grep -qi 'vendor' "$src/testdata/baseline/ANSWER.md" && grep -qi 'area' "$src/testdata/baseline/ANSWER.md" && grep -qi 'quick gate' "$src/testdata/baseline/ANSWER.md"; then ok "A06-AC-3: testdata/baseline/ANSWER.md answers the gate, out-of-scope, areas and quick gate questions"; else bad "A06-AC-3: testdata/baseline/ANSWER.md is missing or lacks the gate, vendor, areas or quick gate answers"; fi
a06_mkfix "$a06d/fx0"
if (cd "$a06d/fx0" && git ls-files | grep -q '^vendor/shunit/shunit.sh$'); then ok "A06-AC-3: the fixture function tracks the vendored folder with git add -f"; else bad "A06-AC-3: the fixture function does not track vendor/"; fi
if [ "$(cd "$a06d/fx0" && sh -c 'make test' 2>&1 | grep -c '^FAIL ')" = 1 ]; then ok "A06-AC-3: the fixture has exactly one failing test"; else bad "A06-AC-3: the fixture does not have exactly one failing test"; fi
hit=$(find "$bfx" "$src/testdata/baseline/ANSWER.md" -type f -exec cat {} + | sed -e 's#/\{0,1\}noodlebot:[a-z]*##g' -e 's#\.noodlebot/##g' | grep -in -e themonolith -e monolith -e strange-company -e qa-lab -e linux-live-iso-factory -e 'tuckermclean/' -e noodlebot | head -n 3)
if [ -z "$hit" ]; then ok "A06-AC-3: the baseline fixture names no repository"; else bad "A06-AC-3: the baseline fixture names a repository: $hit"; fi
a06_win A06-AC-3 "$a06d/sdry" 8 "the dry run copies the input to a temporary folder and runs the gate there" 'copy|copies' 'temporary' 'gate'
if [ -d "$bex" ]; then ok "A06-AC-3: example-baseline/ exists"; else bad "A06-AC-3: example-baseline/ does not exist"; fi
if [ -f "$bex/SPEC.md" ] && [ -f "$bex/docs/graph.yaml" ] && [ -f "$bex/AGENTS.md" ]; then ok "A06-AC-3: example-baseline/ holds SPEC.md, AGENTS.md and docs/graph.yaml"; else bad "A06-AC-3: example-baseline/ lacks SPEC.md, AGENTS.md or docs/graph.yaml"; fi
if [ -f "$bex/AGENTS.md" ] && grep -q '^#\{1,\} .*Building a node' "$bex/AGENTS.md"; then ok "A06-AC-3: example-baseline/AGENTS.md has a Building a node section"; else bad "A06-AC-3: example-baseline/AGENTS.md is missing or has no Building a node heading"; fi
if [ -d "$bex" ]; then
	hit=$(find "$bex" -type f -exec cat {} + | sed -e 's#/\{0,1\}noodlebot:[a-z]*##g' -e 's#\.noodlebot/##g' | grep -in -e themonolith -e monolith -e strange-company -e qa-lab -e linux-live-iso-factory -e 'tuckermclean/' -e noodlebot | head -n 3)
	if [ -z "$hit" ]; then ok "A06-AC-3: example-baseline/ names no repository"; else bad "A06-AC-3: example-baseline/ names a repository: $hit"; fi
else
	bad "A06-AC-3: example-baseline/ names no repository (cannot check: no example-baseline/)"
fi
# the graph, and the gate run in a fresh copy of the fixture
cat >"$a06d/graph-check.py" <<'PY'
import os, re, subprocess, sys
graph, copy = sys.argv[1], sys.argv[2]
LABELS = ["the graph has nodes: []",
          "gate.command, gate.fail_pattern and gate.known_red are set",
          "known_red names the fixture's failing test (t_narrow)",
          "out_of_scope names the vendored folder, with a reason",
          "adoption has at least one area",
          "gate.command run in a copy of the fixture prints at least one line fail_pattern matches",
          "every matched line contains a known_red entry"]
res = {}
def r(i, ok):
    res[i] = bool(ok)
try:
    import yaml
    g = yaml.safe_load(open(graph)) or {}
    r(0, "nodes" in g and g["nodes"] == [])
    gate = g.get("gate") or {}
    cmd, fp, kr = gate.get("command"), gate.get("fail_pattern"), gate.get("known_red")
    r(1, isinstance(cmd, str) and cmd.strip() and isinstance(fp, str) and fp and isinstance(kr, list) and kr)
    kr = [k for k in (kr or []) if isinstance(k, str) and k]
    r(2, any("t_narrow" in k for k in kr))
    oos = g.get("out_of_scope") or []
    r(3, any(isinstance(e, dict) and str(e.get("glob", "")).startswith("vendor") and str(e.get("reason", "")).strip() for e in oos))
    areas = (g.get("adoption") or {}).get("areas")
    r(4, isinstance(areas, list) and len(areas) > 0)
    if res[1]:
        env = {k: v for k, v in os.environ.items() if k not in ("MAKEFLAGS", "MFLAGS", "MAKELEVEL")}
        p = subprocess.run(cmd, shell=True, cwd=copy, capture_output=True, text=True, timeout=120, env=env)
        lines = (p.stdout + "\n" + p.stderr).splitlines()
        m = [l for l in lines if re.search(fp, l)]
        r(5, len(m) >= 1)
        r(6, len(m) >= 1 and all(any(k in l for k in kr) for l in m))
except Exception as e:
    sys.stderr.write("graph-check: %s\n" % e)
for i, l in enumerate(LABELS):
    print(("ok " if res.get(i) else "bad ") + l)
PY
a06_mkfix "$a06d/fx1"
python3 -I "$a06d/graph-check.py" "$bex/docs/graph.yaml" "$a06d/fx1" >"$a06d/gc.out" 2>"$a06d/gc.err"
if [ "$(wc -l <"$a06d/gc.out")" -ne 7 ]; then
	bad "A06-AC-3: the graph check did not run: $(head -n 2 "$a06d/gc.err")"
else
	while IFS= read -r l; do
		case $l in
		"ok "*) ok "A06-AC-3: ${l#ok }" ;;
		*) bad "A06-AC-3: ${l#bad }" ;;
		esac
	done <"$a06d/gc.out"
fi
# the coverage of the dry run: the drafts laid over a copy of the fixture, committed, both checkers PROBLEMS 0
a06_mkfix "$a06d/fx2"
for p in SPEC.md AGENTS.md docs nodes .noodlebot; do
	if [ -e "$bex/$p" ]; then rm -rf "$a06d/fx2/$p"; cp -R "$bex/$p" "$a06d/fx2/$p"; fi
done
(cd "$a06d/fx2" && git add -f -A && git -c user.name=t -c user.email=t@t commit -q -m drafts)
if [ -f "$a06d/fx2/docs/graph.yaml" ]; then
	rep=$(python3 -I "$src/../node/check-regime.py" --root "$a06d/fx2" 2>&1)
	if printf '%s\n' "$rep" | grep -q 'PROBLEMS 0$'; then ok "A06-AC-3: check-regime.py reports PROBLEMS 0 on the fixture with the dry run laid over it"; else bad "A06-AC-3: check-regime.py does not report PROBLEMS 0 on the fixture with the dry run: $(printf '%s\n' "$rep" | head -n 2 | tr '\n' ' ')"; fi
	rep=$(python3 -I "$src/../node/check-coverage.py" --root "$a06d/fx2" 2>&1)
	if printf '%s\n' "$rep" | grep -q 'PROBLEMS 0$'; then ok "A06-AC-3: check-coverage.py reports PROBLEMS 0 on the fixture with the dry run laid over it"; else bad "A06-AC-3: check-coverage.py does not report PROBLEMS 0 on the fixture with the dry run: $(printf '%s\n' "$rep" | head -n 2 | tr '\n' ' ')"; fi
else
	bad "A06-AC-3: check-regime.py reports PROBLEMS 0 on the fixture with the dry run laid over it (no example-baseline/docs/graph.yaml)"
	bad "A06-AC-3: check-coverage.py reports PROBLEMS 0 on the fixture with the dry run laid over it (no example-baseline/docs/graph.yaml)"
fi
if [ -d "$ex" ] && python3 -I "$src/../node/check-regime.py" --root "$ex" 2>&1 | grep -q 'PROBLEMS 0$'; then ok "A06-AC-3: the checks of example/ still pass (check-regime.py PROBLEMS 0)"; else bad "A06-AC-3: the checks of example/ no longer pass"; fi

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: all adopt checks"
