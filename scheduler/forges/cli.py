"""The CLI of scheduler/forge.py (G04): `python3 -I forge.py ...` (see forge.py's docstring) and forge.main.

Not a module of its own: forge.py compiles this file into its own namespace the first time its main runs (a process
that only uses the Python interface never compiles it). Everything forge.py defines is in scope here (`open` is
forge.open; a file is opened with builtins.open).
"""


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
    if not _ARGS[op] and not argv:
        return {}   # no options to parse: argparse is not loaded
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


def _fail(code, message, err=None):
    (sys.stderr if err is None else err).write("forge.py: %s\n" % " ".join(str(message).split())[:500])
    return code


def _cli_main(argv, out=None, err=None):
    """The CLI; out/err (default stdout/stderr) take what it prints, so a process can run it in a thread (loop.sh's pr_tsvs)."""
    out, err = sys.stdout if out is None else out, sys.stderr if err is None else err
    repo = None
    if argv[:1] == ["--repo"]:
        if len(argv) < 2:
            return _fail(2, "--repo needs a value", err)
        repo, argv = argv[1], argv[2:]
    if len(argv) == 3 and argv[0] == "remote-commit-link":  # remote-commit-link URL SHA: version.sh's signature link
        link = commit_link(argv[1], argv[2])
        if link is None:
            return _fail(1, "no commit link for %s" % argv[1], err)
        print(json.dumps(link), file=out)
        return 0
    if argv == ["ops"]:
        print(json.dumps(OPERATIONS), file=out)
        return 0
    try:
        if argv == ["caps"]:
            print(json.dumps(sorted(open(repo).capabilities)), file=out)
            return 0
        if argv == ["runtime"]:
            # loop.sh, once per start: <runtime name> TAB <owner> TAB <canonical spec> TAB <capabilities> TAB <clone URL>,
            # the last two as `caps` and `repo clone-url` give them (space-separated; the URL as its JSON string without the
            # quotes), each empty when it cannot be had (the loop then assumes all capabilities, and a clone fails)
            fname, path = parse(repo if repo is not None else os.environ.get("NOODLEBOT_FORGE_REPO"))
            canon = repo if repo is not None else os.environ.get("NOODLEBOT_FORGE_REPO")
            if fname == "github":
                owner, _, rname = path.partition("/")
                canon = path
            else:
                rname, owner = os.path.basename(path.rstrip("/")), ""
                try:
                    with builtins.open(os.path.join(path, "forge.json"), encoding="utf-8") as f:
                        owner = str(json.load(f).get("owner") or "")
                except (OSError, ValueError, AttributeError):
                    pass
            caps = url = ""
            try:
                f = open(canon)
                caps = " ".join(sorted(f.capabilities))
                url = json.dumps(f.repo_clone_url())[1:-1]
            except Exception:  # noqa: BLE001 (what cannot be had is empty)
                pass
            print("%s\t%s\t%s\t%s\t%s" % (rname, owner, canon, caps, url), file=out)
            return 0
        if len(argv) < 2 or "%s %s" % (argv[0], argv[1]) not in _ARGS:
            raise _Usage("usage: forge.py [--repo SPEC] <family> <op> [--opt value ...] | ops | caps")
        op = "%s %s" % (argv[0], argv[1])
        kw = _kwargs(op, argv[2:])
        result = getattr(open(repo), op.replace(" ", "_").replace("-", "_"))(**kw)
        text = json.dumps(result)
    except _Usage as e:
        return _fail(2, e, err)
    except UnknownForge as e:
        return _fail(2, e, err)
    except CapabilityOff as e:
        err.write("%s\n" % e)
        return 3
    except ForgeError as e:
        return _fail(1, e or "the call failed", err)
    except Exception as e:  # noqa: BLE001 (a backend bug is a failed call, never an empty result)
        return _fail(1, "%s: %s" % (type(e).__name__, e), err)
    print(text, file=out)
    return 0
