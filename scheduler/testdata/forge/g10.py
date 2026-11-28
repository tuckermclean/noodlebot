#!/usr/bin/env python3
"""The cases of scheduler/forge.test.sh for G10 (G10-AC-1, G10-AC-2, G10-AC-5): `branch delete --branch NAME`.

  g10.py <github|fake> <workdir>    run every case against one backend, through the Python interface and the CLI, and print one
                                    PASS:/FAIL: line per check (details indented), then "DONE".
  g10.py readme <README.md>         the README's row of the operation (G10-AC-1) and `forge.py ops`.

<workdir> holds bin/gh (the emulator, testdata/forge/fakegh.py). The GitHub backend runs over it (state <workdir>/state, calls
recorded in calls.jsonl with their -f fields), the fake forge over the same fixture content with a repo.git whose heads are
the branches of a case (its calls are recorded by fake.py in <workdir>/fake-calls.jsonl, $FAKE_FORGE_CALLS). Expectations are
the same for both backends. Environment: GH_TOKEN and NOODLEBOT_FORGE* are unset by the caller, HOME is a scratch folder.

A refusal of a well-formed name (exit 1) is a ForgeError that is neither BadValue nor CapabilityOff; its stderr line names the
branch and a reason word (REASON below). Scratch lives under <workdir>; nothing is removed here (the caller removes it).
"""
import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCHED = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, SCHED)
sys.path.insert(0, HERE)
fails = 0


def line(ok, name, details=()):
    global fails
    print("%s: %s" % ("PASS" if ok else "FAIL", name))
    if not ok:
        fails += 1
        for d in details:
            print("  " + d)
    sys.stdout.flush()


# ------------------------------------------------------------------------------------------------------------ README
def readme(path):
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        text = ""
    m = re.search(r"^## Operations\s*$(.*?)(?=^## |\Z)", text, re.M | re.S)
    rows = [[c.strip() for c in l.strip().strip("|").split("|")] for l in (m.group(1) if m else "").splitlines() if l.strip().startswith("|")]
    row = [r for r in rows if r and r[0].strip("`") == "branch delete"]
    line(bool(row) and len(row[0]) == 5, "G10-AC-1: the README's operations table has a row for `branch delete`", ["rows: %s" % [r[0] for r in rows][:60]])
    bad = []
    for col, cell in zip(("GitHub", "GitLab", "Gitea", "Forgejo"), (row[0][1:] if row and len(row[0]) == 5 else [""] * 4)):
        if not (re.search(r"\]\(https://[^)\s]+\)", cell) or cell.startswith("none: capability off")):
            bad.append("%s: %r" % (col, cell[:60]))
    line(bool(row) and not bad, "G10-AC-1: the `branch delete` row has four filled cells, each a link to https://... API documentation or `none: capability off`", bad)
    import forge
    line("branch delete" in forge.OPERATIONS, "G10-AC-1: forge.OPERATIONS has `branch delete`", ["got %s" % forge.OPERATIONS[-3:]])
    r = subprocess.run([sys.executable, "-I", os.path.join(SCHED, "forge.py"), "ops"], capture_output=True, text=True, stdin=subprocess.DEVNULL)
    line(r.returncode == 0 and "branch delete" in r.stdout, "G10-AC-1: `forge.py ops` lists `branch delete`", [r.stdout[-80:]])
    line(r.returncode == 0 and "branch_delete" in getattr(forge, "CAPABILITIES", ()),
         "G10-AC-2: forge.CAPABILITIES has branch_delete", ["got %r" % (getattr(forge, "CAPABILITIES", None),)])


if sys.argv[1] == "readme":
    readme(sys.argv[2])
    print("DONE")
    sys.exit(0)

backend, WORK = sys.argv[1], os.path.abspath(sys.argv[2])
GH = backend == "github"
STATE = os.path.join(WORK, "state")
FK_CALLS = os.path.join(WORK, "fake-calls.jsonl")
BARE_T = os.path.join(WORK, "bare-template.git")
SPEC = "acme/widgets" if GH else "fake:" + STATE
NAME = "github" if GH else "fake"
os.environ["FAKE_GH_DIR"] = STATE
os.environ["FAKE_FORGE_CALLS"] = FK_CALLS
os.environ["PATH"] = os.path.join(WORK, "bin") + ":" + os.environ["PATH"]
os.environ["GIT_CEILING_DIRECTORIES"] = os.path.dirname(WORK)

import forge  # noqa: E402

BV = getattr(forge, "BadValue", None)
CAPS = ["pin", "resolve_threads", "site", "visibility", "branch_delete"]
FOUR = ["pin", "resolve_threads", "site", "visibility"]
OWNER = "acme"


def git(*a):
    r = subprocess.run(["git"] + list(a), capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError("git %s: %s" % (" ".join(a), r.stderr.strip()[:200]))
    return r.stdout.strip()


# ------------------------------------------------------------------------------------------------------------ state
def pr(number, head, base, state="open"):
    return {"number": number, "title": "G10 pr", "body": "", "state": state, "head": head, "head_sha": "a" * 40, "base": base,
            "author": {"login": "ada", "is_bot": False, "is_owner": True}, "mergeable": "MERGEABLE", "created_at": "2026-05-01T10:00:00Z",
            "merged_at": "2026-05-02T10:00:00Z" if state == "merged" else None,
            "closed_at": None if state == "open" else "2026-05-02T10:00:00Z"}


def edit(name, fn):
    p = os.path.join(STATE, name + ".json")
    d = json.load(open(p))
    json.dump(fn(d), open(p, "w"))


def setup(branches, prs=(), edits=None, caps=CAPS):
    """A fresh state: the fixture, `branches` [(name, protected, [rule types])] served by the backend, `prs` appended to prs.json,
    forge.json edited with `edits`, the fake forge's capabilities `caps` (None: the fixture's own: none listed)."""
    shutil.rmtree(STATE, ignore_errors=True)
    shutil.copytree(os.path.join(HERE, "fixture"), STATE)
    if os.path.exists(FK_CALLS):
        os.remove(FK_CALLS)
    ed = dict(edits or {})
    if GH:
        json.dump([{"name": n, "protected": p, "rules": list(r)} for n, p, r in branches], open(os.path.join(STATE, "branches.json"), "w"))
    else:
        shutil.copytree(BARE_T, os.path.join(STATE, "repo.git"))
        tip = git("--git-dir", BARE_T, "rev-parse", "refs/heads/seed")
        for n, _, _ in branches:
            git("--git-dir", os.path.join(STATE, "repo.git"), "update-ref", "refs/heads/" + n, tip)
        ed["protected_branches"] = [n for n, p, _ in branches if p]
        ed["branch_rules"] = {n: list(r) for n, _, r in branches if r}
        if caps is not None:
            ed["capabilities"] = caps
    if ed:
        edit("forge", lambda d: dict(d, **ed))
    if prs:
        edit("prs", lambda d: d + list(prs))


def present():
    """The names of the branches the backend still has."""
    if GH:
        p = os.path.join(STATE, "branches.json")
        return sorted(b["name"] for b in json.load(open(p))) if os.path.exists(p) else []
    return sorted(x for x in git("--git-dir", os.path.join(STATE, "repo.git"), "for-each-ref", "--format=%(refname:short)", "refs/heads/").split("\n")
                  if x and x != "seed")


def calls():
    p = os.path.join(STATE, "calls.jsonl") if GH else FK_CALLS
    return [json.loads(l) for l in open(p) if l.strip()] if os.path.exists(p) else []


def gh_calls():
    """The gh emulator's records, a failed call's second record of the same call dropped."""
    out = []
    for c in calls():
        if not out or out[-1] != c:
            out.append(c)
    return out


# ------------------------------------------------------------------------------------------------------------ calls
class Res:
    def __init__(self, **kw):
        self.ok = self.exc = self.msg = self.cap = self.rc = self.out = self.err = None
        self.bad = self.capoff = self.forgeerr = False
        self.__dict__.update(kw)

    def brief(self):
        if self.ok is not None:
            return "ok %s" % json.dumps(self.ok)[:150]
        if self.exc:
            return "raised %s: %s" % (self.exc, (self.msg or "")[:150])
        return "exit %s stdout=%r stderr=%r" % (self.rc, (self.out or "")[:100], (self.err or "")[:150])


def run_py(name):
    try:
        f = forge.open(SPEC)
        return Res(ok=json.loads(json.dumps(f.branch_delete(branch=name))))
    except BaseException as e:  # noqa: BLE001 (a missing operation is a failed case, never a crash of the harness)
        return Res(exc=type(e).__name__, msg=str(e), cap=getattr(e, "capability", None),
                   bad=BV is not None and isinstance(e, BV), capoff=isinstance(e, getattr(forge, "CapabilityOff", ())),
                   forgeerr=isinstance(e, forge.ForgeError))


def run_cli(name):
    r = subprocess.run([sys.executable, "-I", os.path.join(SCHED, "forge.py"), "--repo", SPEC, "branch", "delete", "--branch", name],
                       capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
    ok = None
    if r.returncode == 0:
        try:
            ok = json.loads(r.stdout)
        except ValueError:
            ok = "<not JSON: %r>" % r.stdout[:100]
    return Res(ok=ok, rc=r.returncode, out=r.stdout, err=r.stderr)


RUN = {"py": run_py, "cli": run_cli}


def one_line(err):
    return err.strip() != "" and len(err.strip().splitlines()) == 1


# ------------------------------------------------------------------------------------------------------------ verdicts
def delete_calls(name):
    return [c for c in gh_calls() if c.get("method") == "DELETE"] if GH else []


def v_result(mode, res, name, result):
    why = []
    want = {"branch": name, "result": result}
    if res.ok != want:
        why.append("%s: expected %s, got %s" % (mode, json.dumps(want), res.brief()))
    if mode == "cli" and res.rc != 0:
        why.append("cli: exit %s, not 0" % res.rc)
    return why


def v_refuse(mode, res, name, reason, code=1):
    """A refusal: ForgeError (not BadValue, not CapabilityOff) / exit 1, nothing on stdout, one stderr line naming the branch."""
    why = []
    if mode == "py":
        if not res.forgeerr or res.bad or res.capoff:
            why.append("py: expected a ForgeError (not BadValue, not CapabilityOff), got %s" % res.brief())
        elif name not in (res.msg or "") or (reason and not re.search(reason, res.msg, re.I)):
            why.append("py: the message does not name the branch and the reason /%s/: %r" % (reason, res.msg))
    else:
        if res.rc != code or res.out:
            why.append("cli: expected exit %s and nothing on stdout, got %s" % (code, res.brief()))
        elif not one_line(res.err) or name not in res.err or (reason and not re.search(reason, res.err, re.I)):
            why.append("cli: expected one stderr line naming the branch and the reason /%s/, got %r" % (reason, res.err))
    return why


def v_cap(mode, res):
    why = []
    want = "forge %s lacks branch_delete" % NAME
    if mode == "py":
        if not res.capoff or res.cap != "branch_delete" or want not in (res.msg or ""):
            why.append("py: expected CapabilityOff(branch_delete) '%s', got %s" % (want, res.brief()))
    elif res.rc != 3 or res.out or want not in res.err or not one_line(res.err):
        why.append("cli: expected exit 3, nothing on stdout, one stderr line '%s', got %s" % (want, res.brief()))
    return why


def v_failed(mode, res, text=None):
    """A failed call: a ForgeError (not BadValue, not CapabilityOff) / exit 1, nothing on stdout, a stderr line (with `text`)."""
    why = []
    if mode == "py":
        if not res.forgeerr or res.bad or res.capoff or (text and text not in (res.msg or "")):
            why.append("py: expected a ForgeError%s, got %s" % (" carrying %r" % text if text else "", res.brief()))
    elif res.rc != 1 or res.out or not one_line(res.err) or (text and text not in res.err):
        why.append("cli: expected exit 1, nothing on stdout, one stderr line%s, got %s" % (" carrying %r" % text if text else "", res.brief()))
    return why


def scenario(ac, title, branches, name, want, prs=(), edits=None, caps=CAPS, nocall=False, expect_calls=(), attempt=False, removed=False):
    """Both modes on a fresh state. want: ("deleted",) | ("gone",) | ("refuse", reason) | ("cap",) | ("failed", text|None).
    attempt: the delete is called (and answered otherwise); removed: the forge's answer left the branch gone."""
    why = []
    for mode in ("py", "cli"):
        try:
            setup(branches, prs, edits, caps)
            before = present()
            res = RUN[mode](name)
            kind = want[0]
            w = {"deleted": lambda: v_result(mode, res, name, "deleted"), "gone": lambda: v_result(mode, res, name, "gone"),
                 "refuse": lambda: v_refuse(mode, res, name, want[1] if len(want) > 1 else None),
                 "cap": lambda: v_cap(mode, res), "failed": lambda: v_failed(mode, res, want[1] if len(want) > 1 else None)}[kind]()
            why += w
            after = present()
            if kind == "deleted":
                if after != sorted(b for b in before if b != name):
                    why.append("%s: branches after %s, expected %s without %s" % (mode, after, before, name))
                if GH:
                    dc = delete_calls(name)
                    ok = len(dc) == 1 and dc[0].get("path", "").endswith("git/refs/heads/" + name) and dc[0]["path"] == "repos/acme/widgets/git/refs/heads/" + name
                    if not ok:
                        why.append("%s: expected one DELETE of repos/acme/widgets/git/refs/heads/%s, saw %s" % (mode, name, [(c.get("method"), c.get("path")) for c in dc]))
            else:
                if after != before and not removed:
                    why.append("%s: branches changed from %s to %s" % (mode, before, after))
                if GH and delete_calls(name) and not attempt:
                    why.append("%s: a delete call was made: %s" % (mode, [(c.get("method"), c.get("path")) for c in delete_calls(name)]))
            if nocall and calls():
                why.append("%s: a call was made (%d), the check is made before any call" % (mode, len(calls())))
            for method, tail in expect_calls:
                if GH and not any(c.get("method") == method and c.get("path") == ("repos/acme/widgets/" + tail.replace("<name>", name)).rstrip("/") for c in gh_calls()):
                    why.append("%s: no %s of repos/acme/widgets/%s; saw %s" % (mode, method, tail.replace("<name>", name), [(c.get("method"), c.get("path")) for c in gh_calls()][:8]))
        except Exception as e:  # noqa: BLE001
            why.append("%s: harness error %s: %s" % (mode, type(e).__name__, e))
    line(not why, "%s: [%s] %s" % (ac, NAME, title), why)


# ------------------------------------------------------------------------------------------------------------ cases
KEEP = ("ci-probe/keep", False, [])
MAIN = ("main", False, [])
X = "ci-probe/G10-x"


def cases_delete():
    AC = "G10-AC-1"
    base = [MAIN, (X, False, []), KEEP]
    scenario(AC, "`branch delete --branch %s` deletes it and prints {branch, result: deleted} (Python and CLI); the other branches stay, one delete call of the ref" % X,
             base, X, ("deleted",), expect_calls=[("GET", "branches/<name>"), ("GET", "rules/branches/<name>"), ("GET", "")])
    scenario(AC, "a name that never existed is `gone` (exit 0), nothing deleted", base, "ci-probe/G10-never", ("gone",))
    scenario(AC, "a branch whose rules list no `deletion` rule (only non_fast_forward) is deleted", [MAIN, ("ci-probe/G10-nff", False, ["non_fast_forward"]), KEEP],
             "ci-probe/G10-nff", ("deleted",))
    scenario(AC, "a branch that was the head of a merged PR is deleted", base, X, ("deleted",), prs=[pr(21, X, "main", "merged")])
    scenario(AC, "a branch that is the base of a closed PR is deleted", base, X, ("deleted",), prs=[pr(21, "feat/g10", X, "closed")])
    scenario(AC, "a branch that is the head of an open PR on another branch name does not block (the open PRs of the fixture)", base, X, ("deleted",),
             prs=[pr(21, "ci-probe/G10-other", "main", "open")])
    # a second call on the same name is `gone`
    why = []
    for mode in ("py", "cli"):
        try:
            setup(base)
            r1 = RUN[mode](X)
            r2 = RUN[mode](X)
            why += v_result(mode, r1, X, "deleted") + ["%s second call: %s" % (mode, x) for x in v_result(mode, r2, X, "gone")]
            if present() != sorted(["main", "ci-probe/keep"]):
                why.append("%s: branches after %s" % (mode, present()))
            if GH and len(delete_calls(X)) != 1:
                why.append("%s: %d delete calls for two calls of the operation" % (mode, len(delete_calls(X))))
        except Exception as e:  # noqa: BLE001
            why.append("%s: harness error %s: %s" % (mode, type(e).__name__, e))
    line(not why, "%s: [%s] a second call on the same name prints `gone` and exits 0, with no second delete call" % (AC, NAME), why)


def cases_refuse():
    AC = "G10-AC-1"
    # outside the prefix: refused before any call
    out_base = [MAIN, ("node/G10-x", False, []), ("ci-probe", False, [])]
    for n in ("main", "node/G10-x", "ci-probe"):
        scenario(AC, "`%s` (well-formed, outside the throwaway prefix) is refused: exit 1, one stderr line naming it, nothing on stdout, no call at all" % n,
                 out_base, n, ("refuse", r"prefix|ci-probe|outside|throwaway"), nocall=True)
    scenario(AC, "the default branch is refused (exit 1, naming it and `default`), no delete call", [("ci-probe/trunk", False, []), KEEP], "ci-probe/trunk",
             ("refuse", r"default"), edits={"default_branch": "ci-probe/trunk"})
    scenario(AC, "a protected branch under the prefix (.protected true) is refused (exit 1, naming it and `protect`), no delete call",
             [MAIN, ("ci-probe/G10-prot", True, []), KEEP], "ci-probe/G10-prot", ("refuse", r"protect"))
    scenario(AC, "an unprotected branch whose rules list a `deletion` rule is refused (exit 1, naming it and the rule), no delete call",
             [MAIN, ("ci-probe/G10-rule", False, ["non_fast_forward", "deletion"]), KEEP], "ci-probe/G10-rule", ("refuse", r"protect|deletion|rule"),
             expect_calls=[("GET", "rules/branches/<name>")])
    scenario(AC, "a branch that is the head of an open PR is refused (exit 1, naming it and the PR), no delete call",
             [MAIN, ("ci-probe/G10-head", False, []), KEEP], "ci-probe/G10-head", ("refuse", r"pull request|\bPR\b|open"),
             prs=[pr(21, "ci-probe/G10-head", "main", "open")])
    scenario(AC, "a branch that is the base of an open PR is refused (exit 1, naming it and the PR), no delete call",
             [MAIN, ("ci-probe/G10-base", False, []), KEEP], "ci-probe/G10-base", ("refuse", r"pull request|\bPR\b|open"),
             prs=[pr(21, "feat/g10", "ci-probe/G10-base", "open")])
    # a failed check call exits 1 and deletes nothing
    base = [MAIN, (X, False, []), KEEP]
    why = []
    for mode in ("py", "cli"):
        try:
            setup(base)
            open(os.path.join(STATE, "fail"), "w").close()
            res = RUN[mode](X)
            why += v_failed(mode, res)
            os.remove(os.path.join(STATE, "fail"))
            if present() != sorted(b[0] for b in base):
                why.append("%s: branches changed to %s" % (mode, present()))
            if GH and delete_calls(X):
                why.append("%s: a delete call was made" % mode)
        except Exception as e:  # noqa: BLE001
            why.append("%s: harness error %s: %s" % (mode, type(e).__name__, e))
    line(not why, "%s: [%s] with the fail switch on, `branch delete` is a failed call (exit 1, nothing on stdout, a ForgeError), never `gone`, and deletes nothing" % (AC, NAME), why)
    if GH:
        for ep in ("repo", "branch", "rules", "pulls"):
            scenario(AC, "a check call that fails (the %s endpoint answers 500) exits 1, no result, nothing deleted (not `gone`)" % ep, base, X,
                     ("failed", None), edits={"fail_endpoint": ep})


def cases_shape():
    AC = "G10-AC-5"
    bad = ["", "ci-probe/", "ci-probe/x/", "ci-probe//x", "ci-probe/../main", "ci-probe/./x", "ci-probe/.x", "ci-probe/x.lock", "ci-probe/x?y=1",
           "ci-probe/x#y", "ci-probe/%2e%2e/main", "ci-probe/a b", "ci-probe/x\t", "ci-probe/x\n", "../x", "x?y=1", "ci-probe/x\x01", "ci-probe/x..y/",
           "/ci-probe/x", "ci-probe/x&y=1", "ci-probe/é", "ci-probe/x:y", "ci-probe/x\\y"]
    setup([MAIN, ("ci-probe/G10-x", False, []), KEEP])
    for v in bad:
        why = []
        try:
            before = present()
            res = run_py(v)
            if not res.bad:
                why.append("py: expected forge.BadValue, got %s" % res.brief())
            elif "branch" not in (res.msg or "").lower():
                why.append("py: the message does not name --branch: %r" % res.msg)
            res = run_cli(v)
            if res.rc != 2 or res.out:
                why.append("cli: expected exit 2 and nothing on stdout, got %s" % res.brief())
            elif not one_line(res.err) or "--branch" not in res.err:
                why.append("cli: expected one stderr line naming --branch, got %r" % res.err)
            if calls():
                why.append("a call was made to the backend (%d)" % len(calls()))
            if present() != before:
                why.append("branches changed to %s" % present())
        except Exception as e:  # noqa: BLE001
            why.append("harness error %s: %s" % (type(e).__name__, e))
        line(not why, "%s: [%s] `branch delete --branch %r` is a usage error (BadValue / exit 2 naming --branch, nothing on stdout), no call" % (AC, NAME, v), why)
    # a name of the right shape that only looks odd is accepted
    for v in ("ci-probe/G10.x_y-1", "ci-probe/a/b/c", "ci-probe/x.lock.y"):
        setup([MAIN, (v, False, []), KEEP])
        res = run_py(v)
        line(res.ok == {"branch": v, "result": "deleted"} and v not in present(), "%s: [%s] the well-formed name %r is accepted and deleted" % (AC, NAME, v), [res.brief()])
    if GH:
        # the open-PR lookup: a GET with its head and base filters as -f fields, no query string in its path
        why = []
        for mode in ("py", "cli"):
            try:
                setup([MAIN, (X, False, []), KEEP], prs=[pr(21, "feat/other", "main", "open")])
                res = RUN[mode](X)
                if res.ok != {"branch": X, "result": "deleted"}:
                    why.append("%s: expected deleted, got %s" % (mode, res.brief()))
                pulls = [c for c in gh_calls() if c.get("path") == "repos/acme/widgets/pulls"]
                if not pulls:
                    why.append("%s: no lookup of the pulls; saw %s" % (mode, [(c.get("method"), c.get("path")) for c in gh_calls()][:8]))
                for c in pulls:
                    if c.get("method") != "GET":
                        why.append("%s: the lookup is a %s, not a GET" % (mode, c.get("method")))
                    if any("?" in a for a in c.get("argv", [])):
                        why.append("%s: a query string in the lookup's argv: %s" % (mode, c.get("argv")))
                    if c.get("body") is not None:
                        why.append("%s: the GET lookup has a body" % mode)
                if not any(c.get("fields", {}).get("head") == OWNER + ":" + X for c in pulls):
                    why.append("%s: no lookup with -f head=%s:%s; fields seen %s" % (mode, OWNER, X, [c.get("fields") for c in pulls]))
                if not any(c.get("fields", {}).get("base") == X for c in pulls):
                    why.append("%s: no lookup with -f base=%s; fields seen %s" % (mode, X, [c.get("fields") for c in pulls]))
            except Exception as e:  # noqa: BLE001
                why.append("%s: harness error %s: %s" % (mode, type(e).__name__, e))
        line(not why, "%s: [github] the open-PR lookup is a GET with its head (owner:branch) and base filters as -f fields and no query string in its path" % AC, why)


def cases_refused_deletion():
    AC = "G10-AC-2"
    base = [MAIN, (X, False, []), KEEP]
    if GH:
        scenario(AC, "a delete the forge answers with 403 exits 3 naming `forge github lacks branch_delete`, no result on stdout, the branch stays", base, X,
                 ("cap",), edits={"delete_answer": 403}, attempt=True, expect_calls=[("DELETE", "git/refs/heads/<name>")])
        scenario(AC, "a delete answered with 422 while the branch is still served exits 1 with the forge's message, no result (not `gone`)", base, X,
                 ("failed", "G10-rule-block"), edits={"delete_answer": 422}, attempt=True)
        scenario(AC, "a delete answered with 422 and then 404 for the branch is `gone` (exit 0)", base, X, ("gone",), edits={"delete_answer": "422-gone"}, attempt=True, removed=True)
        # the branch is read again after the 422
        why = []
        for mode in ("py", "cli"):
            try:
                setup(base, edits={"delete_answer": 422})
                RUN[mode](X)
                seq = [(c.get("method"), c.get("path")) for c in gh_calls()]
                d = [i for i, c in enumerate(seq) if c[0] == "DELETE"]
                if not d or ("GET", "repos/acme/widgets/branches/" + X) not in seq[d[0] + 1:]:
                    why.append("%s: the branch was not read again after the delete: %s" % (mode, seq))
            except Exception as e:  # noqa: BLE001
                why.append("%s: harness error %s: %s" % (mode, type(e).__name__, e))
        line(not why, "%s: [github] after a 422 on the delete the backend reads the branch again" % AC, why)
        scenario(AC, "a delete answered with 404 (the branch went meanwhile) is `gone`", base, X, ("gone",), edits={"delete_answer": 404}, attempt=True)
        r = subprocess.run([sys.executable, "-I", os.path.join(SCHED, "forge.py"), "--repo", SPEC, "caps"], capture_output=True, text=True, stdin=subprocess.DEVNULL)
        line(r.returncode == 0 and "branch_delete" in r.stdout, "G10-AC-2: [github] `forge.py caps` lists branch_delete", [r.stdout[:100], r.stderr[:100]])
    else:
        scenario(AC, "a deletion the fake forge's world refuses exits 3 naming `forge fake lacks branch_delete`, no result on stdout, the branch stays", base, X,
                 ("cap",), edits={"refuse_branch_delete": [X]})
        scenario(AC, "a deletion the fake forge's world refuses for all branches exits 3 the same way", base, X, ("cap",), edits={"refuse_branch_delete": True})
        scenario(AC, "a fake forge with no capability list (the fixture's four) lacks branch_delete: exit 3 / CapabilityOff, no result, no call, nothing deleted", base, X,
                 ("cap",), caps=None, nocall=True)
        scenario(AC, "a fake forge configured with the four capabilities and no branch_delete exits 3 the same way before any call", base, X, ("cap",), caps=FOUR, nocall=True)
        scenario(AC, "a fake forge configured with branch_delete deletes (the capability is what lets it)", base, X, ("deleted",), caps=CAPS)


def main():
    os.makedirs(WORK, exist_ok=True)
    seed = os.path.join(WORK, "seed")
    git("init", "-q", "-b", "seed", seed)
    git("-C", seed, "-c", "user.name=t", "-c", "user.email=t@example.test", "commit", "-q", "--allow-empty", "-m", "seed")
    shutil.rmtree(BARE_T, ignore_errors=True)
    git("clone", "-q", "--bare", seed, BARE_T)
    for fn in (cases_shape, cases_delete, cases_refuse, cases_refused_deletion):
        try:
            fn()
        except BaseException as e:  # noqa: BLE001
            line(False, "G10-AC-1: the G10 cases %s ran to their end [%s]" % (fn.__name__, NAME), ["%s: %s" % (type(e).__name__, e)])
    print("DONE")


def cases_round2():
    """G10-AC-5: a missing, None or non-str `branch` is a BadValue (naming branch) and no call; G10-AC-1: a check answer of the
    wrong JSON type is a failed call (ForgeError), never `not protected`, and no delete."""
    AC = "G10-AC-5"
    setup([MAIN, (X, False, []), KEEP])
    before = present()
    variants = (("branch=None", lambda f: f.branch_delete(branch=None)), ("positional None", lambda f: f.branch_delete(None)),
                ("no branch argument", lambda f: f.branch_delete()), ("branch=123", lambda f: f.branch_delete(branch=123)),
                ("branch=['ci-probe/x']", lambda f: f.branch_delete(branch=["ci-probe/x"])))
    for label, fn in variants:
        why = []
        try:
            setup([MAIN, (X, False, []), KEEP])
            try:
                f = forge.open(SPEC)
                res = Res(ok=fn(f))
            except BaseException as e:  # noqa: BLE001
                res = Res(exc=type(e).__name__, msg=str(e), bad=BV is not None and isinstance(e, BV), forgeerr=isinstance(e, forge.ForgeError))
            if not res.bad:
                why.append("py: expected forge.BadValue, got %s" % res.brief())
            elif not res.forgeerr or "branch" not in (res.msg or "").lower():
                why.append("py: BadValue must be a ForgeError naming branch: %r" % res.msg)
            if calls():
                why.append("a call was made to the backend (%d)" % len(calls()))
            if present() != before:
                why.append("branches changed to %s" % present())
        except Exception as e:  # noqa: BLE001
            why.append("harness error %s: %s" % (type(e).__name__, e))
        line(not why, "%s: [%s] the Python interface with %s raises BadValue naming branch (not a raw exception), no call" % (AC, NAME, label), why)
    if GH:
        AC = "G10-AC-1"
        base = [MAIN, (X, False, []), KEEP]
        for ep, ans, what in (("branch", [], "a list"), ("branch", "protected", "a string"), ("branch", None, "null"),
                              ("rules", {"type": "deletion"}, "an object"), ("rules", "deletion", "a string")):
            if ans is None:
                continue  # null is the fake's 404 form; not served here
            scenario(AC, "a check call answered with %s for the %s endpoint is a failed call (exit 1, no result), nothing deleted" % (what, ep), base, X,
                     ("failed", None), edits={"malformed": {ep: ans}})


def cases_round3():
    """G10-AC-5: the --branch shape is a subset of what `git check-ref-format --branch` accepts; a `..` inside a segment and a
    trailing dot are refused by git, so they are usage errors here (BadValue / exit 2 naming --branch), with no call."""
    AC = "G10-AC-5"
    setup([MAIN, ("ci-probe/G10-x", False, []), KEEP])
    for v in ("ci-probe/x..y", "ci-probe/x.", "ci-probe/a/x.", "ci-probe/x../y"):
        why = []
        try:
            chk = subprocess.run(["git", "check-ref-format", "--branch", v], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if chk.returncode == 0:
                why.append("premise: git check-ref-format --branch accepts %r" % v)
            before = present()
            res = run_py(v)
            if not res.bad:
                why.append("py: expected forge.BadValue, got %s" % res.brief())
            elif "branch" not in (res.msg or "").lower():
                why.append("py: the message does not name --branch: %r" % res.msg)
            res = run_cli(v)
            if res.rc != 2 or res.out:
                why.append("cli: expected exit 2 and nothing on stdout, got %s" % res.brief())
            elif not one_line(res.err) or "--branch" not in res.err:
                why.append("cli: expected one stderr line naming --branch, got %r" % res.err)
            if calls():
                why.append("a call was made to the backend (%d)" % len(calls()))
            if present() != before:
                why.append("branches changed to %s" % present())
        except Exception as e:  # noqa: BLE001
            why.append("harness error %s: %s" % (type(e).__name__, e))
        line(not why, "%s: [%s] `branch delete --branch %r` (refused by git check-ref-format --branch) is a usage error (BadValue / exit 2 naming --branch, nothing on stdout), no call" % (AC, NAME, v), why)


main()
try:
    cases_round2()
except BaseException as e:  # noqa: BLE001
    line(False, "G10-AC-5: the G10 round-2 cases ran to their end [%s]" % NAME, ["%s: %s" % (type(e).__name__, e)])
try:
    cases_round3()
except BaseException as e:  # noqa: BLE001
    line(False, "G10-AC-5: the G10 round-3 cases ran to their end [%s]" % NAME, ["%s: %s" % (type(e).__name__, e)])
print("DONE2")
sys.exit(0)
