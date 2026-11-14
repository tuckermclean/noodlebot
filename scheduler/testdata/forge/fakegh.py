#!/usr/bin/env python3
"""A GitHub emulator for the conformance suite (G04): the `gh` command, answering the argv forms the GitHub backend uses
from the same fixture content as the fake forge. Its data is a state folder of world.py ($FAKE_GH_DIR); GitHub-shaped
answers are made from it, and writes change it, so a read after a write shows the effect.

Forms: `gh api [-X M] [-f k=v|-F k=v] [--input FILE|-] [--paginate] [-q|--jq EXPR] [-H h] PATH[?query]` for
  repos/R, repos/R/pulls[?state=], repos/R/pulls/N, .../pulls/N/{reviews,comments}, .../pulls/N/comments/ID/replies,
  repos/R/issues[?labels=&state=&sort=&direction=&per_page=], .../issues/N, .../issues/N/{comments[?per_page&page&since],
  events,labels}, .../issues/N/labels/NAME, .../issues/comments/ID/reactions, repos/R/labels[?per_page&page],
  repos/R/commits/SHA/check-runs, repos/R/actions/workflows/WF/runs (-f head_sha, event, branch), gists/ID (PATCH),
  graphql (pinIssue, unpinIssue, resolveReviewThread), and
  `gh pr list [--repo R] [--state S] [--limit N] --json F1,F2 [-q|--jq EXPR]`.
R must be the folder's owner/name, else 404. --paginate prints one JSON array per page of $FAKE_GH_PAGE items (2), like
gh; without it per_page is honoured (at most 100). jq subset: .a.b  .[]  .[].a.b  .[] | "text \(.a.b) \(.a // "x") \(.a != null)".
Every call is appended to $FAKE_GH_DIR/calls.jsonl as {"argv", "method", "path", "body", "gh_token"} (gh_token: the
GH_TOKEN of the call's environment, null when unset). The file $FAKE_GH_DIR/fail makes every call exit 1 with
"HTTP 502". A failed request prints gh's message on stderr (and the API's body on stdout) and exits 1.
"""
import json
import os
import re
import sys
from urllib.parse import parse_qs, unquote, urlparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import world as W

D = os.environ["FAKE_GH_DIR"]


class Fail(Exception):
    def __init__(self, status, message, body=None):
        self.status, self.message, self.body = status, message, body


def user(u):
    return {"login": u["login"], "type": "Bot" if u["is_bot"] else "User", "id": 1}


def assoc(u):
    return "OWNER" if u["is_owner"] else "NONE"


def base_url(w):
    return "https://github.com/%s/%s" % (w.forge["owner"], w.forge["name"])


def g_pr(w, p):
    return {"number": p["number"], "title": p["title"], "body": p["body"], "state": "open" if p["state"] == "open" else "closed",
            "merged": p["state"] == "merged", "merged_at": p["merged_at"], "closed_at": p["closed_at"],
            "created_at": p["created_at"], "html_url": "%s/pull/%d" % (base_url(w), p["number"]),
            "head": {"ref": p["head"], "sha": p["head_sha"]}, "base": {"ref": p["base"]}, "user": user(p["author"]),
            "author_association": assoc(p["author"]),
            "mergeable": {"MERGEABLE": True, "CONFLICTING": False}.get(p["mergeable"]),
            "mergeable_state": "unknown", "node_id": "PR_node_%d" % p["number"]}


def g_prlist(w, p):
    return {"number": p["number"], "title": p["title"], "body": p["body"], "state": p["state"].upper(),
            "headRefName": p["head"], "headRefOid": p["head_sha"], "baseRefName": p["base"],
            "author": {"login": p["author"]["login"], "is_bot": p["author"]["is_bot"], "id": "U_1", "name": ""},
            "authorAssociation": assoc(p["author"]), "mergeable": p["mergeable"], "createdAt": p["created_at"],
            "mergedAt": p["merged_at"], "closedAt": p["closed_at"], "url": "%s/pull/%d" % (base_url(w), p["number"]),
            "isDraft": False}


def g_issue(w, i):
    return {"number": i["number"], "title": i["title"], "body": i["body"], "state": i["state"],
            "labels": [{"name": n, "color": "ededed"} for n in i["labels"]], "user": user(i["author"]),
            "author_association": assoc(i["author"]), "created_at": i["created_at"], "node_id": "I_node_%d" % i["number"],
            "html_url": "%s/issues/%d" % (base_url(w), i["number"])}


def g_comment(w, c, n):
    return {"id": c["id"], "body": c["body"], "user": user(c["author"]), "author_association": assoc(c["author"]),
            "created_at": c["created_at"], "html_url": "%s/issues/%s#issuecomment-%d" % (base_url(w), n, c["id"])}


def g_review(w, c, n):
    return {"id": c["id"], "state": c["state"], "body": c["body"], "user": user(c["author"]),
            "author_association": assoc(c["author"]), "submitted_at": c["submitted_at"],
            "html_url": "%s/pull/%s#pullrequestreview-%d" % (base_url(w), n, c["id"])}


def g_lc(w, c, n):
    return {"id": c["id"], "body": c["body"], "user": user(c["author"]), "author_association": assoc(c["author"]),
            "path": c["path"], "line": None if c.get("outdated") else c["line"], "original_line": c["line"],
            "in_reply_to_id": c["in_reply_to"], "created_at": c["created_at"],
            "html_url": "%s/pull/%s#discussion_r%d" % (base_url(w), n, c["id"])}


def g_event(e):
    return {"event": e["event"], "label": {"name": e["label"], "color": "ededed"} if e["label"] else None,
            "actor": {"login": e["actor"]} if e["actor"] else None, "created_at": e["created_at"]}


# --- jq subset ---
def get(v, path):
    for k in path.split(".")[1:]:
        if k == "":
            continue
        v = v.get(k) if isinstance(v, dict) else None
    return v


def show(v):
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (dict, list)):
        return json.dumps(v)
    return str(v)


def interp(e, r):
    m = re.fullmatch(r'\s*(\.[\w.]*)\s*(?:(!=|==)\s*(null|"[^"]*")|//\s*"([^"]*)")?\s*', e)
    if not m:
        sys.exit("fake gh: unsupported jq expression: " + e)
    v = get(r, m[1])
    if m[2]:
        return show((v == (None if m[3] == "null" else m[3].strip('"'))) == (m[2] == "=="))
    if m[4] is not None and v is None:
        return m[4]
    return show(v)


def jq(expr, data):
    e = expr.strip()
    if re.fullmatch(r'\.[\w.]*', e):
        return [show(get(data, e))]
    m = re.fullmatch(r'\.\[\]\s*(\.[\w.]*)?', e)
    if m:
        return [show(get(r, m[1] or ".")) for r in data]
    m = re.fullmatch(r'\.\[\]\s*\|\s*"(.*)"', e)
    if m:
        return [re.sub(r'\\\(((?:[^()]|\([^()]*\))*)\)', lambda x: interp(x[1], r), m[1]) for r in data]
    sys.exit("fake gh: unsupported jq expression: " + expr)


def out(data, q):
    if q is not None:
        for line in jq(q, data):
            print(line)
    else:
        print(json.dumps(data))


def paginate(data):
    n = int(os.environ.get("FAKE_GH_PAGE", "2"))
    if not isinstance(data, list):
        return [data]
    return [data[i:i + n] for i in range(0, max(len(data), 1), n)]


def main():
    argv = sys.argv[1:]
    rec = {"argv": argv, "method": None, "path": None, "body": None, "gh_token": os.environ.get("GH_TOKEN")}
    try:
        run(argv, rec)
    except Fail as e:
        log(rec)
        if e.body is not None:
            print(json.dumps(e.body))
        print("gh: %s (HTTP %d)" % (e.message, e.status), file=sys.stderr)
        sys.exit(1)


def log(rec):
    with open(os.path.join(D, "calls.jsonl"), "a") as f:
        f.write(json.dumps(rec) + "\n")


def run(argv, rec):
    if os.path.exists(os.path.join(D, "fail")):
        log(rec)
        print("gh: fake gh: server error (HTTP 502)", file=sys.stderr)
        sys.exit(1)
    w = W.World(D)
    if argv[:2] == ["pr", "list"]:
        return pr_list(w, argv[2:], rec)
    if not argv or argv[0] != "api":
        log(rec)
        sys.exit("fake gh: unsupported command: %s" % argv[:2])
    method, fields, inp, pag, q, path = None, {}, None, False, None, None
    i = 1
    while i < len(argv):
        a = argv[i]
        if a in ("-X", "--method"):
            method = argv[i + 1]; i += 1
        elif a in ("-f", "-F", "--field", "--raw-field"):
            k, _, v = argv[i + 1].partition("="); fields[k] = v; i += 1
        elif a == "--input":
            inp = argv[i + 1]; i += 1
        elif a == "--paginate":
            pag = True
        elif a in ("-q", "--jq"):
            q = argv[i + 1]; i += 1
        elif a in ("-H", "--header", "--cache"):
            i += 1
        elif not a.startswith("-"):
            path = a
        i += 1
    body = None
    if inp is not None:
        body = json.load(sys.stdin) if inp == "-" else json.load(open(inp))
    if method is None:
        method = "POST" if (body is not None or (fields and False)) else "GET"
    u = urlparse(path)
    qs = {k: v[0] for k, v in parse_qs(u.query).items()}
    if method == "GET":
        qs.update(fields)
    elif body is None and fields:
        body = fields
    rec.update(method=method, path=u.path, body=body)
    log(rec)
    res = route(w, method, u.path.strip("/"), qs, body)
    if res is None:
        raise Fail(404, "Not Found", {"message": "Not Found"})
    if isinstance(res, tuple):  # (data, per_page, page): a list that pages
        data, per, page = res
        if pag:
            for pg in paginate(data):
                print(json.dumps(pg))
            return
        data = data[(page - 1) * per: page * per]
        return out(data, q)
    out(res, q)


def page_of(qs, data):
    return (data, min(int(qs.get("per_page", "30")), 100), int(qs.get("page", "1")))


def route(w, method, path, qs, body):
    own = "repos/%s/%s" % (w.forge["owner"], w.forge["name"])
    if path == "graphql":
        return graphql(w, body)
    m = re.fullmatch(r"gists/([\w-]+)", path)
    if m and method == "PATCH":
        w.site_publish(m[1], (body or {}).get("files", {}))
        return {"id": m[1]}
    if path != own and not path.startswith(own + "/"):
        return None
    rest = path[len(own):].strip("/")
    n = lambda s: int(s)
    try:
        if rest == "" and method == "GET":
            return {"full_name": "%s/%s" % (w.forge["owner"], w.forge["name"]), "private": bool(w.forge.get("private")),
                    "default_branch": w.forge["default_branch"], "name": w.forge["name"]}
        if rest == "pulls" and method == "GET":
            st = qs.get("state", "open")
            if st not in ("open", "closed", "all"):
                raise Fail(422, "Validation Failed")
            return page_of(qs, [g_pr(w, p) for p in w.pr_list(st)])
        if rest == "pulls" and method == "POST":
            return g_pr(w, w.pr_create(body["head"], body["base"], body["title"], body.get("body", "")))
        m = re.fullmatch(r"pulls/(\d+)", rest)
        if m and method == "GET":
            return g_pr(w, w.find_pr(m[1]))
        if m and method == "PATCH":
            return g_pr(w, w.pr_edit(m[1], body.get("title"), body.get("body")))
        m = re.fullmatch(r"pulls/(\d+)/reviews", rest)
        if m and method == "GET":
            w.find_pr(m[1])
            return page_of(qs, [g_review(w, c, m[1]) for c in w.reviews.get(m[1], [])])
        m = re.fullmatch(r"pulls/(\d+)/comments", rest)
        if m and method == "GET":
            w.find_pr(m[1])
            return page_of(qs, [g_lc(w, c, m[1]) for c in w.line_comments.get(m[1], [])])
        m = re.fullmatch(r"pulls/(\d+)/comments/(\d+)/replies", rest)
        if m and method == "POST":
            w.find_pr(m[1])
            return g_lc(w, w.reply(m[1], m[2], body["body"]), m[1])
        if rest == "issues" and method == "GET":
            lab = qs.get("labels", "")
            st = qs.get("state", "open")
            asc = qs.get("direction") == "asc"
            lst = [i for i in w.issues if (not lab or lab in i["labels"]) and st in ("all", i["state"])]
            lst.sort(key=lambda i: i["number"], reverse=not asc)
            return page_of(qs, [g_issue(w, i) for i in lst])
        if rest == "issues" and method == "POST":
            for lab in body.get("labels", []):
                if not any(l["name"] == lab for l in w.labels):
                    raise Fail(422, "Validation Failed")
            return g_issue(w, w.issue_create(body["title"], body.get("body", ""), body.get("labels")))
        m = re.fullmatch(r"issues/(\d+)", rest)
        if m and method == "GET":
            try:
                return g_issue(w, w.find_issue(m[1]))
            except W.WorldError:  # a PR is an issue too
                p = w.find_pr(m[1])
                return {"number": p["number"], "title": p["title"], "body": p["body"], "state": "open" if p["state"] == "open" else "closed",
                        "labels": [], "user": user(p["author"]), "author_association": assoc(p["author"]),
                        "created_at": p["created_at"], "pull_request": {}, "html_url": "%s/pull/%d" % (base_url(w), p["number"]),
                        "node_id": "PR_node_%d" % p["number"]}
        if m and method == "PATCH":
            return g_issue(w, w.issue_edit(m[1], body.get("title"), body.get("body"), body.get("state")))
        m = re.fullmatch(r"issues/(\d+)/comments", rest)
        if m and method == "GET":
            if not any(x["number"] == int(m[1]) for x in w.issues + w.prs):
                return None
            return page_of(qs, [g_comment(w, c, m[1]) for c in w.comments_of(m[1], qs.get("since"))])
        if m and method == "POST":
            if not any(x["number"] == int(m[1]) for x in w.issues + w.prs):
                return None
            return g_comment(w, w.comment_add(m[1], body["body"]), m[1])
        m = re.fullmatch(r"issues/(\d+)/events", rest)
        if m and method == "GET":
            w.find_issue(m[1])
            return page_of(qs, [g_event(e) for e in w.events.get(m[1], [])])
        m = re.fullmatch(r"issues/(\d+)/labels", rest)
        if m and method == "POST":
            for lab in body["labels"]:
                w.label_add(m[1], lab)
            return [{"name": l} for l in w.find_issue(m[1])["labels"]]
        m = re.fullmatch(r"issues/(\d+)/labels/(.+)", rest)
        if m and method == "DELETE":
            w.label_remove(m[1], unquote(m[2]))
            return [{"name": l} for l in w.find_issue(m[1])["labels"]]
        m = re.fullmatch(r"issues/comments/(\d+)/reactions", rest)
        if m and method == "POST":
            w.react(m[1], body["content"])
            return {"id": 1, "content": body["content"]}
        if rest == "labels" and method == "GET":
            return page_of(qs, list(w.labels))
        if rest == "labels" and method == "POST":
            if not w.label_ensure(body["name"], body.get("color", "ededed"), body.get("description", "")):
                raise Fail(422, "Validation Failed", {"message": "Validation Failed", "errors": [
                    {"resource": "Label", "code": "already_exists", "field": "name"}]})
            return {"name": body["name"], "color": body.get("color", "ededed"), "description": body.get("description", "")}
        m = re.fullmatch(r"commits/([\w]+)/check-runs", rest)
        if m and method == "GET":
            runs = w.checks.get(m[1], [])
            return {"total_count": len(runs), "check_runs": [dict(r, id=k + 1) for k, r in enumerate(runs)]}
        m = re.fullmatch(r"actions/workflows/([\w.-]+)/runs", rest)
        if m and method == "GET":
            runs = [{"id": r["id"], "status": r["status"], "conclusion": r["conclusion"], "head_sha": r["head_sha"],
                     "created_at": r["created_at"], "head_branch": r["branch"], "event": r["event"]}
                    for r in w.ci(m[1], qs.get("head_sha"), qs.get("branch"), qs.get("event"))]
            return {"total_count": len(runs), "workflow_runs": runs}
    except W.WorldError as e:
        raise Fail(404, "Not Found", {"message": str(e)})
    except (KeyError, TypeError) as e:
        raise Fail(422, "Validation Failed: %s" % e)
    return None


def graphql(w, body):
    text = json.dumps(body)
    m = re.search(r"mutation[^{]*\{\s*(\w+)", (body or {}).get("query", ""))
    name = m[1] if m else ""
    try:
        if name in ("pinIssue", "unpinIssue"):
            n = re.search(r"I_node_(\d+)", text)
            if not n:
                raise Fail(422, "no issue id")
            w.pin(n[1], name == "pinIssue")
        elif name == "resolveReviewThread":
            t = re.search(r"PRRT_\w+", text)
            if not t:
                raise Fail(422, "no thread id")
            w.resolve_thread(t[0])
        else:
            raise Fail(422, "unsupported graphql: %s" % name)
    except W.WorldError as e:
        raise Fail(404, "Not Found", {"message": str(e)})
    return {"data": {name: {"clientMutationId": None}}}


def pr_list(w, args, rec):
    state, limit, fields, q = "open", 30, None, None
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("--state", "-s"):
            state = args[i + 1]; i += 1
        elif a in ("--limit", "-L"):
            limit = int(args[i + 1]); i += 1
        elif a == "--json":
            fields = args[i + 1].split(","); i += 1
        elif a in ("-q", "--jq"):
            q = args[i + 1]; i += 1
        elif a in ("--repo", "-R", "--base", "--head", "--label", "--author", "--search"):
            i += 1
        i += 1
    rec.update(method="pr list", path=state)
    log(rec)
    try:
        prs = w.pr_list(state, limit)
    except W.WorldError as e:
        sys.exit("gh: %s" % e)
    rows = [g_prlist(w, p) for p in prs]
    if fields is None:
        sys.exit("gh: fake gh: pr list needs --json")
    for r in rows:
        for f in fields:
            if f not in r:
                sys.exit("Unknown JSON field: %r" % f)
    rows = [{f: r[f] for f in fields} for r in rows]
    out(rows, q)


main()
