#!/usr/bin/env python3
"""The ownership checker for a node's branch: it changes only the files it owns and its direct deps' files (A05).

  python3 -I <this dir>/check-owns-diff.py [--repo DIR] <ID> <from> <to>    (--repo default: the current directory)

Judges `git diff --name-status -M <from>...<to>` (from the merge base, so what came in from main is not the
node's; renames are judged by both paths, a deletion by its old path). The node's deps and the deps' globs
are read from docs/graph.yaml at <from>, the node's own globs from the graph at <to>. Each changed path
(old path of a rename or deletion, new path of the rest, an added path alike) must match an own glob or a
direct dep's glob; the regime's own files (owns.regime_files of AGENTS.md at <to>, over the files at <to>
and at <from>) are exempt. Globs resolve folders against the tracked files at <to> (at <from> for an old path).
Prints the globs it used (`OWN GLOBS ...`, `DEP GLOBS <ID> ...`), then one line each:
- `NOT OWNED <path> (owner: <ID or none>)`: the owner is the node owning the path in the graph at <from>,
  else in the graph at <to>, else none;
- `UNUSED <glob>`: an own glob matching no file at <to>.
A graph (at <from>) with no owns, out_of_scope or adoption prints `no ownership declared` and exits 0.
Exits 0 when clean, 1 on any NOT OWNED or UNUSED, 2 when git fails (an unknown commit).
"""
import os
import subprocess
import sys

import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import owns  # noqa: E402


class GitError(Exception):
    pass


def git(repo, *args, check=True):
    r = subprocess.run(["git", "-C", repo] + list(args), capture_output=True, text=True)
    if r.returncode and check:
        raise GitError("git %s: %s" % (" ".join(args), r.stderr.strip()))
    return r.stdout if r.returncode == 0 else ""


def load_graph(repo, rev):
    return yaml.safe_load(git(repo, "show", rev + ":docs/graph.yaml")) or {}


def node_of(g, nid):
    for n in g.get("nodes") or []:
        if n.get("id") == nid:
            return n
    return {}


def main():
    a = sys.argv[1:]
    repo = "."
    if a[:1] == ["--repo"]:
        if len(a) < 2:
            raise GitError("--repo needs a value")
        repo, a = a[1], a[2:]
    if len(a) != 3:
        raise GitError("usage: check-owns-diff.py [--repo DIR] <ID> <from> <to>")
    nid, frm, to = a
    gfrom = load_graph(repo, frm)
    gto = load_graph(repo, to)
    nodes = gfrom.get("nodes") or []
    oos = gfrom.get("out_of_scope") or []
    areas = (gfrom.get("adoption") or {}).get("areas") or []
    if not (oos or areas or any(n.get("owns") for n in nodes)):
        print("no ownership declared")
        return 0
    ls = lambda rev: sorted(x for x in git(repo, "ls-tree", "-r", "-z", "--name-only", rev).split("\0") if x)
    tree_to, tree_from = owns.Tree(ls(to)), owns.Tree(ls(frm))
    tokens = git(repo, "diff", "--name-status", "-z", "-M", frm + "..." + to).split("\0")
    judged = []  # (path, tree it resolves in)
    i = 0
    while i < len(tokens) and tokens[i]:
        st = tokens[i]
        if st[0] in "RC":
            judged += [(tokens[i + 1], tree_from), (tokens[i + 2], tree_to)]
            i += 3
        else:
            judged.append((tokens[i + 1], tree_from if st[0] == "D" else tree_to))
            i += 2
    own = list(node_of(gto, nid).get("owns") or [])
    deps = {d: list(node_of(gfrom, d).get("owns") or []) for d in node_of(gfrom, nid).get("deps") or []}
    print("OWN GLOBS %s: %s" % (nid, " ".join(own)))
    for d, gl in deps.items():
        print("DEP GLOBS %s: %s" % (d, " ".join(gl)))
    agents = git(repo, "show", to + ":AGENTS.md", check=False)
    exempt = set(owns.regime_files(agents, owns.Tree(sorted(set(tree_to) | set(tree_from)))))
    mine = [(gl, None) for gl in own] + [(gl, None) for gl_l in deps.values() for gl in gl_l]
    problems = []
    for path, tree in judged:
        if path in exempt or any(owns.match(gl, path, tree) for gl, _ in mine):
            continue
        who = sorted({n["id"] for n in nodes for gl in n.get("owns") or [] if owns.match(gl, path, tree)})
        if not who:
            who = sorted({n["id"] for n in gto.get("nodes") or [] for gl in n.get("owns") or [] if owns.match(gl, path, tree)})
        problems.append("NOT OWNED %s (owner: %s)" % (path, ", ".join(who) or "none"))
    for gl in own:
        if not any(owns.match(gl, f, tree_to) for f in tree_to):
            problems.append("UNUSED %s" % gl)
    for line in problems:
        print(line)
    return 1 if problems else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except GitError as e:
        print("check-owns-diff: %s" % e)
        sys.exit(2)
