"""Prints "<ID> <name>" for the first node in graph order that the scheduler may start, or nothing.

    python3 -I ready.py --graph docs/graph.yaml --markers out/node \
        [--merged ID]... [--open ID]... [--subjects FILE]

A node is ready when it is not merged, every dep is merged, it has no open PR, and
<markers>/<ID>/ holds neither QUESTION.md nor FAILED. A node counts as merged when it is passed
with --merged (a merged node/<ID>-* PR) or when a line of --subjects (`git log --format=%s
origin/main`) starts with "<ID> <name>:", the squash subject of its PR. The second source exists
because GitHub hides the PRs of a suspended author. Any error exits non-zero and prints no node.
"""
import argparse
import os
import sys

import yaml


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--graph", required=True)
    ap.add_argument("--markers", required=True)
    ap.add_argument("--merged", action="append", default=[])
    ap.add_argument("--open", action="append", default=[])
    ap.add_argument("--subjects")
    a = ap.parse_args()

    with open(a.graph, encoding="utf-8") as f:
        nodes = yaml.safe_load(f)["nodes"]
    merged = set(a.merged)
    if a.subjects:
        with open(a.subjects, encoding="utf-8") as f:
            subjects = f.read().splitlines()
        for n in nodes:
            if any(s.startswith(f"{n['id']} {n['name']}:") for s in subjects):
                merged.add(n["id"])
    opened = set(a.open)

    for n in nodes:
        nid = n["id"]
        if nid in merged or nid in opened:
            continue
        if not all(d in merged for d in n.get("deps") or []):
            continue
        if any(os.path.exists(os.path.join(a.markers, nid, m)) for m in ("QUESTION.md", "FAILED")):
            continue
        print(f"{nid} {n['name']}")
        return 0
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # noqa: BLE001 - fail closed: never name a node after an error
        print(f"ready.py: {e}", file=sys.stderr)
        sys.exit(2)
