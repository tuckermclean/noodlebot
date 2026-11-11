#!/usr/bin/env python3
"""The machine-wide queue of session starts: one start per gap, in a fixed order (S07).

  turn.py list|ask|giveback|took --root DATA --repo NAME [--tick S] [--gap S] [--starve S] [--now EPOCH] [KEY]

Every loop of the machine keeps its waiting units in DATA/state/NAME/waiting.json and shares the start
record DATA/state/starts.json. All reads and writes happen under an exclusive flock on
DATA/state/starts.lock, and files are replaced atomically, so two loops asking at once get one turn.

  list      read this loop's waiting units on stdin, one "<key> <kind> <size> <since-epoch>" per line
            (kind: triage|update|followup|resumed|fresh; size: S|M|L|-), store them with --tick, and
            clear this loop's give-backs. Lines that do not have four fields or a numeric since are ignored.
            A since that is a number but not finite (inf, nan) is an error: list exits 1 and removes this
            loop's waiting list, so the loop is left out (an ask from it gets no turn) until its next good list.
  ask       give this loop a turn when the gap has passed since the last start and the first unit of the
            merged order of all live loops is this loop's. It records the start and prints
            "<key>\\tturn: <kind or Size>, waited <H>h<MM>m, [first by the starvation limit, ]ahead of <units>";
            otherwise it prints nothing. Exit 0 either way.
  giveback  the start of KEY failed: restore the previous start record and leave KEY out of this loop's
            order until its next list.

  took      KEY was started without a turn (a released node): record its start like a granted ask, whatever the
            gap and the order, so a giveback of KEY restores the previous record. No KEY is an error.
            A previous record more than the gap in the future is dropped, as ask does.

Order: units that waited more than the starvation limit (--starve, SCHED_STARVE, 21600 s) first, the
longest waiting first; then triage/update/followup/resumed; then fresh S, M, L (no Size counts as L);
within a group the longest waiting first; ties by repository name, then the loop's own order.
The gap is --gap, else SCHED_START_GAP, else the largest tick among the live loops. A loop is live when
its state/NAME/heartbeat is less than three of its ticks old; stale loops and loops with a missing or
malformed waiting.json are left out. A missing or malformed starts.json means no start yet.
Exits 1 with a message on stderr on an error.
"""
import argparse
import fcntl
import json
import math
import os
import sys
import time

SMALL = ("triage", "update", "followup", "resumed")
GROUP = {"S": 1, "M": 2, "L": 3}


def num(x):
    try:
        return isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x)
    except OverflowError:  # a JSON integer too big for a float
        return False


def env_num(name, default):
    """The number in the environment variable (inf allowed), or the default when it is unset, empty, not a number or nan."""
    try:
        v = float(os.environ.get(name) or "x")
    except ValueError:
        return default
    return default if math.isnan(v) else v


def read_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def write_json(path, data):
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "w") as f:
        json.dump(data, f)
        f.write("\n")
    os.replace(tmp, path)


def valid_list(d):
    def text(x):
        return isinstance(x, str)
    return (isinstance(d, dict) and num(d.get("tick")) and d["tick"] > 0 and isinstance(d.get("units"), list)
            and all(isinstance(u, dict) and num(u.get("since")) and text(u.get("key"))
                    and text(u.get("kind")) and text(u.get("size")) for u in d["units"])
            and isinstance(d.get("gaveback", []), list) and all(text(k) for k in d.get("gaveback", [])))


def valid_start(d):
    return isinstance(d, dict) and num(d.get("time"))


def parse_units(text):
    units = []
    for line in text.splitlines():
        f = line.split()
        if len(f) != 4:
            continue
        try:
            since = float(f[3])
        except ValueError:
            continue
        if not math.isfinite(since):
            raise ValueError("unit %s: since %s is not finite" % (f[0], f[3]))
        units.append({"key": f[0], "kind": f[1], "size": f[2], "since": since})
    return units


def live_lists(state, now):
    """{repo: waiting list} of the live loops."""
    out = {}
    for repo in sorted(os.listdir(state)):
        d = read_json(os.path.join(state, repo, "waiting.json"))
        hb = read_json(os.path.join(state, repo, "heartbeat"))
        if valid_list(d) and num(hb) and now - hb < 3 * d["tick"]:
            out[repo] = d
    return out


def label(u):
    return u["kind"] if u["kind"] in SMALL else (u["size"] if u["size"] in GROUP else "L")


def order(lists, now, starve):
    """The merged order: [(unit, repo, starved, gaveback)]."""
    rows = []
    for repo, d in lists.items():
        skip = d.get("gaveback", [])
        for i, u in enumerate(d["units"]):
            wait = now - u["since"]
            starved = wait > starve
            group = 0 if u["kind"] in SMALL else GROUP.get(u["size"], 3)
            rows.append(((0 if starved else 1, -wait, 0 if starved else group, repo, i), u, repo, starved,
                         u["key"] in skip))
    # starved units compare by wait alone; the rest by group, then wait
    rows.sort(key=lambda r: (r[0][0], r[0][2], r[0][1], r[0][3], r[0][4]))
    return [(u, repo, starved, given) for _, u, repo, starved, given in rows]


def hm(secs):
    m = int(max(secs, 0) // 60)
    return "%dh%02dm" % (m // 60, m % 60)


def start_gap(lists, args):
    gap = args.gap
    if gap is None:
        gap = env_num("SCHED_START_GAP", None)
    if gap is None or not math.isfinite(gap):
        gap = max(d["tick"] for d in lists.values()) if lists else 0.0
    return gap


def ask(state, repo, now, args):
    lists = live_lists(state, now)
    if repo not in lists:
        return None
    gap = start_gap(lists, args)
    starve = args.starve
    if starve is None:
        starve = env_num("SCHED_STARVE", 21600.0)
    spath = os.path.join(state, "starts.json")
    last = read_json(spath)
    if not valid_start(last):
        last = None
    if last is not None and last["time"] > now + gap:
        last = None  # a start far in the future is a bad record (clock step, junk): no start yet
    if last is not None and now - last["time"] < gap:
        return None
    everyone = order(lists, now, starve)
    queue = [r for r in everyone if not r[3]]  # given-back units wait but get no turn
    if not queue or queue[0][1] != repo:
        return None
    u, _, starved, _ = queue[0]
    wait = now - u["since"]
    ahead = ["%s" % x["key"] if r == repo else "%s/%s" % (r, x["key"])
             for x, r, _, _ in everyone if x is not u and now - x["since"] > wait]
    text = "turn: %s, waited %s" % (label(u), hm(wait))
    if starved:
        text += ", first by the starvation limit"
    if ahead:
        text += ", ahead of " + ", ".join(ahead[:3]) + (", +%d more" % (len(ahead) - 3) if len(ahead) > 3 else "")
    prev = None
    if last is not None:
        prev = {k: v for k, v in last.items() if k != "prev"}
    write_json(spath, {"time": now, "repo": repo, "unit": u["key"], "prev": prev})
    return "%s\t%s" % (u["key"], text)


def took(state, repo, now, key, args):
    spath = os.path.join(state, "starts.json")
    last = read_json(spath)
    # as ask: a start far in the future (more than the gap) is a bad record, not a previous start
    if valid_start(last) and last["time"] > now + start_gap(live_lists(state, now), args):
        last = None
    prev = {k: v for k, v in last.items() if k != "prev"} if valid_start(last) else None
    write_json(spath, {"time": now, "repo": repo, "unit": key, "prev": prev})
    # a later giveback of KEY must restore this record, not be taken for an undone grant
    wpath = os.path.join(state, repo, "waiting.json")
    d = read_json(wpath)
    if valid_list(d) and key in d.get("gaveback", []):
        d["gaveback"] = [k for k in d["gaveback"] if k != key]
        write_json(wpath, d)


def giveback(state, repo, key):
    spath = os.path.join(state, "starts.json")
    last = read_json(spath)
    wpath = os.path.join(state, repo, "waiting.json")
    d = read_json(wpath)
    # a key already given back (until the next list) belongs to a grant already undone
    done = valid_list(d) and key in d.get("gaveback", [])
    if not done and valid_start(last) and last.get("repo") == repo and last.get("unit") == key:
        if valid_start(last.get("prev")):
            write_json(spath, last["prev"])
        else:
            os.unlink(spath)
    if valid_list(d):
        d["gaveback"] = sorted(set(d.get("gaveback", [])) | {key})
        write_json(wpath, d)


def main():
    p = argparse.ArgumentParser(prog="turn.py")
    p.add_argument("command", choices=("list", "ask", "giveback", "took"))
    p.add_argument("key", nargs="?")
    p.add_argument("--root", required=True)
    p.add_argument("--repo", required=True)
    p.add_argument("--tick", type=float)
    p.add_argument("--gap", type=float)
    p.add_argument("--starve", type=float)
    p.add_argument("--now", type=float)
    # KEY may follow the options (`took --root D --repo R A1`);
    # an older parse_args (3.12.3) binds an empty KEY with COMMAND and rejects it
    args = p.parse_intermixed_args()
    if args.now is not None and not math.isfinite(args.now):
        p.error("--now must be finite")
    state = os.path.join(args.root, "state")
    os.makedirs(os.path.join(state, args.repo), exist_ok=True)
    with open(os.path.join(state, "starts.lock"), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        now = time.time() if args.now is None else args.now
        if args.command == "list":
            if args.tick is None:
                p.error("list needs --tick")
            if not (math.isfinite(args.tick) and args.tick > 0):
                p.error("--tick must be a positive finite number")
            wpath = os.path.join(state, args.repo, "waiting.json")
            try:
                units = parse_units(sys.stdin.read())
            except ValueError:
                # leave this loop out until its next good list
                if os.path.exists(wpath):
                    os.unlink(wpath)
                raise
            write_json(wpath, {"tick": args.tick, "units": units, "gaveback": []})
        elif args.command == "ask":
            line = ask(state, args.repo, now, args)
            if line:
                print(line)
        elif args.command == "took":
            if not args.key:
                p.error("took needs a KEY")
            took(state, args.repo, now, args.key, args)
        else:
            if not args.key:
                p.error("giveback needs a KEY")
            giveback(state, args.repo, args.key)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # a failure is reported, never a traceback
        print("turn.py: %s" % e, file=sys.stderr)
        sys.exit(1)
