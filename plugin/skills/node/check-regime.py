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


def node_fields(i, n, p):
    st = n.get("status", "planned")
    if st not in ("planned", "imported", "pinned"):
        p("%s: unknown status %r" % (i, st))
    ow = n.get("owns")
    if "owns" in n and not (isinstance(ow, list) and all(isinstance(x, str) and x for x in ow)):
        p("%s: owns is not a list of globs" % i)
    if st in ("imported", "pinned"):
        if not (isinstance(ow, list) and ow):
            p("%s: no owns" % i)
        if n.get("track") != "done":
            p("%s: track must be done for a %s node" % (i, st))


def owns_paragraph(s):
    out, on = [], False
    for line in s.splitlines():
        if not on:
            if line.startswith("**Owns:**"):
                on = True
                out.append(line)
        elif not line.strip() or re.match(r"^\*\*[^*]+:\*\*", line):
            break
        else:
            out.append(line)
    return "\n".join(out)


def top_fields(g, by, p):
    gate = g.get("gate")
    adoption = g.get("adoption")
    if gate is None:
        if adoption is not None or any(n.get("status") in ("imported", "pinned") for n in by.values()):
            p("gate: required (the graph has imported or pinned nodes, or an adoption)")
    elif not isinstance(gate, dict):
        p("gate: not a mapping")
    else:
        cmd = gate.get("command")
        if not isinstance(cmd, str) or not cmd.strip():
            p("gate.command: not a non-empty string")
        kr = gate.get("known_red", [])
        if not isinstance(kr, list):
            p("gate.known_red: not a list")
            kr = []
        else:
            for k, e in enumerate(kr):
                if not isinstance(e, str) or not e:
                    p("gate.known_red: entry %d is not a non-empty string" % (k + 1))
        fp = gate.get("fail_pattern")
        if fp is None:
            if kr:
                p("gate.fail_pattern: required when known_red is not empty")
        else:
            try:
                if not isinstance(fp, str) or not fp:
                    raise ValueError
                re.compile(fp)
            except (re.error, ValueError):
                p("gate.fail_pattern: not a valid regular expression: %r" % (fp,))
    oos = g.get("out_of_scope")
    if oos is not None:
        if not isinstance(oos, list):
            p("out_of_scope: not a list")
        else:
            for k, e in enumerate(oos):
                if not (isinstance(e, dict) and isinstance(e.get("glob"), str) and e["glob"]
                        and isinstance(e.get("reason"), str) and e["reason"].strip()):
                    p("out_of_scope entry %d: needs a glob and a non-empty reason" % (k + 1))
    if adoption is not None:
        areas = adoption.get("areas") if isinstance(adoption, dict) else None
        if not isinstance(areas, list):
            p("adoption: areas is not a list")
            areas = []
        seen = set()
        for k, a in enumerate(areas):
            nm = a.get("name") if isinstance(a, dict) else None
            if not isinstance(nm, str) or not NAME.match(nm):
                p("adoption area %d: bad name %r (kebab-case)" % (k + 1, nm))
                continue
            if nm in ("scaffold", "plan"):
                p("adoption area %s: reserved name" % nm)
            if nm in seen:
                p("adoption area %s: duplicate name" % nm)
            seen.add(nm)
            gl = a.get("globs")
            if not (isinstance(gl, list) and gl and all(isinstance(x, str) and x for x in gl)):
                p("adoption area %s: globs must be a non-empty list of globs" % nm)


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
    for i, n in by.items():
        node_fields(i, n, p)
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
            elif n.get("status") == "pinned" and re.match(r"unpinned\b", rest.split("*Verify:*", 1)[1].strip().lstrip("`").strip()):
                p("%s-AC-%s: unpinned criterion on a pinned node" % (i, a))
        if isinstance(n.get("owns"), list):
            para = owns_paragraph(s)
            for gl in n["owns"]:
                if isinstance(gl, str) and gl and "`%s`" % gl not in para:
                    p("%s: owns glob %s not in the spec's Owns paragraph" % (i, gl))
    owners = {}
    for i, n in by.items():
        for gl in n["owns"] if isinstance(n.get("owns"), list) else []:
            if isinstance(gl, str) and i not in owners.setdefault(gl, []):
                owners[gl].append(i)
    for gl, who in owners.items():
        if len(who) > 1:
            p("%s listed by %s" % (gl, " and ".join(who)))
    top_fields(g, by, p)
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
