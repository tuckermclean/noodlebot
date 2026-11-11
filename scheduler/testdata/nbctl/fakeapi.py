# fakeapi.py <socket> <fixture-root> <request-log> <mode>: a fake of the noodlebot API on a Unix socket.
#  GET /v1/<x>   serves <fixture-root>/v1/<x>.json byte for byte (mode "v99": parsed, "version" set to 99); /v1/boom is 500,
#                /v1/teapot is 418, anything else unknown is 404 {"version": 1, "error": ...}.
#  GET /v1/events  an event stream as P01 sends it (": stream open", then "id: <cursor>\ndata: {"repo","line"}\n\n").
#                1st connection: events 1-3, then the fake closes the connection. Later connections: the events after the
#                cursor given in Last-Event-ID or ?since= (all of them when the cursor is not one it knows), then it holds the
#                connection open. ?repo= filters. Each request is appended to <request-log> as a JSON line; the ids of the
#                events go to <request-log>.ids, one per line; <request-log>.ready appears when the fake listens.
import base64, http.server, json, os, socketserver, sys, threading, time, urllib.parse
sockpath, fx, reqlog, mode = sys.argv[1:5]
EV = []
for i, repo in enumerate(["acme/alpha", "acme/beta", "acme/alpha", "acme/beta", "acme/alpha"], 1):
    cid = base64.urlsafe_b64encode(json.dumps({"acme/alpha": [11, i * 100], "acme/beta": [12, i * 50]}).encode()).decode().rstrip("=")
    EV.append((cid, repo, "2026-11-10T10:00:0%dZ evtok-%d something changed" % (i, i)))
with open(reqlog + ".ids", "w") as f:
    f.write("".join(e[0] + "\n" for e in EV))
lock = threading.Lock()
conns = [0]

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send_json(self, code, body):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        u = urllib.parse.urlsplit(self.path)
        q = urllib.parse.parse_qs(u.query)
        path = urllib.parse.unquote(u.path)
        with lock:
            with open(reqlog, "a") as f:
                f.write(json.dumps({"method": "GET", "path": path, "query": q, "last_event_id": self.headers.get("Last-Event-ID")}) + "\n")
            if path == "/v1/events":
                conns[0] += 1
                n = conns[0]
        if path == "/v1/events":
            return self.events(q, n)
        if path == "/v1/boom":
            return self.send_json(500, b'{"version": 1, "error": "boom"}')
        if path == "/v1/teapot":
            return self.send_json(418, b'{"version": 1, "error": "teapot"}')
        rel = path.strip("/")
        f = os.path.join(fx, rel + ".json")
        if ".." in rel.split("/") or not path.startswith("/v1/") or not os.path.isfile(f):
            return self.send_json(404, b'{"version": 1, "error": "no such resource"}')
        body = open(f, "rb").read()
        if mode == "v99":
            d = json.loads(body)
            d["version"] = 99
            body = json.dumps(d).encode()
        self.send_json(200, body)
    def events(self, q, n):
        cur = self.headers.get("Last-Event-ID") or (q.get("since") or [None])[0]
        ids = [e[0] for e in EV]
        if n == 1:
            sel, hold = EV[:3], False
        else:
            sel, hold = EV[ids.index(cur) + 1:] if cur in ids else EV, True
        want = (q.get("repo") or [None])[0]
        self.close_connection = True
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        try:
            self.wfile.write(b": stream open\n\n")
            for cid, repo, line in sel:
                if want and repo != want: continue
                self.wfile.write(("id: %s\ndata: %s\n\n" % (cid, json.dumps({"repo": repo, "line": line}))).encode())
            self.wfile.flush()
            t = time.time()
            while hold and time.time() - t < 120:
                time.sleep(0.5)
                self.wfile.write(b": keep-alive\n\n")
                self.wfile.flush()
        except OSError:
            pass

class S(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
try:
    os.unlink(sockpath)
except OSError:
    pass
srv = S(sockpath, H)
open(reqlog + ".ready", "w").close()
srv.serve_forever()
