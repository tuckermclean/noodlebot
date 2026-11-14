#!/usr/bin/env python3
"""The README checks of scheduler/forge.test.sh (G04-AC-1, G04-AC-8): readme_check.py <README.md> <repo root> <ops.json>
<ops.json> is `forge.py ops` (empty or missing when the CLI does not work). Prints PASS:/FAIL: lines."""
import json
import os
import re
import sys

readme, root, opsfile = sys.argv[1:4]
fails = 0


def line(ok, name, *details):
    global fails
    print("%s: %s" % ("PASS" if ok else "FAIL", name))
    if not ok:
        fails += 1
        for d in details:
            print("  " + d)


def section(text, title):
    m = re.search(r"^## %s\s*$(.*?)(?=^## |\Z)" % re.escape(title), text, re.M | re.S)
    return m.group(1) if m else None


def table(body):
    rows = []
    for l in (body or "").splitlines():
        l = l.strip()
        if l.startswith("|"):
            cells = [c.strip() for c in l.strip("|").split("|")]
            if all(re.fullmatch(r":?-{2,}:?", c) for c in cells):
                continue
            rows.append(cells)
    return rows


try:
    text = open(readme).read()
except OSError:
    text = None
try:
    ops = json.load(open(opsfile))
    assert isinstance(ops, list) and ops and all(isinstance(o, str) for o in ops)
except (OSError, ValueError, AssertionError):
    ops = None

line(text is not None, "G04-AC-1: scheduler/forges/README.md exists", "missing: " + readme)
line(ops is not None, "G04-AC-1: `forge.py ops` prints the operations as a JSON list of 'family op' strings")
text = text or ""
ops = ops or []

inv = table(section(text, "Inventory"))
head, rows = (inv[0], inv[1:]) if inv else ([], [])
line([h.lower() for h in head] == ["call site", "operation", "reads"] and rows,
     "G04-AC-1: `## Inventory` is a table `| Call site | Operation | Reads |` with rows", "header: %s, %d rows" % (head, len(rows)))
sites = [(r[0], r[1]) for r in rows if len(r) >= 2]
bad = [s for s, _ in sites if not re.fullmatch(r"`[\w./-]+:\d+`", s)]
line(sites and not bad, "G04-AC-1: every call site is `path:line`", "bad: %s" % bad[:5])
missing = [s for s, _ in sites if not os.path.exists(os.path.join(root, re.sub(r":\d+`$", "", s).strip("`")))]
line(sites and not missing, "G04-AC-1: every listed call site is a file of the repository", "missing: %s" % missing[:5])
opnames = [o.strip("`") for _, o in sites]
notexp = sorted({o for o in opnames if o not in ops})
line(sites and ops and not notexp, "G04-AC-1: every operation the README lists is exported by the interface (forge.OPERATIONS)",
     "not exported: %s" % notexp[:8])
files = {re.sub(r":\d+`$", "", s).strip("`") for s, _ in sites}
need = ["scheduler/loop.sh", "scheduler/report.py", "scheduler/issues.py", "scheduler/labels.py", "scheduler/feedback.py",
        "scheduler/site.py", "scheduler/api.py", "scheduler/nbctl.py", "scheduler/status.sh", "scheduler/version.sh",
        "scheduler/deploy.sh", "plugin/skills/triage/nodes.py"]
line(not [f for f in need if f not in files], "G04-AC-1: the inventory lists a call site in each core file that calls the forge or names a forge URL",
     "no call site in: %s" % [f for f in need if f not in files])
core = {"repo visibility", "repo default-branch", "repo clone-url", "pr list", "issue list", "issue comments", "issue create",
        "label ensure", "issue pin", "commit checks", "ci runs", "site publish", "issue events"}
line(core <= set(opnames), "G04-AC-1: the inventory covers the operations of the merge base's call sites (visibility, clone, PR lists, issues, labels, pin, checks, CI runs, site)",
     "no call site for: %s" % sorted(core - set(opnames)))

ot = table(section(text, "Operations"))
head, rows = (ot[0], ot[1:]) if ot else ([], [])
line([h.lower() for h in head] == ["operation", "github", "gitlab", "gitea", "forgejo"],
     "G04-AC-8: `## Operations` is a table `| Operation | GitHub | GitLab | Gitea | Forgejo |`", "header: %s" % head)
names = [r[0].strip("`") for r in rows if r]
line(ops and sorted(names) == sorted(ops) and len(set(names)) == len(names),
     "G04-AC-8: one row per operation of the interface, no more, no fewer",
     "missing: %s" % sorted(set(ops) - set(names)), "extra or repeated: %s" % sorted(set(names) - set(ops) | {n for n in names if names.count(n) > 1}))
bad = []
for r in rows:
    if len(r) != 5:
        bad.append("%s: %d cells" % (r[0] if r else "?", len(r)))
        continue
    for col, cell in zip(("GitHub", "GitLab", "Gitea", "Forgejo"), r[1:]):
        if not (re.search(r"\]\(https://[^)\s]+\)", cell) or cell.startswith("none: capability off")):
            bad.append("%s / %s: %r" % (r[0], col, cell[:60]))
line(rows and not bad, "G04-AC-8: every row has four filled cells, each a link to https://... API documentation or `none: capability off`",
     *bad[:8])
sys.exit(0)
