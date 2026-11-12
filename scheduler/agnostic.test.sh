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

[ "$fails" = 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "all checks passed"
