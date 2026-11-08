#!/usr/bin/env python3
"""The graph regime's generic spec checker: docs/graph.yaml against nodes/<ID>-<name>.md.

  python3 -I <this dir>/check-regime.py [--root DIR]        (default: the current directory)

Checks:
- the graph: every node has an id (a capital letter and two digits), a kebab-case name and a deps
  list; ids are unique; deps resolve; no cycles;
- every node has its spec nodes/<ID>-<name>.md, whose title is "# <ID> — <name>";
- a header row `| Track | Deps | Unlocks | ...` (if the spec has one) matches the graph: track,
  deps and the nodes that depend on this one;
- the spec has the headings `## <h>` the repository's template names (graph.yaml
  `template: {headings: [...]}`; default Purpose, Tests, Gate, Risks);
- the Gate's criteria are `**<ID>-AC-<n>**`, numbered from 1 without gaps, each with *Verify:*.
Prints one line per problem, then `PROBLEMS <n>`; exits 1 when n > 0. A repository may run its own
checker on top of this one (its AGENTS.md says which).
"""
import os
import re
import sys

import yaml

ID = re.compile(r"^[A-Z][0-9][0-9]$")
NAME = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")


def main():
    root = sys.argv[sys.argv.index("--root") + 1] if "--root" in sys.argv else "."
    g = yaml.safe_load(open(os.path.join(root, "docs/graph.yaml")))
    nodes = g.get("nodes") or []
    want = ((g.get("template") or {}).get("headings")) or ["Purpose", "Tests", "Gate", "Risks"]
    problems = []
    p = problems.append
    ids = [n.get("id") for n in nodes]
    by = {}
    for n in nodes:
        i = n.get("id")
        if not isinstance(i, str) or not ID.match(i):
            p("bad node id %r" % i)
            continue
        if i in by:
            p("%s: duplicate id" % i)
        by[i] = n
        if not isinstance(n.get("name"), str) or not NAME.match(n["name"]):
            p("%s: bad name %r" % (i, n.get("name")))
        if not isinstance(n.get("deps"), list):
            p("%s: deps is not a list" % i)
            n["deps"] = []
        for d in n["deps"]:
            if d not in ids:
                p("%s: unknown dep %s" % (i, d))
    # cycles
    state = {}

    def visit(i, path):
        if state.get(i) == 1:
            p("cycle: %s" % " -> ".join(path + [i]))
            return
        if state.get(i) == 2 or i not in by:
            return
        state[i] = 1
        for d in by[i]["deps"]:
            visit(d, path + [i])
        state[i] = 2

    for i in by:
        visit(i, [])
    unlocks = {i: sorted(j for j in by if i in by[j]["deps"]) for i in by}

    for i, n in by.items():
        f = os.path.join(root, "nodes", "%s-%s.md" % (i, n.get("name")))
        if not os.path.exists(f):
            p("%s: no spec %s" % (i, os.path.relpath(f, root)))
            continue
        s = open(f).read()
        if not re.match(r"^# %s — %s\s*$" % (i, re.escape(str(n.get("name")))), s.splitlines()[0] if s else ""):
            p("%s: the title is not '# %s — %s'" % (i, i, n.get("name")))
        lines = s.splitlines()
        for k, line in enumerate(lines):
            if line.startswith("| Track | Deps | Unlocks"):
                row = [c.strip() for c in (lines[k + 2] if k + 2 < len(lines) else "").strip("|").split("|")]
                exp = [str(n.get("track", "")), ", ".join(n["deps"]) or "none", ", ".join(unlocks[i]) or "none"]
                if row[:3] != exp:
                    p("%s: header row %s, the graph says %s" % (i, row[:3], exp))
                break
        heads = re.findall(r"^## (.+?)\s*$", s, re.M)
        missing = [h for h in want if h not in heads]
        if missing:
            p("%s: missing headings %s" % (i, missing))
        gate = s.split("## Gate", 1)[1].split("\n## ", 1)[0] if "## Gate" in s else ""
        acs = re.findall(r"^- \*\*%s-AC-(\d+)\*\*(.*)$" % i, gate, re.M)
        nums = [int(a) for a, _ in acs]
        if nums != list(range(1, len(nums) + 1)):
            p("%s: criteria numbered %s, want 1..%d" % (i, nums, len(nums)))
        if not acs and "Gate" in want:
            p("%s: no criteria in the Gate" % i)
        for a, rest in acs:
            if "*Verify:*" not in rest:
                p("%s-AC-%s: no *Verify:*" % (i, a))
    for line in problems:
        print(line)
    print("%d nodes, %d criteria" % (len(by), sum(len(re.findall(r"-AC-\d+\*\*", open(os.path.join(root, "nodes", "%s-%s.md" % (i, n.get("name")))).read()))
                                              for i, n in by.items() if os.path.exists(os.path.join(root, "nodes", "%s-%s.md" % (i, n.get("name")))))))
    print("PROBLEMS %d" % len(problems))
    return 1 if problems else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        print("check-regime: %s" % e)
        print("PROBLEMS 1")
        sys.exit(1)
