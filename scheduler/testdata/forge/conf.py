#!/usr/bin/env python3
"""The conformance cases of scheduler/forge.test.sh (G04-AC-2, the capability half of G04-AC-3).

  conf.py run <github|fake> <workdir> <out.json>   run every case against one backend, through the Python interface
                                                   ("py") and through the CLI ("cli"), each on freshly reset state, and
                                                   write the raw results (and what each write left behind) to <out.json>
  conf.py check <github.json> <fake.json>          compare the two backends' results case by case and print one
                                                   PASS:/FAIL: line per check (details on indented lines)

The GitHub backend runs over fakegh.py on PATH (state in <workdir>/state, calls recorded in calls.jsonl); the fake forge
over the same fixture content (testdata/forge/fixture). Results are compared only by their guaranteed keys (SHAPES); the
"url" of a shape must be a non-empty string but its value is the backend's. Environment of a run: GH_TOKEN and
NOODLEBOT_FORGE_* unset, so the GitHub backend has no token. Both backends see the same numbers: a new issue or PR is
#8, a new comment id is 404, the clock of writes is 2026-06-01T12:00:00Z.
"""
import json
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCHED = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import world as W

NOW = W.NOW
BOT = {"login": "noodlebot[bot]", "is_bot": True, "is_owner": False}
SHA5 = "5" * 40
CI_SHA = "c0ffee" + "0" * 34
GH_REPO = "acme/widgets"
USER = ["login", "is_bot", "is_owner"]
SHAPES = {
    "comment": ["id", "body", "author", "created_at", "url"],
    "review": ["id", "state", "body", "author", "submitted_at", "url"],
    "lc": ["id", "body", "author", "path", "line", "in_reply_to", "created_at", "url"],
    "issue": ["number", "title", "body", "state", "labels", "is_pr", "author", "created_at", "url"],
    "pr": ["number", "title", "body", "state", "head", "head_sha", "base", "author", "mergeable", "created_at",
           "merged_at", "closed_at", "url"],
    "label": ["name", "color", "description"],
    "event": ["event", "label", "actor", "created_at"],
    "check": ["name", "status", "conclusion"],
    "ci": ["id", "status", "conclusion", "head_sha", "created_at"],
}


def proj(shape, v, exp=False, keys=None):
    """The guaranteed keys of v in shape ('list:<shape>', 'user', a SHAPES name, 'raw')."""
    if shape == "raw":
        return v
    if shape.startswith("list:"):
        if not isinstance(v, list):
            return "<NOT A LIST: %r>" % (v,)
        return [proj(shape[5:], x, exp, keys) for x in v]
    if not isinstance(v, dict):
        return "<NOT AN OBJECT: %r>" % (v,)
    if shape == "user":
        return {k: v.get(k, "<MISSING %s>" % k) for k in USER}
    out = {}
    for k in SHAPES[shape]:
        if keys and k not in keys:
            continue
        if k == "url":
            out[k] = "<url>" if exp or (isinstance(v.get("url"), str) and v["url"]) else "<MISSING url>"
        elif k == "author":
            out[k] = proj("user", v["author"], exp) if isinstance(v.get("author"), dict) else "<MISSING author>"
        else:
            out[k] = v.get(k, "<MISSING %s>" % k)
    return out


def fixture():
    return W.World(os.path.join(HERE, "fixture"))


def by(lst, key, *vals):
    return [x for v in vals for x in lst if x[key] == v]


def upd(d, **kw):
    d = dict(d)
    d.update(kw)
    return d


F = fixture()
PR = lambda n: by(F.prs, "number", n)[0]
ISS = lambda n: by(F.issues, "number", n)[0]
NEWC = lambda body, **kw: dict({"id": 404, "body": body, "author": BOT, "created_at": NOW}, **kw)


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def cases():
    cs = []

    def add(id, op, kw=None, shape="raw", **more):
        c = {"id": id, "op": op, "kw": kw or {}, "shape": shape}
        c.update(more)
        cs.append(c)

    pub = lambda b, m: "public"
    # --- repository ---
    add("repo visibility public", "repo visibility", expect=pub)
    add("repo visibility private", "repo visibility", expect=lambda b, m: "private",
        setup=lambda s: edit_forge(s, private=True))
    add("repo default-branch", "repo default-branch", expect=lambda b, m: "main")
    add("repo default-branch trunk", "repo default-branch", expect=lambda b, m: "trunk",
        setup=lambda s: edit_forge(s, default_branch="trunk"))
    add("repo clone-url", "repo clone-url", expect=lambda b, m: GH_URL if b == "github" else m["state"] + "/repo.git")
    for kind, ref, tail in (("repo", None, ""), ("issue", "1", "/issues/1"), ("pr", "5", "/pull/5"),
                            ("commit", SHA5, "/commit/" + SHA5)):
        add("repo url %s" % kind, "repo url", {"kind": kind, **({"ref": ref} if ref else {})},
            expect=lambda b, m, tail=tail: (GH_URL if b == "github" else "fake://acme/widgets") + tail)
    add("repo identities", "repo identities", expect=lambda b, m: {"owner": "acme", "bot": None})
    # --- pull requests: reads ---
    for st, nums in (("open", (6, 5)), ("closed", (7, 4)), ("merged", (7,)), ("all", (7, 6, 5, 4))):
        add("pr list %s" % st, "pr list", {"state": st, "limit": 500}, "list:pr",
            expect=lambda b, m, nums=nums: by(F.prs, "number", *nums))
    add("pr list limit 2", "pr list", {"state": "all", "limit": 2}, "list:pr", expect=lambda b, m: by(F.prs, "number", 7, 6))
    wanted = ["number", "head", "head_sha", "author", "mergeable"]
    add("pr list fields", "pr list", {"state": "open", "limit": 500, "fields": wanted}, "list:pr", keys=wanted,
        expect=lambda b, m: by(F.prs, "number", 6, 5))
    for n in (5, 6, 7, 4):
        add("pr view %d" % n, "pr view", {"number": n}, "pr", expect=lambda b, m, n=n: PR(n))
    add("pr comments", "pr comments", {"number": 5}, "list:comment", expect=lambda b, m: F.comments["5"])
    add("pr reviews", "pr reviews", {"number": 5}, "list:review", expect=lambda b, m: F.reviews["5"])
    add("pr line-comments", "pr line-comments", {"number": 5}, "list:lc", expect=lambda b, m: F.line_comments["5"])
    # --- issues: reads ---
    for st, nums in (("open", (2, 1)), ("closed", (3,)), ("all", (3, 2, 1))):
        add("issue list %s" % st, "issue list", {"label": "noodlebot", "state": st}, "list:issue",
            expect=lambda b, m, nums=nums: by(F.issues, "number", *nums))
    add("issue list oldest-first", "issue list", {"label": "noodlebot", "state": "all", "oldest_first": True},
        "list:issue", expect=lambda b, m: by(F.issues, "number", 1, 2, 3))
    add("issue list other label", "issue list", {"label": "bug", "state": "open"}, "list:issue",
        expect=lambda b, m: by(F.issues, "number", 1))
    add("issue view 1", "issue view", {"number": 1}, "issue", expect=lambda b, m: ISS(1))
    add("issue view 3 (closed)", "issue view", {"number": 3}, "issue", expect=lambda b, m: ISS(3))
    add("issue comments", "issue comments", {"number": 1}, "list:comment", expect=lambda b, m: F.comments["1"])
    add("issue comments since", "issue comments", {"number": 1, "since": "2026-05-02T00:00:00Z"}, "list:comment",
        expect=lambda b, m: F.comments["1"][1:])
    add("issue events", "issue events", {"number": 1}, "list:event", expect=lambda b, m: F.events["1"])
    add("label list", "label list", {}, "list:label", expect=lambda b, m: F.labels)
    add("commit checks", "commit checks", {"sha": SHA5}, "list:check", expect=lambda b, m: F.checks[SHA5])
    add("ci runs", "ci runs", {"workflow": "ci.yml", "sha": CI_SHA, "branch": "main", "event": "push"}, "list:ci",
        expect=lambda b, m: by(F.ci_runs, "id", 9002, 9001))
    add("ci runs without branch", "ci runs", {"workflow": "ci.yml", "sha": CI_SHA}, "list:ci",
        expect=lambda b, m: by(F.ci_runs, "id", 9004, 9002, 9001))
    # --- writes: result, then the effect read back ---
    new_pr = {"number": 8, "title": "New PR", "body": "new body", "state": "open", "head": "feat/new", "head_sha": "f" * 40,
              "base": "main", "author": BOT, "mergeable": "UNKNOWN", "created_at": NOW, "merged_at": None,
              "closed_at": None}
    add("pr create", "pr create", {"head": "feat/new", "base": "main", "title": "New PR", "body": "new body"}, "pr",
        expect=lambda b, m: new_pr, effect=("pr view", {"number": 8}, "pr"), effect_expect=lambda b, m: new_pr,
        gh=[("POST", "repos/acme/widgets/pulls", {"head": "feat/new", "base": "main", "title": "New PR"})])
    edited = upd(PR(5), title="G04 forge v2", body="Resolves #1, #2")
    add("pr edit", "pr edit", {"number": 5, "title": "G04 forge v2", "body": "Resolves #1, #2"}, "pr",
        expect=lambda b, m: edited, effect=("pr view", {"number": 5}, "pr"), effect_expect=lambda b, m: edited,
        gh=[("PATCH", "repos/acme/widgets/pulls/5", {"title": "G04 forge v2", "body": "Resolves #1, #2"})])
    add("pr comment", "pr comment", {"number": 5, "body": "a PR comment"}, "comment",
        expect=lambda b, m: NEWC("a PR comment"), effect=("pr comments", {"number": 5}, "list:comment"),
        effect_expect=lambda b, m: F.comments["5"] + [NEWC("a PR comment")],
        gh=[("POST", "repos/acme/widgets/issues/5/comments", {"body": "a PR comment"})])
    reply = {"id": 404, "body": "agreed", "author": BOT, "path": "scheduler/forge.py", "line": 12, "in_reply_to": 401,
             "created_at": NOW}
    add("pr reply", "pr reply", {"number": 5, "to": 401, "body": "agreed"}, "lc", expect=lambda b, m: reply,
        effect=("pr line-comments", {"number": 5}, "list:lc"), effect_expect=lambda b, m: F.line_comments["5"] + [reply],
        gh=[("POST", "repos/acme/widgets/pulls/5/comments/401/replies", {"body": "agreed"})])
    add("pr resolve-thread", "pr resolve-thread", {"thread": "PRRT_5a"}, expect=lambda b, m: {}, observe="resolved",
        observe_expect=["PRRT_5a"], gh=[("POST", "graphql", "resolveReviewThread")])
    new_issue = {"number": 8, "title": "New issue", "body": "text", "state": "open", "labels": ["noodlebot", "bug"],
                 "is_pr": False, "author": BOT, "created_at": NOW}
    add("issue create", "issue create", {"title": "New issue", "body": "text", "labels": ["noodlebot", "bug"]}, "issue",
        expect=lambda b, m: new_issue, effect=("issue view", {"number": 8}, "issue"), effect_expect=lambda b, m: new_issue,
        gh=[("POST", "repos/acme/widgets/issues", {"title": "New issue", "labels": ["noodlebot", "bug"]})])
    ed = upd(ISS(1), title="Forge, renamed", body="New text")
    add("issue edit", "issue edit", {"number": 1, "title": "Forge, renamed", "body": "New text"}, "issue",
        expect=lambda b, m: ed, effect=("issue view", {"number": 1}, "issue"), effect_expect=lambda b, m: ed,
        gh=[("PATCH", "repos/acme/widgets/issues/1", {"title": "Forge, renamed"})])
    add("issue comment", "issue comment", {"number": 1, "body": "an issue comment"}, "comment",
        expect=lambda b, m: NEWC("an issue comment"), effect=("issue comments", {"number": 1}, "list:comment"),
        effect_expect=lambda b, m: F.comments["1"] + [NEWC("an issue comment")],
        gh=[("POST", "repos/acme/widgets/issues/1/comments", {"body": "an issue comment"})])
    add("issue comment by body file", "issue comment", {"number": 1, "body": "from a file"}, "comment",
        cli={"body": None, "body_file": "<WORK>/body.txt"}, expect=lambda b, m: NEWC("from a file"),
        effect=("issue comments", {"number": 1}, "list:comment"),
        effect_expect=lambda b, m: F.comments["1"] + [NEWC("from a file")],
        gh=[("POST", "repos/acme/widgets/issues/1/comments", {"body": "from a file"})])
    add("issue close", "issue close", {"number": 2}, "issue", expect=lambda b, m: upd(ISS(2), state="closed"),
        effect=("issue view", {"number": 2}, "issue"), effect_expect=lambda b, m: upd(ISS(2), state="closed"),
        gh=[("PATCH", "repos/acme/widgets/issues/2", {"state": "closed", "state_reason": "completed"})])
    add("issue reopen", "issue reopen", {"number": 3}, "issue", expect=lambda b, m: upd(ISS(3), state="open"),
        effect=("issue view", {"number": 3}, "issue"), effect_expect=lambda b, m: upd(ISS(3), state="open"),
        gh=[("PATCH", "repos/acme/widgets/issues/3", {"state": "open"})])
    add("issue pin", "issue pin", {"number": 1}, expect=lambda b, m: {}, observe="pins", observe_expect=[1],
        gh=[("POST", "graphql", "pinIssue"), ("POST", "graphql", "I_node_1")])
    add("issue unpin", "issue unpin", {"number": 1}, expect=lambda b, m: {}, observe="pins", observe_expect=[],
        setup=lambda s: put(s, "pins", [1]), gh=[("POST", "graphql", "unpinIssue")])
    add("issue react", "issue react", {"comment": 101, "reaction": "+1"}, expect=lambda b, m: {}, observe="reactions",
        observe_expect=[{"comment": 101, "reaction": "+1"}],
        gh=[("POST", "repos/acme/widgets/issues/comments/101/reactions", {"content": "+1"})])
    newlab = {"name": "new-one", "color": "123456", "description": "A new label"}
    add("label ensure new", "label ensure", {"name": "new-one", "color": "123456", "description": "A new label"},
        expect=lambda b, m: {"name": "new-one", "created": True}, effect=("label list", {}, "list:label"),
        effect_expect=lambda b, m: F.labels + [newlab],
        gh=[("POST", "repos/acme/widgets/labels", {"name": "new-one", "color": "123456"})])
    add("label ensure existing", "label ensure", {"name": "bug", "color": "d73a4a", "description": ""},
        expect=lambda b, m: {"name": "bug", "created": False}, effect=("label list", {}, "list:label"),
        effect_expect=lambda b, m: F.labels)
    add("label add", "label add", {"number": 2, "name": "bug"}, expect=lambda b, m: {},
        effect=("issue view", {"number": 2}, "issue"), effect_expect=lambda b, m: upd(ISS(2), labels=["noodlebot", "bug"]),
        gh=[("POST", "repos/acme/widgets/issues/2/labels", {"labels": ["bug"]})])
    add("label remove", "label remove", {"number": 1, "name": "bug"}, expect=lambda b, m: {},
        effect=("issue view", {"number": 1}, "issue"), effect_expect=lambda b, m: upd(ISS(1), labels=["noodlebot"]),
        gh=[("DELETE", "repos/acme/widgets/issues/1/labels/bug", None)])
    add("site publish", "site publish", {"target": "gist123", "input": "<WORK>/site-body.json"}, expect=lambda b, m: {},
        observe="site", observe_expect={"gist123": {"index.json": "{\"a\": 1}"}},
        gh=[("PATCH", "gists/gist123", {"files": {"index.json": {"content": "{\"a\": 1}"}}})])
    add("branch push", "branch push", {"path": "<WORK>/checkout", "branch": "feat/x"}, expect=lambda b, m: {},
        observe="push", observe_expect=None)  # expectation: the commit of the checkout's feat/x (see check)
    # --- R02-AC-6: the operations the texts need (change 6 of R02): new cases only, G04's cases above are unchanged ---
    add("R02-AC-6 pr close", "pr close", {"number": 6}, "pr", expect=lambda b, m: upd(PR(6), state="closed", closed_at=NOW),
        effect=("pr view", {"number": 6}, "pr"), effect_expect=lambda b, m: upd(PR(6), state="closed", closed_at=NOW),
        gh=[("PATCH", "repos/acme/widgets/pulls/6", {"state": "closed"})])
    add("R02-AC-6 pr view merge_commit of a merged PR", "pr view", {"number": 7}, "prm",
        expect=lambda b, m: {"number": 7, "state": "merged", "merge_commit": MERGE_SHA},
        setup=lambda s: set_pr(s, 7, merge_commit=MERGE_SHA))
    add("R02-AC-6 pr view merge_commit of an open PR is null", "pr view", {"number": 5}, "prm",
        expect=lambda b, m: {"number": 5, "state": "open", "merge_commit": None})
    add("R02-AC-6 pr view merge_commit of a PR closed unmerged is null", "pr view", {"number": 4}, "prm",
        expect=lambda b, m: {"number": 4, "state": "closed", "merge_commit": None})
    add("R02-AC-6 ci runs by branch alone", "ci runs", {"branch": "main"}, "list:ci",
        expect=lambda b, m: by(F.ci_runs, "id", 9005, 9003, 9002, 9001))
    add("R02-AC-6 ci runs by another branch alone", "ci runs", {"branch": "feat/two"}, "list:ci",
        expect=lambda b, m: by(F.ci_runs, "id", 9004))
    add("R02-AC-6 ci runs by an unknown branch is empty", "ci runs", {"branch": "no/such"}, "list:ci", expect=lambda b, m: [])
    add("R02-AC-6 ci runs by branch and event", "ci runs", {"branch": "main", "event": "push"}, "list:ci",
        expect=lambda b, m: by(F.ci_runs, "id", 9005, 9003, 9002, 9001))
    reran = upd(by(F.ci_runs, "id", 9001)[0], status="queued", conclusion=None)
    add("R02-AC-6 ci rerun", "ci rerun", {"run": 9001}, expect=lambda b, m: {},
        effect=("ci runs", {"workflow": "ci.yml", "sha": CI_SHA}, "list:ci"),
        effect_expect=lambda b, m: [by(F.ci_runs, "id", 9004)[0], by(F.ci_runs, "id", 9002)[0], reran],
        gh=[("POST", "repos/acme/widgets/actions/runs/9001/rerun-failed-jobs", None)])
    add("R02-AC-6 repo url run", "repo url", {"kind": "run", "ref": "9001"},
        expect=lambda b, m: (GH_URL if b == "github" else "fake://acme/widgets") + "/actions/runs/9001")
    add("R02-AC-6 issue list without a label, state all", "issue list", {"state": "all"}, "list:issue",
        expect=lambda b, m: [NOLAB] + by(F.issues, "number", 3, 2, 1), setup=lambda s: add_issue(s, NOLAB))
    add("R02-AC-6 issue list without a label, default state is open", "issue list", {}, "list:issue",
        expect=lambda b, m: [NOLAB] + by(F.issues, "number", 2, 1), setup=lambda s: add_issue(s, NOLAB))
    add("R02-AC-6 issue list without a label, state closed", "issue list", {"state": "closed"}, "list:issue",
        expect=lambda b, m: by(F.issues, "number", 3), setup=lambda s: add_issue(s, NOLAB))
    add("R02-AC-6 issue list without a label, oldest first", "issue list", {"state": "all", "oldest_first": True}, "list:issue",
        expect=lambda b, m: by(F.issues, "number", 1, 2, 3) + [NOLAB], setup=lambda s: add_issue(s, NOLAB))
    add("R02-AC-6 issue list with a label and state all still filters", "issue list", {"label": "bug", "state": "all"}, "list:issue",
        expect=lambda b, m: by(F.issues, "number", 1), setup=lambda s: add_issue(s, NOLAB))
    add("R02-AC-6 repo permissions with every access", "repo permissions", {}, "raw",
        expect=lambda b, m: {"read": True, "write": True, "admin": True})
    add("R02-AC-6 repo permissions without admin", "repo permissions", {}, "raw",
        expect=lambda b, m: {"read": True, "write": True, "admin": False},
        setup=lambda s: edit_forge(s, permissions={"read": True, "write": True, "admin": False}))
    add("R02-AC-6 repo permissions read-only", "repo permissions", {}, "raw",
        expect=lambda b, m: {"read": True, "write": False, "admin": False},
        setup=lambda s: edit_forge(s, permissions={"read": True, "write": False, "admin": False}))
    # --- G08: ci logs (the fake forge is configured with the capability; the default fixture has the four of G04) ---
    on = lambda s: edit_forge(s, capabilities=G08_CAPS)
    add("G08-AC-1 ci logs --run of a failed run", "ci logs", {"run": 9001}, "list:cilog", expect=lambda b, m: g08_jobs(9001), setup=on)
    add("G08-AC-1 ci logs --run of a green run", "ci logs", {"run": 9002}, "list:cilog", expect=lambda b, m: g08_jobs(9002), setup=on)
    add("G08-AC-1 ci logs --run --job returns only that job", "ci logs", {"run": 9001, "job": "lint"}, "list:cilog",
        expect=lambda b, m: g08_jobs(9001, "lint"), setup=on)
    add("G08-AC-1 ci logs --run --job of the failed job", "ci logs", {"run": 9001, "job": "test"}, "list:cilog",
        expect=lambda b, m: g08_jobs(9001, "test"), setup=on)
    add("G08-AC-1 ci logs --run of a run with no jobs is an empty list", "ci logs", {"run": 9003}, "list:cilog",
        expect=lambda b, m: [], setup=on)
    add("G08-AC-1 ci logs --run of a run with more jobs than the default page (3 jobs, 2 per page)", "ci logs", {"run": 9004}, "list:cilog",
        expect=lambda b, m: g08_jobs(9004), setup=on)
    # --- G08 (second round): the log as the forge serves it, and paging past the page a call is given ---
    add("G08-AC-1 ci logs returns a log byte for byte (CRLF, a lone CR, a non-ASCII character, no final newline)", "ci logs",
        {"run": 9100}, "list:cilog", expect=lambda b, m: g08_extra_jobs(9100), setup=lambda s: (on(s), g08_extra_runs(s)))
    add("G08-AC-1 ci logs of a run with more jobs than a page holds (5 jobs, a page of at most 2) returns them all", "ci logs",
        {"run": 9101}, "list:cilog", expect=lambda b, m: g08_extra_jobs(9101), setup=lambda s: (on(s), g08_extra_runs(s)))
    add("G08-AC-1 ci logs --job of a run with more jobs than a page holds returns the job from the last page", "ci logs",
        {"run": 9101, "job": "job-5"}, "list:cilog", expect=lambda b, m: g08_extra_jobs(9101, "job-5"),
        setup=lambda s: (on(s), g08_extra_runs(s)))
    return cs


GH_URL = "https://github.com/acme/widgets"

FAIL_OPS = [
    ("repo default-branch", {}), ("pr list", {"state": "all", "limit": 500}), ("pr view", {"number": 5}),
    ("pr comments", {"number": 5}), ("pr reviews", {"number": 5}), ("pr line-comments", {"number": 5}),
    ("issue list", {"label": "noodlebot", "state": "open"}), ("issue view", {"number": 1}),
    ("issue comments", {"number": 1}), ("issue events", {"number": 1}), ("label list", {}),
    ("commit checks", {"sha": SHA5}), ("ci runs", {"workflow": "ci.yml", "sha": CI_SHA}),
    ("issue create", {"title": "t", "body": "b"}), ("label ensure", {"name": "x", "color": "000000", "description": ""}),
]
MISSING_OPS = [("issue view", {"number": 99}), ("pr view", {"number": 99}), ("issue comments", {"number": 99})]
# R02-AC-6: the same failure rules for the new operations (the lists are extended, G04's entries are untouched)
SHAPES["prm"] = ["number", "state", "merge_commit"]
MERGE_SHA = "7" * 40
NOLAB = {"number": 8, "title": "No label", "body": "Unlabelled.", "state": "open", "labels": [], "is_pr": False,
         "author": {"login": "ada", "is_bot": False, "is_owner": False}, "created_at": "2026-05-08T07:00:00Z"}
FAIL_OPS += [("pr close", {"number": 6}), ("ci rerun", {"run": 9001}), ("repo permissions", {})]
MISSING_OPS += [("pr close", {"number": 99}), ("ci rerun", {"run": 99999})]


def set_pr(s, number, **kw):
    p = os.path.join(s, "prs.json")
    d = json.load(open(p))
    for x in d:
        if x["number"] == number:
            x.update(kw)
    json.dump(d, open(p, "w"))


def add_issue(s, issue):
    p = os.path.join(s, "issues.json")
    d = json.load(open(p))
    json.dump(d + [issue], open(p, "w"))


def edit_forge(s, **kw):
    p = os.path.join(s, "forge.json")
    d = json.load(open(p))
    d.update(kw)
    json.dump(d, open(p, "w"))


def put(s, name, value):
    json.dump(value, open(os.path.join(s, name + ".json"), "w"))


# G08: ci logs
SHAPES["cilog"] = ["id", "name", "conclusion", "log"]
G08_CAPS = ["pin", "resolve_threads", "site", "visibility", "ci_logs"]
G08_FOUR = ["pin", "resolve_threads", "site", "visibility"]


def g08_jobs(run, job=None):
    """The expected result of `ci logs`: the fixture's jobs of the run (only the job named `job` when given)."""
    with open(os.path.join(HERE, "fixture", "ci_jobs.json")) as f:
        return [dict(j) for j in json.load(f).get(str(run), []) if job is None or j["name"] == job]


def run_g08(backend, ctx, spec):
    """The failing and refused log reads of both backends, and the fake forge without ci_logs: raw py/cli results."""
    out = {}
    for tag, run, kw, edits, fail in (
            ("fail", 9001, {}, {}, True),
            ("missing run", 99999, {}, {}, False),
            ("expired log", 9001, {}, {"logs_gone": True}, False),
            ("refused", 9001, {}, {"refuse_logs": True}, False),
            ("refused one log of two", 9001, {}, {"refuse_logs": [7002]}, False),
            ("refused with --job", 9001, {"job": "lint"}, {"refuse_logs": True}, False)):
        res = {}
        for mode in ("py", "cli"):
            reset(ctx)
            edit_forge(ctx.state, capabilities=G08_CAPS, **edits)
            if fail:
                open(os.path.join(ctx.state, "fail"), "w").close()
            res[mode] = (run_py if mode == "py" else run_cli)(spec, "ci logs", dict(kw, run=run))
        out["G08: " + tag] = res
    if backend == "fake":
        for tag, caps, fail in (("default fixture", None, False), ("four capabilities listed", G08_FOUR, False),
                                ("no ci_logs and the fail switch on", G08_FOUR, True)):
            res = {}
            for mode in ("py", "cli"):
                reset(ctx)
                if caps is not None:
                    edit_forge(ctx.state, capabilities=caps)
                if fail:
                    open(os.path.join(ctx.state, "fail"), "w").close()
                res[mode] = (run_py if mode == "py" else run_cli)(spec, "ci logs", {"run": 9001})
            out["G08: lacks: " + tag] = res
    return out


# G08 (second round): two runs added to a case's state (the fixture files are untouched)
G08_LOG_BYTES = "step 1\r\nprogress 10%\rprogress 100%\r\ncaf\u00e9 \u2713 done\nlast line without a newline"
G08_EXTRA = {
    "9100": [{"id": 7201, "name": "build", "conclusion": "failure", "log": G08_LOG_BYTES}],
    "9101": [{"id": 7300 + n, "name": "job-%d" % n, "conclusion": "success", "log": "log of job-%d\n" % n} for n in range(1, 6)],
}


def g08_extra_jobs(run, job=None):
    return [dict(j) for j in G08_EXTRA[str(run)] if job is None or j["name"] == job]


def g08_extra_runs(s):
    p = os.path.join(s, "ci_runs.json")
    runs = json.load(open(p))
    for rid in (9100, 9101):
        runs.append({"workflow": "ci.yml", "branch": "feat/g08", "event": "push", "id": rid, "status": "completed",
                     "conclusion": "failure" if rid == 9100 else "success", "head_sha": "e" * 40,
                     "created_at": "2026-05-04T10:00:00Z"})
    json.dump(runs, open(p, "w"))
    p = os.path.join(s, "ci_jobs.json")
    jobs = json.load(open(p))
    jobs.update(G08_EXTRA)
    json.dump(jobs, open(p, "w"))


def run_g08b(backend, ctx, spec):
    """The GitHub backend given a jobs listing that is not {"jobs": [...]}: raw py/cli results."""
    out = {}
    if backend != "github":
        return out
    for tag in ("empty", "null", "list"):
        res = {}
        for mode in ("py", "cli"):
            reset(ctx)
            edit_forge(ctx.state, capabilities=G08_CAPS, jobs_page=tag)
            res[mode] = (run_py if mode == "py" else run_cli)(spec, "ci logs", {"run": 9001})
        out["G08b: " + tag] = res
    return out


def g08b_check(data):
    for tag, what in (("empty", "{}"), ("null", '{"jobs": null}'), ("list", "[]")):
        probs = []
        rec = data["github"].get("G08b: " + tag)
        if not rec:
            probs.append("github: not run")
        else:
            p, k = rec["py"], rec["cli"]
            if p.get("exc") != "ForgeError":
                probs.append("github py: expected ForgeError, got %s" % summ(p))
            if k.get("rc") != 1 or k.get("stdout") or not k.get("stderr"):
                probs.append("github cli: expected exit 1, empty stdout, a stderr line; got %s" % summ(k))
        line(not probs, "G08-AC-1: ci logs when the jobs listing answers %s at exit 0 is a failed call (ForgeError / exit 1, nothing on stdout), never an empty list" % what, probs)


def g08_check(data):
    AC1, AC2 = "G08-AC-1", "G08-AC-2"
    for tag in ("fail", "missing run", "expired log"):
        probs = []
        for b in data:
            rec = data[b].get("G08: " + tag)
            if not rec:
                probs.append("%s: not run" % b)
                continue
            p, k = rec["py"], rec["cli"]
            if p.get("exc") != "ForgeError":
                probs.append("%s py: expected ForgeError, got %s" % (b, summ(p)))
            if k.get("rc") != 1 or k.get("stdout") or not k.get("stderr"):
                probs.append("%s cli: expected exit 1, empty stdout, a stderr line; got %s" % (b, summ(k)))
        line(not probs, "%s: ci logs (%s) raises ForgeError / exits 1 with nothing on stdout, never an empty list" % (AC1, tag), probs)
    for tag in ("refused", "refused one log of two", "refused with --job"):
        probs = []
        for b in data:
            rec = data[b].get("G08: " + tag)
            if not rec:
                probs.append("%s: not run" % b)
                continue
            p, k = rec["py"], rec["cli"]
            want = "forge %s lacks ci_logs" % b
            if p.get("exc") != "CapabilityOff" or p.get("cap") != "ci_logs" or want not in p.get("msg", ""):
                probs.append("%s py: expected CapabilityOff(ci_logs) '%s', got %s" % (b, want, summ(p)))
            if k.get("rc") != 3 or k.get("stdout") or want not in k.get("stderr", ""):
                probs.append("%s cli: expected exit 3, empty stdout, stderr '%s'; got %s" % (b, want, summ(k)))
        line(not probs, "%s: ci logs with a log read the forge refuses (%s) raises CapabilityOff / exits 3 naming ci_logs, no list, no empty log" % (AC2, tag), probs)
    fk = data["fake"]
    for tag in ("default fixture", "four capabilities listed", "no ci_logs and the fail switch on"):
        rec = fk.get("G08: lacks: " + tag)
        probs = []
        if not rec:
            probs.append("not run")
        else:
            p, k = rec["py"], rec["cli"]
            want = "forge fake lacks ci_logs"
            if p.get("exc") != "CapabilityOff" or p.get("cap") != "ci_logs" or want not in p.get("msg", ""):
                probs.append("py: expected CapabilityOff(ci_logs) '%s', got %s" % (want, summ(p)))
            if k.get("rc") != 3 or k.get("stdout") or want not in k.get("stderr", ""):
                probs.append("cli: expected exit 3, empty stdout, stderr '%s'; got %s" % (want, summ(k)))
        line(not probs, "%s: ci logs on a fake forge configured without ci_logs (%s) exits 3 naming ci_logs, before any call" % (AC2, tag), probs)


# ------------------------------------------------------------------ running
class Ctx:
    pass


def subst(v, work):
    if isinstance(v, str):
        return v.replace("<WORK>", work)
    if isinstance(v, list):
        return [subst(x, work) for x in v]
    if isinstance(v, dict):
        return {k: subst(x, work) for k, x in v.items()}
    return v


def cli_args(kw):
    out = []
    for k, v in kw.items():
        flag = "--" + k.replace("_", "-")
        if isinstance(v, list):
            for x in v:
                out += [flag, str(x)]
        elif v is True:
            out.append(flag)
        elif v is False or v is None:
            continue
        else:
            out += [flag, str(v)]
    return out


def jsonable(v):
    return json.loads(json.dumps(v, default=str))


def run_py(spec, op, kw):
    try:
        import forge
    except Exception as e:  # forge.py is missing or broken: every case reports it
        return {"exc": type(e).__name__, "msg": str(e)[:300]}
    try:
        f = forge.open(spec)
        fam, o = op.split(" ", 1)
        return {"ok": jsonable(getattr(f, fam + "_" + o.replace("-", "_"))(**kw))}
    except Exception as e:
        return {"exc": type(e).__name__, "msg": str(e)[:300], "cap": getattr(e, "capability", None)}


def run_cli(spec, op, kw):
    try:
        r = sh([sys.executable, "-I", os.path.join(SCHED, "forge.py"), "--repo", spec] + op.split(" ", 1) + cli_args(kw),
               timeout=60, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return {"rc": "timeout", "stdout": "", "stderr": ""}
    if r.returncode == 0:
        try:
            return {"ok": json.loads(r.stdout)}
        except ValueError:
            return {"rc": 0, "stdout": r.stdout[:300], "stderr": "stdout is not one JSON document"}
    return {"rc": r.returncode, "stdout": r.stdout[:300], "stderr": r.stderr[:300]}


def observe(name, ctx):
    s = ctx.state
    if name == "pins":
        return json.load(open(os.path.join(s, "pins.json")))
    if name == "resolved":
        t = json.load(open(os.path.join(s, "threads.json")))
        return sorted(x["id"] for lst in t.values() for x in lst if x["resolved"])
    if name == "reactions":
        return json.load(open(os.path.join(s, "reactions.json")))
    if name == "site":
        return json.load(open(os.path.join(s, "site.json")))
    if name == "push":
        r = sh(["git", "--git-dir", ctx.bare, "for-each-ref", "--format=%(refname) %(objectname)"])
        return dict(l.split(" ") for l in r.stdout.split("\n") if l)
    return None


def calls_of(ctx):
    p = os.path.join(ctx.state, "calls.jsonl")
    if not os.path.exists(p):
        return []
    return [json.loads(l) for l in open(p) if l.strip()]


def reset(ctx):
    shutil.rmtree(ctx.state, ignore_errors=True)
    shutil.copytree(os.path.join(HERE, "fixture"), ctx.state)
    shutil.rmtree(ctx.bare, ignore_errors=True)
    shutil.copytree(ctx.bare_template, ctx.bare)


def run_all(backend, work, outfile):
    ctx = Ctx()
    ctx.state = os.path.join(work, "state")
    ctx.bare_template = os.path.join(work, "bare-template.git")
    ctx.bare = os.path.join(ctx.state, "repo.git") if backend == "fake" else os.path.join(work, "bare-gh.git")
    spec = "fake:" + ctx.state if backend == "fake" else GH_REPO
    meta = {"state": ctx.state, "backend": backend}
    env = os.environ
    for k in [k for k in env if k == "GH_TOKEN" or k.startswith("NOODLEBOT_FORGE")]:
        del env[k]
    if backend == "github":
        env["PATH"] = os.path.join(work, "bin") + ":" + env["PATH"]
        env["FAKE_GH_DIR"] = ctx.state
        env["FAKE_GH_JOBS_PER_PAGE"] = "2"  # G08: a run list without per_page or --paginate gets 2 jobs, not all
        env["FAKE_GH_JOBS_MAX_PER_PAGE"] = "2"  # G08: a page holds at most 2 jobs whatever per_page asks: a call that does not page loses jobs
        env.update(GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="url.%s.insteadOf" % ctx.bare, GIT_CONFIG_VALUE_0=GH_URL)
    sys.path.insert(0, SCHED)
    out = {"_meta": meta}
    for c in cases():
        res = {}
        for mode in ("py", "cli"):
            reset(ctx)
            if c.get("setup"):
                c["setup"](ctx.state)
            kw = subst(c["kw"], work)
            ckw = subst(dict(kw, **c["cli"]), work) if mode == "cli" and c.get("cli") else kw
            run = (run_py if mode == "py" else run_cli)
            rec = {"op": run(spec, c["op"], ckw)}
            if c.get("effect") and "ok" in rec["op"]:
                eop, ekw, _ = c["effect"]
                rec["effect"] = run(spec, eop, ekw)
            if c.get("observe"):
                try:
                    rec["observe"] = observe(c["observe"], ctx)
                except Exception as e:
                    rec["observe"] = "<%s: %s>" % (type(e).__name__, e)
            if backend == "github":
                rec["calls"] = calls_of(ctx)
            if c["id"] == "branch push":
                head = sh(["git", "-C", os.path.join(work, "checkout"), "rev-parse", "feat/x"]).stdout.strip()
                rec["head"] = head
            res[mode] = rec
        out[c["id"]] = res
    # failing calls: the switch is on
    for tag, lst in (("fail", FAIL_OPS), ("missing", MISSING_OPS)):
        for op, kw in lst:
            res = {}
            for mode in ("py", "cli"):
                reset(ctx)
                if tag == "fail":
                    open(os.path.join(ctx.state, "fail"), "w").close()
                res[mode] = (run_py if mode == "py" else run_cli)(spec, op, kw)
            out["%s: %s" % (tag, op)] = res
    if backend == "fake":
        out["_caps"] = run_caps(ctx, work)
    out.update(run_g08(backend, ctx, spec))
    out.update(run_g08b(backend, ctx, spec))
    json.dump(out, open(outfile, "w"))


def run_caps(ctx, work):
    """The fake forge configured without some capabilities: caps, and the operations of the missing ones."""
    out = {}
    for tag, caps, ops in (
            ("no pin, no site", ["resolve_threads", "visibility"],
             [("issue pin", {"number": 1}), ("issue unpin", {"number": 1}), ("site publish", {"target": "g", "input": os.path.join(work, "site-body.json")}),
              ("pr resolve-thread", {"thread": "PRRT_5a"}), ("repo visibility", {})]),
            ("none", [], [("repo visibility", {}), ("pr resolve-thread", {"thread": "PRRT_5a"}), ("issue view", {"number": 1})])):
        spec = "fake:" + ctx.state
        reset(ctx)
        edit_forge(ctx.state, capabilities=caps)
        rec = {}
        r = sh([sys.executable, "-I", os.path.join(SCHED, "forge.py"), "--repo", spec, "caps"], stdin=subprocess.DEVNULL)
        rec["caps_cli"] = {"rc": r.returncode, "stdout": r.stdout[:300], "stderr": r.stderr[:300]}
        try:
            import forge
            f = forge.open(spec)
            rec["caps_py"] = sorted(f.capabilities)
            rec["has_py"] = {c: bool(f.has(c)) for c in W.ALL_CAPS}
        except Exception as e:
            rec["caps_py"] = "<%s: %s>" % (type(e).__name__, e)
            rec["has_py"] = None
        rec["ops"] = {}
        for op, kw in ops:
            rec["ops"][op] = {"py": run_py(spec, op, kw), "cli": run_cli(spec, op, kw)}
        rec["state_after"] = {"pins": json.load(open(os.path.join(ctx.state, "pins.json"))) if os.path.exists(os.path.join(ctx.state, "pins.json")) else [],
                              "site": json.load(open(os.path.join(ctx.state, "site.json"))) if os.path.exists(os.path.join(ctx.state, "site.json")) else {},
                              "threads": json.load(open(os.path.join(ctx.state, "threads.json")))}
        out[tag] = rec
    return out


# ------------------------------------------------------------------ checking
AC = "G04-AC-2"


def summ(rec):
    if "ok" in rec:
        return "ok " + json.dumps(rec["ok"])[:200]
    if "exc" in rec:
        return "raised %s: %s" % (rec["exc"], rec.get("msg", ""))
    return "exit %s stdout=%r stderr=%r" % (rec.get("rc"), rec.get("stdout"), rec.get("stderr"))


def line(ok, name, details=()):
    print("%s: %s" % ("PASS" if ok else "FAIL", name))
    if not ok:
        for d in details:
            print("  " + d)
    return ok


def compare(c, key, shape, expect_fn, runs, meta, keys=None):
    """runs {(backend, mode): record}; returns problems for the part `key` ('op' or 'effect')."""
    probs, vals = [], {}
    for (b, m), rec in runs.items():
        r = rec.get(key)
        if not r or "ok" not in r:
            probs.append("%s %s: %s" % (b, m, summ(r) if r else "no result"))
            continue
        vals[(b, m)] = proj(shape, r["ok"], keys=keys)
    if expect_fn is not None:
        for (b, m), v in vals.items():
            exp = expect_fn(b, meta)
            e = proj(shape, exp, exp=True, keys=keys)
            if v != e:
                probs.append("%s %s: got %s, expected %s" % (b, m, json.dumps(v)[:400], json.dumps(e)[:400]))
    else:
        first = next(iter(vals.values()), None)
        for k, v in vals.items():
            if v != first:
                probs.append("%s differs: %s" % (k, json.dumps(v)[:300]))
    return probs


def check(ghfile, fakefile):
    data = {"github": json.load(open(ghfile)), "fake": json.load(open(fakefile))}
    metas = {b: data[b]["_meta"] for b in data}
    for c in cases():
        runs = {(b, m): data[b].get(c["id"], {}).get(m, {}) for b in data for m in ("py", "cli")}
        name = "%s: %s: same normalised result from the GitHub backend and the fake forge, by Python and by CLI" % (AC, c["id"])
        meta = dict(metas["fake"])
        probs = []
        for key, shape, exp in (("op", c["shape"], c.get("expect")),):
            probs += compare(c, "op", shape, exp, runs, meta, c.get("keys"))
        if c.get("effect"):
            probs += compare(c, "effect", c["effect"][2], c["effect_expect"], runs, meta)
        if c.get("observe"):
            for (b, m), rec in runs.items():
                exp = c["observe_expect"]
                if c["id"] == "branch push":
                    exp = {"refs/heads/feat/x": rec.get("head")}
                if rec.get("observe") != exp:
                    probs.append("%s %s: left %s, expected %s" % (b, m, json.dumps(rec.get("observe"))[:300], json.dumps(exp)[:300]))
        line(not probs, name, probs)
        if c.get("gh"):
            gprobs = []
            for m in ("py", "cli"):
                calls = runs.get(("github", m), {}).get("calls", [])
                for method, path, want in c["gh"]:
                    if not any(call.get("method") == method and call.get("path") == path and has(call.get("body"), want) for call in calls):
                        gprobs.append("%s: no gh call %s %s with %s; saw %s" % (m, method, path, json.dumps(want), [(x.get("method"), x.get("path")) for x in calls]))
            line(not gprobs, "%s: %s: the GitHub backend made the recorded gh call(s) of its effect" % (AC, c["id"]), gprobs)
    # failing calls
    for tag, lst, what in (("fail", FAIL_OPS, "a failing backend call"), ("missing", MISSING_OPS, "a missing issue or PR")):
        for op, _ in lst:
            probs = []
            for b in data:
                rec = data[b].get("%s: %s" % (tag, op))
                if not rec:
                    probs.append("%s: not run" % b)
                    continue
                p, k = rec["py"], rec["cli"]
                if p.get("exc") != "ForgeError":
                    probs.append("%s py: expected ForgeError, got %s" % (b, summ(p)))
                if k.get("rc") != 1 or k.get("stdout") or not k.get("stderr"):
                    probs.append("%s cli: expected exit 1, empty stdout, a stderr line; got %s" % (b, summ(k)))
            line(not probs, "%s: %s (%s) raises ForgeError / exits 1 with nothing on stdout, never an empty result" % (AC, op, what), probs)
    caps_check(data["fake"]["_caps"])
    g08_check(data)
    g08b_check(data)


def caps_check(caps):
    AC3 = "G04-AC-3"
    a = caps["no pin, no site"]
    probs = []
    if not (a["caps_cli"].get("rc") == 0 and parse(a["caps_cli"].get("stdout")) == ["resolve_threads", "visibility"]):
        probs.append("caps (CLI): %s" % summ(a["caps_cli"]))
    if a["caps_py"] != ["resolve_threads", "visibility"]:
        probs.append("f.capabilities: %s" % (a["caps_py"],))
    if a["has_py"] != {"pin": False, "resolve_threads": True, "site": False, "visibility": True}:
        probs.append("f.has(): %s" % (a["has_py"],))
    line(not probs, "%s: a fake forge configured without pin and site reports its capabilities (caps, capabilities, has)" % AC3, probs)

    def off(tag, op, cap):
        r = caps[tag]["ops"].get(op)
        probs = []
        if not r:
            return ["not run"]
        p, k = r["py"], r["cli"]
        if p.get("exc") != "CapabilityOff" or p.get("cap") != cap or ("forge fake lacks " + cap) not in p.get("msg", ""):
            probs.append("py: expected CapabilityOff(%s) 'forge fake lacks %s', got %s (cap=%s)" % (cap, cap, summ(p), p.get("cap")))
        if k.get("rc") != 3 or k.get("stdout") or ("forge fake lacks " + cap) not in k.get("stderr", ""):
            probs.append("cli: expected exit 3, empty stdout, stderr 'forge fake lacks %s'; got %s" % (cap, summ(k)))
        return probs
    for tag, op, cap in (("no pin, no site", "issue pin", "pin"), ("no pin, no site", "issue unpin", "pin"),
                         ("no pin, no site", "site publish", "site"), ("none", "repo visibility", "visibility"),
                         ("none", "pr resolve-thread", "resolve_threads")):
        line(not (pr := off(tag, op, cap)), "%s: `%s` with capability %s off raises CapabilityOff / exits 3 naming it" % (AC3, op, cap), pr)
    st = a["state_after"]
    refused = a["ops"]["issue pin"]["py"].get("exc") == "CapabilityOff" and a["ops"]["site publish"]["py"].get("exc") == "CapabilityOff"
    line(refused and st["pins"] == [] and st["site"] == {}, "%s: a refused operation changes nothing in the state" % AC3,
         ["state after: %s" % json.dumps(st)[:300]])
    probs = []
    for op in ("pr resolve-thread", "repo visibility"):
        r = a["ops"][op]
        for m in ("py", "cli"):
            if "ok" not in r[m]:
                probs.append("%s %s with its capability on: %s" % (op, m, summ(r[m])))
    line(not probs, "%s: operations whose capability stays on still work on that fake forge" % AC3, probs)
    n = caps["none"]
    probs = []
    if n["caps_py"] != [] or not (n["caps_cli"].get("rc") == 0 and parse(n["caps_cli"].get("stdout")) == []):
        probs.append("a fake forge with no capability: py %s cli %s" % (n["caps_py"], summ(n["caps_cli"])))
    r = n["ops"]["issue view"]
    for m in ("py", "cli"):
        if "ok" not in r[m]:
            probs.append("issue view (always available) %s: %s" % (m, summ(r[m])))
    line(not probs, "%s: with no capability caps is empty and the always-available operations still work" % AC3, probs)


def parse(text):
    try:
        return json.loads(text or "")
    except ValueError:
        return "<not JSON: %r>" % (text,)


def has(body, want, top=True):
    """want is None (any), a name that occurs in the body (top level string), a dict whose keys all match, or a value."""
    if want is None:
        return True
    if isinstance(want, str) and top:
        return want in json.dumps(body)
    if isinstance(want, dict):
        return isinstance(body, dict) and all(k in body and has(body[k], v, False) for k, v in want.items())
    return body == want


if __name__ == "__main__":
    if sys.argv[1] == "run":
        run_all(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        check(sys.argv[2], sys.argv[3])
