#!/usr/bin/env python3
"""The graph at a glance, for triage: one line per node with its state, deps and what it owns.

  python3 -I <skill dir>/nodes.py [--grep TERM]...      (run from the repository root)

State comes from the node branches' PRs (`node/<ID>-<name>`): merged, open #N, or none; a squash commit
subject "<ID> <name>: ..." on HEAD also counts as merged (run it on a fresh checkout of main). --grep lists,
for each term, the nodes whose spec mentions it (case-insensitive), most mentions first. Needs `gh`
authenticated for the repository; without it the state column is "?".
Reads the graph regime's layout: docs/graph.yaml (nodes: id, name, deps, track, summary) and
nodes/<ID>-<name>.md (with an **Owns:** line).
"""
import json, os, re, subprocess, sys

import yaml


def main():
    terms = [sys.argv[i + 1] for i, a in enumerate(sys.argv[:-1]) if a == "--grep"]
    g = yaml.safe_load(open("docs/graph.yaml"))
    nodes = g["nodes"]
    state = {}
    try:
        r = subprocess.run(["gh", "pr", "list", "--state", "all", "--limit", "1000", "--json",
                            "number,state,headRefName"], capture_output=True, text=True, timeout=60)
        for pr in sorted(json.loads(r.stdout), key=lambda p: p["number"]):
            m = re.match(r"node/([A-Z][0-9][0-9])-", pr["headRefName"])
            if m and not state.get(m.group(1), "").startswith("merged"):
                if pr["state"] == "MERGED":
                    state[m.group(1)] = "merged #%d" % pr["number"]
                elif pr["state"] == "OPEN":
                    state[m.group(1)] = "open #%d" % pr["number"]
    except (OSError, ValueError, subprocess.TimeoutExpired):
        state = None
    # A squash commit "<ID> <name>: ..." on HEAD also means merged (some PRs are hidden on GitHub).
    subjects = subprocess.run(["git", "log", "--format=%s", "HEAD"], capture_output=True, text=True).stdout.splitlines()
    for n in nodes:
        if any(s.startswith("%s %s:" % (n["id"], n["name"])) for s in subjects):
            if state is not None and not state.get(n["id"], "").startswith("merged"):
                state[n["id"]] = "merged"
    unlocks = {n["id"]: [] for n in nodes}
    for n in nodes:
        for d in n.get("deps", []):
            unlocks.setdefault(d, []).append(n["id"])
    specs = {}
    for n in nodes:
        p = "nodes/%s-%s.md" % (n["id"], n["name"])
        specs[n["id"]] = open(p).read() if os.path.exists(p) else ""
        owns = re.search(r"^\*\*Owns:\*\*\s*(.*)$", specs[n["id"]], re.M)
        st = "?" if state is None else state.get(n["id"], "none")
        print("%s %-22s %-11s track=%-8s deps=%-20s unlocks=%s" % (
            n["id"], n["name"], st, n.get("track", "-"), ",".join(n.get("deps", [])) or "-",
            ",".join(unlocks[n["id"]]) or "-"))
        print("    spec: %s%s" % (p, "" if specs[n["id"]] else " (MISSING)"))
        if owns:
            print("    owns: %s" % owns.group(1)[:300])
    for t in terms:
        hits = sorted(((len(re.findall(re.escape(t), s, re.I)), i) for i, s in specs.items()), reverse=True)
        print("grep %r: %s" % (t, ", ".join("%s(%d)" % (i, c) for c, i in hits if c) or "no node spec mentions it"))
    ids = [n["id"] for n in nodes]
    print("ids in use: %s" % " ".join(sorted(ids)))


if __name__ == "__main__":
    main()
