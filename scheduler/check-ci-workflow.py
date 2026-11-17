#!/usr/bin/env python3
# D10: read a workflow (default .github/workflows/test.yml) and report every way a failing `make test`
# could still end in a successful run. Prints one line per problem, then `PROBLEMS <n>`; exit 1 if n > 0.
#   python3 -I scheduler/check-ci-workflow.py [<workflow>]
# The expected env values repeat D08-AC-1's; change them here when the CI budgets change.
import os
import re
import sys

EVENTS = ("pull_request", "push")
EXPECT = {"TEST_FILE_BUDGET": "60", "TEST_BUDGET": "360", "SITE_TESTS": "required"}
IF_RE = re.compile(r"^(?:\$\{\{\s*)?github\.event_name\s*==\s*(?:'([^']*)'|\"([^\"]*)\")\s*(?:\}\})?$")


def is_make_test(run):
    if not isinstance(run, str):
        return False
    for seg in re.split(r"[;&|\n()]", run):
        toks = seg.split()
        if any(t.endswith("runtests.sh") for t in toks):
            return True
        for i, t in enumerate(toks):
            if t == "make" and "test" in toks[i + 1:]:
                return True
    return False


def step_events(step):
    """The events a step runs on, or None when its if: cannot be read."""
    if "if" not in step:
        return set(EVENTS)
    cond = step["if"]
    m = IF_RE.match(cond.strip()) if isinstance(cond, str) else None
    if not m:
        return None
    ev = m.group(1) if m.group(1) is not None else m.group(2)
    return {ev} & set(EVENTS)


def triggers(wf):
    on = wf.get("on", wf.get(True))
    if isinstance(on, str):
        return {on: None}
    if isinstance(on, list):
        return {str(x): None for x in on}
    if isinstance(on, dict):
        return {str(k): v for k, v in on.items()}
    return {}


def check(wf):
    out = []
    trig = triggers(wf)
    if "pull_request" not in trig:
        out.append("workflow: not triggered by pull_request")
    if "push" not in trig:
        out.append("workflow: not triggered by push to main")
    else:
        v = trig["push"]
        br = v.get("branches") if isinstance(v, dict) else None
        if br is not None and "main" not in (br if isinstance(br, list) else [br]):
            out.append("workflow: push is not triggered for branch main")
        if isinstance(v, dict) and "branches-ignore" in v:
            ign = v["branches-ignore"]
            if "main" in (ign if isinstance(ign, list) else [ign]):
                out.append("workflow: push ignores branch main")

    wf_env = wf.get("env")
    if wf_env is not None and not isinstance(wf_env, dict):
        out.append("workflow: env is not a mapping")
    jobs = wf.get("jobs")
    if not isinstance(jobs, dict):
        jobs = {}
        out.append("workflow: jobs is not a mapping")
    runs = {e: [] for e in EVENTS}
    for jid, job in jobs.items():
        jid = str(jid)
        if not isinstance(job, dict):
            out.append("%s: job is not a mapping" % jid)
            continue
        steps = job.get("steps")
        if not isinstance(steps, list):
            continue
        found = []
        for i, step in enumerate(steps):
            if isinstance(step, dict) and is_make_test(step.get("run")):
                found.append((i, step))
        if not found:
            continue
        if "if" in job:
            out.append("%s: job has an if:, it may skip make test" % jid)
        if job.get("continue-on-error", False) is not False:
            out.append("%s: continue-on-error is %s on the job, must be false" % (jid, job["continue-on-error"]))
        job_env = job.get("env")
        if job_env is not None and not isinstance(job_env, dict):
            out.append("%s: env is not a mapping" % jid)
        for i, step in found:
            pre = "%s / %s" % (jid, step.get("name") or "step %d" % (i + 1))
            if step.get("continue-on-error", False) is not False:
                out.append("%s: continue-on-error is %s, must be false" % (pre, step["continue-on-error"]))
            run = step["run"]
            if run.strip() != "make test":
                out.append("%s: run is %r, must be exactly make test" % (pre, run.strip()))
            step_env = step.get("env")
            if step_env is not None and not isinstance(step_env, dict):
                out.append("%s: env is not a mapping" % pre)
            evs = step_events(step)
            if evs is None:
                out.append("%s: if: %r cannot be read, must be absent or github.event_name == '<event>'" % (pre, step["if"]))
                continue
            env = {}
            for lvl in (wf_env, job_env, step_env):
                if isinstance(lvl, dict):
                    env.update({str(k): v for k, v in lvl.items()})
            for e in sorted(evs):
                runs[e].append(jid)
                want = dict(EXPECT)
                if e == "pull_request":
                    want["TEST_BUDGET_ENFORCE"] = "1"
                for k in sorted(list(want) + ["TEST_BUDGET_ENFORCE"]):
                    val = env.get(k)
                    sv = None if val is None else str(val)
                    if sv is not None and "${{" in sv:
                        out.append("%s: %s is an expression (%s), cannot be read" % (pre, k, sv))
                    elif k in want:
                        if sv != want[k]:
                            out.append("%s: %s is %s on %s, must be %s" % (pre, k, sv, e, want[k]))
                    elif sv == "1":
                        out.append("%s: TEST_BUDGET_ENFORCE is 1 on push, must not be" % pre)
    for e in EVENTS:
        if len(runs[e]) != 1:
            who = ",".join(sorted(set(runs[e])))
            out.append("%smake test steps on %s: %d, must be exactly one" % (who + ": " if who else "", e, len(runs[e])))
    return out


def main(argv):
    if len(argv) > 2:
        print("usage: check-ci-workflow.py [<workflow>]", file=sys.stderr)
        return 2
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    path = argv[1] if len(argv) == 2 else os.path.join(root, ".github", "workflows", "test.yml")
    try:
        import yaml
        with open(path, encoding="utf-8") as f:
            wf = yaml.safe_load(f)
        if not isinstance(wf, dict):
            raise ValueError("not a mapping at top level")
        problems = check(wf)
    except Exception as exc:  # unreadable or unparseable: one problem
        problems = ["%s: cannot be read: %s" % (path, str(exc).splitlines()[0] if str(exc) else type(exc).__name__)]
    for p in problems:
        print(p)
    print("PROBLEMS %d" % len(problems))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
