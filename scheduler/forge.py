#!/usr/bin/env python3
"""The forge interface (G04): what the scheduler needs from the place its repository lives, behind one module.

Python:  import forge; f = forge.open("owner/name")  (or "github:owner/name", "fake:<state folder>"; no argument reads
         $NOODLEBOT_FORGE_REPO); f.<family>_<op>(**kwargs), e.g. f.issue_list(label="noodlebot", state="open").
CLI:     python3 -I forge.py [--repo SPEC] <family> <op> [--opt value ...]   prints the result as one JSON document.
         forge.py remote-commit-link URL SHA   a commit's web link from an origin remote's URL (exit 1: none).
         forge.py ops   the operations as JSON;   forge.py [--repo SPEC] caps   the forge's capabilities as JSON.
Exit codes: 0 done; 1 a call failed (one line on stderr, nothing on stdout, never an empty result); 2 usage error,
unknown forge or a value the operation rejects (forge.BadValue, checked before any call); 3 the forge lacks a capability the operation needs (stderr: `forge <name> lacks <capability>`).

Backends are classes `Backend(path)` with methods named <family>_<op> (`-` -> `_`): `github` is scheduler/forges/github.py,
`fake` is scheduler/testdata/forge/fake.py. The capability rule lives here: an operation whose capability the backend lacks
raises CapabilityOff before the backend is called. The operations and result shapes are documented in forges/README.md.
"""
import _thread
import builtins
import json
import os
import re
import sys
import types

sys.dont_write_bytecode = True  # a deployed checkout gets no __pycache__ from the backends loaded here
HERE = os.path.dirname(os.path.abspath(__file__))

# (family op, capability it needs or None, arguments: name -> "str"|"int"|"list"|"bool"|"text"|"path", a trailing "!" = required;
#  "path" is a local file or folder, a "str" to the CLI)
_OPS = [
    ("repo visibility", "visibility", {}),
    ("repo default-branch", None, {}),
    ("repo clone-url", None, {}),
    ("repo url", None, {"kind": "str!", "ref": "str"}),
    ("repo identities", None, {}),
    ("repo permissions", None, {}),
    ("pr list", None, {"state": "str", "limit": "int", "fields": "list"}),
    ("pr view", None, {"number": "int!"}),
    ("pr create", None, {"head": "str!", "base": "str!", "title": "str!", "body": "text!"}),
    ("pr edit", None, {"number": "int!", "title": "str", "body": "text"}),
    ("pr close", None, {"number": "int!"}),
    ("pr comment", None, {"number": "int!", "body": "text!"}),
    ("pr comments", None, {"number": "int!"}),
    ("pr reviews", None, {"number": "int!"}),
    ("pr line-comments", None, {"number": "int!"}),
    ("pr reply", None, {"number": "int!", "to": "int!", "body": "text!"}),
    ("pr resolve-thread", "resolve_threads", {"thread": "str!"}),
    ("issue list", None, {"label": "str", "state": "str", "oldest_first": "bool"}),
    ("issue view", None, {"number": "int!"}),
    ("issue comments", None, {"number": "int!", "since": "str"}),
    ("issue create", None, {"title": "str!", "body": "text!", "labels": "list"}),
    ("issue edit", None, {"number": "int!", "title": "str", "body": "text"}),
    ("issue comment", None, {"number": "int!", "body": "text!"}),
    ("issue close", None, {"number": "int!"}),
    ("issue reopen", None, {"number": "int!"}),
    ("issue pin", "pin", {"number": "int!"}),
    ("issue unpin", "pin", {"number": "int!"}),
    ("issue events", None, {"number": "int!"}),
    ("issue react", None, {"comment": "int!", "reaction": "str"}),
    ("label list", None, {}),
    ("label ensure", None, {"name": "str!", "color": "str!", "description": "str!"}),
    ("label add", None, {"number": "int!", "name": "str!"}),
    ("label remove", None, {"number": "int!", "name": "str!"}),
    ("commit checks", None, {"sha": "str!"}),
    ("ci runs", None, {"workflow": "str", "sha": "str", "branch": "str", "event": "str"}),
    ("ci rerun", None, {"run": "int!"}),
    ("ci logs", "ci_logs", {"run": "int!", "job": "str"}),
    ("site publish", "site", {"target": "str!", "input": "path!"}),
    ("branch push", None, {"path": "path!", "branch": "str!"}),
    ("branch delete", "branch_delete", {"branch": "str!"}),
]
OPERATIONS = [o[0] for o in _OPS]
_CAP = {o[0]: o[1] for o in _OPS}
_ARGS = {o[0]: o[2] for o in _OPS}
_METHODS = {o.replace(" ", "_").replace("-", "_"): o for o in OPERATIONS}
CAPABILITIES = ("visibility", "pin", "resolve_threads", "site", "ci_logs", "branch_delete")
BACKENDS = {"github": os.path.join(HERE, "forges", "github.py"),
            "fake": os.path.join(HERE, "testdata", "forge", "fake.py")}


class ForgeError(Exception):
    """A backend call failed. .status is the HTTP status when the forge answered with one."""

    def __init__(self, message="", status=None):
        Exception.__init__(self, message)
        self.status = status


class BadValue(ForgeError):
    """A value an operation takes into a request path, a query, a web URL or a git argument is not in its accepted form
    (the message names the option); raised before the backend is called, the CLI's exit 2."""


class CapabilityOff(ForgeError):
    def __init__(self, forge, capability):
        ForgeError.__init__(self, "forge %s lacks %s" % (forge, capability))
        self.capability = capability


class UnknownForge(ValueError):
    pass


def parse(spec):
    """'owner/name' | 'github:owner/name' | 'fake:<path>' -> (forge name, path); anything else is UnknownForge."""
    if not spec:
        raise UnknownForge("no forge given (--repo SPEC or $NOODLEBOT_FORGE_REPO)")
    name, sep, path = spec.partition(":")
    if not sep:
        name, path = "github", spec
    if name not in BACKENDS:
        raise UnknownForge("unknown forge %r in %r" % (name, spec))
    if not path or (name == "github" and not re.fullmatch(r"[\w.-]+/[\w.-]+", path)):
        raise UnknownForge("bad repository %r for forge %s (want owner/name)" % (path, name))
    return name, path


_LOADED = {}  # the backend modules, loaded once per process (the GitHub backend keeps its token cache in its module)
_LOAD_LOCK = _thread.allocate_lock()  # threads opening a forge at once share one module (one token cache, one token lock)


def _load(name):
    with _LOAD_LOCK:
        if name not in _LOADED:
            _LOADED[name] = _load_file(name)
        return _LOADED[name]


def _load_file(name):
    """A backend's module from its source file, compiled here (no bytecode is written; importlib's loader is not needed)."""
    path = BACKENDS[name]
    mod = types.ModuleType("forge_backend_" + name)
    mod.__file__ = path
    _exec_file(path, mod.__dict__)
    return mod


def _exec_file(path, namespace):
    with builtins.open(path, encoding="utf-8") as f:
        code = compile(f.read(), path, "exec")
    exec(code, namespace)


def _num(v):
    return (isinstance(v, int) and not isinstance(v, bool) and v >= 0) or (isinstance(v, str) and re.fullmatch(r"[0-9]+", v) is not None)


def _sha(v):
    return isinstance(v, str) and re.fullmatch(r"[0-9a-fA-F]{4,64}", v) is not None


def _branch(v):
    """git check-ref-format --branch for the characters [A-Za-z0-9._/-], with no leading '-' (no git is run)."""
    if not isinstance(v, str) or not re.fullmatch(r"[A-Za-z0-9._/-]+", v) or v.startswith("-") or v in ("@", "HEAD"):
        return False
    return all(c and not c.startswith(".") and not c.endswith(".lock") and ".." not in c for c in v.split("/")) and not v.endswith(".")


THROWAWAY_PREFIXES = ("ci-probe/",)  # `branch delete` deletes only branches under these


def _ref_name(v):
    """The shape of a branch name `branch delete` takes: `/`-separated segments of [A-Za-z0-9._-], none empty, starting with
    a dot or ending in .lock."""
    return isinstance(v, str) and all(re.fullmatch(r"[A-Za-z0-9._-]+", c) and not c.startswith(".") and not c.endswith(".lock")
                                      for c in v.split("/"))


def _str_ok(pattern):
    return lambda v: isinstance(v, str) and re.fullmatch(pattern, v) is not None


_CHECKS = {
    ("ci runs", "workflow"): lambda v: isinstance(v, str) and (re.fullmatch(r"[A-Za-z0-9._-]+\.ya?ml|[0-9]+", v) is not None),
    ("commit checks", "sha"): _sha,
    ("issue comments", "since"): _str_ok(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z"),
    ("site publish", "target"): _str_ok(r"[A-Za-z0-9]+"),
    ("label remove", "name"): lambda v: isinstance(v, str) and v not in ("", ".", ".."),
    ("branch push", "branch"): _branch,
    ("branch delete", "branch"): _ref_name,
}


def _bad(option, value):
    return BadValue("bad value for --%s: %.60r" % (option.replace("_", "-"), value))


def check_ref(kind, ref):
    """repo url --ref: a number for issue, pr and run, 4 to 64 hex digits for commit (other kinds: the backend decides)."""
    if (kind in ("issue", "pr", "run") and not _num(ref)) or (kind == "commit" and not _sha(ref)):
        raise _bad("ref", ref)


def _check(op, args, kwargs):
    kw = dict(zip(_ARGS[op], args))
    kw.update(kwargs)
    for name, value in kw.items():
        if value is not None and (op, name) in _CHECKS and not _CHECKS[(op, name)](value):
            raise _bad(name, value)
    if op == "repo url" and kw.get("kind") is not None and kw.get("ref") is not None:
        check_ref(kw["kind"], kw["ref"])


class Forge:
    """A backend with the capability rule in front of it."""

    def __init__(self, name, path, backend):
        self.name, self.path, self._backend = name, path, backend
        self.capabilities = frozenset(backend.capabilities)

    def has(self, capability):
        return capability in self.capabilities

    def __getattr__(self, attr):
        op = _METHODS.get(attr)
        if op is None or attr.startswith("_"):
            raise AttributeError(attr)
        fn, cap = getattr(self._backend, attr), _CAP[op]

        def call(*args, **kwargs):
            if cap and cap not in self.capabilities:
                raise CapabilityOff(self.name, cap)
            _check(op, args, kwargs)
            if op == "branch delete":
                name = dict(zip(_ARGS[op], args), **kwargs).get("branch")
                if not isinstance(name, str) or not _ref_name(name):
                    raise _bad("branch", name)
                if not name.startswith(THROWAWAY_PREFIXES):
                    raise ForgeError("branch %s is outside the throwaway prefix (%s), not deleted" % (name, ", ".join(THROWAWAY_PREFIXES)))
            try:
                return fn(*args, **kwargs)
            except ForgeError:
                raise
            except Exception as e:  # noqa: BLE001 (bad data from a backend is a failed call, never a raw traceback)
                raise ForgeError("%s %s failed: %s" % (self.name, attr.replace("_", " ", 1), type(e).__name__))
        call.__name__ = attr
        return call


def open(spec=None):  # noqa: A001 (the interface's name)
    name, path = parse(spec if spec is not None else os.environ.get("NOODLEBOT_FORGE_REPO"))
    return Forge(name, path, _load(name).Backend(path))


def web_url(spec, kind, ref=None):
    """The web URL of the repository or of one issue, PR, commit or run; no call for GitHub."""
    name, path = parse(spec)
    if kind != "repo" and ref is not None:
        check_ref(kind, ref)
    if name == "github":
        return _load("github").web_url(path, kind, ref)
    return open(spec).repo_url(kind=kind, ref=ref)


def repo_of_remote(url):
    """The repository spec of an origin remote URL, for a caller that has no NOODLEBOT_FORGE_REPO (nodes.py): a GitHub
    remote gives owner/name; any other remote (a local path) gives its last two path components, which no forge call
    will find (the call fails and the caller says so), None when it has fewer."""
    repo = _load("github").repo_of_remote(url)
    if repo:
        return repo
    parts = [x for x in re.sub(r"\.git/?$", "", (url or "").strip()).replace(":", "/").split("/") if x]
    return "/".join(parts[-2:]) if len(parts) >= 2 and re.fullmatch(r"[\w.-]+", parts[-1]) and re.fullmatch(r"[\w.-]+", parts[-2]) else None


def commit_link(url, sha):
    """The web link of a commit from the origin remote's URL, or None when no backend knows the URL (no forge call)."""
    if sha:
        check_ref("commit", sha)
    return _load("github").commit_link(url, sha)


# ---- CLI -------------------------------------------------------------------------------------------------------
def main(argv, out=None, err=None):
    """The CLI; out/err (default stdout/stderr) take what it prints, so a process can run it in a thread (loop.sh's pr_tsvs).
    Its code is forges/cli.py, compiled into this module's namespace on the first call (once, also under threads)."""
    if "_cli_main" not in globals():
        with _LOAD_LOCK:
            if "_cli_main" not in globals():
                _exec_file(os.path.join(HERE, "forges", "cli.py"), globals())
    return _cli_main(argv, out, err)  # noqa: F821 (defined by forges/cli.py)


if __name__ == "__main__":
    sys.modules.setdefault("forge", sys.modules["__main__"])
    sys.exit(main(sys.argv[1:]))
