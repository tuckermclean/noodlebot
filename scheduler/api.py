#!/usr/bin/env python3
"""Read-only HTTP API over the scheduler's runtime files (node P01).

HTTP/1.1 on $NOODLEBOT_DATA/api.sock (default root ~/.local/share/noodlebot, made absolute as loop.sh does),
mode 0600. One server per runtime root: it holds $NOODLEBOT_DATA/api.lock (exit 2 if another does). Every
request is a GET under /v1/; other methods are 405, unknown paths 404, both JSON. Every response has
"version": 1. The server reads local files only (and of ~/.config/noodlebot/ only `repos`); it makes no
GitHub call, runs no token script, and logs only its start, stop and errors.

Every NOODLEBOT_API_HEAD_CHECK seconds (default 60) it compares its checkout's HEAD with the one it started
under and, when it moved, re-execs itself keeping the lock and the listening socket (their fds are passed in
NOODLEBOT_API_FDS). NOODLEBOT_API_KEEPALIVE (default 15) is the event stream's comment interval.

Resources are registered with @route(<regex>); the handler gets the regex match and the request handler
(req: req.query is the parsed query string, req.headers, req.wfile) and returns (status, object) (a third
item True: served verbatim, no "version" added; None: the handler wrote the whole response itself, as a
stream does) or raises Err(status, text). Schemas: scheduler/api-schema/v1/<resource>.json.
"""
import collections
import datetime
import fcntl
import http.server
import json
import os
import re
import signal
import socket
import socketserver
import subprocess
import sys
import threading
import time
import urllib.parse

HERE = os.path.dirname(os.path.realpath(__file__))
CHECKOUT = os.path.dirname(HERE)
SCHEMAS = os.path.join(HERE, "api-schema", "v1")
VERSION = 1

root = os.path.abspath(os.environ.get("NOODLEBOT_DATA") or os.path.join(os.path.expanduser("~"), ".local/share/noodlebot"))
home = os.path.expanduser("~")
repos_list = os.path.join(home, ".config", "noodlebot", "repos")


def log(msg):
    print("api.py: " + msg, file=sys.stderr, flush=True)


class Err(Exception):
    def __init__(self, status, text):
        Exception.__init__(self, text)
        self.status, self.text = status, text


ROUTES = []


def route(pattern):
    def deco(fn):
        ROUTES.append((re.compile(pattern + r"\Z"), fn))
        return fn
    return deco


# ---- reading the runtime files ----

def read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


def read_json(path):
    t = read_text(path)
    if t is None:
        return None
    try:
        return json.loads(t)
    except ValueError:
        return None


def repo_list():
    """The repositories in ~/.config/noodlebot/repos, as loops.sh reads them."""
    out = []
    t = read_text(repos_list)
    for line in (t or "").splitlines():
        line = re.sub(r"\s", "", line.split("#", 1)[0])
        if not line or line.startswith("/") or line.endswith("/") or line.count("/") != 1:
            continue
        if line not in out:
            out.append(line)
    return out


def _mount_dev(path):
    """major:minor of the mount holding path, from mountinfo (for filesystems whose st_dev differs)."""
    best, dev = -1, None
    path = os.path.realpath(path)
    t = read_text("/proc/self/mountinfo") or ""
    for line in t.splitlines():
        f = line.split()
        if len(f) < 5:
            continue
        mp = f[4].replace("\\040", " ")
        if (path == mp or path.startswith(mp.rstrip("/") + "/")) and len(mp) > best:
            best, dev = len(mp), f[2]
    if dev:
        try:
            a, b = dev.split(":")
            return int(a), int(b)
        except ValueError:
            pass
    return None


def held(path):
    """Some process holds a lock on the file, as /proc/locks shows it; the lock is never taken."""
    try:
        st = os.stat(path)
    except OSError:
        return False
    dev = (os.major(st.st_dev), os.minor(st.st_dev))
    mdev = None
    t = read_text("/proc/locks") or ""
    for line in t.splitlines():
        f = line.split()
        if len(f) < 6 or f[1] == "->" or f[0] == "->":
            continue
        try:
            maj, mnr, ino = f[5].split(":")
            if int(ino) != st.st_ino:
                continue
            ldev = (int(maj, 16), int(mnr, 16))
        except ValueError:
            continue
        if ldev == dev:
            return True
        if mdev is None:
            mdev = _mount_dev(path) or ()
        if ldev == mdev:
            return True
    return False


def repo_info(repo):
    name = repo.split("/", 1)[1]
    sd = os.path.join(root, "state", name)
    hb = None
    t = read_text(os.path.join(sd, "heartbeat"))
    if t and t.split():
        try:
            hb = int(t.split()[0])
        except ValueError:
            pass
    issue = None
    rep = read_json(os.path.join(sd, "report.json"))
    if isinstance(rep, dict) and isinstance(rep.get("issue"), int) and not isinstance(rep.get("issue"), bool):
        issue = rep["issue"]
    return {
        "repo": repo,
        "running": held(os.path.join(sd, "loop.lock")),
        "stop": os.path.exists(os.path.join(home, "STOP-" + name)),
        "stop_all": os.path.exists(os.path.join(home, "STOP")),
        "heartbeat": hb,
        "heartbeat_age": None if hb is None else max(0, int(time.time()) - hb),
        "status_issue": issue,
    }


# ---- resources ----

@route(r"/v1/repos")
def r_repos(m, req):
    return 200, {"repos": [repo_info(r) for r in repo_list()]}


@route(r"/v1/repos/([^/]+/[^/]+)")
def r_repo(m, req):
    if m.group(1) not in repo_list():
        raise Err(404, "no such repository: " + m.group(1))
    return 200, repo_info(m.group(1))


# ---- nodes ----

NODE_ID = r"[A-Z][0-9][0-9]"
GRAPH_READER = """
import json, sys, yaml
with open(sys.argv[1], encoding="utf-8") as f:
    nodes = yaml.safe_load(f)["nodes"]
print(json.dumps([{"id": str(n["id"]), "name": str(n["name"]), "deps": [str(d) for d in n.get("deps") or []],
                   "track": str(n.get("track") or "")} for n in nodes]))
"""
LIMIT_TEXT = re.compile(r"usage limit|rate limit|limit reached|hit your limit", re.I)


def run_py(args, what):
    """Run python3 -I with args (stdlib-only api.py leaves PyYAML to this child, as ready.py needs it too); 503 on any failure."""
    try:
        r = subprocess.run(["python3", "-I"] + args, capture_output=True, text=True, timeout=30, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError) as e:
        log("%s failed: %r" % (what, e))
        raise Err(503, what + " failed")
    if r.returncode != 0:
        log("%s failed: rc %d: %s" % (what, r.returncode, r.stderr.strip()[:300]))
        raise Err(503, what + " failed")
    return r.stdout


TOKEN = re.compile(r"(?:gh[spou]_|github_pat_|sk-ant-)[A-Za-z0-9_-]*")


def redact(text):
    """text with every GitHub token or Anthropic key replaced by [redacted]. Every text served from a session log, a
    status log or a marker file goes through this before it is cut to length."""
    return TOKEN.sub("[redacted]", text)


def first_line(path):
    t = read_text(path)
    return None if t is None else redact((t.splitlines() or [""])[0])


def first_word(path):
    t = read_text(path)
    return (t.split() or [None])[0] if t is not None else None


def session_alive(d, key):
    """The session's pid is a live process whose command line is a session of key, as alive() in loop.sh decides it."""
    w = first_word(os.path.join(d, "session.pid"))
    if not w or not w.isdigit():
        return False
    try:
        os.kill(int(w), 0)
    except OSError:
        return False
    cmd = (read_text("/proc/%s/cmdline" % w) or "").replace("\0", " ")
    return re.search(r"run-session\.sh .* %s( |$)|claude -p /node %s( |$)" % (key, key), cmd) is not None


def at_limit(d):
    """The log's last line is a usage-limit rejection as S06 reads it: a rate_limit_event whose status is not
    allowed, or a result naming a usage limit."""
    try:
        with open(os.path.join(d, "session.jsonl"), "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 400000))
            lines = f.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return False
    lines = [x for x in lines if x.strip()]
    try:
        ev = json.loads(lines[-1]) if lines else None
    except ValueError:
        return False
    if not isinstance(ev, dict):
        return False
    if ev.get("type") == "rate_limit_event":
        return ((ev.get("rate_limit_info") or {}).get("status", "allowed")) != "allowed"
    if ev.get("type") == "result":
        return LIMIT_TEXT.search(str(ev.get("result") or "") + " " + str(ev.get("subtype") or "")) is not None
    return False


def node_ids(path, col):
    """IDs of the node/<ID>-... branches in column col (0-based) of a space-separated file, as ids() in loop.sh."""
    out = []
    for line in (read_text(path) or "").splitlines():
        f = line.split(" ")
        if len(f) > col:
            m = re.match(r"node/(%s)-" % NODE_ID, f[col])
            if m and m.group(1) not in out:
                out.append(m.group(1))
    return out


def nodes_of(repo):
    if repo not in repo_list():
        raise Err(404, "no such repository: " + repo)
    owner, name = repo.split("/", 1)
    sd = os.path.join(root, "state", name)
    graph = os.path.join(sd, "graph.yaml")
    if not os.path.exists(graph):
        raise Err(503, "no graph fetched yet for " + repo)
    try:
        nodes = json.loads(run_py(["-c", GRAPH_READER, graph], "reading graph.yaml"))
    except ValueError:
        raise Err(503, "reading graph.yaml failed")
    merged_tsv, open_tsv = os.path.join(sd, "merged-prs.tsv"), os.path.join(sd, "open-prs.tsv")
    merged_ids = node_ids(merged_tsv, 1)
    open_ids = node_ids(os.path.join(sd, "open-prs.txt"), 0)
    subjects = (read_text(os.path.join(sd, "subjects.txt")) or "").splitlines()
    merged_prs = set((read_text(os.path.join(sd, "merged-prs.txt")) or "").split())
    prs = {}   # node ID -> (number, mergeable) of its open PR
    for line in (read_text(open_tsv) or "").splitlines():
        f = line.split(" ")
        m = re.match(r"node/(%s)-" % NODE_ID, f[1]) if len(f) > 1 else None
        if m and m.group(1) not in prs:
            prs[m.group(1)] = (int(f[0]) if f[0].isdigit() else None, f[4] if len(f) > 4 else None)
    # ready.py over the loop's cached files, exactly as tick() in loop.sh runs it (it writes nothing)
    args = [os.path.join(HERE, "ready.py"), "--graph", graph, "--markers", os.path.join(sd, "node")]
    if os.path.exists(os.path.join(sd, "subjects.txt")):
        args += ["--subjects", os.path.join(sd, "subjects.txt")]
    if os.path.exists(os.path.join(sd, "merged-prs.txt")):
        args += ["--merged-prs", os.path.join(sd, "merged-prs.txt")]
    args.append("--all")
    for i in merged_ids:
        args += ["--merged", i]
    for i in open_ids:
        args += ["--open", i]
    ready = set()
    for line in run_py(args, "ready.py").splitlines():
        w = line.split()
        if len(w) == 2:   # a third word is a merged node to follow up
            ready.add(w[0])
    usage = read_json(os.path.join(root, "state", "usage.json"))
    hold = isinstance(usage, dict) and usage.get("hold") is True
    status_issue = (read_json(os.path.join(sd, "report.json")) or {}).get("issue") if isinstance(read_json(os.path.join(sd, "report.json")), dict) else None
    merged = set(merged_ids)
    for n in nodes:
        if any(x.startswith("%s %s:" % (n["id"], n["name"])) for x in subjects):
            merged.add(n["id"])
    out = []
    for n in nodes:
        i = n["id"]
        d = os.path.join(sd, "node", i)
        has = lambda f: os.path.exists(os.path.join(d, f))   # noqa: E731
        n.update(starts=0, state=None, pr=None, mergeable=None, reason=None, question=None, issue_url=None, spec_pr=None,
                 waiting_on=[])
        st = first_word(os.path.join(d, "starts"))
        if st and st.isdigit():
            n["starts"] = int(st)
        wp = first_word(os.path.join(d, "WAITING-PR"))
        if i in merged:
            n["state"] = "merged"
        elif i in prs:
            n["state"], (n["pr"], n["mergeable"]) = "pr-open", prs[i]
        # idle-limit before running: a session idle at the limit is still alive, so "any live session is running"
        # first would make idle-limit unreachable
        elif session_alive(d, i) and at_limit(d):
            n["state"] = "idle-limit"
        elif session_alive(d, i):
            n["state"] = "running"
        elif has("FAILED"):
            n["state"], n["reason"] = "failed", first_line(os.path.join(d, "FAILED"))
        elif has("QUESTION.md") and not has("ANSWER.md"):
            n["state"], n["question"] = "question", first_line(os.path.join(d, "QUESTION.md"))
            num = first_word(os.path.join(d, "issue"))
            if not (num and num.isdigit()) and isinstance(status_issue, int) and not isinstance(status_issue, bool):
                num = str(status_issue)
            if num and num.isdigit():
                n["issue_url"] = "https://github.com/%s/%s/issues/%s" % (owner, name, num)
        elif has("QUESTION.md"):
            n["state"] = "answered"
        elif wp and wp.isdigit() and wp not in merged_prs:   # a merged spec PR lets ready.py resume the node
            n["state"], n["spec_pr"] = "waiting-pr", int(wp)
        elif i in ready:
            n["state"] = "held" if hold else "ready"
        else:
            n["state"], n["waiting_on"] = "waiting", [x for x in n["deps"] if x not in merged]
        out.append(n)
    return out


@route(r"/v1/repos/([^/]+/[^/]+)/nodes")
def r_nodes(m, req):
    return 200, {"nodes": nodes_of(m.group(1))}


@route(r"/v1/repos/([^/]+/[^/]+)/nodes/(%s)" % NODE_ID)
def r_node(m, req):
    for n in nodes_of(m.group(1)):
        if n["id"] == m.group(2):
            return 200, n
    raise Err(404, "no such node: " + m.group(2))


# ---- sessions ----

def epoch(ts):
    """Epoch seconds of an ISO timestamp such as 2026-11-09T09:02:00Z, or None."""
    try:
        return int(datetime.datetime.fromisoformat(str(ts).replace("Z", "+00:00")).timestamp())
    except ValueError:
        return None


def tool_text(inp):
    """The first line of input.description, else command, else path, else file_path; redacted, then cut to 200."""
    if not isinstance(inp, dict):
        return None
    for k in ("description", "command", "path", "file_path"):
        v = inp.get(k)
        if isinstance(v, str) and v.strip():
            lines = redact(v).splitlines()
            return lines[0][:200] if lines else None
    return None


def scan_log(path):
    """One pass over a session log, a line at a time (memory stays bounded however large the log): its last 10 events,
    the pending wakeup, the unfinished background tasks and the last rate-limit rejection."""
    events = collections.deque(maxlen=10)
    wake = None            # (epoch, delaySeconds) of the last ScheduleWakeup
    wake_open = False      # no assistant tool use or result since
    bg = collections.OrderedDict()   # tool use id -> [kind, text, background id or None]
    done = set()
    limit = None
    try:
        f = open(path, "rb")
    except OSError:
        return events, None, [], [], None
    with f:
        for raw in f:
            if (b'"tool_use"' not in raw and b'"result"' not in raw and b"rate_limit_event" not in raw
                    and b"task_notification" not in raw and b"tool_result" not in raw):
                continue
            try:
                ev = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(ev, dict):
                continue
            t, kind = epoch(ev.get("timestamp")), ev.get("type")
            msg = ev.get("message")
            blocks = msg.get("content") if isinstance(msg, dict) else None
            if not isinstance(blocks, list):
                blocks = []
            if kind == "assistant":
                for b in blocks:
                    if not (isinstance(b, dict) and b.get("type") == "tool_use"):
                        continue
                    inp = b.get("input") if isinstance(b.get("input"), dict) else {}
                    e = {"type": "tool_use", "time": t, "tool": b.get("name"), "text": tool_text(inp),
                         "subagent": bool(ev.get("parent_tool_use_id"))}
                    events.append(e)
                    wake_open = False
                    if b.get("name") == "ScheduleWakeup" and t is not None and isinstance(inp.get("delaySeconds"), (int, float)):
                        wake, wake_open = t + int(inp["delaySeconds"]), True
                    if inp.get("run_in_background") is True and b.get("name") in ("Bash", "Agent"):
                        bg[b.get("id")] = [b.get("name"), e["text"], None]
            elif kind == "user":
                for b in blocks:
                    if isinstance(b, dict) and b.get("type") == "tool_result" and b.get("tool_use_id") in bg:
                        c = b.get("content")
                        if isinstance(c, list):
                            c = " ".join(str(x.get("text", "")) for x in c if isinstance(x, dict))
                        m = re.search(r"ID: (\S+)", c if isinstance(c, str) else "")
                        if m:
                            bg[b["tool_use_id"]][2] = m.group(1)
            elif kind == "result":
                events.append({"type": "result", "time": t, "subtype": ev.get("subtype")})
                wake_open = False
            elif kind == "system" and ev.get("subtype") == "task_notification" and ev.get("task_id"):
                done.add(ev["task_id"])
            elif kind == "rate_limit_event":
                info = ev.get("rate_limit_info")
                if isinstance(info, dict) and info.get("status", "allowed") != "allowed":
                    limit = {"at": t, "resets_at": info.get("resetsAt")}
    pend = [v for v in bg.values() if v[2] and v[2] not in done]
    cmds = [{"id": v[2], "text": v[1]} for v in pend if v[0] == "Bash"]
    agents = [{"id": v[2], "text": v[1]} for v in pend if v[0] == "Agent"]
    return events, wake if wake_open else None, cmds, agents, limit


def session_of(sd, sub, kind, subject):
    d = os.path.join(sd, sub)
    pidf = os.path.join(d, "session.pid")
    w = first_word(pidf)
    if not (w and w.isdigit()):
        return None
    log_path = os.path.join(d, "session.jsonl")
    events, wake, cmds, agents, limit = scan_log(log_path)
    try:
        st = os.stat(log_path)
        size, mod = st.st_size, int(st.st_mtime)
    except OSError:
        size = mod = None
    rc = first_word(os.path.join(d, "session.rc"))
    try:
        started = int(os.stat(pidf).st_mtime)
    except OSError:
        started = None
    return {"kind": kind, "subject": subject, "pid": int(w), "alive": session_alive(d, subject), "started": started,
            "log_size": size, "log_modified": mod, "events": list(events),
            "rc": int(rc) if rc and rc.lstrip("-").isdigit() else None,
            "wakeup_at": wake, "bg_commands": cmds, "bg_agents": agents, "limit": limit}


@route(r"/v1/repos/([^/]+/[^/]+)/sessions")
def r_sessions(m, req):
    if m.group(1) not in repo_list():
        raise Err(404, "no such repository: " + m.group(1))
    sd = os.path.join(root, "state", m.group(1).split("/", 1)[1])
    out = []
    for parent, kind, rx in (("node", "node", NODE_ID), ("issue", "triage", r"[0-9]+"), ("pr", "update", r"[0-9]+")):
        try:
            names = sorted(os.listdir(os.path.join(sd, parent)))
        except OSError:
            continue
        for n in names:
            if re.fullmatch(rx, n):
                s = session_of(sd, parent + "/" + n, kind, n)
                if s:
                    out.append(s)
    return 200, {"sessions": out}


@route(r"/v1/schema/([A-Za-z0-9_-]+)")
def r_schema(m, req):
    s = read_json(os.path.join(SCHEMAS, m.group(1) + ".json"))
    if not isinstance(s, dict):
        raise Err(404, "no such schema: " + m.group(1))
    return 200, s, True   # served verbatim, without adding "version"


# ---- HTTP ----

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "noodlebot-api"
    timeout = 120   # an idle keep-alive client lets go of its thread; a stream writes, and clears this (req.connection.settimeout(None))

    def log_message(self, *a):
        pass

    def send_obj(self, status, obj):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if status == 405:
            self.send_header("Allow", "GET")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def send_error(self, code, message=None, explain=None):
        """Malformed requests get a JSON body too, never the stdlib's HTML."""
        self.close_connection = True
        self.send_obj(code, {"version": VERSION, "error": message or self.responses.get(code, ("error",))[0]})

    def __getattr__(self, name):
        if name.startswith("do_"):   # every method but GET, known or not: 405
            return self.other
        raise AttributeError(name)

    def do_GET(self):
        path = self.path.split("?", 1)[0].split("#", 1)[0]
        self.query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        try:
            for rx, fn in ROUTES:
                m = rx.match(path)
                if m:
                    res = fn(m, self)
                    if res is None:
                        return
                    body = res[1]
                    if len(res) == 2:
                        body = dict(body, version=VERSION)
                    return self.send_obj(res[0], body)
            raise Err(404, "not found: " + path)
        except Err as e:
            self.send_obj(e.status, {"version": VERSION, "error": e.text})
        except Exception as e:
            log("error on GET %s: %r" % (path, e))
            self.send_obj(500, {"version": VERSION, "error": "internal error"})

    def other(self):
        self.close_connection = True   # an unread body must not be taken for the next request
        self.send_obj(405, {"version": VERSION, "error": "method not allowed: only GET is served"})


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    address_family = socket.AF_UNIX
    daemon_threads = True

    def __init__(self, sock):
        socketserver.BaseServer.__init__(self, sock.getsockname(), Handler)
        self.socket = sock

    def get_request(self):
        c, _ = self.socket.accept()
        return c, ("local", 0)


# ---- start, lock, HEAD check ----

def head():
    try:
        r = subprocess.run(["git", "-C", CHECKOUT, "rev-parse", "HEAD"], capture_output=True, text=True, timeout=20)
        return r.stdout.strip() if r.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        return None


def watch_head(started):
    try:
        every = float(os.environ.get("NOODLEBOT_API_HEAD_CHECK") or 60)
    except ValueError:
        every = 60.0
    while True:
        time.sleep(every)
        h = head()
        # HEAD unreadable at start: the code now running is of unknown age, so the first HEAD read restarts it
        if h and h != started:
            log("HEAD moved %s..%s; restarting" % (started[:7], h[:7]))
            argv = getattr(sys, "orig_argv", None) or [sys.executable] + sys.argv   # keeps flags such as -I
            os.execv(sys.executable, argv)


def main():
    sockpath = os.path.join(root, "api.sock")
    fds = os.environ.pop("NOODLEBOT_API_FDS", "")
    sock = None
    if fds:   # re-exec from a moved HEAD: the lock and the socket come along
        try:
            lfd, sfd = (int(x) for x in fds.split(","))
            lock = os.fdopen(lfd, "w")
            sock = socket.socket(fileno=sfd)
        except (ValueError, OSError) as e:
            log("could not take over the lock and socket: %r" % e)
            return 1
    else:
        os.makedirs(root, exist_ok=True)
        lock = open(os.path.join(root, "api.lock"), "w")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            print("api.py: another server holds %s" % os.path.join(root, "api.lock"), file=sys.stderr)
            return 2
        try:
            os.unlink(sockpath)   # a socket file left by a server that died
        except FileNotFoundError:
            pass
        old = os.umask(0o177)
        try:
            sock = socket.socket(socket.AF_UNIX)
            sock.bind(sockpath)
        finally:
            os.umask(old)
        os.chmod(sockpath, 0o600)
        sock.listen(64)
        log("started on %s" % sockpath)
    os.set_inheritable(lock.fileno(), True)
    os.set_inheritable(sock.fileno(), True)
    os.environ["NOODLEBOT_API_FDS"] = "%d,%d" % (lock.fileno(), sock.fileno())
    srv = Server(sock)
    threading.Thread(target=watch_head, args=(head(),), daemon=True).start()

    def stop(*_):
        threading.Thread(target=srv.shutdown, daemon=True).start()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        srv.serve_forever()
    finally:
        try:
            os.unlink(sockpath)
        except OSError:
            pass
        log("stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
