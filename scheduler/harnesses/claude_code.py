"""The Claude Code backend of scheduler/harness.py (S08).

Everything that is Claude Code's lives here: the `claude` command line and its settings, the credential, how a prompt
names a skill, how a session's process is recognised, and the translation of its stream-json output into the
normalised event log events.jsonl. The contract of a backend is in scheduler/testdata/harness/fake.py (its header);
the operations and events are documented in scheduler/harnesses/README.md.
"""
import fcntl
import json
import math
import os
import re
import signal
import stat
import subprocess
import sys
import threading
import time

NAME = "claude-code"
CAPS = ["usage", "resume", "bg-wait"]
LIMIT_RE = re.compile(r"usage limit|rate limit|limit reached|hit your limit", re.I)
CUTOFF_RE = re.compile(r"background tasks? still running.*after the last turn.*stopping them", re.I)


def capabilities():
    return list(CAPS)


def skill_command(skill, args, shipped=False):
    """/noodlebot:node B03, or /node B03 for a repository that ships its own skill."""
    return ("/%s %s" if shipped else "/noodlebot:%s %s") % (skill, args)


def matches(cmdline, unit):
    """cmdline: /proc/<pid>/cmdline with NULs turned into spaces."""
    return re.search(r"run-session\.sh .* %s( |$)|claude -p /node %s( |$)" % (re.escape(unit), re.escape(unit)), cmdline) is not None


def _oauth_path():
    return os.path.join(os.environ.get("HOME", ""), ".config", "noodlebot", "oauth-token")


def preflight():
    p = _oauth_path()
    if os.access(p, os.R_OK):
        return None
    return "%s is missing (claude setup-token)" % p


# --- the translation of one raw line into events ------------------------------------------------------------------

def _first(v, n):
    lines = v.splitlines()
    return lines[0][:n] if lines else ""


def _tool_text(inp):
    """(the first line of input.description, else command, else path, else file_path, uncut) or None."""
    for k in ("description", "command", "path", "file_path"):
        v = inp.get(k)
        if isinstance(v, str) and v.strip():
            lines = v.splitlines()
            return lines[0] if lines else None
    return None


def _label(inp):
    for k in ("description", "command", "file_path", "skill"):
        if inp.get(k):
            return _first(str(inp[k]), 100)
    return ""


def _bg_id(content):
    if isinstance(content, list):
        content = " ".join(str(x.get("text", "")) for x in content if isinstance(x, dict))
    if not isinstance(content, str):
        return None
    m = re.search(r"\bID: ([\w.-]*[\w-])", content) or re.search(r"agentId: ([\w.-]*[\w-])", content)
    return m.group(1) if m else None


def _num(v):
    """A finite number (not a bool) that fits a float; an integer too large for one is not."""
    if not isinstance(v, (int, float)) or isinstance(v, bool):
        return False
    try:
        return math.isfinite(v)
    except OverflowError:
        return False


def translate(line):
    """The events of one raw line (str), as dicts. Pure: the same line gives the same events live and rebuilt. A line
    that cannot be decoded or translated for any reason (nested too deeply to parse, say) is a "garbled" event."""
    try:
        return _translate(line)
    except Exception:   # RecursionError, OverflowError, MemoryError ...: never lose the lines after this one
        return [{"t": None, "type": "garbled"}] if line.strip() else []


def _translate(line):
    if not line.strip():
        return []
    try:
        d = json.loads(line)
    except ValueError:
        d = None
    if not isinstance(d, dict):
        return [{"t": None, "type": "garbled"}]
    t = d.get("timestamp") if isinstance(d.get("timestamp"), str) else None
    kind, out = d.get("type"), []
    sub = bool(d.get("parent_tool_use_id"))
    if kind == "system" and d.get("subtype") == "init" and d.get("session_id"):
        out.append({"t": t, "type": "start", "session": d["session_id"]})
    elif kind == "system" and d.get("subtype") == "task_notification" and (d.get("task_id") or d.get("tool_use_id")):
        out.append({"t": t, "type": "task_done", "ids": [x for x in (d.get("task_id"), d.get("tool_use_id")) if x]})
    elif kind == "rate_limit_event":
        ri = d.get("rate_limit_info")
        info = ri if isinstance(ri, dict) else {}
        wins = {}
        uw = info.get("unifiedWindows")
        if isinstance(uw, dict):
            for k, w in uw.items():
                if isinstance(w, dict):
                    wins[k] = {"status": w.get("status"), "has_status": "status" in w, "utilization": w.get("utilization"),
                               "reset": w.get("resetsAt")}
        out.append({"t": t, "type": "usage", "status": info.get("status"), "has_status": "status" in info,
                    "info_bad": bool(ri) and not isinstance(ri, dict), "reset": info.get("resetsAt"),
                    "window": info.get("rateLimitType"), "utilization": info.get("utilization"), "windows": wins})
    elif kind in ("assistant", "user"):
        msg = d.get("message")
        blocks = msg.get("content") if isinstance(msg, dict) else None
        for b in blocks if isinstance(blocks, list) else []:
            if not isinstance(b, dict):
                continue
            bt = b.get("type")
            if bt == "text" and kind == "assistant":
                txt = " ".join(str(b.get("text") or "").split())[:400]
                if txt:
                    out.append({"t": t, "type": "text", "text": txt, "subagent": sub})
            elif bt == "tool_use" and kind == "assistant":
                inp = b.get("input") if isinstance(b.get("input"), dict) else {}
                name = b.get("name")
                ds = inp.get("delaySeconds")   # a bool counts as 0 or 1, as api.py reads it
                delay = int(ds) if name == "ScheduleWakeup" and isinstance(ds, bool) else \
                    ds if name == "ScheduleWakeup" and isinstance(ds, (int, float)) else None
                full = _tool_text(inp)
                e = {"t": t, "type": "tool", "id": b.get("id"), "name": name, "text": None if full is None else full[:200],
                     "text_full": full, "label": _label(inp),
                     "subagent": sub, "background": inp.get("run_in_background") is True and name in ("Bash", "Agent"),
                     "delay": delay, "desc": None}
                if name in ("Agent", "Task"):
                    e["desc"] = inp.get("description") or "a subagent"
                out.append(e)
            elif bt == "tool_result" and kind == "user":
                out.append({"t": t, "type": "tool_result", "id": b.get("tool_use_id"), "subagent": sub,
                            "bg_id": _bg_id(b.get("content"))})
    elif kind == "result":
        r, st = d.get("result"), d.get("subtype")
        cost, turns = d.get("total_cost_usd"), d.get("num_turns")
        cost_ok = _num(cost)
        turns_ok = isinstance(turns, int) and _num(turns) and turns >= 0
        text = r.strip() if isinstance(r, str) and r.strip() else None
        out.append({"t": t, "type": "result", "subtype": st, "text": text, "cost": cost if cost_ok else None,
                    "turns": turns if turns_ok else None,
                    "limit": LIMIT_RE.search(str(r or "") + " " + str(st or "")) is not None})
    return out or [{"t": t, "type": "other"}]


# --- the event log -------------------------------------------------------------------------------------------------

def _dump(e):
    out = json.dumps(e, ensure_ascii=False) + "\n"
    try:
        out.encode("utf-8")
    except UnicodeEncodeError:   # a lone surrogate (a string cut in the middle of a pair): written escaped
        out = json.dumps(e) + "\n"
    return out


def _paths(state_dir):
    return (os.path.join(state_dir, "session.jsonl"), os.path.join(state_dir, "events.jsonl"),
            os.path.join(state_dir, "events.pos"), os.path.join(state_dir, "session.stderr"))


def _cut_off(stderr_path):
    try:
        with open(stderr_path, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 100000))
            tail = f.read().decode("utf-8", "replace")
    except OSError:
        return False
    return CUTOFF_RE.search(tail.replace("\n", " ")) is not None


def _tmp(path):
    return "%s.%d.%d.tmp" % (path, os.getpid(), threading.get_ident())   # readers and the recorder never share one


def _replace(path, text):
    tmp = _tmp(path)
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def _write_pos(path, n):
    _replace(path, "%d\n" % n)


def _lock(state_dir, block):
    """The lock the recorder holds for as long as it writes events.jsonl: a rebuild takes it too, so it never replaces
    the file under a live recorder. None when it is not to be had without waiting (block false)."""
    fd = os.open(os.path.join(state_dir, "events.lock"), os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | (0 if block else fcntl.LOCK_NB))
    except OSError:
        os.close(fd)
        return None
    return fd


def _build(state_dir, limit=None):
    raw, ev, pos, err = _paths(state_dir)
    parts, size = [], 0
    with open(raw, "rb") as f:
        for line in f:
            if limit is not None and size >= limit:
                break
            size += len(line)
            for e in translate(line.decode("utf-8", "replace")):
                parts.append(_dump(e))
    if _cut_off(err):
        parts.append(_dump({"t": None, "type": "cutoff"}))
    _replace(ev, "".join(parts))
    _write_pos(pos, size)


def rebuild(state_dir):
    """events.jsonl from session.jsonl (and session.stderr for the cutoff). False when a recorder is writing it."""
    fd = _lock(state_dir, False)
    if fd is None:
        return False
    try:
        _build(state_dir)
    finally:
        os.close(fd)
    return True


def _read_events(ev):
    try:
        with open(ev, encoding="utf-8", errors="replace") as f:
            out = []
            for l in f:
                try:
                    out.append(json.loads(l))
                except ValueError:
                    pass
            return out
    except OSError:
        return []


def _translate_file(state_dir):
    """The events of the raw log, translated in memory (no file is written, no lock taken); None without a raw log."""
    raw, _, _, err = _paths(state_dir)
    out = []
    try:
        with open(raw, "rb") as f:
            for line in f:
                out.extend(translate(line.decode("utf-8", "replace")))
    except OSError:
        return None
    if _cut_off(err):
        out.append({"t": None, "type": "cutoff"})
    return out


def events(state_dir, write=True):
    """The events of the session. write=False (the readers that must not write: the API, the report) translates the
    raw log in memory and creates no file; a state dir without a raw log gives the events file as it is."""
    raw, ev, pos, _ = _paths(state_dir)
    if not write:
        out = _translate_file(state_dir)
        return _read_events(ev) if out is None else json.loads(json.dumps(out))
    try:
        rsize = os.path.getsize(raw)
    except OSError:
        return _read_events(ev)
    try:
        with open(pos) as f:
            covered = int(f.read().strip())
    except (OSError, ValueError):
        covered = -1
    # behind the raw log, or a raw log that a new start truncated (covered > size): rebuild, unless a recorder is
    # writing the file (then it is being kept up to date, and the lines read so far are the truth)
    if not os.path.exists(ev) or covered != rsize:
        try:
            rebuild(state_dir)
        except OSError:
            pass
    return _read_events(ev)


def _finish(state_dir):
    """After the session: the cutoff is the last event, once."""
    _, ev, _, err = _paths(state_dir)
    if not _cut_off(err):
        return
    try:
        with open(ev, encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        lines = []
    keep = [l for l in lines if not re.match(r'\{"t": null, "type": "cutoff"\}$', l.strip())]
    new = keep + [_dump({"t": None, "type": "cutoff"})]
    if new != lines:
        _replace(ev, "".join(new))


# --- running claude --------------------------------------------------------------------------------------------------

def _credential():
    """The session credential, read once per start or resume (as $(cat file): trailing newlines cut)."""
    try:
        with open(_oauth_path()) as f:
            return f.read().rstrip("\n")
    except OSError:
        return ""


def _out_base():
    """The size of stdout when it is a regular file (the raw log, appended to), else None."""
    try:
        st = os.fstat(sys.stdout.fileno())
        return st.st_size if stat.S_ISREG(st.st_mode) else None
    except (OSError, ValueError):
        return None


def _open_events(state_dir, fresh, base):
    """Before the agent's first line: take the lock and make events.jsonl and events.pos exist and agree with the raw
    log (a fresh start on an empty log: both empty; never deleted, so no reader sees them missing and rebuilds under
    the recorder). Returns (lock fd, events.jsonl open for append)."""
    _, ev, pos, _ = _paths(state_dir)
    fd = _lock(state_dir, True)
    if fresh and not base:
        _replace(ev, "")
        _write_pos(pos, 0)
    elif base is not None:   # appending to a log that has a history: events.jsonl must cover exactly that
        try:
            with open(pos) as f:
                covered = int(f.read().strip())
        except (OSError, ValueError):
            covered = -1
        if covered != base or not os.path.exists(ev):
            _build(state_dir, base)
    evf = open(ev, "a", encoding="utf-8")
    return fd, evf


def _record_stream(src, evf, pos, base, out):
    """Pass the raw lines of src to out and append their events to evf, live. The raw line goes first (the log is the
    truth), then its events, then the position of the raw log that events.jsonl covers. A failure in the events leaves
    the position behind, so that a rebuild makes them whole, and does not stop the stream."""
    done, ok, raw_ok = base, True, True
    for line in src:
        if raw_ok:
            try:
                out.write(line)
                out.flush()
            except (OSError, ValueError):
                raw_ok = False   # the log cannot be written: keep reading, so that the agent is not sent EPIPE
        if done is not None:
            done += len(line)
        if not (ok and raw_ok):
            continue
        try:
            for e in translate(line.decode("utf-8", "replace")):
                evf.write(_dump(e))
            evf.flush()
            if done is not None:
                _write_pos(pos, done)
        except Exception as e:
            ok = False
            sys.stderr.write("harness: events.jsonl not written: %r\n" % (e,))
    try:
        evf.close()
    except OSError:
        pass


def _alive(pid):
    try:
        with open("/proc/%d/stat" % pid) as f:
            return f.read().rsplit(")", 1)[1].split()[0] not in ("Z", "X")
    except (OSError, IndexError):
        return False


def record(state_dir, fresh, pidfile=None):
    """The recorder of run-session.sh's pipeline: stdin is the agent's raw stream, stdout the raw log. It ignores
    SIGTERM (stop_idle signals every child of run-session.sh; the agent stops, this finishes at EOF, so events.jsonl is
    complete). A background task that kept the pipe open must not hold the session: once the agent (pid in pidfile) is
    gone and nothing has come on the stream for 5 s, it ends."""
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    base = _out_base()
    fd, evf = _open_events(state_dir, fresh, base)
    out = sys.stdout.buffer
    r, w = os.pipe()
    src = os.fdopen(r, "rb")
    last = [time.monotonic()]

    def copy():
        try:
            with os.fdopen(w, "wb") as dst:
                while True:
                    chunk = os.read(0, 65536)
                    if not chunk:
                        break
                    last[0] = time.monotonic()
                    dst.write(chunk)
                    dst.flush()
        except OSError:
            pass
    th = threading.Thread(target=copy, daemon=True)
    th.start()
    finish = threading.Thread(target=_record_stream, args=(src, evf, _paths(state_dir)[2], base, out), daemon=True)
    finish.start()
    while finish.is_alive():
        finish.join(0.5)
        pid = None
        if pidfile:
            try:
                with open(pidfile) as f:
                    pid = int(f.read().strip())
            except (OSError, ValueError):
                pid = None
        if pid is not None and not _alive(pid) and th.is_alive() and time.monotonic() - last[0] >= 5:
            finish.join(1)   # what the copy already passed on
            break
    _finish(state_dir)
    os.close(fd)
    return 0


def command(op, worktree, state_dir, *args):
    """What to run for start (prompt, system prompt file, plugin) or resume (session id, prompt): (argv, env, cwd).
    The credential is read here once and goes in the environment only."""
    env = dict(os.environ)
    env["CLAUDE_CODE_OAUTH_TOKEN"] = _credential()
    if not env.get("CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS"):
        env["CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS"] = "0"
    if op == "start":
        prompt, sp_file, plugin = args
        try:
            with open(sp_file) as f:
                sp = f.read().rstrip("\n")
        except OSError:
            sp = ""
        return _command(prompt, sp, plugin), env, worktree
    sid, prompt = args
    return _command(prompt, *_resume_context(state_dir), resume=sid), env, worktree


def _resume_context(state_dir):
    plugin = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "plugin"))
    try:
        with open(os.path.join(state_dir, "unattended.md")) as f:
            sp = f.read().rstrip("\n")
    except OSError:
        sp = ""
    return sp, plugin


def _run(worktree, state_dir, argv, fresh):
    env = dict(os.environ)
    env["CLAUDE_CODE_OAUTH_TOKEN"] = _credential()
    if not env.get("CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS"):
        env["CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS"] = "0"
    base = _out_base()
    fd, evf = _open_events(state_dir, fresh, base)
    proc = subprocess.Popen(argv, cwd=worktree, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE)

    def fwd(signum, frame):
        try:
            proc.send_signal(signum)
        except OSError:
            pass
    old = signal.signal(signal.SIGTERM, fwd)
    th = threading.Thread(target=_record_stream, args=(proc.stdout, evf, _paths(state_dir)[2], base, sys.stdout.buffer),
                          daemon=True)
    th.start()
    rc = proc.wait()
    th.join(5)   # a background task that kept the pipe open must not hold the session
    signal.signal(signal.SIGTERM, old)
    _finish(state_dir)
    os.close(fd)
    return 128 - rc if rc < 0 else rc


def _command(prompt, system_prompt, plugin, resume=None):
    return (["claude", "-p", prompt] + (["--resume", resume] if resume else []) +
            ["--plugin-dir", plugin, "--permission-mode", "auto", "--permission-prompts", "none",
             "--output-format", "stream-json", "--verbose", "--append-system-prompt", system_prompt])


def start(worktree, state_dir, prompt, system_prompt, plugin):
    return _run(worktree, state_dir, _command(prompt, system_prompt, plugin), True)


def resume(worktree, state_dir, session_id, prompt):
    sp, plugin = _resume_context(state_dir)
    return _run(worktree, state_dir, _command(prompt, sp, plugin, session_id), False)
