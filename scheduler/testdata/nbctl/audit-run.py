# audit-run.py <log> <script> [args...]: runs a script as __main__ with an audit hook that appends a line to <log> for
#   - each open / os.listdir / os.scandir of a path under $HOME or $NOODLEBOT_DATA other than $NOODLEBOT_DATA/api.sock
#   - each way of running another program (subprocess, exec, system, spawn, fork)
import os, runpy, sys
log = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
home = os.path.realpath(os.environ["HOME"])
data = os.path.realpath(os.environ["NOODLEBOT_DATA"])
sock = os.path.join(data, "api.sock")
RUN = {"subprocess.Popen", "os.exec", "os.system", "os.posix_spawn", "os.spawn", "os.fork", "os.forkpty"}
busy = False
def under(p, d): return p == d or p.startswith(d + os.sep)
def hook(ev, args):
    global busy
    if busy: return
    busy = True
    try:
        if ev in ("open", "os.listdir", "os.scandir"):
            p = args[0] if args else None
            if p is None or isinstance(p, int): return
            p = os.path.realpath(os.path.abspath(os.fsdecode(p)))
            if (under(p, home) or under(p, data)) and p != sock:
                os.write(log, ("%s %s\n" % (ev, p)).encode())
        elif ev in RUN:
            os.write(log, ("%s\n" % ev).encode())
    finally:
        busy = False
sys.addaudithook(hook)
script = sys.argv[2]
sys.argv = sys.argv[2:]
runpy.run_path(script, run_name="__main__")
