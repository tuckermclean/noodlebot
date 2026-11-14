"""Part of the GitHub backend (forges/github.py): a PR's comments, reviews and line comments, a reply, resolving a
thread (feedback.py).

Not a module of its own: github.py compiles this file into its own namespace the first time a call needs one of these
operations (so a process compiles only the families it uses), and the functions named in _register at the end become
methods of its Backend. Everything github.py defines is in scope here; `gh` itself is run only by github.py's _run.
"""


def _review(o):
    return {"id": o["id"], "state": o.get("state"), "body": o.get("body") or "",
            "author": _user(o.get("user"), o.get("author_association")), "submitted_at": o.get("submitted_at"),
            "url": o.get("html_url") or ""}


def _line_comment(o):
    line = o.get("line") if o.get("line") is not None else o.get("original_line")
    return {"id": o["id"], "body": o.get("body") or "", "author": _user(o.get("user"), o.get("author_association")),
            "path": o.get("path"), "line": line, "in_reply_to": o.get("in_reply_to_id"),
            "created_at": o.get("created_at"), "url": o.get("html_url") or ""}


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


_register(_paginate, pr_comments, pr_reviews, pr_line_comments, pr_reply, pr_resolve_thread)
