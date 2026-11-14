#!/usr/bin/env python3
"""The graph at a glance, for triage: one line per node with its state, deps and what it owns.

  python3 -I <skill dir>/nodes.py [--grep TERM]...      (run from the repository root)

State comes from the node branches' PRs (`node/<ID>-<name>`): merged, open #N, or none; a squash commit
subject "<ID> <name>: ..." on HEAD also counts as merged (run it on a fresh checkout of main). --grep lists,
for each term, the nodes whose spec mentions it (case-insensitive), most mentions first. The PR list comes from the
forge interface: in a session, $NOODLEBOT_FORGE (the wrapper scheduler/forge-cli.sh, which holds the token script) is run
as a CLI (`pr list`, JSON on stdout); without it the checkout's own scheduler/forge.py is imported. The repository is
$NOODLEBOT_FORGE_REPO (a session has it), else the one `origin` names; if the forge cannot be reached (the CLI exits
non-zero) the state column is "?".
Also lists the open PRs whose head branch starts with spec/ (their docs/graph.yaml is read from
origin/<branch>, so fetch first): the IDs each adds that main lacks, with its PR number; one `next free:`
line holding, for every letter in use, the number after the highest ID on main, in those PRs and in this graph (`next free: S05 T02`); and
`clash` lines for a new ID that main or another open spec PR gives to a node of another name. On a spec
branch main's graph is origin/main's and the branch's own PR is not counted as another PR. If the PR list
or a PR's graph cannot be read it says the IDs in open spec PRs are unknown, prints no `next free:` line
and exits 1.
Reads the graph regime's layout: docs/graph.yaml (nodes: id, name, deps, track, summary) and
nodes/<ID>-<name>.md (with an **Owns:** line).
"""
import json, os, re, subprocess, sys

import yaml


def import_forge(folder):
    sys.dont_write_bytecode = True  # the checkout the forge module lives in gets no __pycache__
    sys.path.insert(0, folder)
    try:
        import forge
    except ImportError:
        raise ValueError("the forge module is not found")
    finally:
        sys.path.pop(0)
    return forge


def open_forge():
    """The forge of $NOODLEBOT_FORGE_REPO, else of `origin`; ValueError when none can be opened (callers say "unknown")."""
    here = os.path.dirname(os.path.realpath(__file__))
    forge = import_forge(os.path.join(here, "..", "..", "..", "scheduler"))  # this checkout's own scheduler/
    spec = os.environ.get("NOODLEBOT_FORGE_REPO")
    if not spec:
        r = subprocess.run(["git", "remote", "get-url", "origin"], capture_output=True, text=True)
        spec = forge.repo_of_remote(r.stdout.strip()) if r.returncode == 0 else None
    if not spec:
        raise ValueError("no repository: no $NOODLEBOT_FORGE_REPO and no origin")
    try:
        return forge.open(spec), forge
    except forge.UnknownForge as e:
        raise ValueError(str(e))


def list_prs(**kw):
    """The forge's pr list; a failed call is a ValueError, as the callers treat every unreadable list."""
    cli = os.environ.get("NOODLEBOT_FORGE")
    if cli:
        return cli_prs(cli, **kw)
    f, forge = open_forge()
    try:
        return f.pr_list(**kw)
    except forge.ForgeError as e:
        raise ValueError(str(e))


def cli_prs(cli, state, limit, fields):
    """`pr list` through the session's forge CLI; the repository is $NOODLEBOT_FORGE_REPO (the CLI reads it), else origin's."""
    argv = [cli]
    if not os.environ.get("NOODLEBOT_FORGE_REPO"):
        try:
            forge = import_forge(os.path.dirname(os.path.realpath(cli)))
            r = subprocess.run(["git", "remote", "get-url", "origin"], capture_output=True, text=True)
            spec = forge.repo_of_remote(r.stdout.strip()) if r.returncode == 0 else None
        except (ValueError, OSError):
            spec = None
        if spec:
            argv += ["--repo", spec]
    argv += ["pr", "list", "--state", state, "--limit", str(limit)]
    for f in fields:
        argv += ["--fields", f]
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=120)
        if r.returncode:
            raise ValueError("forge CLI failed (%d): %s" % (r.returncode, r.stderr.strip()[:200]))
        return json.loads(r.stdout)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise ValueError(str(e))


def graph_pairs(text):
    return [(n["id"], n["name"]) for n in (yaml.safe_load(text) or {}).get("nodes", [])]


def graph_names(text):
    return dict(graph_pairs(text))


def pr_graph(p):
    """A spec PR's graph text: origin/<branch>, else (fork head) the PR's head ref fetched."""
    try:
        return git_show("origin/%s:docs/graph.yaml" % p["head"])
    except ValueError:
        r = subprocess.run(["git", "fetch", "-q", "origin", "pull/%d/head" % p["number"]],
                           capture_output=True, text=True, timeout=120)
        if r.returncode:
            raise ValueError("cannot fetch PR #%d" % p["number"])
        return git_show("FETCH_HEAD:docs/graph.yaml")


def git_show(ref):
    r = subprocess.run(["git", "show", ref], capture_output=True, text=True)
    if r.returncode:
        raise ValueError("cannot read " + ref)
    return r.stdout


def spec_pr_report(work):
    """Print the open spec PRs' new IDs, clashes and next free IDs; return False if they are unknown."""
    branch = subprocess.run(["git", "rev-parse", "--abbrev-ref", "HEAD"], capture_output=True, text=True).stdout.strip()
    try:
        workpairs = list(work)
        mainpairs = workpairs
        if branch.startswith("spec/"):
            mainpairs = graph_pairs(git_show("origin/main:docs/graph.yaml"))
        mainnames = dict(mainpairs)
        work = dict(workpairs)
        listed = list_prs(state="open", limit=1000, fields=["number", "head"])
        prs = sorted((p for p in listed
                      if (p["head"] or "").startswith("spec/") and p["head"] != branch),
                     key=lambda p: p["number"])
        added = []  # (pr number, id, name)
        allids = set(mainnames) | set(work)
        for p in prs:
            names = graph_names(pr_graph(p))
            allids |= set(names)
            added += [(p["number"], i, n) for i, n in names.items() if i not in mainnames]
    except (OSError, ValueError, KeyError, TypeError, AttributeError, yaml.YAMLError, subprocess.TimeoutExpired):
        print("IDs in open spec PRs: unknown (could not list the open PRs or read a PR's graph); no next free ID")
        return False
    for num, i, n in added:
        print("open spec PR #%d adds %s %s" % (num, i, n))
    own = [(i, n) for i, n in workpairs if (i, n) not in mainpairs] if branch.startswith("spec/") else []
    for i, n in own:
        for j, m in mainpairs:
            if j == i and m != n:
                print("clash: %s %s is %s on main" % (i, n, m))
        for num, j, m in added:
            if j == i and m != n:
                print("clash: %s %s is %s in open spec PR #%d" % (i, n, m, num))
        for j, m in workpairs:
            if j == i and m != n and (j, m) in own and n < m:
                print("clash: %s is %s and %s in this graph" % (i, n, m))
    for k, (num, i, n) in enumerate(added):
        for num2, j, m in added[k + 1:]:
            if i == j and n != m:
                print("clash: %s is %s in open spec PR #%d and %s in #%d" % (i, n, num, m, num2))
    top = {}
    for i in allids:
        m = re.match(r"([A-Z])([0-9]+)$", i)
        if m:
            top[m.group(1)] = max(top.get(m.group(1), 0), int(m.group(2)))
    if top:
        print("next free: " + " ".join("%s%02d" % (l, top[l] + 1) for l in sorted(top)))
    return True


def main():
    terms = [sys.argv[i + 1] for i, a in enumerate(sys.argv[:-1]) if a == "--grep"]
    g = yaml.safe_load(open("docs/graph.yaml"))
    nodes = g["nodes"]
    state = {}
    try:
        for pr in sorted(list_prs(state="all", limit=1000, fields=["number", "state", "head"]), key=lambda p: p["number"]):
            m = re.match(r"node/([A-Z][0-9][0-9])-", pr["head"] or "")
            if m and not state.get(m.group(1), "").startswith("merged"):
                if pr["state"] == "merged":
                    state[m.group(1)] = "merged #%d" % pr["number"]
                elif pr["state"] == "open":
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
    if not spec_pr_report([(n["id"], n["name"]) for n in nodes]):
        sys.exit(1)


if __name__ == "__main__":
    main()
