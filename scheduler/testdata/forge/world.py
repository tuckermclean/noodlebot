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
