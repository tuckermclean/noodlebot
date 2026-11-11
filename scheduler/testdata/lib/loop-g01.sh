# Shared by loop-g01*.test.sh (source after loop-prelude.sh): the fixture of the G01 end-to-end runs.
# ---- G01: update sessions for the bot's spec PRs (state/<name>/pr/<N>/, worktrees/<name>/pr-<N>) ----
# A fresh loop (o/up, 1 s tick, the throttle on) over its own remote: main has X01 and X02 (both held by
# FAILED, so no node starts). The fake gh answers the open-PR list from $GD/prs.tsv ("<number> <branch>
# <author login> <is_bot> <mergeable>"; the JSON has number, headRefName, headRefOid, author{login,is_bot},
# mergeable) and evaluates the -q expression itself with a small jq subset (.[], .a.b, |, "\(.x)", select,
# ==, !=, and, or, //, not, startswith, if); $GD/open.fail makes the open-PR list fail.
#   101 spec/c1     bot   CONFLICTING            update
#   102 spec/human  human CONFLICTING            none
#   103 spec/clean  bot   MERGEABLE, no clash    none
#   104 spec/unk    bot   UNKNOWN                none
#   105 node/X03-foo bot  CONFLICTING            none (not a spec/* PR)
#   106 spec/clash  bot   MERGEABLE, its graph names X02 differently from main: update
# The fake claude logs "<kind> <key> run <n> <prompt> | <pwd> | <branch>" to $GD/claude.log and holds
# while $GD/hold.<key> exists (key: the PR number, or t for the triage of issue 46); $GD/limit.<key>.<run>
# makes that run exit 1 with a usage-limit event, $GD/rc.<key>.<run> sets its exit code (default 0).
GD=$tmp/g01; export GD
mkdir -p "$GD" "$tmp/bin6" "$tmp/nb6/scheduler" "$tmp/nb6/plugin" "$tmp/data6"
data6=$(cd "$tmp/data6" && pwd -P)
GD_STATE=$data6/state/up; export GD_STATE
for f in "$src"/*; do case $f in *.test.sh) ;; *) [ -f "$f" ] && cp "$f" "$tmp/nb6/scheduler/" ;; esac; done
[ -f "$src/harness.py" ] && { mkdir -p "$tmp/nb6/scheduler/harnesses"; cp "$src/harness.py" "$tmp/nb6/scheduler/"; cp "$src"/harnesses/*.py "$tmp/nb6/scheduler/harnesses/"; }
cp -R "$src/../plugin/." "$tmp/nb6/plugin/" 2>/dev/null
g6() { git -C "$tmp/work6" -c user.name=t -c user.email=t@t "$@"; }
git init -q -b main "$tmp/work6"; mkdir -p "$tmp/work6/docs"
g01base='nodes:\n  - {id: X01, name: first, deps: []}\n  - {id: X02, name: second, deps: []}\n'
printf "$g01base" >"$tmp/work6/docs/graph.yaml"
g6 add -A && g6 commit -q -m init
git clone -q --bare "$tmp/work6" "$tmp/remote6.git"
# g01branch <branch> <graph text>: a branch off main whose graph is <graph text>.
g01branch() {
	g6 checkout -q -b "$1" main && printf "$2" >"$tmp/work6/docs/graph.yaml" && g6 commit -q -am "$1" &&
		g6 push -q "$tmp/remote6.git" "$1"; g6 checkout -q main
}
for b in spec/c1 spec/human spec/clean spec/unk node/X03-foo spec/lim spec/late; do
	g01branch "$b" "${g01base}  - {id: X03, name: new-${b##*/}, deps: []}\n"
done
g01branch spec/clash 'nodes:\n  - {id: X01, name: first, deps: []}\n  - {id: X02, name: clashing, deps: []}\n'
# mvref <branch>: a new commit on that branch of the remote, same tree (main or the PR's head moves).
mvref() {
	local t c
	t=$(git -C "$tmp/remote6.git" rev-parse "$1^{tree}") &&
		c=$(GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
			git -C "$tmp/remote6.git" commit-tree "$t" -p "$1" -m "move $1 $RANDOM") &&
		git -C "$tmp/remote6.git" update-ref "refs/heads/$1" "$c"
}
mkdir -p "$data6/repos" "$GD_STATE/node/X01" "$GD_STATE/node/X02"
touch "$GD_STATE/node/X01/FAILED" "$GD_STATE/node/X02/FAILED"
git clone -q "$tmp/remote6.git" "$data6/repos/up"
cat >"$GD/prs.tsv" <<'EOF'
101 spec/c1 app/noodlebot true CONFLICTING
102 spec/human tuckermclean false CONFLICTING
103 spec/clean app/noodlebot true MERGEABLE
104 spec/unk app/noodlebot true UNKNOWN
105 node/X03-foo app/noodlebot true CONFLICTING
106 spec/clash app/noodlebot true MERGEABLE
EOF
echo '[]' >"$GD/issues.json"
touch "$GD/hold.101" "$GD/hold.106" "$GD/hold.t" "$GD/limit.107.1"
echo 1 >"$GD/rc.107.2"; echo 1 >"$GD/rc.107.3"
cat >"$GD/gh.py" <<'EOF'
import json, os, re, subprocess, sys
GD = os.environ["GD"]
a = sys.argv[1:]
j = " ".join(a)


class P:
    def __init__(s, t): s.t, s.i = t, 0
    def ws(s):
        while s.i < len(s.t) and s.t[s.i].isspace(): s.i += 1
    def peek(s, x): s.ws(); return s.t.startswith(x, s.i)
    def eat(s, x):
        if s.peek(x): s.i += len(x); return True
        return False
    def need(s, x):
        if not s.eat(x): bad(s.t[s.i:])
    def word(s):
        s.ws(); m = re.compile(r"[A-Za-z_][A-Za-z_0-9]*").match(s.t, s.i)
        if not m: return None
        s.i = m.end(); return m[0]


def bad(rest):
    sys.exit("fake gh: unsupported jq expression near: " + rest)


def truthy(x): return x is not None and x is not False


def text(x): return x if isinstance(x, str) else json.dumps(x)


def pipe(p):
    l = alt(p)
    while p.peek("|") and not p.peek("||"):
        p.eat("|"); r = alt(p)
        l = (lambda l, r: lambda v: (y for x in l(v) for y in r(x)))(l, r)
    return l


def alt(p):
    l = orx(p)
    while p.eat("//"):
        r = orx(p)
        l = (lambda l, r: lambda v: iter([x for x in l(v) if truthy(x)] or list(r(v))))(l, r)
    return l


def kw(p, w):
    p.ws(); m = re.compile(w + r"(?![A-Za-z_0-9])").match(p.t, p.i)
    if m: p.i = m.end(); return True
    return False


def orx(p):
    l = andx(p)
    while kw(p, "or"):
        r = andx(p)
        l = (lambda l, r: lambda v: (truthy(x) or truthy(y) for x in l(v) for y in r(v)))(l, r)
    return l


def andx(p):
    l = cmp(p)
    while kw(p, "and"):
        r = cmp(p)
        l = (lambda l, r: lambda v: (truthy(x) and truthy(y) for x in l(v) for y in r(v)))(l, r)
    return l


def cmp(p):
    l = prim(p)
    for op in ("==", "!="):
        if p.eat(op):
            r = prim(p)
            return (lambda l, r, op: lambda v: ((x == y) == (op == "==") for x in l(v) for y in r(v)))(l, r, op)
    return l


def path(p):
    steps = []
    while True:
        if p.i < len(p.t) and p.t[p.i] == ".":
            m = re.compile(r"\.([A-Za-z_][A-Za-z_0-9]*)").match(p.t, p.i)
            if m: steps.append(m[1]); p.i = m.end(); continue
            if p.t.startswith(".[]", p.i): steps.append(None); p.i += 3; continue
            if len(steps) == 0: p.i += 1; continue
            break
        elif p.t.startswith("[]", p.i): steps.append(None); p.i += 2; continue
        break

    def f(v):
        cur = [v]
        for s in steps:
            nxt = []
            for x in cur:
                if s is None: nxt += list(x)
                else: nxt.append(x.get(s) if isinstance(x, dict) else None)
            cur = nxt
        return iter(cur)
    return f


def prim(p):
    p.ws()
    if p.eat("("):
        e = pipe(p); p.need(")"); return e
    if p.peek('"'):
        p.i += 1; parts = []; buf = ""
        while p.t[p.i] != '"':
            if p.t.startswith("\\(", p.i):
                p.i += 2; parts.append(buf); buf = ""; parts.append(pipe(p)); p.need(")")
            elif p.t[p.i] == "\\":
                buf += {"n": "\n", "t": "\t"}.get(p.t[p.i + 1], p.t[p.i + 1]); p.i += 2
            else: buf += p.t[p.i]; p.i += 1
        p.i += 1; parts.append(buf)
        return lambda v: iter(["".join(x if isinstance(x, str) and k % 2 == 0 else text(next(x(v), None)) if k % 2 else x
                                       for k, x in enumerate(parts))])
    m = re.compile(r"-?[0-9]+").match(p.t, p.i)
    if m: p.i = m.end(); n = int(m[0]); return lambda v: iter([n])
    if p.peek("."): return path(p)
    w = p.word()
    if w in ("null", "true", "false"):
        c = {"null": None, "true": True, "false": False}[w]; return lambda v: iter([c])
    if w == "not": return lambda v: iter([not truthy(v)])
    if w == "length": return lambda v: iter([len(v)])
    if w == "select":
        p.need("("); c = pipe(p); p.need(")")
        return lambda v: (v for x in c(v) if truthy(x))
    if w in ("startswith", "endswith", "test"):
        p.need("("); c = pipe(p); p.need(")")
        fn = {"startswith": lambda v, x: v.startswith(x), "endswith": lambda v, x: v.endswith(x),
              "test": lambda v, x: re.search(x, v) is not None}[w]
        return lambda v: (isinstance(v, str) and fn(v, x) for x in c(v))
    if w == "if":
        c = pipe(p); kw(p, "then"); t = pipe(p); e = lambda v: iter([v])
        if kw(p, "else"): e = pipe(p)
        kw(p, "end")
        return lambda v: (y for x in c(v) for y in (t(v) if truthy(x) else e(v)))
    bad(p.t[p.i:])


def jq(expr, data):
    p = P(expr); f = pipe(p); p.ws()
    if p.i != len(p.t): bad(p.t[p.i:])
    for x in f(data): print(x if isinstance(x, str) else json.dumps(x, separators=(",", ":")))


def prs():
    out = []
    for line in open(GD + "/prs.tsv"):
        f = line.split()
        if len(f) < 5: continue
        oid = subprocess.run(["git", "--git-dir", os.environ["GD"] + "/../remote6.git", "rev-parse", f[1]],
                             capture_output=True, text=True).stdout.strip()
        out.append({"number": int(f[0]), "headRefName": f[1], "headRefOid": oid, "baseRefName": "main",
                    "state": "OPEN", "title": "t", "isCrossRepository": False, "mergeable": f[4],
                    "author": {"login": f[2], "is_bot": f[3] == "true", "name": "", "id": "x"}})
    return out


if a[:2] == ["pr", "list"]:
    if "--state" in a and a[a.index("--state") + 1] == "open":
        if os.path.exists(GD + "/open.fail"):
            print("fake-open-failure", file=sys.stderr); sys.exit(1)
        q = next((a[i + 1] for i, x in enumerate(a) if x in ("-q", "--jq") and i + 1 < len(a)), None)
        if q is None: print(json.dumps(prs()))
        else: jq(q, prs())
    sys.exit(0)
if "/issues?labels=noodlebot" in j: sys.stdout.write(open(GD + "/issues.json").read())
elif "/events" in j: print('[{"event": "labeled", "label": {"name": "noodlebot"}, "actor": {"login": "o"}}]')
elif " DELETE " in " " + j + " " and "/labels/noodlebot" in j: print("[]")
elif "/labels" in j: sys.stdin.read(); print("{}")
sys.exit(0)
EOF
printf '#!/bin/sh\nexec python3 -I "$GD/gh.py" "$@"\n' >"$tmp/bin6/gh"
cat >"$tmp/bin6/claude" <<'EOF'
#!/bin/sh
case "$2" in
"/noodlebot:triage --update "*) k=${2##* }; kind=update ;;
"/noodlebot:triage "*) k=t; kind=triage ;;
*) k=other; kind=other ;;
esac
n=$(( $(cat "$GD/runs.$k" 2>/dev/null || echo 0) + 1 )); echo $n >"$GD/runs.$k"
echo "$kind $k run $n $2 | $(pwd -P) | $(git branch --show-current 2>/dev/null)" >>"$GD/claude.log"
while [ -e "$GD/hold.$k" ]; do sleep 0.2; done
[ $kind = triage ] && echo "Q1: x" >"$GD_STATE/issue/46/QUESTION.md"
if [ -e "$GD/limit.$k.$n" ]; then
	echo '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","unifiedWindows":{"five_hour":{"utilization":1.0,"resetsAt":1,"status":"rejected"}}}}'
	echo '{"type":"result","subtype":"error_during_execution","result":"You have hit your usage limit"}'
	exit 1
fi
exit "$(cat "$GD/rc.$k.$n" 2>/dev/null || echo 0)"
EOF
chmod +x "$tmp/bin6/gh" "$tmp/bin6/claude"
state=$GD_STATE wt6=$data6/worktrees/up
s6runs() { cat "$GD/runs.$1" 2>/dev/null || echo 0; }
runsis() { [ "$(s6runs "$1")" = "$2" ]; }
# pr_ev <N> <pattern>: status-log events that name PR #N and match the pattern.
pr_ev() { grep -E "PR #$1([^0-9]|\$)" "$state/status.log" 2>/dev/null | grep -cE "$2"; }
pr_evis() { [ "$(pr_ev "$1" "$2")" = "$3" ]; }
rl6() { rl_event "$state/node/X01/session.jsonl" "$@"; }
loop6() {
	NOODLEBOT_DATA=$data6 PATH=$tmp/bin6:$PATH SCHED_REPORT=0 SCHED_TICK=1 SCHED_POLL=0.2 \
		bash "$tmp/nb6/scheduler/loop.sh" o/up >>"$tmp/g01-loop.out" 2>&1 &
	pids+=("$!"); lp6=$!
}

g01_gone() { ! kill -0 "$1" 2>/dev/null; }
