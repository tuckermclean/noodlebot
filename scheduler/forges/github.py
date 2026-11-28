"""The GitHub backend of scheduler/forge.py (G04): the interface's operations over the `gh` CLI (and `git` for a push).

Credentials: a GH_TOKEN the caller put in the environment is used as given; else the token script named by
$NOODLEBOT_FORGE_TOKEN_SCRIPT runs once per process and repository (`<script> <owner/name>`) and its token is kept in
memory (its failure too: later calls fail alike without rerunning it); else no token and `gh` uses its own login. The
token reaches `gh` and `git` only through the child's environment: never an argument, never output, a log, a file or
Git configuration.

The argv of each `gh` call is the form the scheduler's call sites used before the interface (see forges/README.md); a few
operations choose between forms by their arguments:
  pr list   (state, fields) matching a loop/status.sh form runs `gh pr list ... --json F -q 'jq'` and parses its lines
            (_PR_LINES); other fields without `author` run `gh pr list ... --json F` (nodes.py); no fields, or `author`,
            runs `gh api -X GET repos/R/pulls?state=S&per_page=100` (report.py; its author_association gives is_owner)
  issue comments   reads every page itself (the first without a page parameter)
  issue list       oldest_first adds `&per_page=50&sort=created&direction=asc` (one page), else `&per_page=100`

The operations are in parts, forges/github_<part>.py (_PARTS below), each compiled into this module's namespace the first
time a call needs it, so a process compiles only what it uses (no bytecode is written: every process compiles its source).
This file keeps the credentials, the web URLs, the plumbing that runs `gh` and the repository operations.
"""
import _thread
import json
import os
import re

import forge

_TOKENS = {}  # repository -> token (kept in this process's memory only)
_TOKEN_FAILED = {}  # repository -> why its token script failed (it is not run again in this process)
_TOKEN_LOCK = _thread.allocate_lock()  # the script runs at most once per repository, also under threads
TIMEOUT = 60
PATCH_TIMEOUT = 120  # the gist PATCH of a site publish (site.py's own)
CAPABILITIES = frozenset(forge.CAPABILITIES)


_URL_SAFE = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-~")  # urllib.parse's always-safe


def quote(s, safe=""):
    """urllib.parse.quote(s, safe=safe). A string of safe characters only (a label name) is the quoted form itself, as
    quote gives it, without importing urllib.parse (with its ipaddress, a large share of a report.py run's start-up)."""
    if type(s) is str and type(safe) is str and safe.isascii() and all(c in _URL_SAFE or c in safe for c in s):
        return s
    from urllib.parse import quote as q   # imported when first needed: most calls never quote a character
    return q(s, safe=safe)


def web_url(repo, kind, ref=None):
    tail = {"repo": "", "issue": "/issues/%s", "pr": "/pull/%s", "commit": "/commit/%s",
            "run": "/actions/runs/%s"}.get(kind)
    if tail is None or (kind != "repo" and ref is None):
        raise forge.ForgeError("bad url kind %r" % (kind,))
    return "https://github.com/" + repo + (tail % (ref,) if kind != "repo" else "")


def commit_link(url, sha):
    """The web link of a commit from an origin remote URL (https://github.com/o/n[.git], ssh://git@github.com/o/n,
    git@github.com:o/n), or None when the URL is no GitHub remote of exactly owner/name (version.sh's signature link)."""
    path = repo_of_remote(url)
    return web_url(path, "commit", sha) if path and sha else None


def repo_of_remote(url):
    """owner/name of a GitHub origin remote URL (the forms of commit_link), else None."""
    m = re.match(r"(?:https://github\.com/|ssh://git@github\.com/|git@github\.com:)(.*)$", url or "", re.S)
    path = m and (m[1][:-4] if m[1].endswith(".git") else m[1])
    return path if path and re.fullmatch(r"[^/]+/[^/]+", path) else None


def _token(repo):
    """(token, from the script): the caller's GH_TOKEN as given (None: leave the environment alone), else the script's.
    The script runs at most once per process and repository: its token is kept, and so is its failure (every later
    call raises the same ForgeError without running it again)."""
    if os.environ.get("GH_TOKEN"):
        return None
    script = os.environ.get("NOODLEBOT_FORGE_TOKEN_SCRIPT")
    with _TOKEN_LOCK:
        if repo in _TOKENS:
            return _TOKENS[repo]
        if repo in _TOKEN_FAILED:
            raise forge.ForgeError(_TOKEN_FAILED[repo])
        if not script:
            return None
        import subprocess   # a process that only builds URLs never loads it
        try:
            r = subprocess.run([script, repo], capture_output=True, text=True, timeout=30, stdin=subprocess.DEVNULL)
            why = None if r.returncode == 0 else "token script failed for %s (exit %d)" % (repo, r.returncode)
        except (OSError, subprocess.SubprocessError) as e:
            r, why = None, "token script failed for %s: %s" % (repo, type(e).__name__)
        tok = r.stdout.strip() if why is None else ""
        if why is None and not tok:
            why = "token script printed no token for %s" % repo
        if why is not None:
            _TOKEN_FAILED[repo] = why
            raise forge.ForgeError(why)
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


# The parts and the Backend methods each defines (a method is looked up here the first time; its part then registers it).
_PARTS = {
    "pr": ("pr_list", "pr_view", "pr_create", "pr_edit", "pr_close", "pr_comment", "_pr_rest", "_json", "_pr_row"),
    "prlines": (),
    "review": ("pr_comments", "pr_reviews", "pr_line_comments", "pr_reply", "pr_resolve_thread", "_paginate"),
    "issue": ("issue_list", "issue_view", "issue_comments", "issue_create", "issue_edit", "issue_comment", "issue_close",
              "issue_reopen", "issue_pin", "issue_unpin", "issue_events", "issue_react", "_pin", "_seen", "label_list",
              "label_ensure", "label_add", "label_remove", "_labels", "commit_checks"),
    "artifact": ("ci_artifact",),
    "misc": ("ci_runs", "ci_rerun", "ci_dispatch", "ci_logs", "site_publish", "branch_push"),
}
_PART_OF = {m: p for p, ms in _PARTS.items() for m in ms}
_LOADED = set()
_PART_LOCK = _thread.RLock()  # threads needing a part at once compile it once


def _part(part):
    """Compiles forges/github_<part>.py into this module's namespace, once per process (also under threads)."""
    with _PART_LOCK:
        if part in _LOADED:
            return
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "github_%s.py" % part)
        try:
            with open(path, encoding="utf-8") as f:
                code = compile(f.read(), path, "exec")
        except OSError as e:  # a failed call, as any other
            raise forge.ForgeError("the GitHub backend's part %s cannot be read: %s" % (part, e.strerror))
        exec(code, globals())
        _LOADED.add(part)


def _register(*fns):
    """A part's methods become the Backend's."""
    for fn in fns:
        setattr(Backend, fn.__name__, fn)


class Backend:
    name = "github"
    capabilities = CAPABILITIES

    def __init__(self, path):
        self.path = path  # owner/name
        self.repo = path

    def __getattr__(self, attr):  # an operation not yet compiled: its part is, and registers it on the class
        part = _PART_OF.get(attr)
        if part is None:
            raise AttributeError(attr)
        _part(part)
        return object.__getattribute__(self, attr)

    # --- plumbing ---
    def _env(self):
        """(the child's environment, whichever token the child gets, for scrubbing its error text). Without a token of
        the script's the environment is None: the child inherits this process's own (no copy per call)."""
        tok = _token(self.repo)
        if not tok:
            return None, os.environ.get("GH_TOKEN")
        env = dict(os.environ)
        env["GH_TOKEN"] = tok
        return env, tok

    def _scrub(self, text, tok):
        text = " ".join((text or "").split())
        return text.replace(tok, "***") if tok else text

    def _run(self, cmd, label, stdin=None, timeout=TIMEOUT):
        """(stdout) of a child with the token in its environment; a failure is a ForgeError naming `label`."""
        import subprocess   # loaded with the first call (a URL needs none)
        env, tok = self._env()
        try:
            r = subprocess.run(cmd, input=stdin.encode() if stdin is not None else None,
                               stdin=None if stdin is not None else subprocess.DEVNULL,
                               capture_output=True, timeout=timeout, env=env)
            # bytes decoded as UTF-8, no newline translation: a log is returned as served
            r.stdout = r.stdout.decode("utf-8", errors="replace")
            r.stderr = r.stderr.decode("utf-8", errors="replace")
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

    @staticmethod
    def _set(**kw):
        return {k: v for k, v in kw.items() if v is not None}

    def _graphql(self, query, node_id):
        self._api("POST", "graphql", {"query": query, "variables": {"id": node_id}})

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

    def repo_permissions(self):
        got = self._obj("GET", self._r())
        perm = got.get("permissions")
        if not isinstance(perm, dict):
            raise forge.ForgeError("gh api %s: no permissions in the answer" % self._r())
        return {"read": bool(perm.get("pull")), "write": bool(perm.get("push")), "admin": bool(perm.get("admin"))}

    def repo_identities(self):
        return {"owner": self.repo.split("/")[0], "bot": None}
