"""Part of the GitHub backend (forges/github.py): issues, labels and a commit's check runs (report.py, issues.py, labels.py).

Not a module of its own: github.py compiles this file into its own namespace the first time a call needs one of these
operations (so a process compiles only the families it uses), and the functions named in _register at the end become
methods of its Backend. Everything github.py defines is in scope here; `gh` itself is run only by github.py's _run.
"""


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
        if e.status == 422 and _already_exists(e):
            return {"name": name, "created": False}
        raise
    return {"name": name, "created": True}


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


def commit_checks(self, sha):
    got = self._api("GET", self._r("/commits/%s/check-runs?per_page=100" % sha))
    if not isinstance(got, dict) or not isinstance(got.get("check_runs"), list):
        raise forge.ForgeError("the answer for the checks of %s does not parse: no check_runs list" % sha)
    return [{"name": o.get("name"), "status": o.get("status"), "conclusion": o.get("conclusion")}
            for o in got["check_runs"]]


_register(issue_list, issue_view, issue_comments, issue_create, issue_edit, issue_comment, issue_close, issue_reopen,
          _pin, issue_pin, issue_unpin, issue_events, issue_react, _labels, label_list, label_ensure, label_add, label_remove,
          commit_checks)
