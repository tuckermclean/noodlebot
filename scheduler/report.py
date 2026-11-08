#!/usr/bin/env python3
"""Mirror one repository's scheduler state to a GitHub status issue, and take the owner's answers from it.

  report.py --repo OWNER/NAME --state DIR [--worktrees DIR] [--owner LOGIN]

Run by loop.sh after each tick with GH_TOKEN set; exits 3 when it wrote an ANSWER.md; stdlib only, all GitHub access through `gh api`.
Each run:
  1. finds the open issue labelled `noodlebot-status` (creating the label and issue if there is none,
     e.g. after the owner closed it), and remembers its number in DIR/report.json;
  2. turns each new comment by the owner on that issue into ANSWER.md for the node waiting on a
     question (the only one waiting, or the one named first: "B03: ..."), and replies;
  3. posts new status.log events (starts, ends, releases, merges, FAILED) as one comment;
  4. posts each new unanswered QUESTION.md in full, once;
  5. rewrites the issue body: what waits on the owner, every running session and its latest narration,
     recent events. Body edits do not notify; comments do.
On the first run it does not replay old comments or events. Any failure exits non-zero; the loop
logs it and carries on, and the next run picks up where this one stopped.
"""
import argparse, hashlib, json, os, re, subprocess, sys, time
from datetime import datetime, timezone

LABEL = "noodlebot-status"
EVENT = re.compile(r"started |ended |done |released |merged |wrote FAILED|found ~/STOP")
NODE = re.compile(r"^[A-Z][0-9][0-9]$")
MAX_COMMENT = 60000


def gh(method, path, body=None):
    cmd = ["gh", "api", "-X", method, path]
    if body is not None:
        cmd += ["--input", "-"]
    r = subprocess.run(cmd, input=json.dumps(body) if body is not None else None,
                       capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        raise RuntimeError("gh api %s %s failed: %s" % (method, path, (r.stderr or r.stdout).strip()[:300]))
    return json.loads(r.stdout) if r.stdout.strip() else None


def local(ts=None):
    return datetime.fromtimestamp(ts if ts is not None else time.time()).astimezone().strftime("%Y-%m-%d %H:%M %Z")


def tail_lines(path, nbytes):
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - nbytes))
            data = f.read().decode("utf-8", "replace")
    except OSError:
        return []
    lines = data.splitlines()
    return lines[1:] if size > nbytes else lines


def event_text(line):
    """'2026-11-08T19:04:42Z open=[..] merged-prs=[..]; session B03 ended' -> ('19:04Z', 'session B03 ended')."""
    stamp, _, rest = line.partition(" ")
    what = rest.split("; ", 1)[1] if "; " in rest else rest
    return stamp, what


def nodes(state):
    """The tasks with a state directory: nodes ("B03", node/B03) and triaged issues ("#46", issue/46)."""
    out = []
    for kind, pat, fmt in (("node", NODE, "%s"), ("issue", re.compile(r"^\d+$"), "#%s")):
        d = os.path.join(state, kind)
        if os.path.isdir(d):
            out += [fmt % n for n in sorted(os.listdir(d)) if pat.match(n) and os.path.isdir(os.path.join(d, n))]
    return out


def tdir(state, task):
    return os.path.join(state, "issue", task[1:]) if task.startswith("#") else os.path.join(state, "node", task)


def has(state, task, name):
    return os.path.exists(os.path.join(tdir(state, task), name))


def waiting(state):
    """Tasks whose QUESTION.md has no ANSWER.md yet."""
    return [n for n in nodes(state) if has(state, n, "QUESTION.md") and not has(state, n, "ANSWER.md")]


def sessions(state):
    """[(task, pid, started)] of the live sessions."""
    out = []
    for n in nodes(state):
        f = os.path.join(tdir(state, n), "session.pid")
        try:
            pid = open(f).read().strip()
            cmd = open("/proc/%s/cmdline" % pid, "rb").read().replace(b"\0", b" ").decode()
        except OSError:
            continue
        k = n.lstrip("#")
        if re.search(r"run-session\.sh .* %s( |$)|claude -p /node %s( |$)" % (k, k), cmd):
            out.append((n, pid, os.path.getmtime(f)))
    return out


def narration(log):
    """The orchestrator's latest plain-text lines, and the subagent it is waiting on (if any)."""
    texts, agents, done = [], {}, set()
    for line in tail_lines(log, 1 << 20):
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if not isinstance(d, dict) or d.get("parent_tool_use_id"):
            continue
        msg = d.get("message")
        content = msg.get("content") if isinstance(msg, dict) else None
        if not isinstance(content, list):
            continue
        for c in content:
            if not isinstance(c, dict):
                continue
            if d.get("type") == "assistant" and c.get("type") == "text" and c.get("text", "").strip():
                texts.append(" ".join(c["text"].split())[:400])
            elif d.get("type") == "assistant" and c.get("type") == "tool_use" and c.get("name") in ("Agent", "Task"):
                agents[c.get("id")] = (c.get("input") or {}).get("description") or "a subagent"
            elif d.get("type") == "user" and c.get("type") == "tool_result":
                done.add(c.get("tool_use_id"))
        if d.get("type") == "result":
            texts.append("(session turn ended: %s)" % d.get("subtype"))
    running = [desc for i, desc in agents.items() if i not in done]
    return texts[-8:], (running[-1] if running else None)


def last_result(log):
    """The text of the session's last result (its closing message), or None."""
    for line in reversed(tail_lines(log, 1 << 20)):
        if '"type":"result"' in line.replace(" ", ""):
            try:
                r = json.loads(line).get("result")
            except (ValueError, AttributeError):
                return None
            return r.strip() or None if isinstance(r, str) else None
    return None


def num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def cost_turns(log):
    """(latest total_cost_usd, turns summed over results) of the well-formed result events in the whole log, or None.

    Streams the file line by line (constant memory) and parses only lines that mention a result."""
    cost, turns, found = 0.0, 0, False
    try:
        with open(log, "rb") as f:
            for raw in f:
                if b'"result"' not in raw:
                    continue
                try:
                    d = json.loads(raw.decode("utf-8", "replace"))
                except ValueError:
                    continue
                if (isinstance(d, dict) and d.get("type") == "result" and num(d.get("total_cost_usd"))
                        and num(d.get("num_turns"))):
                    cost, turns, found = d["total_cost_usd"], turns + d["num_turns"], True
    except OSError:
        return None
    return (cost, turns) if found else None


def cost_text(log):
    ct = cost_turns(log)
    return "no cost yet" if ct is None else "$%.2f, %d turns" % ct


def git_lines(wt, *args):
    try:
        r = subprocess.run(["git", "-C", wt] + list(args), capture_output=True, text=True, timeout=30)
        return r.stdout.splitlines() if r.returncode == 0 else []
    except (OSError, subprocess.TimeoutExpired):
        return []


def body_for(a, sts, prs):
    state = a.state
    out = ["# noodlebot status: %s" % a.repo, "",
           "_Updated %s by the scheduler loop (within a minute of a change; when nothing changes, every 15 minutes). If this is more than ~20 minutes old, "
           "the loop is not running._" % local(), "", "## Waiting on you"]
    items = []
    for n in nodes(state):
        if has(state, n, "FAILED"):
            items.append("- **%s FAILED** (2 starts with no PR and no question). To retry, delete `%s`." %
                         (n, os.path.join(tdir(state, n), "FAILED")))
        elif has(state, n, "QUESTION.md") and has(state, n, "ANSWER.md"):
            items.append("- %s: answered; resumes within seconds." % n)
        elif has(state, n, "QUESTION.md"):
            items.append("- **%s asks a question** (posted below as a comment). Reply to this issue to answer." % n)
        elif has(state, n, "WAITING-PR"):
            pr = open(os.path.join(tdir(state, n), "WAITING-PR")).read().strip()
            items.append("- **%s** waits for you to merge spec PR #%s; it resumes within a minute after." % (n, pr))
    for n, pr in sorted(prs.items()):
        if not has(state, n, "QUESTION.md") and not has(state, n, "WAITING-PR") and n not in [t[0] for t in sts]:
            items.append("- %s's PR #%s: open, no session running on it (review or merge it)." % (n, pr))
    out += items or ["- nothing"]

    out += ["", "## Sessions (%d running)" % len(sts),
            "", "_Costs are the CLI's list-price estimate, not the bill._"]
    many = len(sts) > 1
    for n, pid, started in sts:
        label = "triage of %s" % n if n.startswith("#") else n
        mins = int((time.time() - started) // 60)
        starts = (open(os.path.join(tdir(state, n), "starts")).read().strip()
                  if has(state, n, "starts") else "?")
        line = "### %s, running for %dh%02dm (start %s of 2, pid %s)" % (label, mins // 60, mins % 60, starts, pid)
        if n in prs:
            line += ", PR #%s" % prs[n]
        line += ", " + cost_text(os.path.join(tdir(state, n), "session.jsonl"))
        out += ["", line]
        texts, agent = narration(os.path.join(tdir(state, n), "session.jsonl"))
        if agent:
            out += ["", "Now running subagent: **%s**" % agent]
        out += [""] + (["> %s" % t for t in texts[-4 if many else -8:]] or ["> (nothing yet)"])
        commits = [] if n.startswith("#") else git_lines(os.path.join(a.worktrees, n), "log", "--oneline",
                                                         "-3" if many else "-8", "origin/main..HEAD")
        if commits:
            out += ["", "Latest commits:", ""] + ["- `%s`" % c for c in commits]
    if not sts:
        out.append("No session running.")

    events = [l for l in tail_lines(os.path.join(state, "status.log"), 64 << 10) if EVENT.search(event_text(l)[1])]
    out += ["", "## Recent events", ""]
    out += ["- `%s` %s" % event_text(l) for l in events[-10:]] or ["- none yet"]
    out += ["", "---", "Answer a question by replying to this issue in plain words (e.g. \"Q1 approve, Q2 as "
            "recommended\"). Only %s's replies count; if more than one is waiting, start with its ID or "
            "issue number, e.g. `B03: ...` or `#46: ...`. Hand an issue to the bot by adding the `noodlebot` label "
            "(only labels you add count). Closing this issue is fine: the loop opens a new one." % a.owner]
    return "\n".join(out) + "\n"


def find_issue(a, rs):
    n = rs.get("issue")
    if n:
        try:
            if gh("GET", "repos/%s/issues/%s" % (a.repo, n)).get("state") == "open":
                return n, False
        except RuntimeError:
            pass
    found = gh("GET", "repos/%s/issues?labels=%s&state=open&per_page=10" % (a.repo, LABEL)) or []
    found = [i for i in found if "pull_request" not in i]
    if found:
        return found[0]["number"], True
    try:
        gh("POST", "repos/%s/labels" % a.repo, {"name": LABEL, "color": "5319e7",
                                              "description": "Kept up to date by the noodlebot scheduler"})
    except RuntimeError as e:
        if "already_exists" not in str(e) and "422" not in str(e):
            raise
    issue = gh("POST", "repos/%s/issues" % a.repo, {"title": "noodlebot status", "labels": [LABEL],
                                                  "body": "Starting up..."})
    try:
        gh("POST", "graphql", {"query": "mutation($id:ID!){pinIssue(input:{issueId:$id}){issue{number}}}",
                               "variables": {"id": issue["node_id"]}})
    except RuntimeError:
        pass  # pinning is a nicety
    return issue["number"], True


def comment(a, issue, text):
    if len(text) > MAX_COMMENT:
        text = text[:MAX_COMMENT] + "\n\n(cut here: too long for one comment)"
    gh("POST", "repos/%s/issues/%s/comments" % (a.repo, issue), {"body": text})


def take_answers(a, rs, issue):
    seen = rs.get("comment_id", 0)
    comments = gh("GET", "repos/%s/issues/%s/comments?per_page=100%s" %
                  (a.repo, issue, "&since=" + rs["comment_since"] if rs.get("comment_since") else "")) or []
    for c in sorted(comments, key=lambda c: c["id"]):
        if c["id"] <= seen:
            continue
        rs["comment_id"], rs["comment_since"] = c["id"], c["created_at"]
        user = c.get("user") or {}
        if user.get("type") == "Bot" or user.get("login") != a.owner or c.get("author_association") != "OWNER":
            continue
        text = c.get("body") or ""
        open_q = waiting(a.state)
        m = re.match(r"\s*\**(#\d+|[A-Z][0-9][0-9])\**\s*[:\-]", text)
        node = (m.group(1) if m.group(1) in open_q else None) if m else (open_q[0] if len(open_q) == 1 else None)
        if node is None and m and open_q:
            comment(a, issue, "Not recorded as an answer: %s is not waiting on a question (waiting: %s)." %
                    (m.group(1), ", ".join(open_q)))
            continue
        if node is None:
            comment(a, issue, "Not recorded as an answer: %s. Start the reply with the node's ID, e.g. `%s: ...`." %
                    ("no node is waiting on a question" if not open_q else
                     "more than one node is waiting (%s)" % ", ".join(open_q), open_q[0] if open_q else "B03"))
            continue
        d = tdir(a.state, node)
        with open(os.path.join(d, "ANSWER.md.tmp"), "w") as f:
            f.write("# Answer to %s's QUESTION.md\n\nThe owner's answer, posted by %s on GitHub at %s: %s\n\n%s\n" %
                    (node, a.owner, c["created_at"], c["html_url"], text))
        os.replace(os.path.join(d, "ANSWER.md.tmp"), os.path.join(d, "ANSWER.md"))
        comment(a, issue, "Recorded as %s's ANSWER.md; %s resumes within seconds." % (node, node))
        a.answered = True


def post_events(a, rs, issue):
    log = os.path.join(a.state, "status.log")
    size = os.path.getsize(log) if os.path.exists(log) else 0
    off = rs.get("log_offset")
    if off is None or off > size:
        rs["log_offset"] = size if off is None else 0
        if off is None:
            return
        off = 0
    with open(log, "rb") as f:
        f.seek(off)
        data = f.read()
    end = data.rfind(b"\n") + 1  # only whole lines
    lines = [l for l in data[:end].decode("utf-8", "replace").splitlines() if EVENT.search(event_text(l)[1])]
    if lines:
        text = "\n".join("- `%s` %s" % event_text(l) for l in lines)
        for l in lines:  # a session's end: add its own closing summary
            m = re.search(r"session ([A-Z][0-9][0-9]) ended|triage of (#\d+) (?:ended|done)", event_text(l)[1])
            task = m and (m.group(1) or m.group(2))
            summary = task and last_result(os.path.join(tdir(a.state, task), "session.jsonl"))
            if task:
                text += "\n\n**%s's total:** %s" % (task, cost_text(os.path.join(tdir(a.state, task), "session.jsonl")))
            if summary:
                text += "\n\n**%s's closing summary:**\n\n%s" % (task, summary[:20000])
        comment(a, issue, text)
    rs["log_offset"] = off + end


def post_questions(a, rs, issue):
    posted = rs.setdefault("questions", {})
    for n in waiting(a.state):
        q = os.path.join(tdir(a.state, n), "QUESTION.md")
        key = str(int(os.path.getmtime(q)))
        if posted.get(n) == key:
            continue
        comment(a, issue, "## %s asks\n\n%s\n\n---\nTo answer, reply to this issue in plain words. Only %s's "
                "replies count; if more than one node is waiting, start with `%s:`.\n" %
                (n, open(q).read().strip(), a.owner, n))
        posted[n] = key


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--repo", required=True)
    p.add_argument("--state", required=True)
    p.add_argument("--worktrees", default="")
    p.add_argument("--owner", default="")
    a = p.parse_args()
    a.answered = False
    a.owner = a.owner or a.repo.split("/")[0]
    a.worktrees = a.worktrees or os.path.join(os.path.dirname(os.path.dirname(a.state)), "worktrees",
                                              a.repo.split("/")[1])
    path = os.path.join(a.state, "report.json")
    try:
        rs = json.load(open(path))
    except (OSError, ValueError):
        rs = {}

    def save():
        with open(path + ".tmp", "w") as f:
            json.dump(rs, f, indent=1)
        os.replace(path + ".tmp", path)

    issue, new = find_issue(a, rs)
    if new or rs.get("issue") != issue:
        rs["issue"] = issue
        rs.pop("body_hash", None)
        if "comment_id" not in rs:  # first run ever: do not replay old comments
            old = gh("GET", "repos/%s/issues/%s/comments?per_page=100" % (a.repo, issue)) or []
            rs["comment_id"] = max([c["id"] for c in old] or [0])
        save()
    try:
        take_answers(a, rs, issue)
        post_events(a, rs, issue)
        post_questions(a, rs, issue)
    finally:
        save()
    prs = {}
    for pr in gh("GET", "repos/%s/pulls?state=open&per_page=100" % a.repo) or []:
        m = re.match(r"node/([A-Z][0-9][0-9])-", pr["head"]["ref"])
        if m:
            prs[m.group(1)] = pr["number"]
    try:
        body = body_for(a, sessions(a.state), prs)
    except Exception as e:  # show the failure on the issue rather than leave it silently stale
        body = ("# noodlebot status: %s\n\n_Updated %s. The scheduler loop is running, but building this "
                "status failed: `%s`. See report.log._\n" % (a.repo, local(), str(e)[:300]))
        print("report.py: status body failed: %s" % e, file=sys.stderr)
    h = hashlib.sha256(re.sub(r"_Updated .*?_", "", body).encode()).hexdigest()
    if h != rs.get("body_hash") or time.time() - rs.get("body_time", 0) >= 900:
        gh("PATCH", "repos/%s/issues/%s" % (a.repo, issue), {"body": body})
        rs["body_hash"], rs["body_time"] = h, time.time()
        save()
    return 3 if a.answered else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # one line for the loop's log; the next run retries
        print("report.py: %s" % e, file=sys.stderr)
        sys.exit(1)
