#!/usr/bin/env python3
"""The plan's usage, read from the sessions' own rate_limit_event lines, and whether to hold new sessions.

  usage.py --state-root DIR [--now EPOCH]

All repositories' sessions run on one account, so they share one budget: this reads every
DIR/<repo>/{node,issue,pr}/*/session.jsonl changed in the last 7 days and merges what it finds into
DIR/usage.json. Within a window usage only grows, so the current reading of a window is the highest
utilization among the readings with the latest reset time; no timestamps are needed.

It holds new sessions (running ones are never stopped) when:
- a window's status is not "allowed";
- the 5-hour window is projected to pass USAGE_5H_LIMIT (default 0.90) by its reset, at the burn rate
  of the last 30 minutes (or of the whole window so far, with too few samples);
- only with USAGE_7D_PACE=1 (off by default): the 7-day window is more than USAGE_7D_MARGIN (default 0.10)
  ahead of an even pace for the week. The reading is kept in usage.json either way.
Prints one line: "open: ..." or "hold: <reason>"; exits 0 either way (1 only on an error).
"""
import glob
import json
import os
import sys
import time

FIVE_H, WEEK = 5 * 3600, 7 * 86400


def readings(root, now):
    """{window: {"resetsAt", "utilization", "status"}} from the session logs."""
    out = {}
    pats = [os.path.join(root, "*", k, "*", "session.jsonl") for k in ("node", "issue", "pr")]
    for f in [f for p in pats for f in glob.glob(p)]:
        try:
            if os.path.getmtime(f) < time.time() - WEEK:   # file age: the real clock
                continue
            fh = open(f, errors="replace")
        except OSError:
            continue
        with fh:
            for line in fh:
                if '"rate_limit_event"' not in line:
                    continue
                try:
                    info = json.loads(line).get("rate_limit_info") or {}
                except (ValueError, AttributeError):
                    continue
                for name, w in (info.get("unifiedWindows") or {}).items():
                    merge(out, name, w)
    return out


def merge(into, name, w):
    """Keep the reading with the latest reset; within one reset, the highest utilization."""
    try:
        r, u = int(w["resetsAt"]), float(w["utilization"])
    except (KeyError, TypeError, ValueError):
        return
    cur = into.get(name)
    st = w.get("status", "allowed")
    if cur is None or r > cur["resetsAt"]:
        into[name] = {"resetsAt": r, "utilization": u, "status": st}
    elif r == cur["resetsAt"] and (u > cur["utilization"] or st != "allowed"):
        into[name] = {"resetsAt": r, "utilization": max(u, cur["utilization"]),
                      "status": st if st != "allowed" else cur["status"]}


def main():
    a = sys.argv
    root = a[a.index("--state-root") + 1]
    now = float(a[a.index("--now") + 1]) if "--now" in a else time.time()
    lim5 = float(os.environ.get("USAGE_5H_LIMIT", "0.90"))
    margin7 = float(os.environ.get("USAGE_7D_MARGIN", "0.10"))
    pace7 = os.environ.get("USAGE_7D_PACE") == "1"
    path = os.path.join(root, "usage.json")
    try:
        prev = json.load(open(path))
    except (OSError, ValueError):
        prev = {}
    win = dict(prev.get("windows") or {})
    for name, w in readings(root, now).items():
        merge(win, name, w)
    # Samples of the 5-hour window, for the burn rate; only the current window's.
    five = win.get("five_hour")
    samples = [s for s in prev.get("samples5h") or [] if five and s[2] == five["resetsAt"]]
    if five and (not samples or samples[-1][1] != five["utilization"] or now - samples[-1][0] > 300):
        samples.append([now, five["utilization"], five["resetsAt"]])
    samples = [s for s in samples if s[0] >= now - FIVE_H][-60:]

    hold, why, proj = [], [], None
    for name, w in win.items():
        if w["resetsAt"] > now and w["status"] != "allowed":
            hold.append("%s window %s" % (name.replace("_", "-"), w["status"]))
    if five and five["resetsAt"] > now:
        u, left = five["utilization"], five["resetsAt"] - now
        recent = [s for s in samples if s[0] >= now - 1800]
        if len(recent) >= 2 and recent[-1][0] - recent[0][0] >= 300:
            rate = (recent[-1][1] - recent[0][1]) / (recent[-1][0] - recent[0][0])
        else:
            elapsed = max(FIVE_H - left, 600)
            rate = u / elapsed
        proj = min(u + max(rate, 0) * left, 9.99)
        why.append("5-hour %.0f%%, projected %.0f%% at its reset" % (u * 100, proj * 100))
        if proj >= lim5:
            hold.append("5-hour window projected to reach %.0f%% before it resets (limit %.0f%%)" % (proj * 100, lim5 * 100))
    seven = win.get("seven_day")
    pace = None
    if seven and seven["resetsAt"] > now:
        pace = min(max(1 - (seven["resetsAt"] - now) / WEEK, 0), 1)
        why.append("7-day %.0f%% at %.0f%% of the week" % (seven["utilization"] * 100, pace * 100))
        if pace7 and seven["utilization"] > pace + margin7:
            hold.append("7-day window %.0f%% used at %.0f%% of the week (more than %.0f%% ahead of pace)"
                        % (seven["utilization"] * 100, pace * 100, margin7 * 100))

    state = {"updated": now, "windows": win, "samples5h": samples, "projected5h": proj, "weekElapsed": pace,
             "hold": bool(hold), "reason": "; ".join(hold) if hold else "", "summary": "; ".join(why) or "no reading yet",
             "limits": {"five_hour": lim5, "seven_day_margin": margin7, "seven_day_pace": pace7}}
    with open(path + ".tmp", "w") as f:
        json.dump(state, f, indent=1)
    os.replace(path + ".tmp", path)
    print(("hold: " + state["reason"]) if hold else ("open: " + state["summary"]))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        print("usage.py: %s" % e, file=sys.stderr)
        sys.exit(1)
