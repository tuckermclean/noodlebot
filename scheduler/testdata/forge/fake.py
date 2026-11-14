"""The fake forge: a backend of scheduler/forge.py that keeps everything as files (G04, change 7). Frozen after the RED
commit of G04's slice 1: the conformance suite and the loop's end-to-end case drive it.

The loader instantiates `Backend(path)`; `path` is the state folder, whose layout is documented in world.py (next to
this file): forge.json, prs.json, issues.json, comments.json, ... and the `fail` switch. Every call reads the folder
afresh and writes its changes back, so a test may edit the files between calls (merge a PR: state "merged", merged_at,
closed_at). `repo clone-url` is `<path>/repo.git`, a bare repository the test creates; `branch push` pushes to it.

Methods are named <family>_<op> (`-` -> `_`) and take the keyword arguments of the interface; results are the normalised
shapes of the interface (a "url" is added to PRs, issues, comments, reviews and line comments). Failures raise
forge.ForgeError. The backend does not raise CapabilityOff: the core refuses an operation whose capability is off
(visibility: repo visibility; pin: issue pin, issue unpin; resolve_threads: pr resolve-thread; site: site publish);
should one reach this backend anyway, it raises a plain ForgeError, so nothing is silently done.
URLs are fake://<owner>/<name>[/issues/N | /pull/N | /commit/SHA].
"""
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import forge  # the core module: ForgeError (the loader has imported it already)
import world as _world


class Backend:
    name = "fake"

    def __init__(self, path):
        self.path = path
        self.capabilities = frozenset(_world.World(path).capabilities())

    # --- plumbing ---
    def _w(self, need=None):
        w = _world.World(self.path)
        if w.failing():
            raise forge.ForgeError("fake forge: the call failed (the fail switch is on)")
        if need and need not in w.capabilities():
            raise forge.ForgeError("fake forge: capability %s is off but the operation was called" % need)
        return w

    def _do(self, fn, *a, **k):
        try:
            return fn(*a, **k)
        except _world.WorldError as e:
            raise forge.ForgeError("fake forge: %s" % e)

    def _url(self, w, kind, ref=None):
        base = "fake://%s/%s" % (w.forge["owner"], w.forge["name"])
        return base + {"repo": "", "issue": "/issues/%s", "pr": "/pull/%s", "commit": "/commit/%s"}[kind] % ((ref,) if kind != "repo" else ())

    def _with_url(self, w, obj, kind, ref=None):
        out = dict(obj)
        out["url"] = self._url(w, kind, ref if ref is not None else obj.get("number"))
        return out

    def _pr(self, w, p):
        return self._with_url(w, p, "pr")

    def _issue(self, w, i):
        return self._with_url(w, i, "issue")

    def _comments(self, w, lst, number, kind):
        return [dict(c, url=self._url(w, kind, number) + "#c%d" % c["id"]) for c in lst]

    def _lc(self, w, lst, number):
        out = []
        for c in lst:
            d = {k: v for k, v in c.items() if k != "outdated"}
            d["url"] = self._url(w, "pr", number) + "#r%d" % c["id"]
            out.append(d)
        return out

    # --- repo ---
    def repo_visibility(self):
        w = self._w("visibility")
        return "private" if w.forge.get("private") else "public"

    def repo_default_branch(self):
        return self._w().forge["default_branch"]

    def repo_clone_url(self):
        self._w()
        return os.path.join(self.path, "repo.git")

    def repo_url(self, kind="repo", ref=None):
        w = _world.World(self.path)
        if kind not in ("repo", "issue", "pr", "commit"):
            raise forge.ForgeError("fake forge: bad url kind %r" % (kind,))
        return self._url(w, kind, ref)

    def repo_identities(self):
        w = self._w()
        return {"owner": w.forge["owner"], "bot": w.forge.get("bot")}

    # --- pull requests ---
    def pr_list(self, state="open", limit=None, fields=None):
        w = self._w()
        return [self._pr(w, p) for p in self._do(w.pr_list, state, limit)]

    def pr_view(self, number):
        w = self._w()
        return self._pr(w, self._do(w.find_pr, number))

    def pr_create(self, head, base, title, body):
        w = self._w()
        return self._pr(w, self._do(w.pr_create, head, base, title, body))

    def pr_edit(self, number, title=None, body=None):
        w = self._w()
        return self._pr(w, self._do(w.pr_edit, number, title, body))

    def pr_comment(self, number, body):
        w = self._w()
        self._do(w.find_pr, number)
        c = self._do(w.comment_add, number, body)
        return self._comments(w, [c], number, "pr")[0]

    def pr_comments(self, number):
        w = self._w()
        self._do(w.find_pr, number)
        return self._comments(w, w.comments_of(number), number, "pr")

    def pr_reviews(self, number):
        w = self._w()
        self._do(w.find_pr, number)
        return self._comments(w, w.reviews.get(str(int(number)), []), number, "pr")

    def pr_line_comments(self, number):
        w = self._w()
        self._do(w.find_pr, number)
        return self._lc(w, w.line_comments.get(str(int(number)), []), number)

    def pr_reply(self, number, to, body):
        w = self._w()
        self._do(w.find_pr, number)
        return self._lc(w, [self._do(w.reply, number, to, body)], number)[0]

    def pr_resolve_thread(self, thread):
        w = self._w("resolve_threads")
        self._do(w.resolve_thread, thread)
        return {}

    # --- issues ---
    def issue_list(self, label, state="open", oldest_first=False):
        w = self._w()
        return [self._issue(w, i) for i in self._do(w.issue_list, label, state, oldest_first)]

    def issue_view(self, number):
        w = self._w()
        return self._issue(w, self._do(w.find_issue, number))

    def issue_comments(self, number, since=None):
        w = self._w()
        self._do(w.find_issue, number)
        return self._comments(w, w.comments_of(number, since), number, "issue")

    def issue_create(self, title, body, labels=None):
        w = self._w()
        return self._issue(w, self._do(w.issue_create, title, body, labels))

    def issue_edit(self, number, title=None, body=None):
        w = self._w()
        return self._issue(w, self._do(w.issue_edit, number, title, body))

    def issue_comment(self, number, body):
        w = self._w()
        self._do(w.find_issue, number)
        return self._comments(w, [self._do(w.comment_add, number, body)], number, "issue")[0]

    def issue_close(self, number):
        w = self._w()
        return self._issue(w, self._do(w.issue_edit, number, None, None, "closed"))

    def issue_reopen(self, number):
        w = self._w()
        return self._issue(w, self._do(w.issue_edit, number, None, None, "open"))

    def issue_pin(self, number):
        w = self._w("pin")
        self._do(w.pin, number, True)
        return {}

    def issue_unpin(self, number):
        w = self._w("pin")
        self._do(w.pin, number, False)
        return {}

    def issue_events(self, number):
        w = self._w()
        self._do(w.find_issue, number)
        return list(w.events.get(str(int(number)), []))

    def issue_react(self, comment, reaction="+1"):
        w = self._w()
        self._do(w.react, comment, reaction)
        return {}

    # --- labels ---
    def label_list(self):
        return list(self._w().labels)

    def label_ensure(self, name, color, description):
        w = self._w()
        return {"name": name, "created": w.label_ensure(name, color, description)}

    def label_add(self, number, name):
        w = self._w()
        self._do(w.label_add, number, name)
        return {}

    def label_remove(self, number, name):
        w = self._w()
        self._do(w.label_remove, number, name)
        return {}

    # --- checks, CI, site, push ---
    def commit_checks(self, sha):
        return list(self._w().checks.get(sha, []))

    def ci_runs(self, workflow, sha, branch=None, event=None):
        w = self._w()
        return [{k: r[k] for k in ("id", "status", "conclusion", "head_sha", "created_at")}
                for r in w.ci(workflow, sha, branch, event)]

    def site_publish(self, target, input):
        w = self._w("site")
        with open(input) as f:
            body = json.load(f)
        self._do(w.site_publish, target, body["files"])
        return {}

    def branch_push(self, path, branch):
        self._w()
        r = subprocess.run(["git", "-C", path, "push", "--quiet", os.path.join(self.path, "repo.git"), branch],
                           capture_output=True, text=True)
        if r.returncode:
            raise forge.ForgeError("fake forge: push failed: %s" % r.stderr.strip()[:300])
        return {}
