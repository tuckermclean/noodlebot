#!/usr/bin/env python3
"""The cases of scheduler/forge-g11.test.sh (G11-AC-1 .. G11-AC-3): the values that reach a request path, a query, a web
URL or a git argument, checked before any call.

  g11.py <workdir>     run every case and print one PASS:/FAIL: line per check (details after the name), then "DONE".

<workdir> holds what forge-g11.test.sh made: bin/gh (the emulator, recording each call in <state>/calls.jsonl), bin/git
(recording its argv in gitlog, running the real git), checkout/ (a repository with branches), bare-template.git and
site-body.json. The GitHub backend runs over the emulator (state <workdir>/gh-state, repository acme/widgets), the fake
forge over <workdir>/fake-state; the fake forge's calls are recorded by fake.py in <workdir>/fake-calls.jsonl
($FAKE_FORGE_CALLS). Each backend is driven through the Python interface and through the CLI. A push goes to a local bare
repository (the GitHub clone URL is redirected to it with url.<bare>.insteadOf), never to the network.
Environment: GH_TOKEN and NOODLEBOT_FORGE* are unset by the caller; HOME is a scratch folder.
"""
import json
import os
import re
import shutil
import subprocess
import sys
from urllib.parse import urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
SCHED = os.path.dirname(os.path.dirname(HERE))
WORK = os.path.abspath(sys.argv[1])
REAL_GIT = sys.argv[2]
sys.path.insert(0, SCHED)
sys.path.insert(0, HERE)

GH_URL = "https://github.com/acme/widgets"
GH_STATE = os.path.join(WORK, "gh-state")
FK_STATE = os.path.join(WORK, "fake-state")
FK_CALLS = os.path.join(WORK, "fake-calls.jsonl")
GITLOG = os.path.join(WORK, "gitlog")
CHECKOUT = os.path.join(WORK, "checkout")
SITE = os.path.join(WORK, "site-body.json")
BARE = {"github": os.path.join(WORK, "bare-gh.git"), "fake": os.path.join(FK_STATE, "repo.git")}
STATE = {"github": GH_STATE, "fake": FK_STATE}
SPEC = {"github": "acme/widgets", "fake": "fake:" + FK_STATE}

os.environ["FAKE_GH_DIR"] = GH_STATE
os.environ["FAKE_FORGE_CALLS"] = FK_CALLS
os.environ["PATH"] = os.path.join(WORK, "bin") + ":" + os.environ["PATH"]
os.environ.update(GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="url.%s.insteadOf" % BARE["github"], GIT_CONFIG_VALUE_0=GH_URL,
                  GIT_ALLOW_PROTOCOL="file", GIT_CEILING_DIRECTORIES=os.path.dirname(WORK))

import forge  # noqa: E402

BV = getattr(forge, "BadValue", None)
fails = 0


def report(ok, name, detail=""):
    global fails
    if ok:
        print("PASS: " + name)
    else:
        fails += 1
        print("FAIL: %s%s" % (name, (": " + detail) if detail else ""))
    sys.stdout.flush()


def reset(b, bare=False):
    shutil.rmtree(STATE[b], ignore_errors=True)
    shutil.copytree(os.path.join(HERE, "fixture"), STATE[b])
    if bare:
        shutil.rmtree(BARE[b], ignore_errors=True)
        shutil.copytree(os.path.join(WORK, "bare-template.git"), BARE[b])
    for p in (FK_CALLS, GITLOG):
        if os.path.exists(p):
            os.remove(p)


def calls(b):
    p = os.path.join(GH_STATE, "calls.jsonl") if b == "github" else FK_CALLS
    return [json.loads(l) for l in open(p) if l.strip()] if os.path.exists(p) else []


def gitlog():
    return [l for l in open(GITLOG).read().splitlines() if l.strip()] if os.path.exists(GITLOG) else []


class Res:
    def __init__(self, rc, exc="", msg="", out="", err="", b=None):
        self.rc, self.exc, self.msg, self.out, self.err = rc, exc, msg, out, err
        self.calls, self.git = calls(b), gitlog()

    def brief(self):
        return "rc=%s %s %r calls=%d git=%d" % (self.rc, self.exc, (self.msg or self.err)[:80], len(self.calls), len(self.git))


def jsonable(v):
    return json.loads(json.dumps(v, default=str))


def run_py(b, op, kw):
    reset(b, op == "branch push")
    try:
        f = forge.open(SPEC[b])
        getattr(f, op.replace(" ", "_").replace("-", "_"))(**kw)
        return Res(0, b=b)
    except BaseException as e:  # noqa: BLE001 (a missing check or a crash is a failed case, never a crash of the harness)
        bad = BV is not None and isinstance(e, BV)
        return Res(2 if bad else 1, type(e).__name__, str(e), b=b)


def cli_args(kw):
    a = []
    for k, v in kw.items():
        for x in (v if isinstance(v, list) else [v]):
            a += ["--" + k.replace("_", "-"), str(x)]
    return a


def run_cli(b, op, kw):
    reset(b, op == "branch push")
    r = subprocess.run([sys.executable, "-I", os.path.join(SCHED, "forge.py"), "--repo", SPEC[b]] + op.split(" ", 1) + cli_args(kw),
                       capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
    return Res(r.returncode, out=r.stdout, err=r.stderr, b=b)


def named(res, opt):
    return opt.replace("_", "-") in (res.msg + res.err) or opt in (res.msg + res.err)


def check_reject(b, mode, op, kw, opt, label):
    """A rejected value: exit 2 / BadValue naming the option, nothing on stdout, one stderr line, no call, no git command."""
    res = (run_py if mode == "py" else run_cli)(b, op, kw)
    why = []
    if mode == "py":
        if BV is None:
            why.append("forge.BadValue does not exist")
        elif res.rc != 2:
            why.append("not BadValue (%s)" % (res.exc or "returned"))
        elif not named(res, opt):
            why.append("message does not name %s: %r" % (opt, res.msg))
    else:
        if res.rc != 2:
            why.append("exit %s, not 2" % res.rc)
        if res.out:
            why.append("stdout not empty")
        if len(res.err.strip().splitlines()) != 1:
            why.append("stderr is not one line: %r" % res.err[:100])
        elif "--" + opt.replace("_", "-") not in res.err:
            why.append("stderr does not name --%s: %r" % (opt.replace("_", "-"), res.err[:100]))
    if res.calls:
        why.append("a call was made (%d)" % len(res.calls))
    if res.git:
        why.append("git was run: %s" % res.git[:2])
    return res, why


def reject_cases(ac, op, opt, values, kw_of, backends=("github", "fake"), cli_values=None):
    for h in values:
        for b in backends:
            for mode in ("py", "cli"):
                if mode == "cli" and cli_values is not None and h not in cli_values:
                    continue
                try:
                    _, why = check_reject(b, mode, op, kw_of(h), opt, "")
                except Exception as e:  # noqa: BLE001
                    why = ["harness error %s: %s" % (type(e).__name__, e)]
                report(not why, "%s: %s %s --%s %r is rejected (exit 2 / BadValue, no call), %s" % (
                    ac, mode, op, opt.replace("_", "-"), h, b), "; ".join(why))


def path_of(rec):
    return rec.get("path")


def accept_cases(ac, op, opt, values, kw_of, want=None, backends=("github", "fake"), cli_values=None):
    """An accepted value: not exit 2 / BadValue, the backend is called (and, on GitHub, as want(value) says: (method, path))."""
    for h in values:
        for b in backends:
            for mode in ("py", "cli"):
                if mode == "cli" and cli_values is not None and h not in cli_values:
                    continue
                try:
                    res = (run_py if mode == "py" else run_cli)(b, op, kw_of(h))
                    why = []
                    if res.rc == 2:
                        why.append("rejected: %s" % res.brief())
                    if not res.calls:
                        why.append("no call made: %s" % res.brief())
                    elif want and b == "github":
                        exp = want(h)
                        got = [(c["method"], path_of(c)) for c in res.calls]
                        if exp not in got:
                            why.append("want call %s, got %s" % (exp, got[:3]))
                    elif want and b == "fake" and not any(c["op"] == op.replace(" ", "_").replace("-", "_") for c in res.calls):
                        why.append("the fake forge was not called for %s" % op)
                except Exception as e:  # noqa: BLE001
                    why = ["harness error %s: %s" % (type(e).__name__, e)]
                report(not why, "%s: %s %s --%s %r is accepted, %s" % (ac, mode, op, opt.replace("_", "-"), h, b), "; ".join(why))


# ---------------------------------------------------------------------------------------------------------------------
def section(fn):
    try:
        fn()
    except BaseException as e:  # noqa: BLE001
        report(False, "G11: the harness section %s ran to its end" % fn.__name__, "%s: %s" % (type(e).__name__, e))


def ac_base():
    report(BV is not None, "G11-AC-1: forge.BadValue exists", "forge has no BadValue")
    report(BV is not None and isinstance(BV, type) and issubclass(BV, forge.ForgeError),
           "G11-AC-1: forge.BadValue is a subclass of forge.ForgeError")


YML = ["../pulls/1?x=", "a/b.yml", "ci.yml?x=1", "ci.yml#x", "%2e%2e.yml", "ci.yml/", "ci.txt", ""]


def ac1():
    kw = lambda w: {"workflow": w, "sha": "c0ffee" + "0" * 34}
    accept_cases("G11-AC-1", "ci runs", "workflow", ["test.yml", "a-b_c.1.yaml", "12345"], kw,
                 want=lambda w: ("GET", "repos/acme/widgets/actions/workflows/%s/runs" % w))
    reject_cases("G11-AC-1", "ci runs", "workflow", YML, kw)


def sha_kw(s):
    return {"sha": s}


def ac2_simple():
    ac = "G11-AC-2"
    # commit checks --sha
    accept_cases(ac, "commit checks", "sha", ["abcd", "5" * 40, "a" * 64], sha_kw,
                 want=lambda s: ("GET", "repos/acme/widgets/commits/%s/check-runs" % s), cli_values=["abcd"])
    reject_cases(ac, "commit checks", "sha", ["abc", "g123", "", "a" * 65, "../x", "abcd/..", "main", "abcd?x=1", "abcd#x", "%2e%2e"],
                 sha_kw, cli_values=["abc", "main"])
    # issue comments --since
    sk = lambda s: {"number": 1, "since": s}
    accept_cases(ac, "issue comments", "since", ["2026-05-02T00:00:00Z", "2026-05-02T00:00:00.123Z", "2026-05-02T00:00:00.5Z"], sk,
                 want=lambda s: ("GET", "repos/acme/widgets/issues/1/comments"), cli_values=["2026-05-02T00:00:00.123Z"])
    reject_cases(ac, "issue comments", "since",
                 ["2026-05-02", "2026-05-02T00:00:00", "2026-05-02T00:00:00+00:00", "x&per_page=1", "2026-05-02T00:00:00Z&x=1",
                  "2026-05-02T00:00:00Z#x", "../x", "yesterday", "2026-05-02T00:00:00Z "], sk,
                 cli_values=["2026-05-02", "x&per_page=1"])
    # site publish --target
    tk = lambda t: {"target": t, "input": SITE}
    accept_cases(ac, "site publish", "target", ["gist123", "a1B2", "0"], tk, want=lambda t: ("PATCH", "gists/%s" % t),
                 cli_values=["gist123"])
    reject_cases(ac, "site publish", "target", ["", "../x", "a/b", "x?y=1", "a-b", "a_b", "x#y", "%2e%2e", ".", "..", "x&y=1"], tk,
                 cli_values=["", "a-b"])
    # label remove --name
    nk = lambda n: {"number": 1, "name": n}
    accept_cases(ac, "label remove", "name", ["bug", "good first issue", "a/b", "x?y=1", "..."], nk,
                 want=lambda n: ("DELETE", "repos/acme/widgets/issues/1/labels/" + re.sub(r"[^A-Za-z0-9_.~-]", lambda m: "%%%02X" % ord(m[0]), n)),
                 cli_values=["good first issue"])
    reject_cases(ac, "label remove", "name", ["", ".", ".."], nk, cli_values=["", ".."])


def ac2_ref():
    ac = "G11-AC-2"
    for kind, good, bad in (("issue", ["5", 5, "123456"], ["abc", "1/2", "../x", "-1", "1?x", "", "1 ", "%2e%2e", "5#x"]),
                            ("pr", ["7", 7], ["x", "5/../6", "a1", ".."]),
                            ("run", ["9001", 9001], ["1a", "../x", "1?x=1", "abcd"]),
                            ("commit", ["abcd", "5" * 40, "a" * 64, "c0ffee"], ["abc", "xyz1", "a" * 65, "../x", "abcd/x", "abcd?x=1", "123", "", "%2e%2e"])):
        for h in bad:
            for b in ("github", "fake"):
                for mode in ("py", "cli"):
                    if mode == "cli" and h != bad[0]:
                        continue
                    _, why = check_reject(b, mode, "repo url", {"kind": kind, "ref": h}, "ref", "")
                    report(not why, "%s: %s repo url --kind %s --ref %r is rejected, %s" % (ac, mode, kind, h, b), "; ".join(why))
        for h in good:
            for b in ("github", "fake"):
                for mode in ("py", "cli"):
                    if mode == "cli" and h != good[0]:
                        continue
                    if mode == "cli" and not isinstance(h, str):
                        continue
                    res = None if mode == "py" else run_cli(b, "repo url", {"kind": kind, "ref": h})
                    base = GH_URL if b == "github" else "fake://acme/widgets"
                    tail = {"issue": "/issues/", "pr": "/pull/", "run": "/actions/runs/", "commit": "/commit/"}[kind] + str(h)
                    if mode == "py":
                        try:
                            got = getattr(forge.open(SPEC[b]), "repo_url")(kind=kind, ref=h)
                        except BaseException as e:  # noqa: BLE001
                            got = "%s: %s" % (type(e).__name__, e)
                        ok = got == base + tail
                        detail = "got %r" % (got,)
                    else:
                        ok = res.rc == 0 and json.loads(res.out or "null") == base + tail
                        detail = res.brief() + " " + res.out[:80]
                    report(ok, "%s: %s repo url --kind %s --ref %r gives %s, %s" % (ac, mode, kind, h, base + tail, b), detail)
    # forge.web_url
    for spec, base in (("acme/widgets", GH_URL), ("github:acme/widgets", GH_URL), ("fake:" + FK_STATE, "fake://acme/widgets")):
        for kind, ref, tail in (("issue", 5, "/issues/5"), ("issue", "5", "/issues/5"), ("pr", "12", "/pull/12"),
                                ("commit", "abcd", "/commit/abcd"), ("repo", None, "")):
            reset("fake")
            try:
                got = forge.web_url(spec, kind, ref)
            except BaseException as e:  # noqa: BLE001
                got = "%s: %s" % (type(e).__name__, e)
            report(got == base + tail, "%s: forge.web_url(%r, %r, %r) is %s" % (ac, spec, kind, ref, base + tail), "got %r" % (got,))
        for kind, ref in (("issue", "../x"), ("issue", "x"), ("pr", "1/2"), ("commit", "abc"), ("commit", "../x"), ("commit", "zzzz"),
                          ("run", "1?x")):
            reset("fake")
            try:
                got, exc = forge.web_url(spec, kind, ref), None
            except BaseException as e:  # noqa: BLE001
                got, exc = None, e
            ok = BV is not None and isinstance(exc, BV) and not calls("fake")
            report(ok, "%s: forge.web_url(%r, %r, %r) raises BadValue, no call" % (ac, spec, kind, ref),
                   "got %r %s" % (got, "" if exc is None else "%s: %s" % (type(exc).__name__, exc)))
    # forge.commit_link and the CLI's remote-commit-link
    for url in ("https://github.com/acme/widgets.git", "git@github.com:acme/widgets.git"):
        for sha in ("abcd", "a" * 40, "a" * 64):
            try:
                got = forge.commit_link(url, sha)
            except BaseException as e:  # noqa: BLE001
                got = "%s: %s" % (type(e).__name__, e)
            report(got == GH_URL + "/commit/" + sha, "%s: forge.commit_link(%r, %r) is the commit's link" % (ac, url, sha), "got %r" % (got,))
        for sha in ("abc", "zzzz", "../x", "abcd/x", "a" * 65, "abcd?x"):
            try:
                got, exc = forge.commit_link(url, sha), None
            except BaseException as e:  # noqa: BLE001
                got, exc = None, e
            report(BV is not None and isinstance(exc, BV), "%s: forge.commit_link(%r, %r) raises BadValue" % (ac, url, sha),
                   "got %r %r" % (got, exc))
    for sha, rc in (("abcd1234", 0), ("a" * 40, 0), ("zzzz", 2), ("abc", 2), ("../x", 2), ("a" * 65, 2)):
        r = subprocess.run([sys.executable, "-I", os.path.join(SCHED, "forge.py"), "remote-commit-link", "https://github.com/acme/widgets.git", sha],
                           capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
        why = []
        if r.returncode != rc:
            why.append("exit %d, want %d" % (r.returncode, rc))
        if rc == 2 and (r.stdout or len(r.stderr.strip().splitlines()) != 1):
            why.append("want empty stdout and one stderr line: %r %r" % (r.stdout[:50], r.stderr[:100]))
        if rc == 0 and json.loads(r.stdout or "null") != GH_URL + "/commit/" + sha:
            why.append("wrong link %r" % r.stdout[:100])
        report(not why, "%s: forge.py remote-commit-link URL %r exits %d" % (ac, sha, rc), "; ".join(why))


BRANCH_OK = ["feat/x", "node/G11-forge-path-values", "spec/a.b_c", "main"]
BRANCH_BAD = [":main", "+main", "@", "x#y", "%2e%2e", "-x", "", "src:dst", "a..b", "a b", "x.lock", "/x", "x/", "a//b", "x.", "a/.b",
              "-", "../x", ".", "..", "a@{b}", "a~1", "a^b", "a\\b", "feat/x:main", "+feat/x", "--force", "x\ty"]


def ac2_branch():
    ac = "G11-AC-2"
    # the examples agree with git's own check (and the charset rule), so a RED failure is the missing check
    for h in BRANCH_OK:
        r = subprocess.run([REAL_GIT, "check-ref-format", "--branch", h], capture_output=True)
        report(r.returncode == 0 and re.fullmatch(r"[A-Za-z0-9._/-]+", h) and not h.startswith("-"),
               "G11-AC-2: (precondition) %r is accepted by git check-ref-format --branch and has the charset" % h)
    for h in BRANCH_BAD:
        r = subprocess.run([REAL_GIT, "check-ref-format", "--branch", h], capture_output=True)
        report(r.returncode != 0 or not re.fullmatch(r"[A-Za-z0-9._/-]+", h) or h.startswith("-"),
               "G11-AC-2: (precondition) %r fails git's check, the charset or the leading dash rule" % h)
    kw = lambda h: {"path": CHECKOUT, "branch": h}
    for h in BRANCH_OK:
        for b in ("github", "fake"):
            for mode in ("py", "cli"):
                if mode == "cli" and h != "feat/x":
                    continue
                res = (run_py if mode == "py" else run_cli)(b, "branch push", kw(h))
                want = subprocess.run([REAL_GIT, "-C", CHECKOUT, "rev-parse", "refs/heads/" + h], capture_output=True, text=True).stdout.strip()
                got = subprocess.run([REAL_GIT, "--git-dir", BARE[b], "rev-parse", "refs/heads/" + h], capture_output=True, text=True).stdout.strip()
                report(res.rc == 0 and got == want and want and any(" push " in " %s " % l for l in res.git),
                       "%s: %s branch push --branch %r is accepted and pushes, %s" % (ac, mode, h, b), res.brief())
    for h in BRANCH_BAD:
        for b in ("github", "fake"):
            for mode in ("py", "cli"):
                if mode == "cli" and h not in (":main", "+main", "@", "-x"):
                    continue
                _, why = check_reject(b, mode, "branch push", kw(h), "branch", "")
                report(not why, "%s: %s branch push --branch %r is rejected before any git command, %s" % (ac, mode, h, b), "; ".join(why))


# ---------------------------------------------------------------------------------------------------------------------
HOSTILE = ["../x", "a/b", "x?y=1", "x#y", "x&y=1", "%2e%2e", ".", ".."]
PLAIN = {"kind": "issue", "ref": "1", "state": "open", "limit": 5, "number": 1, "to": 401, "head": "feat/x", "base": "main",
         "title": "t", "body": "b", "thread": "PRRT_5a", "label": "bug", "comment": 101, "reaction": "+1", "name": "bug",
         "color": "ededed", "description": "d", "sha": "abcdef12", "workflow": "ci.yml", "branch": "main", "event": "push",
         "run": 9001, "job": "lint", "target": "gist123", "input": SITE, "path": CHECKOUT,
         "since": "2026-05-02T00:00:00Z", "labels": ["bug"], "fields": ["number"]}
VALUE_FLAGS = {"-X", "--method", "-f", "-F", "--field", "--raw-field", "--input", "-q", "--jq", "-H", "--header", "--cache"}


def target_of(argv):
    """The request target (path and query, as the argv gives it) of a recorded `gh api` call, else None."""
    if not argv or argv[0] != "api":
        return None
    i, t = 1, None
    while i < len(argv):
        if argv[i] in VALUE_FLAGS:
            i += 1
        elif not argv[i].startswith("-"):
            t = argv[i]
        i += 1
    return t


def target_problem(h, target):
    """Why the target lets h point the request elsewhere, else None."""
    path, _, query = target.partition("?")
    if "#" in target:
        return "a '#' in the target"
    if "?" in query:
        return "a second '?' in the target"
    segs = path.split("/")
    if "." in segs or ".." in segs:
        return "a dot segment in the path"
    if h in target and any(c in h for c in "/?#&%"):
        return "the value raw in the target"
    if h in segs and h in (".", ".."):
        return "a dot segment"
    return None


def plain_for(name, kind):
    if name in PLAIN:
        return PLAIN[name]
    base = kind.rstrip("!")
    return {"int": 1, "list": ["plain1"], "text": "text"}.get(base, "plain1")


def ac3():
    ac = "G11-AC-3"
    args = getattr(forge, "_ARGS", None)
    report(isinstance(args, dict) and args, "G11-AC-3: the operation table forge._ARGS is readable")
    if not isinstance(args, dict):
        return
    for op, name in (("site publish", "input"), ("branch push", "path")):
        report(args.get(op, {}).get(name, "").rstrip("!") == "path",
               "G11-AC-3: the operation table marks %s --%s with the kind path" % (op, name), "kind is %r" % args.get(op, {}).get(name))
    reset("github")
    total = 0
    for op, spec in args.items():
        meth = op.replace(" ", "_").replace("-", "_")
        for name, kind in spec.items():
            base = kind.rstrip("!")
            if base not in ("str", "list"):
                continue
            problems = []
            for h in HOSTILE:
                kw = {n: plain_for(n, k) for n, k in spec.items() if k.endswith("!") and k.rstrip("!") != "bool"}
                kw[name] = [h] if base == "list" else h
                reset("github")
                try:
                    getattr(forge.open(SPEC["github"]), meth)(**kw)
                    outcome = "ok"
                except BaseException as e:  # noqa: BLE001
                    outcome = "badvalue" if (BV is not None and isinstance(e, BV)) else "failed"
                cs = calls("github")
                total += len(cs)
                if outcome == "badvalue":
                    if cs or gitlog():
                        problems.append("%r: BadValue after a call" % h)
                    continue
                for c in cs:
                    t = target_of(c["argv"])
                    if t is None:
                        continue
                    p = target_problem(h, t)
                    if p:
                        problems.append("%r reached %s (%s)" % (h, t, p))
            report(not problems, "%s: sweep %s --%s (%s)" % (ac, op, name.replace("_", "-"), base), "; ".join(problems[:4]))
    report(total >= 20, "G11-AC-3: (precondition) the sweep reached the emulated GitHub API (%d calls)" % total)


# ---------------------------------------------------------------------------------------------------------------------
# G11-AC-4: forges/README.md names the accepted form of each checked value, forge.BadValue and the kind path. A value's
# form is named in one table row or one paragraph that also names the operation and the option.
FORMS = [  # (what, operation, option, [regexes the same block holds])
    ("ci runs --workflow", "ci runs", "workflow", [r"\.yml", r"\.yaml", r"numeric|digits|number"]),
    ("commit checks --sha", "commit checks", "sha", [r"hex", r"\b4\b", r"\b64\b"]),
    ("issue comments --since", "issue comments", "since", [r"YYYY-MM-DDTHH:MM:SSZ", r"fraction"]),
    ("site publish --target", "site publish", "target", [r"letters", r"digits"]),
    ("label remove --name", "label remove", "name", [r"empty", r"`\.`|\"\.\"|'\.'", r"`\.\.`"]),
    ("repo url --ref", "repo url", "ref", [r"number|digits", r"hex", r"\b64\b"]),
    ("branch push --branch", "branch push", "branch", [re.escape("[A-Za-z0-9._/-]"), r"check-ref-format"]),
]


def readme():
    try:
        text = open(os.path.join(SCHED, "forges", "README.md"), encoding="utf-8").read()
    except OSError:
        text = ""
    blocks = []
    for para in re.split(r"\n\s*\n", text):
        lines = para.splitlines()
        blocks.append(para)
        blocks += [l for l in lines if l.lstrip().startswith(("|", "-", "*"))]
    for what, op, opt, pats in FORMS:
        ok = any(op in b and re.search(r"--%s\b|`%s`" % (opt, opt), b) and all(re.search(p, b) for p in pats) for b in blocks)
        report(ok, "G11-AC-4: the README names the accepted form of %s (operation, option and %s in one row or paragraph)" % (what, ", ".join(pats)))
    report("BadValue" in text and any("BadValue" in b and re.search(r"exit(s)? 2|exit code 2|usage error", b) for b in blocks),
           "G11-AC-4: the README says a rejected value is forge.BadValue (exit 2)")
    report(any(re.search(r"kind `path`|`path` kind|kind of `path`|kind \"path\"", b) and re.search(r"site publish|branch push|local", b) for b in blocks),
           "G11-AC-4: the README says a local path argument has the kind path")
    report(any(re.search(r"web_url", b) and re.search(r"commit_link", b) and "BadValue" in b for b in blocks) or ("web_url" in text and "commit_link" in text),
           "G11-AC-4: the README names forge.web_url and forge.commit_link among the checked calls")


def main():
    work = os.path.join(WORK, "cwd")
    os.makedirs(work, exist_ok=True)
    os.chdir(work)
    for b in ("feat/x", "node/G11-forge-path-values", "spec/a.b_c"):
        subprocess.run([REAL_GIT, "-C", CHECKOUT, "branch", b], capture_output=True)
    import time
    for fn in (ac_base, ac1, ac2_simple, ac2_ref, ac2_branch, ac3, readme):
        t = time.time()
        section(fn)
        print("# %s %.1fs" % (fn.__name__, time.time() - t))
    print("DONE")


main()
sys.exit(0)
