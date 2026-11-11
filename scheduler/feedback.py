#!/usr/bin/env python3
"""Find the owner's new feedback on the bot's open PRs, for the loop to hand to a session (G03).

  feedback.py --repo OWNER/NAME --state DIR --owner LOGIN --prs FILE        print the PRs with new feedback
  feedback.py --repo OWNER/NAME --state DIR --owner LOGIN --prs FILE mark N  advance PR N's record

FILE is the loop's open-prs.tsv ("<number> <branch> <headOid> <is_bot> <mergeable>"); DIR is state/<name>; all
GitHub access is `gh api --paginate` (every page), so GH_TOKEN must be set.
For each open bot PR on node/<ID>-... or spec/* it reads the conversation comments, the line comments and the
reviews. Feedback is an item by the owner (login, association OWNER, not a bot): a conversation comment, a line
comment, a CHANGES_REQUESTED review, a COMMENTED review with a body; not an approval, an empty review, a comment
that is only a thumbs-up (👍, :+1:, +1), anyone else's item or an owner comment recorded as an answer (its URL in
ANSWER.md or answered/*-ANSWER.md of the PR's unit: node/<ID>/ or pr/<N>/).
The record DIR/feedback/N holds the newest conversation, line and review ID handed to a session. A PR with
feedback newer than it prints "<N> <branch>" on stdout and gets DIR/feedback/N.md (the FEEDBACK.md: PR, branch and
per item kind, id, url, author, time, body, and for a line comment file, line, thread); `mark N` advances the record
to the items of that file. The first run (no feedback/ folder) records every open bot PR's newest IDs and prints
nothing; a PR seen later starts from an empty record. The record and file of a PR no longer open are removed.
A failing gh call is logged to stderr, prints nothing for that PR, leaves its record alone and makes the exit code 1.
"""
import argparse
import concurrent.futures
import glob
import json
import os
import re
import shutil
import subprocess
import sys

KINDS = ("conversation", "line", "review")
THUMBS = {"\U0001F44D", ":+1:", "+1"}


def log(msg):
    print("feedback.py: " + msg, file=sys.stderr)


def write_atomic(path, text):
    tmp = path + ".tmp%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def gh_list(path):
    """Every item of a paginated list: gh prints one JSON array per page."""
    p = subprocess.run(["gh", "api", "--paginate", path], capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError("gh api %s failed (rc %d): %s" % (path, p.returncode, p.stderr.strip()))
    dec, text, i, items = json.JSONDecoder(), p.stdout, 0, []
    while True:
        while i < len(text) and text[i].isspace():
            i += 1
        if i >= len(text):
            return items
        val, i = dec.raw_decode(text, i)
        items.extend(val if isinstance(val, list) else [val])


def read_record(state, n):
    rec = {k: 0 for k in KINDS}
    try:
        with open(os.path.join(state, "feedback", str(n)), encoding="utf-8") as f:
            for line in f:
                k, _, v = line.partition(" ")
                if k in rec and v.strip().isdigit():
                    rec[k] = int(v)
    except OSError:
        pass
    return rec


def record_text(rec):
    return "".join("%s %d\n" % (k, rec[k]) for k in KINDS)


def write_record(state, n, rec):
    write_atomic(os.path.join(state, "feedback", str(n)), record_text(rec))


def unit_dir(state, n, branch):
    if branch.startswith("spec/"):
        return os.path.join(state, "pr", str(n))
    m = re.match(r"node/([A-Z][0-9][0-9])-", branch)
    return os.path.join(state, "node", m.group(1)) if m else None


def answer_urls(udir):
    """The URLs of the comments recorded as answers in the unit's ANSWER.md files: only the line report.py writes
    ("The owner's answer, posted by <login> on GitHub at <time>: <URL>", or "answer: <URL>"), never a URL in the
    answer's own text."""
    return {m.group(1) for m in re.finditer(
        r"^(?:The owner's answer, posted by .* at [^\n]*?|answer): (https?://\S+)[ \t]*$", answer_text(udir), re.M)}


def answer_text(udir):
    text = ""
    for p in [os.path.join(udir, "ANSWER.md")] + glob.glob(os.path.join(udir, "answered", "*-ANSWER.md")):
        try:
            with open(p, encoding="utf-8", errors="replace") as f:
                text += f.read() + "\n"
        except OSError:
            pass
    return text


def is_owner(item, owner):
    u = item.get("user") or {}
    return u.get("login") == owner and item.get("author_association") == "OWNER" and u.get("type") != "Bot"


def only_thumbs(body):
    return (body or "").strip().replace("️", "") in THUMBS


def fetch_pr(pool, repo, n):
    """Start the three reads of PR n on the pool: the futures of its conversation comments, line comments, reviews."""
    return [pool.submit(gh_list, "repos/%s/%s/%d/%s" % (repo, base, n, what))
            for base, what in (("issues", "comments"), ("pulls", "comments"), ("pulls", "reviews"))]


def read_pr(futures):
    """(items, newest ids) from the futures of fetch_pr (a failed read raises here): items are all candidate
    feedback dicts, newest the max id of each kind."""
    conv, line, rev = [f.result() for f in futures]
    newest = {
        "conversation": max([c["id"] for c in conv] or [0]),
        "line": max([c["id"] for c in line] or [0]),
        "review": max([c["id"] for c in rev] or [0]),
    }
    byid = {c["id"]: c for c in line}
    items = []
    for c in conv:
        items.append({"kind": "conversation", "raw": c, "time": c.get("created_at", "")})
    for c in line:
        root, seen = c, set()
        while root.get("in_reply_to_id") in byid and root["id"] not in seen:
            seen.add(root["id"])
            root = byid[root["in_reply_to_id"]]
        items.append({"kind": "line", "raw": c, "time": c.get("created_at", ""), "file": c.get("path", ""),
                      "line": c.get("line") or c.get("original_line") or "", "thread": root["id"]})
    for r in rev:
        if r.get("state") == "CHANGES_REQUESTED" or (r.get("state") == "COMMENTED" and (r.get("body") or "").strip()):
            items.append({"kind": "review", "raw": r, "time": r.get("submitted_at", "")})
    return items, newest


def new_items(items, rec, owner, answers):
    out = []
    for it in items:
        c = it["raw"]
        if c["id"] <= rec[it["kind"]] or not is_owner(c, owner) or only_thumbs(c.get("body")):
            continue
        if it["kind"] != "review" and c.get("html_url") and c["html_url"] in answers:
            continue
        out.append(it)
    return out


def feedback_md(n, branch, items):
    out = ["# Feedback", "", "PR: %d" % n, "Branch: %s" % branch, ""]
    for it in items:
        c = it["raw"]
        out += ["kind: " + it["kind"], "id: %d" % c["id"], "url: " + c.get("html_url", ""),
                "author: " + (c.get("user") or {}).get("login", ""), "time: " + it["time"]]
        if it["kind"] == "line":
            out += ["file: %s" % it["file"], "line: %s" % it["line"], "thread: %d" % it["thread"]]
        # continuation lines are indented, so no line of a body looks like an item's field
        out += ["body: " + "\n  ".join((c.get("body") or "").strip().splitlines()), ""]
    return "\n".join(out)


def mark(state, n):
    """Advance the record to DIR/feedback/N.next, the IDs written together with N.md (not parsed from its bodies)."""
    rec = read_record(state, n)
    try:
        with open(os.path.join(state, "feedback", "%d.next" % n), encoding="utf-8") as f:
            for line in f:
                k, _, v = line.partition(" ")
                if k in rec and v.strip().isdigit():
                    rec[k] = max(rec[k], int(v))
    except OSError:
        return
    write_record(state, n, rec)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--state", required=True)
    ap.add_argument("--owner", required=True)
    ap.add_argument("--prs", required=True)
    ap.add_argument("cmd", nargs="*")
    a = ap.parse_args()
    fdir = os.path.join(a.state, "feedback")
    if a.cmd:
        if len(a.cmd) != 2 or a.cmd[0] != "mark" or not a.cmd[1].isdigit():
            ap.error("usage: [mark N]")
        mark(a.state, int(a.cmd[1]))
        return 0
    prs = []
    try:
        with open(a.prs, encoding="utf-8") as f:
            for line in f:
                p = line.split()
                if len(p) >= 4 and p[0].isdigit():
                    prs.append((int(p[0]), p[1], p[3] == "true"))
    except OSError as e:
        log("cannot read %s: %s" % (a.prs, e))
        return 1
    first = not os.path.isdir(fdir)
    open_nums = {str(n) for n, _, _ in prs}
    if first:
        # built aside and renamed only when every read succeeded, so a failed first run is still a first run
        fdir = os.path.join(a.state, "feedback.new")
        shutil.rmtree(fdir, ignore_errors=True)
        os.makedirs(fdir)
    else:
        for name in os.listdir(fdir):
            if name.split(".")[0] not in open_nums:
                try:
                    os.remove(os.path.join(fdir, name))
                except OSError:
                    pass
    rc = 0
    todo = []
    for n, branch, is_bot in prs:
        udir = unit_dir(a.state, n, branch) if is_bot else None
        if udir is not None:
            todo.append((n, branch, udir))
    # the reads of all PRs run at once (a small pool); the results are used in file order
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=8) if todo else None
    fetched = {n: fetch_pr(pool, a.repo, n) for n, _, _ in todo}
    for n, branch, udir in todo:
        try:
            items, newest = read_pr(fetched[n])
            if first:
                write_atomic(os.path.join(fdir, str(n)), record_text(newest))
                continue
            found = new_items(items, read_record(a.state, n), a.owner, answer_urls(udir))
            if found:
                nxt = read_record(a.state, n)
                for it in found:
                    nxt[it["kind"]] = max(nxt[it["kind"]], it["raw"]["id"])
                # N.next first, then N.md: the pair is only complete once N.md is there
                write_atomic(os.path.join(fdir, "%d.next" % n), record_text(nxt))
                write_atomic(os.path.join(fdir, "%d.md" % n), feedback_md(n, branch, found))
                print("%d %s" % (n, branch))
            else:
                for ext in (".md", ".next"):
                    try:
                        os.remove(os.path.join(fdir, "%d%s" % (n, ext)))
                    except OSError:
                        pass
        except Exception as e:   # one malformed item only skips that PR
            log("PR %d: %s" % (n, e))
            rc = 1
    if pool:
        pool.shutdown()
    if first:
        if rc:
            shutil.rmtree(fdir, ignore_errors=True)
        else:
            os.rename(fdir, os.path.join(a.state, "feedback"))
    sys.stdout.flush()
    return rc


if __name__ == "__main__":
    sys.exit(main())
