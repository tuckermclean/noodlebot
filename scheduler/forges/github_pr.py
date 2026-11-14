"""Part of the GitHub backend (forges/github.py): the pull request list (the REST and `gh pr list --json` forms), view, create, edit, comment.

Not a module of its own: github.py compiles this file into its own namespace the first time a call needs one of these
operations (so a process compiles only the families it uses), and the functions named in _register at the end become
methods of its Backend. Everything github.py defines is in scope here; `gh` itself is run only by github.py's _run.
"""

# `gh pr list --json` field of each pr key it can give (`author` is not here: its is_owner needs author_association,
# which only the REST list has, and gh pr list has no authorAssociation field)
_PR_JSON = {"number": ["number"], "title": ["title"], "body": ["body"], "state": ["state"], "head": ["headRefName"],
            "head_sha": ["headRefOid"], "base": ["baseRefName"], "mergeable": ["mergeable"],
            "created_at": ["createdAt"], "merged_at": ["mergedAt"], "closed_at": ["closedAt"], "url": ["url"]}
_PR_KEYS = set(_PR_JSON) | {"author"}


def pr_list(self, state="open", limit=None, fields=None):
    if state not in ("open", "closed", "merged", "all"):
        raise forge.ForgeError("pr list: bad state %r" % (state,))
    limit = None if limit is None else int(limit)
    keys = list(fields) if fields else None
    if keys:
        _part("prlines")  # the line forms a caller's fields may name (compiled only for a caller that names fields)
    bad = [k for k in keys or () if k not in _PR_KEYS and _pr_form(state, keys) is None]
    if bad:
        raise forge.ForgeError("pr list: unknown fields %s" % bad)
    lim = [] if limit is None else ["--limit", str(limit)]
    base = ["pr", "list", "--repo", self.repo, "--state", state] + lim
    form = _pr_form(state, keys) if keys else None
    if form:
        jsonf, jq, parse_line = form
        out = self._gh(base + ["--json", jsonf, "-q", jq], None, "gh pr list --state " + state)
        lines = out.split("\n")
        if lines[-1] == "":
            lines.pop()  # the newline that ends the last line
        return [parse_line(ln) for ln in lines]
    if keys and "author" not in keys:
        # nodes.py's forms: `gh pr list --json` with fields gh knows (authorAssociation is not one of them)
        names = []
        for k in keys:
            names += [n for n in _PR_JSON[k] if n not in names]
        got = self._json(base + ["--json", ",".join(names)], "gh pr list --state " + state)
        if not isinstance(got, list):
            raise forge.ForgeError("gh pr list: the answer is not a list")
        return [self._pr_row(r, keys) for r in got]
    rows = self._pr_rest(state, limit)
    return [{k: r[k] for k in keys} for r in rows] if keys else rows


def _pr_rest(self, state, limit):
    """report.py's form: `gh api -X GET repos/R/pulls?state=S&per_page=100`, further pages with &page=P. The REST list
    knows open and closed (merged pulls included); `merged` keeps those with a merged_at."""
    api = {"open": "open", "closed": "closed", "merged": "closed", "all": "all"}[state]
    out, page = [], 1
    while page <= 50:
        got = self._api("GET", self._r("/pulls?state=%s&per_page=100%s" % (api, "&page=%d" % page if page > 1 else ""))) or []
        if not isinstance(got, list):
            raise forge.ForgeError("gh api pulls: the answer is not a list")
        out += [r for r in map(_pr, got) if state != "merged" or r["merged_at"]]
        if (limit is not None and len(out) >= limit) or len(got) < 100:
            break
        page += 1
    return out if limit is None else out[:limit]


def _json(self, args, label):
    out = self._gh(args, None, label)
    try:
        return json.loads(out)
    except ValueError:
        raise forge.ForgeError("%s: the answer is not JSON" % label)


def _pr_row(self, r, keys):
    out = {}
    for k in keys:
        if k == "state":
            out[k] = str(r.get("state") or "").lower()
        elif k in ("merged_at", "closed_at"):
            out[k] = _time(r.get(_PR_JSON[k][0]))
        elif k in ("title", "body"):
            out[k] = r.get(_PR_JSON[k][0]) or ""
        else:
            out[k] = r.get(_PR_JSON[k][0])
    return out


def pr_view(self, number):
    return _pr(self._obj("GET", self._r("/pulls/%d" % int(number))))


def pr_create(self, head, base, title, body):
    return _pr(self._obj("POST", self._r("/pulls"), {"head": head, "base": base, "title": title, "body": body}))


def pr_edit(self, number, title=None, body=None):
    return _pr(self._obj("PATCH", self._r("/pulls/%d" % int(number)), self._set(title=title, body=body)))


def pr_comment(self, number, body):
    return _comment(self._obj("POST", self._r("/issues/%d/comments" % int(number)), {"body": body}))


_register(pr_list, _pr_rest, _json, _pr_row, pr_view, pr_create, pr_edit, pr_comment)
