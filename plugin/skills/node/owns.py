"""The one glob matcher for ownership, and the regime's own files (A02; A03, A04 and A05 import it).

  import owns
  owns.match(glob, path, files=None) -> bool
      A root-relative path against one glob. `*` matches within one path component, `**` as a whole
      component matches zero or more components, a trailing `/` means the folder and everything under it,
      and a glob with no wildcard that names a folder among `files` (some tracked path starts with
      glob + "/") means the same; otherwise a wildcard-free glob is a literal path. Only `*` is a
      wildcard: `?` and `[` are literal. The folder set of `files` is built once per list and kept
      (the last list, by identity), so a caller must not mutate `files` between calls; owns.Tree(files)
      is the recommended form: build it once and pass it as `files`.
  owns.Tree(files)
      The tracked paths with their folder set (every proper prefix of every path) precomputed.
  owns.regime_files(agents_text, files) -> list
      The paths in `files` that are the regime's own and no node owns: the spec files as
      check-spec-diff.py reads them, entry by entry, not as globs (the **Spec files:** line of AGENTS.md's "Building a node" section,
      else SPEC.md, docs/graph.yaml and nodes/), plus AGENTS.md and .noodlebot/roles.yaml.

The caller passes AGENTS.md's text and the tracked-file list at the commit it judges; this module
never reads the working tree. Standard library only.
"""
import importlib.util
import os
import re

REGIME_EXTRA = ["AGENTS.md", ".noodlebot/roles.yaml"]


def _spec_diff():
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location("_check_spec_diff", os.path.join(here, "check-spec-diff.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _comp(pat, name):
    rx = "".join("[^/]*" if c == "*" else re.escape(c) for c in pat) if "*" in pat else None
    return name == pat if rx is None else re.fullmatch(rx, name) is not None


def _walk(gs, ps):
    if not gs:
        return not ps
    if gs[0] == "**":
        return any(_walk(gs[1:], ps[k:]) for k in range(len(ps) + 1))
    return bool(ps) and _comp(gs[0], ps[0]) and _walk(gs[1:], ps[1:])


class Tree(list):
    def __init__(self, files=()):
        super().__init__(files)
        self.folders = set()
        for f in self:
            parts = f.split("/")
            for k in range(1, len(parts)):
                self.folders.add("/".join(parts[:k]))


_last = None


def _folders(files):
    global _last
    if isinstance(files, Tree):
        return files.folders
    if _last is None or _last[0] is not files:
        _last = (files, Tree(files).folders)
    return _last[1]


def match(glob, path, files=None):
    if glob.endswith("/"):
        glob = glob + "**"
    elif "*" not in glob and files and glob in _folders(files):
        glob = glob + "/**"
    return _walk(glob.split("/"), path.split("/"))


def regime_files(agents_text, files):
    mod = _spec_diff()
    spec = list(mod.spec_line(agents_text) or mod.DEFAULT)
    return [f for f in files if mod.in_spec(f, spec) or f in REGIME_EXTRA]
