#!/usr/bin/env python3
"""The forge interface (G04): what the scheduler needs from the place its repository lives, behind one module.

Python:  import forge; f = forge.open("owner/name")  (or "github:owner/name", "fake:<state folder>"; no argument reads
         $NOODLEBOT_FORGE_REPO); f.<family>_<op>(**kwargs), e.g. f.issue_list(label="noodlebot", state="open").
CLI:     python3 -I forge.py [--repo SPEC] <family> <op> [--opt value ...]   prints the result as one JSON document.
         forge.py remote-commit-link URL SHA   a commit's web link from an origin remote's URL (exit 1: none).
         forge.py ops   the operations as JSON;   forge.py [--repo SPEC] caps   the forge's capabilities as JSON.
Exit codes: 0 done; 1 a call failed (one line on stderr, nothing on stdout, never an empty result); 2 usage error or
unknown forge; 3 the forge lacks a capability the operation needs (stderr: `forge <name> lacks <capability>`).

Backends are classes `Backend(path)` with methods named <family>_<op> (`-` -> `_`): `github` is scheduler/forges/github.py,
`fake` is scheduler/testdata/forge/fake.py. The capability rule lives here: an operation whose capability the backend lacks
raises CapabilityOff before the backend is called. The operations and result shapes are documented in forges/README.md.
"""
import builtins
import importlib.util
import json
import os
import re
import sys
import threading

sys.dont_write_bytecode = True  # a deployed checkout gets no __pycache__ from the backends loaded here
HERE = os.path.dirname(os.path.abspath(__file__))

# (family op, capability it needs or None, arguments: name -> "str"|"int"|"list"|"bool", a trailing "!" = required)
_OPS = [
    ("repo visibility", "visibility", {}),
    ("repo default-branch", None, {}),
    ("repo clone-url", None, {}),
    ("repo url", None, {"kind": "str!", "ref": "str"}),
    ("repo identities", None, {}),
    ("pr list", None, {"state": "str", "limit": "int", "fields": "list"}),
    ("pr view", None, {"number": "int!"}),
    ("pr create", None, {"head": "str!", "base": "str!", "title": "str!", "body": "text!"}),
    ("pr edit", None, {"number": "int!", "title": "str", "body": "text"}),
    ("pr comment", None, {"number": "int!", "body": "text!"}),
    ("pr comments", None, {"number": "int!"}),
    ("pr reviews", None, {"number": "int!"}),
    ("pr line-comments", None, {"number": "int!"}),
    ("pr reply", None, {"number": "int!", "to": "int!", "body": "text!"}),
    ("pr resolve-thread", "resolve_threads", {"thread": "str!"}),
    ("issue list", None, {"label": "str!", "state": "str", "oldest_first": "bool"}),
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
    ("ci runs", None, {"workflow": "str!", "sha": "str!", "branch": "str", "event": "str"}),
    ("site publish", "site", {"target": "str!", "input": "str!"}),
    ("branch push", None, {"path": "str!", "branch": "str!"}),
]
OPERATIONS = [o[0] for o in _OPS]
_CAP = {o[0]: o[1] for o in _OPS}
_ARGS = {o[0]: o[2] for o in _OPS}
_METHODS = {o.replace(" ", "_").replace("-", "_"): o for o in OPERATIONS}
CAPABILITIES = ("visibility", "pin", "resolve_threads", "site")
BACKENDS = {"github": os.path.join(HERE, "forges", "github.py"),
            "fake": os.path.join(HERE, "testdata", "forge", "fake.py")}


class ForgeError(Exception):
    """A backend call failed. .status is the HTTP status when the forge answered with one."""

    def __init__(self, message="", status=None):
        Exception.__init__(self, message)
        self.status = status


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
_LOAD_LOCK = threading.Lock()  # threads opening a forge at once share one module (one token cache, one token lock)


def _load(name):
    with _LOAD_LOCK:
        if name not in _LOADED:
            _LOADED[name] = _load_file(name)
        return _LOADED[name]


def _load_file(name):
    spec = importlib.util.spec_from_file_location("forge_backend_" + name, BACKENDS[name])
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


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
    """The web URL of the repository or of one issue, PR or commit; no call for GitHub."""
    name, path = parse(spec)
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
    return _load("github").commit_link(url, sha)


# ---- CLI -------------------------------------------------------------------------------------------------------
class _Usage(Exception):
    pass


def _op_parser(op):
    import argparse   # only the CLI parses arguments: a library user (every tick's python process) does not pay for it

    class _Parser(argparse.ArgumentParser):
        def error(self, message):
            raise _Usage(message)

    p = _Parser(prog="forge.py " + op, add_help=False, allow_abbrev=False)
    for name, kind in _ARGS[op].items():
        flag = "--" + name.replace("_", "-")
        if kind == "bool":
            p.add_argument(flag, dest=name, action="store_true")
        elif kind == "list":
            p.add_argument(flag, dest=name, action="append")
        else:
            p.add_argument(flag, dest=name, type=int if kind.startswith("int") else str)
        if kind.startswith("text"):
            p.add_argument(flag + "-file", dest=name + "_file")
    return p


def _kwargs(op, argv):
    ns = vars(_op_parser(op).parse_args(argv))
    kw = {}
    for name, kind in _ARGS[op].items():
        v = ns.get(name)
        if kind.startswith("text") and ns.get(name + "_file") is not None:
            if v is not None:
                raise _Usage("--%s and --%s-file together" % (name, name))
            try:
                with builtins.open(ns[name + "_file"], encoding="utf-8") as f:
                    v = f.read()
            except OSError as e:
                raise _Usage("cannot read %s: %s" % (ns[name + "_file"], e.strerror))
        if kind == "list" and v is not None:
            if len(v) == 1 and v[0].lstrip().startswith("["):
                try:
                    v = json.loads(v[0])
                except ValueError:
                    raise _Usage("--%s: not a JSON list" % name.replace("_", "-"))
        if kind == "bool":
            if v:
                kw[name] = True
        elif v is None:
            if kind.endswith("!"):
                raise _Usage("%s: --%s is required" % (op, name.replace("_", "-")))
        else:
            kw[name] = v
    return kw


def _fail(code, message):
    sys.stderr.write("forge.py: %s\n" % " ".join(str(message).split())[:500])
    return code


def main(argv):
    repo = None
    if argv[:1] == ["--repo"]:
        if len(argv) < 2:
            return _fail(2, "--repo needs a value")
        repo, argv = argv[1], argv[2:]
    if len(argv) == 3 and argv[0] == "remote-commit-link":  # remote-commit-link URL SHA: version.sh's signature link
        link = commit_link(argv[1], argv[2])
        if link is None:
            return _fail(1, "no commit link for %s" % argv[1])
        print(json.dumps(link))
        return 0
    if argv == ["ops"]:
        print(json.dumps(OPERATIONS))
        return 0
    try:
        if argv == ["caps"]:
            print(json.dumps(sorted(open(repo).capabilities)))
            return 0
        if argv == ["runtime"]:  # loop.sh: <runtime name> TAB <owner> of the repository
            fname, path = parse(repo if repo is not None else os.environ.get("NOODLEBOT_FORGE_REPO"))
            if fname == "github":
                owner, _, rname = path.partition("/")
            else:
                rname, owner = os.path.basename(path.rstrip("/")), ""
                try:
                    with builtins.open(os.path.join(path, "forge.json"), encoding="utf-8") as f:
                        owner = str(json.load(f).get("owner") or "")
                except (OSError, ValueError, AttributeError):
                    pass
            print("%s\t%s" % (rname, owner))
            return 0
        if len(argv) < 2 or "%s %s" % (argv[0], argv[1]) not in _ARGS:
            raise _Usage("usage: forge.py [--repo SPEC] <family> <op> [--opt value ...] | ops | caps")
        op = "%s %s" % (argv[0], argv[1])
        kw = _kwargs(op, argv[2:])
        result = getattr(open(repo), op.replace(" ", "_").replace("-", "_"))(**kw)
        text = json.dumps(result)
    except _Usage as e:
        return _fail(2, e)
    except UnknownForge as e:
        return _fail(2, e)
    except CapabilityOff as e:
        sys.stderr.write("%s\n" % e)
        return 3
    except ForgeError as e:
        return _fail(1, e or "the call failed")
    except Exception as e:  # noqa: BLE001 (a backend bug is a failed call, never an empty result)
        return _fail(1, "%s: %s" % (type(e).__name__, e))
    print(text)
    return 0


if __name__ == "__main__":
    sys.modules.setdefault("forge", sys.modules["__main__"])
    sys.exit(main(sys.argv[1:]))
