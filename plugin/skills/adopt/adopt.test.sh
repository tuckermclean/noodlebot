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
	hit=$(sed -e 's#/\{0,1\}noodlebot:[a-z]*##g' "$f" | grep -in -e themonolith -e monolith -e strange-company -e qa-lab -e linux-live-iso-factory -e 'tuckermclean/' -e noodlebot | head -n 3)
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
if grep -q 'gh pr create' "$f"; then ok "A01-AC-3: SKILL.md opens the PR with gh pr create"; else bad "A01-AC-3: SKILL.md does not say 'gh pr create'"; fi
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
	hit=$(grep -rin -e themonolith -e monolith -e strange-company -e qa-lab -e linux-live-iso-factory -e 'tuckermclean/' -e noodlebot "$ex" | head -n 3)
	if [ -z "$hit" ]; then ok "A01-AC-2: example/ names no repository"; else bad "A01-AC-2: example/ names a repository: $hit"; fi
else
	bad "A01-AC-2: example/ names no repository (cannot check: no example/)"
fi

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: all adopt checks"
