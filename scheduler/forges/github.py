"""The GitHub backend of scheduler/forge.py (G04): the interface's operations over the `gh` CLI (and `git` for a push).

Credentials: a GH_TOKEN the caller put in the environment is used as given; else the token script named by
$NOODLEBOT_FORGE_TOKEN_SCRIPT runs once per process and repository (`<script> <owner/name>`) and its token is kept in
memory; else no token and `gh` uses its own login. The token reaches `gh` and `git` only through the child's environment:
never an argument, never output, a log, a file or Git configuration.

The argv of each `gh` call is the form the scheduler's call sites used before the interface (see forges/README.md); a few
operations choose between forms by their arguments:
  pr list   (state, fields) matching a loop/status.sh form runs `gh pr list ... --json F -q 'jq'` and parses its lines
            (_PR_LINES); other fields without `author` run `gh pr list ... --json F` (nodes.py); no fields, or `author`,
            runs `gh api -X GET repos/R/pulls?state=S&per_page=100` (report.py; its author_association gives is_owner)
  issue comments   reads every page itself (the first without a page parameter)
  issue list       oldest_first adds `&per_page=50&sort=created&direction=asc` (one page), else `&per_page=100`
"""
import json
import os
import re
import subprocess
import sys
import threading
from urllib.parse import quote

import forge

_TOKENS = {}  # repository -> token (kept in this process's memory only)
_TOKEN_LOCK = threading.Lock()  # the script runs at most once per repository, also under threads
TIMEOUT = 60
PATCH_TIMEOUT = 120  # the gist PATCH of a site publish (site.py's own)
CAPABILITIES = frozenset(forge.CAPABILITIES)


def web_url(repo, kind, ref=None):
    tail = {"repo": "", "issue": "/issues/%s", "pr": "/pull/%s", "commit": "/commit/%s"}.get(kind)
    if tail is None or (kind != "repo" and ref is None):
        raise forge.ForgeError("bad url kind %r" % (kind,))
    return "https://github.com/" + repo + (tail % (ref,) if kind != "repo" else "")


def _token(repo):
    """(token, from the script): the caller's GH_TOKEN as given (None: leave the environment alone), else the script's."""
    if os.environ.get("GH_TOKEN"):
        return None
    script = os.environ.get("NOODLEBOT_FORGE_TOKEN_SCRIPT")
    with _TOKEN_LOCK:
        if repo in _TOKENS:
            return _TOKENS[repo]
        if not script:
            return None
        try:
            r = subprocess.run([script, repo], capture_output=True, text=True, timeout=30, stdin=subprocess.DEVNULL)
        except (OSError, subprocess.SubprocessError) as e:
            raise forge.ForgeError("token script failed for %s: %s" % (repo, type(e).__name__))
        if r.returncode != 0:
            raise forge.ForgeError("token script failed for %s (exit %d)" % (repo, r.returncode))
        tok = r.stdout.strip()
        if not tok:
            raise forge.ForgeError("token script printed no token for %s" % repo)
        _TOKENS[repo] = tok
        return tok


def _user(u, assoc=None):
    u = u or {}
    return {"login": u.get("login"), "is_bot": u.get("type") == "Bot" or u.get("is_bot") is True,
            "is_owner": assoc == "OWNER"}


def _time(v):
    return None if not v or str(v).startswith("0001-01-01") else v


def _pr(o):
    merged = bool(o.get("merged") or o.get("merged_at"))
    return {"number": o["number"], "title": o.get("title") or "", "body": o.get("body") or "",
            "state": "merged" if merged else o.get("state") or "", "head": (o.get("head") or {}).get("ref"),
            "head_sha": (o.get("head") or {}).get("sha"), "base": (o.get("base") or {}).get("ref"), "author": _user(o.get("user"), o.get("author_association")),
            "mergeable": {True: "MERGEABLE", False: "CONFLICTING"}.get(o.get("mergeable"), "UNKNOWN"),
            "created_at": o.get("created_at"), "merged_at": o.get("merged_at"), "closed_at": o.get("closed_at"),
            "url": o.get("html_url") or ""}


def _issue(o):
    return {"number": o["number"], "title": o.get("title") or "", "body": o.get("body") or "",
            "state": o.get("state") or "",
            "labels": [(l.get("name") if isinstance(l, dict) else l) for l in o.get("labels") or []],
            "is_pr": "pull_request" in o, "author": _user(o.get("user"), o.get("author_association")),
            "created_at": o.get("created_at"), "url": o.get("html_url") or ""}


def _comment(o):
    return {"id": o["id"], "body": o.get("body") or "", "author": _user(o.get("user"), o.get("author_association")),
            "created_at": o.get("created_at"), "url": o.get("html_url") or ""}


def _review(o):
    return {"id": o["id"], "state": o.get("state"), "body": o.get("body") or "",
            "author": _user(o.get("user"), o.get("author_association")), "submitted_at": o.get("submitted_at"),
            "url": o.get("html_url") or ""}


def _line_comment(o):
    line = o.get("line") if o.get("line") is not None else o.get("original_line")
    return {"id": o["id"], "body": o.get("body") or "", "author": _user(o.get("user"), o.get("author_association")),
            "path": o.get("path"), "line": line, "in_reply_to": o.get("in_reply_to_id"),
            "created_at": o.get("created_at"), "url": o.get("html_url") or ""}


# `gh pr list --json` field of each pr key it can give (`author` is not here: its is_owner needs author_association,
# which only the REST list has, and gh pr list has no authorAssociation field)
_PR_JSON = {"number": ["number"], "title": ["title"], "body": ["body"], "state": ["state"], "head": ["headRefName"],
            "head_sha": ["headRefOid"], "base": ["baseRefName"], "mergeable": ["mergeable"],
            "created_at": ["createdAt"], "merged_at": ["mergedAt"], "closed_at": ["closedAt"], "url": ["url"]}
_PR_KEYS = set(_PR_JSON) | {"author"}
# The loop's, status.sh's forms: (state, fields) -> (--json fields, -q expression, line pattern, converters). The
# conversions give the pr keys of the fields; "author_is_bot" and "merged" are fields of these forms only.
_PR_LINES = {
    ("merged", ("number", "head")): (
        "number,headRefName", '.[] | "\\(.number) \\(.headRefName)"', re.compile(r"(\d+) (\S+)$"),
        lambda m: {"number": int(m[1]), "head": m[2]}),
    ("open", ("number", "head", "head_sha", "author_is_bot", "mergeable")): (
        "number,headRefName,headRefOid,author,mergeable",
        '.[] | "\\(.number) \\(.headRefName) \\(.headRefOid) \\(.author.is_bot) \\(.mergeable)"',
        re.compile(r"(\d+) (\S+) (\S+) (true|false) (\S+)$"),
        lambda m: {"number": int(m[1]), "head": m[2], "head_sha": m[3], "author_is_bot": m[4] == "true",
                   "author": {"login": None, "is_bot": m[4] == "true", "is_owner": False}, "mergeable": m[5]}),
    ("closed", ("number", "head", "closed_at", "merged")): (
        "number,headRefName,closedAt,mergedAt",
        '.[] | "\\(.number) \\(.headRefName) \\(.closedAt) \\(.mergedAt != null)"',
        re.compile(r"(\d+) (\S+) (\S+) (true|false)$"),
        lambda m: {"number": int(m[1]), "head": m[2], "closed_at": m[3], "merged": m[4] == "true",
                   "state": "merged" if m[4] == "true" else "closed"}),
    # status.sh: the open PRs but dependabot's, a line each ("   #N title"; the title cut at 90 characters)
    ("open", ("number", "title")): (
        "number,title,author",
        '.[] | select(.author.login | test("dependabot") | not) | "   #\\(.number) \\(.title[0:90])"',
        re.compile(r"\s*#(\d+) (.*)$"), lambda m: {"number": int(m[1]), "title": m[2]}),
}


def _pr_form(state, keys):
    """The _PR_LINES form of (state, fields), the fields compared as a set."""
    for (st, fl), form in _PR_LINES.items():
        if st == state and set(fl) == set(keys):
            return form
    return None


class Backend:
    name = "github"
    capabilities = CAPABILITIES

    def __init__(self, path):
        self.path = path  # owner/name
        self.repo = path

    # --- plumbing ---
    def _env(self):
        env = dict(os.environ)
        tok = _token(self.repo)
        if tok:
            env["GH_TOKEN"] = tok
        return env, env.get("GH_TOKEN")  # whichever token the child gets, for scrubbing its error text

    def _scrub(self, text, tok):
        text = " ".join((text or "").split())
        return text.replace(tok, "***") if tok else text

    def _run(self, cmd, label, stdin=None, timeout=TIMEOUT):
        """(stdout) of a child with the token in its environment; a failure is a ForgeError naming `label`."""
        env, tok = self._env()
        try:
            r = subprocess.run(cmd, input=stdin, stdin=None if stdin is not None else subprocess.DEVNULL,
                               capture_output=True, text=True, errors="replace", timeout=timeout, env=env)
        except (OSError, subprocess.SubprocessError) as e:
            raise forge.ForgeError("%s failed: %s" % (label, type(e).__name__))
        if r.returncode != 0:
            full = self._scrub(r.stderr or r.stdout, tok)
            m = re.findall(r"\bHTTP (\d{3})\b", full)
            e = forge.ForgeError("%s failed (exit %d): %s" % (label, r.returncode, full[:300]), int(m[-1]) if m else None)
            e.text = full
            e.stdout = self._scrub(r.stdout, tok)
            e.raw_stdout = r.stdout
            raise e
        return r.stdout

    def _gh(self, args, body=None, label=None, timeout=TIMEOUT):
        label = label or "gh " + " ".join(a for a in args if not a.startswith("--") or a == "--paginate")[:80]
        return self._run(["gh"] + args, label, json.dumps(body) if body is not None else None, timeout)

    def _api(self, method, path, body=None, extra=()):
        args = ["api", "-X", method, path] + list(extra) + (["--input", "-"] if body is not None else [])
        out = self._gh(args, body, "gh api %s %s" % (method, path.split("?")[0]))
        try:
            return json.loads(out) if out.strip() else None
        except ValueError:
            raise forge.ForgeError("gh api %s %s: the answer is not JSON" % (method, path.split("?")[0]))

    def _obj(self, method, path, body=None):
        """_api for an operation whose answer is one object: an empty answer is a failed call."""
        got = self._api(method, path, body)
        if not isinstance(got, dict):
            raise forge.ForgeError("gh api %s %s: no object in the answer" % (method, path.split("?")[0]))
        return got

    def _paginate(self, path):
        out = self._gh(["api", "--paginate", path], None, "gh api --paginate " + path)
        dec, i, items = json.JSONDecoder(), 0, []
        try:
            while True:
                while i < len(out) and out[i].isspace():
                    i += 1
                if i >= len(out):
                    return items
                val, i = dec.raw_decode(out, i)
                items.extend(val if isinstance(val, list) else [val])
        except ValueError:
            raise forge.ForgeError("gh api --paginate %s: the answer is not JSON" % path)

    def _r(self, tail=""):
        return "repos/%s%s" % (self.repo, tail)

    # --- repo ---
    def repo_visibility(self):
        out = self._gh(["api", self._r(), "--jq", ".private"], None, "gh api repos --jq .private").strip()
        if out not in ("true", "false"):
            raise forge.ForgeError("gh api %s: no visibility in the answer" % self._r())
        return "private" if out == "true" else "public"

    def repo_default_branch(self):
        out = self._gh(["api", self._r(), "--jq", ".default_branch"], None, "gh api repos --jq .default_branch").strip()
        if not out:
            raise forge.ForgeError("gh api %s: no default branch in the answer" % self._r())
        return out

    def repo_clone_url(self):
        return web_url(self.repo, "repo")

    def repo_url(self, kind="repo", ref=None):
        return web_url(self.repo, kind, ref)

    def repo_identities(self):
        return {"owner": self.repo.split("/")[0], "bot": None}

    # --- pull requests ---
    def pr_list(self, state="open", limit=None, fields=None):
        if state not in ("open", "closed", "merged", "all"):
            raise forge.ForgeError("pr list: bad state %r" % (state,))
        limit = None if limit is None else int(limit)
        keys = list(fields) if fields else None
        bad = [k for k in keys or () if k not in _PR_KEYS and _pr_form(state, keys) is None]
        if bad:
            raise forge.ForgeError("pr list: unknown fields %s" % bad)
        lim = [] if limit is None else ["--limit", str(limit)]
        base = ["pr", "list", "--repo", self.repo, "--state", state] + lim
        form = _pr_form(state, keys) if keys else None
        if form:
            jsonf, jq, pat, conv = form
            out = self._gh(base + ["--json", jsonf, "-q", jq], None, "gh pr list --state " + state)
            rows = []
            for ln in out.splitlines():
                m = pat.match(ln)
                if not m:
                    raise forge.ForgeError("gh pr list --state %s: an unreadable line" % state)
                rows.append(conv(m))
            return rows
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

    @staticmethod
    def _set(**kw):
        return {k: v for k, v in kw.items() if v is not None}

    def pr_comment(self, number, body):
        return _comment(self._obj("POST", self._r("/issues/%d/comments" % int(number)), {"body": body}))

    def pr_comments(self, number):
        return [_comment(o) for o in self._paginate(self._r("/issues/%d/comments" % int(number)))]

    def pr_reviews(self, number):
        return [_review(o) for o in self._paginate(self._r("/pulls/%d/reviews" % int(number)))]

    def pr_line_comments(self, number):
        return [_line_comment(o) for o in self._paginate(self._r("/pulls/%d/comments" % int(number)))]

    def pr_reply(self, number, to, body):
        return _line_comment(self._obj("POST", self._r("/pulls/%d/comments/%d/replies" % (int(number), int(to))),
                                       {"body": body}))

    def pr_resolve_thread(self, thread):
        self._graphql("mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{id}}}", thread)
        return {}

    def _graphql(self, query, node_id):
        self._api("POST", "graphql", {"query": query, "variables": {"id": node_id}})

    # --- issues ---
    def issue_list(self, label, state="open", oldest_first=False):
        if state not in ("open", "closed", "all"):
            raise forge.ForgeError("issue list: bad state %r" % (state,))
        head = "issues?labels=%s&state=%s" % (quote(label, safe="-_.,"), state)
        if oldest_first:
            got = self._api("GET", self._r("/" + head + "&per_page=50&sort=created&direction=asc")) or []
            return [_issue(o) for o in got]
        out, page = [], 1
        while page <= 50:
            got = self._api("GET", self._r("/%s&per_page=100%s" % (head, "&page=%d" % page if page > 1 else ""))) or []
            out += got
            if len(got) < 100:
                break
            page += 1
        return [_issue(o) for o in out]

    def issue_view(self, number):
        return _issue(self._obj("GET", self._r("/issues/%d" % int(number))))

    def issue_comments(self, number, since=None):
        tail = "&since=" + since if since else ""
        base = "/issues/%d/comments?per_page=100" % int(number)
        out, p = [], 1
        while p <= 50:
            got = self._api("GET", self._r("%s%s%s" % (base, "&page=%d" % p if p > 1 else "", tail))) or []
            out += got
            if len(got) < 100:
                break
            p += 1
        return [_comment(o) for o in out]

    def issue_create(self, title, body, labels=None):
        return _issue(self._obj("POST", self._r("/issues"), self._set(title=title, body=body, labels=labels)))

    def issue_edit(self, number, title=None, body=None):
        return _issue(self._obj("PATCH", self._r("/issues/%d" % int(number)), self._set(title=title, body=body)))

    def issue_comment(self, number, body):
        return _comment(self._obj("POST", self._r("/issues/%d/comments" % int(number)), {"body": body}))

    def issue_close(self, number):
        return _issue(self._obj("PATCH", self._r("/issues/%d" % int(number)),
                                {"state": "closed", "state_reason": "completed"}))

    def issue_reopen(self, number):
        return _issue(self._obj("PATCH", self._r("/issues/%d" % int(number)), {"state": "open"}))

    def _pin(self, number, op):
        node = (self._api("GET", self._r("/issues/%d" % int(number))) or {}).get("node_id")
        if not node:
            raise forge.ForgeError("issue %s: no node id in the answer" % number)
        self._graphql("mutation($id:ID!){%sIssue(input:{issueId:$id}){issue{number}}}" % op, node)
        return {}

    def issue_pin(self, number):
        return self._pin(number, "pin")

    def issue_unpin(self, number):
        return self._pin(number, "unpin")

    def issue_events(self, number):
        got = self._api("GET", self._r("/issues/%d/events?per_page=100" % int(number))) or []
        return [{"event": o.get("event"), "label": (o.get("label") or {}).get("name"),
                 "actor": (o.get("actor") or {}).get("login"), "created_at": o.get("created_at")} for o in got]

    def issue_react(self, comment, reaction="+1"):
        self._api("POST", self._r("/issues/comments/%d/reactions" % int(comment)), {"content": reaction})
        return {}

    # --- labels ---
    def _labels(self):
        out, page = [], 1
        while page <= 50:
            got = self._api("GET", self._r("/labels?per_page=100&page=%d" % page)) or []
            out += got
            if len(got) < 100:
                break
            page += 1
        return out

    def label_list(self):
        return [{"name": o.get("name"), "color": o.get("color"), "description": o.get("description") or ""}
                for o in self._labels()]

    def label_ensure(self, name, color, description):
        try:
            self._api("POST", self._r("/labels"), {"name": name, "color": color, "description": description})
        except forge.ForgeError as e:
            if e.status == 422 and self._already_exists(e):
                return {"name": name, "created": False}
            raise
        return {"name": name, "created": True}

    @staticmethod
    def _already_exists(e):
        """A 422 whose answer says the label exists: code already_exists in the JSON on stdout, or in the error text."""
        try:
            errs = json.loads(getattr(e, "raw_stdout", "") or "").get("errors") or []
        except (ValueError, AttributeError):
            errs = []
        return any(isinstance(x, dict) and x.get("code") == "already_exists" for x in errs) or "already_exists" in getattr(e, "text", "")

    def label_add(self, number, name):
        self._api("POST", self._r("/issues/%d/labels" % int(number)), {"labels": [name]})
        return {}

    def label_remove(self, number, name):
        self._api("DELETE", self._r("/issues/%d/labels/%s" % (int(number), quote(name, safe="-_."))))
        return {}

    # --- checks, CI, site, push ---
    def commit_checks(self, sha):
        got = self._api("GET", self._r("/commits/%s/check-runs?per_page=100" % sha)) or {}
        return [{"name": o.get("name"), "status": o.get("status"), "conclusion": o.get("conclusion")}
                for o in got.get("check_runs") or []]

    def ci_runs(self, workflow, sha, branch=None, event=None):
        extra = ["-f", "head_sha=" + sha]
        if event:
            extra += ["-f", "event=" + event]
        if branch:
            extra += ["-f", "branch=" + branch]
        got = self._api("GET", self._r("/actions/workflows/%s/runs" % workflow), None, extra) or {}
        return [{"id": o["id"], "status": o.get("status"), "conclusion": o.get("conclusion"),
                 "head_sha": o.get("head_sha"), "created_at": o.get("created_at")}
                for o in got.get("workflow_runs") or [] if isinstance(o, dict)]

    def site_publish(self, target, input):
        self._gh(["api", "-X", "PATCH", "gists/" + target, "--input", input], None, "gh api -X PATCH gists",
                 PATCH_TIMEOUT)
        return {}

    def branch_push(self, path, branch):
        helper = '!f() { echo username=x-access-token; echo "password=$NOODLEBOT_PUSH_TOKEN"; }; f'
        cmd = ["git", "-C", path]
        env, tok = self._env()
        env.pop("GH_TOKEN", None)  # git gets the token only as the variable its credential helper reads
        if tok:
            env["NOODLEBOT_PUSH_TOKEN"] = tok
            cmd += ["-c", "credential.helper=", "-c", "credential.helper=" + helper]
        env.setdefault("GIT_TERMINAL_PROMPT", "0")
        cmd += ["push", self.repo_clone_url(), branch]
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, errors="replace", timeout=300, env=env,
                               stdin=subprocess.DEVNULL)
        except (OSError, subprocess.SubprocessError) as e:
            raise forge.ForgeError("git push of %s failed: %s" % (branch, type(e).__name__))
        if r.returncode != 0:
            raise forge.ForgeError("git push of %s failed (exit %d): %s" % (
                branch, r.returncode, self._scrub(r.stderr, tok)[:300]))
        return {}
