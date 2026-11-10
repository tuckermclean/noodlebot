#!/usr/bin/env python3
"""The status site's data files, built from what the loops keep on the machine (no GitHub call).

  site.py build --data-root DIR --repos FILE --out DIR [--throttle LINE] [--now EPOCH]

Writes to --out (replacing its contents), as sorted-key JSON without spaces:
  repo.<owner>.<name>.json  one per listed repository whose state/<name>/visibility holds "public"
  throttle.json             the plan's windows, the throttle line, the five-hour history
  activity.json             the last 100 status-log events, the triage issues, the deploy record
scheduler/site-schema.json names every key and type. Fields are chosen by name, never dumped; every
string read from a file goes through text() (local paths and token-shaped strings removed), then the
length cuts apply. Node states: ready.py is run over the files the loop cached (never re-implemented),
a loop's lock is read from /proc/locks as loops.sh does. Session logs, session.stderr, environment
files, prompts and ~/.config/noodlebot/ (but for the --repos list) are never opened.
Exits 1 when the list is unreadable or --out is unwritable; a repository's own bad files give defaults.

  site.py publish --data-root DIR --repos FILE --gist ID [--throttle LINE] [--now EPOCH]
                  [--min-interval SECONDS] [--keepalive SECONDS]

Builds into DIR/site/out/ and sends what changed to the gist in one `gh api -X PATCH gists/ID --input
FILE` (GH_TOKEN is inherited from the environment, never an argument, output or file; gists are never
created). Changed files go as {"content": ...}, files no longer built as null, plus manifest.json:
{version (site-schema.json), updated (when the content last changed), seen (this publish), files
{name: sha256}}. DIR/site/published.json holds the last manifest sent, written (temp file and rename)
only after a 2xx answer. A change is sent at most every --min-interval seconds (60); with nothing
changed a manifest-only keepalive goes every --keepalive seconds (900). DIR/site/lock is held
non-blocking: a publish that finds it held does nothing and exits 0. A 404 or any other failed call
logs one line naming the status (never the response body) and exits 1, published.json untouched.
"""
import argparse
import collections
import fcntl
import hashlib
import json
import math
import os
import re
import subprocess
import sys
import time

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
URL = re.compile(r"https?://[^\s<>\"')\]]+")
PATH = re.compile(r"(?<![\w.~-])/[\w.@+-]+(?:/[\w.@+-]*)+")
TOKEN = re.compile(r"(?:ghp_|gho_|ghu_|ghs_|ghr_|github_pat_|sk-ant-)[\w-]*")
RUN = re.compile(r"[A-Za-z0-9+/]{40,}")
LOOP_PREFIX = re.compile(r"^open=\[[^\]]*\] merged-prs=\[[^\]]*\]; ")
DEPLOY = re.compile(r"(deployed|not deployed|rolled back)\b")
SAFE = re.compile(r"^[A-Za-z0-9][\w.-]*$")
HOLD = re.compile(r"hold:\s*")  # the throttle line's hold prefix
LOCAL = []  # literal strings (runtime root, HOME) the filter removes


def log(msg):
    print("site.py: " + msg, file=sys.stderr)


def text(s):
    """The one filter: local paths, the runtime root, HOME and token-shaped strings out; URLs kept."""
    out, pos = [], 0
    for lit in LOCAL:
        s = s.replace(lit, "…")
    for m in list(URL.finditer(s)) + [None]:
        end = m.start() if m else len(s)
        part = PATH.sub("…", s[pos:end])
        out.append(RUN.sub("[redacted]", TOKEN.sub("[redacted]", part)))
        if m:
            out.append(TOKEN.sub("[redacted]", m.group(0)))
            pos = m.end()
    return "".join(out)


def cut(s, n):
    return s[:n]


def read(path, limit=None):
    """The file's text, None when missing, unreadable or a symlink (never followed)."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, encoding="utf-8", errors="replace") as f:
            return f.read(limit) if limit else f.read()
    except OSError:
        return None


def first_line(path, n=300):
    """The filtered, cut first line of a file; None when it is missing."""
    s = read(path, 4000)
    if s is None:
        return None
    lines = s.splitlines()
    return cut(text(lines[0].strip()), n) if lines else ""


def jdump(obj):
    return (json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False) + "\n").encode("utf-8")


# ---- the loop's facts

def held(lockfile):
    """Some process holds a lock on the file, as /proc/locks shows it (as loops.sh held() reads it)."""
    try:
        st = os.stat(lockfile)
        with open("/proc/locks", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return False
    dev = "%d:%d" % (os.major(st.st_dev), os.minor(st.st_dev))
    mdev = None
    for line in lines:
        w = line.split()
        if len(w) < 6 or w[1] == "->":
            continue
        ldev, _, lino = w[5].rpartition(":")
        if lino != str(st.st_ino):
            continue
        try:
            a, b = ldev.split(":")
            ldev = "%d:%d" % (int(a, 16), int(b, 16))
        except ValueError:
            continue
        if ldev == dev:
            return True
        if mdev is None:
            try:
                r = subprocess.run(["findmnt", "-n", "-o", "MAJ:MIN", "-T", lockfile], capture_output=True, text=True)
                mdev = r.stdout.replace(" ", "").strip() or "none"
            except OSError:
                mdev = "none"
        if ldev == mdev:
            return True
    return False


def alive(pidfile, key):
    """The pid file's process exists and is that task's session (loop.sh alive())."""
    s = read(pidfile, 64)
    if s is None or not re.fullmatch(r"[0-9]+", s.strip()):
        return False
    try:
        pid = int(s.strip())
        os.kill(pid, 0)
        with open("/proc/%d/cmdline" % pid, "rb") as f:
            cmd = f.read().replace(b"\0", b" ").decode("utf-8", "replace")
    except (OSError, ValueError, OverflowError):
        return False
    k = re.escape(key)
    return bool(re.search(r"run-session\.sh .* %s( |$)|claude -p /node %s( |$)" % (k, k), cmd))


def git_show(clone, spec):
    try:
        r = subprocess.run(["git", "-C", clone, "show", spec], capture_output=True, text=True, errors="replace")
    except OSError:
        return None
    return r.stdout if r.returncode == 0 else None


def graph_nodes(src):
    try:
        nodes = yaml.safe_load(src)["nodes"]
    except Exception:  # noqa: BLE001 - a bad graph is an empty one
        return []
    out = []
    for n in nodes or []:
        if isinstance(n, dict) and isinstance(n.get("id"), str) and isinstance(n.get("name"), str):
            deps = n.get("deps") or []
            out.append({"id": n["id"], "name": n["name"], "track": str(n.get("track", "")),
                        "deps": [str(d) for d in deps] if isinstance(deps, list) else [],
                        "summary": str(n.get("summary", ""))})
    return out


def entry(n):
    return {"id": text(n["id"]), "name": text(n["name"]), "track": text(n["track"]),
            "deps": [text(d) for d in n["deps"]], "summary": cut(text(n["summary"]), 300)}


def rows(path):
    s = read(path)
    return [l.split(" ") for l in (s or "").splitlines() if l.strip()]


def spec_of(clone, n):
    """(size, criteria) of the node's spec on origin/main, or None when it has none."""
    src = git_show(clone, "origin/main:nodes/%s-%s.md" % (n["id"], n["name"]))
    if src is None:
        return None
    size, lines = None, src.splitlines()
    for i, l in enumerate(lines):
        if l.startswith("|---") and i + 1 < len(lines):
            cells = [c.strip() for c in lines[i + 1].strip().strip("|").split("|")]
            if len(cells) >= 4:
                size = cut(text(cells[3]), 300)
            break
    crit = []
    pat = re.compile(r"^- \*\*(%s-AC-\d+)\*\* — (.*)$" % re.escape(n["id"]))
    for l in lines:
        m = pat.match(l)
        if m:
            crit.append({"id": text(m.group(1)), "text": cut(text(m.group(2).strip()), 600)})
    return size, crit


def ready_ids(state, nodes, merged_ids, open_ids):
    """The IDs ready.py --all prints, run as loop.sh tick() runs it; empty when it fails."""
    g = os.path.join(state, "graph.yaml")
    cmd = [sys.executable, "-I", os.path.join(HERE, "ready.py"), "--graph", g, "--markers", os.path.join(state, "node")]
    for opt, f in (("--subjects", "subjects.txt"), ("--merged-prs", "merged-prs.txt")):
        if os.path.exists(os.path.join(state, f)):
            cmd += [opt, os.path.join(state, f)]
    cmd.append("--all")
    for i in sorted(merged_ids):
        cmd += ["--merged", i]
    for i in sorted(open_ids):
        cmd += ["--open", i]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True)
    except OSError as e:
        log("ready.py: %s" % e)
        return set()
    if r.returncode != 0:
        log("ready.py failed: %s" % r.stderr.strip()[:200])
        return set()
    return {l.split()[0] for l in r.stdout.splitlines() if l.split()}


def branch_id(branch):
    m = re.match(r"^node/([A-Z][0-9][0-9])-", branch)
    return m.group(1) if m else None


# ---- the repository file

def repo_file(root, repo, running, hold, home):
    owner, name = repo.split("/")
    state = os.path.join(root, "state", name)
    clone = os.path.join(root, "repos", name)
    nodes = graph_nodes(read(os.path.join(state, "graph.yaml")) or "")
    merged_rows = [(r[0], r[1]) for r in rows(os.path.join(state, "merged-prs.tsv")) if len(r) >= 2 and r[0].isdigit()]
    open_rows = [r for r in rows(os.path.join(state, "open-prs.tsv")) if len(r) >= 5 and r[0].isdigit()]
    subjects = (read(os.path.join(state, "subjects.txt")) or "").splitlines()
    merged_ids = {branch_id(b) for _, b in merged_rows} - {None}
    open_ids = {branch_id(r[1]) for r in open_rows} - {None}
    for n in nodes:
        if any(s.startswith("%s %s:" % (n["id"], n["name"])) for s in subjects):
            merged_ids.add(n["id"])
    ready = ready_ids(state, nodes, merged_ids, open_ids) if nodes else set()
    report = read(os.path.join(state, "report.json"))
    status_issue = None
    try:
        v = json.loads(report)["issue"]
        status_issue = v if isinstance(v, int) and not isinstance(v, bool) else None
    except Exception:  # noqa: BLE001
        pass

    out_nodes = []
    for n in nodes:
        i = n["id"]
        d = os.path.join(state, "node", i) if SAFE.match(i) else None
        has = (lambda m: d is not None and os.path.lexists(os.path.join(d, m)))  # noqa: E731
        o = {"id": text(i), "name": text(n["name"]), "track": text(n["track"]), "deps": [text(x) for x in n["deps"]],
             "unlocks": [text(m["id"]) for m in nodes if i in m["deps"]], "summary": cut(text(n["summary"]), 300),
             "size": None, "has_spec": False, "criteria": [], "starts": 0, "state": "waiting", "pr": None,
             "started": None, "text": None, "url": None, "mergeable": None, "waiting_for": []}
        sp = spec_of(clone, n) if SAFE.match(i) else None
        if sp is not None:
            o["has_spec"], (o["size"], o["criteria"]) = True, sp
        s = read(os.path.join(d, "starts"), 32) if d else None
        if s and s.strip().isdigit():
            o["starts"] = int(s.strip())
        if i in merged_ids:
            o["state"] = "merged"
            nums = [int(p) for p, b in merged_rows if b.startswith("node/%s-" % i)]
            if nums:
                o["pr"] = max(nums)
            else:
                for sub in subjects:
                    m = re.match(r"^%s %s:.*\(#(\d+)\)\s*$" % (re.escape(i), re.escape(n["name"])), sub)
                    if m:
                        o["pr"] = int(m.group(1))
                        break
        elif d and alive(os.path.join(d, "session.pid"), i):
            o["state"] = "running"
            try:
                o["started"] = int(os.stat(os.path.join(d, "session.pid")).st_mtime)
            except OSError:
                pass
        elif has("FAILED"):
            o["state"], o["text"] = "failed", first_line(os.path.join(d, "FAILED"))
        elif has("QUESTION.md") and not has("ANSWER.md"):
            o["state"], o["text"] = "question", first_line(os.path.join(d, "QUESTION.md"))
            home_issue = (read(os.path.join(d, "issue"), 200) or "").split()
            num = int(home_issue[0]) if home_issue and home_issue[0].isdigit() else status_issue
            if num is not None:
                o["url"] = "https://github.com/%s/%s/issues/%d" % (owner, name, num)
        elif has("QUESTION.md"):
            o["state"] = "answered"
        elif has("WAITING-PR"):
            o["state"] = "waiting-pr"
            w = (read(os.path.join(d, "WAITING-PR"), 32) or "").strip()
            o["pr"] = int(w) if w.isdigit() else None
        elif any(r[1].startswith("node/%s-" % i) for r in open_rows):
            r = next(r for r in open_rows if r[1].startswith("node/%s-" % i))
            o["state"], o["pr"], o["mergeable"] = "pr-open", int(r[0]), cut(text(r[4]), 60)
        elif i in ready:
            o["state"] = "held" if hold else "ready"
        else:
            o["waiting_for"] = [text(x) for x in n["deps"] if x not in merged_ids]
        out_nodes.append(o)

    open_prs = [{"number": int(r[0]), "branch": cut(text(r[1]), 300), "mergeable": cut(text(r[4]), 60), "bot": r[3] == "true"}
                for r in open_rows]
    spec_prs = []
    base = {n["id"]: n for n in graph_nodes(git_show(clone, "origin/main:docs/graph.yaml") or "")} or {n["id"]: n for n in nodes}
    for r in open_rows:
        if not r[1].startswith("spec/"):
            continue
        raw = git_show(clone, "origin/%s:docs/graph.yaml" % r[1])
        if raw is None:
            spec_prs.append({"number": int(r[0]), "branch": cut(text(r[1]), 300), "added": [], "changed": [], "removed": []})
            continue
        new = graph_nodes(raw)
        ids = {n["id"] for n in new}
        added = [entry(n) for n in new if n["id"] not in base]
        changed = []
        for n in new:
            b = base.get(n["id"])
            if b is None:
                continue
            diff = {k: (n[k] if n[k] != b[k] else None) for k in ("name", "track", "deps", "summary")}
            if any(v is not None for v in diff.values()):
                e = entry(n)
                changed.append({"id": e["id"], **{k: (e[k] if diff[k] is not None else None) for k in diff}})
        spec_prs.append({"number": int(r[0]), "branch": cut(text(r[1]), 300), "added": added, "changed": changed,
                         "removed": [text(i) for i in base if i not in ids]})
    stop = os.path.exists(os.path.join(home, "STOP")) or os.path.exists(os.path.join(home, "STOP-" + name))
    return {"repo": repo, "name": name, "running": running, "stop": stop, "nodes": out_nodes,
            "open_prs": open_prs, "spec_prs": spec_prs}


# ---- the throttle file

def thin(samples, n=60):
    if len(samples) <= n:
        return samples
    return [samples[round(k * (len(samples) - 1) / (n - 1))] for k in range(n)]


def throttle_file(root, line):
    usage = {}
    try:
        with open(os.path.join(root, "state", "usage.json"), encoding="utf-8") as f:
            usage = json.load(f)
        if not isinstance(usage, dict):
            usage = {}
    except (OSError, ValueError):
        pass
    num = lambda v: v if isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) else None  # noqa: E731
    integ = lambda v: int(v) if num(v) is not None else None  # noqa: E731
    wins = []
    w = usage.get("windows")
    for k in sorted(w) if isinstance(w, dict) else []:
        v = w[k]
        if isinstance(v, dict):
            st = v.get("status")
            wins.append({"name": text(str(k)), "utilization": num(v.get("utilization")), "resets_at": integ(v.get("resetsAt")),
                         "status": cut(text(st), 60) if isinstance(st, str) else None})
    samples = []
    sm = usage.get("samples5h")
    for s in sm if isinstance(sm, list) else []:
        if isinstance(s, list) and len(s) >= 2 and num(s[0]) is not None and num(s[1]) is not None:
            samples.append({"t": int(s[0]), "u": s[1]})
    is_held, reason = False, None
    if line is not None:
        m = HOLD.match(line)
        if m:
            is_held, reason = True, line[m.end():].strip()
        else:
            reason = line[6:] if line.startswith("open: ") else line
        reason = cut(text(reason), 300)
    return {"windows": wins, "updated": integ(usage.get("updated")), "held": is_held, "reason": reason,
            "history": thin(samples)}


# ---- the activity file

def tail_lines(path, n):
    """The last n lines of a file, reading from its end."""
    try:
        with open(path, "rb") as f:
            size = f.seek(0, 2)
            block, data = 65536, b""
            while True:
                start = max(0, size - len(data) - block)
                f.seek(start)
                data = f.read(size - start)
                if start == 0 or data.count(b"\n") > n:
                    break
                block *= 2
    except OSError:
        return []
    lines = data.decode("utf-8", "replace").splitlines()
    return lines[-n:]


def event(repo, line):
    t, _, rest = line.partition(" ")
    return {"time": cut(text(t), 40), "repo": repo, "text": cut(text(LOOP_PREFIX.sub("", rest)), 300)}


def triage(root, repo):
    owner, name = repo.split("/")
    base = os.path.join(root, "state", name, "issue")
    try:
        nums = sorted(int(d) for d in os.listdir(base) if d.isdigit() and os.path.isdir(os.path.join(base, d)))
    except OSError:
        return []
    out = []
    for n in nums:
        d = os.path.join(base, str(n))
        has = lambda m: os.path.lexists(os.path.join(d, m))  # noqa: E731
        state, txt = "idle", None
        if alive(os.path.join(d, "session.pid"), str(n)):
            state = "running"
        elif has("FAILED"):
            state, txt = "failed", first_line(os.path.join(d, "FAILED"))
        elif has("QUESTION.md") and not has("ANSWER.md"):
            state, txt = "question", first_line(os.path.join(d, "QUESTION.md"))
        elif has("QUESTION.md"):
            state = "answered"
        w = (read(os.path.join(d, "WAITING-PR"), 32) or "").strip()
        out.append({"repo": repo, "number": n, "url": "https://github.com/%s/%s/issues/%d" % (owner, name, n),
                    "state": state, "text": txt, "spec_pr": int(w) if w.isdigit() else None})
    return out


def activity_file(root, repos):
    events, deploys, tri, version = [], [], [], None
    for idx, repo in enumerate(repos):
        try:
            version = activity_repo(root, repo, idx, events, deploys, tri, version)
        except Exception as e:  # noqa: BLE001 - one repository's bad files give defaults
            log("%s: activity: %s: %s" % (repo, type(e).__name__, e))
    return finish_activity(root, events, deploys, tri, version)


def activity_repo(root, repo, idx, events, deploys, tri, version):
    name = repo.split("/")[1]
    state = os.path.join(root, "state", name)
    log_path = os.path.join(state, "status.log")
    for ln, line in enumerate(tail_lines(log_path, 100)):
        if line.strip():
            events.append(((line.partition(" ")[0], -idx, ln), event(repo, line)))
    mine = collections.deque(maxlen=10)
    try:  # the deploy events: the whole log, line by line
        with open(log_path, encoding="utf-8", errors="replace") as f:
            for ln, line in enumerate(f):
                line = line.rstrip("\n")
                if DEPLOY.match(LOOP_PREFIX.sub("", line.partition(" ")[2])):
                    mine.append(((line.partition(" ")[0], -idx, ln), event(repo, line)))
    except OSError:
        pass
    deploys += mine
    tri += triage(root, repo)
    if version is None:
        version = first_line(os.path.join(state, "version"))
    return version


def finish_activity(root, events, deploys, tri, version):
    events.sort(key=lambda e: e[0], reverse=True)
    dep = sorted(deploys, key=lambda e: e[0], reverse=True)[:10]
    prev = (read(os.path.join(root, "deploy", "previous"), 4000) or "").split("\n")[0].strip()
    rej = [l.strip()[:12] for l in (read(os.path.join(root, "deploy", "rejected")) or "").splitlines() if l.strip()]
    return {"events": [e for _, e in events[:100]], "triage": tri,
            "deploy": {"version": version, "previous": text(prev[:12]) if prev else None,
                       "rejected": [text(r) for r in rej], "events": [e for _, e in dep]}}


# ---- the command

def read_repos(path):
    try:
        with open(path, encoding="utf-8") as f:
            raw = f.read().splitlines()
    except OSError as e:
        log("cannot read the repository list: %s" % e)
        sys.exit(1)
    repos = []
    for line in raw:
        line = re.sub(r"\s+", "", line.split("#")[0])
        if re.fullmatch(r"[\w.-]+/[\w.-]+", line) and line not in repos:
            repos.append(line)
    return repos


def write_out(out, files):
    try:
        os.makedirs(out, exist_ok=True)
        for name, data in files.items():
            with open(os.path.join(out, name + ".tmp"), "wb") as f:
                f.write(data)
        for name in files:
            os.replace(os.path.join(out, name + ".tmp"), os.path.join(out, name))
        for e in os.listdir(out):
            p = os.path.join(out, e)
            if e not in files and (os.path.isfile(p) or os.path.islink(p)):
                os.unlink(p)
    except OSError as e:
        log("cannot write %s: %s" % (out, e))
        sys.exit(1)


def build(a):
    root = os.path.abspath(a.data_root)
    home = os.environ.get("HOME", "")
    for p in {root, os.path.realpath(root), home, os.path.realpath(home) if home else ""}:
        if len(p) > 1 and p not in LOCAL:
            LOCAL.append(p)
    LOCAL.sort(key=len, reverse=True)
    published = []
    for repo in read_repos(a.repos):
        v = read(os.path.join(root, "state", repo.split("/")[1], "visibility"), 64)
        if v is not None and v.strip() == "public":
            published.append(repo)
    throttle = a.throttle
    files = {}
    for repo in published:
        try:
            lock = os.path.join(root, "state", repo.split("/")[1], "loop.lock")
            data = repo_file(root, repo, held(lock), bool(throttle and HOLD.match(throttle)), home)
            files["repo.%s.%s.json" % tuple(repo.split("/"))] = jdump(data)
        except Exception as e:  # noqa: BLE001 - one repository's bad files do not stop the others
            log("%s: %s: %s" % (repo, type(e).__name__, e))
    try:
        files["throttle.json"] = jdump(throttle_file(root, throttle))
    except Exception as e:  # noqa: BLE001
        log("throttle.json: %s: %s" % (type(e).__name__, e))
        files["throttle.json"] = jdump({"windows": [], "updated": None, "held": False, "reason": None, "history": []})
    files["activity.json"] = jdump(activity_file(root, published))
    write_out(a.out, files)
    return files


# ---- publish

def gh_patch(gist, body_path):
    """One PATCH of the gist; None on a 2xx answer, else the one line to log (never the response body)."""
    cmd = ["gh", "api", "-X", "PATCH", "gists/" + gist, "--input", body_path]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, errors="replace", stdin=subprocess.DEVNULL, timeout=120)
    except (OSError, subprocess.SubprocessError) as e:
        return "publish failed: gh api: %s" % type(e).__name__
    if r.returncode == 0:
        return None
    m = re.search(r"\bHTTP (\d{3})\b", r.stderr)
    if m and m.group(1) == "404":
        return "gist %s not found or not writable with this token" % gist
    if m:
        return "publish failed: HTTP %s" % m.group(1)
    return "publish failed: gh api exited %d without a status" % r.returncode


def publish(a):
    root = os.path.abspath(a.data_root)
    site = os.path.join(root, "site")
    now = a.now if a.now is not None else int(time.time())
    try:
        os.makedirs(site, exist_ok=True)
        lk = open(os.path.join(site, "lock"), "a")
        fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return 0
    except OSError as e:
        log("cannot lock %s: %s" % (site, e))
        return 1
    a.out = os.path.join(site, "out")
    a.now = now
    files = build(a)
    hashes = {n: hashlib.sha256(d).hexdigest() for n, d in files.items()}
    prev = None
    try:
        with open(os.path.join(site, "published.json"), encoding="utf-8") as f:
            prev = json.load(f)
        old, seen, updated = prev["files"], int(prev["seen"]), int(prev["updated"])
        if not isinstance(old, dict):
            raise ValueError("files")
    except (OSError, ValueError, KeyError, TypeError):
        prev, old, seen, updated = None, {}, None, None
    send = {n: {"content": files[n].decode("utf-8")} for n in files if old.get(n) != hashes[n]}
    send.update({n: None for n in old if n not in files})
    if send:
        if seen is not None and now - seen < a.min_interval:
            return 0
        updated = now
    elif seen is None or now - seen < a.keepalive:
        return 0
    with open(os.path.join(HERE, "site-schema.json"), encoding="utf-8") as f:
        version = json.load(f)["version"]
    manifest = {"version": version, "updated": updated, "seen": now, "files": hashes}
    mdata = jdump(manifest)
    send["manifest.json"] = {"content": mdata.decode("utf-8")}
    body = os.path.join(site, "request.json")
    try:
        with open(body, "w", encoding="utf-8") as f:
            json.dump({"files": send}, f, ensure_ascii=False)
        err = gh_patch(a.gist, body)
    except OSError as e:
        err = "cannot write the request: %s" % e
    finally:
        try:
            os.unlink(body)
        except OSError:
            pass
    if err:
        log(err)
        return 1
    try:
        tmp = os.path.join(site, "published.json.tmp")
        with open(tmp, "wb") as f:
            f.write(mdata)
        os.replace(tmp, os.path.join(site, "published.json"))
    except OSError as e:
        log("cannot write published.json: %s" % e)
        return 1
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--data-root", required=True)
    b.add_argument("--repos", required=True)
    b.add_argument("--out", required=True)
    b.add_argument("--throttle")
    b.add_argument("--now", type=int)
    p = sub.add_parser("publish")
    p.add_argument("--data-root", required=True)
    p.add_argument("--repos", required=True)
    p.add_argument("--gist", required=True)
    p.add_argument("--throttle")
    p.add_argument("--now", type=int)
    p.add_argument("--min-interval", type=int, default=60)
    p.add_argument("--keepalive", type=int, default=900)
    a = ap.parse_args()
    if a.cmd == "publish":
        if not re.fullmatch(r"[A-Za-z0-9]+", a.gist):
            log("bad gist ID")
            return 1
        return publish(a)
    build(a)
    return 0


if __name__ == "__main__":
    sys.exit(main())
