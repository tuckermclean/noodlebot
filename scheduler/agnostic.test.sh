#!/bin/sh
# The core check, harness rules (S08, change 6): the tracked .sh and .py files under scheduler/ and plugin/ name no
# harness, so a second harness needs no change to core. It passes on the tree and fails, naming file and line, on each
# planted form in a scratch copy. (G04 adds its forge rules to this file when it merges.)
#   sh scheduler/agnostic.test.sh   (make test)
#
# What is scanned: tracked .sh/.py under scheduler/ and plugin/, except *.test.sh, scheduler/testdata/,
# scheduler/harnesses/claude_code.py (the Claude Code backend) and plugin/hooks/ (the role guard is R02's).
# What is a comment, and so ignored:
#   .sh  a '#' that starts a word outside quotes, whole-line or trailing ('${#x}', '$#', "#" and 'a#b' are not comments;
#        quotes are tracked across lines; a heredoc body is code, except its whole-line '#' lines);
#   .py  every COMMENT token (python's tokenizer, so '#' inside strings is safe) and every docstring (a string
#        statement on its own), whole or multi-line.
# What fails (each outside comments):
#   - a 'claude' command: at the start of a line or after | ; & a backquote or $( , optionally behind exec, setsid,
#     nohup, command [-v], which, env, sudo, time, timeout N, then/do/else or VAR=x, in a .sh outside single quotes;
#     'claude -p' anywhere in code (also inside a string); in a .py, "claude" or 'claude' as an element of an
#     argument list (after [ ( or , and before , ] or ) ). The word in prose inside a string ("the resumed claude
#     wrote no init line") and a path such as .claude/skills are not commands.
#   - a CLAUDE_CODE_ name, stream-json, --plugin-dir, --append-system-prompt, and the field names rate_limit_event,
#     rate_limit_info, total_cost_usd, num_turns, anywhere outside comments (strings included).
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
root=$(cd "$src/.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

cat >"$tmp/scan.py" <<'PY'
import io, re, sys, tokenize

root = sys.argv[1]
EXEMPT_PREFIX = ("scheduler/testdata/", "plugin/hooks/")
EXEMPT_FILE = ("scheduler/harnesses/claude_code.py",)
GLOBAL = [("CLAUDE_CODE_ name", r"CLAUDE_CODE_"), ("stream-json", r"stream-json"), ("--plugin-dir", r"--plugin-dir"),
          ("--append-system-prompt", r"--append-system-prompt"), ("rate_limit_event", r"rate_limit_event"),
          ("rate_limit_info", r"rate_limit_info"), ("total_cost_usd", r"total_cost_usd"), ("num_turns", r"num_turns"),
          ("claude command line (claude -p)", r"(?<![\w.\-/])claude\s+-p\b")]
PRE = r"(?:(?:exec|setsid|nohup|command\s+-v|command|which|env|sudo|time|then|do|else|!)\s+|timeout\s+\S+\s+|\w+=\S*\s+)*"
SH_CMD = re.compile(r"(?:^\s*\(?|[|;&`]|\$\()\s*" + PRE + r"claude(?=\s|$|[;|&)`])")
PY_ARG = re.compile(r"(?:^|[\[(,])\s*[\"']claude[\"']\s*[,\])]")
HEREDOC = re.compile(r"<<(-?)\s*(['\"]?)(\w+)\2")

def sh_lines(text):
    """Yield (lineno, code, cmd): code has comments cut; cmd also has single-quoted text blanked."""
    state, term, strip_tabs = None, None, False
    for no, line in enumerate(text.split("\n"), 1):
        if term is not None:
            if (line.lstrip("\t") if strip_tabs else line) == term:
                term = None
            elif not line.lstrip().startswith("#"):
                yield no, line, line
            continue
        code, cmd, i, n = [], [], 0, len(line)
        while i < n:
            c = line[i]
            if state == "'":
                code.append(c); cmd.append(" ")
                if c == "'": state = None
            elif state == '"':
                code.append(c); cmd.append(c)
                if c == "\\" and i + 1 < n:
                    i += 1; code.append(line[i]); cmd.append(line[i])
                elif c == '"': state = None
            else:
                if c == "\\" and i + 1 < n:
                    code.append(c + line[i + 1]); cmd.append(c + line[i + 1]); i += 2; continue
                if c == "#" and (i == 0 or line[i - 1] in " \t;|&("):
                    break
                if c == "'": state = "'"
                elif c == '"': state = '"'
                code.append(c); cmd.append(c)
            i += 1
        code, cmd = "".join(code), "".join(cmd)
        m = HEREDOC.search(cmd.replace("<<<", "   "))
        if m and state is None:
            term, strip_tabs = m.group(3), m.group(1) == "-"
        yield no, code, cmd

def py_lines(text):
    """Yield (lineno, code): comments and docstrings blanked, strings kept."""
    lines = text.split("\n")
    buf = [list(l) for l in lines]
    def blank(a, b):
        (r1, c1), (r2, c2) = a, b
        for r in range(r1, r2 + 1):
            row = buf[r - 1]
            lo = c1 if r == r1 else 0
            hi = c2 if r == r2 else len(row)
            for k in range(lo, min(hi, len(row))):
                row[k] = " "
    prev = None
    toks = list(tokenize.generate_tokens(io.StringIO(text).readline))
    for idx, t in enumerate(toks):
        if t.type == tokenize.COMMENT:
            blank(t.start, t.end)
        elif t.type == tokenize.STRING and prev in (None, tokenize.NEWLINE, tokenize.INDENT, tokenize.DEDENT):
            nxt = toks[idx + 1].type if idx + 1 < len(toks) else None
            if nxt in (tokenize.NEWLINE, tokenize.ENDMARKER):
                blank(t.start, t.end)
        if t.type not in (tokenize.NL, tokenize.COMMENT):
            prev = t.type
    for no, row in enumerate(buf, 1):
        yield no, "".join(row)

bad = 0
for rel in sys.stdin.read().split("\n"):
    if not rel or not rel.endswith((".sh", ".py")) or not rel.startswith(("scheduler/", "plugin/")):
        continue
    if rel.endswith(".test.sh") or rel.startswith(EXEMPT_PREFIX) or rel in EXEMPT_FILE:
        continue
    try:
        text = open(root + "/" + rel, encoding="utf-8").read()
        rows = ((no, code, cmd) for no, code, cmd in sh_lines(text)) if rel.endswith(".sh") \
            else ((no, code, None) for no, code in py_lines(text))
        for no, code, cmd in rows:
            hits = [name for name, rx in GLOBAL if re.search(rx, code)]
            if cmd is not None and SH_CMD.search(cmd):
                hits.append("claude command")
            if cmd is None and PY_ARG.search(code):
                hits.append("claude command (argument list)")
            for h in hits:
                print("%s:%d: %s: %s" % (rel, no, h, code.strip()[:100]))
                bad += 1
    except (OSError, SyntaxError, tokenize.TokenError, UnicodeDecodeError) as e:
        print("%s:0: cannot scan: %s" % (rel, e))
        bad += 1
sys.exit(1 if bad else 0)
PY
# scan <root>: the file list on stdin, one relative path per line; findings (file:line: rule: text) on stdout.
scan() { python3 -I "$tmp/scan.py" "$1"; }

# S08-AC-7: the check passes on the tree.
out=$(cd "$root" && git ls-files scheduler plugin | scan "$root"); rc=$?
if [ $rc = 0 ]; then pass "S08-AC-7: the core check passes on the tree"
else fail "S08-AC-7: the core check finds harness forms in the tree:
$out"; fi

# A scratch copy of the tracked scripts; planted forms go in here, never in the tree.
sc=$tmp/sc
mkdir -p "$sc"
(cd "$root" && git ls-files scheduler plugin | grep -E '\.(sh|py)$' | tar -cf - -T -) | tar -xf - -C "$sc"
plant() { mkdir -p "$(dirname "$sc/$1")"; cat >"$sc/$1"; }
# expect <rel> <line> <what>: the scan of <rel> alone names that file and line.
expect() {
	printf "%s\n" "$1" | scan "$sc" >"$tmp/o" 2>&1
	if grep -q "^$1:$2: " "$tmp/o"; then pass "S08-AC-7: a planted $3 fails, naming $1:$2"; else fail "S08-AC-7: planted $3 not named at $1:$2 (got: $(cat "$tmp/o"))"; fi
}
# quiet <rel> <what>: the scan of <rel> alone passes.
quiet() {
	if printf '%s\n' "$1" | scan "$sc" >"$tmp/o" 2>&1; then pass "S08-AC-7: $2 passes"; else fail "S08-AC-7: $2 was flagged: $(cat "$tmp/o")"; fi
}

plant scheduler/plant.sh <<'EOF2'
#!/bin/sh
claude -p hi
echo x | claude --resume y
echo a; claude foo
true && claude foo
false || claude foo
x=$(claude -v)
y=`claude -v`
exec claude foo
setsid claude foo
timeout 30 claude foo
if true; then claude foo; fi
echo "run: claude -p /node X"
echo "$CLAUDE_CODE_OAUTH_TOKEN"
run --output-format stream-json
run --plugin-dir p
run --append-system-prompt p
grep rate_limit_event f
grep rate_limit_info f
grep total_cost_usd f
grep num_turns f
EOF2
n=1
for what in "claude command at line start" "claude command after a pipe" "claude command after ;" "claude command after &&" \
	"claude command after ||" 'claude command in $(' "claude command in backquotes" "claude command after exec" \
	"claude command after setsid" "claude command after timeout N" "claude command after then" "claude -p inside a string" \
	"CLAUDE_CODE_ name" "stream-json" "--plugin-dir" "--append-system-prompt" "rate_limit_event" "rate_limit_info" \
	"total_cost_usd" "num_turns"; do
	n=$((n + 1)); expect scheduler/plant.sh $n ".sh $what"
done

plant scheduler/plant.py <<'EOF2'
import subprocess
subprocess.run(["claude", "-p", "hi"])
subprocess.run(['claude', "x"])
subprocess.run(
    "claude",
    "x")
os.environ["CLAUDE_CODE_OAUTH_TOKEN"] = t
f = "--output-format=stream-json"
g = ["--plugin-dir", p]
h = ["--append-system-prompt", p]
e.get("rate_limit_event")
e.get("rate_limit_info")
e.get("total_cost_usd")
e.get("num_turns")
os.system("claude -p /node X")
EOF2
set -- 2 3 5 7 8 9 10 11 12 13 14 15
w1='claude in an argument list (double quotes)'; w2='claude in an argument list (single quotes)'
i=0
for what in "$w1" "$w2" "claude on its own line in an argument list" "CLAUDE_CODE_ name" "stream-json" "--plugin-dir" \
	"--append-system-prompt" "rate_limit_event" "rate_limit_info" "total_cost_usd" "num_turns" "claude -p inside a string"; do
	i=$((i + 1)); ln=$(eval "echo \${$i}");
	expect scheduler/plant.py "$ln" ".py $what"
done

# Mentions in comments, docstrings and prose are not commands; exempt places are not scanned.
plant scheduler/ok.sh <<'EOF2'
#!/bin/sh
# claude -p /node X, stream-json, rate_limit_event, CLAUDE_CODE_TOKEN, --plugin-dir, num_turns
echo hi # claude -p, total_cost_usd, rate_limit_info, --append-system-prompt
x=abc; echo "${#x} $# a#b" "#" 'claude is # here' # trailing claude -p
git cat-file -e origin/main:.claude/skills/node/SKILL.md
echo "the resumed claude wrote no init line"
cat <<'TXT'
# claude -p in a heredoc comment line
TXT
EOF2
quiet scheduler/ok.sh "a .sh with mentions in comments, a .claude/skills path, prose and '#' in strings"
plant scheduler/ok.py <<'EOF2'
"""A module docstring: claude -p, stream-json, rate_limit_event, ["claude", "x"]."""
import re
def f(x):
    """Docstring over
    two lines: CLAUDE_CODE_X, num_turns, total_cost_usd."""
    # ["claude", "-p"], --plugin-dir, rate_limit_info
    y = "a # b"  # trailing: --append-system-prompt claude -p
    z = "the resumed claude wrote no init line"
    w = ".claude/skills/node"
    return y, z, w, x == "claude"
EOF2
quiet scheduler/ok.py "a .py with mentions in comments and docstrings, prose, a .claude path and '#' in strings"
for rel in scheduler/testdata/p.sh scheduler/testdata/p.py scheduler/harnesses/claude_code.py plugin/hooks/p.py plugin/hooks/p.sh \
	scheduler/p.test.sh; do
	case $rel in *.py) printf 'x = ["claude", "-p", "stream-json", "rate_limit_event"]\n' | plant "$rel" ;;
	*) printf 'claude -p --output-format stream-json\n' | plant "$rel" ;; esac
	quiet "$rel" "planted forms in the exempt $rel"
done
printf 'claude -p\n' | plant plugin/skills/p.sh
expect plugin/skills/p.sh 1 "claude command under plugin/ (outside plugin/hooks/)"

# ---- G04-AC-5 (change 4): the forge rules. Core names no forge: no 'gh' command and no github.com URL outside comments,
# *.test.sh, scheduler/testdata/ and scheduler/forges/github.py (the GitHub backend). Comments are the same as S08's
# above: scan2.py is S08's scanner functions (sh_lines, py_lines, copied from scan.py) with the forge rules.
{
	cat <<'PY'
import io, re, sys, tokenize

root = sys.argv[1]
EXEMPT_PREFIX = ("scheduler/testdata/",)
EXEMPT_FILE = ("scheduler/forges/github.py",)
URL = re.compile(r"github\.com")
PRE = r"(?:(?:exec|setsid|nohup|command\s+-v|command|which|env|sudo|time|then|do|else|if|elif|while|until|!)\s+|timeout\s+\S+\s+|\w+=(?:\$\((?:[^()]|\([^()]*\))*\)|\"[^\"]*\"|'[^']*'|\S*)\s+)*"
SH_GH = re.compile(r"(?:^\s*\(?|[|;&`]|\$\()\s*" + PRE + r"gh(?=\s|$|[;|&)`])")
PY_GH = re.compile(r"(?:^|[\[(,])\s*[\"']gh[\"']\s*[,\])]")
PY
	sed -n '/^HEREDOC = /,/^bad = 0$/p' "$tmp/scan.py" | sed '$d'
	cat <<'PY'
bad = 0
for rel in sys.stdin.read().split("\n"):
    if not rel or not rel.endswith((".sh", ".py")) or not rel.startswith(("scheduler/", "plugin/")):
        continue
    if rel.endswith(".test.sh") or rel.startswith(EXEMPT_PREFIX) or rel in EXEMPT_FILE:
        continue
    try:
        text = open(root + "/" + rel, encoding="utf-8").read()
        rows = ((no, code, cmd) for no, code, cmd in sh_lines(text)) if rel.endswith(".sh") \
            else ((no, code, None) for no, code in py_lines(text))
        for no, code, cmd in rows:
            hits = []
            if cmd is not None and SH_GH.search(cmd):
                hits.append("gh command")
            if cmd is None and PY_GH.search(code):
                hits.append("gh command (argument list)")
            if URL.search(code):
                hits.append("github.com URL")
            for h in hits:
                print("%s:%d: %s: %s" % (rel, no, h, code.strip()[:100]))
                bad += 1
    except (OSError, SyntaxError, tokenize.TokenError, UnicodeDecodeError) as e:
        print("%s:0: cannot scan: %s" % (rel, e))
        bad += 1
sys.exit(1 if bad else 0)
PY
} >"$tmp/scan2.py"
scan() { python3 -I "$tmp/scan2.py" "$1"; }

out=$(cd "$root" && git ls-files scheduler plugin | scan "$root"); rc=$?
if [ $rc = 0 ]; then pass "G04-AC-5: the core check passes on the tree (no gh command, no github.com URL in core)"
else fail "G04-AC-5: the core check finds forge forms in the tree (file:line):
$out"; fi

# Scratch folders named G04 inside the tmp (the S08 copy $sc stays as it is; the forge plants go in their own copy).
G04=$tmp/G04
sc=$G04/sc
mkdir -p "$sc"
(cd "$root" && git ls-files scheduler plugin | grep -E '\.(sh|py)$' | tar -cf - -T -) | tar -xf - -C "$sc"
g_expect() {
	printf "%s\n" "$1" | scan "$sc" >"$G04/o" 2>&1
	if grep -q "^$1:$2: " "$G04/o"; then pass "G04-AC-5: a planted $3 fails, naming $1:$2"; else fail "G04-AC-5: planted $3 not named at $1:$2 (got: $(cat "$G04/o"))"; fi
}
g_quiet() {
	if printf '%s\n' "$1" | scan "$sc" >"$G04/o" 2>&1; then pass "G04-AC-5: $2 passes"; else fail "G04-AC-5: $2 was flagged: $(cat "$G04/o")"; fi
}
for d in scheduler plugin/skills; do
	b=$(echo "$d" | tr / _)
	plant "$d/g04.sh" <<'EOF2'
#!/bin/sh
gh api repos/o/n
echo x | gh api y
echo a; gh pr list
true && gh pr list
x=$(gh api z)
y=`gh api z`
GH_TOKEN=t gh api z
timeout 30 gh api z
curl https://github.com/o/n/issues/1
if ! GH_TOKEN=x gh pr list; then :; fi
while gh pr list; do :; done
GH_TOKEN=$(tok "$repo" 2>/dev/null) gh pr list
GH_TOKEN="a b" gh pr list
GH_TOKEN='a b' gh pr list
EOF2
	n=1
	for what in "gh command at line start" "gh command after a pipe" "gh command after ;" "gh command after &&" 'gh command in $(' \
		"gh command in backquotes" "gh command behind VAR=x" "gh command behind timeout N" "github.com URL" \
		"gh command behind if ! VAR=x" "gh command behind while" 'gh command behind VAR=$(cmd "arg" 2>/dev/null)' \
		'gh command behind VAR="a b"' "gh command behind VAR='a b'"; do
		n=$((n + 1)); g_expect "$d/g04.sh" $n "$d .sh $what"
	done
	plant "$d/g04.py" <<'EOF2'
import subprocess
subprocess.run(["gh", "api", "x"])
subprocess.run(['gh', "api"])
subprocess.run(
    "gh",
    "api")
url = "https://github.com/o/n/issues/1"
EOF2
	set -- 2 3 5 7
	i=0
	for what in "gh in an argument list (double quotes)" "gh in an argument list (single quotes)" "gh on its own line in an argument list" "github.com URL"; do
		i=$((i + 1)); ln=$(eval "echo \${$i}")
		g_expect "$d/g04.py" "$ln" "$d .py $what"
	done
done

# Mentions in comments and docstrings pass; the GitHub backend and the exempt places are not scanned; look-alikes pass.
plant scheduler/g04ok.sh <<'EOF2'
#!/bin/sh
# gh api repos/o/n and https://github.com/o/n in a comment
echo hi # gh pr list, github.com
echo "the gh CLI" "ghost"
gh_list() { echo "$gh $1"; }
x=$gh; y=ghost
if [ -n "$gh" ]; then x=$(echo ghost); fi
z=$(echo "a b") echo ghost
cat <<'TXT'
# gh api in a heredoc comment line
TXT
EOF2
g_quiet scheduler/g04ok.sh "a .sh with gh and github.com in comments, 'ghost', gh_list, \$gh and 'the gh CLI'"
plant scheduler/g04ok.py <<'EOF2'
"""Module docstring: the gh CLI, ["gh", "api"], https://github.com/o/n."""
import re
def gh_list(x):
    """Docstring over
    two lines: gh api, github.com."""
    # ["gh", "api"], github.com
    y = "a"  # trailing: gh pr list, github.com
    z = "the gh CLI and ghost"
    w = re.compile(r"gh[spou]_[A-Za-z0-9]+")
    return y, z, w, x == "ghost"
EOF2
g_quiet scheduler/g04ok.py "a .py with gh and github.com in comments and docstrings, 'ghost', gh_list, the token regex and 'the gh CLI'"
for rel in scheduler/forges/github.py scheduler/testdata/g04.sh scheduler/testdata/g04.py scheduler/g04.test.sh; do
	case $rel in *.py) printf 'x = ["gh", "api", "https://github.com/o/n"]\n' | plant "$rel" ;;
	*) printf 'gh api https://github.com/o/n\n' | plant "$rel" ;; esac
	g_quiet "$rel" "a gh call and a github.com URL in the exempt $rel"
done
rm -rf "$G04"

# ---- R02-AC-2 / R02-AC-4 (change 4): the plugin rules. The tracked files under plugin/ and the templates
# scheduler/unattended*.md and scheduler/limit-resume.md name no forge CLI, no harness and no harness tool. Exempt: the
# adapter's files (plugin/.claude-plugin/, plugin/hooks/hooks.json, plugin/hooks/claude_code.py), *.test.sh and any
# testdata/ folder. Whole text is scanned, prose and code spans too: Markdown is the content, so a 'gh pr create' in a
# sentence is a gh command; in a .py or .sh under plugin/ comments and docstrings count as well (AC-2 names texts, and
# a neutral file has no reason to name a harness even in a comment). What fails, per line, in any scanned file:
#   - a gh command: the word gh (not part of a longer word, path, option or variable: ghost, gh_x, $gh, ./gh, gh-pages
#     pass) anywhere: `gh pr create`, "every gh call", `gh` in a code span all fail; GitHub (the word) passes;
#   - a github.com URL: 'github.com' anywhere;
#   - a claude command: the word claude (lower case; CLAUDE.md, Claude, .claude/ and claude_code do not count) followed
#     by an option ('claude -p', 'claude --resume'), or at a command position: at the start of a line (behind a list
#     bullet or '$ '), after | ; & ( a backquote or $( , behind exec/env/sudo/time/nohup/setsid/then/do/else;
#   - 'Claude Code', CLAUDE_PLUGIN_ROOT, PreToolUse, and the tool names of change 2: 'Agent tool', subagent_type,
#     run_in_background, SendMessage, TaskStop.
# Not flagged (owner Q4 and change 2): the frontmatter 'tools: Read, Grep, Glob, Edit, Write, Bash', '.claude/' paths,
# CLAUDE.md, the word GitHub, 'Agent' or 'subagent' alone.
cat >"$tmp/scan3.py" <<'PY'
import re, sys

root = sys.argv[1]
ADAPTER = ("plugin/.claude-plugin/", "plugin/hooks/hooks.json", "plugin/hooks/claude_code.py")
GH = re.compile(r"(?<![\w./$\-])gh(?![\w\-])")
URL = re.compile(r"github\.com")
PRE = r"(?:(?:exec|env|sudo|time|nohup|setsid|command|then|do|else)\s+)*"
CLAUDE = re.compile(r"(?<![\w./\-])claude(?=\s+-)|(?:^\s*(?:[-*+]\s+|\$\s+)?|[|;&(`]\s*|\$\(\s*)" + PRE + r"claude(?![\w./\-])")
PLAIN = [("Claude Code", r"Claude Code"), ("CLAUDE_PLUGIN_ROOT", r"CLAUDE_PLUGIN_ROOT"), ("PreToolUse", r"PreToolUse"),
         ("Agent tool", r"\bAgent tool\b"), ("subagent_type", r"subagent_type"),
         ("run_in_background", r"run_in_background"), ("SendMessage", r"SendMessage"), ("TaskStop", r"TaskStop")]

def in_scope(rel):
    parts = rel.split("/")
    if rel.endswith(".test.sh") or "testdata" in parts[:-1] or rel.startswith(ADAPTER[0]) or rel in ADAPTER[1:]:
        return False
    if rel.startswith("plugin/"):
        return True
    return len(parts) == 2 and parts[0] == "scheduler" and rel.endswith(".md") and \
        (parts[1].startswith("unattended") or parts[1] == "limit-resume.md")

bad = 0
for rel in sys.stdin.read().split("\n"):
    if not rel or not in_scope(rel):
        continue
    try:
        text = open(root + "/" + rel, encoding="utf-8").read()
    except (OSError, UnicodeDecodeError) as e:
        print("%s:0: cannot scan: %s" % (rel, e))
        bad += 1
        continue
    for no, line in enumerate(text.split("\n"), 1):
        hits = []
        if GH.search(line):
            hits.append("gh command")
        if URL.search(line):
            hits.append("github.com URL")
        if CLAUDE.search(line):
            hits.append("claude command")
        hits += [n for n, rx in PLAIN if re.search(rx, line)]
        for h in hits:
            print("%s:%d: %s: %s" % (rel, no, h, line.strip()[:100]))
            bad += 1
sys.exit(1 if bad else 0)
PY
scan3() { python3 -I "$tmp/scan3.py" "$1"; }

out=$(cd "$root" && { git ls-files plugin; git ls-files 'scheduler/unattended*.md' scheduler/limit-resume.md; } | scan3 "$root"); rc=$?
if [ $rc = 0 ]; then pass "R02-AC-2: no skill, fixture, agent or session template holds a gh command, github.com URL, claude command, Claude Code or harness tool name"
else fail "R02-AC-2: the plugin and the templates hold forge or harness forms (file:line):
$out"; fi
if [ $rc = 0 ]; then pass "R02-AC-4: the core check passes on the tree (plugin rules)"
else fail "R02-AC-4: the core check's plugin rules fail on the tree (findings under R02-AC-2 above)"; fi

# Scratch folders named R02 inside the tmp. Each plant file holds one form per line; line numbers follow it.
R02=$tmp/R02
mkdir -p "$R02"
r_plant() { mkdir -p "$R02/$(dirname "$1")"; cat >"$R02/$1"; }
r_expect() { # <rel> <line> <what>
	printf '%s\n' "$1" | scan3 "$R02" >"$R02/o" 2>&1
	if grep -q "^$1:$2: " "$R02/o"; then pass "R02-AC-4: a planted $3 fails, naming $1:$2"; else fail "R02-AC-4: planted $3 not named at $1:$2 (got: $(cat "$R02/o"))"; fi
}
r_quiet() { # <rel> <what>
	if printf '%s\n' "$1" | scan3 "$R02" >"$R02/o" 2>&1; then pass "R02-AC-4: $2 passes"; else fail "R02-AC-4: $2 was flagged: $(cat "$R02/o")"; fi
}
cat >"$R02/forms.md" <<'EOF2'
Open the PR with gh pr create when done.
Read it with `gh issue view 3 --comments` first.
The log is at https://github.com/o/n/issues/1 today.
Start it with `claude -p /noodlebot:node X` now.
$ claude --resume abc
This text is written for Claude Code only.
Load ${CLAUDE_PLUGIN_ROOT}/skills/node first.
The hook fires on PreToolUse for every call.
Start the reviewer with the Agent tool, one per slice.
Pass subagent_type: tester to it.
Set run_in_background: true for it.
Answer it with SendMessage afterwards.
End it with TaskStop when stale.
x=1; claude
run it | claude
every gh call needs a token
EOF2
cat >"$R02/wl" <<'EOF2'
a gh command in prose
a gh command in a code span
a github.com URL
a claude command with -p
a claude command behind a $ prompt
Claude Code
CLAUDE_PLUGIN_ROOT
PreToolUse
the Agent tool name
subagent_type
run_in_background
SendMessage
TaskStop
a claude command after ;
a claude command after a pipe
a bare gh word in prose (gh call)
EOF2
for kind in "plugin/skills/x/SKILL.md skill" "plugin/agents/x.md agent" "scheduler/unattended-x.md session template" \
	"scheduler/limit-resume.md limit-resume template"; do
	rel=${kind%% *}; what=${kind#* }
	mkdir -p "$R02/$(dirname "$rel")"; cp "$R02/forms.md" "$R02/$rel"
	i=0
	while IFS= read -r w; do
		i=$((i + 1)); r_expect "$rel" "$i" "$w in a $what"
	done <"$R02/wl"
done
# More places: a skill fixture, a .py's comment (comments count), templates by the glob.
r_plant plugin/skills/adopt/example/FACTS.md <<'EOF2'
stood in for gh issue list --state all
EOF2
r_expect plugin/skills/adopt/example/FACTS.md 1 "gh command in a skill fixture"
r_plant plugin/skills/x/p.py <<'EOF2'
"""A docstring."""
# runs gh pr list and Claude Code
x = 1
EOF2
r_expect plugin/skills/x/p.py 2 "gh command in a .py comment (comments count)"
# A plugin file that is not an adapter file is scanned (plugin/hooks/guard.py is neutral).
r_plant plugin/hooks/guard.py <<'EOF2'
# the Claude Code hook
x = 1
EOF2
r_expect plugin/hooks/guard.py 1 "Claude Code in plugin/hooks/guard.py (only claude_code.py and hooks.json are the adapter)"

# Not flagged: look-alikes in a skill, an agent and a template.
cat >"$R02/ok.md" <<'EOF2'
---
name: x
description: GitHub is only a word here, and ghost, high and gh_x are not commands.
tools: Read, Grep, Glob, Edit, Write, Bash
---
The repository's own facts live in CLAUDE.md and .claude/agents and .claude/skills/node/SKILL.md.
The adapter is claude_code.py and the claude_code module; Claude is a name; the Claudette tool.
Use "$NOODLEBOT_FORGE" pr create and a fresh subagent; the Agent role starts a reviewer in the background.
The variable $gh and the path ./gh/x and gh-pages are not commands; GH_TOKEN is a variable.
Pre-tool hooks and a task stop are role terms.
EOF2
for rel in plugin/skills/x/ok.md plugin/agents/ok.md scheduler/unattended-ok.md scheduler/limit-resume.md; do
	mkdir -p "$R02/$(dirname "$rel")"; cp "$R02/ok.md" "$R02/$rel"
	r_quiet "$rel" "$rel with GitHub, ghost, CLAUDE.md, .claude/ paths, claude_code, the tools: list and the forge CLI"
done
# Exempt places hold every form without failing: the adapter's files, tests and testdata.
for rel in plugin/.claude-plugin/plugin.json plugin/hooks/hooks.json plugin/hooks/claude_code.py plugin/skills/x/p.test.sh \
	plugin/skills/x/testdata/p.md plugin/hooks/testdata/p.md plugin/skills/node/p.test.sh scheduler/testdata/unattended-p.md \
	scheduler/unattended-p.test.sh; do
	mkdir -p "$R02/$(dirname "$rel")"; cp "$R02/forms.md" "$R02/$rel"
	r_quiet "$rel" "the planted forms in the exempt $rel"
done
# Files outside the rule's places are not scanned (the core's own rules are S08's and G04's scans).
for rel in scheduler/notes.md README.md scheduler/loop.sh; do
	mkdir -p "$R02/$(dirname "$rel")"; cp "$R02/forms.md" "$R02/$rel"
	r_quiet "$rel" "the planted forms in $rel (outside plugin/ and the templates)"
done
rm -rf "$R02"

# ---- R02 change 2 (review 1): the agents and the templates name no fixed harness path or file. .claude/ and CLAUDE.md are
# named only as the repository's own facts, read from its AGENTS.md or .noodlebot/roles.yaml; limit-resume.md names no harness tool.
r02_files="$root/plugin/agents/*.md $root/scheduler/unattended*.md $root/scheduler/limit-resume.md"
r02_hit=$(grep -nE -e '\.claude/|CLAUDE\.md' $r02_files 2>/dev/null | sed "s#^$root/##" | head -n 12)
if [ -z "$r02_hit" ]; then pass "R02-AC-2: no agent or session template holds a fixed .claude/ path or CLAUDE.md"
else fail "R02-AC-2: an agent or template names a fixed .claude/ path or CLAUDE.md (file:line:text):
$r02_hit"; fi
r02_hit=$(grep -nE -e 'Monitor|[Ss]cheduled wakeup|ScheduleWakeup' "$root/scheduler/limit-resume.md" 2>/dev/null | head -n 5)
if [ -z "$r02_hit" ]; then pass "R02-AC-2: limit-resume.md names no harness tool (Monitor, scheduled wakeup)"
else fail "R02-AC-2: limit-resume.md names a harness tool (line:text):
$r02_hit"; fi

[ "$fails" = 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "all checks passed"
