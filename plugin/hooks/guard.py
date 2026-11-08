#!/usr/bin/env python3
"""Role guard: a PreToolUse hook that holds the plugin's role agents to their roles.

Why a plugin-level hook keyed on agent_type: Claude Code ignores the `hooks`,
`mcpServers` and `permissionMode` frontmatter fields of agents shipped by a plugin
(https://code.claude.com/docs/en/sub-agents, "Choose the subagent scope"), and tells a
plugin to ship its hooks in hooks/hooks.json instead. Those apply whenever the plugin is
enabled, so this script runs for every Edit, Write, NotebookEdit and Bash call and acts
only when the hook input's `agent_type` is one of the plugin's agents
(`noodlebot:tester`, `noodlebot:implementer`, `noodlebot:reviewer`;
https://code.claude.com/docs/en/hooks, "Hook locations"). Any other session is allowed.

  tester       may write only test paths
  implementer  may not write test or spec paths
  reviewer     may write nothing in the repository

Paths come from `.noodlebot/roles.yaml` in the repository root (`tests:` and `specs:`,
root-relative globs; a key that is present replaces that key's default). A malformed file
blocks role writes with a reason. The Bash detection is a heuristic guardrail for
cooperative agents, not a sandbox. Exit 2 with the reason on stderr blocks; exit 0 allows.
"""
import json
import os
import re
import subprocess
import sys

ROLES = {"noodlebot:tester": "tester", "noodlebot:implementer": "implementer",
         "noodlebot:reviewer": "reviewer"}
DEFAULTS = {
    "tests": ["**/*.test.sh", "**/*_test.*", "**/test_*", "**/tests/**", "**/testdata/**", "**/fixtures/**"],
    "specs": ["SPEC.md", "AGENTS.md", "CLAUDE.md", "docs/graph.yaml", "nodes/**"],
}
REVIEWER_GIT = {"add", "commit", "rm", "mv", "stash", "restore", "reset", "merge", "rebase",
                "cherry-pick", "apply", "clean", "am", "revert", "pull"}


class Block(Exception):
    pass


def glob_re(g):
    out, i = "", 0
    while i < len(g):
        if g.startswith("**/", i):
            out, i = out + "(?:.*/)?", i + 3
        elif g.startswith("**", i):
            out, i = out + ".*", i + 2
        elif g[i] == "*":
            out, i = out + "[^/]*", i + 1
        elif g[i] == "?":
            out, i = out + "[^/]", i + 1
        else:
            out, i = out + re.escape(g[i]), i + 1
    return re.compile(out)


def load_config(root):
    cfg = dict(DEFAULTS)
    path = os.path.join(root, ".noodlebot", "roles.yaml")
    if not os.path.isfile(path):
        return cfg
    try:
        import yaml
        with open(path) as f:
            data = yaml.safe_load(f)
    except Exception as e:
        raise Block(f"{path} is malformed or unreadable ({type(e).__name__}); fix it before this role can write")
    if data is None:
        return cfg
    if not isinstance(data, dict):
        raise Block(f"{path} must be a mapping with 'tests' and 'specs' lists")
    for k in ("tests", "specs"):
        if k in data:
            v = data[k]
            if not isinstance(v, list) or not all(isinstance(x, str) for x in v):
                raise Block(f"{path}: '{k}' must be a list of glob strings")
            cfg[k] = v
    return cfg


class Repo:
    def __init__(self, root):
        self.root = os.path.realpath(root)
        self._cfg = None

    def cfg(self):
        if self._cfg is None:
            self._cfg = load_config(self.root)
        return self._cfg

    def rel(self, p):
        """Root-relative path, or None when p is outside the repository or unknowable."""
        if p.startswith(("$", "`")):
            return None
        p = os.path.expanduser(p)
        full = os.path.realpath(p if os.path.isabs(p) else os.path.join(self.root, p))
        r = os.path.relpath(full, self.root)
        return None if r == ".." or r.startswith("../") else r

    def match(self, key, rel):
        return any(glob_re(g).fullmatch(rel) for g in self.cfg()[key])

    def hit(self, key, rel, dirs):
        """rel matches; with dirs, a directory also counts for what lies under it."""
        return self.match(key, rel) or (dirs and self.match(key, rel.rstrip("/") + "/x"))

    def check(self, role, p, strict_outside, dirs=False):
        """Raise Block if role may not write p. strict_outside: outside the repo is a violation.
        dirs: p may be a directory, so writing it writes everything under it."""
        rel = self.rel(p)
        if role == "reviewer":
            if rel is not None or strict_outside:
                raise Block("the reviewer role is read-only: it writes nothing in the repository")
            return
        if rel is None:
            if strict_outside and role == "tester":
                raise Block(f"the tester may write only test paths; {p} is outside the repository")
            return
        if role == "tester":
            if not self.hit("tests", rel, dirs):
                raise Block(f"the tester may write only test and fixture paths; {rel} is not one")
        elif self.hit("tests", rel, dirs) or self.hit("specs", rel, dirs) or rel == ".noodlebot/roles.yaml":
            raise Block(f"the implementer may not write test, fixture or spec paths; {rel} is one")

    def staged(self):
        try:
            r = subprocess.run(["git", "-C", self.root, "diff", "--cached", "--name-only", "-z"],
                               capture_output=True, timeout=20)
        except Exception:
            return []
        if r.returncode != 0:
            return []
        return [x for x in r.stdout.decode("utf-8", "replace").split("\0") if x]

    def git_list(self, *args):
        try:
            r = subprocess.run(["git", "-C", self.root, *args, "-z"], capture_output=True, timeout=20)
        except Exception:
            return []
        if r.returncode != 0:
            return []
        return [x for x in r.stdout.decode("utf-8", "replace").split("\0") if x]


OPS = ["&>>", "<<<", "<<-", "&&", "||", ";;", "|&", "&>", ">>", ">|", ">&", "<&", "<>", "<<",
       ";", "|", "&", "(", ")", "<", ">"]
REDIR = re.compile(r"\d*(?:&>>|&>|<<<|<<-|<<|>>|>\||>&|<&|<>|>|<)")
WRITE_REDIR = {">", ">>", ">|", "&>", "&>>", "<>", ">&"}
PREFIX = {"sudo", "env", "command", "exec", "nohup", "builtin", "time", "!", "if", "then", "else",
          "elif", "do", "while", "until", "{"}


class Word:
    """A shell word: its text with quotes removed (expansions kept as written, so a `$` or a
    backquote in it marks it unknowable) and the command lists of its $( … ) and ` … `."""

    def __init__(self):
        self.text, self.quoted, self.subs = "", False, []


class Lexer:
    """A small shell lexer. Words come out as Word, unquoted operators as strings (a
    redirection carries its fd number, e.g. '2>&'), newlines as '\\n'. Quoting is kept
    visible, backslash-newline joins lines and heredoc bodies are skipped as data."""

    def __init__(self, s):
        self.s, self.i = s, 0

    def _match(self, j, open_, close):
        """Index after the bracket that closes the one opened just before j."""
        depth, s = 1, self.s
        while j < len(s) and depth:
            if s[j] == "\\":
                j += 1
            elif s[j] == open_:
                depth += 1
            elif s[j] == close:
                depth -= 1
            j += 1
        return j

    def _dollar(self, w):
        s, i = self.s, self.i
        if s.startswith("$((", i):
            self.i = self._match(i + 3, "(", ")") + 1
            w.text += s[i:self.i]
        elif s.startswith("$(", i):
            self.i = i + 2
            w.subs.append(self.tokens(close=True))
            w.text += s[i:self.i]
        elif s.startswith("${", i):
            self.i = self._match(i + 2, "{", "}")
            w.text += s[i:self.i]
        else:
            w.text += "$"
            self.i += 1

    def _backquote(self, w):
        s, j = self.s, self.i + 1
        while j < len(s) and s[j] != "`":
            j += 2 if s[j] == "\\" else 1
        w.subs.append(Lexer(s[self.i + 1:j].replace("\\`", "`")).tokens())
        w.text += s[self.i:j + 1]
        self.i = j + 1

    def _double(self, w):
        s = self.s
        self.i += 1
        while self.i < len(s) and s[self.i] != '"':
            c = s[self.i]
            if c == "\\" and self.i + 1 < len(s) and s[self.i + 1] in '$`"\\\n':
                if s[self.i + 1] != "\n":
                    w.text += s[self.i + 1]
                self.i += 2
            elif c == "$":
                self._dollar(w)
            elif c == "`":
                self._backquote(w)
            else:
                w.text += c
                self.i += 1
        self.i += 1

    def _body(self, delim, dash):
        s, j = self.s, self.i
        while j < len(s):
            k = s.find("\n", j)
            line = s[j:] if k < 0 else s[j:k]
            j = len(s) if k < 0 else k + 1
            if (line.lstrip("\t") if dash else line) == delim:
                break
        self.i = j

    def tokens(self, close=False):
        """Tokens up to the end, or with close, up to the ')' that ends a $( (consumed)."""
        s, out, pending, depth = self.s, [], [], 0
        word, delim = None, None

        def flush():
            nonlocal word, delim
            if word is not None:
                out.append(word)
                if delim is not None:
                    pending.append((word.text, delim))
                    delim = None
            word = None

        while self.i < len(s):
            c = s[self.i]
            if s.startswith("\\\n", self.i):
                self.i += 2
            elif c in " \t":
                flush()
                self.i += 1
            elif c == "#" and word is None:
                while self.i < len(s) and s[self.i] != "\n":
                    self.i += 1
            elif c == "\n":
                flush()
                out.append("\n")
                self.i += 1
                for d, dash in pending:
                    self._body(d, dash)
                pending = []
            elif c in "|&;()<>":
                fd = ""
                if c in "<>" and word is not None and not word.quoted and word.text.isdigit() and not word.subs:
                    fd, word = word.text, None
                flush()
                op = next(o for o in OPS if s.startswith(o, self.i))
                self.i += len(op)
                if op == "(":
                    depth += 1
                elif op == ")":
                    if depth == 0 and close:
                        return out
                    depth = max(depth - 1, 0)
                if op in ("<<", "<<-"):
                    delim = op == "<<-"
                out.append(fd + op)
            else:
                if word is None:
                    word = Word()
                if c == "'":
                    k = s.find("'", self.i + 1)
                    k = len(s) if k < 0 else k
                    word.text += s[self.i + 1:k]
                    word.quoted, self.i = True, k + 1
                elif c == '"':
                    word.quoted = True
                    self._double(word)
                elif c == "\\":
                    word.text += s[self.i + 1:self.i + 2]
                    word.quoted, self.i = True, self.i + 2
                elif c == "$":
                    self._dollar(word)
                elif c == "`":
                    self._backquote(word)
                else:
                    word.text += c
                    self.i += 1
        flush()
        return out


def strip_prefix(words):
    while words and (re.fullmatch(r"\w+=.*", words[0], re.S) or words[0] in PREFIX):
        words = words[1:]
    return words


def opts_split(args):
    return [a for a in args if not a.startswith("-")], [a for a in args if a.startswith("-")]


def bash_writes(words):
    """Repository-changing paths a simple command writes, by heuristic."""
    words = strip_prefix(words)
    if not words:
        return []
    c, a = os.path.basename(words[0]), words[1:]
    pos, opt = opts_split(a)
    if c == "tee":
        return pos
    tdir = []
    for j, x in enumerate(a):
        if x in ("-t", "--target-directory") and j + 1 < len(a):
            tdir = [a[j + 1]]
        elif x.startswith("--target-directory="):
            tdir = [x.split("=", 1)[1]]
    if tdir:
        pos = [x for x in pos if x not in tdir]
    if c in ("cp", "install", "ln", "mv") and tdir:
        return tdir + (pos if c == "mv" else [])
    if c in ("rm", "touch", "mkdir", "rmdir", "truncate", "mv", "unlink", "shred"):
        return pos
    if c in ("cp", "install", "ln"):
        return pos[-1:]
    if c == "sed" and any(o.startswith("-i") or o == "--in-place" or (o[:2] == "-" + o[1:2] and not o.startswith("--") and "i" in o[1:])
                          for o in opt):
        has_script = any(o in ("-e", "-f") or o.startswith(("--expression", "--file")) for o in opt)
        if has_script:
            # the argument after -e/-f is a script, not a path
            skip = {j + 1 for j, x in enumerate(a) if x in ("-e", "-f", "--expression", "--file")}
            return [x for j, x in enumerate(a) if not x.startswith("-") and j not in skip]
        return pos[1:]
    return []


def resolve(base, d):
    """Directory d taken from base (None: unknown); None when it cannot be known."""
    if re.search(r"[$`]", d) or d == "-":
        return None
    d = os.path.expanduser(d)
    if os.path.isabs(d):
        return os.path.normpath(d)
    return os.path.normpath(os.path.join(base, d)) if base else None


class Bash:
    """Walks one Bash call's tokens, tracking the working directory per subshell."""

    def __init__(self, role, repo):
        self.role, self.repo = role, repo
        self.pending = []  # paths a git add/rm earlier in this call will put in the index

    def run(self, toks, cwd):
        stack, cur, redirs, k = [], [], [], 0
        while k < len(toks):
            t = toks[k]
            if isinstance(t, Word):
                cur.append(t)
                k += 1
            elif REDIR.fullmatch(t):
                nxt = toks[k + 1] if k + 1 < len(toks) and isinstance(toks[k + 1], Word) else None
                if nxt is not None:
                    redirs.append((t.lstrip("0123456789"), nxt))
                k += 2 if nxt is not None else 1
            else:
                cwd = self.simple(cur, redirs, cwd)
                cur, redirs = [], []
                if t == "(":
                    stack.append(cwd)
                elif t == ")" and stack:
                    cwd = stack.pop()
                k += 1
        self.simple(cur, redirs, cwd)

    def simple(self, words, redirs, cwd):
        """Judge one simple command; return the working directory after it."""
        role, repo = self.role, self.repo
        for w in words + [x for _, x in redirs]:
            for sub in w.subs:
                self.run(sub, cwd)

        def at(p, base=cwd):
            if os.path.isabs(p) or p.startswith(("~", "$", "`")):
                return p
            return os.path.join(base, p) if base else "$unknown/" + p

        for op, w in redirs:
            p = w.text
            if op not in WRITE_REDIR or p.startswith("/dev/") or (op == ">&" and re.fullmatch(r"\d*-?", p)):
                continue
            repo.check(role, at(p), False)
        texts = [w.text for w in words]
        for p in bash_writes(texts):
            repo.check(role, at(p), False, True)
        w = strip_prefix(texts)
        if w and w[0] in ("cd", "pushd", "popd"):
            args = [x for x in w[1:] if not x.startswith("-") or x == "-"]
            if w[0] == "popd" or not args:
                return None
            return resolve(cwd, args[0])
        if len(w) < 2 or os.path.basename(w[0]) != "git":
            return cwd
        i, gdir = 1, cwd
        while i < len(w) and w[i].startswith("-"):
            if w[i] == "-C" and i + 1 < len(w):
                gdir = resolve(gdir, w[i + 1]) if w[i + 1] else gdir
                i += 2
            else:
                i += 2 if w[i] in ("-c", "--git-dir", "--work-tree", "--namespace") else 1
        if gdir is None or repo.rel(gdir) is None:
            return cwd  # another repository (or one that cannot be known): not judged
        sub = w[i] if i < len(w) else ""
        rest = w[i + 1:]
        if role == "reviewer":
            if sub == "stash" and [x for x in rest if not x.startswith("-")][:1] in (["list"], ["show"]):
                return cwd
            if sub in REVIEWER_GIT or (sub in ("checkout", "switch") and any(
                    x in ("-b", "-B", "-c", "-C") for x in rest)):
                raise Block(f"the reviewer role is read-only: 'git {sub}' changes the repository")
        elif sub in ("add", "rm"):
            ops = [x for x in rest if not x.startswith("-")]
            if sub == "add" and (any(x in ("-A", "--all", "-u", "--update") for x in rest) or "." in ops):
                self.pending += repo.git_list("ls-files", "-m", "-o", "--exclude-standard")
                ops = [x for x in ops if x != "."]
            self.pending += [at(x, gdir) for x in ops]
        elif sub == "commit":
            extra = list(self.pending)
            if any(x in ("-a", "--all") or (re.fullmatch(r"-[a-zA-Z]+", x) and "a" in x[1:]) for x in rest):
                extra += repo.git_list("diff", "--name-only")
            j = 0
            while j < len(rest):
                x = rest[j]
                if x == "--":
                    extra += [at(y, gdir) for y in rest[j + 1:]]
                    break
                if x.startswith("--"):
                    j += 2 if x in ("--message", "--file", "--author", "--date", "--template",
                                    "--reuse-message", "--reedit-message", "--fixup", "--squash", "--cleanup") else 1
                elif x.startswith("-") and len(x) > 1:
                    # a short option cluster ending in m, F, C or c takes the next word
                    j += 2 if x[-1] in "mFCc" else 1
                else:
                    extra.append(at(x, gdir))
                    j += 1
            for rel in repo.staged() + extra:
                try:
                    repo.check(role, os.path.join(repo.root, rel), True, True)
                except Block as b:
                    raise Block(f"git commit would commit a path this role may not write: {b}")
        return cwd


def decide(role, repo, tool, tin):
    if tool in ("Edit", "Write", "NotebookEdit"):
        p = tin.get("file_path") or tin.get("notebook_path")
        if role == "reviewer":
            raise Block("the reviewer role is read-only: it may not use " + tool)
        if not p:
            return
        repo.check(role, p, True)
        return
    if tool != "Bash":
        return
    Bash(role, repo).run(Lexer(tin.get("command") or "").tokens(), repo.root)


def main():
    try:
        data = json.load(sys.stdin)
        role = ROLES.get(data.get("agent_type"))
        if role is None:
            return 0
        root = os.environ.get("CLAUDE_PROJECT_DIR") or data.get("cwd") or os.getcwd()
        decide(role, Repo(root), data.get("tool_name"), data.get("tool_input") or {})
    except Block as b:
        print(f"noodlebot role guard: {b}", file=sys.stderr)
        return 2
    except Exception as e:  # a bug here must not block unrelated work
        print(f"noodlebot role guard: ignored internal error: {e!r}", file=sys.stderr)
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
