#!/usr/bin/env python3
"""Judge a branch's diff against the repository's spec files.

Usage: python3 -I check-spec-diff.py [--repo <dir>] [--allow <path>]... <from> <to>

Judges `git diff --name-only --no-renames <from>...<to>` (a rename shows both names; a squash
commit checks as `<sha>^ <sha>`). The spec files are the backticked paths on the `**Spec files:**`
line of the "Building a node" section of AGENTS.md as it is at <from>, so a branch cannot widen its
own list; a path ending in `/` is a folder. The line must be one physical line. With no such line they are SPEC.md, docs/graph.yaml and
nodes/. `--allow <path>` adds a path for one run.

Output, line by line: `spec files: <list>`; then `from: AGENTS.md at <from>` when the line was found, or
`from: default (no **Spec files:** line in AGENTS.md at <from>)` when not (either may end `, plus
--allow`); then one `NOT SPEC <path>` per changed path outside the list.
Exit 0: none outside; 1: one or more; 2: git failed or any other error (nothing on stdout, the error
on stderr). Paths that are not UTF-8 are kept byte for byte (surrogateescape).
"""
import os
import re
import subprocess
import sys

DEFAULT = ["SPEC.md", "docs/graph.yaml", "nodes/"]


class GitFailure(Exception):
    pass


def dec(b):
    return b.decode("utf-8", errors="surrogateescape")


def git(repo, *args, check=True):
    p = subprocess.run(["git", "-C", repo, *args], capture_output=True)
    if check and p.returncode != 0:
        raise GitFailure("git %s: %s" % (" ".join(args), dec(p.stderr).strip()))
    return p


def spec_line(text):
    """The paths on the **Spec files:** line of the Building a node section, or None."""
    on = False
    for line in text.splitlines():
        if line.startswith("## "):
            if on:
                break
            on = line[3:].strip().lower().startswith("building a node")
            continue
        if on and "**Spec files:**" in line:
            return re.findall(r"`([^`]+)`", line)
    return None


def usage():
    sys.stderr.write(__doc__)
    return 2


def main(argv):
    repo, allow, pos = ".", [], []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--repo", "--allow"):
            if i + 1 >= len(argv):
                return usage()
            if a == "--repo":
                repo = argv[i + 1]
            else:
                allow.append(argv[i + 1])
            i += 2
        else:
            pos.append(a)
            i += 1
    if len(pos) != 2:
        return usage()
    frm, to = pos
    try:
        for ref in (frm, to):
            git(repo, "rev-parse", "--verify", "--quiet", ref + "^{commit}")
        diff = git(repo, "diff", "--name-only", "--no-renames", "-z", frm + "..." + to).stdout
        diff = dec(diff)
        show = git(repo, "show", frm + ":AGENTS.md", check=False)
    except (GitFailure, OSError) as e:
        sys.stderr.write("check-spec-diff: %s\n" % e)
        return 2
    paths = spec_line(dec(show.stdout)) if show.returncode == 0 else None
    if paths:
        source = "AGENTS.md at " + frm
        spec = paths
    else:
        source = "default (no **Spec files:** line in AGENTS.md at %s)" % frm
        spec = list(DEFAULT)
    spec = spec + allow
    if allow:
        source += ", plus --allow"

    def inside(p):
        return any(p == s or (s.endswith("/") and p.startswith(s)) for s in spec)

    outside = []
    for p in diff.split("\0"):
        if p and not inside(p) and p not in outside:
            outside.append(p)
    out = ["spec files: " + " ".join(spec), "from: " + source]
    out += ["NOT SPEC " + p for p in outside]
    sys.stdout.buffer.write(os.fsencode("\n".join(out) + "\n"))
    sys.stdout.buffer.flush()
    return 1 if outside else 0


if __name__ == "__main__":
    try:
        rc = main(sys.argv[1:])
    except Exception as e:  # never 1: the loop reads 1 as "out of scope"
        sys.stderr.write("check-spec-diff: %s: %s\n" % (type(e).__name__, e))
        rc = 2
    sys.exit(rc)
