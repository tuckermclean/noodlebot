"""scheduler/harness.py: the one interface through which the scheduler reaches the agent harness (S08).

The backend is chosen by $SCHED_HARNESS (unset or "claude-code": harnesses/claude_code.py; "fake": the fake harness of
testdata/harness/fake.py; any other name: a message on stderr and exit 2). Each operation of a backend is re-exported
here as a function and as a CLI subcommand (name with "_" written "-"); the contract is in the header of fake.py and
the operations are described in harnesses/README.md.

  harness.py start <worktree> <state-dir> <prompt> <system-prompt-file> <plugin>
  harness.py resume <worktree> <state-dir> <session-id> <prompt>
  harness.py exec-start|exec-resume <pidfile> <the arguments of start|resume>   (run-session.sh's pipeline, stage 1)
  harness.py record <state-dir> fresh|append [<pidfile>]                             (run-session.sh's pipeline, stage 2)
  harness.py skill-command <skill> <args> [shipped]
  harness.py matches <unit> <cmdline>
  harness.py preflight
  harness.py events [--no-write] <state-dir>           (--no-write: translate in memory, create no file)
  harness.py capabilities
  harness.py log-stat <state-dir>                      (the raw log: one JSON object with path, size, mtime)
"""
import importlib.util
import inspect
import json
import os
import sys

sys.dont_write_bytecode = True   # the backends loaded below leave no __pycache__ in a deployed checkout

HERE = os.path.dirname(os.path.abspath(__file__))
BACKENDS = {"claude-code": os.path.join(HERE, "harnesses", "claude_code.py"),
            "fake": os.path.join(HERE, "testdata", "harness", "fake.py")}


def backend():
    name = os.environ.get("SCHED_HARNESS") or "claude-code"
    path = BACKENDS.get(name)
    if path is None:
        sys.stderr.write("harness.py: unknown harness %r (SCHED_HARNESS: %s)\n" % (name, ", ".join(sorted(BACKENDS))))
        sys.exit(2)
    spec = importlib.util.spec_from_file_location("harness_backend_" + name.replace("-", "_"), path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def name():
    return backend().NAME


def capabilities():
    return backend().capabilities()


def skill_command(skill, args, shipped=False):
    return backend().skill_command(skill, args, shipped)


def matches(cmdline, unit):
    return backend().matches(cmdline, unit)


def preflight():
    return backend().preflight()


def start(worktree, state_dir, prompt, system_prompt, plugin):
    return backend().start(worktree, state_dir, prompt, system_prompt, plugin)


def resume(worktree, state_dir, session_id, prompt):
    return backend().resume(worktree, state_dir, session_id, prompt)


def events(state_dir, write=True):
    """The normalised events of the session. write=False: for the readers that must not write into the state
    directory (a backend without the argument writes its events file as it always does)."""
    be = backend()
    if not write and "write" in inspect.signature(be.events).parameters:
        return be.events(state_dir, write=False)
    return be.events(state_dir)


def log_stat(state_dir):
    """{"path", "size", "mtime"} of the session's raw log (size and mtime None when it does not exist): for the readers
    that show its size and age. A backend without log_stat has the raw log at <state-dir>/session.jsonl."""
    be = backend()
    if hasattr(be, "log_stat"):
        return be.log_stat(state_dir)
    path = os.path.join(state_dir, "session.jsonl")
    try:
        st = os.stat(path)
        return {"path": path, "size": st.st_size, "mtime": st.st_mtime}
    except OSError:
        return {"path": path, "size": None, "mtime": None}


def _usage():
    sys.stderr.write(__doc__.split("\n\n", 1)[1] if "\n\n" in (__doc__ or "") else "usage: harness.py <operation> ...\n")
    return 2


def main(argv):
    if not argv:
        return _usage()
    op, a = argv[0], argv[1:]
    if op == "start" and len(a) == 5:
        try:
            with open(a[3]) as f:
                system_prompt = f.read().rstrip("\n")
        except OSError:
            system_prompt = ""   # as $(cat missing-file) was: an empty system prompt
        return int(start(a[0], a[1], a[2], system_prompt, a[4]))
    if op in ("exec-start", "exec-resume") and len(a) >= 2:
        # run-session.sh runs the session as `exec-X ... | record ...`, so that the agent CLI is a direct child of the
        # script: a backend with command() gets exec'd (this process becomes the agent), another one runs in-process
        pidfile, a = a[0], a[1:]
        be, real = backend(), op[5:]
        if not hasattr(be, "command"):
            return main([real] + a)
        argv, env, cwd = be.command(real, *a)
        try:
            with open(pidfile, "w") as f:
                f.write("%d\n" % os.getpid())
            os.chdir(cwd)
            fd = os.open(os.devnull, os.O_RDONLY)
            os.dup2(fd, 0)
            os.execvpe(argv[0], argv, env)
        except OSError as e:
            sys.stderr.write("harness.py: cannot run %s: %s\n" % (argv[0], e))
            return 127
    if op == "record" and len(a) in (2, 3):
        be = backend()
        if not hasattr(be, "record"):
            for chunk in iter(lambda: os.read(0, 65536), b""):
                os.write(1, chunk)   # the backend writes its own events
            return 0
        return be.record(a[0], a[1] == "fresh", a[2] if len(a) == 3 else None)
    if op == "resume" and len(a) == 4:
        return int(resume(*a))
    if op == "skill-command" and len(a) in (2, 3):
        print(skill_command(a[0], a[1], len(a) == 3 and a[2] not in ("", "0", "no")))
        return 0
    if op == "matches" and len(a) == 2:
        return 0 if matches(a[1], a[0]) else 1
    if op == "preflight" and not a:
        msg = preflight()
        if msg:
            sys.stderr.write(msg + "\n")
            return 1
        return 0
    if op == "events" and len(a) == 2 and a[0] == "--no-write":
        for e in events(a[1], write=False):
            sys.stdout.write(json.dumps(e) + "\n")   # ASCII-escaped, as events.jsonl: a lone surrogate prints too
        return 0
    if op == "events" and len(a) == 1:
        events(a[0])
        try:
            with open(os.path.join(a[0], "events.jsonl"), "rb") as f:
                sys.stdout.buffer.write(f.read())
        except OSError:
            pass
        sys.stdout.flush()
        return 0
    if op == "log-stat" and len(a) == 1:
        print(json.dumps(log_stat(a[0])))
        return 0
    if op == "capabilities" and not a:
        for c in capabilities():
            print(c)
        return 0
    return _usage()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
