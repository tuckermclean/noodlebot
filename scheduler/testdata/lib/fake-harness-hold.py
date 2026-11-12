"""The fake harness of the S08 loop runs (scheduler/loop-s08*.test.sh): testdata/harness/fake.py, wrapped.

The fixture (loop-s08.sh) copies this file over testdata/harness/fake.py of its scheduler copy and the real fake as
fake_real.py beside it. Per scenario folder $S08_DIR:
  the first start     replays the script as the real fake does (FAKE_HARNESS_SCRIPT), writes the file named by
                      $S08_STDERR to stderr (the CLI's session.stderr), and, with $S08_IDLE set, then stays alive
                      (an idle session; its pid goes to $S08_DIR/pid.<n>) until the loop stops it
  a later start       replays nothing and writes QUESTION.md into the node's state folder, exit 0
  a resume            replays FAKE_HARNESS_RESUME_SCRIPT, writes QUESTION.md, exit 0
Every call is logged by the real fake to $FAKE_HARNESS_LOG ("start <dir> <prompt>", "resume <dir> <sid> <prompt>").
"""
import importlib.util
import os
import sys
import time

_here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("fake_real", os.path.join(_here, "fake_real.py"))
real = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(real)

NAME = real.NAME
capabilities, skill_command, matches, preflight, events = (
    real.capabilities, real.skill_command, real.matches, real.preflight, real.events)


def _bump(name):
    p = os.path.join(os.environ.get("S08_DIR", "."), name)
    try:
        n = int(open(p).read())
    except (OSError, ValueError):
        n = 0
    with open(p, "w") as f:
        f.write(str(n + 1))
    return n + 1


def _question(state_dir):
    with open(os.path.join(state_dir, "QUESTION.md"), "w") as f:
        f.write("Q1: x\n")


def start(worktree, state_dir, prompt, system_prompt, plugin):
    n = _bump("starts")
    if n >= 2:
        os.environ.pop("FAKE_HARNESS_SCRIPT", None)
        real.start(worktree, state_dir, prompt, system_prompt, plugin)
        _question(state_dir)
        return 0
    rc = real.start(worktree, state_dir, prompt, system_prompt, plugin)
    msg = os.environ.get("S08_STDERR")
    if msg:
        with open(msg) as f:
            sys.stderr.write(f.read())
        sys.stderr.flush()
    if os.environ.get("S08_IDLE"):
        with open(os.path.join(os.environ["S08_DIR"], "pid.%d" % n), "w") as f:
            f.write("%d\n" % os.getpid())
        while True:
            time.sleep(0.2)
    return rc


def resume(worktree, state_dir, session_id, prompt):
    rc = real.resume(worktree, state_dir, session_id, prompt)
    _question(state_dir)
    return rc
