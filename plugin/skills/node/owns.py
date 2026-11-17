"""The one glob matcher for ownership, and the regime's own files (A02; A03, A04 and A05 import it).

  import owns
  owns.match(glob, path, files=None) -> bool
      A root-relative path against one glob. `*` matches within one path component, `**` as a whole
      component matches zero or more components, a trailing `/` means the folder and everything under it,
      and a glob with no wildcard that names a folder among `files` (some tracked path starts with
      glob + "/") means the same; otherwise a wildcard-free glob is a literal path.
  owns.regime_files(agents_text, files) -> list
      The paths in `files` that are the regime's own and no node owns: the spec files as
      check-spec-diff.py reads them (the **Spec files:** line of AGENTS.md's "Building a node" section,
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


def match(glob, path, files=None):
    if glob.endswith("/"):
        glob = glob + "**"
    elif "*" not in glob and files and any(f.startswith(glob + "/") for f in files):
        glob = glob + "/**"
    return _walk(glob.split("/"), path.split("/"))


def regime_files(agents_text, files):
    mod = _spec_diff()
    globs = list(mod.spec_line(agents_text) or mod.DEFAULT) + REGIME_EXTRA
    return [f for f in files if any(match(g, f, files) for g in globs)]
