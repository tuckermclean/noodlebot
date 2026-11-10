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
