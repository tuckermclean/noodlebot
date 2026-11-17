#!/bin/sh
# D09-AC-1: the quick gate. AGENTS.md defines it (the red targets plus the touched files' test files, run as
# `TEST_JOBS=2 make test TESTS="<files>"`) and leaves the whole `make test` to CI on the PR; this repository's
# .claude/agents/noodlebot-*.md and the session templates that run tests (unattended.md, unattended-followup.md,
# unattended-node-update.md, no other) name the quick gate, and none tells a session to run the whole suite (a bare
# `make test`, or "the repository's test entry point"). The check runs against a root directory, so a copy of the tree
# with a planted line can be checked: each planted form fails it, naming file and line.
#   sh scheduler/quick-gate.test.sh   (make test)
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
root=$(cd "$src/.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

TEMPLATES="scheduler/unattended.md scheduler/unattended-followup.md scheduler/unattended-node-update.md"

# qg_files <root>: the files whose texts tell a session what to run, relative to <root>.
qg_files() {
	(cd "$1" && for f in .claude/agents/noodlebot-*.md; do [ -f "$f" ] && echo "$f"; done)
	for f in $TEMPLATES; do echo "$f"; done
}

# qg_bullet <file> <start-ere> : the "- " list item starting at the first line matching <start-ere>, with its continuations.
qg_bullet() { awk -v re="$2" '/^- / { if (on) exit } !on && $0 ~ re { on = 1 } on { print }' "$1" 2>/dev/null; }

# qg_check <root>: prints one finding per line, "<tag>|<relpath>:<line>: <what>"; exit 1 when there is any.
# Tags: define-*, name:<relpath>, whole:<relpath>.
qg_check() {
	r=$1
	ag="$r/AGENTS.md"
	if [ ! -f "$ag" ]; then echo "define-tests|AGENTS.md:0: missing"; return 1; fi
	qg_bullet "$ag" '^- \*\*Tests:\*\*' | tr '\n' ' ' | tr -s ' ' >"$tmp/tests-bullet.txt"
	tb=$(cat "$tmp/tests-bullet.txt")
	n=$(grep -n '^- \*\*Tests:\*\*' "$ag" | head -n 1 | cut -d: -f1); n=${n:-0}
	lc=$(printf '%s' "$tb" | tr 'A-Z' 'a-z')
	case $lc in *"quick gate"*) ;; *) echo "define-quick|AGENTS.md:$n: the Tests line does not define the quick gate" ;; esac
	case $lc in *"red target"*"test file"*|*"test file"*"red target"*) ;; *) echo "define-quick|AGENTS.md:$n: the quick gate is not the red targets plus the touched files' test files" ;; esac
	case $tb in *'TEST_JOBS=2 make test TESTS="<files>"'*) ;; *) echo "define-quick|AGENTS.md:$n: the quick gate is not run as TEST_JOBS=2 make test TESTS=\"<files>\"" ;; esac
	case $lc in *"both the quick gate and the whole suite"*) echo "define-ci|AGENTS.md:$n: make test is still both the quick gate and the whole suite" ;; esac
	case $lc in *"whole"*" ci "*|*" ci "*"whole"*) ;; *) echo "define-ci|AGENTS.md:$n: the Tests line does not leave the whole make test to CI" ;; esac
	case $lc in *" pr"*) ;; *) echo "define-ci|AGENTS.md:$n: the Tests line does not say CI runs it on the PR" ;; esac
	cn=$(grep -n '^- `make test`' "$ag" | head -n 1 | cut -d: -f1); cn=${cn:-0}
	cb=$(qg_bullet "$ag" '^- `make test`' | tr '\n' ' ' | tr 'A-Z' 'a-z')
	case $cb in *" ci"*) ;; *) echo "define-cmd|AGENTS.md:$cn: the Commands line does not say the whole make test is CI's" ;; esac
	eb=$(qg_bullet "$ag" '^- \*\*CI evidence:\*\*' | tr '\n' ' ' | tr 'A-Z' 'a-z')
	case $eb in *"whole suite"*) ;; *) echo "define-ci|AGENTS.md:$(grep -n '^- \*\*CI evidence:\*\*' "$ag" | head -n 1 | cut -d: -f1): the CI evidence line does not name the PR's CI run as the whole suite's evidence" ;; esac
	qg_files "$r" | while read -r f; do
		if [ ! -f "$r/$f" ]; then echo "name:$f|$f:0: missing"; continue; fi
		if ! tr 'A-Z' 'a-z' <"$r/$f" | tr '\n' ' ' | grep -Eq 'quick (test )?gate'; then
			echo "name:$f|$f:1: does not name the quick gate"
		fi
		awk -v f="$f" '
			{ low = tolower($0); rest = $0; bare = 0
			  if (low ~ /test entry point/) printf "whole:%s|%s:%d: runs \"the repository'"'"'s test entry point\" (the whole suite)\n", f, f, NR
			  while (match(rest, /make test/)) {
				after = substr(rest, RSTART + RLENGTH)
				if (after !~ /^[ \t]+TESTS=/ && after !~ /^[-A-Za-z0-9_]/) bare = 1
				rest = after
			  }
			  if (bare && low !~ /(never|do not|does not|not run|n.t run|without|instead)|(^|[^a-z])ci([^a-z]|$)/)
				printf "whole:%s|%s:%d: a bare make test (no TESTS=) runs the whole suite\n", f, f, NR
			}' "$r/$f"
	done
	return 0
}
# qg_run <root> <outfile>: qg_check into <outfile>; exit 1 when it found anything.
qg_run() { qg_check "$1" >"$2"; [ ! -s "$2" ]; }
# qg_unit <label> <tag> <findings-file>: PASS when no finding carries the tag, else FAIL with the findings.
qg_unit() {
	if grep -q "^$2|" "$3"; then
		fail "$1"; grep "^$2|" "$3" | sed 's/^[^|]*|/    /'
	else pass "$1"; fi
}

# ---------- this repository ----------
real="$tmp/real.txt"; qg_run "$root" "$real"
qg_unit "D09-AC-1: AGENTS.md defines the quick gate as the red targets plus the touched files' test files, run as TEST_JOBS=2 make test TESTS=\"<files>\"" define-quick "$real"
qg_unit "D09-AC-1: AGENTS.md leaves the whole make test to CI on the PR (the Tests line, and no longer 'both the quick gate and the whole suite')" define-ci "$real"
qg_unit "D09-AC-1: AGENTS.md's Commands line says the whole make test is CI's" define-cmd "$real"
for f in $(qg_files "$root"); do
	qg_unit "D09-AC-1: $f names the quick gate" "name:$f" "$real"
	qg_unit "D09-AC-1: $f tells no session to run the whole suite (no bare make test, no test entry point)" "whole:$f" "$real"
done
n=$(qg_files "$root" | grep -c '^\.claude/agents/noodlebot-')
if [ "$n" -eq 3 ]; then pass "D09-AC-1: the three .claude/agents/noodlebot-*.md agents are checked"; else fail "D09-AC-1: expected 3 .claude/agents/noodlebot-*.md agents, found $n"; fi

# ---------- the check itself, on a synthetic clean root ----------
clean="$tmp/clean"; mkdir -p "$clean/.claude/agents" "$clean/scheduler"
cat >"$clean/AGENTS.md" <<'EOT'
# Agents
- `make test`: the whole suite. CI runs it on the PR; a session does not.
- **Tests:** the quick gate is the change's red targets plus the test files of each file it touches, run through
  `TEST_JOBS=2 make test TESTS="<files>"`; the whole `make test` runs in CI on the PR.
- **CI evidence:** the PR's CI run is the whole suite's evidence.
EOT
for a in tester implementer reviewer; do
	printf '%s\n' "Run the quick gate: TEST_JOBS=2 make test TESTS=\"<files>\"." >"$clean/.claude/agents/noodlebot-$a.md"
done
for t in $TEMPLATES; do printf '%s\n' "Rerun the quick test gate the repository's AGENTS.md names and the red targets." >"$clean/$t"; done
if qg_run "$clean" "$tmp/clean.txt"; then pass "D09-AC-1: the check passes a root whose agents and templates name the quick gate"; else fail "D09-AC-1: the check flags a clean root"; sed 's/^/    /' "$tmp/clean.txt"; fi

# ---------- planted forms, each in a scratch copy of the real files ----------
# plant <relpath> <text> <label>: copy the real file under a copy of the tree, append <text> as its last line, and check
# that the check fails and names that file and that line.
plant() {
	pf=$1; ptxt=$2; plbl=$3
	pr="$tmp/plant-$$-$(echo "$pf" | tr '/.' '__')"
	mkdir -p "$pr/.claude/agents" "$pr/scheduler"
	cp "$root/AGENTS.md" "$pr/"
	cp "$root"/.claude/agents/noodlebot-*.md "$pr/.claude/agents/"
	for t in $TEMPLATES; do cp "$root/$t" "$pr/$t"; done
	cp "$root/scheduler/unattended-triage.md" "$pr/scheduler/" 2>/dev/null
	printf '%s\n' "$ptxt" >>"$pr/$pf"
	pl=$(wc -l <"$pr/$pf" | tr -d ' ')
	if qg_run "$pr" "$pr.out"; then fail "$plbl: the check passes with the planted line"; return; fi
	if grep -q "^whole:$pf|$pf:$pl: " "$pr.out"; then pass "$plbl: the check fails, naming $pf:$pl"; else fail "$plbl: the check does not name $pf:$pl"; sed 's/^/    /' "$pr.out"; fi
}
plant .claude/agents/noodlebot-reviewer.md 'Run `make test` at head.' "D09-AC-1: a planted bare make test in a copy of an agent file"
plant .claude/agents/noodlebot-tester.md 'Then run make test and report.' "D09-AC-1: a planted bare make test (no backticks) in a copy of another agent file"
plant scheduler/unattended-node-update.md "Rerun the repository's test entry point after the merge." "D09-AC-1: a planted 'test entry point' in a copy of unattended-node-update.md"

# a bare make test or test entry point in a template that runs no tests (here unattended-triage.md) is not this check's business
pr="$tmp/other"; mkdir -p "$pr/.claude/agents" "$pr/scheduler"
cp -R "$clean/.claude" "$pr/"; cp "$clean/AGENTS.md" "$pr/"; for t in $TEMPLATES; do cp "$clean/$t" "$pr/$t"; done
printf '%s\n' 'Run make test and the repository test entry point.' >"$pr/scheduler/unattended-triage.md"
if qg_run "$pr" "$pr.out"; then pass "D09-AC-1: only unattended.md, unattended-followup.md and unattended-node-update.md are checked (no other template)"; else fail "D09-AC-1: a template that runs no tests was checked"; sed 's/^/    /' "$pr.out"; fi

# a TESTS= form of make test is the quick gate, not the whole suite
printf '%s\n' 'Run `TEST_JOBS=2 make test TESTS="a.test.sh"`.' >>"$clean/.claude/agents/noodlebot-tester.md"
if qg_run "$clean" "$tmp/clean2.txt"; then pass "D09-AC-1: make test TESTS=\"<files>\" is not flagged as a whole-suite run"; else fail "D09-AC-1: make test TESTS=... was flagged"; sed 's/^/    /' "$tmp/clean2.txt"; fi

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
