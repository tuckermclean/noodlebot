"""Serves python to the clients that `report-fakegh.sh` installs, so the interpreter's start-up is paid once.

report-fakegh-server.py <dir> <pid of the test> [pyc]. Without `pyc` it serves one fake `gh` (the python script
<dir>/gh.py): the script is run again for every call, from its source as it is on disk, with the call's arguments and
standard input, and gives the answers it gives as a script of its own. With `pyc` it serves `python3 -I -c <code>
<args>` for the checks' queries: <code> is the first argument. A client that names a variable of its environment in the
code (os.environ) has its environment in <dir>/env.<id>. It ends when <dir> is removed or the test's process is gone."""
import io, os, select, shlex, sys, traceback

d, owner = sys.argv[1], int(sys.argv[2])
pyc = sys.argv[3:] == ["pyc"]
src = os.path.join(d, "gh.py")
fd = os.open(os.path.join(d, "req"), os.O_RDWR)
cached = {}


def lines(text):
    """The lines of text, split at newlines only (not at the other separators str.splitlines knows)."""
    parts = text.split("\n")
    return parts[:-1] if parts[-1] == "" else parts


def serve(i):
    base = os.path.join(d, "%s")
    argv = ["gh"]
    with open(base % ("args." + i), "rb") as f:
        raw = f.read()
    os.unlink(base % ("args." + i))
    if raw:
        argv += [os.fsdecode(a) for a in raw.split(b"\0")[:-1]]
    stdin = ""
    if os.path.exists(base % ("in." + i)):
        with open(base % ("in." + i), "rb") as f:
            stdin = f.read().decode("utf-8", "surrogateescape")
        os.unlink(base % ("in." + i))
    env = None
    if os.path.exists(base % ("env." + i)):
        with open(base % ("env." + i), "rb") as f:
            words = shlex.split(f.read().decode("utf-8", "surrogateescape"))
        os.unlink(base % ("env." + i))
        env = dict(w.split("=", 1) for w in words if "=" in w and not w.startswith("="))
    saved_env = None
    if env is not None:
        saved_env = dict(os.environ)
        os.environ.clear()
        os.environ.update(env)
    out, err, rc = io.StringIO(), io.StringIO(), 0
    saved = sys.argv, sys.stdin, sys.stdout, sys.stderr
    if pyc:
        text, argv = argv[1], ["-c"] + argv[2:]
    sys.argv, sys.stdin, sys.stdout, sys.stderr = argv, io.StringIO(stdin), out, err
    try:
        if not pyc:
            with open(src, encoding="utf-8") as f:
                text = f.read()
        if text not in cached:
            cached[text] = compile(text, "<string>" if pyc else src, "exec")
        exec(cached[text], {"__name__": "__main__"} if pyc else {"__name__": "__main__", "__file__": src})
    except SystemExit as e:
        rc = e.code if isinstance(e.code, int) else (0 if e.code is None else 1)
        if isinstance(e.code, str):
            print(e.code, file=err)
    except BaseException:
        traceback.print_exc(file=err)
        rc = 1
    finally:
        sys.argv, sys.stdin, sys.stdout, sys.stderr = saved
        if saved_env is not None:
            os.environ.clear()
            os.environ.update(saved_env)
    msg = "".join("o" + l + "\n" for l in lines(out.getvalue())) + "".join("e" + l + "\n" for l in lines(err.getvalue())) + "r%d\n" % rc
    try:
        w = os.open(base % ("resp." + i), os.O_WRONLY | os.O_NONBLOCK)
        os.set_blocking(w, True)
        os.write(w, msg.encode("utf-8", "surrogateescape"))
        os.close(w)
    except OSError:
        pass


buf = b""
while True:
    if not select.select([fd], [], [], 0.5)[0]:
        try:
            os.kill(owner, 0)
        except OSError:
            break
        if not os.path.isdir(d):
            break
        continue
    buf += os.read(fd, 4096)
    while b"\n" in buf:
        line, buf = buf.split(b"\n", 1)
        serve(line.decode())
