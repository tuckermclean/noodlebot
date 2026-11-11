#!/usr/bin/env python3
"""Mirror one repository's scheduler state to a GitHub status issue, and take the owner's answers from it.

  report.py --repo OWNER/NAME --state DIR [--worktrees DIR] [--clone DIR] [--owner LOGIN]

Run by loop.sh after each tick with GH_TOKEN set; exits 3 when it wrote an ANSWER.md; PyYAML is used when present (the graph is optional), all GitHub access through `gh api`.
Each run:
  1. finds today's log issue, "noodlebot log <local date>" labelled `noodlebot-status` (creating the label and
     issue, linking the previous day's, if there is none, e.g. after the owner closed it), and remembers it in
     DIR/report.json ("log"); when it is opened, its first comment is the morning overview (the previous day's
     summary, what waits on the owner, the nodes ready next), posted once before any event;
     at the first run on a later date it posts one summary of the day (PRs merged and opened, units that wrote FAILED,
     the cost of the sessions that ended) on the old issue, closes it, opens the new one, links them both ways and
     tries to pin the new and unpin the old, each step recorded in report.json ("roll", "pins") and done once; an
     open `noodlebot-status` issue that is not a log issue (the old sticky one) is closed with one comment linking
     the log issue, and the owner's prefixed answers on it, or on an earlier log issue ("old_logs"), count while the
     question they name was posted there ("qissue") and is open;
  2. turns each new comment by the owner on that issue into ANSWER.md for the unit waiting on a
     question (the only one waiting, or the one named first: "B03: ..."), and replies; likewise each new
     owner comment on a unit's home issue, posted after the unit's question comment (no ID needed when one
     question is open there; it gets a +1 and the answer-received milestone, no reply). It replies only when no
     question is open there, or several are and the comment starts with none of their IDs. A question answered
     on one issue is not answered again from the other;
  3. posts new status.log events (starts, ends, releases, merges, FAILED) as one comment, one line each (an
     ended session's line with its total cost; no closing summary);
  4. posts each new unanswered QUESTION.md once (a node-PR update's, from a PR folder with a `node` file, only on
     its node's home issue, created like the node's own when it has none, as the milestone "PR #N asks"; the update
     has no issue of its own and its answer, taken like a unit's, needs the prefix `PR #N:` when the node or another
     update waits on the same issue): a short `## <ID> asks` pointer on the status issue (its
     Waiting on you item links the question's comment on the unit's issue), and
     the whole QUESTION.md as a milestone on the unit's home issue;
  5. posts milestones on each unit's home issue, each once, each starting with a `**Stage:**` line: a start
     or resume (with its start count, read from new status.log lines), the question, answer received, FAILED.
     The home issue of a triage of N is N; of a node, the first issue on the **Resolves:** line of its spec
     (nodes/<ID>-*.md on origin/main of --clone; default <data>/repos/<basename of --worktrees>) with the
     others linked in its first milestone, or, with no Resolves line, a new "Build <ID> <name>" issue labelled
     `noodlebot-unit`. It is recorded in the unit's state folder (node/<ID>/issue, issue/<N>/issue). What was
     posted per unit is in report.json, so a failed post is retried on the next run and nothing is posted twice;
     the first run after this was added posts nothing for events, questions or FAILED from before;
  6. posts PR milestones on a node's home issue, each once: the PR opened, the CI result per head commit (once all
     its check runs completed), each `Fresh review (<verdict>)` PR comment's verdict, merged or closed without
     merging (from the loop's merged-prs.tsv / closed-prs.tsv), a triage ended done (with its spec PR);
     then closes the home issue, the Build issue and the Resolves issues of merged nodes (one comment naming the PR)
     once every node resolving the issue is merged and none of its units holds it (open or unreleased question,
     follow-up); a new QUESTION.md of a unit whose home issue is closed reopens that issue. Issues of triages are
     never closed. Merged nodes and PRs from before this bookkeeping are only recorded, never commented on or closed
     (recorded at the first run whose merged-prs.tsv / closed-prs.tsv are readable; until then none of it is posted);
  7. rewrites the issue body: usage and throttle, what waits on the owner (each item linking the unit's issue),
     every running session and its latest narration, the deployed commit (HEAD of the live checkout, or of
     $NOODLEBOT_LIVE). Body edits do not notify; comments do. ($NOODLEBOT_NOW, an ISO local datetime, replaces
     the clock; for tests.)
On the first run it does not replay old comments or events. Any failure (a failed milestone post included,
after the other work is done) exits non-zero; the loop logs it and carries on, and the next run picks up
where this one stopped.
"""
import argparse, hashlib, json, math, os, re, subprocess, sys, time
from datetime import datetime, timedelta, timezone

LABEL = "noodlebot-status"
EVENT = re.compile(r"started |ended |done |released |merged |wrote FAILED|stopped session |found ~/STOP|throttle |usage limit")
NODE = re.compile(r"^[A-Z][0-9][0-9]$")
UNIT_LABEL = "noodlebot-unit"
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


def now():
    """The local time now; $NOODLEBOT_NOW (an ISO local datetime) replaces the clock, for tests."""
    v = os.environ.get("NOODLEBOT_NOW")
    if v:
        try:
            return datetime.fromisoformat(v).astimezone()
        except ValueError:
            pass
    return datetime.now().astimezone()


def local(ts=None):
    d = datetime.fromtimestamp(ts).astimezone() if ts is not None else now()
    return d.strftime("%Y-%m-%d %H:%M %Z")


def local_date(stamp):
    """'2026-03-09T22:00:00Z' (a status.log stamp) -> the local date '2026-03-09', or None."""
    try:
        return datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).astimezone().strftime("%Y-%m-%d")
    except ValueError:
        return None


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
    """The tasks with a state directory: nodes ("B03", node/B03) and triaged issues ("#46", issue/46) and spec-PR updates ("PR #12", pr/12)."""
    out = []
    for kind, pat, fmt in (("node", NODE, "%s"), ("issue", re.compile(r"^\d+$"), "#%s"),
                         ("pr", re.compile(r"^\d+$"), "PR #%s")):
        d = os.path.join(state, kind)
        if os.path.isdir(d):
            out += [fmt % n for n in sorted(os.listdir(d)) if pat.match(n) and os.path.isdir(os.path.join(d, n))]
    return out


def pr_node(state, task):
    """The node ID of a node-PR update ("PR #N" whose folder holds a `node` file), else None (a spec-PR update)."""
    if not task.startswith("PR #"):
        return None
    try:
        v = open(os.path.join(tdir(state, task), "node")).read().split()[0]
    except (OSError, IndexError):
        return None
    return v if NODE.match(v) else None


def tdir(state, task):
    if task.startswith("PR #"):
        return os.path.join(state, "pr", task[4:])
    return os.path.join(state, "issue", task[1:]) if task.startswith("#") else os.path.join(state, "node", task)


def has(state, task, name):
    return os.path.exists(os.path.join(tdir(state, task), name))


def read_lines(path):
    try:
        with open(path, errors="replace") as f:
            return [l.strip() for l in f if l.strip()]
    except OSError:
        return []


def merged_ids(state, graph=()):
    """Node IDs whose PR is merged: from merged-prs.tsv's branches, and the squash subjects in subjects.txt."""
    out = set()
    for l in read_lines(os.path.join(state, "merged-prs.tsv")):
        m = re.match(r"\S+ node/([A-Z][0-9][0-9])-", l)
        if m:
            out.add(m.group(1))
    subjects = read_lines(os.path.join(state, "subjects.txt"))
    for n in graph:
        if any(s.startswith("%s %s:" % (n["id"], n["name"])) for s in subjects):
            out.add(n["id"])
    return out


def is_merged(state, n):
    try:
        return n in merged_ids(state, graph_nodes(state))
    except Exception:
        return False


def graph_nodes(state):
    try:
        import yaml
        with open(os.path.join(state, "graph.yaml"), encoding="utf-8") as fh:
            ns = yaml.safe_load(fh)["nodes"]
        return [n for n in ns if isinstance(n, dict) and isinstance(n.get("id"), str) and isinstance(n.get("name"), str)]
    except Exception:
        return []


def start_info(state, node):
    """What the scheduler will do with an answered node: ("ready", merged) when ready.py, run on the state
    folder's latest inputs, names it; ("wait", why) when it does not; None when that cannot be told."""
    try:
        import yaml
        graph = yaml.safe_load(open(os.path.join(state, "graph.yaml"), encoding="utf-8"))["nodes"]
        merged = merged_ids(state, graph)
        cmd = [sys.executable, "-I", os.path.join(os.path.dirname(os.path.abspath(__file__)), "ready.py"),
               "--graph", os.path.join(state, "graph.yaml"), "--markers", os.path.join(state, "node"), "--all",
               "--merged-prs", os.path.join(state, "merged-prs.txt")]
        if os.path.exists(os.path.join(state, "subjects.txt")):
            cmd += ["--subjects", os.path.join(state, "subjects.txt")]
        for i in sorted(merged_ids(state)):
            cmd += ["--merged", i]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if r.returncode != 0:
            return None
        for l in r.stdout.splitlines():
            w = l.split()
            if w and w[0] == node:
                return "ready", len(w) > 2 and w[2] == "followup"
        entry = next((n for n in graph if n["id"] == node), None)
        if entry is None:
            return "wait", "%s is not in the graph" % node
        d = tdir(state, node)
        if has(state, node, "FAILED"):
            return "wait", "it is held by FAILED: %s" % (next(iter(read_lines(os.path.join(d, "FAILED"))), "no reason given"))
        if has(state, node, "WAITING-PR"):
            pr = open(os.path.join(d, "WAITING-PR")).read().strip()
            if pr not in read_lines(os.path.join(state, "merged-prs.txt")):
                return "wait", "it waits for you to merge spec PR #%s" % pr
        deps = [x for x in entry.get("deps") or [] if x not in merged]
        if node not in merged and deps:
            return "wait", "it waits for unmerged deps: %s" % ", ".join(deps)
        return "wait", "the scheduler does not start it yet"
    except Exception as e:
        if os.path.exists(os.path.join(state, "graph.yaml")):
            print("report.py: cannot tell when %s starts: %s" % (node, e), file=sys.stderr)
        return None


def answered_text(state, node):
    """The clause for an answered node: when it starts, or what it waits for, or nothing about timing."""
    info = start_info(state, node)
    if info is None:
        return "the answer is recorded"
    if info[0] == "ready":
        return "a follow-up starts within seconds" if info[1] else "resumes within seconds"
    return "answered, but " + info[1]


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
        k = n.rsplit("#", 1)[-1]
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
    if not isinstance(v, (int, float)) or isinstance(v, bool):
        return False
    try:
        return math.isfinite(v)
    except OverflowError:  # an int too large for a float
        return False


def whole(v):
    """A turn count: a non-negative int that fits a float (not a float, so a sum of them cannot overflow)."""
    return isinstance(v, int) and num(v) and v >= 0


def cost_turns(log):
    """(latest total_cost_usd, turns summed over results) of the well-formed result events in the whole log, or None.

    Streams the file line by line (memory is bounded by the longest line) and parses only lines that mention a
    result. Any error while decoding, parsing or checking one line makes it a malformed line, which is skipped."""
    cost, turns, found = 0.0, 0, False
    try:
        with open(log, "rb") as f:
            for raw in f:
                if b'"result"' not in raw:
                    continue
                try:
                    d = json.loads(raw.decode("utf-8", "replace"))
                    if not (isinstance(d, dict) and d.get("type") == "result" and num(d.get("total_cost_usd"))
                            and whole(d.get("num_turns"))):
                        continue
                    c, t = d["total_cost_usd"], d["num_turns"]
                except Exception:  # e.g. too deeply nested (RecursionError): a malformed line
                    continue
                cost, turns, found = c, turns + t, True
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


def bar(u, width=20):
    n = max(0, min(width, int(round(u * width))))
    return "`" + "█" * n + "░" * (width - n) + "`"


def usage_lines(state):
    """The plan's usage from usage.py's file (shared by every repository's loop), or nothing."""
    try:
        u = json.load(open(os.path.join(os.path.dirname(state), "usage.json")))
    except (OSError, ValueError):
        return []
    w = u.get("windows") or {}
    out = ["## Usage", ""]
    names = {"five_hour": "5-hour", "seven_day": "7-day"}
    for k in ("five_hour", "seven_day"):
        if k not in w:
            continue
        x = w[k]
        line = "- **%s** %s %.0f%%, resets %s" % (names[k], bar(x["utilization"]), x["utilization"] * 100, local(x["resetsAt"]))
        if k == "five_hour" and u.get("projected5h") is not None:
            line += " (projected %.0f%% at the reset)" % (min(u["projected5h"], 9.99) * 100)
        if k == "seven_day" and u.get("weekElapsed") is not None:
            line += " (%.0f%% of the week gone)" % (u["weekElapsed"] * 100)
        out.append(line)
    out.append("- **Throttle:** " + ("**holding new sessions**: " + u["reason"] if u.get("hold")
                                    else "open (new sessions start)"))
    return out + [""]


def mtime_key_of(a, task):
    try:
        return mtime_key(os.path.join(tdir(a.state, task), "QUESTION.md"))
    except OSError:
        return None


def question_link(a, rs, task):
    """Where to read and answer a task's open question: its comment on the unit's issue, once that is posted."""
    qc = rs.get("units", {}).get(task, {}).get("qc") or {}
    try:
        current = qc.get("key") == "question:" + mtime_key(os.path.join(tdir(a.state, task), "QUESTION.md"))
    except OSError:
        current = False
    if current and qc.get("url"):
        return "read and answer it on the unit's issue: %s" % qc["url"]
    if (rs.get("questions") or {}).get(task) == mtime_key_of(a, task) and not qc:
        return "answer it on this issue, starting the reply with `%s:`" % task  # posted here by the old version
    return "its comment on the unit's issue is not posted yet"


def unit_ref(a, n):
    """' Unit issue: #N.' for a unit whose home issue is recorded, else ''."""
    try:
        return " Unit issue: #%d." % int(open(os.path.join(tdir(a.state, n), "issue")).read().split()[0])
    except (OSError, ValueError, IndexError):
        return ""


def waiting_items(a, sts, prs, rs):
    """The Markdown items for what waits on the owner (none when nothing does), each linking the unit's issue."""
    state = a.state
    items = []
    for n in nodes(state):
        if has(state, n, "FAILED"):
            path = os.path.join(tdir(state, n), "FAILED")
            with open(path, errors="replace") as fh:
                why = fh.readline().strip() or "no reason given"
            items.append("- **%s FAILED**: %s. To retry, delete `%s`.%s" % (n, why, path, unit_ref(a, n)))
        elif has(state, n, "QUESTION.md") and has(state, n, "ANSWER.md"):
            items.append("- %s: %s.%s" % (n, answered_text(state, n) if n in nodes(state) and not n.startswith("#") else "answered",
                                         unit_ref(a, n)))
        elif has(state, n, "QUESTION.md") and not n.startswith("#") and is_merged(state, n):
            items.append("- **%s's PR is merged; its question is still open, and an answer starts a follow-up** "
                         "(%s).%s" % (n, question_link(a, rs, n), unit_ref(a, n)))
        elif has(state, n, "QUESTION.md"):
            items.append("- **%s asks a question** (%s).%s" % (n, question_link(a, rs, n), unit_ref(a, n)))
        elif has(state, n, "WAITING-PR"):
            pr = open(os.path.join(tdir(state, n), "WAITING-PR")).read().strip()
            items.append("- **%s** waits for you to merge spec PR #%s; it resumes within a minute after.%s" % (n, pr, unit_ref(a, n)))
    for n, pr in sorted(prs.items()):
        if not has(state, n, "QUESTION.md") and not has(state, n, "WAITING-PR") and n not in [t[0] for t in sts]:
            items.append("- %s's PR #%s: open, no session running on it (review or merge it).%s" % (n, pr, unit_ref(a, n)))
    return items


def live_checkout():
    return os.environ.get("NOODLEBOT_LIVE") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def deployed_commit():
    """'abc1234 subject' of HEAD of the live checkout, or 'unknown'."""
    out = git_lines(live_checkout(), "log", "-1", "--abbrev=7", "--format=%h %s")
    return out[0] if out else "unknown"


def body_for(a, sts, prs, rs=None):
    state = a.state
    rs = rs or {}
    log = rs.get("log") or {}
    out = ["# noodlebot log %s: %s%s" % (log.get("date") or now().strftime("%Y-%m-%d"), a.repo,
                                       " (noodlebot %s)" % a.version if a.version else ""), "",
           "_Updated %s by the scheduler loop (within a minute of a change; when nothing changes, every 15 minutes). If this is more than ~20 minutes old, "
           "the loop is not running._" % local(), "",
           "**Deployed:** `%s`" % deployed_commit()]
    if log.get("prev"):
        out.append("")
        out.append("Previous day's log: #%s" % log["prev"])
    out += [""] + usage_lines(state) + ["## Waiting on you"]
    items = waiting_items(a, sts, prs, rs)
    out += items or ["- nothing"]

    out += ["", "## Sessions (%d running)" % len(sts),
            "", "_Costs are the CLI's list-price estimate, not the bill._"]
    many = len(sts) > 1
    for n, pid, started in sts:
        label = "triage of %s" % n if n.startswith("#") else n
        mins = max(0, int((now().timestamp() - started) // 60))
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
        commits = [] if "#" in n else git_lines(os.path.join(a.worktrees, n), "log", "--oneline",
                                                         "-3" if many else "-8", "origin/main..HEAD")
        if commits:
            out += ["", "Latest commits:", ""] + ["- `%s`" % c for c in commits]
    if not sts:
        out.append("No session running.")

    out += ["", "---", "Answer a question on the unit's issue (the link is in its item above) in plain words (e.g. "
            "\"Q1 approve, Q2 as recommended\"). Only %s's replies count; if more than one unit on that issue is "
            "waiting, start with its ID or issue number. A reply here still works if it starts with the ID "
            "prefix, e.g. `B03: ...` or `#46: ...`. Hand an issue to the bot by adding the `noodlebot` label "
            "(only labels you add count). Closing this issue is fine: the loop opens a new one." % a.owner]
    return "\n".join(out) + "\n"


LOG_TITLE = re.compile(r"^noodlebot log (\d{4}-\d\d-\d\d)$")


def log_issues(a, state):
    """[(date, number)] of the issues labelled `noodlebot-status` whose title is a day's log title, newest date first."""
    found = gh("GET", "repos/%s/issues?labels=%s&state=%s&per_page=100" % (a.repo, LABEL, state)) or []
    out = [(LOG_TITLE.match(i.get("title") or "").group(1), i["number"]) for i in found
           if "pull_request" not in i and LOG_TITLE.match(i.get("title") or "")]
    return sorted(out, reverse=True)


def find_issue(a, rs):
    """(number, new) of today's log issue: the recorded one while open, else the open one with today's title, else a
    new one (label created if needed) linking the previous day's. Recorded in rs["log"] and rs["issue"]."""
    today = a.today
    log = rs.get("log") or {}
    n = rs.get("issue")
    if n and log.get("date") == today and log.get("issue") == n:
        try:
            st = gh("GET", "repos/%s/issues/%s" % (a.repo, n)).get("state")
            if st == "open":
                return n, False
            if st == "closed" and (rs.get("roll") or {}).get("old") != n:  # the owner closed today's issue: a new one, linked from it
                park_link(rs)
                rs["roll"] = {"old": n, "date": today, "summary": True, "closed": True}
                a.save()
        except RuntimeError:
            pass
    roll = rs.get("roll") or {}
    prev = roll.get("old") or next((num for d, num in log_issues(a, "all") if d < today), None)
    for i in gh("GET", "repos/%s/issues?labels=%s&state=open&per_page=100" % (a.repo, LABEL)) or []:
        if "pull_request" not in i and i.get("title") == "noodlebot log " + today:
            if log.get("date") == today and log.get("issue") == i["number"]:
                rs["issue"] = i["number"]  # the one we recorded (its read failed): keep its overview state
                a.save()
                return i["number"], False
            rs["log"], rs["issue"] = {"date": today, "issue": i["number"], "prev": prev, "overview": True}, i["number"]
            adopt(a, rs, i["number"], i.get("node_id"), False)
            a.save()  # found, not opened by us: no overview
            return i["number"], True
    try:
        gh("POST", "repos/%s/labels" % a.repo, {"name": LABEL, "color": "5319e7",
                                              "description": "Kept up to date by the noodlebot scheduler"})
    except RuntimeError as e:
        if "already_exists" not in str(e) and "422" not in str(e):
            raise
    issue = gh("POST", "repos/%s/issues" % a.repo, {"title": "noodlebot log " + today, "labels": [LABEL],
                                                  "body": "Starting up..." + ("\n\nPrevious day's log: #%s" % prev if prev else "")})
    rs["log"], rs["issue"] = {"date": today, "issue": issue["number"], "prev": prev, "overview": False}, issue["number"]
    adopt(a, rs, issue["number"], issue.get("node_id"), True)
    a.save()
    return issue["number"], True


def adopt(a, rs, number, node_id, pin):
    """A new log issue is today's: queue its pin (when opened by us) and the unpin of the one it replaces, and note it in
    the rollover's record. Saved by the caller, with rs["log"]."""
    roll = rs.get("roll")
    pins = rs.setdefault("pins", [])
    if roll and not roll.get("new"):
        roll["new"] = number
        pins.append({"op": "unpin", "number": roll["old"]})  # before the pin: GitHub allows three
    if pin:
        pins.append({"op": "pin", "number": number, "node_id": node_id})


def run_pins(a, rs):
    """Try each queued pin and unpin once. A refusal (the pin cap, no permission) is logged and dropped; a server error
    or timeout is tried again on the next run (twice at most). Nothing else depends on it."""
    left = []
    for p in rs.get("pins") or []:
        try:
            node_id = p.get("node_id") or gh("GET", "repos/%s/issues/%s" % (a.repo, p["number"]))["node_id"]
            gh("POST", "graphql", {"query": "mutation($id:ID!){%sIssue(input:{issueId:$id}){issue{number}}}" % p["op"],
                                   "variables": {"id": node_id}})
        except Exception as e:
            print("report.py: %s of #%s failed: %s" % (p["op"], p["number"], e), file=sys.stderr)
            if re.search(r"HTTP 5\d\d|timed out|Timeout", str(e)) and p.get("tries", 0) < 2:
                p["tries"] = p.get("tries", 0) + 1
                left.append(p)
    rs["pins"] = left
    a.save()


def rollover(a, rs):
    """The first run on a date after the open log issue's: one summary of that day on it, then close it. Each step is
    recorded in the roll (rs["roll"]; rs["parked"] for a roll still unfinished at the next midnight) so that a failed run
    finishes the rest on the next, repeating none (the new issue, its link on the old one and the pins follow in
    find_issue, finish_roll and run_pins)."""
    log = rs.get("log") or {}
    roll = rs.get("roll")
    if roll and roll.get("new") and log.get("issue") == roll["new"] and log.get("date", a.today) < a.today:
        park_link(rs)  # still unfinished at the next midnight: keep it apart, start the pending day's rollover
        roll = None
    if roll is None:
        if log.get("issue") and log.get("date") and log["date"] < a.today:
            roll = rs["roll"] = {"old": log["issue"], "date": log["date"]}
            a.save()
    for r in list(rs.get("parked") or []) + ([roll] if roll else []):
        try:
            roll_steps(a, rs, r)
        except Exception as e:  # another roll's steps do not depend on this one's
            a.errors.append(str(e))


def roll_steps(a, rs, roll):
    """The summary of the roll's own day on its old issue, then the close, each once."""
    if not roll.get("summary"):
        try:
            comment(a, roll["old"], "\n".join(["## End-of-day summary, %s" % roll["date"], ""] +
                                              summary_lines(a, rs, roll["date"], "The day") + [""]))
        except RuntimeError as e:
            if not gone(e):
                raise
            print("report.py: issue #%s is gone; no summary on it" % roll["old"], file=sys.stderr)
        roll["summary"] = True
        a.save()
    if not roll.get("closed"):
        try:
            gh("PATCH", "repos/%s/issues/%s" % (a.repo, roll["old"]), {"state": "closed", "state_reason": "completed"})
        except RuntimeError as e:
            if not gone(e):
                raise
            print("report.py: issue #%s is gone; not closed" % roll["old"], file=sys.stderr)
        roll["closed"] = True
        a.save()


def gone(e):
    return bool(re.search(r"HTTP (404|410)", str(e)))


def park_link(rs):
    """Move a rollover that has a new issue but is not finished (summary, close, link) to rs["parked"], where rollover and
    finish_roll complete it, whatever the roll of a later day."""
    roll = rs.get("roll")
    if roll and roll.get("new") and not (roll.get("summary") and roll.get("closed") and roll.get("linked")):
        rs.setdefault("parked", []).append(roll)
        rs.pop("roll", None)


def put_link(a, old, new):
    try:
        comment(a, old, "Next log issue: #%s" % new)
    except RuntimeError as e:
        if not gone(e):
            raise
        print("report.py: issue #%s is gone; no link on it" % old, file=sys.stderr)


def finish_roll(a, rs):
    """Put the link to the new issue on the old one, once, when the roll's summary and close are done; then that
    rollover is done."""
    for roll in list(rs.get("parked") or []) + ([rs["roll"]] if rs.get("roll") else []):
        if not roll.get("new") or not (roll.get("summary") and roll.get("closed")):
            continue
        try:
            if not roll.get("linked"):
                put_link(a, roll["old"], roll["new"])
                roll["linked"] = True
                a.save()
            if roll is rs.get("roll"):
                rs.pop("roll", None)
            else:
                rs["parked"].remove(roll)
            a.save()
        except Exception as e:
            a.errors.append(str(e))
    if not rs.get("parked"):
        rs.pop("parked", None)


def close_old_status(a, rs, log_issue):
    """Close each open `noodlebot-status` issue that is not a log issue (the old sticky one), once, with one comment linking
    today's log issue; the owner's answers on it are taken while its question is open (take_old_answers)."""
    old = rs.setdefault("old_status", {})
    for i in gh("GET", "repos/%s/issues?labels=%s&state=open&per_page=100" % (a.repo, LABEL)) or []:
        n = i["number"]
        if "pull_request" in i or LOG_TITLE.match(i.get("title") or "") or n == log_issue:
            continue
        try:
            st = old.setdefault(str(n), {})
            if not st.get("commented"):
                c = comment(a, n, "This status issue is replaced by the daily log, #%s. Closing it. A reply that starts with a "
                            "unit's ID still works here while that unit's question was asked here and is open; "
                            "otherwise answer on the unit's issue or on the log issue." % log_issue)
                st.update({"commented": True, "cursor": c.get("id") or 0, "since": c.get("created_at") or ""})
                a.save()
            if not st.get("closed"):
                gh("PATCH", "repos/%s/issues/%s" % (a.repo, n), {"state": "closed", "state_reason": "completed"})
                st["closed"] = True
                rs.setdefault("pins", []).append({"op": "unpin", "number": n})
                a.save()
                run_pins(a, rs)
        except Exception as e:
            a.errors.append(str(e))


def take_old_answers(a, rs):
    """The owner's new prefixed comments on a closed old status issue (rs["old_status"]) or an earlier log issue
    (rs["old_logs"]): recorded as an answer only when the question the prefix names was posted on that issue
    (rs["qissue"]) and is still open; refused, with a reply, otherwise. An earlier log issue is kept only while an open
    question was posted on it; an issue that is gone (404/410) is dropped."""
    held = {(rs.get("qissue") or {}).get(n) for n in waiting(a.state) if n in (rs.get("questions") or {})
            and rs["questions"][n] == mtime_key(os.path.join(tdir(a.state, n), "QUESTION.md"))}
    logs = rs.get("old_logs") or {}
    for num in [n for n in logs if int(n) not in held]:
        logs.pop(num)
        a.save()
    for key in ("old_status", "old_logs"):
        for num, st in sorted((rs.get(key) or {}).items()):
            if st.get("cursor") is None:
                continue
            try:
                take_old_comments(a, rs, num, st)
            except Exception as e:
                if gone(e):
                    print("report.py: issue #%s is gone; its answers are no longer read" % num, file=sys.stderr)
                    rs[key].pop(num, None)
                    a.save()
                else:
                    a.errors.append(str(e))


def take_old_comments(a, rs, num, st):
    comments = gh("GET", "repos/%s/issues/%s/comments?per_page=100%s" %
                  (a.repo, num, "&since=" + st["since"] if st.get("since") else "")) or []
    for c in sorted(comments, key=lambda c: c["id"]):
        if c["id"] <= st["cursor"]:
            continue
        user = c.get("user") or {}
        text = c.get("body") or ""
        if user.get("type") != "Bot" and user.get("login") == a.owner and c.get("author_association") == "OWNER":
            m = ID_PREFIX.match(text)
            node = m.group(1) if m else None
            q = os.path.join(tdir(a.state, node), "QUESTION.md") if node and node in nodes(a.state) else None
            live = bool(q) and node in waiting(a.state) and (rs.get("qissue") or {}).get(node) == int(num) \
                and (rs.get("questions") or {}).get(node) == mtime_key(q)
            if live:
                what = record_answer(a, rs, node, c, text)
                comment(a, num, "Recorded as %s's ANSWER.md%s." % (node, "" if what is None else "; " + what))
            else:
                comment(a, num, "Not recorded as an answer: this issue is closed, and %s. Answer on the unit's issue "
                        "or on the log issue (#%s)." % ("no reply starting with a unit's ID" if not node else
                        "%s has no question asked here that is still open" % node, rs.get("issue")))
        st["cursor"], st["since"] = c["id"], c.get("created_at", "")
        a.save()


def day_summary(a, date):
    """(tasks whose session ended on the local date, their summed total cost) from status.log; the cost is each task's
    latest total, so a task that ended twice counts once."""
    ended = set()
    for l in read_lines(os.path.join(a.state, "status.log")):
        stamp, what = event_text(l)
        m = re.search(r"session ([A-Z][0-9][0-9]) ended|triage of (#\d+) (?:ended|done)|update of (PR #\d+) ended", what)
        if m and local_date(stamp) == date:
            ended.add(m.group(1) or m.group(2) or m.group(3))
    cost = 0.0
    for t in ended:
        ct = cost_turns(os.path.join(tdir(a.state, t), "session.jsonl"))
        cost += ct[0] if ct else 0.0
    return sorted(ended), cost


def merged_on(a, date):
    """PR numbers merged on the local date: the loop's closed-prs.tsv ("<n> <branch> <closedAt> <merged>")."""
    return sorted(int(w[0]) for w in tsv(a, "closed-prs.tsv")
                  if len(w) > 3 and w[0].isdigit() and w[3] == "true" and local_date(w[2]) == date)


def failed_on(a, date):
    """Units whose session ended on the local date with the loop writing FAILED (status.log)."""
    out = set()
    for l in read_lines(os.path.join(a.state, "status.log")):
        stamp, what = event_text(l)
        m = re.search(r"session ([A-Z][0-9][0-9]) ended|triage of (#\d+) (?:ended|done)|update of (PR #\d+) ended", what)
        if m and ("wrote FAILED" in what or "held by FAILED" in what) and local_date(stamp) == date:
            out.add(m.group(1) or m.group(2) or m.group(3))
    return sorted(out)


def summary_lines(a, rs, date, label):
    """One day's summary, for the closing summary and for the morning overview: the sessions that ended and their summed
    cost, the PRs merged and opened that day, the units that wrote FAILED. PRs opened are those seen open (rs["pr_opened"],
    recorded each run from the open PR list with GitHub's created_at)."""
    tasks, cost = day_summary(a, date)
    merged = merged_on(a, date)
    opened = sorted(int(n) for n, d in (rs.get("pr_opened") or {}).items() if d == date)
    failed = failed_on(a, date)
    nums = lambda ns: ", ".join("#%d" % n for n in ns) or "none"
    return ["**%s (%s):** " % (label, date) +
            ("%d session%s ended (%s), $%.2f total cost (list-price estimate)." %
             (len(tasks), "" if len(tasks) == 1 else "s", ", ".join(tasks), cost) if tasks else "no session ended."),
            "", "- PRs merged: " + nums(merged), "- PRs opened: " + nums(opened),
            "- Units that wrote FAILED: " + (", ".join(failed) or "none")]


def ready_next(a, prs):
    """['ID name', ...]: the nodes ready.py would start next (all of them, in graph order), [] when it cannot tell."""
    graph = os.path.join(a.state, "graph.yaml")
    if not os.path.exists(graph):
        return []
    try:
        cmd = [sys.executable, "-I", os.path.join(os.path.dirname(os.path.abspath(__file__)), "ready.py"),
               "--graph", graph, "--markers", os.path.join(a.state, "node"), "--all",
               "--merged-prs", os.path.join(a.state, "merged-prs.txt")]
        if os.path.exists(os.path.join(a.state, "subjects.txt")):
            cmd += ["--subjects", os.path.join(a.state, "subjects.txt")]
        for i in sorted(merged_ids(a.state, graph_nodes(a.state))):
            cmd += ["--merged", i]
        for i in sorted(prs):
            cmd += ["--open", i]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if r.returncode != 0:
            print("report.py: ready.py failed: %s" % r.stderr.strip()[:200], file=sys.stderr)
            return []
        return [l.strip() for l in r.stdout.splitlines() if l.strip()]
    except (OSError, subprocess.TimeoutExpired) as e:
        print("report.py: ready.py failed: %s" % e, file=sys.stderr)
        return []


def post_overview(a, rs, issue, prs):
    """The log issue's first comment, once: the previous day's summary, what waits on the owner, the nodes ready next."""
    log = rs["log"]
    prev_date = (datetime.strptime(log["date"], "%Y-%m-%d") - timedelta(days=1)).strftime("%Y-%m-%d")
    out = ["## Morning overview, %s" % log["date"], ""] + summary_lines(a, rs, prev_date, "Yesterday")
    if log.get("prev"):
        out += ["", "Previous day's log: #%s" % log["prev"]]
    try:
        items = waiting_items(a, sessions(a.state), prs, rs) or ["- nothing"]
    except Exception as e:  # the body shows the failure too; the overview is still posted
        items = ["- (cannot be listed: %s)" % str(e)[:200]]
    out += ["", "**Waiting on you:**", ""] + items
    ready = ready_next(a, prs)
    out += ["", "**Ready to start next:**", ""] + (["- " + r for r in ready] or ["- nothing"])
    comment(a, issue, "\n".join(out) + "\n")
    log["overview"] = True
    a.save()


def signed(a, text):
    return text.rstrip("\n") + "\n\n" + a.signature + "\n" if a.signature else text


def comment(a, issue, text):
    room = MAX_COMMENT - (len(a.signature) + 4 if a.signature else 0)
    if len(text) > room:
        text = text[:room] + "\n\n(cut here: too long for one comment)"
    text = signed(a, text)
    return gh("POST", "repos/%s/issues/%s/comments" % (a.repo, issue), {"body": text}) or {}


def spec_info(a, node):
    """(name or None, [Resolves issue numbers]) of node's spec on origin/main of the clone; (None, []) when unreadable."""
    names = [l for l in git_lines(a.clone, "ls-tree", "--name-only", "origin/main", "nodes/")
             if re.match(r"nodes/%s-.*\.md$" % re.escape(node), l)]
    name, issues = None, []
    if names:
        f = sorted(names)[0]
        name = f[len("nodes/%s-" % node):-len(".md")]
        for l in git_lines(a.clone, "show", "origin/main:" + f):
            if l.startswith("**Resolves:**"):
                issues = [int(x) for x in re.findall(r"#(\d+)", l)]
                break
    if name is None:
        name = next((n["name"] for n in graph_nodes(a.state) if n["id"] == node), None)
    return name, issues


def home_issue(a, rs, task):
    """The unit's home issue number: the recorded one, else decided (and for a Build issue created) and recorded."""
    if pr_node(a.state, task):  # a node-PR update has no issue of its own: its node's
        return home_issue(a, rs, pr_node(a.state, task))
    f = os.path.join(tdir(a.state, task), "issue")
    try:
        return int(open(f).read().split()[0])
    except (OSError, ValueError, IndexError):
        pass
    if task.startswith("#"):
        n = int(task[1:])
    else:
        name, issues = spec_info(a, task)
        if issues:
            n = issues[0]
        else:
            title = "Build %s%s" % (task, " " + name if name else "")
            if not getattr(a, "unit_label", False):
                a.unit_label = True
                try:
                    gh("POST", "repos/%s/labels" % a.repo, {"name": UNIT_LABEL, "color": "0e8a16",
                                                          "description": "A unit of noodlebot work, while it is built"})
                except RuntimeError:
                    pass  # exists already, or labels.py ensures it
            spec = "`nodes/%s-%s.md`" % (task, name) if name else "its spec"
            n = None  # a POST that failed after GitHub created the issue must not lead to a second one
            for i in gh("GET", "repos/%s/issues?labels=%s&state=open&per_page=100" % (a.repo, UNIT_LABEL)) or []:
                names = [l.get("name") if isinstance(l, dict) else l for l in i.get("labels") or []]
                if i.get("title") == title and UNIT_LABEL in names and "pull_request" not in i:
                    n = i["number"]
                    break
            if n is None:
                n = gh("POST", "repos/%s/issues" % a.repo, {
                    "title": title, "labels": [UNIT_LABEL],
                    "body": signed(a, "Home of node %s: the scheduler loop posts its milestones here (start, questions, PR, CI, "
                                      "result). Its spec is %s on the main branch. The loop closes this issue once "
                                      "the node is merged." % (task, spec))})["number"]
    with open(f + ".tmp", "w") as fh:
        fh.write("%d\n" % n)
    os.replace(f + ".tmp", f)
    return n


def milestone(a, rs, task, key, stage, body=""):
    """Post one milestone comment on the unit's home issue, once per key (recorded in report.json after the post)."""
    if task.startswith("PR #") and not (pr_node(a.state, task) and key.split(":")[0] in ("question", "answer")):
        return  # a spec-PR update is not a unit: no issue; a node-PR update posts only its question and answer, on its node's
    u = rs.setdefault("units", {}).setdefault(task, {})
    done = u.setdefault("done", [])
    if key in done:
        return
    issue = home_issue(a, rs, task)
    text = "**Stage:** " + stage
    if not u.get("intro") and not task.startswith("#") and not task.startswith("PR #"):
        others = [i for i in spec_info(a, task)[1] if i != issue]
        if others:
            text += "\n\nAlso on this node's Resolves line: " + ", ".join("#%d" % i for i in others) + "."
    if body:
        text += "\n\n" + body
    c = comment(a, issue, text)
    u["intro"] = True
    if c.get("created_at") and not u.get("first_at"):
        u["first_at"] = c["created_at"]
    if key.startswith("question:"):  # where the owner's answer on the unit's issue is taken from
        u["qc"] = {"key": key, "id": c.get("id"), "url": c.get("html_url"), "at": c.get("created_at")}
    done.append(key)
    a.save()


def flush(a, rs):
    """Post the queued milestones; one that fails stays queued and is logged at the end of the run."""
    left = []
    tried = a.__dict__.setdefault("failed_keys", set())
    for m in rs.get("pending", []):
        if not os.path.isdir(tdir(a.state, m["task"])):
            continue  # its unit is gone
        if (m["task"], m["key"]) in tried:  # failed earlier in this run: the next run retries it
            left.append(m)
            continue
        try:
            milestone(a, rs, m["task"], m["key"], m["stage"], m.get("body", ""))
        except Exception as e:
            a.errors.append(str(e))
            tried.add((m["task"], m["key"]))
            left.append(m)
    rs["pending"] = left
    a.save()


def queue(a, rs, task, key, stage, body=""):
    rs.setdefault("pending", []).append({"task": task, "key": key, "stage": stage, "body": body})
    a.save()


def mtime_key(path):
    return str(int(os.path.getmtime(path)))


def migrate(a, rs):
    """A report.json from before milestones: what is there now was seen; post no milestone for it."""
    units = rs.setdefault("units", {})
    for n in nodes(a.state):
        keys = []
        if has(a.state, n, "FAILED"):
            keys.append("failed:" + mtime_key(os.path.join(tdir(a.state, n), "FAILED")))
        if has(a.state, n, "QUESTION.md"):
            key = mtime_key(os.path.join(tdir(a.state, n), "QUESTION.md"))
            if rs.get("questions", {}).get(n) == key:  # only a question the old version posted
                keys.append("question:" + key)
        if keys:
            units.setdefault(n, {}).setdefault("done", []).extend(keys)
    if rs.get("m_offset") is None:
        rs["m_offset"] = rs.get("log_offset", 0)


START = re.compile(r"started (?:([A-Z][0-9][0-9]) \(|triage of (#\d+) )")
TRIAGE_DONE = re.compile(r"triage of (#\d+) done")


def collect_starts(a, rs):
    """Queue a milestone for each new `started` line of status.log (only whole lines after the last one read)."""
    log = os.path.join(a.state, "status.log")
    size = os.path.getsize(log) if os.path.exists(log) else 0
    off = rs.get("m_offset")
    if off is None:
        rs["m_offset"] = size  # first run: do not replay
        return
    if off > size:
        off = 0
    with open(log, "rb") as f:
        f.seek(off)
        data = f.read()
    end = data.rfind(b"\n") + 1
    pos = off
    for raw in data[:end].splitlines(keepends=True):
        line_off, pos = pos, pos + len(raw)
        what = event_text(raw.decode("utf-8", "replace").strip())[1]
        d = TRIAGE_DONE.match(what)
        if d:
            if not getattr(a, "pulls_ok", True):  # its spec PR cannot be told: read this line again next run
                end = line_off - off
                break
            pr = next((p for p in getattr(a, "pulls", []) if re.match(r"spec/triage-%s-" % d.group(1)[1:],
                                                                      (p.get("head") or {}).get("ref") or "")), None)
            queue(a, rs, d.group(1), "done:%d" % line_off, "triage done",
                  "The triage ended done." + (" Its spec PR: %s" % pr_link(pr) if pr else ""))
            continue
        m = START.match(what)
        if not m:
            continue
        task = m.group(1) or m.group(2)
        k = re.search(r"\bstart (\d+) of (\d+)", what)
        count = "start %s of %s" % (k.group(1), k.group(2)) if k else "start count unknown"
        resumed = os.path.isdir(os.path.join(tdir(a.state, task), "answered"))
        if task.startswith("#") and resumed:
            stage = "triage resumed after your answer (%s)" % count
        elif task.startswith("#"):
            stage = "triage started (%s)" % count
        elif resumed:
            stage = "resumed after your answer (%s)" % count
        else:
            stage = "session started (%s)" % count
        queue(a, rs, task, "start:%d" % line_off, stage)
    rs["m_offset"] = off + end
    a.save()


def post_failed(a, rs):
    for n in nodes(a.state):
        if n.startswith("PR #") or not has(a.state, n, "FAILED"):  # a spec-PR update is not a unit: no issue
            continue
        path = os.path.join(tdir(a.state, n), "FAILED")
        key = "failed:" + mtime_key(path)
        done = rs.setdefault("units", {}).setdefault(n, {}).setdefault("done", [])
        if key in done:
            continue
        if a.first_run:  # FAILED files from before the first run were seen, not new
            done.append(key)
            continue
        with open(path, errors="replace") as fh:
            why = fh.readline().strip() or "no reason given"
        try:
            milestone(a, rs, n, key, "FAILED, held until you delete its FAILED file", "Reason: %s" % why)
        except Exception as e:
            a.errors.append(str(e))


def record_answer(a, rs, node, c, text):
    """Write the node's ANSWER.md from the owner's comment and queue the answer-received milestone; returns the
    clause saying what the answer waits for (None for a triage)."""
    d = tdir(a.state, node)
    with open(os.path.join(d, "ANSWER.md.tmp"), "w") as f:
        f.write("# Answer to %s's QUESTION.md\n\nThe owner's answer, posted by %s on GitHub at %s: %s\n\n%s\n" %
                (node, a.owner, c["created_at"], c["html_url"], text))
    os.replace(os.path.join(d, "ANSWER.md.tmp"), os.path.join(d, "ANSWER.md"))
    a.answered = True
    what = None if node.startswith("#") or node.startswith("PR #") else answered_text(a.state, node)
    queue(a, rs, node, "answer:%s" % c["id"], "answer received" + (", " + what if what else ""),
          "The owner's answer was recorded: %s" % c["html_url"])
    flush(a, rs)
    return what


def home_units(a):
    """{issue number: [tasks]} for the units whose home issue is recorded."""
    out = {}
    for n in nodes(a.state):
        if n.startswith("PR #") and not pr_node(a.state, n):
            continue
        try:
            d = tdir(a.state, pr_node(a.state, n) or n)
            out.setdefault(int(open(os.path.join(d, "issue")).read().split()[0]), []).append(n)
        except (OSError, ValueError, IndexError):
            pass
    return out


def finished(a, n):
    """A unit nothing more is expected from: no question, no session and, for a node, merged without a follow-up
    in progress; a triage once it ended done. A new QUESTION.md makes it unfinished again."""
    if held(a, n) or has(a.state, n, "session.pid") or has(a.state, n, "FAILED"):
        return False
    if n.startswith("PR #"):  # a node-PR update: nothing more once it asks nothing
        return True
    if n.startswith("#"):  # done: its done line was seen (queued or posted)
        rs = getattr(a, "rs", None) or {}
        return any(k.startswith("done:") for k in rs.get("units", {}).get(n, {}).get("done", [])) or \
            any(m["task"] == n and m["key"].startswith("done:") for m in rs.get("pending", []))
    return is_merged(a.state, n)


def held(a, n):
    """A unit with an open or answered-but-unreleased question, or a follow-up in progress: its issue stays open."""
    return has(a.state, n, "QUESTION.md") or has(a.state, n, "FOLLOWUP")


ID_PREFIX = re.compile(r"\s*\**(PR #\d+|#\d+|[A-Z][0-9][0-9])\**\s*[:\-]")


def take_home_answers(a, rs, status_issue):
    """The owner's new comments on the units' home issues: the answer to the one open question there, with a +1;
    a reply only when none is open, or several are and the comment does not start with one's ID."""
    seen = rs.setdefault("home", {})
    for issue, tasks in sorted(home_units(a).items()):
        st = seen.get(str(issue))
        for rid in list((st or {}).get("react", [])):  # a failed +1 is retried even when the unit is finished
            try:
                gh("POST", "repos/%s/issues/comments/%s/reactions" % (a.repo, rid), {"content": "+1"})
                st["react"].remove(rid)
                a.save()
            except RuntimeError as e:
                a.errors.append(str(e))
        tasks = [t for t in tasks if not finished(a, t)]
        if issue == status_issue or not tasks:
            continue
        units = rs.get("units", {})
        floor = min([units[t]["first_at"] for t in tasks if units.get(t, {}).get("first_at")] or [""])
        try:
            since = (st or {}).get("since") or floor
            comments = gh("GET", "repos/%s/issues/%s/comments?per_page=100%s" %
                          (a.repo, issue, "&since=" + since if since else "")) or []
            if st is None:
                st = seen[str(issue)] = {"id": 0}
                if not floor:  # nothing of ours was posted there yet: do not replay
                    st["id"] = max([c["id"] for c in comments] or [0])
                    a.save()
                    continue
            for c in sorted(comments, key=lambda c: c["id"]):
                if c["id"] <= st["id"]:
                    continue
                user = c.get("user") or {}
                text = c.get("body") or ""
                if (user.get("type") != "Bot" and user.get("login") == a.owner and c.get("author_association") == "OWNER"
                        and c.get("created_at", "") > floor):
                    pending = [t for t in tasks if t in waiting(a.state)]
                    opened = [t for t in pending if (units.get(t, {}).get("qc") or {}).get("key") ==
                              "question:" + mtime_key(os.path.join(tdir(a.state, t), "QUESTION.md"))]
                    def after(t):  # posted after the unit's question: by comment id when known, else by time
                        qc = units[t]["qc"]
                        return c["id"] > qc["id"] if isinstance(qc.get("id"), int) else (qc.get("at") or "") < c["created_at"]
                    cands = [t for t in opened if after(t)]
                    m = ID_PREFIX.match(text)
                    if not pending:
                        comment(a, issue, "Not recorded as an answer: no question is waiting on this issue.")
                    elif len(cands) > 1 and not (m and m.group(1) in cands):
                        comment(a, issue, "Not recorded as an answer: more than one unit is waiting on this issue (%s). "
                                "Start the reply with the ID of the one you answer, e.g. `%s: ...`." %
                                (", ".join(cands), cands[0]))
                    elif cands and m and m.group(1) in nodes(a.state) and m.group(1) not in cands:
                        comment(a, issue, "Not recorded as an answer: %s has no question waiting on this issue (waiting here: %s)." %
                                (m.group(1), ", ".join(cands)))
                    elif cands:
                        node = m.group(1) if m and m.group(1) in cands else cands[0]
                        record_answer(a, rs, node, c, text)
                        try:
                            gh("POST", "repos/%s/issues/comments/%s/reactions" % (a.repo, c["id"]), {"content": "+1"})
                        except RuntimeError as e:
                            a.errors.append(str(e))
                            st.setdefault("react", []).append(c["id"])  # retried on the next run
                st["id"], st["since"] = c["id"], c.get("created_at", "")
                a.save()
        except Exception as e:  # retried on the next run, from this comment on
            a.errors.append(str(e))


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
        m = ID_PREFIX.match(text)
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
        what = record_answer(a, rs, node, c, text)
        if node.startswith("#"):
            comment(a, issue, "Recorded as %s's ANSWER.md." % node)
        else:
            comment(a, issue, "Recorded as %s's ANSWER.md; %s." % (node, (node + " " + what) if what == "resumes within seconds" else what))


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
        out = []
        for l in lines:  # a session's end: its total cost on its own line
            stamp, what = event_text(l)
            m = re.search(r"session ([A-Z][0-9][0-9]) ended|triage of (#\d+) (?:ended|done)|update of (PR #\d+) ended", what)
            task = m and (m.group(1) or m.group(2) or m.group(3))
            ct = task and cost_turns(os.path.join(tdir(a.state, task), "session.jsonl"))
            out.append("- `%s` %s" % (stamp, what) + (" (total $%.2f, %d turns)" % ct if ct else ""))
        text = "\n".join(out)
        comment(a, issue, text)
    rs["log_offset"] = off + end


def post_questions(a, rs, issue):
    posted = rs.setdefault("questions", {})
    for n in waiting(a.state):
        if n.startswith("PR #") and not pr_node(a.state, n):
            continue
        q = os.path.join(tdir(a.state, n), "QUESTION.md")
        key = mtime_key(q)
        if posted.get(n) == key and ("question:" + key) in rs.get("units", {}).get(n, {}).get("done", []):
            continue
        try:
            home = home_issue(a, rs, n)
            if ("question:" + key) not in rs.get("units", {}).get(n, {}).get("done", []):
                reopen(a, rs, home)
            if posted.get(n) != key and pr_node(a.state, n):
                posted[n] = key  # a node-PR update's question is only on its node's issue
            elif posted.get(n) != key:
                comment(a, issue, "## %s asks\n\nThe question is on #%d, the unit's issue; answer it there, or here "
                        "starting the reply with `%s:`.\n" % (n, home, n))
                posted[n] = key
                rs.setdefault("qissue", {})[n] = issue  # where it was posted: an answer on a closed old issue counts only there
            milestone(a, rs, n, "question:" + key, "%s asks a question, waiting for your answer" % n,
                      "## %s asks\n\n%s\n\n---\nTo answer, reply to this issue in plain words. Only %s's replies count.\n" %
                      (n, open(q).read().strip(), a.owner))
        except Exception as e:
            a.errors.append(str(e))


def pr_link(pr):
    return pr.get("html_url") or "#%s" % pr.get("number")


def tsv(a, name):
    return [l.split() for l in read_lines(os.path.join(a.state, name))]


def merged_numbers(a):
    """{node: [merged PR numbers]} from merged-prs.tsv."""
    out = {}
    for w in tsv(a, "merged-prs.tsv"):
        m = len(w) > 1 and w[0].isdigit() and re.match(r"node/([A-Z][0-9][0-9])-", w[1])
        if m:
            out.setdefault(m.group(1), []).append(int(w[0]))
    return out


def subject_numbers(a):
    """{node: PR number or None} for the nodes whose squash subject is in subjects.txt (the number from a trailing "(#N)")."""
    subjects = read_lines(os.path.join(a.state, "subjects.txt"))
    out = {}
    for n in graph_nodes(a.state):
        for s in subjects:
            if s.startswith("%s %s:" % (n["id"], n["name"])):
                m = re.search(r"\(#(\d+)\)\s*$", s)
                out[n["id"]] = int(m.group(1)) if m else out.get(n["id"])
                if m:
                    break
    return out


def merges_unknown(a):
    """True when merged-prs.tsv is empty although merges are known: from the subjects, or from a merged PR in closed-prs.tsv
    (a list made after it in the same tick, so left from an earlier one): the loop's gh pr list failed this tick."""
    if tsv(a, "merged-prs.tsv"):
        return False
    return any(len(w) > 3 and w[3] == "true" for w in tsv(a, "closed-prs.tsv")) or \
        bool(merged_ids(a.state, graph_nodes(a.state)))


def closed_unknown(a):
    """True when closed-prs.tsv is empty although merges are known (it lists the merged PRs too): its gh pr list failed."""
    return not tsv(a, "closed-prs.tsv") and bool(merged_ids(a.state, graph_nodes(a.state)))


def pr_events(a, rs=None):
    """[(node, key, kind, PR number or None)] for the merged and closed-without-merging PRs the loop recorded."""
    out, seen = [], set()
    unknown = merges_unknown(a)
    if not unknown:
        for node, nums in sorted(merged_numbers(a).items()):
            seen.add(node)
            out += [(node, "merged:%d" % n, "merged", n) for n in sorted(nums)]
        subj = subject_numbers(a)
        for node in sorted(merged_ids(a.state, graph_nodes(a.state)) - seen):  # merged by squash subject only
            done = ((rs or {}).get("units", {}).get(node, {}) or {}).get("done", [])
            n = subj.get(node)
            if n:
                if "merged" in done:
                    continue
                out.append((node, "merged:%d" % n, "merged", n))
            elif not any(k == "merged" or k.startswith("merged:") for k in done):
                out.append((node, "merged", "merged", None))
    for w in tsv(a, "closed-prs.tsv"):
        m = len(w) > 3 and w[0].isdigit() and w[3] == "false" and re.match(r"node/([A-Z][0-9][0-9])-", w[1])
        if m:
            out.append((m.group(1), "closed:%s" % w[0], "closed", int(w[0])))
    return out


def resolves_map(a):
    """{node: [issue numbers on its Resolves line]} for every node spec on origin/main of the clone."""
    out = {}
    for l in git_lines(a.clone, "grep", "--no-color", "-e", r"^\*\*Resolves:\*\*", "origin/main", "--", "nodes/"):
        m = re.match(r"origin/main:nodes/([A-Z][0-9][0-9])-[^:]*\.md:(.*)$", l)
        if m and m.group(1) not in out:
            out[m.group(1)] = [int(x) for x in re.findall(r"#(\d+)", m.group(2))]
    return out


def closing_candidates(a, rs):
    """({issue: [merged nodes it is a candidate of]}, resolves map): the home issue and Resolves issues of the merged nodes."""
    merged = merged_ids(a.state, graph_nodes(a.state))
    mine = [n for n in nodes(a.state) if NODE.match(n) and n in merged]
    if not mine:
        return {}, {}
    res = resolves_map(a)
    homes = {n: i for i, ts in home_units(a).items() for n in ts}
    out = {}
    for n in mine:
        for i in set(res.get(n, [])) | ({homes[n]} if n in homes else set()):
            out.setdefault(i, []).append(n)
    return out, res


def reopen(a, rs, issue):
    """Make a unit's home issue open for its new question (closed by the loop, or by someone else)."""
    if gh("GET", "repos/%s/issues/%s" % (a.repo, issue)).get("state") == "closed":
        gh("PATCH", "repos/%s/issues/%s" % (a.repo, issue), {"state": "open"})
    if (rs.get("closed") or {}).pop(str(issue), None) is not None:
        a.save()


def closable(a, issue, res, merged, homed):
    """True when every node resolving the issue is merged and no unit of it (a resolver or one homed there) holds it."""
    units = homed.get(issue, [])
    resolvers = {k for k, iss in res.items() if issue in iss} | {t for t in units if NODE.match(t)}
    return resolvers <= merged and not any(held(a, t) for t in resolvers | set(units))


def close_issues(a, rs):
    """Close the home issue and Resolves issues of the merged nodes, each with one comment naming the PR(s), once every node
    resolving the issue is merged and no unit holds it open; the first run after that holds."""
    if not rs.get("close_seed") or merges_unknown(a) or not git_lines(a.clone, "rev-parse", "--verify", "-q", "origin/main"):
        return  # not yet seeded, or the specs cannot be read (a Resolves issue could be closed too early)
    cands, res = closing_candidates(a, rs)
    if not cands:
        return
    merged = merged_ids(a.state, graph_nodes(a.state))
    nums, subj = merged_numbers(a), subject_numbers(a)
    closed = rs.setdefault("closed", {})
    homed = home_units(a)
    for issue in sorted(cands):
        c = closed.get(str(issue)) or {}
        if c.get("closed"):
            continue
        if not closable(a, issue, res, merged, homed):
            continue
        resolvers = {k for k, iss in res.items() if issue in iss} | {t for t in homed.get(issue, []) if NODE.match(t)}
        try:
            if not c.get("commented") and gh("GET", "repos/%s/issues/%s" % (a.repo, issue)).get("state") == "closed":
                closed[str(issue)] = {"closed": True, "by_other": True}  # closed by someone already: left as they closed it
                a.save()
                continue
            if not c.get("commented"):
                prs = sorted({n for k in resolvers for n in nums.get(k) or ([subj[k]] if subj.get(k) else [])})
                what = ", ".join("PR #%d" % n for n in prs) if prs else "the node's PR"
                comment(a, issue, "**Stage:** merged, closing this issue\n\nMerged: %s. Closing this issue." % what)
                c = closed[str(issue)] = {"commented": True}
                a.save()
            gh("PATCH", "repos/%s/issues/%s" % (a.repo, issue), {"state": "closed", "state_reason": "completed"})
            c["closed"] = True
            a.save()
        except Exception as e:
            a.errors.append(str(e))


def seed_closing(a, rs):
    """Record the issues closable now whose merged nodes were all merged at the merge seed (before this bookkeeping) as
    closed, so the loop leaves them alone; only once origin/main of the clone is readable, else a Resolves issue would be
    missed. An issue of a node merged since is left to the rule."""
    if rs.get("close_seed") or rs.get("merge_seed") is None or merges_unknown(a):
        return
    if not git_lines(a.clone, "rev-parse", "--verify", "-q", "origin/main"):
        return
    try:
        closed = rs.setdefault("closed", {})
        cands, res = closing_candidates(a, rs)
        merged, homed = merged_ids(a.state, graph_nodes(a.state)), home_units(a)
        before = set(rs["merge_seed"])
        for i in cands:
            if set(cands[i]) <= before and closable(a, i, res, merged, homed):
                closed.setdefault(str(i), {"seed": True, "closed": True})
        rs["close_seed"] = True
    except Exception as e:
        a.errors.append(str(e))


def seed_events(a, rs, done_of):
    """Record the merged and the closed-without-merging PRs already there as seen, each list once it is known (a failed
    gh pr list leaves its file empty: seeding then would replay all of it later). A PR recorded open since the PR seed
    ("pr:N") was merged or closed after it: it is not seeded, and its milestone is posted."""
    if rs.get("merge_seed") is None and not merges_unknown(a):
        new = set()
        for t, key, kind, n in pr_events(a):
            if kind != "merged":
                continue
            if n and "pr:%d" % n in done_of(t):
                new.add(t)
            elif key not in done_of(t):
                done_of(t).append(key)
        rs["merge_seed"] = sorted(merged_ids(a.state, graph_nodes(a.state)) - new)
        a.save()
    if not rs.get("closedpr_seed") and not closed_unknown(a):
        for t, key, kind, n in pr_events(a):
            if kind == "closed" and "pr:%d" % n not in done_of(t) and key not in done_of(t):
                done_of(t).append(key)
        rs["closedpr_seed"] = True
        a.save()


def post_prs(a, rs, pulls):
    """Milestones from the PRs: opened, the CI result per head commit, each fresh review's verdict (open node PRs), and
    merged / closed without merging (from the loop's state files). The first run with this bookkeeping only records
    what is already there (the merged and the closed PRs each at the first run their list is readable)."""
    tasks = set(nodes(a.state))
    units = rs.setdefault("units", {})

    def done_of(t):
        return units.setdefault(t, {}).setdefault("done", [])

    def node_prs():
        for pr in pulls:
            m = re.match(r"node/([A-Z][0-9][0-9])-", (pr.get("head") or {}).get("ref") or "")
            if m and pr.get("number"):
                yield m.group(1), pr

    def comments_of(pr, every=False):
        """The PR's comments since the cursor (every page on the seed run), in order."""
        since = (rs.get("pr_since") or {}).get(str(pr["number"]))
        out, page = [], 1
        while True:
            got = gh("GET", "repos/%s/issues/%s/comments?per_page=100&page=%d%s" %
                     (a.repo, pr["number"], page, "&since=" + since if since else "")) or []
            out += got
            if not every or len(got) < 100 or page >= 50:
                break
            page += 1
        return sorted(out, key=lambda c: c["id"])

    def verdict(c):  # a quoted line ("> Fresh review (...)") is not a verdict
        m = re.match(r"[^\w>]*Fresh review \((\w+)\)", c.get("body") or "")
        return m and m.group(1)

    if not rs.get("pr_seed"):  # the open PRs already there
        try:
            for t, pr in node_prs():
                keys = ["pr:%s" % pr["number"]] + (["ci:%s" % pr["head"]["sha"]] if (pr.get("head") or {}).get("sha") else [])
                cs = comments_of(pr, True)
                keys += ["review:%s" % c["id"] for c in cs if verdict(c)]
                if cs:
                    rs.setdefault("pr_since", {})[str(pr["number"])] = max(c.get("created_at", "") for c in cs)
                done_of(t).extend(k for k in keys if k not in done_of(t))
            rs["pr_seed"] = True
        except Exception as e:
            a.errors.append(str(e))
        else:
            seed_events(a, rs, done_of)
            seed_closing(a, rs)
        a.save()
        return
    seed_events(a, rs, done_of)
    seed_closing(a, rs)

    def post(t, key, stage, body=""):
        try:
            milestone(a, rs, t, key, stage, body)
        except Exception as e:
            a.errors.append(str(e))

    for t, pr in node_prs():
        if t not in tasks:
            continue
        n = pr["number"]
        post(t, "pr:%s" % n, "PR #%s open, final review running" % n, "The pull request: %s" % pr_link(pr))
        sha = (pr.get("head") or {}).get("sha")
        if sha and "ci:" + sha not in done_of(t) and sha not in rs.get("ci_off", []):
            try:
                runs = (gh("GET", "repos/%s/commits/%s/check-runs?per_page=100" % (a.repo, sha)) or {}).get("check_runs") or []
                if runs and all(r.get("status") == "completed" for r in runs):
                    bad = [r.get("name") or "?" for r in runs if r.get("conclusion") not in ("success", "neutral", "skipped")]
                    if bad:
                        post(t, "ci:" + sha, "PR #%s: CI failed" % n,
                             "Failing checks on %s: %s." % (sha[:7], ", ".join(bad)))
                    else:
                        post(t, "ci:" + sha, "PR #%s: CI passed" % n, "All %d checks on %s passed." % (len(runs), sha[:7]))
            except Exception as e:
                if re.search(r"\(HTTP (403|404)\)", str(e)) and "rate limit" not in str(e).lower():  # check runs not readable for this commit: log once, stop asking
                    rs.setdefault("ci_off", []).append(sha)
                    print("report.py: no CI result for %s: %s" % (sha[:7], e), file=sys.stderr)
                else:
                    a.errors.append(str(e))
        try:
            for c in comments_of(pr):
                v = verdict(c)
                if v:
                    post(t, "review:%s" % c["id"], "PR #%s: fresh review (%s)" % (n, v),
                         "Verdict: %s%s" % (v, " (%s)" % c["html_url"] if c.get("html_url") else ""))
                    if "review:%s" % c["id"] not in done_of(t):
                        break  # its post failed: read from this comment again next run
                rs.setdefault("pr_since", {})[str(n)] = c.get("created_at", "")
        except Exception as e:
            a.errors.append(str(e))
    for t, key, kind, n in pr_events(a, rs):
        if t not in tasks or (rs.get("merge_seed") is None if kind == "merged" else not rs.get("closedpr_seed")):
            continue  # its list is not seeded yet: what is in it may be from before
        pr = "PR #%d" % n if n else "the node's PR"
        if kind == "merged":
            post(t, key, "%s merged" % pr, "%s was merged into the main branch." % pr)
        else:
            post(t, key, "%s closed without merging" % pr, "%s was closed without merging." % pr)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--repo", required=True)
    p.add_argument("--state", required=True)
    p.add_argument("--worktrees", default="")
    p.add_argument("--owner", default="")
    p.add_argument("--clone", default="")
    p.add_argument("--version", default="")
    p.add_argument("--signature", default="")
    a = p.parse_args()
    a.answered = False
    a.owner = a.owner or a.repo.split("/")[0]
    a.worktrees = a.worktrees or os.path.join(
        os.environ.get("NOODLEBOT_DATA") or os.path.join(os.path.expanduser("~"), ".local", "share", "noodlebot"),
        "worktrees", a.repo.split("/")[1])
    a.worktrees = os.path.abspath(a.worktrees)
    a.clone = a.clone or os.path.join(os.path.dirname(os.path.dirname(a.worktrees)), "repos", os.path.basename(a.worktrees))
    class Errors(list):
        def append(self, e):  # logged as it happens, so a later crash cannot lose it
            print("report.py: %s" % e, file=sys.stderr)
            super().append(e)

    a.errors = Errors()
    path = os.path.join(a.state, "report.json")
    try:
        rs = json.load(open(path))
    except (OSError, ValueError):
        rs = {}

    def save():
        with open(path + ".tmp", "w") as f:
            json.dump(rs, f, indent=1)
        os.replace(path + ".tmp", path)

    a.save = save
    a.first_run = not rs  # no (readable) report.json: what is on disk now was seen, not new
    a.today = now().strftime("%Y-%m-%d")
    if rs and "units" not in rs:
        migrate(a, rs)
    rs.setdefault("units", {})
    if "qissue" not in rs:  # questions posted before this was recorded were posted on the issue then in use
        rs["qissue"] = {n: rs["issue"] for n in rs.get("questions") or {}} if rs.get("issue") else {}
    a.rs = rs
    a.pulls, pulls_err, a.pulls_ok = [], None, True
    try:
        a.pulls = gh("GET", "repos/%s/pulls?state=open&per_page=100" % a.repo) or []
    except Exception as e:  # raised after the work below, as before
        pulls_err, a.pulls_ok = e, False
    keep = (now() - timedelta(days=4)).strftime("%Y-%m-%d")
    opened = {k: d for k, d in (rs.get("pr_opened") or {}).items() if d >= keep}
    for pr in a.pulls:
        d = local_date(pr.get("created_at") or "")
        if d and pr.get("number"):
            opened[str(pr["number"])] = d
    if opened != rs.get("pr_opened", {}):
        rs["pr_opened"] = opened
        save()
    try:
        rollover(a, rs)
    except Exception as e:  # the rest of the run does not depend on it; its record makes the next run finish it
        a.errors.append(str(e))
    was = rs.get("issue") if rs.get("issue") == (rs.get("log") or {}).get("issue") else None
    issue, new = find_issue(a, rs)
    if was and was != issue:  # an earlier log issue: its answers still count while their question is open there
        rs.setdefault("old_logs", {})[str(was)] = {"cursor": rs.get("comment_id", 0), "since": rs.get("comment_since", "")}
    if new or rs.get("issue") != issue:
        rs["issue"] = issue
        rs.pop("body_hash", None)
        if "comment_id" not in rs:  # first run ever: do not replay old comments
            old = gh("GET", "repos/%s/issues/%s/comments?per_page=100" % (a.repo, issue)) or []
            rs["comment_id"] = max([c["id"] for c in old] or [0])
        save()
    for step in (finish_roll, run_pins):
        try:
            step(a, rs)
        except Exception as e:
            a.errors.append(str(e))
    try:
        close_old_status(a, rs, issue)
    except Exception as e:
        a.errors.append(str(e))
    prs = {}
    for pr in a.pulls:
        m = re.match(r"node/([A-Z][0-9][0-9])-", pr["head"]["ref"])
        if m:
            prs[m.group(1)] = pr["number"]
    try:
        if not rs["log"].get("overview"):  # before any other comment on the issue; a failure ends the run, the next retries
            post_overview(a, rs, issue, prs)
        take_answers(a, rs, issue)
        take_home_answers(a, rs, issue)
        take_old_answers(a, rs)
        post_events(a, rs, issue)
        collect_starts(a, rs)
        flush(a, rs)
        post_failed(a, rs)
        if merges_unknown(a):  # logged once per spell; the run still succeeds
            if not rs.get("merges_unknown"):
                print("report.py: merged-prs.tsv is empty although merges are known (its gh pr list failed?): no merged "
                      "milestone, seeding or closing until it is filled", file=sys.stderr)
                rs["merges_unknown"] = True
        else:
            rs.pop("merges_unknown", None)
        if pulls_err is None:
            post_prs(a, rs, a.pulls)
        post_questions(a, rs, issue)
        close_issues(a, rs)
    finally:
        save()
    if pulls_err is not None:
        raise pulls_err
    try:
        body = body_for(a, sessions(a.state), prs, rs)
    except Exception as e:  # show the failure on the issue rather than leave it silently stale
        body = ("# noodlebot log %s: %s\n\n_Updated %s. The scheduler loop is running, but building this "
                "status failed: `%s`. See report.log._\n" % (a.today, a.repo, local(), str(e)[:300]))
        if a.version:
            body = body.replace("log %s: %s\n" % (a.today, a.repo), "log %s: %s (noodlebot %s)\n" % (a.today, a.repo, a.version), 1)
        print("report.py: status body failed: %s" % e, file=sys.stderr)
    body = signed(a, body)
    h = hashlib.sha256(re.sub(r"_Updated .*?_", "", body).encode()).hexdigest()
    if h != rs.get("body_hash") or time.time() - rs.get("body_time", 0) >= 900:
        gh("PATCH", "repos/%s/issues/%s" % (a.repo, issue), {"body": body})
        rs["body_hash"], rs["body_time"] = h, time.time()
        save()
    return 3 if a.answered else (1 if a.errors else 0)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # one line for the loop's log; the next run retries
        print("report.py: %s" % e, file=sys.stderr)
        sys.exit(1)
