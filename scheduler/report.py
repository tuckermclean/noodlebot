#!/usr/bin/env python3
"""Mirror one repository's scheduler state to a GitHub status issue, and take the owner's answers from it.

  report.py --repo OWNER/NAME --state DIR [--worktrees DIR] [--clone DIR] [--owner LOGIN]

Run by loop.sh after each tick with GH_TOKEN set; exits 3 when it wrote an ANSWER.md; PyYAML is used when present (the graph is optional), all GitHub access through `gh api`.
Each run:
  1. finds the open issue labelled `noodlebot-status` (creating the label and issue if there is none,
     e.g. after the owner closed it), and remembers its number in DIR/report.json;
  2. turns each new comment by the owner on that issue into ANSWER.md for the unit waiting on a
     question (the only one waiting, or the one named first: "B03: ..."), and replies; likewise each new
     owner comment on a unit's home issue, posted after the unit's question comment (no ID needed when one
     question is open there; it gets a +1 and the answer-received milestone, no reply). It replies only when no
     question is open there, or several are and the comment starts with none of their IDs. A question answered
     on one issue is not answered again from the other;
  3. posts new status.log events (starts, ends, releases, merges, FAILED) as one comment;
  4. posts each new unanswered QUESTION.md once: a short `## <ID> asks` pointer on the status issue (its
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
  6. rewrites the issue body: what waits on the owner, every running session and its latest narration,
     recent events. Body edits do not notify; comments do.
On the first run it does not replay old comments or events. Any failure (a failed milestone post included,
after the other work is done) exits non-zero; the loop logs it and carries on, and the next run picks up
where this one stopped.
"""
import argparse, hashlib, json, math, os, re, subprocess, sys, time
from datetime import datetime, timezone

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
    """The tasks with a state directory: nodes ("B03", node/B03) and triaged issues ("#46", issue/46) and spec-PR updates ("PR #12", pr/12)."""
    out = []
    for kind, pat, fmt in (("node", NODE, "%s"), ("issue", re.compile(r"^\d+$"), "#%s"),
                         ("pr", re.compile(r"^\d+$"), "PR #%s")):
        d = os.path.join(state, kind)
        if os.path.isdir(d):
            out += [fmt % n for n in sorted(os.listdir(d)) if pat.match(n) and os.path.isdir(os.path.join(d, n))]
    return out


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


def body_for(a, sts, prs, rs=None):
    state = a.state
    rs = rs or {}
    out = ["# noodlebot status: %s" % a.repo, "",
           "_Updated %s by the scheduler loop (within a minute of a change; when nothing changes, every 15 minutes). If this is more than ~20 minutes old, "
           "the loop is not running._" % local(), ""] + usage_lines(state) + ["## Waiting on you"]
    items = []
    for n in nodes(state):
        if has(state, n, "FAILED"):
            path = os.path.join(tdir(state, n), "FAILED")
            with open(path, errors="replace") as fh:
                why = fh.readline().strip() or "no reason given"
            items.append("- **%s FAILED**: %s. To retry, delete `%s`." % (n, why, path))
        elif has(state, n, "QUESTION.md") and has(state, n, "ANSWER.md"):
            items.append("- %s: %s." % (n, answered_text(state, n) if n in nodes(state) and not n.startswith("#") else "answered"))
        elif has(state, n, "QUESTION.md") and not n.startswith("#") and is_merged(state, n):
            items.append("- **%s's PR is merged; its question is still open, and an answer starts a follow-up** "
                         "(%s)." % (n, question_link(a, rs, n)))
        elif has(state, n, "QUESTION.md"):
            items.append("- **%s asks a question** (%s)." % (n, question_link(a, rs, n)))
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
        commits = [] if "#" in n else git_lines(os.path.join(a.worktrees, n), "log", "--oneline",
                                                         "-3" if many else "-8", "origin/main..HEAD")
        if commits:
            out += ["", "Latest commits:", ""] + ["- `%s`" % c for c in commits]
    if not sts:
        out.append("No session running.")

    events = [l for l in tail_lines(os.path.join(state, "status.log"), 64 << 10) if EVENT.search(event_text(l)[1])]
    out += ["", "## Recent events", ""]
    out += ["- `%s` %s" % event_text(l) for l in events[-10:]] or ["- none yet"]
    out += ["", "---", "Answer a question on the unit's issue (the link is in its item above) in plain words (e.g. "
            "\"Q1 approve, Q2 as recommended\"). Only %s's replies count; if more than one unit on that issue is "
            "waiting, start with its ID or issue number. A reply here still works if it starts with the ID "
            "prefix, e.g. `B03: ...` or `#46: ...`. Hand an issue to the bot by adding the `noodlebot` label "
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
                    "body": "Home of node %s: the scheduler loop posts its milestones here (start, questions, PR, CI, "
                            "result). Its spec is %s on the main branch. The loop closes this issue once the node is "
                            "merged." % (task, spec)})["number"]
    with open(f + ".tmp", "w") as fh:
        fh.write("%d\n" % n)
    os.replace(f + ".tmp", f)
    return n


def milestone(a, rs, task, key, stage, body=""):
    """Post one milestone comment on the unit's home issue, once per key (recorded in report.json after the post)."""
    if task.startswith("PR #"):  # a spec-PR update is not a unit: no issue
        return
    u = rs.setdefault("units", {}).setdefault(task, {})
    done = u.setdefault("done", [])
    if key in done:
        return
    issue = home_issue(a, rs, task)
    text = "**Stage:** " + stage
    if not u.get("intro") and not task.startswith("#"):
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
    what = None if node.startswith("#") else answered_text(a.state, node)
    queue(a, rs, node, "answer:%s" % c["id"], "answer received" + (", " + what if what else ""),
          "The owner's answer was recorded: %s" % c["html_url"])
    flush(a, rs)
    return what


def home_units(a):
    """{issue number: [tasks]} for the units whose home issue is recorded."""
    out = {}
    for n in nodes(a.state):
        if n.startswith("PR #"):
            continue
        try:
            out.setdefault(int(open(os.path.join(tdir(a.state, n), "issue")).read().split()[0]), []).append(n)
        except (OSError, ValueError, IndexError):
            pass
    return out


def finished(a, n):
    """A unit nothing more is expected from: no question, no session and, for a node, merged without a follow-up
    in progress; a triage with no question. A new QUESTION.md makes it unfinished again."""
    if has(a.state, n, "QUESTION.md") or has(a.state, n, "session.pid") or has(a.state, n, "FOLLOWUP"):
        return False
    return n.startswith("#") or is_merged(a.state, n)


ID_PREFIX = re.compile(r"\s*\**(#\d+|[A-Z][0-9][0-9])\**\s*[:\-]")


def take_home_answers(a, rs, status_issue):
    """The owner's new comments on the units' home issues: the answer to the one open question there, with a +1;
    a reply only when none is open, or several are and the comment does not start with one's ID."""
    seen = rs.setdefault("home", {})
    for issue, tasks in sorted(home_units(a).items()):
        tasks = [t for t in tasks if not finished(a, t)]
        if issue == status_issue or not tasks:
            continue
        units = rs.get("units", {})
        floor = min([units[t]["first_at"] for t in tasks if units.get(t, {}).get("first_at")] or [""])
        st = seen.get(str(issue))
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
            for rid in list(st.get("react", [])):
                try:
                    gh("POST", "repos/%s/issues/comments/%s/reactions" % (a.repo, rid), {"content": "+1"})
                    st["react"].remove(rid)
                except RuntimeError as e:
                    a.errors.append(str(e))
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
                    cands = [t for t in opened if (units[t]["qc"].get("at") or "") < c["created_at"]]
                    m = ID_PREFIX.match(text)
                    if not pending:
                        comment(a, issue, "Not recorded as an answer: no question is waiting on this issue.")
                    elif len(cands) > 1 and not (m and m.group(1) in cands):
                        comment(a, issue, "Not recorded as an answer: more than one unit is waiting on this issue (%s). "
                                "Start the reply with the ID of the one you answer, e.g. `%s: ...`." %
                                (", ".join(cands), cands[0]))
                    elif cands and m and m.group(1) in nodes(a.state) and m.group(1) not in cands:
                        comment(a, issue, "Not recorded as an answer: %s is not waiting on a question (waiting: %s)." %
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
        text = "\n".join("- `%s` %s" % event_text(l) for l in lines)
        for l in lines:  # a session's end: add its own closing summary
            m = re.search(r"session ([A-Z][0-9][0-9]) ended|triage of (#\d+) (?:ended|done)|update of (PR #\d+) ended", event_text(l)[1])
            task = m and (m.group(1) or m.group(2) or m.group(3))
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
        if n.startswith("PR #"):
            continue
        q = os.path.join(tdir(a.state, n), "QUESTION.md")
        key = mtime_key(q)
        if posted.get(n) == key and ("question:" + key) in rs.get("units", {}).get(n, {}).get("done", []):
            continue
        try:
            home = home_issue(a, rs, n)
            if posted.get(n) != key:
                comment(a, issue, "## %s asks\n\nThe question is on #%d, the unit's issue; answer it there, or here "
                        "starting the reply with `%s:`.\n" % (n, home, n))
                posted[n] = key
            milestone(a, rs, n, "question:" + key, "%s asks a question, waiting for your answer" % n,
                      "## %s asks\n\n%s\n\n---\nTo answer, reply to this issue in plain words. Only %s's replies count.\n" %
                      (n, open(q).read().strip(), a.owner))
        except Exception as e:
            a.errors.append(str(e))


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--repo", required=True)
    p.add_argument("--state", required=True)
    p.add_argument("--worktrees", default="")
    p.add_argument("--owner", default="")
    p.add_argument("--clone", default="")
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
    if rs and "units" not in rs:
        migrate(a, rs)
    rs.setdefault("units", {})
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
        take_home_answers(a, rs, issue)
        post_events(a, rs, issue)
        collect_starts(a, rs)
        flush(a, rs)
        post_failed(a, rs)
        post_questions(a, rs, issue)
    finally:
        save()
    prs = {}
    for pr in gh("GET", "repos/%s/pulls?state=open&per_page=100" % a.repo) or []:
        m = re.match(r"node/([A-Z][0-9][0-9])-", pr["head"]["ref"])
        if m:
            prs[m.group(1)] = pr["number"]
    try:
        body = body_for(a, sessions(a.state), prs, rs)
    except Exception as e:  # show the failure on the issue rather than leave it silently stale
        body = ("# noodlebot status: %s\n\n_Updated %s. The scheduler loop is running, but building this "
                "status failed: `%s`. See report.log._\n" % (a.repo, local(), str(e)[:300]))
        print("report.py: status body failed: %s" % e, file=sys.stderr)
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
