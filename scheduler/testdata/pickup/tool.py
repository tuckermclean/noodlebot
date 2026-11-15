"""Helpers of scheduler/pickup.test.sh (S09): edit and query the fake forge's folder, write the fake harness's scripts.
Run as `python3 -I tool.py <command> ...`; every command prints on stdout and exits 0, except `script`/`addc` (they print
what they made). The fake forge folder is the one documented in scheduler/testdata/forge/world.py.

  addc FK ISSUE LOGIN OWNER BOT BODY      add a comment (OWNER, BOT: 0|1) after the newest one; prints its id. Its time is
                                          later than every comment the fake forge itself writes (2026-06-01T12:00:00Z).
  url FK ID                               the url of comment ID ("fake://owner/repo/issues/N#cID")
  count FK ISSUE TEXT                     how many comments on ISSUE contain TEXT
  nbot FK ISSUE                           how many comments on ISSUE are the bot's
  bodies FK ISSUE TEXT                    the bodies (JSON list) of the comments on ISSUE containing TEXT
  reply FK ISSUE TEXT                     the body of the first bot comment on ISSUE containing TEXT
  samereply PENDING FK ISSUE TEXT         True when the pending file's reply + "\\n\\nSIG-9\\n" is the first bot comment of ISSUE with TEXT
  react FK ID                             how many +1 reactions comment ID has
  nreact FK                               how many reactions there are
  logissue FK                             the number of the "noodlebot log" issue
  titled FK TEXT                          the numbers of the issues (not PRs) whose title contains TEXT, one per line
  issue FK N FIELD                        one field of issue N, as JSON
  notrec FK [ISSUE[:TEXT]...]             the bot's "Not recorded as an answer" comments as sorted "<issue> <body>" lines
                                          (JSON-quoted bodies); for each ISSUE[:TEXT] given, the first one on ISSUE whose
                                          body contains TEXT is left out
  rmissue FK N / putissue FK N JSON       take issue N out of issues.json (its comments stay) / put it back
  script OUT TEXT [tool] [cost]           the fake harness's script: a start event, a `tool` event when "tool", and a result
                                          event whose text is TEXT
  json FILE EXPR                          print the value of the python expression EXPR over the JSON in FILE (as `d`)
"""
import json
import os
import sys


def load(fk, name, default):
    try:
        with open(os.path.join(fk, name + ".json")) as f:
            return json.load(f)
    except OSError:
        return default


def save(fk, name, data):
    with open(os.path.join(fk, name + ".json"), "w") as f:
        json.dump(data, f, indent=1)


def comments(fk, issue):
    return load(fk, "comments", {}).get(str(issue), [])


def main(a):
    cmd, args = a[0], a[1:]
    if cmd == "addc":
        fk, issue, login, owner, bot, body = args
        d = load(fk, "comments", {})
        n = max([c["id"] for lst in d.values() for c in lst] + [0]) + 1
        d.setdefault(str(issue), []).append({
            "id": n, "body": body, "author": {"login": login, "is_bot": bot == "1", "is_owner": owner == "1"},
            "created_at": "2026-06-02T10:%02d:%02dZ" % divmod(n, 60)})
        save(fk, "comments", d)
        print(n)
    elif cmd == "url":
        fk, cid = args
        for issue, lst in load(fk, "comments", {}).items():
            if any(c["id"] == int(cid) for c in lst):
                print("fake://owner/repo/issues/%s#c%s" % (issue, cid))
    elif cmd == "count":
        print(sum(1 for c in comments(args[0], args[1]) if args[2] in c["body"]))
    elif cmd == "nbot":
        print(sum(1 for c in comments(*args) if c["author"]["is_bot"]))
    elif cmd == "bodies":
        print(json.dumps([c["body"] for c in comments(args[0], args[1]) if args[2] in c["body"]]))
    elif cmd == "reply":
        for c in comments(args[0], args[1]):
            if c["author"]["is_bot"] and args[2] in c["body"]:
                print(c["body"])
                break
    elif cmd == "samereply":
        # samereply PENDING-FILE FK ISSUE TEXT: the pending file's reply, signed, is the first bot comment on ISSUE with TEXT
        with open(args[0]) as f:
            want = json.load(f)["reply"] + "\n\nSIG-9\n"
        got = next((c["body"] for c in comments(args[1], args[2]) if c["author"]["is_bot"] and args[3] in c["body"]), None)
        print(want == got)
    elif cmd == "snap":
        # snap FK ST LOGISSUE ID...: what must stay as it is over more applies (reactions, bot comments per thread, issues,
        # the feedback urls and the files' sums, the handled record)
        import hashlib
        fk, st, log = args[0], args[1], args[2]
        react = load(fk, "reactions", [])
        for c in args[3:]:
            print("react", c, sum(1 for r in react if r["comment"] == int(c)))
        for t in ("11", "12", "13", "14", log):
            print("nbot", t, sum(1 for c in comments(fk, t) if c["author"]["is_bot"]))
        print("issues", len(load(fk, "issues", [])))
        for f in ("node/A01/ANSWER.md", "node/F06/FEEDBACK.md", "pr/26/FEEDBACK.md"):
            try:
                with open(os.path.join(st, f), "rb") as fh:
                    data = fh.read()
                print(f, hashlib.md5(data).hexdigest(), data.count(b"\nurl: "))
            except OSError:
                print(f, "missing")
        try:
            with open(os.path.join(st, "pickup", "handled")) as fh:
                print("handled", sorted(fh.read().split()))
        except OSError:
            print("handled missing")
    elif cmd == "logged":
        # logged ERRFILE FK ID...: every ID's url is on a line of ERRFILE that says "refused"
        with open(args[0]) as f:
            lines = [l for l in f if "refused" in l.lower()]
        urls = {}
        for t, lst in load(args[1], "comments", {}).items():
            for c in lst:
                urls[c["id"]] = "fake://owner/repo/issues/%s#c%d" % (t, c["id"])
        print(all(any(urls[int(i)] in l for l in lines) for i in args[2:]))
    elif cmd == "react":
        print(sum(1 for r in load(args[0], "reactions", []) if r["comment"] == int(args[1]) and r["reaction"] == "+1"))
    elif cmd == "nreact":
        print(len(load(args[0], "reactions", [])))
    elif cmd == "logissue":
        print(next((i["number"] for i in load(args[0], "issues", []) if i["title"].startswith("noodlebot log ")), ""))
    elif cmd == "titled":
        for i in load(args[0], "issues", []):
            if not i["is_pr"] and args[1] in i["title"]:
                print(i["number"])
    elif cmd == "issue":
        print(json.dumps(next((i.get(args[2]) for i in load(args[0], "issues", []) if i["number"] == int(args[1])), None)))
    elif cmd == "notrec":
        fk, drop = args[0], list(args[1:])
        out = []
        for issue, lst in load(fk, "comments", {}).items():
            for c in lst:
                if c["author"]["is_bot"] and c["body"].startswith("Not recorded as an answer"):
                    out.append((issue, c["body"]))
        for spec in drop:
            issue, _, text = spec.partition(":")
            for i, (n, b) in enumerate(out):
                if n == issue and text in b:
                    del out[i]
                    break
        for n, b in sorted(out):
            print(n, json.dumps(b))
    elif cmd == "rmissue":
        fk, n = args
        d = load(fk, "issues", [])
        saved = [i for i in d if i["number"] == int(n)]
        with open(os.path.join(fk, "issue-%s.saved" % n), "w") as f:
            json.dump(saved, f)
        save(fk, "issues", [i for i in d if i["number"] != int(n)])
    elif cmd == "putissue":
        fk, n = args
        with open(os.path.join(fk, "issue-%s.saved" % n)) as f:
            saved = json.load(f)
        save(fk, "issues", load(fk, "issues", []) + saved)
    elif cmd == "script":
        out, text = args[0], args[1]
        flags = args[2:]
        lines = [{"t": "2026-06-02T11:00:00Z", "type": "start", "session": "sess-pickup"}]
        if "tool" in flags:
            lines.append({"t": "2026-06-02T11:00:01Z", "type": "tool", "id": "toolu_p1", "name": "Bash", "text": "ls",
                          "label": "ls", "subagent": False, "background": False, "delay": None})
        lines.append({"t": "2026-06-02T11:00:02Z", "type": "result", "subtype": "success", "text": text, "cost": 0.0123,
                      "turns": 1, "limit": False})
        with open(out, "w") as f:
            for l in lines:
                f.write(json.dumps(l) + "\n")
    elif cmd == "json":
        try:
            with open(args[0]) as f:
                d = json.load(f)
            print(eval(args[1], {"d": d, "json": json}))
        except Exception:
            print("ERROR")
    else:
        sys.exit(2)


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except Exception:   # a query that cannot be answered says so (a test compares the output, it never parses a traceback)
        print("ERROR")
