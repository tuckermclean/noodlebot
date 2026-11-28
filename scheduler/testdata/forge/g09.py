#!/usr/bin/env python3
"""The cases of scheduler/forge-g09.test.sh (G09-AC-1, G09-AC-2, G09-AC-5): ci dispatch and ci logs --attempt.

  g09.py <workdir>     run every case and print one PASS:/FAIL: line per check (details after the name), then "DONE".

<workdir> holds what forge-g09.test.sh made: bin/gh (the emulator, recording each call in <state>/calls.jsonl) and at-file
(a real file an input's value can name with a leading @). The GitHub backend runs over the emulator (state
<workdir>/gh-state, repository acme/widgets), the fake forge over <workdir>/fake-state (its calls are recorded by fake.py in
<workdir>/fake-calls.jsonl, $FAKE_FORGE_CALLS). Each backend is driven through the Python interface and through the CLI.
Environment: GH_TOKEN and NOODLEBOT_FORGE* are unset by the caller; HOME is a scratch folder.

Slice 2 (ci artifact, G09-AC-3 and G09-AC-4) appends its cases below the AC-5 ones, before main(), and adds its sections to
the list in main().

The bound for finding a dispatched run (the design the implementation follows): $FORGE_DISPATCH_WAIT seconds (default 60, the
constant DISPATCH_WAIT of the GitHub backend's module) and $FORGE_DISPATCH_POLL seconds between two listings, both parsed
with float() at each call; the cases that wait for a run that never appears set the bound to 1 second.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SCHED = os.path.dirname(os.path.dirname(HERE))
WORK = os.path.abspath(sys.argv[1])
sys.path.insert(0, SCHED)
sys.path.insert(0, HERE)

GH_STATE = os.path.join(WORK, "gh-state")
FK_STATE = os.path.join(WORK, "fake-state")
FK_CALLS = os.path.join(WORK, "fake-calls.jsonl")
STATE = {"github": GH_STATE, "fake": FK_STATE}
SPEC = {"github": "acme/widgets", "fake": "fake:" + FK_STATE}
PREFIX = {"github": "https://github.com/acme/widgets/", "fake": "fake://acme/widgets/"}
ATFILE = os.path.join(WORK, "at-file")
TS = os.path.join(HERE, "token-count.sh")
TOK = "ghs_G04distinctive0token"

os.environ["FAKE_GH_DIR"] = GH_STATE
os.environ["FAKE_FORGE_CALLS"] = FK_CALLS
os.environ["PATH"] = os.path.join(WORK, "bin") + ":" + os.environ["PATH"]

import forge  # noqa: E402
import world as W  # noqa: E402

BV = getattr(forge, "BadValue", None)
CAPS = ["pin", "resolve_threads", "site", "visibility", "ci_logs", "ci_dispatch", "ci_artifact"]
CAPS_NO_DISPATCH = ["pin", "resolve_threads", "site", "visibility", "ci_logs", "ci_artifact"]
fails = 0


def report(ok, name, detail=""):
    global fails
    if ok:
        print("PASS: " + name)
    else:
        fails += 1
        print("FAIL: %s%s" % (name, (": " + detail) if detail else ""))
    sys.stdout.flush()


def put(b, name, value):
    with open(os.path.join(STATE[b], name + ".json"), "w") as f:
        json.dump(value, f)


def get(b, name, empty=None):
    p = os.path.join(STATE[b], name + ".json")
    return json.load(open(p)) if os.path.exists(p) else empty


def setup(b, caps=CAPS, edit=None, seed=True):
    """A fresh state for backend b: the fixture, forge.json with `caps` (None: the fixture's, no list) and `edit`, and (seed)
    an earlier dispatched run 9100 of ci.yml on feat/x, which a dispatch must not take for its own."""
    shutil.rmtree(STATE[b], ignore_errors=True)
    shutil.copytree(os.path.join(HERE, "fixture"), STATE[b])
    if os.path.exists(FK_CALLS):
        os.remove(FK_CALLS)
    fj = get(b, "forge")
    if caps is not None:
        fj["capabilities"] = caps
    fj.update(edit or {})
    put(b, "forge", fj)
    if seed:
        runs = get(b, "ci_runs")
        runs.append({"workflow": "ci.yml", "branch": "feat/x", "event": "workflow_dispatch", "id": 9100, "status": "completed",
                     "conclusion": "success", "head_sha": "d" * 40, "created_at": "2026-05-03T09:00:00Z"})
        put(b, "ci_runs", runs)


def calls(b):
    p = os.path.join(GH_STATE, "calls.jsonl") if b == "github" else FK_CALLS
    return [json.loads(l) for l in open(p) if l.strip()] if os.path.exists(p) else []


class Res:
    """rc: 0 done, 1 a failed call, 2 a rejected value, 3 the capability off, -1 a crash (py: the exception's name in exc)."""

    def __init__(self, rc, b, value=None, exc="", msg="", out="", err="", cap=None, secs=0.0):
        self.rc, self.value, self.exc, self.msg, self.out, self.err, self.cap, self.secs = rc, value, exc, msg, out, err, cap, secs
        self.calls = calls(b)

    def brief(self):
        return "rc=%s %s %r stdout=%r calls=%d" % (self.rc, self.exc, (self.msg or self.err)[:90], self.out[:40], len(self.calls))

    @property
    def text(self):
        return self.msg if self.exc else self.err


def method_of(op):
    return op.replace(" ", "_").replace("-", "_")


def call_py(b, op, kw, env):
    old = {k: os.environ.get(k) for k in env}
    os.environ.update(env)
    t = time.time()
    try:
        try:
            v = getattr(forge.open(SPEC[b]), method_of(op))(**kw)
            return Res(0, b, value=v, secs=time.time() - t)
        except BaseException as e:  # noqa: BLE001 (a missing check or a crash is a failed case, never a crash of the harness)
            if BV is not None and isinstance(e, BV):
                rc = 2
            elif isinstance(e, forge.CapabilityOff):
                rc = 3
            elif isinstance(e, forge.ForgeError):
                rc = 1
            else:
                rc = -1
            return Res(rc, b, exc=type(e).__name__, msg=str(e), cap=getattr(e, "capability", None), secs=time.time() - t)
    finally:
        for k, v in old.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


def cli_args(kw):
    a = []
    for k, v in kw.items():
        for x in (v if isinstance(v, list) else [v]):
            a += ["--" + k.replace("_", "-"), str(x)]
    return a


def call_cli(b, op, kw, env):
    e = dict(os.environ)
    e.update(env)
    t = time.time()
    r = subprocess.run([sys.executable, "-I", os.path.join(SCHED, "forge.py"), "--repo", SPEC[b]] + op.split(" ", 1) + cli_args(kw),
                       capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL, env=e)
    value = None
    if r.returncode == 0:
        try:
            value = json.loads(r.stdout)
        except ValueError:
            pass
    return Res(r.returncode, b, value=value, out=r.stdout, err=r.stderr, secs=time.time() - t)


def call(b, mode, op, kw, env=None):
    return (call_py if mode == "py" else call_cli)(b, op, kw, env or {})


def problems_fail(res, mode, rc, empty_stdout=True):
    """The shape of a call that did not give a result: Python raises the class of rc, the CLI exits rc with one stderr line and
    nothing on stdout."""
    why = []
    if mode == "py":
        want = {1: "a ForgeError that is neither BadValue nor CapabilityOff", 2: "forge.BadValue", 3: "forge.CapabilityOff"}[rc]
        if res.rc != rc:
            why.append("raised %s (rc %s), want %s" % (res.exc or "nothing (returned %r)" % (res.value,), res.rc, want))
    else:
        if res.rc != rc:
            why.append("exit %s, want %s" % (res.rc, rc))
        if res.out:
            why.append("stdout not empty: %r" % res.out[:60])
        if len(res.err.strip().splitlines()) != 1:
            why.append("stderr is not one line: %r" % res.err[:100])
    return why


DISPATCH_PATH = "repos/acme/widgets/actions/workflows/%s/dispatches"


def posts(res):
    return [c for c in res.calls if c.get("method") == "POST" and (c.get("path") or "").endswith("/dispatches")]


# ---------------------------------------------------------------------------------------------------------------------
def section(fn):
    try:
        fn()
    except BaseException as e:  # noqa: BLE001
        report(False, "G09: the harness section %s ran to its end" % fn.__name__, "%s: %s" % (type(e).__name__, e))


# ---- G09-AC-1 -------------------------------------------------------------------------------------------------------
EXACT = ["a=@" + ATFILE, "b=true", "c=123", "d=x=y", "e=line1\nline2", "f="]
EXACT_WANT = {"a": "@" + ATFILE, "b": "true", "c": "123", "d": "x=y", "e": "line1\nline2", "f": ""}
INPUT_SETS = [("one input", ["env=staging"], {"env": "staging"}), ("exact strings (@file, true, 123, =, newline, empty)", EXACT, EXACT_WANT),
              ("no input", [], {})]


def dispatch_ok(ac, b, mode, ans, label, inputs, want, wf="ci.yml", ref="feat/x"):
    setup(b, edit={"dispatch": ans} if b == "github" else None)
    kw = {"workflow": wf, "ref": ref}
    if inputs:
        kw["input"] = list(inputs)
    res = call(b, mode, "ci dispatch", kw, {"FORGE_DISPATCH_WAIT": "5", "FORGE_DISPATCH_POLL": "0.1"})
    log = W.dispatches(W.World(STATE[b]))
    runs = log[-1]["runs"] if log else []
    new = runs[0] if len(runs) == 1 else None
    why = []
    if res.rc != 0:
        why.append("did not succeed: %s" % res.brief())
    else:
        if mode == "cli" and res.out.strip() != json.dumps({"id": new}):
            why.append("stdout %r, want %s" % (res.out[:60], json.dumps({"id": new})))
        if res.value != {"id": new}:
            why.append("result %r, want {'id': %s}" % (res.value, new))
    if len(log) != 1:
        why.append("%d dispatches recorded, want 1" % len(log))
    else:
        if (log[0]["workflow"], log[0]["ref"], log[0]["inputs"]) != (wf, ref, want):
            why.append("recorded %r" % ((log[0]["workflow"], log[0]["ref"], log[0]["inputs"]),))
        if new in (None, 9100):
            why.append("the new run is %r" % (new,))
    if b == "github":
        ps = posts(res)
        if len(ps) != 1:
            why.append("%d POSTs of a dispatch, want 1" % len(ps))
        else:
            p = ps[0]
            av = p["argv"]
            if p["path"] != DISPATCH_PATH % wf:
                why.append("POST to %s" % p["path"])
            if not any(av[i] == "--input" and av[i + 1] == "-" for i in range(len(av) - 1)):
                why.append("the body is not sent with --input -: %s" % av)
            if any(a in ("-f", "-F", "--field", "--raw-field") for a in av):
                why.append("an input or the ref is sent as a field: %s" % av)
            body = p["body"] if isinstance(p["body"], dict) else {}
            if body.get("ref") != ref or body.get("inputs", {}) != want:
                why.append("body %r" % (p["body"],))
        for v in want.values():
            if v and any(v in a for c in res.calls for a in c["argv"]):
                why.append("the value %r is in an argv" % v)
    else:
        n = [c for c in res.calls if c["op"] == "ci_dispatch"]
        if len(n) != 1:
            why.append("%d ci_dispatch calls of the fake forge, want 1" % len(n))
    report(not why, "%s: %s ci dispatch %s -> one dispatch, its run's id printed (%s, answer %s), %s" % (
        ac, mode, label, "ref and inputs recorded", ans if b == "github" else "-", b), "; ".join(why))


def ac1_ok():
    for mode in ("py", "cli"):
        for label, inputs, want in INPUT_SETS:
            for ans in ("id", "none"):
                dispatch_ok("G09-AC-1", "github", mode, ans, label, inputs, want)
            dispatch_ok("G09-AC-1", "fake", mode, None, label, inputs, want)
    # the three accepted workflow forms (the call is made with each, on both backends)
    for wf in ("ci.yaml", "12345"):
        for mode in ("py", "cli"):
            dispatch_ok("G09-AC-1", "github", mode, "none", "--workflow %s" % wf, ["k=val9"], {"k": "val9"}, wf=wf)
            dispatch_ok("G09-AC-1", "fake", mode, None, "--workflow %s" % wf, ["k=val9"], {"k": "val9"}, wf=wf)


def ac1_rejected():
    for b, modes in (("github", ("404", "422")), ("fake", ("404", "422"))):
        for ans in modes:
            for mode in ("py", "cli"):
                setup(b, edit={"dispatch": ans})
                n0 = len(get(b, "ci_runs"))
                res = call(b, mode, "ci dispatch", {"workflow": "ci.yml", "ref": "feat/x", "input": ["k=v"]})
                why = problems_fail(res, mode, 1)
                if not res.text.strip():
                    why.append("no message")
                if len(get(b, "ci_runs")) != n0:
                    why.append("a run was added")
                report(not why, "G09-AC-1: %s ci dispatch rejected by the forge (HTTP %s) is a failed call, no result, %s" % (mode, ans, b),
                       "; ".join(why))


def ac1_not_found_and_two():
    bound = {"FORGE_DISPATCH_WAIT": "1", "FORGE_DISPATCH_POLL": "0.1"}
    for mode in ("py", "cli"):
        setup("github", edit={"dispatch": "never"})
        res = call("github", mode, "ci dispatch", {"workflow": "ci.yml", "ref": "feat/x", "input": ["k=v"]}, bound)
        why = problems_fail(res, mode, 1)
        low = res.text.lower()
        if "accepted" not in low or "not found" not in low:
            why.append("the message does not say the dispatch was accepted and its run not found: %r" % res.text[:160])
        if "ci runs" not in res.text:
            why.append("the message does not send the caller to `ci runs`: %r" % res.text[:160])
        if res.secs > 30:
            why.append("took %.0f s: the bound $FORGE_DISPATCH_WAIT is not read" % res.secs)
        ps = posts(res)
        if len(ps) != 1:
            why.append("%d POSTs, want 1 (never a second dispatch)" % len(ps))
        elif not any(c["method"] == "GET" and (c["path"] or "").endswith("/runs") for c in res.calls[res.calls.index(ps[0]) + 1:]):
            why.append("no listing of the runs after the dispatch")
        report(not why, "G09-AC-1: %s ci dispatch whose run never appears (bound 1 s) exits 1 saying accepted / run not found, no id, github" % mode,
               "; ".join(why))
        setup("github", edit={"dispatch": "two"})
        res = call("github", mode, "ci dispatch", {"workflow": "ci.yml", "ref": "feat/x"}, bound)
        ids = (W.dispatches(W.World(GH_STATE)) or [{"runs": []}])[-1]["runs"]
        why = problems_fail(res, mode, 1)
        if len(ids) != 2 or not all(str(i) in res.text for i in ids):
            why.append("the message does not name both runs %s: %r" % (ids, res.text[:160]))
        report(not why, "G09-AC-1: %s ci dispatch that finds two new runs exits 1 naming both, no id, github" % mode, "; ".join(why))


YML_BAD = ["../pulls/1/merge?x=", "a/b.yml", "ci.yml?x=", "ci.yml#x", "ci%2fx.yml", "ci", ""]
INPUT_BAD = [["novalue"], ["=v"], ["="], ["k=1", "k=2"], ["a=1", "b=2", "a=3"], ["k=1", "k=1"]]


def reject(ac, b, mode, kw, opt, label):
    setup(b)
    res = call(b, mode, "ci dispatch", kw)
    why = problems_fail(res, mode, 2)
    if res.calls:
        why.append("a call was made (%d)" % len(res.calls))
    if mode == "cli" and res.rc == 2 and "--" + opt not in res.err:
        why.append("stderr does not name --%s: %r" % (opt, res.err[:100]))
    if mode == "py" and res.rc == 2 and opt not in res.msg:
        why.append("the message does not name %s: %r" % (opt, res.msg[:100]))
    report(not why, "%s: %s ci dispatch %s is rejected (%s, no call), %s" % (
        ac, mode, label, "forge.BadValue" if mode == "py" else "exit 2", b), "; ".join(why))


def ac1_validation():
    for b in ("github", "fake"):
        for mode in ("py", "cli"):
            for wf in YML_BAD:
                reject("G09-AC-1", b, mode, {"workflow": wf, "ref": "feat/x", "input": ["k=v"]}, "workflow", "--workflow %r" % wf)
            for inp in INPUT_BAD:
                reject("G09-AC-1", b, mode, {"workflow": "ci.yml", "ref": "feat/x", "input": inp}, "input", "--input %r" % (inp,))


def ac1_interface():
    caps = getattr(forge, "CAPABILITIES", ())
    report("ci_dispatch" in caps, "G09-AC-1: forge.CAPABILITIES has ci_dispatch", "got %r" % (caps,))
    report("ci dispatch" in forge.OPERATIONS, "G09-AC-1: forge.OPERATIONS has `ci dispatch`", "got %s" % (forge.OPERATIONS,))
    r = subprocess.run([sys.executable, "-I", os.path.join(SCHED, "forge.py"), "ops"], capture_output=True, text=True, timeout=60)
    try:
        ops = json.loads(r.stdout)
    except ValueError:
        ops = []
    report("ci dispatch" in ops, "G09-AC-1: `forge.py ops` lists `ci dispatch`", "rc %s %r" % (r.returncode, r.stdout[:80]))
    args = getattr(forge, "_ARGS", {}).get("ci dispatch")
    report(args == {"workflow": "str!", "ref": "str!", "input": "list"},
           "G09-AC-1: the operation table has `ci dispatch` with workflow and ref required and input a list", "got %r" % (args,))
    r = subprocess.run([sys.executable, "-I", os.path.join(SCHED, "forge.py"), "--repo", "acme/widgets", "caps"], capture_output=True,
                       text=True, timeout=60)
    report(r.returncode == 0 and "ci_dispatch" in r.stdout, "G09-AC-1: `forge.py caps` of the GitHub backend lists ci_dispatch", "%r" % r.stdout[:100])
    # the default bound is 60 seconds: the constant of the GitHub backend's module, reachable once ci_dispatch is
    why = ""
    try:
        mod = forge._load("github")
        getattr(mod.Backend("acme/widgets"), "ci_dispatch")
        got = getattr(mod, "DISPATCH_WAIT", None)
        ok = got == 60
        why = "DISPATCH_WAIT is %r" % (got,)
    except BaseException as e:  # noqa: BLE001
        ok, why = False, "%s: %s" % (type(e).__name__, e)
    report(ok, "G09-AC-1: the default bound for finding the dispatched run is 60 seconds (the GitHub backend's DISPATCH_WAIT)", why)


def readme_row(op):
    try:
        text = open(os.path.join(SCHED, "forges", "README.md"), encoding="utf-8").read()
    except OSError:
        return None
    m = re.search(r"^## Operations\s*$(.*?)(?=^## |\Z)", text, re.M | re.S)
    for l in (m.group(1) if m else "").splitlines():
        l = l.strip()
        if l.startswith("|"):
            cells = [c.strip() for c in l.strip("|").split("|")]
            if cells and cells[0].strip("`") == op:
                return cells
    return None


def ac1_readme():
    # G04-AC-8's check (readme_check.py) for the new row: four cells, each a link to https://... or `none: capability off`
    row = readme_row("ci dispatch")
    report(row is not None and len(row) == 5, "G09-AC-1: the README's operations table has a row for `ci dispatch`")
    bad = []
    for col, cell in zip(("GitHub", "GitLab", "Gitea", "Forgejo"), (row[1:] if row and len(row) == 5 else [""] * 4)):
        if not (re.search(r"\]\(https://[^)\s]+\)", cell) or cell.startswith("none: capability off")):
            bad.append("%s: %r" % (col, cell[:60]))
    report(row is not None and not bad, "G09-AC-1: the `ci dispatch` row has four filled cells, each a link to https://... or `none: capability off`", "; ".join(bad))
    report(bool(row) and len(row) == 5 and "dispatches" in row[1], "G09-AC-1: the GitHub cell of `ci dispatch` names the dispatches call", "%r" % (row and row[1][:80],))


# ---- G09-AC-2 -------------------------------------------------------------------------------------------------------
def ac2():
    ac = "G09-AC-2"
    for label, b, caps, edit, unconfigured in (("403 from the fake gh", "github", CAPS, {"dispatch": "403"}, False),
                                               ("a refusal in the fake forge", "fake", CAPS, {"dispatch": "403"}, False),
                                               ("a fake forge configured without ci_dispatch", "fake", CAPS_NO_DISPATCH, None, True),
                                               ("a fake forge with no capability list", "fake", None, None, True)):
        for mode in ("py", "cli"):
            setup(b, caps=caps, edit=edit)
            n0 = len(get(b, "ci_runs"))
            res = call(b, mode, "ci dispatch", {"workflow": "ci.yml", "ref": "feat/x", "input": ["k=v"]})
            want = "forge %s lacks ci_dispatch" % ("github" if b == "github" else "fake")
            why = problems_fail(res, mode, 3)
            if mode == "py" and res.rc == 3 and (res.cap != "ci_dispatch" or res.msg != want):
                why.append("capability %r message %r, want %r" % (res.cap, res.msg, want))
            if mode == "cli" and res.rc == 3 and res.err.strip() != want:
                why.append("stderr %r, want %r" % (res.err.strip(), want))
            if unconfigured and res.calls:
                why.append("a call was made (%d): %s" % (len(res.calls), [c.get("op") for c in res.calls][:3]))
            if len(get(b, "ci_runs")) != n0 or get(b, "dispatches", []):
                why.append("a dispatch was recorded")
            report(not why, "%s: %s ci dispatch with %s exits 3 naming ci_dispatch, no result%s, %s" % (
                ac, mode, label, ", no call" if unconfigured else "", b), "; ".join(why))


# ---- G09-AC-5 -------------------------------------------------------------------------------------------------------
KEYS = ("id", "name", "conclusion", "log", "html_url")


def exp_jobs(b, run, attempt=None):
    """The jobs the fixture holds: the run's own (ci_jobs.json, the latest attempt) or those of an attempt, each with the
    web page the fixture gives it."""
    fx = os.path.join(HERE, "fixture")
    if attempt is None:
        jobs = json.load(open(os.path.join(fx, "ci_jobs.json")))[str(run)]
    else:
        jobs = json.load(open(os.path.join(fx, "ci_attempts.json")))[str(run)][str(attempt)]
    urls = json.load(open(os.path.join(fx, "ci_job_urls.json")))
    return [dict({k: j[k] for k in ("id", "name", "conclusion", "log")}, html_url=PREFIX[b] + urls[str(j["id"])]) for j in jobs]


def same_jobs(got, want):
    if not isinstance(got, list) or len(got) != len(want):
        return "got %s jobs, want %d (%r)" % (len(got) if isinstance(got, list) else got, len(want), str(got)[:80])
    for g, w in zip(got, want):
        for k in KEYS:
            if not isinstance(g, dict) or g.get(k) != w[k]:
                return "job %s: %s is %r, want %r" % (w["id"], k, (g or {}).get(k) if isinstance(g, dict) else g, w[k])
    return ""


_WORKS = {}


def attempt_works(b, mode):
    """(precondition of the failing-attempt cases) attempt 1 of run 9001 is served, so a failure of the others is the missing
    attempt's and not a missing option."""
    if (b, mode) not in _WORKS:
        setup(b)
        r = call(b, mode, "ci logs", {"run": 9001, "attempt": 1})
        _WORKS[(b, mode)] = r.rc == 0 and not same_jobs(r.value, exp_jobs(b, 9001, 1))
    return _WORKS[(b, mode)]


def ac5():
    ac = "G09-AC-5"
    for b in ("github", "fake"):
        for mode in ("py", "cli"):
            for run, att in ((9001, 1), (9001, 2)):
                setup(b)
                res = call(b, mode, "ci logs", {"run": run, "attempt": att})
                why = [] if res.rc == 0 else ["did not succeed: %s" % res.brief()]
                if res.rc == 0:
                    bad = same_jobs(res.value, exp_jobs(b, run, att))
                    if bad:
                        why.append(bad)
                report(not why, "%s: %s ci logs --run %d --attempt %d gives that attempt's jobs, each with id, name, conclusion, log and html_url, %s" % (
                    ac, mode, run, att, b), "; ".join(why))
            # attempt 1 differs from the latest attempt's (and attempt 2 is the latest one)
            setup(b)
            first = call(b, mode, "ci logs", {"run": 9001, "attempt": 1})
            latest = call(b, mode, "ci logs", {"run": 9001})
            ok = first.rc == 0 and latest.rc == 0 and first.value != latest.value and \
                not ({j["id"] for j in first.value} & {j["id"] for j in latest.value}) and \
                all(a["log"] != c["log"] for a in first.value for c in latest.value)
            report(ok, "%s: %s ci logs of attempt 1 differs from the latest attempt's (other jobs, other logs), %s" % (ac, mode, b),
                   "%s / %s" % (first.brief(), latest.brief()))
            for run in (9001, 9002, 9004):
                setup(b)
                res = call(b, mode, "ci logs", {"run": run})
                why = [] if res.rc == 0 else ["did not succeed: %s" % res.brief()]
                if res.rc == 0:
                    bad = same_jobs(res.value, exp_jobs(b, run))
                    if bad:
                        why.append(bad)
                report(not why, "%s: %s ci logs --run %d without --attempt gives each job an html_url (the forge's), %s" % (ac, mode, run, b),
                       "; ".join(why))
            # an attempt the run lacks: a failed call, never an empty list
            for run, att in ((9001, 3), (9001, 99), (9002, 1), (424242, 1)):
                setup(b)
                res = call(b, mode, "ci logs", {"run": run, "attempt": att})
                why = problems_fail(res, mode, 1)
                if res.rc == 1 and not res.text.strip():
                    why.append("no message")
                if not attempt_works(b, mode):
                    why.append("(precondition) attempt 1 of run 9001 is not served")
                report(not why, "%s: %s ci logs --run %d --attempt %d (the run has no such attempt) exits 1, never an empty list, %s" % (
                    ac, mode, run, att, b), "; ".join(why))
            # below 1: exit 2 with no call
            for att in (0, -1):
                setup(b)
                res = call(b, mode, "ci logs", {"run": 9001, "attempt": att})
                why = problems_fail(res, mode, 2)
                if res.calls:
                    why.append("a call was made (%d)" % len(res.calls))
                if not attempt_works(b, mode):
                    why.append("(precondition) attempt 1 of run 9001 is not served")
                report(not why, "%s: %s ci logs --attempt %d is rejected (%s, no call), %s" % (
                    ac, mode, att, "forge.BadValue" if mode == "py" else "exit 2", b), "; ".join(why))
            # a refused attempt listing: exit 3 naming ci_logs
            setup(b, edit={"refuse_attempts": True})
            res = call(b, mode, "ci logs", {"run": 9001, "attempt": 1})
            want = "forge %s lacks ci_logs" % b
            why = problems_fail(res, mode, 3)
            if mode == "py" and res.rc == 3 and (res.cap != "ci_logs" or res.msg != want):
                why.append("capability %r message %r, want %r" % (res.cap, res.msg, want))
            if mode == "cli" and res.rc == 3 and res.err.strip() != want:
                why.append("stderr %r, want %r" % (res.err.strip(), want))
            if not attempt_works(b, mode):
                why.append("(precondition) attempt 1 of run 9001 is not served")
            report(not why, "%s: %s ci logs --attempt with the attempt listing refused exits 3 naming ci_logs, no result, %s" % (ac, mode, b),
                   "; ".join(why))
    # G08's call without --attempt is not an attempt listing: the refusal of attempts leaves it alone
    for b in ("github", "fake"):
        setup(b, edit={"refuse_attempts": True})
        res = call(b, "cli", "ci logs", {"run": 9001})
        report(res.rc == 0 and not same_jobs(res.value, exp_jobs(b, 9001)),
               "%s: ci logs without --attempt still works when only the attempt listing is refused, %s" % (ac, b), res.brief())
    # the README's ci logs row names the attempt's call
    row = readme_row("ci logs")
    report(bool(row) and len(row) == 5 and "attempt" in row[1], "%s: the GitHub cell of the README's `ci logs` row names the attempt's call" % ac,
           "%r" % (row and row[1][:100],))


# ---- the token (G04-AC-3's checks for the new calls) ------------------------------------------------------------------
def token():
    for label, b_edit, op, kw in (("ci dispatch (answer names the run)", {"dispatch": "id"}, "ci dispatch", {"workflow": "ci.yml", "ref": "feat/x", "input": ["k=v"]}),
                                  ("ci dispatch (found by listing)", {"dispatch": "none"}, "ci dispatch", {"workflow": "ci.yml", "ref": "feat/x", "input": ["k=v"]}),
                                  ("ci dispatch (run not found, bound 1 s)", {"dispatch": "never"}, "ci dispatch", {"workflow": "ci.yml", "ref": "feat/x"}),
                                  ("ci dispatch (403)", {"dispatch": "403"}, "ci dispatch", {"workflow": "ci.yml", "ref": "feat/x"}),
                                  ("ci logs --attempt 1", {}, "ci logs", {"run": 9001, "attempt": 1}),
                                  ("ci logs --attempt 1 (refused)", {"refuse_attempts": True}, "ci logs", {"run": 9001, "attempt": 1})):
        setup("github", edit=b_edit)
        cnt = os.path.join(WORK, "token-count")
        if os.path.exists(cnt):
            os.remove(cnt)
        res = call_cli("github", op, kw, {"NOODLEBOT_FORGE_TOKEN_SCRIPT": TS, "TOKEN_COUNT_FILE": cnt,
                                          "FORGE_DISPATCH_WAIT": "1", "FORGE_DISPATCH_POLL": "0.1"})
        why = []
        if not res.calls:
            why.append("no gh call was made: %s" % res.brief())
        toks = {c["gh_token"] for c in res.calls}
        if res.calls and toks != {TOK}:
            why.append("gh saw the tokens %r, want only the script's" % (toks,))
        if any(TOK in json.dumps(c["argv"]) for c in res.calls):
            why.append("the token is in an argv")
        if TOK in res.out or TOK in res.err:
            why.append("the token is in the output")
        report(not why, "G09-AC-1: %s: the token is in GH_TOKEN of every gh call and in no argv, stdout or stderr" % label, "; ".join(why))


def main():
    work = os.path.join(WORK, "cwd")
    os.makedirs(work, exist_ok=True)
    os.chdir(work)
    for fn in (ac1_interface, ac1_readme, ac1_ok, ac1_rejected, ac1_not_found_and_two, ac1_validation, ac2, ac5, token):
        t = time.time()
        section(fn)
        print("# %s %.1fs" % (fn.__name__, time.time() - t))
    print("DONE")


main()
sys.exit(0)
