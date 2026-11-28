"""The state folder of the fake forge, and the rules that change it (no import of `forge`: the gh emulator uses it too).

A state folder holds JSON files; `fixture/` is a complete one, the conformance suite copies it per case. Tests (and the
loop's end-to-end case) may edit these files directly between calls, for example to merge a PR (set its "state" to
"merged", "merged_at" and "closed_at"), add a comment, or touch `fail`. Every call reads the files afresh.

  forge.json         {"owner", "name", "private", "default_branch", "bot"?, "capabilities"?}. "capabilities" is a list of
                     "visibility", "pin", "resolve_threads", "site"; absent = all four. "bot" is the bot's login (None
                     when absent).
  fail               (a file; its existence is the switch) every call of the backend fails.
  prs.json           [pr] in the normalised shape without "url": number, title, body, state ("open"|"closed"|"merged"),
                     head, head_sha, base, author, mergeable, created_at, merged_at, closed_at.
  issues.json        [issue] without "url": number, title, body, state, labels [name], is_pr, author, created_at.
                     Issue and PR numbers share one sequence (a new number is the highest of both + 1).
  comments.json      {"<number>": [comment]}: the issue comments of an issue or PR; comment = id, body, author, created_at.
  reviews.json       {"<pr number>": [review]}: id, state, body, author, submitted_at.
  line_comments.json {"<pr number>": [line comment]}: id, body, author, path, line, in_reply_to, created_at, and
                     "outdated" (true: GitHub gives no `line` for it, only `original_line`; `line` here is that one).
  threads.json       {"<pr number>": [{"id": str, "resolved": bool, "comments": [line comment id]}]}
  events.json        {"<number>": [{"event", "label": name|None, "actor": login|None, "created_at"}]}
  labels.json        [{"name", "color", "description"}]
  checks.json        {"<commit sha>": [{"name", "status", "conclusion"}]}
  ci_runs.json       [{"workflow", "branch", "event", "id", "status", "conclusion", "head_sha", "created_at"}]
  pins.json          [issue number] pinned issues.
  reactions.json     [{"comment": id, "reaction": str}] reactions put on comments.
  site.json          {"<target>": {"<file name>": "<content>"}} what site publish wrote, per target (gist id).
  repo.git/          the fake forge's bare repository (made by the test); `repo clone-url` is its path, branch push pushes to it.

A user is {"login": str|None, "is_bot": bool, "is_owner": bool}. Ids of new comments are the highest comment, review or
line comment id + 1. The clock of every write is NOW below (a fixed time).
"""
import json
import os

NOW = "2026-06-01T12:00:00Z"
FILES = ["prs", "issues", "comments", "reviews", "line_comments", "threads", "events", "labels", "checks", "ci_runs",
         "pins", "reactions", "site"]
EMPTY = {"prs": [], "issues": [], "comments": {}, "reviews": {}, "line_comments": {}, "threads": {}, "events": {},
         "labels": [], "checks": {}, "ci_runs": [], "pins": [], "reactions": [], "site": {}}
ALL_CAPS = ["pin", "resolve_threads", "site", "visibility"]


class WorldError(Exception):
    pass


class World:
    def __init__(self, path):
        self.path = path
        with open(os.path.join(path, "forge.json")) as f:
            self.forge = json.load(f)
        for name in FILES:
            p = os.path.join(path, name + ".json")
            if os.path.exists(p):
                with open(p) as f:
                    setattr(self, name, json.load(f))
            else:
                setattr(self, name, json.loads(json.dumps(EMPTY[name])))

    # --- state ---
    def failing(self):
        return os.path.exists(os.path.join(self.path, "fail"))

    def capabilities(self):
        return sorted(self.forge.get("capabilities", ALL_CAPS))

    def save(self, *names):
        for name in names:
            p = os.path.join(self.path, name + ".json")
            with open(p + ".tmp", "w") as f:
                json.dump(getattr(self, name), f, indent=1)
            os.replace(p + ".tmp", p)

    def bot(self):
        return {"login": self.forge.get("bot") or "noodlebot[bot]", "is_bot": True, "is_owner": False}

    # --- numbers and ids ---
    def next_number(self):
        return max([p["number"] for p in self.prs] + [i["number"] for i in self.issues] + [0]) + 1

    def next_id(self):
        ids = [0]
        for table in (self.comments, self.reviews, self.line_comments):
            ids += [c["id"] for lst in table.values() for c in lst]
        return max(ids) + 1

    def find_pr(self, number):
        for p in self.prs:
            if p["number"] == int(number):
                return p
        raise WorldError("pull request %s not found" % number)

    def find_issue(self, number):
        for i in self.issues:
            if i["number"] == int(number):
                return i
        raise WorldError("issue %s not found" % number)

    # --- reads (normalised, no url) ---
    def pr_list(self, state="open", limit=None):
        want = {"open": ("open",), "merged": ("merged",), "closed": ("closed", "merged"),
                "all": ("open", "closed", "merged")}.get(state)
        if want is None:
            raise WorldError("bad state %r" % (state,))
        out = sorted((p for p in self.prs if p["state"] in want), key=lambda p: -p["number"])
        return out[:int(limit)] if limit else out

    def issue_list(self, label, state="open", oldest_first=False):
        if state not in ("open", "closed", "all"):
            raise WorldError("bad state %r" % (state,))
        out = [i for i in self.issues if label in i["labels"] and state in ("all", i["state"])]
        return sorted(out, key=lambda i: i["number"] if oldest_first else -i["number"])

    def comments_of(self, number, since=None):
        out = list(self.comments.get(str(int(number)), []))
        if since:
            out = [c for c in out if c["created_at"] >= since]
        return sorted(out, key=lambda c: (c["created_at"], c["id"]))

    def ci(self, workflow, sha=None, branch=None, event=None):
        out = [r for r in self.ci_runs if r["workflow"] == workflow and (not sha or r["head_sha"] == sha)
               and (not branch or r["branch"] == branch) and (not event or r["event"] == event)]
        return sorted(out, key=lambda r: (r["created_at"], r["id"]), reverse=True)

    # --- writes ---
    def pr_create(self, head, base, title, body):
        pr = {"number": self.next_number(), "title": title, "body": body, "state": "open", "head": head,
              "head_sha": "f" * 40, "base": base, "author": self.bot(), "mergeable": "UNKNOWN", "created_at": NOW,
              "merged_at": None, "closed_at": None}
        self.prs.append(pr)
        self.save("prs")
        return pr

    def pr_edit(self, number, title=None, body=None):
        pr = self.find_pr(number)
        if title is not None:
            pr["title"] = title
        if body is not None:
            pr["body"] = body
        self.save("prs")
        return pr

    def issue_create(self, title, body, labels=None):
        i = {"number": self.next_number(), "title": title, "body": body, "state": "open", "labels": list(labels or []),
             "is_pr": False, "author": self.bot(), "created_at": NOW}
        self.issues.append(i)
        self.save("issues")
        return i

    def issue_edit(self, number, title=None, body=None, state=None):
        i = self.find_issue(number)
        if title is not None:
            i["title"] = title
        if body is not None:
            i["body"] = body
        if state is not None:
            i["state"] = state
        self.save("issues")
        return i

    def comment_add(self, number, body):
        n = int(number)
        if not any(p["number"] == n for p in self.prs) and not any(i["number"] == n for i in self.issues):
            raise WorldError("#%s not found" % number)
        c = {"id": self.next_id(), "body": body, "author": self.bot(), "created_at": NOW}
        self.comments.setdefault(str(n), []).append(c)
        self.save("comments")
        return c

    def reply(self, number, to, body):
        lst = self.line_comments.get(str(int(number)), [])
        parent = next((c for c in lst if c["id"] == int(to)), None)
        if parent is None:
            raise WorldError("review comment %s not found" % to)
        c = {"id": self.next_id(), "body": body, "author": self.bot(), "path": parent["path"], "line": parent["line"],
             "in_reply_to": parent["id"], "created_at": NOW, "outdated": False}
        lst.append(c)
        for t in self.threads.get(str(int(number)), []):
            if parent["id"] in t["comments"]:
                t["comments"].append(c["id"])
        self.save("line_comments", "threads")
        return c

    def resolve_thread(self, thread):
        for lst in self.threads.values():
            for t in lst:
                if t["id"] == thread:
                    t["resolved"] = True
                    self.save("threads")
                    return
        raise WorldError("thread %s not found" % thread)

    def pin(self, number, on):
        self.find_issue(number)
        n = int(number)
        self.pins = [x for x in self.pins if x != n] + ([n] if on else [])
        self.save("pins")

    def react(self, comment, reaction):
        if not any(c["id"] == int(comment) for lst in self.comments.values() for c in lst):
            raise WorldError("comment %s not found" % comment)
        self.reactions.append({"comment": int(comment), "reaction": reaction})
        self.save("reactions")

    def label_ensure(self, name, color, description):
        if any(l["name"] == name for l in self.labels):
            return False
        self.labels.append({"name": name, "color": color, "description": description})
        self.save("labels")
        return True

    def label_add(self, number, name):
        i = self.find_issue(number)
        if not any(l["name"] == name for l in self.labels):
            raise WorldError("label %s not found" % name)
        if name not in i["labels"]:
            i["labels"].append(name)
        self.save("issues")

    def label_remove(self, number, name):
        i = self.find_issue(number)
        if name not in i["labels"]:
            raise WorldError("label %s is not on #%s" % (name, number))
        i["labels"].remove(name)
        self.save("issues")

    def site_publish(self, target, files):
        cur = self.site.setdefault(target, {})
        for fname, v in files.items():
            if v is None:
                cur.pop(fname, None)
            else:
                cur[fname] = v["content"] if isinstance(v, dict) else v
        self.save("site")


# --- G08: the jobs and logs of a CI run (added; the rules above are unchanged) ---
# ci_jobs.json  {"<run id>": [{"id", "name", "conclusion", "log"}]}: the jobs of a run and each job's whole log text. A run
#               of ci_runs.json with no entry has no jobs; a run id that is not in ci_runs.json is unknown.
# forge.json may also hold "refuse_logs" and "logs_gone": true (every job's log) or a list of job ids. A refused log read
# is the forge refusing the credential (the fake gh answers 403, the fake forge raises CapabilityOff `ci_logs`); a gone log
# is an expired one (the fake gh answers 410, the fake forge raises ForgeError). The jobs list itself is never refused.
def _ci_jobs_all(w):
    p = os.path.join(w.path, "ci_jobs.json")
    if not os.path.exists(p):
        return {}
    with open(p) as f:
        return json.load(f)


def ci_jobs(w, run):
    """The jobs of run `run` (a list, empty when it has none), None when the run is unknown."""
    if not any(r["id"] == int(run) for r in w.ci_runs):
        return None
    return list(_ci_jobs_all(w).get(str(int(run)), []))


def ci_job(w, job_id):
    for lst in _ci_jobs_all(w).values():
        for j in lst:
            if j["id"] == int(job_id):
                return j
    return None


def log_flag(w, key, job_id):
    v = w.forge.get(key)
    return v is True or (isinstance(v, list) and int(job_id) in v)


# --- G09: dispatched runs, the jobs of each attempt and the jobs' web pages (added; the rules above are unchanged) ---
# dispatches.json   [{"workflow", "ref", "inputs": {name: str}, "runs": [run id]}]: each dispatch the forge took, in order
#                   (written by dispatch(); "runs" is empty when the dispatch was accepted and no run appears).
# ci_attempts.json  {"<run id>": {"<attempt>": [{"id", "name", "conclusion", "log"}]}}: the jobs of each attempt of a run
#                   (the latest attempt's jobs are also the run's ci_jobs.json entry; a run with no entry has no attempts).
# ci_job_urls.json  {"<job id>": "<path>"}: a job's web page below the repository's web URL (a job with no entry has
#                   actions/runs/<run id>/job/<job id>).
# forge.json may also hold "dispatch": "id" | "none" (GitHub's answer names the run or does not; the run is added),
# "never" (accepted, no run appears), "two" (two runs appear), "403" | "404" | "422" (the forge refuses or rejects; a 403 is
# the capability off); "refuse_attempts": true (an attempt's job listing is refused, as a 403).
def _g09_read(w, name, empty):
    p = os.path.join(w.path, name + ".json")
    if not os.path.exists(p):
        return empty
    with open(p) as f:
        return json.load(f)


def dispatch(w, workflow, ref, inputs, runs=1):
    """Record one dispatch and add `runs` runs of the workflow on the ref (event workflow_dispatch); the new run ids."""
    ids = []
    for _ in range(runs):
        rid = max([r["id"] for r in w.ci_runs] + [0]) + 1
        w.ci_runs.append({"workflow": workflow, "branch": ref, "event": "workflow_dispatch", "id": rid, "status": "queued",
                          "conclusion": None, "head_sha": "d" * 40, "created_at": NOW})
        ids.append(rid)
    w.save("ci_runs")
    log = _g09_read(w, "dispatches", [])
    log.append({"workflow": workflow, "ref": ref, "inputs": dict(inputs), "runs": ids})
    p = os.path.join(w.path, "dispatches.json")
    with open(p + ".tmp", "w") as f:
        json.dump(log, f, indent=1)
    os.replace(p + ".tmp", p)
    return ids


def dispatches(w):
    return _g09_read(w, "dispatches", [])


def ci_attempt_jobs(w, run, attempt):
    """The jobs of attempt `attempt` of run `run`, None when the run is unknown or has no such attempt."""
    if not any(r["id"] == int(run) for r in w.ci_runs):
        return None
    got = _g09_read(w, "ci_attempts", {}).get(str(int(run)), {}).get(str(int(attempt)))
    return None if got is None else list(got)


def ci_attempt_job(w, job_id):
    for atts in _g09_read(w, "ci_attempts", {}).values():
        for lst in atts.values():
            for j in lst:
                if j["id"] == int(job_id):
                    return j
    return None


def job_path(w, run, job_id):
    return _g09_read(w, "ci_job_urls", {}).get(str(int(job_id))) or "actions/runs/%d/job/%d" % (int(run), int(job_id))


# --- G09 (slice 2): artifacts of a run (added; the rules above are unchanged) ---
# ci_artifacts.json {"<run id>": [{"id", "name", "expired": bool, "entries": [entry]}]}: the artifacts of a run (live and
#                   expired). An entry is {"name": the archive entry's path as stored (may be absolute or hold ".."), and one of
#                   "text": str (stored as UTF-8), "b64": base64 of the bytes (any bytes, not only UTF-8), "link": str (a
#                   symbolic link entry with that target)}. artifact_zip(art) builds the zip archive of an artifact at the time
#                   it is served (zipfile, entries in order, a link entry marked by ZipInfo.external_attr S_IFLNK).
# forge.json may also hold "refuse_artifacts": true (the artifact listing is refused: the fake gh answers 403, the fake forge
# raises CapabilityOff `ci_artifact`), "list" (the same, only the listing), "download" (the fake gh answers 403 on the archive,
# the fake forge raises CapabilityOff `ci_artifact`).
def artifacts(w, run):
    """The artifacts of run `run` (a list, empty when it has none), None when the run is unknown."""
    if not any(r["id"] == int(run) for r in w.ci_runs):
        return None
    return list(_g09_read(w, "ci_artifacts", {}).get(str(int(run)), []))


def artifact_by_id(w, art_id):
    for lst in _g09_read(w, "ci_artifacts", {}).values():
        for a in lst:
            if a["id"] == int(art_id):
                return a
    return None


def artifact_zip(art):
    import base64
    import io
    import stat
    import zipfile
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for e in art.get("entries", []):
            zi = zipfile.ZipInfo(e["name"], (2026, 5, 3, 9, 0, 0))
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.create_system = 3
            if "link" in e:
                zi.external_attr = (stat.S_IFLNK | 0o777) << 16
                z.writestr(zi, e["link"])
            else:
                zi.external_attr = (stat.S_IFREG | 0o644) << 16
                z.writestr(zi, base64.b64decode(e["b64"]) if "b64" in e else e["text"].encode("utf-8"))
    return buf.getvalue()


def entry_bytes(e):
    import base64
    return base64.b64decode(e["b64"]) if "b64" in e else e["text"].encode("utf-8")


def entry_problem(e):
    """Why an archive entry may not be unpacked (an absolute path, a '..' component, a link), else None."""
    n = e["name"]
    if "link" in e:
        return "the entry %r is a link" % n
    if n.startswith("/") or n.startswith("\\") or (len(n) > 1 and n[1] == ":"):
        return "the entry %r is an absolute path" % n
    if ".." in n.replace("\\", "/").split("/"):
        return "the entry %r holds '..'" % n
    return None


def artifact_refusal(w):
    """None, "list" (the listing is refused) or "download" (the archive is refused)."""
    v = w.forge.get("refuse_artifacts")
    return "list" if v is True else (v if v in ("list", "download") else None)
