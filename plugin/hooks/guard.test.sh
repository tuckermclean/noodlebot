#!/bin/sh
# Tests the role guard (guard.py) and the plugin's generic role agents.
#   sh plugin/hooks/guard.test.sh   (make test)
# R01-AC-1: agents exist, name no repository, the skill names them. R01-AC-2: the guard's decisions.
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
plug=$(dirname "$src")
guard="$src/guard.py"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

# mkjson <agent_type|-> <cwd> <tool> <key> <value> : the PreToolUse hook input on stdout
cat >"$tmp/mkjson.py" <<'PY'
import json, sys
at, cwd, tool, key, val = sys.argv[1:6]
d = {"hook_event_name": "PreToolUse", "session_id": "s", "cwd": cwd, "tool_name": tool, "tool_input": {key: val}}
if at != "-":
    d["agent_type"] = at
    d["agent_id"] = "a1"
print(json.dumps(d))
PY

# decide <root> <usecwd 0|1> <agent_type> <tool> <key> <value> : sets rc and err
decide() {
	rc=127; err=""
	[ -f "$guard" ] || return 0
	mkdir -p "$tmp/home"
	python3 -I "$tmp/mkjson.py" "$3" "$1" "$4" "$5" "$6" >"$tmp/in.json"
	if [ "$2" = 1 ]; then
		err=$(env -u CLAUDE_PROJECT_DIR python3 -I "$guard" <"$tmp/in.json" 2>&1 >/dev/null)
	else
		err=$(CLAUDE_PROJECT_DIR="$1" python3 -I "$guard" <"$tmp/in.json" 2>&1 >/dev/null)
	fi
	rc=$?
}
# expect <id> <desc> <allow|block> <root> <agent_type> <tool> <key> <value> [usecwd]
expect() {
	decide "$4" "${9:-0}" "$5" "$6" "$7" "$8"
	if [ ! -f "$guard" ]; then bad "$1: $2: plugin/hooks/guard.py does not exist"; return; fi
	if [ "$3" = allow ]; then
		if [ "$rc" -eq 0 ]; then ok "$1: $2"; else bad "$1: $2: want allow (exit 0), got exit $rc: $err"; fi
	else
		if [ "$rc" -eq 2 ] && [ -n "$err" ]; then ok "$1: $2"; else bad "$1: $2: want block (exit 2 with a reason on stderr), got exit $rc: $err"; fi
	fi
}

# ---------- AC-1: the agents and the skill ----------
for r in tester implementer reviewer; do
	f="$plug/agents/$r.md"
	if [ -f "$f" ]; then ok "R01-AC-1: plugin/agents/$r.md exists"; else bad "R01-AC-1: plugin/agents/$r.md does not exist"; continue; fi
	if grep -q "^name: $r\$" "$f"; then ok "R01-AC-1: $r.md has name: $r"; else bad "R01-AC-1: $r.md has no 'name: $r' line"; fi
	hit=$(sed -e 's#/\{0,1\}noodlebot:[a-z]*##g' "$f" | grep -in -e themonolith -e monolith -e strange-company -e qa-lab -e linux-live-iso-factory -e 'tuckermclean/' -e noodlebot | head -n 3)
	if [ -z "$hit" ]; then ok "R01-AC-1: $r.md names no repository"; else bad "R01-AC-1: $r.md names a repository: $hit"; fi
	fm=$(awk 'NR==1&&/^---$/{inf=1;next} inf&&/^---$/{exit} inf{print}' "$f")
	if printf '%s\n' "$fm" | grep -q '^hooks:'; then bad "R01-AC-1: $r.md carries a hooks: frontmatter key (ignored in plugin agents)"; else ok "R01-AC-1: $r.md has no hooks: frontmatter key"; fi
done
skill="$plug/skills/node/SKILL.md"
for r in tester implementer reviewer; do
	if grep -q "noodlebot:$r" "$skill" 2>/dev/null; then ok "R01-AC-1: SKILL.md names noodlebot:$r"; else bad "R01-AC-1: SKILL.md does not name noodlebot:$r"; fi
done
if grep -i 'AGENTS.md' "$skill" 2>/dev/null | grep -qi -e 'no role agent' -e 'names no' -e 'names none' -e 'none of its own'; then ok "R01-AC-1: SKILL.md says the plugin's agents are used when AGENTS.md names none"; else bad "R01-AC-1: SKILL.md does not say the plugin's agents are used when AGENTS.md names no role agents"; fi

# ---------- hook wiring ----------
hj="$src/hooks.json"
if [ -f "$hj" ] && python3 -I - "$hj" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
entries = d["hooks"]["PreToolUse"]
for e in entries:
    m = e.get("matcher", "")
    if all(t in m.split("|") or t in m for t in ("Edit", "Write", "NotebookEdit", "Bash")):
        for h in e["hooks"]:
            c = h.get("command", "")
            if "${CLAUDE_PLUGIN_ROOT}" in c and "guard.py" in c:
                sys.exit(0)
sys.exit(1)
PY
then ok "R01-AC-2: hooks.json wires a PreToolUse hook on Edit|Write|NotebookEdit|Bash to guard.py"; else bad "R01-AC-2: plugin/hooks/hooks.json missing or does not wire PreToolUse on Edit|Write|NotebookEdit|Bash to \${CLAUDE_PLUGIN_ROOT}/.../guard.py"; fi

# ---------- fixtures ----------
mkrepo() {  # mkrepo <dir> : empty git repo
	rm -rf "$1" && mkdir -p "$1" && git -C "$1" init -q 2>/dev/null
}
D="$tmp/def"; mkrepo "$D"                       # no roles.yaml: defaults
C="$tmp/cus"; mkrepo "$C"; mkdir -p "$C/.noodlebot"
printf 'tests: ["spec_tests/**", "**/*.chk"]\nspecs: ["contracts/**"]\n' >"$C/.noodlebot/roles.yaml"
P="$tmp/part"; mkrepo "$P"; mkdir -p "$P/.noodlebot"
printf 'tests: ["spec_tests/**"]\n' >"$P/.noodlebot/roles.yaml"   # specs stay default
mkdir -p "$tmp/scratch"
T=noodlebot:tester; I=noodlebot:implementer; V=noodlebot:reviewer
W=Write; E=Edit; B=Bash; fp=file_path; cmd=command

# ---------- AC-2: tester, defaults ----------
a=R01-AC-2
expect $a "tester may write a *.test.sh" allow "$D" $T $W $fp "scheduler/x.test.sh"
expect $a "tester may write a tests/ file (absolute path)" allow "$D" $T $E $fp "$D/pkg/tests/t.py"
expect $a "tester may write a testdata/ file" allow "$D" $T $W $fp "scheduler/testdata/f.txt"
expect $a "tester may write a fixtures/ file" allow "$D" $T $W $fp "fixtures/a.json"
expect $a "tester may write a test_* file" allow "$D" $T $W $fp "test_x.py"
expect $a "tester may write a *_test.go file" allow "$D" $T $W $fp "pkg/x_test.go"
expect $a "tester may not write source" block "$D" $T $W $fp "src/main.py"
expect $a "tester may not write source (absolute path)" block "$D" $T $E $fp "$D/src/main.py"
expect $a "tester may not write a spec path" block "$D" $T $W $fp "SPEC.md"
expect $a "tester may not write nodes/" block "$D" $T $E $fp "nodes/A01-x.md"
expect $a "tester may not write outside the repository" block "$D" $T $W $fp "/tmp/elsewhere-r01.txt"
expect $a "tester may not edit a notebook outside the test paths" block "$D" $T NotebookEdit notebook_path "src/n.ipynb"
expect $a "tester may read anything" allow "$D" $T Read $fp "src/main.py"
expect $a "tester Bash redirect into a test file" allow "$D" $T $B $cmd "echo x > a.test.sh"
expect $a "tester Bash redirect into source" block "$D" $T $B $cmd "echo x > src/main.py"
expect $a "tester Bash append into source" block "$D" $T $B $cmd "echo x >> src/main.py"
expect $a "tester Bash sed -i on source" block "$D" $T $B $cmd "sed -i s/a/b/ src/main.py"
expect $a "tester Bash rm of a spec file" block "$D" $T $B $cmd "rm SPEC.md"
expect $a "tester Bash cp into source" block "$D" $T $B $cmd "cp a.test.sh src/b.py"
expect $a "tester Bash cp into a test file" allow "$D" $T $B $cmd "cp a.test.sh b.test.sh"
expect $a "tester Bash tee into source" block "$D" $T $B $cmd "echo x | tee src/main.py"
expect $a "tester Bash running a test is allowed" allow "$D" $T $B $cmd "sh scheduler/loop.test.sh"
expect $a "tester Bash git diff is allowed" allow "$D" $T $B $cmd "git diff --stat"

# ---------- implementer, defaults ----------
expect $a "implementer may write source" allow "$D" $I $W $fp "src/main.py"
expect $a "implementer may write source (absolute path)" allow "$D" $I $E $fp "$D/src/main.py"
expect $a "implementer may not write a *.test.sh" block "$D" $I $W $fp "scheduler/x.test.sh"
expect $a "implementer may not write a tests/ file" block "$D" $I $E $fp "$D/pkg/tests/t.py"
expect $a "implementer may not write testdata" block "$D" $I $W $fp "scheduler/testdata/f.txt"
expect $a "implementer may not write fixtures" block "$D" $I $W $fp "fixtures/a.json"
expect $a "implementer may not write SPEC.md" block "$D" $I $W $fp "SPEC.md"
expect $a "implementer may not write AGENTS.md" block "$D" $I $E $fp "AGENTS.md"
expect $a "implementer may not write docs/graph.yaml" block "$D" $I $E $fp "docs/graph.yaml"
expect $a "implementer may not write nodes/" block "$D" $I $W $fp "$D/nodes/A01-x.md"
expect $a "implementer may not edit a notebook under tests/" block "$D" $I NotebookEdit notebook_path "tests/n.ipynb"
expect $a "implementer may edit a notebook elsewhere" allow "$D" $I NotebookEdit notebook_path "src/n.ipynb"
expect $a "implementer Bash redirect into source" allow "$D" $I $B $cmd "echo x > src/main.py"
expect $a "implementer Bash redirect into a test" block "$D" $I $B $cmd "echo x > a.test.sh"
expect $a "implementer Bash sed -i on a test" block "$D" $I $B $cmd "sed -i s/a/b/ scheduler/x.test.sh"
expect $a "implementer Bash sed -i on source" allow "$D" $I $B $cmd "sed -i s/a/b/ src/main.py"
expect $a "implementer Bash rm of a spec" block "$D" $I $B $cmd "rm nodes/A01-x.md"
expect $a "implementer Bash cp into a tests/ dir" block "$D" $I $B $cmd "cp src/a.py tests/b.py"
expect $a "implementer Bash cp within source" allow "$D" $I $B $cmd "cp src/a.py src/b.py"
expect $a "implementer Bash running tests is allowed" allow "$D" $I $B $cmd "make test"

# ---------- reviewer ----------
expect $a "reviewer may not Write source" block "$D" $V $W $fp "src/main.py"
expect $a "reviewer may not Edit a test" block "$D" $V $E $fp "x.test.sh"
expect $a "reviewer may not Write outside the repository" block "$D" $V $W $fp "/tmp/anything-r01.txt"
expect $a "reviewer may not NotebookEdit" block "$D" $V NotebookEdit notebook_path "n.ipynb"
expect $a "reviewer may Read" allow "$D" $V Read $fp "src/main.py"
expect $a "reviewer Bash redirect into the repository" block "$D" $V $B $cmd "echo x > out.txt"
expect $a "reviewer Bash sed -i in the repository" block "$D" $V $B $cmd "sed -i s/a/b/ src/main.py"
expect $a "reviewer Bash rm in the repository" block "$D" $V $B $cmd "rm src/main.py"
expect $a "reviewer Bash cp into the repository" block "$D" $V $B $cmd "cp /tmp/x $D/src/y.py"
expect $a "reviewer Bash touch in the repository" block "$D" $V $B $cmd "touch new.txt"
expect $a "reviewer Bash git add" block "$D" $V $B $cmd "git add -A"
expect $a "reviewer Bash git commit" block "$D" $V $B $cmd "git commit -m x"
expect $a "reviewer Bash git stash" block "$D" $V $B $cmd "git stash"
expect $a "reviewer Bash git checkout -b" block "$D" $V $B $cmd "git checkout -b other"
expect $a "reviewer Bash running a test command is allowed" allow "$D" $V $B $cmd "sh scheduler/loop.test.sh"
expect $a "reviewer Bash make test is allowed" allow "$D" $V $B $cmd "make test"
expect $a "reviewer Bash git diff is allowed" allow "$D" $V $B $cmd "git diff main...HEAD"
expect $a "reviewer Bash git show is allowed" allow "$D" $V $B $cmd "git show HEAD"
expect $a "reviewer Bash grep is allowed" allow "$D" $V $B $cmd "grep -rn foo ."
expect $a "reviewer Bash writing under a temp dir outside the repository is allowed" allow "$D" $V $B $cmd "echo x > $tmp/scratch/out.txt"
expect $a "reviewer Bash mkdir under a temp dir outside the repository is allowed" allow "$D" $V $B $cmd "mkdir -p $tmp/scratch/sub"

# ---------- roles.yaml replaces the defaults ----------
expect $a "custom: tester may write a configured test path" allow "$C" $T $W $fp "spec_tests/a.txt"
expect $a "custom: tester may write a configured glob" allow "$C" $T $W $fp "deep/er/x.chk"
expect $a "custom: tester may not write a default test path that was replaced" block "$C" $T $W $fp "x.test.sh"
expect $a "custom: tester may not write a configured spec path" block "$C" $T $W $fp "contracts/c.md"
expect $a "custom: implementer may not write a configured test path" block "$C" $I $W $fp "spec_tests/a.txt"
expect $a "custom: implementer may not write a configured test glob" block "$C" $I $E $fp "$C/deep/x.chk"
expect $a "custom: implementer may not write a configured spec path" block "$C" $I $W $fp "contracts/c.md"
expect $a "custom: implementer may write a default test path that was replaced" allow "$C" $I $W $fp "x.test.sh"
expect $a "custom: implementer may write a default spec path that was replaced" allow "$C" $I $W $fp "SPEC.md"
expect $a "custom: reviewer still writes nothing" block "$C" $V $W $fp "spec_tests/a.txt"
expect $a "custom: Bash redirect by implementer into a configured test path" block "$C" $I $B $cmd "echo x > spec_tests/a.txt"
expect $a "part (tests only): tester may write the configured tests" allow "$P" $T $W $fp "spec_tests/a.txt"
expect $a "part (tests only): implementer may not write the default specs" block "$P" $I $W $fp "SPEC.md"
expect $a "part (tests only): implementer may write a default test path that was replaced" allow "$P" $I $W $fp "x.test.sh"

# ---------- repository root from cwd ----------
expect $a "root from cwd: roles.yaml applies (implementer, configured test path)" block "$C" $I $W $fp "spec_tests/a.txt" 1
expect $a "root from cwd: roles.yaml applies (implementer, replaced default)" allow "$C" $I $W $fp "x.test.sh" 1
expect $a "root from cwd: relative path (tester, source)" block "$D" $T $W $fp "src/main.py" 1

# ---------- git commit with staged paths ----------
staged() {  # staged <dir> <path> : fresh repo with <path> staged
	mkrepo "$1"; mkdir -p "$1/$(dirname "$2")"; echo x >"$1/$2"; git -C "$1" add "$2" 2>/dev/null
}
G="$tmp/gc"
staged "$G" src/a.py;      expect $a "tester git commit with staged source" block "$G" $T $B $cmd "git commit -m x"
staged "$G" a.test.sh;     expect $a "tester git commit with only staged tests" allow "$G" $T $B $cmd "git commit -m x"
staged "$G" SPEC.md;       expect $a "tester git commit with staged spec" block "$G" $T $B $cmd "git commit -m x"
staged "$G" a.test.sh;     expect $a "implementer git commit with staged test" block "$G" $I $B $cmd "git commit -m x"
staged "$G" SPEC.md;       expect $a "implementer git commit with staged spec" block "$G" $I $B $cmd "git commit -m x"
staged "$G" src/a.py;      expect $a "implementer git commit with staged source" allow "$G" $I $B $cmd "git commit -m x"
staged "$G" src/a.py;      expect $a "reviewer git commit" block "$G" $V $B $cmd "git commit -m x"
staged "$G" src/a.py; echo y >"$G/b.test.sh"; git -C "$G" add b.test.sh
expect $a "tester git commit with a mix of test and source staged" block "$G" $T $B $cmd "git commit -m x"
expect $a "implementer git commit with a mix of test and source staged" block "$G" $I $B $cmd "git commit -m x"
staged "$G" src/a.py;      expect $a "main session git commit is allowed" allow "$G" - $B $cmd "git commit -m x"

# ---------- not a plugin role agent: allowed ----------
expect $a "no agent_type: Write to SPEC.md" allow "$D" - $W $fp "SPEC.md"
expect $a "no agent_type: Bash redirect into a test" allow "$D" - $B $cmd "echo x > a.test.sh"
expect $a "non-plugin agent_type: reviewer-like agent writes" allow "$D" "other:reviewer" $W $fp "src/main.py"
expect $a "bare agent_type 'reviewer' (not plugin-scoped) is not a role" allow "$D" reviewer $W $fp "src/main.py"
expect $a "a repository's own implementer writes a test" allow "$D" monolith-implementer $W $fp "x.test.sh"
expect $a "unknown noodlebot agent is not a role" allow "$D" noodlebot:other $W $fp "SPEC.md"

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: all guard checks"
