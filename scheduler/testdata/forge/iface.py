#!/usr/bin/env python3
"""The interface-level checks of scheduler/forge.test.sh (G04-AC-1, G04-AC-2, G04-AC-6's argument forms at the
interface): iface.py <state folder of a fake forge>. Prints PASS:/FAIL: lines; every check runs, whatever fails before."""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCHED = os.path.dirname(os.path.dirname(HERE))
state = sys.argv[1]
EXPECTED = ["repo visibility", "repo default-branch", "repo clone-url", "repo url", "repo identities", "pr list", "pr view",
            "pr create", "pr edit", "pr comment", "pr comments", "pr reviews", "pr line-comments", "pr reply",
            "pr resolve-thread", "issue list", "issue view", "issue comments", "issue create", "issue edit",
            "issue comment", "issue close", "issue reopen", "issue pin", "issue unpin", "issue events", "issue react",
            "label list", "label ensure", "label add", "label remove", "commit checks", "ci runs", "site publish",
            "branch push"]


def line(ok, name, *details):
    print("%s: %s" % ("PASS" if ok else "FAIL", name))
    if not ok:
        for d in details:
            print("  " + d)


HAVE = os.path.exists(os.path.join(SCHED, "forge.py"))


def cli(*args, env=None):
    e = dict(os.environ)
    e.update(env or {})
    r = subprocess.run([sys.executable, "-I", os.path.join(SCHED, "forge.py")] + list(args), capture_output=True, text=True,
                       stdin=subprocess.DEVNULL, env=e, timeout=60)
    return r


def attempt(fn):
    try:
        return fn(), None
    except BaseException as e:  # noqa: any failure is a FAIL line, not a crash of the harness
        return None, "%s: %s" % (type(e).__name__, str(e)[:200])


sys.path.insert(0, SCHED)
try:
    import forge
    err = None
except Exception as e:
    forge, err = None, "%s: %s" % (type(e).__name__, e)

line(forge is not None, "G04-AC-2: scheduler/forge.py can be imported (import forge)", err or "")
ops, e = attempt(lambda: list(forge.OPERATIONS))
line(ops is not None and all(isinstance(o, str) for o in ops), "G04-AC-1: forge.OPERATIONS is a list of 'family op' strings", e or "")
ops = ops or []
line(not [o for o in EXPECTED if o not in ops], "G04-AC-2: forge.OPERATIONS has every operation of the interface table",
     "missing: %s" % [o for o in EXPECTED if o not in ops])
r = cli("ops")
try:
    cl = json.loads(r.stdout)
except ValueError:
    cl = None
line(r.returncode == 0 and cl == ops and ops, "G04-AC-1: `forge.py ops` prints forge.OPERATIONS as JSON", "rc %s, stdout %r, stderr %r" % (r.returncode, r.stdout[:100], r.stderr[:100]))

for spec, want in (("acme/widgets", ("github", "acme/widgets")), ("github:acme/widgets", ("github", "acme/widgets")),
                   ("fake:/some/where", ("fake", "/some/where"))):
    got, e = attempt(lambda: tuple(forge.parse(spec)))
    line(got == want, "G04-AC-2: forge.parse(%r) is %r" % (spec, want), e or "got %r" % (got,))
got, e = attempt(lambda: (forge.open("acme/widgets").name, forge.open("acme/widgets").path))
line(got == ("github", "acme/widgets"), "G04-AC-2: forge.open('acme/widgets') is the github backend on acme/widgets", e or "got %r" % (got,))
got, e = attempt(lambda: (forge.open("github:acme/widgets").name, forge.open("github:acme/widgets").path))
line(got == ("github", "acme/widgets"), "G04-AC-2: forge.open('github:acme/widgets') is the same backend", e or "got %r" % (got,))
got, e = attempt(lambda: (forge.open("fake:" + state).name, forge.open("fake:" + state).path))
line(got == ("fake", state), "G04-AC-2: forge.open('fake:<path>') is the fake forge on <path>", e or "got %r" % (got,))
got, e = attempt(lambda: forge.open("fake:" + state).capabilities)
line(got == frozenset(["visibility", "pin", "resolve_threads", "site"]), "G04-AC-2: a fake forge without a capability list has all four capabilities", e or "got %r" % (got,))

try:
    forge.open("gitlab:foo/bar")
    line(False, "G04-AC-2: forge.open of an unknown forge raises UnknownForge", "no exception")
except Exception as ex:
    line(type(ex).__name__ == "UnknownForge" and isinstance(ex, ValueError), "G04-AC-2: forge.open of an unknown forge raises UnknownForge (a ValueError)", "%s: %s" % (type(ex).__name__, ex))
r = cli("--repo", "gitlab:foo/bar", "caps")
line(HAVE and r.returncode == 2 and r.stdout == "" and r.stderr.strip() and "\n" not in r.stderr.strip(), "G04-AC-2: the CLI on an unknown forge exits 2 with one line on stderr and nothing on stdout",
     "rc %s, stdout %r, stderr %r" % (r.returncode, r.stdout[:100], r.stderr[:200]))
r = cli("--repo", "fake:" + state, "bogus", "op")
line(HAVE and r.returncode == 2 and r.stdout == "" and r.stderr.strip(), "G04-AC-2: the CLI on an unknown operation is a usage error: exit 2, nothing on stdout",
     "rc %s, stdout %r, stderr %r" % (r.returncode, r.stdout[:100], r.stderr[:200]))
r = cli("--repo", "fake:" + state, "repo", "default-branch", "--no-such-option", "1")
line(HAVE and r.returncode == 2 and r.stdout == "", "G04-AC-2: the CLI on an unknown option is a usage error: exit 2, nothing on stdout",
     "rc %s, stdout %r, stderr %r" % (r.returncode, r.stdout[:100], r.stderr[:200]))
r = cli("repo", "default-branch", env={"NOODLEBOT_FORGE_REPO": "fake:" + state})
line(r.returncode == 0 and r.stdout.strip() == '"main"', "G04-AC-2: without --repo the CLI takes the forge from NOODLEBOT_FORGE_REPO",
     "rc %s, stdout %r, stderr %r" % (r.returncode, r.stdout[:100], r.stderr[:200]))
got, e = attempt(lambda: (os.environ.__setitem__("NOODLEBOT_FORGE_REPO", "fake:" + state), forge.open().name)[1])
os.environ.pop("NOODLEBOT_FORGE_REPO", None)
line(got == "fake", "G04-AC-2: forge.open() with no spec takes $NOODLEBOT_FORGE_REPO", e or "got %r" % (got,))

line(forge is not None and issubclass(forge.CapabilityOff, forge.ForgeError) if forge else False,
     "G04-AC-3: CapabilityOff is a ForgeError")
for kind, ref, tail in (("repo", None, ""), ("issue", "1", "/issues/1"), ("pr", "5", "/pull/5"), ("commit", "abc123", "/commit/abc123")):
    got, e = attempt(lambda: forge.web_url("acme/widgets", kind, ref) if ref else forge.web_url("acme/widgets", kind))
    line(got == "https://github.com/acme/widgets" + tail, "G04-AC-2: forge.web_url('acme/widgets', %r) is the GitHub web URL, with no call" % kind, e or "got %r" % (got,))
