#!/usr/bin/env python3
"""The pickup step (S09): a small agent with no tools sorts the owner comments that report.py cannot place; the loop, not
the agent, carries out what it decides and replies once to each comment.

  pickup.py --repo SPEC --state DIR --owner LOGIN [--clone DIR] [--worktrees DIR] [--version V] [--signature S] items
  pickup.py ... run                 one tick's step: no items, nothing; else one run, then its apply; prints one status line
  pickup.py ... apply --run RUNDIR  check and carry out the decisions of one run (again: nothing is done or posted twice)

SPEC is the forge (forge.py: OWNER/NAME, github:OWNER/NAME, fake:FOLDER); nothing is taken from its shape. DIR is
state/<name>; the open PRs are DIR/open-prs.tsv.

Items: report.py --pickup writes each owner comment it cannot place to DIR/pickup/pending/<comment id>.json (with the reply it
would have posted). `items` prints {"items", "questions", "prs", "units"}: the pending comments by the owner, minus those whose
URL is recorded as an answer (ANSWER.md, answered/*-ANSWER.md) or as feedback (FEEDBACK.md, answered/*-FEEDBACK.md) of a unit, those
in DIR/pickup/handled (one comment id per line) and those in a run whose actions are being finished.

Run: DIR/pickup/<UTC timestamp>/ holds items.json, prompt.md (scheduler/pickup.md and the items), the session's log and events
(harness.py small-start: the small model, no tools, one turn) and state.json (what was done per item). The agent's whole
output (the last `result` event's text) is a JSON list, one object per item: {"item": id or url, "action": "answer" | "feedback" |
"request" | "note", "unit", "pr", "title", "reason"}.

Apply: a decision is refused when its action is not one of the four, when `answer` names a unit with no open question, or when
`feedback` names a PR that is not an open bot PR (node/<ID>-... or spec/...); all decisions are refused when the run used a tool
or its output is not such a list with exactly one decision per item. A refused item gets the pending file's reply (report.py's
own, signed) and one line "pickup.py: refused <url>: <reason>" on stderr. An accepted one is carried out, once:
  answer    ANSWER.md as report.py records an answer (its URL, a +1, the answer-received milestone);
  feedback  feedback.py add: the item in the PR unit's FEEDBACK.md;
  request   one new issue quoting the comment and linking it, with no label;
  note      nothing.
and gets one reply on its thread (what was done, and the start clause). An item is recorded as done before its reply, and goes
into the handled record once the reply is posted; a failed post (exit 1) is retried by the next apply (and by `run`).
Nothing outside DIR is written. The budget and the ceiling (S09 slice 3) decide in start_allowed().
"""
import argparse
import glob
import json
import os
import re
import subprocess
import sys
import time

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)
import feedback   # add(): the hand-over of an item from outside the PR (G03, S09)
import forge      # the one interface to the code forge (G04)
import harness    # the one interface to the agent harness (S08)
import report     # the unit and answer bookkeeping: record_answer, start_clause, waiting, the signature

ACTIONS = ("answer", "feedback", "request", "note")
MAX_ITEMS = 40        # items in one run: the prompt is one argument (Linux caps it at 128 KiB)
MAX_TEXT = 1500       # characters of one item's text in the prompt
MAX_LIST = 40         # lines of each list of what is open
SESSION_TIMEOUT = 300


def log(msg):
    print("pickup.py: " + msg, file=sys.stderr)


def write_json(path, data):
    with open(path + ".tmp", "w", encoding="utf-8") as f:
        json.dump(data, f, indent=1)
    os.replace(path + ".tmp", path)


def read_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def pdir(a):
    return os.path.join(a.state, "pickup")


# --- the items ------------------------------------------------------------------------------------------------------

def handled_ids(a):
    try:
        with open(os.path.join(pdir(a), "handled"), encoding="utf-8") as f:
            return {l.strip() for l in f if l.strip()}
    except OSError:
        return set()


def run_dirs(a):
    return sorted(d for d in glob.glob(os.path.join(pdir(a), "*")) if os.path.isfile(os.path.join(d, "items.json")))


def in_flight(a):
    """The ids of the items some run has started on (their actions are done or being finished)."""
    out = set()
    for d in run_dirs(a):
        out |= set(read_json(os.path.join(d, "state.json"), {}))
    return out


def unit_dirs(a):
    return sorted(glob.glob(os.path.join(a.state, "node", "*")) + glob.glob(os.path.join(a.state, "issue", "*")) +
                  glob.glob(os.path.join(a.state, "pr", "*")))


def recorded_urls(a):
    """The URLs recorded as an answer or as feedback in any unit's state folder."""
    urls = set()
    for d in unit_dirs(a):
        urls |= feedback.answer_urls(d)
        for p in [os.path.join(d, "FEEDBACK.md")] + glob.glob(os.path.join(d, "answered", "*-FEEDBACK.md")):
            try:
                with open(p, encoding="utf-8", errors="replace") as f:
                    urls |= {m.group(1) for m in re.finditer(r"^url: (\S+)[ \t]*$", f.read(), re.M)}
            except OSError:
                pass
    return urls


def pending_items(a):
    """The pending records of the owner's comments not recorded, handled or in flight, oldest first."""
    skip = handled_ids(a) | in_flight(a)
    urls = recorded_urls(a)
    out = []
    for p in glob.glob(os.path.join(pdir(a), "pending", "*.json")):
        c = read_json(p, None)
        try:
            u = c["author"]
            if not (u["login"] == a.owner and u["is_owner"] and not u["is_bot"]):
                continue
            if str(c["id"]) in skip or c["url"] in urls:
                continue
            c["id"], c["issue"], c["body"], c["reply"]   # the fields the run needs
        except (KeyError, TypeError):
            continue
        out.append(c)
    return sorted(out, key=lambda c: c["id"])


def first_line(path, n=200):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for l in f:
                if l.strip():
                    return l.strip()[:n]
    except OSError:
        pass
    return ""


def bot_prs(a):
    """{PR number: branch} of the open bot PRs on node/<ID>-... or spec/... (feedback.py's rule)."""
    out = {}
    try:
        with open(os.path.join(a.state, "open-prs.tsv"), encoding="utf-8") as f:
            for line in f:
                p = line.split()
                if len(p) >= 4 and p[0].isdigit() and p[3] == "true" and feedback.unit_dir(a.state, int(p[0]), p[1]):
                    out[int(p[0])] = p[1]
    except OSError:
        pass
    return out


def pr_unit(branch, n):
    m = re.match(r"node/([A-Z][0-9][0-9])-", branch)
    return m.group(1) if m else "PR #%d" % n


def context(a):
    """The short lines of what is open: questions, bot PRs, units."""
    questions = []
    for u in report.waiting(a.state):
        d = report.tdir(a.state, u)
        try:
            issue = " (issue #%d)" % int(open(os.path.join(d, "issue")).read().split()[0])
        except (OSError, ValueError, IndexError):
            issue = ""
        questions.append("%s%s: %s" % (u, issue, first_line(os.path.join(d, "QUESTION.md"))))
    prs = ["#%d %s (unit %s)" % (n, b, pr_unit(b, n)) for n, b in sorted(bot_prs(a).items())]
    units = []
    for u in report.nodes(a.state):
        st = "question open" if u in report.waiting(a.state) else \
            "answered" if report.has(a.state, u, "QUESTION.md") else \
            "feedback pending" if report.has(a.state, u, "FEEDBACK.md") else "idle"
        units.append("%s: %s" % (u, st))
    return questions[:MAX_LIST], prs[:MAX_LIST], units[:MAX_LIST]


def cmd_items(a):
    q, prs, units = context(a)
    print(json.dumps({"items": [{"id": c["id"], "url": c["url"], "issue": c["issue"], "text": c["body"]}
                                for c in pending_items(a)],
                      "questions": q, "prs": prs, "units": units}))
    return 0


# --- the run --------------------------------------------------------------------------------------------------------

def start_allowed(a):
    """(True, "") when a run may start now. The budget and the ceiling of S09's slice 3 decide here."""
    return True, ""


def new_rundir(a):
    base = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    for i in range(1000):
        d = os.path.join(pdir(a), base + ("" if i == 0 else "-%d" % i))
        try:
            os.makedirs(d)
            return d
        except FileExistsError:
            continue
    raise OSError("cannot make a run folder")


def prompt_text(a, items):
    with open(os.path.join(HERE, "pickup.md"), encoding="utf-8") as f:
        text = f.read().rstrip("\n") + "\n"
    q, prs, units = context(a)
    for title, lines in (("Open questions", q), ("Open pull requests of the bot", prs), ("Units", units)):
        text += "\n## %s\n\n" % title + ("".join("- %s\n" % l for l in lines) or "(none)\n")
    text += "\n## Items\n"
    for c in items:
        body = c["body"].strip()
        if len(body) > MAX_TEXT:
            body = body[:MAX_TEXT] + " (cut)"
        text += "\n### item %s (on #%s, %s)\n\n%s\n" % (c["id"], c["issue"], c["url"], body)
    return text


def decision_line(c, ent):
    if ent.get("ok"):
        return "%s %s%s" % (c["id"], ent["action"], " " + str(ent["detail"]) if ent.get("detail") else "")
    return "%s refused" % c["id"]


def cmd_run(a):
    for d in run_dirs(a):   # replies that failed earlier are retried first
        st = read_json(os.path.join(d, "state.json"), {})
        if any(not st.get(str(c["id"]), {}).get("done") for c in read_json(os.path.join(d, "items.json"), [])):
            try:
                apply_run(a, d)
            except Exception as e:
                log("retrying %s: %s" % (d, e))
    items = pending_items(a)[:MAX_ITEMS]
    if not items:
        return 0
    ok, why = start_allowed(a)
    if not ok:
        log("no run: %s" % why)
        return 0
    rundir = new_rundir(a)
    write_json(os.path.join(rundir, "items.json"), items)
    prompt = os.path.join(rundir, "prompt.md")
    with open(prompt, "w", encoding="utf-8") as f:
        f.write(prompt_text(a, items))
    try:
        with open(os.path.join(rundir, "session.jsonl"), "w") as out, open(os.path.join(rundir, "session.stderr"), "w") as err:
            r = subprocess.run([sys.executable, "-I", os.path.join(HERE, "harness.py"), "small-start", rundir, prompt],
                               stdin=subprocess.DEVNULL, stdout=out, stderr=err, cwd=rundir, timeout=SESSION_TIMEOUT)
        if r.returncode:
            log("the run's session exited %d" % r.returncode)
    except (OSError, subprocess.TimeoutExpired) as e:
        log("the run's session failed: %s" % e)
    rc, state = apply_run(a, rundir)
    cost = next((e.get("cost") for e in reversed(events_of(rundir)) if e.get("type") == "result" and
                 isinstance(e.get("cost"), (int, float))), None)
    print("pickup run %s: items [%s]; decisions [%s]; cost $%s" % (
        os.path.basename(rundir), " ".join(c["url"] for c in items),
        "; ".join(decision_line(c, state.get(str(c["id"]), {})) for c in items), "%.4f" % cost if cost is not None else "0"))
    sys.stdout.flush()
    return rc


# --- the decisions --------------------------------------------------------------------------------------------------

def events_of(rundir):
    try:
        return harness.events(rundir, write=False)
    except Exception as e:
        log("cannot read the events of %s: %s" % (rundir, e))
        return []


def decisions(rundir, items):
    """({str(item id): decision}, None) or (None, why every decision is refused)."""
    evs = events_of(rundir)
    if any(e.get("type") == "tool" for e in evs):
        return None, "the run used a tool"
    text = next((e.get("text") for e in reversed(evs) if e.get("type") == "result"), None)
    if not isinstance(text, str) or not text.strip():
        return None, "the run gave no output"
    text = text.strip()
    m = re.match(r"^```(?:json)?[ \t]*\n(.*)\n```$", text, re.S)
    try:
        lst = json.loads(m.group(1) if m else text)
    except ValueError:
        return None, "the output is not JSON"
    if not isinstance(lst, list) or not all(isinstance(d, dict) for d in lst):
        return None, "the output is not a list of decisions"
    byref = {}
    for c in items:
        byref[str(c["id"])] = byref[c["url"]] = str(c["id"])
    out = {}
    for d in lst:
        ref = d.get("item")
        key = byref.get(str(ref) if isinstance(ref, (int, str)) and not isinstance(ref, bool) else None)
        if key is None:
            return None, "a decision names an item that is not in the run"
        if key in out:
            return None, "two decisions for one item"
        out[key] = d
    if any(str(c["id"]) not in out for c in items):
        return None, "an item has no decision"
    return out, None


class Ctx:
    """What report.py's record_answer and comment need (the namespace its main() builds), built when first needed."""

    def __init__(self, args):
        self.a = a = argparse.Namespace(
            repo=args.repo, state=args.state, worktrees=args.worktrees, owner=args.owner, clone=args.clone,
            version=args.version, signature=args.signature, site="", answered=False, pickup=False, first_run=False,
            pulls=[], pulls_ok=True)

        class Errors(list):
            def append(self, e):
                log("report: %s" % e)
                super().append(e)

        a.errors = Errors()
        path = os.path.join(args.state, "report.json")
        self.rs = a.rs = read_json(path, {})

        def save():
            write_json(path, self.rs)

        a.save = save
        report.forge = forge
        a.forge = forge.open(args.repo)


def check(a, d):
    """None when the decision d is acceptable, else the reason it is refused."""
    act = d.get("action")
    if act not in ACTIONS:
        return "the action %r is not one of %s" % (act if isinstance(act, (str, int)) else "?", ", ".join(ACTIONS))
    if act == "answer":
        unit = d.get("unit")
        if not isinstance(unit, str) or unit.strip() not in report.waiting(a.state):
            return "%s has no open question" % (unit.strip() if isinstance(unit, str) and unit.strip() else "no unit")
    elif act == "feedback":
        pr = d.get("pr")
        if isinstance(pr, str) and pr.strip().isdigit():
            pr = int(pr)
        if not isinstance(pr, int) or isinstance(pr, bool) or pr not in bot_prs(a):
            return "PR %s is not an open bot PR" % (pr if isinstance(pr, (int, str)) else "?")
    elif act == "request":
        if not isinstance(d.get("title"), str) or not d["title"].strip():
            return "a request needs a title"
    return None


def perform(ctx, args, rundir, c, ent):
    """Carry out the accepted decision of ent (steps are recorded in ent, so a retry repeats none) and set ent["reply"]."""
    a, url = ctx.a, c["url"]
    act = ent["action"]
    if act == "answer":
        unit = ent["unit"]
        if not ent.get("recorded"):
            what = report.record_answer(a, ctx.rs, unit, {"id": c["id"], "url": url, "created_at": c["created_at"]}, c["body"])
            ent["recorded"] = True
            ent["reply"] = "Recorded as %s's ANSWER.md from this comment (%s); %s." % (
                unit, url, what or "its session starts at its turn")
            yield
        if not ent.get("reacted"):
            a.forge.issue_react(comment=int(c["id"]))
            ent["reacted"] = True
    elif act == "feedback":
        if not ent.get("handed"):
            item = os.path.join(rundir, "item-%s.json" % c["id"])
            write_json(item, {"id": c["id"], "url": url, "author": c["author"]["login"], "time": c["created_at"],
                              "body": c["body"]})
            if feedback.add(args.state, os.path.join(args.state, "open-prs.tsv"), ent["pr"], item) != 0:
                raise RuntimeError("feedback.py add failed")
            ent["handed"] = True
            try:
                clause = report.start_clause(a, ent["unit"], answered=True)
            except Exception:
                clause = "its session starts at its turn"
            ent["reply"] = "Handed to %s as feedback on PR #%d (%s); %s." % (ent["unit"], ent["pr"], url, clause)
    elif act == "request":
        if not ent.get("issue"):
            quote = "\n".join("> " + l for l in c["body"].strip()[:4000].splitlines())
            body = report.signed(a, "Written from the owner's comment %s:\n\n%s" % (url, quote))
            ent["issue"] = a.forge.issue_create(title=ent["title"], body=body)["number"]
            ent["reply"] = ("Opened #%d for this request (%s). It has no label: it waits until you add the `noodlebot` "
                            "label to hand it to the bot." % (ent["issue"], url))
    else:
        ent["reply"] = "Noted (%s); nothing was changed." % url


def refuse(a, c, ent, why):
    ent.update(ok=False, reply=c["reply"], why=why)
    log("refused %s: %s" % (c["url"], why))


def apply_run(a, rundir):
    """Carry out the run's decisions and post the replies; returns (exit code, state). Exit 1: a reply or step failed."""
    items = read_json(os.path.join(rundir, "items.json"), [])
    statep = os.path.join(rundir, "state.json")
    state = read_json(statep, {})
    todo = [c for c in items if not state.get(str(c["id"]), {}).get("done")]
    if not todo:
        return 0, state
    ctx = None
    plan, whole = None, None
    got = False
    rc = 0
    done = handled_ids(a)
    for c in todo:
        key = str(c["id"])
        ent = state.setdefault(key, {})
        try:
            ctx = ctx or Ctx(a)
            if "reply" not in ent and "action" not in ent:   # not decided yet
                if not got:
                    plan, whole = decisions(rundir, items)
                    got = True
                if plan is None:
                    refuse(a, c, ent, whole)
                else:
                    d = plan[key]
                    why = check(a, d)
                    if why:
                        refuse(a, c, ent, why)
                    else:
                        act = d["action"]
                        ent.update(ok=True, action=act)
                        if act == "answer":
                            ent.update(unit=d["unit"].strip(), detail=d["unit"].strip())
                        elif act == "feedback":
                            pr = int(d["pr"])
                            ent.update(pr=pr, unit=pr_unit(bot_prs(a)[pr], pr), detail="PR #%d" % pr)
                        elif act == "request":
                            t = d["title"].strip().splitlines()[0][:120]
                            ent.update(title=t, detail=t)
                write_json(statep, state)
            if ent.get("ok"):
                for _ in perform(ctx, a, rundir, c, ent):
                    write_json(statep, state)   # a step is recorded before the next
                write_json(statep, state)
        except Exception as e:
            log("%s: %s" % (c["url"], e))
            rc = 1
            write_json(statep, state)
            if not ent.get("reply"):
                continue
        if not ent.get("replied"):
            try:
                report.comment(ctx.a, c["issue"], ent["reply"])
                ent["replied"] = True
                write_json(statep, state)
            except Exception as e:
                log("the reply to %s was not posted: %s" % (c["url"], e))
                rc = 1
                continue
        if ent.get("ok") and ent["action"] == "answer" and not ent.get("reacted"):
            rc = 1
            continue
        if key not in done:
            with open(os.path.join(pdir(a), "handled"), "a", encoding="utf-8") as f:
                f.write(key + "\n")
        ent["done"] = True
        write_json(statep, state)
        try:
            os.remove(os.path.join(pdir(a), "pending", key + ".json"))
        except OSError:
            pass
    return rc, state


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--state", required=True)
    ap.add_argument("--owner", required=True)
    ap.add_argument("--clone", default="")
    ap.add_argument("--worktrees", default="")
    ap.add_argument("--version", default="")
    ap.add_argument("--signature", default="")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("items")
    sub.add_parser("run")
    sp = sub.add_parser("apply")
    sp.add_argument("--run", required=True)
    a = ap.parse_args()
    if a.cmd == "items":
        return cmd_items(a)
    if a.cmd == "run":
        return cmd_run(a)
    if not os.path.isfile(os.path.join(a.run, "items.json")):
        log("no run at %s" % a.run)
        return 2
    return apply_run(a, a.run)[0]


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:   # one line for the loop's log
        log(str(e))
        sys.exit(1)
