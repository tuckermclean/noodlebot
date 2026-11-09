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

# ---------- fd redirects after a write command ----------
expect $a "tester mkdir -p with 2>/dev/null is a test-path write" allow "$D" $T $B $cmd "mkdir -p tests/foo 2>/dev/null"
expect $a "tester touch with 2>&1 is a test-path write" allow "$D" $T $B $cmd "touch tests/a.test.sh 2>&1"
expect $a "reviewer rm of a scratch path outside the repository with 2>/dev/null" allow "$D" $V $B $cmd "rm -rf $tmp/scratch/x 2>/dev/null"
expect $a "reviewer mkdir under scratch outside the repository with 2>/dev/null" allow "$D" $V $B $cmd "mkdir -p $tmp/scratch/y 2>/dev/null"
expect $a "implementer cp into tests/ with 2>&1" block "$D" $I $B $cmd "cp src/a.py tests/b.py 2>&1"

# ---------- sed scripts given with -e ----------
expect $a "tester sed -i -e on a test file" allow "$D" $T $B $cmd "sed -i -e s/a/b/ tests/a.test.sh"
expect $a "implementer sed -i -e on a test file" block "$D" $I $B $cmd "sed -i -e s/a/b/ scheduler/x.test.sh"
expect $a "implementer sed -i -e on source" allow "$D" $I $B $cmd "sed -i -e s/a/b/ src/main.py"

# ---------- directory operands ----------
expect $a "implementer rm -rf of the tests directory" block "$D" $I $B $cmd "rm -rf tests"
expect $a "implementer rm -rf of nodes/ with a trailing slash" block "$D" $I $B $cmd "rm -rf nodes/"
expect $a "implementer cp -t into the tests directory" block "$D" $I $B $cmd "cp -t tests src/a.py"
expect $a "implementer rm -rf of a source directory" allow "$D" $I $B $cmd "rm -rf src"

# ---------- add and commit in one call ----------
G2="$tmp/gc2"
mkrepo "$G2"; mkdir -p "$G2/src"; echo x >"$G2/src/a.py"
expect $a "tester git add source && git commit in one call" block "$G2" $T $B $cmd "git add src/a.py && git commit -m x"
expect $a "implementer git add a test && git commit in one call" block "$G2" $I $B $cmd "git add a.test.sh && git commit -m x"
expect $a "implementer git add source && git commit in one call" allow "$G2" $I $B $cmd "git add src/a.py && git commit -m x"
G3="$tmp/gc3"
mkrepo "$G3"; echo x >"$G3/a.test.sh"; echo x >"$G3/s.py"
git -C "$G3" add -A 2>/dev/null
git -C "$G3" -c user.name=t -c user.email=t@t commit -qm init 2>/dev/null
echo y >>"$G3/a.test.sh"
expect $a "implementer git commit -am with a modified tracked test" block "$G3" $I $B $cmd "git commit -am x"
expect $a "implementer git commit with a test pathspec" block "$G3" $I $B $cmd "git commit -m x a.test.sh"

# ---------- heredoc bodies are data (item 8) ----------
nl='
'
expect $a "reviewer python3 - heredoc whose body has a > comparison" allow "$D" $V $B $cmd "python3 - <<'EOF'${nl}for i in range(3):${nl}    if i > 1: print(i)${nl}EOF"
expect $a "tester python3 - heredoc whose body has a > comparison" allow "$D" $T $B $cmd "python3 - <<'EOF'${nl}if 2 > 1: print(1)${nl}EOF"
expect $a "implementer python3 - heredoc whose body has a > comparison" allow "$D" $I $B $cmd "python3 - <<'EOF'${nl}if 2 > 1: print(1)${nl}EOF"
expect $a "reviewer cat > scratch file outside the repository <<EOF with > in the body" allow "$D" $V $B $cmd "cat > $tmp/scratch/p.py <<'EOF'${nl}if 2 > 1: print(1)${nl}EOF"
expect $a "reviewer unquoted <<EOF body naming a repository path after >" allow "$D" $V $B $cmd "cat <<EOF${nl}echo x > src/main.py${nl}EOF"
expect $a "reviewer <<-EOF with tab-indented terminator and a > in the body" allow "$D" $V $B $cmd "python3 - <<-EOF${nl}	if 2 > 1: print(1)${nl}	EOF"
expect $a "reviewer <<\"EOF\" with a > in the body" allow "$D" $V $B $cmd "python3 - <<\"EOF\"${nl}if 2 > 1: print(1)${nl}EOF"
expect $a "tester <<-'EOF' body redirect to source is data" allow "$D" $T $B $cmd "cat <<-'EOF'${nl}echo x > src/main.py${nl}EOF"
expect $a "implementer cat > tests/x.test.sh <<'EOF' is still judged" block "$D" $I $B $cmd "cat > tests/x.test.sh <<'EOF'${nl}echo hi${nl}EOF"
expect $a "implementer cat > src file <<'EOF' is allowed" allow "$D" $I $B $cmd "cat > src/x.py <<'EOF'${nl}if 2 > 1: print(1)${nl}EOF"
expect $a "tester cat > src/x.py <<EOF is still judged" block "$D" $T $B $cmd "cat > src/x.py <<EOF${nl}x${nl}EOF"
expect $a "reviewer cat > repo file <<-\"EOF\" is still judged" block "$D" $V $B $cmd "cat > out.txt <<-\"EOF\"${nl}x${nl}EOF"
expect $a "reviewer write after a heredoc ends is still judged" block "$D" $V $B $cmd "cat <<'EOF'${nl}x${nl}EOF${nl}echo y > out.txt"

# ---------- cd / pushd earlier in the same Bash call (item 9) ----------
expect $a "reviewer cd scratch && run test with > red.log" allow "$D" $V $B $cmd "cd $tmp/scratch && sh x.test.sh > red.log 2>&1"
expect $a "reviewer cd \$(mktemp -d) && echo > out.txt" allow "$D" $V $B $cmd 'cd $(mktemp -d) && echo hi > out.txt'
expect $a "reviewer cd \$VAR && echo > out.txt (unknown dir)" allow "$D" $V $B $cmd 'cd $SCR && echo hi > out.txt'
expect $a "reviewer cd - && echo > out.txt (unknown dir)" allow "$D" $V $B $cmd 'cd - && echo hi > out.txt'
expect $a "implementer cd tests && echo > a.test.sh" block "$D" $I $B $cmd "cd tests && echo x > a.test.sh"
expect $a "implementer cd src && echo > a.py" allow "$D" $I $B $cmd "cd src && echo x > a.py"
expect $a "tester cd tests && echo > b.test.sh" allow "$D" $T $B $cmd "cd tests && echo x > b.test.sh"
expect $a "tester cd src && echo > a.py" block "$D" $T $B $cmd "cd src && echo x > a.py"
expect $a "implementer cd absolute tests dir && echo > a.sh" block "$D" $I $B $cmd "cd $D/tests && echo x > a.sh"
expect $a "implementer cd tests; echo > a.test.sh (semicolon)" block "$D" $I $B $cmd "cd tests; echo x > a.test.sh"
expect $a "implementer cd src; echo > a.py (semicolon)" allow "$D" $I $B $cmd "cd src; echo x > a.py"
expect $a "reviewer cd scratch; echo > out.txt (semicolon)" allow "$D" $V $B $cmd "cd $tmp/scratch; echo hi > out.txt"
expect $a "implementer cd tests on its own line then a write" block "$D" $I $B $cmd "cd tests${nl}echo x > a.test.sh"
expect $a "reviewer cd scratch on its own line then a write" allow "$D" $V $B $cmd "cd $tmp/scratch${nl}echo hi > out.txt"
expect $a "implementer cd tests || true then a write" block "$D" $I $B $cmd "cd tests || exit 1; echo x > a.test.sh"
expect $a "implementer pushd tests && echo > a.test.sh" block "$D" $I $B $cmd "pushd tests >/dev/null && echo x > a.test.sh"
expect $a "implementer pushd src && echo > a.py" allow "$D" $I $B $cmd "pushd src >/dev/null && echo x > a.py"
expect $a "reviewer pushd scratch && echo > out.txt" allow "$D" $V $B $cmd "pushd $tmp/scratch >/dev/null && echo hi > out.txt"
expect $a "implementer cd a && cd b relative chain into tests/sub" block "$D" $I $B $cmd "cd tests && cd sub && echo x > a.py"
expect $a "reviewer cd into the repository && write is still blocked" block "$D" $V $B $cmd "cd $D/src && echo x > a.py"
expect $a "reviewer without cd: relative write still blocked" block "$D" $V $B $cmd "echo hi > out.txt"

# ---------- read-only git stash for the reviewer (item 10) ----------
expect $a "reviewer git stash list is allowed" allow "$D" $V $B $cmd "git stash list"
expect $a "reviewer git stash show is allowed" allow "$D" $V $B $cmd "git stash show"
expect $a "reviewer git stash show -p stash@{0} is allowed" allow "$D" $V $B $cmd "git stash show -p stash@{0}"
expect $a "reviewer git stash pop is blocked" block "$D" $V $B $cmd "git stash pop"
expect $a "reviewer git stash push is blocked" block "$D" $V $B $cmd "git stash push -m x"
expect $a "reviewer git stash drop is blocked" block "$D" $V $B $cmd "git stash drop"
expect $a "reviewer git stash apply is blocked" block "$D" $V $B $cmd "git stash apply"
expect $a "reviewer git stash after git stash list is blocked" block "$D" $V $B $cmd "git stash list && git stash"

# ---------- .noodlebot/roles.yaml is always a spec path (item 11) ----------
expect $a "implementer Write .noodlebot/roles.yaml (defaults)" block "$D" $I $W $fp ".noodlebot/roles.yaml"
expect $a "implementer Write .noodlebot/roles.yaml (absolute path)" block "$D" $I $W $fp "$D/.noodlebot/roles.yaml"
expect $a "implementer Edit .noodlebot/roles.yaml (custom roles.yaml)" block "$C" $I $E $fp ".noodlebot/roles.yaml"
expect $a "implementer Write .noodlebot/roles.yaml (tests-only roles.yaml)" block "$P" $I $W $fp ".noodlebot/roles.yaml"
expect $a "implementer Bash redirect into .noodlebot/roles.yaml" block "$D" $I $B $cmd "echo x > .noodlebot/roles.yaml"
expect $a "implementer Bash redirect into .noodlebot/roles.yaml (custom)" block "$C" $I $B $cmd "echo x > .noodlebot/roles.yaml"
expect $a "tester Write .noodlebot/roles.yaml (defaults)" block "$D" $T $W $fp ".noodlebot/roles.yaml"
expect $a "tester Write .noodlebot/roles.yaml (custom roles.yaml)" block "$C" $T $W $fp ".noodlebot/roles.yaml"
expect $a "tester Bash redirect into .noodlebot/roles.yaml" block "$D" $T $B $cmd "echo x > .noodlebot/roles.yaml"
expect $a "reviewer Write .noodlebot/roles.yaml" block "$D" $V $W $fp ".noodlebot/roles.yaml"
expect $a "implementer may still write another file under .noodlebot/" allow "$D" $I $W $fp ".noodlebot/notes.txt"


# ---------- quoting: only unquoted operators count (item 12) ----------
expect $a "reviewer grep -n '>' file (quoted >)" allow "$D" $V $B $cmd "grep -n '>' plugin/hooks/guard.py"
expect $a "reviewer grep -rn \"> \" src (double-quoted >)" allow "$D" $V $B $cmd 'grep -rn "> " src'
expect $a "reviewer awk -F '>' (quoted > field separator)" allow "$D" $V $B $cmd "awk -F '>' '{print \$1}' src/a.txt"
expect $a "tester grep -n '>' src/main.py" allow "$D" $T $B $cmd "grep -n '>' src/main.py"
expect $a "implementer grep -c '>>' tests/a.test.sh" allow "$D" $I $B $cmd "grep -c '>>' tests/a.test.sh"
expect $a "reviewer quoted ; && | ( ) are words" allow "$D" $V $B $cmd "grep -n 'a; b && c | (d)' src/a.py"
expect $a "reviewer here-string <<< starts no heredoc; next line still judged" block "$D" $V $B $cmd "grep foo <<< \"\$v\"${nl}echo x > src/out.txt"
expect $a "reviewer quoted \"a << b\" starts no heredoc; next line still judged" block "$D" $V $B $cmd "echo \"a << b\"${nl}echo x > src/out.txt"
expect $a "implementer quoted '<<' starts no heredoc; next line writes a test" block "$D" $I $B $cmd "echo 'a << b'${nl}echo x > tests/a.test.sh"
expect $a "implementer a quoted > before a real redirect to a test is still judged" block "$D" $I $B $cmd "echo '>' > tests/a.test.sh"

# ---------- cd inside a subshell holds to the matching ) (item 13) ----------
expect $a "implementer (cd tests && ls) ; echo > src/foo.py" allow "$D" $I $B $cmd "(cd tests && ls) ; echo x > src/foo.py"
expect $a "implementer x=\$(cd tests && pwd); echo > src/foo.py" allow "$D" $I $B $cmd 'x=$(cd tests && pwd); echo x > src/foo.py'
expect $a "implementer (cd /tmp && ls) ; echo > tests/a.test.sh" block "$D" $I $B $cmd "(cd /tmp && ls) ; echo x > tests/a.test.sh"
expect $a "implementer cd inside a subshell still applies within it" block "$D" $I $B $cmd "(cd tests && echo x > a.test.sh)"
expect $a "reviewer (cd scratch && echo > out.txt) is outside the repository" allow "$D" $V $B $cmd "(cd $tmp/scratch && echo hi > out.txt)"
expect $a "reviewer (cd scratch) ; echo > out.txt writes the repository root" block "$D" $V $B $cmd "(cd $tmp/scratch) ; echo hi > out.txt"

# ---------- line continuation joins lines (item 14) ----------
G4="$tmp/gc4"; staged "$G4" src/a.py; echo y >"$G4/a.test.sh"
expect $a "implementer git add src/a.py \\ newline tests/a.test.sh && git commit" block "$G4" $I $B $cmd "git add src/a.py \\${nl} a.test.sh && git commit -m x"
expect $a "implementer git add src/a.py \\ newline src/b.py && git commit" allow "$G4" $I $B $cmd "git add src/a.py \\${nl} src/b.py && git commit -m x"
expect $a "tester echo > \\ newline tests file" allow "$D" $T $B $cmd "echo x > \\${nl}a.test.sh"
expect $a "tester echo > \\ newline source file" block "$D" $T $B $cmd "echo x > \\${nl}src/a.py"

# ---------- git in another repository is not judged (item 15) ----------
S="$tmp/scratch/other"; mkrepo "$S"; mkdir -p "$tmp/scratch/o2"
G5="$tmp/gc5"; staged "$G5" a.test.sh
expect $a "tester cd scratch && git init && git add && git commit" allow "$D" $T $B $cmd "cd $tmp/scratch/o2 && git init -q && echo x > a.py && git add a.py && git commit -qm x"
expect $a "tester cd scratch && git add a.py && git commit (scratch repo)" allow "$D" $T $B $cmd "cd $S && echo x > a.py && git add a.py && git commit -qm x"
expect $a "tester git -C scratch commit" allow "$D" $T $B $cmd "git -C $S commit -qm x"
expect $a "tester git -C scratch add a.py" allow "$D" $T $B $cmd "git -C $S add a.py"
expect $a "implementer git -C scratch commit while its own repo has a staged test" allow "$G5" $I $B $cmd "git -C $S commit -qm x"
expect $a "implementer git -C <repo>/ commit with a staged test" block "$G5" $I $B $cmd "git -C $G5/ commit -qm x"
expect $a "implementer git -C <repo> commit with a staged test" block "$G5" $I $B $cmd "git -C $G5 commit -qm x"
expect $a "implementer cd <repo> && git commit with a staged test" block "$G5" $I $B $cmd "cd $G5 && git commit -qm x"
expect $a "reviewer git -C scratch commit" allow "$D" $V $B $cmd "git -C $S commit -qm x"
expect $a "reviewer git -C <repo> commit" block "$G5" $V $B $cmd "git -C $G5 commit -qm x"
if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: all guard checks"
