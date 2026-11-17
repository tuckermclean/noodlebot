#!/usr/bin/env python3
"""The graph regime's coverage checker: every tracked file is accounted for in docs/graph.yaml (A04).

  python3 -I <this dir>/check-coverage.py [--root DIR] [--ref REV]    (default: the current directory, the working tree)

Without --ref the graph and AGENTS.md are the working tree's, the files `git ls-files`, the merged
subjects `git log` at HEAD. With --ref REV all four come from that commit. Matching is owns.py's.
Each file must be owned by exactly one node, or be matched by an out_of_scope glob, or by an adoption
area's globs, or be one of the regime's own files (owns.regime_files; those are skipped).
Problems, one line each:
- a file no node owns that is not exempt, out of scope or in an area;
- a file two nodes own (both named);
- a file a node owns that an out_of_scope glob or an adoption area also matches (both named);
- a glob of an imported or pinned node, or of a planned node that is merged (a subject of
  `git log --format=%s` starting `<ID> <name>:`), that matches no file.
A graph with no owns, out_of_scope or adoption prints `no ownership declared`.
Prints `PROBLEMS <n>`; exits 1 when n > 0.
"""
import os
import subprocess
import sys

import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import owns  # noqa: E402


def git(root, *args, check=True):
    r = subprocess.run(["git", "-C", root] + list(args), capture_output=True, text=True)
    if check and r.returncode:
        raise RuntimeError("git %s: %s" % (" ".join(args), r.stderr.strip()))
    return r.stdout if r.returncode == 0 else ""


def main():
    a = sys.argv[1:]
    root = a[a.index("--root") + 1] if "--root" in a else "."
    ref = a[a.index("--ref") + 1] if "--ref" in a else None
    if ref:
        graph = git(root, "show", ref + ":docs/graph.yaml")
        files = git(root, "ls-tree", "-r", "--name-only", ref).splitlines()
        agents = git(root, "show", ref + ":AGENTS.md", check=False)
    else:
        graph = open(os.path.join(root, "docs/graph.yaml")).read()
        files = git(root, "ls-files").splitlines()
        p = os.path.join(root, "AGENTS.md")
        agents = open(p).read() if os.path.exists(p) else ""
    subjects = git(root, "log", "--format=%s", ref or "HEAD", check=False).splitlines()
    g = yaml.safe_load(graph) or {}
    nodes = g.get("nodes") or []
    oos = [e["glob"] for e in (g.get("out_of_scope") or [])]
    areas = [(ar["name"], gl) for ar in ((g.get("adoption") or {}).get("areas") or []) for gl in ar["globs"]]
    if not (oos or areas or any(n.get("owns") for n in nodes)):
        print("no ownership declared")
        print("PROBLEMS 0")
        return 0
    tree = owns.Tree(sorted(files))
    exempt = set(owns.regime_files(agents, tree))
    problems = []
    for f in tree:
        if f in exempt:
            continue
        who = sorted({n["id"] for n in nodes for gl in n.get("owns") or [] if owns.match(gl, f, tree)})
        outs = [("out_of_scope " + gl) for gl in oos if owns.match(gl, f, tree)]
        outs += [("adoption area " + nm) for nm, gl in areas if owns.match(gl, f, tree)]
        if len(who) > 1:
            problems.append("%s: owned by %s" % (f, " and ".join(who)))
        if who and outs:
            problems.append("%s: owned by %s and also in %s" % (f, " and ".join(who), ", ".join(sorted(set(outs)))))
        if not who and not outs:
            problems.append("%s: no node owns it, and it is not out of scope or in an adoption area" % f)
    for n in nodes:
        st = n.get("status", "planned")
        merged = any(s.startswith("%s %s:" % (n["id"], n["name"])) for s in subjects)
        if st == "planned" and not merged:
            continue
        for gl in n.get("owns") or []:
            if not any(owns.match(gl, f, tree) for f in tree):
                problems.append("%s: owns glob %s matches no file" % (n["id"], gl))
    for line in problems:
        print(line)
    print("PROBLEMS %d" % len(problems))
    return 1 if problems else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        print("check-coverage: %s" % e)
        print("PROBLEMS 1")
        sys.exit(1)
