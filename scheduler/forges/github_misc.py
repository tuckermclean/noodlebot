"""Part of the GitHub backend (forges/github.py): a workflow's runs for a commit, the site's publishing, a branch's
push.

Not a module of its own: github.py compiles this file into its own namespace the first time a call needs one of these
operations (so a process compiles only the families it uses), and the functions named in _register at the end become
methods of its Backend. Everything github.py defines is in scope here; `gh` itself is run only by github.py's _run.
"""
import math
import subprocess
import time

DISPATCH_WAIT = 60  # seconds to look for the run a dispatch started ($FORGE_DISPATCH_WAIT overrides it, read at each call)
DISPATCH_POLL = 2   # seconds between two listings ($FORGE_DISPATCH_POLL)


def ci_runs(self, workflow=None, sha=None, branch=None, event=None):
    extra = ["-f", "head_sha=" + sha] if sha else []
    if event:
        extra += ["-f", "event=" + event]
    if branch:
        extra += ["-f", "branch=" + branch]
    path = "/actions/workflows/%s/runs" % workflow if workflow else "/actions/runs"
    got = self._api("GET", self._r(path), None, extra)
    if not isinstance(got, dict) or not isinstance(got.get("workflow_runs"), list):
        raise forge.ForgeError("the answer for the runs of %s does not parse: no workflow_runs list" % (workflow or "the repository"))
    return [{"id": o["id"], "status": o.get("status"), "conclusion": o.get("conclusion"),
             "head_sha": o.get("head_sha"), "created_at": o.get("created_at")}
            for o in got["workflow_runs"] if isinstance(o, dict)]


def ci_rerun(self, run):
    path = self._r("/actions/runs/%d/rerun-failed-jobs" % int(run))
    self._gh(["api", "-X", "POST", path], None, "gh api -X POST " + path.split("?")[0])
    return {}


def _dispatch_ids(self, workflow, ref):
    """The ids of the workflow's workflow_dispatch runs on the ref (one listing, newest page; a full ref is filtered by its
    short branch or tag name, as a run's head_branch is)."""
    short = re.sub(r"^refs/(?:heads|tags)/", "", ref)
    got = self._api("GET", self._r("/actions/workflows/%s/runs" % workflow), None,
                    ["-f", "event=workflow_dispatch", "-f", "branch=" + short, "-f", "per_page=100"])
    if not isinstance(got, dict) or not isinstance(got.get("workflow_runs"), list):
        raise forge.ForgeError("the answer for the runs of %s does not parse: no workflow_runs list" % workflow)
    return {o["id"] for o in got["workflow_runs"] if isinstance(o, dict) and "id" in o}


def _positive(var, default):
    """The float in $var when it is finite and above 0, else the default."""
    try:
        v = float(os.environ.get(var, default))
    except ValueError:
        return float(default)
    return v if math.isfinite(v) and v > 0 else float(default)


def ci_dispatch(self, workflow, ref, input=None):
    inputs = {}
    for s in input or []:
        k, _, v = s.partition("=")
        inputs[k] = v
    wait, poll = (_positive("FORGE_DISPATCH_WAIT", DISPATCH_WAIT), max(_positive("FORGE_DISPATCH_POLL", DISPATCH_POLL), 0.05))
    before = _dispatch_ids(self, workflow, ref)
    try:
        got = self._api("POST", self._r("/actions/workflows/%s/dispatches" % workflow), {"ref": ref, "inputs": inputs, "return_run_details": True})
    except forge.ForgeError as e:
        if e.status == 403:
            raise forge.CapabilityOff("github", "ci_dispatch")
        raise
    if isinstance(got, dict) and isinstance(got.get("workflow_run_id"), int):
        return {"id": got["workflow_run_id"]}
    deadline = time.monotonic() + wait
    while True:
        with _TOKEN_LOCK:
            _TOKENS.pop(self.repo, None)   # a token from the script is fetched afresh for each listing (not a caller's GH_TOKEN)
        try:
            new = sorted(_dispatch_ids(self, workflow, ref) - before)
        except forge.ForgeError as e:
            raise forge.ForgeError("the dispatch of %s on %s was accepted but the runs listing failed (%s): "
                                   "look with `ci runs` before dispatching again" % (workflow, ref, e))
        if len(new) == 1:
            return {"id": new[0]}
        if len(new) > 1:
            raise forge.ForgeError("the dispatch of %s on %s found %d new runs (%s): look with `ci runs`, the run is not guessed" % (
                workflow, ref, len(new), ", ".join(str(i) for i in new)))
        if time.monotonic() >= deadline:
            raise forge.ForgeError("the dispatch of %s on %s was accepted but its run was not found within %g seconds: "
                                   "look with `ci runs` before dispatching again" % (workflow, ref, wait))
        time.sleep(max(0.0, min(poll, deadline - time.monotonic())))


def ci_logs(self, run, job=None, attempt=None):
    jobs, dec = [], json.JSONDecoder()
    tail = "/actions/runs/%d/attempts/%d/jobs" % (int(run), int(attempt)) if attempt is not None else "/actions/runs/%d/jobs" % int(run)
    try:
        out = self._gh(["api", "--paginate", self._r(tail + "?per_page=100")], None, "gh api GET actions/runs jobs")
    except forge.ForgeError as e:
        if attempt is not None and e.status == 403:
            raise forge.CapabilityOff("github", "ci_logs")
        raise
    pos = 0
    while pos < len(out):
        while pos < len(out) and out[pos].isspace():
            pos += 1
        if pos >= len(out):
            break
        doc, pos = dec.raw_decode(out, pos)
        if not isinstance(doc, dict) or not isinstance(doc.get("jobs"), list):
            raise forge.ForgeError("gh api GET actions/runs jobs: no jobs list in the answer")
        jobs += doc["jobs"]
    res = []
    for j in jobs:
        if job is not None and j.get("name") != job:
            continue
        try:
            log = self._gh(["api", self._r("/actions/jobs/%d/logs" % int(j["id"]))], None, "gh api GET actions/jobs logs")
        except forge.ForgeError as e:
            if e.status == 403:
                raise forge.CapabilityOff("github", "ci_logs")
            raise
        res.append({"id": j["id"], "name": j.get("name"), "conclusion": j.get("conclusion"), "log": log,
                    "html_url": j.get("html_url")})
    return res


def site_publish(self, target, input):
    self._gh(["api", "-X", "PATCH", "gists/" + target, "--input", input], None, "gh api -X PATCH gists",
             PATCH_TIMEOUT)
    return {}


def branch_push(self, path, branch):
    helper = '!f() { echo username=x-access-token; echo "password=$NOODLEBOT_PUSH_TOKEN"; }; f'
    cmd = ["git", "-C", path]
    env, tok = self._env()
    env = dict(os.environ if env is None else env)
    env.pop("GH_TOKEN", None)  # git gets the token only as the variable its credential helper reads
    if tok:
        env["NOODLEBOT_PUSH_TOKEN"] = tok
        cmd += ["-c", "credential.helper=", "-c", "credential.helper=" + helper]
    env.setdefault("GIT_TERMINAL_PROMPT", "0")
    cmd += ["push", self.repo_clone_url(), branch]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, errors="replace", timeout=300, env=env,
                           stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError) as e:
        raise forge.ForgeError("git push of %s failed: %s" % (branch, type(e).__name__))
    if r.returncode != 0:
        raise forge.ForgeError("git push of %s failed (exit %d): %s" % (
            branch, r.returncode, self._scrub(r.stderr, tok)[:300]))
    return {}


_register(ci_runs, ci_rerun, ci_dispatch, ci_logs, site_publish, branch_push)
