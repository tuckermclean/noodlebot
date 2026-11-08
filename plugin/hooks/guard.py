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
import shlex
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

    def check(self, role, p, strict_outside):
        """Raise Block if role may not write p. strict_outside: outside the repo is a violation."""
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
            if not self.match("tests", rel):
                raise Block(f"the tester may write only test and fixture paths; {rel} is not one")
        elif self.match("tests", rel) or self.match("specs", rel):
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


def tokens(cmd):
    try:
        lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        return list(lex)
    except ValueError:
        return cmd.split()


def commands(cmd):
    """Split a shell line into (words, redirect-targets) per simple command."""
    cur, redirs, out, want = [], [], [], False
    for t in tokens(cmd) + [";"]:
        if want:
            redirs.append(t)
            want = False
        elif t in (">", ">>", ">|", "&>", "&>>"):
            want = True
        elif re.fullmatch(r"[;|&()]+", t) or t == "\n":
            if cur or redirs:
                out.append((cur, redirs))
            cur, redirs = [], []
        elif t.startswith(">") and len(t) > 1 and not t.startswith(">&"):
            redirs.append(t.lstrip(">"))
        elif re.fullmatch(r"\d*>&?\d*-?|>&\d*", t):
            pass
        else:
            cur.append(t)
    return out


def opts_split(args):
    return [a for a in args if not a.startswith("-")], [a for a in args if a.startswith("-")]


def bash_writes(words):
    """Repository-changing paths a simple command writes, by heuristic."""
    while words and re.fullmatch(r"\w+=.*", words[0]):
        words = words[1:]
    while words and words[0] in ("sudo", "env", "command", "exec", "nohup"):
        words = words[1:]
    if not words:
        return []
    c, a = os.path.basename(words[0]), words[1:]
    pos, opt = opts_split(a)
    if c == "tee":
        return pos
    if c in ("rm", "touch", "mkdir", "rmdir", "truncate", "mv", "unlink", "shred"):
        return pos
    if c in ("cp", "install", "ln"):
        return pos[-1:]
    if c == "sed" and any(o.startswith("-i") or o == "--in-place" or (o[:2] == "-" + o[1:2] and not o.startswith("--") and "i" in o[1:])
                          for o in opt):
        return pos if any(o in ("-e", "-f") for o in opt) else pos[1:]
    return []


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
    cmd = tin.get("command") or ""
    for words, redirs in commands(cmd):
        for p in redirs:
            if not p.startswith("/dev/"):
                repo.check(role, p, False)
        for p in bash_writes(words):
            repo.check(role, p, False)
        w = list(words)
        while w and (re.fullmatch(r"\w+=.*", w[0]) or w[0] in ("sudo", "env")):
            w = w[1:]
        if len(w) < 2 or os.path.basename(w[0]) != "git":
            continue
        i = 1
        while i < len(w) and w[i].startswith("-"):
            i += 2 if w[i] in ("-C", "-c", "--git-dir", "--work-tree") else 1
        sub = w[i] if i < len(w) else ""
        rest = w[i + 1:]
        if role == "reviewer":
            if sub in REVIEWER_GIT or (sub in ("checkout", "switch") and any(
                    x in ("-b", "-B", "-c", "-C") for x in rest)):
                raise Block(f"the reviewer role is read-only: 'git {sub}' changes the repository")
        elif sub == "commit":
            for rel in repo.staged():
                try:
                    repo.check(role, os.path.join(repo.root, rel), True)
                except Block as b:
                    raise Block(f"git commit would commit a path this role may not write: {b}")


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
