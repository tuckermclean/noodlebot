"""Prints "<ID> <name>" for the first node in graph order that the scheduler may start, or nothing;
with --all, one line for every such node, in graph order.

    python3 -I ready.py --graph docs/graph.yaml --markers out/node \
        [--merged ID]... [--open ID]... [--subjects FILE] [--merged-prs FILE] [--all]

A node is ready when it is not merged, every dep is merged, and its markers in <markers>/<ID>/
allow it:
- FAILED holds it.
- QUESTION.md holds it until the owner writes ANSWER.md next to it.
- WAITING-PR (a bare PR number, written by a session that opened a spec PR) holds it until that
  number is listed in --merged-prs (one merged PR number per line).
With no markers, a node with an open PR is not ready (it waits for the owner). An answered question
or a merged WAITING-PR makes it ready even with its PR open, so the session can resume.
A merged node is printed with a third word, "followup", when its markers say resume, or when only
a FOLLOWUP marker is there and it has no open PR.
A node counts as merged when it is passed
with --merged (a merged node/<ID>-* PR) or when a line of --subjects (`git log --format=%s
origin/main`) starts with "<ID> <name>:", the squash subject of its PR. The second source exists
because GitHub hides the PRs of a suspended author. Any error exits non-zero and prints no node.
"""
import argparse
import os
import sys

import yaml


def markers(d: str, merged_prs: set) -> str:
    """'hold', 'resume' (an answer or a merged spec PR to act on), 'followup' (a FOLLOWUP marker only) or 'none'."""
    has = lambda m: os.path.exists(os.path.join(d, m))  # noqa: E731
    if has("FAILED"):
        return "hold"
    resume = False
    if has("QUESTION.md"):
        if not has("ANSWER.md"):
            return "hold"
        resume = True
    if has("WAITING-PR"):
        with open(os.path.join(d, "WAITING-PR"), encoding="utf-8") as f:
            num = f.read().strip()
        if not num.isdigit() or num not in merged_prs:
            return "hold"
        resume = True
    if resume:
        return "resume"
    return "followup" if has("FOLLOWUP") else "none"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--graph", required=True)
    ap.add_argument("--markers", required=True)
    ap.add_argument("--merged", action="append", default=[])
    ap.add_argument("--open", action="append", default=[])
    ap.add_argument("--subjects")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--merged-prs")
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
    merged_prs = set()
    if a.merged_prs:
        with open(a.merged_prs, encoding="utf-8") as f:
            merged_prs = {line.strip() for line in f if line.strip()}

    for n in nodes:
        nid = n["id"]
        is_merged = nid in merged
        if not is_merged and not all(d in merged for d in n.get("deps") or []):
            continue
        state = markers(os.path.join(a.markers, nid), merged_prs)
        if is_merged:
            if state == "none" or state == "hold" or (state == "followup" and nid in opened):
                continue
        elif state == "hold" or (state in ("none", "followup") and nid in opened):
            continue
        print(f"{nid} {n['name']}" + (" followup" if is_merged else ""))
        if not a.all:
            return 0
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # noqa: BLE001 - fail closed: never name a node after an error
        print(f"ready.py: {e}", file=sys.stderr)
        sys.exit(2)
