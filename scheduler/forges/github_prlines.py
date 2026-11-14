"""Part of the GitHub backend (forges/github.py): the `gh pr list ... -q` line forms of the loop and status.sh, and
their line parsers.

Not a module of its own: github.py compiles this file into its own namespace the first time a call needs one of these
operations (so a process compiles only the families it uses), and the functions named in _register at the end become
methods of its Backend. Everything github.py defines is in scope here; `gh` itself is run only by github.py's _run.
"""

# The loop's, status.sh's forms: (state, fields) -> (--json fields, -q expression, line parser). A line parser reads
# one line of the -q output as the shell read it (no line is unreadable: only a non-zero gh exit fails the call) and
# gives the pr keys of the form's fields plus "line", the line as gh printed it. "author_is_bot" and "merged" are fields
# of these forms only.
def _int(v):
    return int(v) if v and re.fullmatch(r"[0-9]+", v) else None


def _bool(v):
    return {"true": True, "false": False}.get(v)


def _cut(ln, n):
    """The first n fields of a line as `cut -d' ' -fK` gives them (one space separates; a missing or empty field is
    None). A line without a space is its head: `cut -d' ' -f2` passes it whole, and its number is None."""
    if " " not in ln:
        return [None, ln or None] + [None] * (n - 2)
    f = [x or None for x in ln.split(" ")[:n]]
    return f + [None] * (n - len(f))


def _merged_line(ln):
    n, head = _cut(ln, 2)
    return {"number": _int(n), "head": head, "line": ln}


def _open_line(ln):
    n, head, sha, bot, mergeable = _cut(ln, 5)
    bot = _bool(bot)
    return {"number": _int(n), "head": head, "head_sha": sha, "author_is_bot": bot,
            "author": {"login": None, "is_bot": bot is True, "is_owner": False}, "mergeable": mergeable, "line": ln}


def _closed_line(ln):
    n, head, closed_at, merged = _cut(ln, 4)
    merged = _bool(merged)
    return {"number": _int(n), "head": head, "closed_at": closed_at, "merged": merged,
            "state": {True: "merged", False: "closed"}.get(merged), "line": ln}


def _status_line(ln):
    m = re.match(r"\s*#(\S*) ?(.*)", ln, re.S)
    return {"number": _int(m[1]) if m else None, "title": m[2] if m else ln.strip(), "line": ln}


_PR_LINES = {
    ("merged", ("number", "head")): (
        "number,headRefName", '.[] | "\\(.number) \\(.headRefName)"', _merged_line),
    ("open", ("number", "head", "head_sha", "author_is_bot", "mergeable")): (
        "number,headRefName,headRefOid,author,mergeable",
        '.[] | "\\(.number) \\(.headRefName) \\(.headRefOid) \\(.author.is_bot) \\(.mergeable)"', _open_line),
    ("closed", ("number", "head", "closed_at", "merged")): (
        "number,headRefName,closedAt,mergedAt",
        '.[] | "\\(.number) \\(.headRefName) \\(.closedAt) \\(.mergedAt != null)"', _closed_line),
    # status.sh's display form: the open PRs but dependabot's, a line each ("   #N title"; the title cut at 90
    # characters by the jq expression)
    ("open", ("number", "title")): (
        "number,title,author",
        '.[] | select(.author.login | test("dependabot") | not) | "   #\\(.number) \\(.title[0:90])"', _status_line),
}


def _pr_form(state, keys):
    """The _PR_LINES form of (state, fields), the fields compared as a set."""
    for (st, fl), form in _PR_LINES.items():
        if st == state and set(fl) == set(keys):
            return form
    return None
