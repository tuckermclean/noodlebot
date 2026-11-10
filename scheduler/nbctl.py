#!/usr/bin/env python3
"""nbctl.py: command-line client of the noodlebot API (scheduler/api.py), standard library only.

  nbctl.py [--socket <path>] status                      one line per repository, the throttle and the deploy above
  nbctl.py [--socket <path>] status <owner/name>         one repository in detail (what status.sh shows, and more)
  nbctl.py [--socket <path>] events [--repo R] [--since C]   follow /v1/events, one line per event
  nbctl.py [--socket <path>] get <path>                  the JSON of /v1/<path> as the API gave it (exit 0 for 200, 1 for 404, 2 else)

It talks to the socket and nothing else: no state file is read, no program is run, no token is needed. The socket is
$NOODLEBOT_DATA/api.sock (default root ~/.local/share/noodlebot, as in loop.sh) unless --socket says otherwise.
Exit codes: 0 success, 1 not found (get, status of an unlisted repository), 2 the API is not running or answers wrongly.
"""
import argparse
import http.client
import json
import os
import socket
import sys
import time
import urllib.parse

VERSION = 1
RECONNECT = 2   # seconds between connections of `events`


class Fail(Exception):
    def __init__(self, msg, code=2):
        Exception.__init__(self, msg)
        self.code = code


class UnixConn(http.client.HTTPConnection):
    def __init__(self, path, timeout):
        http.client.HTTPConnection.__init__(self, "localhost", timeout=timeout)
        self.path = path

    def connect(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        try:
            s.connect(self.path)
        except OSError:
            s.close()
            raise
        self.sock = s


def not_running(path):
    return Fail("the API is not running (nothing listens on %s); scheduler/loops.sh start starts it" % path)


def open_request(sock, path, headers=None, timeout=30):
    """(connection, response) of GET path; Fail(2) when nothing listens or the exchange breaks."""
    conn = UnixConn(sock, timeout)
    try:
        conn.request("GET", path, headers=headers or {})
        return conn, conn.getresponse()
    except (FileNotFoundError, ConnectionRefusedError, NotADirectoryError):
        conn.close()
        raise not_running(sock)
    except (OSError, http.client.HTTPException) as e:
        conn.close()
        raise Fail("the API on %s did not answer properly: %s" % (sock, e))


def fetch(sock, path):
    """(status, body bytes) of GET path."""
    conn, resp = open_request(sock, path)
    try:
        return resp.status, resp.read()
    except (OSError, http.client.HTTPException) as e:
        raise Fail("the API on %s did not answer properly: %s" % (sock, e))
    finally:
        conn.close()


def check_version(doc, path):
    if isinstance(doc, dict) and "version" in doc and doc["version"] != VERSION:
        raise Fail("%s answers with version %s, and this client knows only version %d" % (path, doc["version"], VERSION))


def getj(sock, path):
    """The parsed JSON of a 200 answer; Fail(1) for a 404, Fail(2) otherwise."""
    status, body = fetch(sock, path)
    try:
        doc = json.loads(body)
    except ValueError:
        doc = None
    if status == 200 and doc is None:
        raise Fail("%s: the answer is not JSON" % path)
    check_version(doc, path)
    if status == 404:
        raise Fail("%s: not found" % path, 1)
    if status != 200:
        raise Fail("%s: HTTP %d" % (path, status))
    return doc


# ---- formatting ----
def age(secs):
    secs = max(0, int(secs))
    if secs < 120:
        return "%ds" % secs
    if secs < 7200:
        return "%dm" % (secs // 60)
    return "%dh" % (secs // 3600)


def ago(ts, now):
    return "never" if ts is None else age(now - ts) + " ago"


def inn(ts, now):
    return "in " + age(ts - now) if ts > now else "now"


def size(n):
    if n is None:
        return "?"
    if n >= 1 << 20:
        return "%.1fM" % (n / (1 << 20))
    if n >= 1 << 10:
        return "%.1fK" % (n / (1 << 10))
    return "%dB" % n


def pct(w):
    u = (w or {}).get("utilization")
    return "?" if u is None else "%.0f%%" % (u * 100)


def throttle_line(t):
    p = t.get("projected_5h")
    return "throttle: 5-hour %s%s, 7-day %s; %s" % (
        pct(t.get("five_hour")), ", projected %.0f%%" % (p * 100) if p is not None else "", pct(t.get("seven_day")),
        "HOLDING: %s" % t.get("reason") if t.get("hold") else "open")


def deploy_line(d):
    s = "deploy: head %s" % (d.get("head") or "?")
    if d.get("previous"):
        s += ", previous %s" % d["previous"]
    if d.get("rejected"):
        s += ", rejected %s" % " ".join(d["rejected"])
    if d.get("last_failed"):
        s += "; last failure: %s" % (d["last_failed"].get("line") or "")
    return s


def one(text, n=100):
    for l in (text or "").splitlines():
        if l.strip():
            return l.strip()[:n]
    return ""


def waiting(nodes, issues):
    """(label, kind, text, url, spec_pr) of what waits on the owner; kind FAILED, QUESTION, answered or waiting-pr."""
    out = []
    for n in nodes:
        st = n.get("state")
        if st == "failed":
            out.append((n["id"], "FAILED", n.get("reason"), None, None))
        elif st == "question":
            out.append((n["id"], "QUESTION", n.get("question"), n.get("issue_url"), None))
        elif st == "answered":
            out.append((n["id"], "answered", None, None, None))
        elif st == "waiting-pr":
            out.append((n["id"], "waiting-pr", None, None, n.get("spec_pr")))
    for i in issues:
        st, lab = i.get("state"), "#%s" % i.get("number")
        if st == "failed":
            out.append((lab, "FAILED", i.get("reason"), None, None))
        elif st == "question":
            out.append((lab, "QUESTION", i.get("question"), i.get("issue_url"), None))
        elif st == "answered":
            out.append((lab, "answered", None, None, None))
    return out


# ---- commands ----
def cmd_status_all(sock):
    repos = getj(sock, "/v1/repos")["repos"]
    t = getj(sock, "/v1/throttle")
    d = getj(sock, "/v1/deploy")
    print(throttle_line(t))
    print(deploy_line(d))
    for r in repos:
        base = "/v1/repos/" + r["repo"]
        sessions = getj(sock, base + "/sessions")["sessions"]
        nodes = getj(sock, base + "/nodes")["nodes"]
        issues = getj(sock, base + "/issues")["issues"]
        if r.get("running"):
            state = "running"
        else:
            state = "stopped"
        stops = []
        if r.get("stop_all"):
            stops.append("STOP")
        if r.get("stop"):
            stops.append("STOP-" + r["repo"].split("/", 1)[1])
        if stops:
            state += " (%s)" % ", ".join(stops)
        hb = r.get("heartbeat_age")
        subjects = " ".join(s["subject"] for s in sessions if s.get("alive")) or "none"
        w = [x for x in waiting(nodes, issues) if x[1] != "answered"]
        print("%s  %s  heartbeat %s  sessions: %s  %d waiting" % (
            r["repo"], state, "never" if hb is None else age(hb), subjects, len(w)))


def cmd_status_repo(sock, repo):
    base = "/v1/repos/" + repo
    r = getj(sock, base)
    t = getj(sock, "/v1/throttle")
    sessions = getj(sock, base + "/sessions")["sessions"]
    nodes = getj(sock, base + "/nodes")["nodes"]
    issues = getj(sock, base + "/issues")["issues"]
    prs = getj(sock, base + "/prs")["prs"]
    now = time.time()
    name = repo.split("/", 1)[1]
    print("== %s" % time.strftime("%F %T %Z"))
    if r.get("running"):
        print("loop:    running; stop with: touch ~/STOP-%s (or ~/STOP for every loop)" % name)
    else:
        print("loop:    stopped (NOT running); start with: scheduler/loops.sh start")
    if r.get("stop_all"):
        print("         ~/STOP exists: the loops exit within seconds")
    if r.get("stop"):
        print("         ~/STOP-%s exists: this loop exits within seconds" % name)
    hb = r.get("heartbeat_age")
    print("last GitHub check: %s" % ("never" if hb is None else age(hb) + " ago"))
    if r.get("status_issue") is not None:
        print("on GitHub: https://github.com/%s/issues/%s (reply there to answer a question)" % (repo, r["status_issue"]))
    print("usage:   " + throttle_line(t))

    live = [s for s in sessions if s.get("alive")]
    for s in live:
        label = "triage of #%s" % s["subject"] if s["kind"] == "triage" else s["subject"]
        started = s.get("started")
        print("== %s RUNNING (pid %s, for %s); log %s, last written %s" % (
            label, s["pid"], "?" if started is None else age(now - started), size(s.get("log_size")),
            ago(s.get("log_modified"), now)))
        evs = s.get("events") or []
        for e in evs[-4:]:
            if e.get("type") == "result":
                print("   [turn ended: %s]" % e.get("subtype"))
            else:
                print("   %s%s: %s" % ("> " if e.get("subagent") else "", e.get("tool"), one(e.get("text"))))
        if not evs:
            print("   (none yet)")
        for c in s.get("commits") or []:
            print("   commit %s %s" % (c["sha"], c["subject"]))
        if s.get("wakeup_at"):
            print("   wakeup %s (a pending wakeup)" % inn(s["wakeup_at"], now))
        for b in s.get("bg_commands") or []:
            print("   background command: %s" % one(b.get("text")))
        for b in s.get("bg_agents") or []:
            print("   background agent: %s" % one(b.get("text")))
        lim = s.get("limit")
        if lim:
            print("   limit rejected %s, resets %s" % (ago(lim.get("at"), now), "?" if lim.get("resets_at") is None else inn(lim["resets_at"], now)))
    if not live:
        print("sessions: none running")

    print("-- waiting on you:")
    w = waiting(nodes, issues)
    for lab, kind, text, url, spec in w:
        if kind == "FAILED":
            print("   %s FAILED: %s" % (lab, text or ""))
        elif kind == "QUESTION":
            print("   %s QUESTION: %s" % (lab, text or ""))
            if url:
                print("      answer on %s" % url)
        elif kind == "answered":
            print("   %s answered: restarts at the next tick" % lab)
        else:
            print("   %s waits for you to merge spec PR #%s; restarts at the tick after" % (lab, spec))
    if not w:
        print("   nothing")

    print("-- nodes:")
    for n in nodes:
        extra = ""
        if n.get("pr") is not None:
            extra += " PR #%s" % n["pr"]
        if n.get("waiting_on"):
            extra += " (waiting on %s)" % " ".join(n["waiting_on"])
        print("   %s %s: %s%s" % (n["id"], n.get("name", ""), n.get("state"), extra))
    if not nodes:
        print("   none")

    print("-- open PRs:")
    for p in prs:
        print("   #%s %s %s%s" % (p["number"], p.get("branch"), p.get("mergeable") or "UNKNOWN", " (bot)" if p.get("bot") else ""))
    if not prs:
        print("   none")


def cmd_events(sock, repo, since):
    cursor = since
    first = True
    told = False
    while True:
        q = {}
        if repo:
            q["repo"] = repo
        if cursor:
            q["since"] = cursor
        path = "/v1/events" + ("?" + urllib.parse.urlencode(q) if q else "")
        started = time.time()
        try:
            conn, resp = open_request(sock, path, {"Accept": "text/event-stream"}, timeout=300)
        except Fail:
            if first:
                raise
            conn = resp = None
        if resp is not None:
            if resp.status != 200:
                body = resp.read()[:200]
                conn.close()
                raise Fail("/v1/events: HTTP %d %s" % (resp.status, body.decode("utf-8", "replace")))
            first = False
            eid, data = None, []
            try:
                while True:
                    raw = resp.readline()
                    if not raw:
                        break
                    line = raw.decode("utf-8", "replace").rstrip("\r\n")
                    if line == "":
                        if data:
                            try:
                                ev = json.loads("\n".join(data))
                                print("%s %s" % (ev.get("repo"), ev.get("line")), flush=True)
                            except ValueError:
                                print("? %s" % "\n".join(data), flush=True)
                        if eid is not None:
                            cursor = eid
                        eid, data = None, []
                    elif line.startswith("id:"):
                        eid = line[3:].strip()
                    elif line.startswith("data:"):
                        data.append(line[5:].lstrip(" "))
            except (OSError, http.client.HTTPException):
                pass
            finally:
                conn.close()
        if not told:
            print("connection to the API lost; reconnecting every %d seconds" % RECONNECT, file=sys.stderr, flush=True)
            told = True
        wait = RECONNECT - (time.time() - started)
        if wait > 0:
            time.sleep(wait)


def cmd_get(sock, path):
    p = "/v1/" + path.lstrip("/")
    status, body = fetch(sock, p)
    if status == 200:
        try:
            check_version(json.loads(body), p)
        except ValueError:
            pass
        sys.stdout.buffer.write(body)
        sys.stdout.buffer.flush()
        return 0
    sys.stderr.buffer.write(body)
    sys.stderr.buffer.flush()
    return 1 if status == 404 else 2


def main(argv):
    ap = argparse.ArgumentParser(prog="nbctl.py", description="Command-line client of the noodlebot API.")
    ap.add_argument("--socket", help="the API's Unix socket (default $NOODLEBOT_DATA/api.sock)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("status", help="every repository, or one in detail")
    s.add_argument("repo", nargs="?", help="owner/name")
    e = sub.add_parser("events", help="follow the event stream")
    e.add_argument("--repo", help="only this repository (owner/name)")
    e.add_argument("--since", help="resume after this cursor")
    g = sub.add_parser("get", help="print the JSON of /v1/<path>")
    g.add_argument("path")
    a = ap.parse_args(argv)
    sock = a.socket
    if not sock:
        root = os.environ.get("NOODLEBOT_DATA") or os.path.join(os.path.expanduser("~"), ".local/share/noodlebot")
        sock = os.path.join(os.path.abspath(root), "api.sock")
    try:
        if a.cmd == "status":
            if a.repo:
                cmd_status_repo(sock, a.repo)
            else:
                cmd_status_all(sock)
            return 0
        if a.cmd == "events":
            cmd_events(sock, a.repo, a.since)
            return 0
        return cmd_get(sock, a.path)
    except Fail as f:
        print("nbctl: %s" % f, file=sys.stderr)
        return f.code
    except (KeyError, TypeError, ValueError) as f:
        print("nbctl: the API's answer has an unexpected shape: %r" % (f,), file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        return 0
    except BrokenPipeError:
        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
