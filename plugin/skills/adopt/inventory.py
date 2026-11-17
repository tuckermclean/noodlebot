"""Summarise a repository for an adoption session and propose areas small enough for one session each (A03).

  python3 -I plugin/skills/adopt/inventory.py <checkout> [--json] [--glob GLOB] [--unowned] [--areas] [--max-lines N]

Lists the tracked files (git ls-files) with language and non-blank line count, entrypoints (shebang, `if __name__ ==
"__main__"`, a package manifest's main/bin, executable mode), tests, CI files, candidate out-of-scope paths (vendor/,
node_modules/, .venv/, dist/, build/ at any depth, files with a "generated" header) and the import, require and source
links between files. A submodule is one entry and is not descended.

  (default)    a short text summary
  --json       one object: files, languages, entrypoints, tests, ci, candidates, links, unowned, areas
  --glob GLOB  limit every list to the paths A02's matcher (owns.match) accepts
  --unowned    the tracked files no node's `owns` and no `out_of_scope` glob of docs/graph.yaml covers, not the regime's
               own files, one per line; nothing without a graph or without ownership
  --areas      the proposed areas (name, lines, globs, files), in an order where an area follows the areas it imports
               from; --max-lines N (default 4000) is the size above which a folder is split

A missing docs/graph.yaml is a repository with no ownership, not an error. Standard library plus PyYAML.
"""
import argparse
import bisect
import heapq
import json
import os
import posixpath
import re
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "node"))
import owns  # noqa: E402

DEFAULT_MAX_LINES = 4000
EXT_LANG = {
    ".py": "python", ".js": "javascript", ".mjs": "javascript", ".cjs": "javascript", ".jsx": "javascript",
    ".ts": "typescript", ".tsx": "typescript", ".sh": "shell", ".bash": "shell", ".zsh": "shell",
    ".md": "markdown", ".yml": "yaml", ".yaml": "yaml", ".json": "json", ".toml": "toml", ".go": "go",
    ".rs": "rust", ".rb": "ruby", ".java": "java", ".c": "c", ".h": "c", ".cc": "cpp", ".cpp": "cpp",
    ".hpp": "cpp", ".css": "css", ".html": "html", ".sql": "sql", ".pl": "perl", ".php": "php",
}
INTERP_LANG = {"python": "python", "node": "javascript", "sh": "shell", "bash": "shell", "dash": "shell",
               "zsh": "shell", "ksh": "shell", "ruby": "ruby", "perl": "perl"}
CANDIDATE_DIRS = ("vendor", "node_modules", ".venv", "dist", "build")
TEST_DIRS = ("tests", "test", "spec", "testdata", "fixtures")
JS_EXTS = (".js", ".mjs", ".cjs", ".jsx", ".ts", ".tsx", ".json")
HASH, CLIKE = ("#",), ("//", "/*", "*")
COMMENT_STARTS = {
    "python": HASH, "shell": HASH, "yaml": HASH, "toml": HASH, "ruby": HASH, "perl": HASH,
    "javascript": CLIKE, "typescript": CLIKE, "go": CLIKE, "rust": CLIKE, "java": CLIKE, "c": CLIKE,
    "cpp": CLIKE, "css": ("/*", "*"), "php": ("#",) + CLIKE, "sql": ("--", "/*", "*"),
    "html": ("<!--",), "markdown": ("<!--",), "json": (),
}
COMMENT_STARTS_OTHER = ("#", "//", "/*", "--", ";", "<!--")


def git_files(root):
    r = subprocess.run(["git", "-C", root, "ls-files", "-s", "-z"], capture_output=True)
    if r.returncode != 0:
        sys.exit("inventory.py: git ls-files failed in %s: %s" % (root, r.stderr.decode(errors="replace").strip()))
    out = {}
    for rec in r.stdout.decode(errors="surrogateescape").split("\0"):
        if rec:
            meta, path = rec.split("\t", 1)
            out[path] = meta.split()[0]
    return out


def read_text(root, path, mode):
    if mode in ("160000", "120000"):  # submodule or symlink: one entry, never read
        return None
    try:
        with open(os.path.join(root, path), "rb") as f:
            data = f.read()
    except OSError:
        return None
    if b"\0" in data[:8192]:
        return None
    return data.decode("utf-8", errors="replace")


def interpreter(text):
    if not text.startswith("#!"):
        return None
    toks = text.split("\n", 1)[0][2:].split()
    if toks and posixpath.basename(toks[0]) == "env":
        toks = [t for t in toks[1:] if not t.startswith("-")]
    if not toks:
        return None
    name = posixpath.basename(toks[0])
    return re.sub(r"[\d.]+$", "", name) or name


def language(path, text):
    ext = posixpath.splitext(path)[1].lower()
    if ext in EXT_LANG:
        return EXT_LANG[ext]
    if text:
        return INTERP_LANG.get(interpreter(text) or "", "other")
    return "other"


def candidate_folder(path):
    parts = path.split("/")
    for i, p in enumerate(parts[:-1]):
        if p in CANDIDATE_DIRS:
            return "/".join(parts[: i + 1]) + "/"
    return None


GENERATED_RE = re.compile(r"@generated|(?:auto-?)?generated (?:by|from)|this file (?:is|was) (?:auto-?)?generated"
                          r"|code generated", re.I)
DO_NOT_EDIT_RE = re.compile(r"do not edit", re.I)
GENERATED_WORD_RE = re.compile(r"generated", re.I)
DOC_START = re.compile(r"""^[rRuUbB]?(\"\"\"|\'\'\')""")


def is_generated(text, lang="other"):
    """A generated-file marker on a comment or docstring line among the first five lines. "Do not edit" counts
    only beside the word generated in the same header."""
    starts = COMMENT_STARTS.get(lang, COMMENT_STARTS_OTHER)
    in_doc = None
    header = []
    for line in text.split("\n", 5)[:5]:
        s = line.strip()
        m = DOC_START.match(s) if lang == "python" else None
        if m and in_doc is None:
            in_doc = m.group(1)
            commentish = True
            if s.count(in_doc) >= 2:
                in_doc = None
        else:
            commentish = in_doc is not None or (bool(starts) and s.startswith(starts))
            if in_doc is not None and in_doc in s:
                in_doc = None
        if commentish:
            if GENERATED_RE.search(s):
                return True
            header.append(s)
    h = "\n".join(header)
    return bool(DO_NOT_EDIT_RE.search(h) and GENERATED_WORD_RE.search(h))


def is_test(path):
    parts = path.split("/")
    base = parts[-1]
    return (any(p in TEST_DIRS for p in parts[:-1]) or base.startswith("test_")
            or re.fullmatch(r".*_test\..*", base) is not None or re.fullmatch(r".*\.test\..*", base) is not None)


def is_ci(path):
    return (path.startswith(".github/workflows/") or path.startswith(".circleci/")
            or posixpath.basename(path) in (".gitlab-ci.yml", "Jenkinsfile"))


# ---------- links ----------
def first_hit(cands, tracked):
    return next((c for c in cands if c in tracked), None)


def py_cands(base, mod):
    p = posixpath.normpath(posixpath.join(base, mod.replace(".", "/"))) if mod else posixpath.normpath(base or ".")
    p = "" if p == "." else p
    return [p + ".py", p + "/__init__.py"] if p else []


def py_resolve(source, level, mod, tracked):
    here = posixpath.dirname(source)
    if level:
        base = here
        for _ in range(level - 1):
            base = posixpath.dirname(base)
        return first_hit(py_cands(base, mod), tracked)
    for base in ("", "src", here):
        hit = first_hit(py_cands(base, mod), tracked)
        if hit:
            return hit
    return None


def py_links(source, text, tracked):
    out = []
    for line in text.split("\n"):
        line = line.split("#", 1)[0]
        m = re.match(r"\s*import\s+(.+)", line)
        if m:
            for part in m.group(1).split(","):
                name = part.strip().split(" as ")[0].strip()
                if re.fullmatch(r"[\w.]+", name):
                    out.append((source, "import", name, py_resolve(source, 0, name, tracked)))
            continue
        m = re.match(r"\s*from\s+(\.*)([\w.]*)\s+import\s+(.+)", line)
        if m:
            level, mod = len(m.group(1)), m.group(2)
            names = [n.strip().split(" as ")[0].strip(" ()\\") for n in m.group(3).split(",")]
            subs = [py_resolve(source, level, (mod + "." if mod else "") + n, tracked)
                    for n in names if re.fullmatch(r"\w+", n)]
            subs = [s for s in subs if s]
            raw = m.group(1) + mod
            if subs:
                out += [(source, "import", raw, s) for s in sorted(set(subs))]
            else:
                out.append((source, "import", raw, py_resolve(source, level, mod, tracked)))
    return out


JS_RES = [re.compile(r"""\b(?:import|export)\b[^'";]*?\bfrom\s*(['"])([^'"\n]+)\1"""),
          re.compile(r"""\bimport\s*(['"])([^'"\n]+)\1"""),
          re.compile(r"""\brequire\(\s*(['"])([^'"\n]+)\1\s*\)""")]


def js_resolve(source, raw, tracked):
    if not raw.startswith("."):
        return None
    p = posixpath.normpath(posixpath.join(posixpath.dirname(source), raw))
    cands = [p] + [p + e for e in JS_EXTS] + [p + "/index" + e for e in JS_EXTS]
    stem, ext = posixpath.splitext(p)
    if ext in (".js", ".jsx", ".mjs", ".cjs"):
        cands += [stem + e for e in (".ts", ".tsx")]
    return first_hit(cands, tracked)


def js_links(source, text, tracked):
    hits = sorted({(m.start(), m.group(2)) for rx in JS_RES for m in rx.finditer(text)})
    return [(source, "require", raw, js_resolve(source, raw, tracked)) for _, raw in hits]


def sh_resolve(source, raw, tracked):
    raw = re.sub(r"^(\$\{[^}]*\}|\$[A-Za-z_]\w*)/", "", raw)
    p = raw.lstrip("/") if raw.startswith("/") else raw
    if "$" in p or not p:
        return None
    here = posixpath.dirname(source)
    return first_hit([posixpath.normpath(posixpath.join(here, p)), posixpath.normpath(p)], tracked)


def sh_links(source, text, tracked):
    out = []
    for line in text.split("\n"):
        m = re.match(r"\s*(?:source|\.)\s+(.+)", line)
        if not m:
            continue
        rest = re.sub(r"\"?\$\(dirname\s+\"?\$\{?0\}?\"?\)\"?", "", m.group(1)).strip()
        toks = rest.replace('"', "").replace("'", "").split()
        if toks:
            raw = toks[0].rstrip(";")
            out.append((source, "source", raw, sh_resolve(source, raw, tracked)))
    return out


# ---------- ownership ----------
def load_ownership(root):
    """The owned globs of docs/graph.yaml: a list, empty without a graph. An unreadable graph exits 2."""
    path = os.path.join(root, "docs", "graph.yaml")
    if not os.path.isfile(path):
        return []
    try:
        import yaml
        with open(path) as f:
            g = yaml.safe_load(f)
    except Exception as e:
        print("inventory.py: cannot read docs/graph.yaml: %s" % e, file=sys.stderr)
        sys.exit(2)
    if g is None:
        return []

    def bad(what):
        print("inventory.py: docs/graph.yaml: %s" % what, file=sys.stderr)
        sys.exit(2)
    if not isinstance(g, dict):
        bad("not a mapping")
    globs = []
    nodes = g.get("nodes")
    if nodes is not None and not isinstance(nodes, list):
        bad("nodes is not a list")
    for n in nodes or []:
        if not isinstance(n, dict):
            bad("a nodes entry is not a mapping")
        o = n.get("owns")
        if o is not None and (not isinstance(o, list) or not all(isinstance(x, str) for x in o)):
            bad("owns of node %s is not a list of globs" % n.get("id", "?"))
        globs += o or []
    oos = g.get("out_of_scope")
    if oos is not None and not isinstance(oos, list):
        bad("out_of_scope is not a list")
    for o in oos or []:
        if not isinstance(o, dict) or not isinstance(o.get("glob"), str):
            bad("an out_of_scope entry is not a mapping with a glob string")
        globs.append(o["glob"])
    return globs


# ---------- areas ----------
def kebab(s):
    s = re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-") or "root"
    return s + "-area" if s in ("scaffold", "plan") else s


def chunks(files, lines, limit):
    groups, cur, n = [], [], 0
    for f in sorted(files):
        if cur and n + lines[f] > limit:
            groups.append(cur)
            cur, n = [], 0
        cur.append(f)
        n += lines[f]
    return groups + ([cur] if cur else [])


def split_folder(folder, files, lines, limit, force=False):
    """[(label, files, whole_folder)]: a folder, or its subfolders and groups of its own files when over the limit."""
    if not force and (sum(lines[f] for f in files) <= limit or len(files) == 1):
        return [(folder, sorted(files), True)]
    cut = len(folder) + 1 if folder else 0
    own, subs = [], {}
    for f in files:
        if "/" not in f[cut:]:
            own.append(f)
        else:
            subs.setdefault(f[cut:].split("/", 1)[0], []).append(f)
    out = []
    for name in sorted(subs):
        out += split_folder((folder + "/" if folder else "") + name, subs[name], lines, limit)
    label = (folder + "-files" if subs else folder) if folder else "root"
    groups = chunks(own, lines, limit)
    for i, g in enumerate(groups, 1):
        out.append((label + ("-%d" % i if len(groups) > 1 else ""), g, False))
    return out


def folder_counts(paths):
    """{"a/b/": number of tracked files under it} for every folder of the tracked paths, counted once."""
    counts = {}
    for p in paths:
        i = p.find("/")
        while i >= 0:
            counts[p[: i + 1]] = counts.get(p[: i + 1], 0) + 1
            i = p.find("/", i + 1)
    return counts


def cover(inside, counts):
    """The largest folders whose tracked files are all in the area, and single files only where needed. Walks only
    the area's own folders: a folder is whole when it holds as many of the area's files as tracked files."""
    held, own, subs = {}, {}, {}
    for p in inside:
        prev, i = "", p.find("/")
        while i >= 0:
            f = p[: i + 1]
            held[f] = held.get(f, 0) + 1
            subs.setdefault(prev, set()).add(p[len(prev): i])
            prev, i = f, p.find("/", i + 1)
        own.setdefault(prev, []).append(p)

    def walk(prefix):
        if prefix and held[prefix] == counts[prefix]:
            return [prefix]
        out = sorted(own.get(prefix, []))
        for name in sorted(subs.get(prefix, ())):  # by name, as "a" < "a-b" while "a-b/" < "a/"
            out += walk(prefix + name + "/")
        return out
    return walk("")


def components(deps):
    """For each node of the graph deps (node -> the nodes it points to), the lowest node of its strongly connected
    component. Tarjan's algorithm with an explicit stack, so a long chain does not reach the recursion limit."""
    n = len(deps)
    index, low, comp = [None] * n, [0] * n, [None] * n
    stack, on, counter = [], [False] * n, 0
    for root in range(n):
        if index[root] is not None:
            continue
        work = [(root, iter(sorted(deps[root])))]
        index[root] = low[root] = counter
        counter += 1
        stack.append(root)
        on[root] = True
        while work:
            v, it = work[-1]
            for w in it:
                if index[w] is None:
                    index[w] = low[w] = counter
                    counter += 1
                    stack.append(w)
                    on[w] = True
                    work.append((w, iter(sorted(deps[w]))))
                    break
                if on[w]:
                    low[v] = min(low[v], index[w])
            else:
                work.pop()
                if work:
                    u = work[-1][0]
                    low[u] = min(low[u], low[v])
                if low[v] == index[v]:
                    group = []
                    while True:
                        w = stack.pop()
                        on[w] = False
                        group.append(w)
                        if w == v:
                            break
                    first = min(group)
                    for w in group:
                        comp[w] = first
    return comp


def propose_areas(files, lines, links, tracked_tree, limit):
    parts = split_folder("", sorted(files), lines, limit, force=True)
    counts = folder_counts(tracked_tree)
    parts.sort(key=lambda p: p[1][0])
    areas, names = [], set()
    for label, fs, whole in parts:
        name = base = kebab(label)
        k = 2
        while name in names:
            name, k = "%s-%d" % (base, k), k + 1
        names.add(name)
        globs = cover(fs, counts)
        areas.append({"name": name, "globs": globs, "files": fs, "lines": sum(lines[f] for f in fs)})
    where = {f: i for i, a in enumerate(areas) for f in a["files"]}
    deps = [set() for _ in areas]
    for src, _kind, _raw, tgt in links:
        if src in where and tgt in where and where[src] != where[tgt]:
            deps[where[src]].add(where[tgt])
    # areas joined by a cycle form one component; each step places the first component left whose imports are all
    # placed (a component's index is its first area's), its areas by index
    comp = components(deps)
    members = {}
    for i, c in enumerate(comp):
        members.setdefault(c, []).append(i)
    cdeps = {c: {comp[j] for i in ms for j in deps[i]} - {c} for c, ms in members.items()}
    waiting = {c: len(d) for c, d in cdeps.items()}
    users = {c: [] for c in members}
    for c, d in cdeps.items():
        for e in d:
            users[e].append(c)
    ready = [c for c, w in waiting.items() if w == 0]
    heapq.heapify(ready)
    order = []
    while ready:
        c = heapq.heappop(ready)
        order += members[c]
        for u in users[c]:
            waiting[u] -= 1
            if waiting[u] == 0:
                heapq.heappush(ready, u)
    return [areas[i] for i in order]


# ---------- the inventory ----------
def build(root, glob, limit):
    modes = git_files(root)
    paths = sorted(modes)
    tree = owns.Tree(paths)
    tracked = set(paths)
    texts = {p: read_text(root, p, modes[p]) for p in paths}
    try:
        with open(os.path.join(root, "AGENTS.md"), errors="replace") as f:
            agents = f.read()
    except OSError:
        agents = ""
    regime = set(owns.regime_files(agents, tree))
    globs = load_ownership(root)
    owned = {p for p in paths if any(owns.match(g, p, tree) for g in globs)}

    files, cands, entry, tests, ci, links, lines = [], [], [], [], [], [], {}
    folders = set()
    for p in paths:
        t = texts[p]
        n = sum(1 for l in t.split("\n") if l.strip()) if t else 0
        lines[p] = n
        files.append({"path": p, "language": language(p, t), "lines": n})
        folder = candidate_folder(p)
        if folder:
            folders.add(folder)
            continue
        if t and is_generated(t, files[-1]["language"]):
            cands.append({"path": p, "reason": "generated header"})
            continue
        if is_test(p):
            tests.append(p)
        if is_ci(p):
            ci.append(p)
        if modes[p] == "100755":
            entry.append({"path": p, "kind": "executable"})
        if not t:
            continue
        if interpreter(t):
            entry.append({"path": p, "kind": "shebang"})
        lang = files[-1]["language"]
        if lang == "python":
            if re.search(r"""^if\s+__name__\s*==\s*["']__main__["']""", t, re.M):
                entry.append({"path": p, "kind": "main"})
            links += py_links(p, t, tracked)
        elif lang in ("javascript", "typescript"):
            links += js_links(p, t, tracked)
        elif lang == "shell":
            links += sh_links(p, t, tracked)
        if posixpath.basename(p) == "package.json":
            entry += manifest_entries(p, t, tracked)
    reasons = {"vendor/": "vendored dependencies", "node_modules/": "installed dependencies",
               ".venv/": "virtual environment", "dist/": "build output", "build/": "build output"}
    for f in sorted(folders):
        cands.append({"path": f, "reason": reasons[posixpath.basename(f.rstrip("/")) + "/"]})

    unowned = sorted(p for p in paths if p not in owned and p not in regime) if globs else []
    cand_paths = {c["path"] for c in cands}
    eligible = [p for p in paths if candidate_folder(p) is None and p not in owned and p not in regime
                and p not in cand_paths]

    def keep(p):
        return glob is None or owns.match(glob, p, tree)

    def under(folder):
        """The tracked paths that start with folder, from the sorted list."""
        i = bisect.bisect_left(paths, folder)
        while i < len(paths) and paths[i].startswith(folder):
            yield paths[i]
            i += 1

    files = [x for x in files if keep(x["path"])]
    links = [l for l in links if keep(l[0])]
    keep_set = {x["path"] for x in files}
    areas = propose_areas([p for p in eligible if p in keep_set], lines, links, paths, limit) if eligible else []
    langs = {}
    for x in files:
        v = langs.setdefault(x["language"], {"files": 0, "lines": 0})
        v["files"] += 1
        v["lines"] += x["lines"]
    uniq = lambda xs: [dict(t) for t in sorted({tuple(sorted(x.items())) for x in xs})]
    return {
        "files": files,
        "languages": dict(sorted(langs.items())),
        "entrypoints": [x for x in uniq(entry) if keep(x["path"])],
        "tests": [p for p in tests if keep(p)],
        "ci": [p for p in ci if keep(p)],
        "candidates": [c for c in sorted(cands, key=lambda c: c["path"])
                       if keep(c["path"]) or (c["path"].endswith("/") and any(keep(p) for p in under(c["path"])))],
        "links": [{"source": s, "kind": k, "raw": r, "target": t} for s, k, r, t in links],
        "unowned": [p for p in unowned if keep(p)],
        "areas": areas,
    }


def manifest_entries(path, text, tracked):
    try:
        data = json.loads(text)
    except ValueError:
        return []
    if not isinstance(data, dict):
        return []
    refs = []
    if isinstance(data.get("main"), str):
        refs.append(data["main"])
    b = data.get("bin")
    refs += [b] if isinstance(b, str) else [v for v in b.values() if isinstance(v, str)] if isinstance(b, dict) else []
    out = set()
    for r in refs:
        for base in (posixpath.dirname(path),):
            t = posixpath.normpath(posixpath.join(base, r))
            out.add(t if t in tracked else path)
    return [{"path": p, "kind": "manifest"} for p in sorted(out)]


# ---------- text output ----------
def summary(d):
    out = ["Files: %d, lines: %d" % (len(d["files"]), sum(x["lines"] for x in d["files"])), "", "Languages:"]
    for lg, v in sorted(d["languages"].items(), key=lambda kv: (-kv[1]["lines"], kv[0])):
        out.append("  %-12s %5d files %8d lines" % (lg, v["files"], v["lines"]))
    out += ["", "Largest files:"]
    for x in sorted(d["files"], key=lambda x: (-x["lines"], x["path"]))[:10]:
        out.append("  %8d  %s  (%s)" % (x["lines"], x["path"], x["language"]))
    out += ["", "Entrypoints:"] + ["  %s  (%s)" % (e["path"], e["kind"]) for e in d["entrypoints"]]
    out += ["", "Tests:"] + ["  " + p for p in d["tests"]]
    out += ["", "CI:"] + ["  " + p for p in d["ci"]]
    out += ["", "Candidates for out of scope:"] + ["  %s  (%s)" % (c["path"], c["reason"]) for c in d["candidates"]]
    out += ["", "Links: %d (%d unresolved)" % (len(d["links"]), sum(1 for l in d["links"] if l["target"] is None))]
    return "\n".join(out)


def areas_text(areas):
    out = []
    for a in areas:
        out.append("%s  (%d lines, %d files)" % (a["name"], a["lines"], len(a["files"])))
        out.append("  globs: " + " ".join(a["globs"]))
        out += ["  " + f for f in a["files"]]
    return "\n".join(out)


def main(argv):
    ap = argparse.ArgumentParser(prog="inventory.py", description="Summarise a repository and propose areas.")
    ap.add_argument("checkout", nargs="+", help="the repository (a repeated identical path is accepted)")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--glob")
    ap.add_argument("--unowned", action="store_true")
    ap.add_argument("--areas", action="store_true")
    ap.add_argument("--max-lines", type=int, default=DEFAULT_MAX_LINES)
    a = ap.parse_args(argv)
    first = os.path.realpath(a.checkout[0])
    for extra in a.checkout[1:]:
        if os.path.realpath(extra) != first:
            ap.error("unexpected extra argument: %s" % extra)
    d = build(a.checkout[0], a.glob, max(1, a.max_lines))
    if a.json:
        print(json.dumps(d, indent=1))
    elif a.unowned:
        if d["unowned"]:
            print("\n".join(d["unowned"]))
    elif a.areas:
        if d["areas"]:
            print(areas_text(d["areas"]))
    else:
        print(summary(d))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
