"""Part of the GitHub backend (forges/github.py): a workflow's runs for a commit, the site's publishing, a branch's
push, a throwaway branch's deletion.

Not a module of its own: github.py compiles this file into its own namespace the first time a call needs one of these
operations (so a process compiles only the families it uses), and the functions named in _register at the end become
methods of its Backend. Everything github.py defines is in scope here; `gh` itself is run only by github.py's _run.
"""
import subprocess


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


def ci_logs(self, run, job=None):
    jobs, dec = [], json.JSONDecoder()
    out = self._gh(["api", "--paginate", self._r("/actions/runs/%d/jobs?per_page=100" % int(run))], None,
                   "gh api GET actions/runs jobs")
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
        res.append({"id": j["id"], "name": j.get("name"), "conclusion": j.get("conclusion"), "log": log})
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


def branch_delete(self, branch):
    def refuse(why):
        return forge.ForgeError("branch %s is not deleted: %s" % (branch, why))

    def lookup(path):
        try:
            return self._api("GET", path), False
        except forge.ForgeError as e:
            if e.status == 404:
                return None, True
            raise

    if branch == self.repo_default_branch():
        raise refuse("it is the default branch")
    got, gone = lookup(self._r("/branches/" + branch))
    if gone:
        return {"branch": branch, "result": "gone"}
    if not isinstance(got, dict):
        raise forge.ForgeError("gh api GET branches: no object in the answer")
    if got.get("protected"):
        raise refuse("it is protected")
    rules, no_rules = lookup(self._r("/rules/branches/" + branch))
    if not no_rules and not isinstance(rules, list):
        raise forge.ForgeError("gh api GET rules: no list in the answer")
    if any(isinstance(r, dict) and r.get("type") == "deletion" for r in rules or []):
        raise refuse("a rule forbids deleting it (deletion)")
    owner = self.repo.split("/")[0]
    for key, val in (("head", owner + ":" + branch), ("base", branch)):
        prs = self._api("GET", self._r("/pulls"), None, ["-f", "state=open", "-f", key + "=" + val])
        if not isinstance(prs, list):
            raise forge.ForgeError("gh api GET pulls: no list in the answer")
        if prs:
            raise refuse("an open pull request has it as its %s (#%s)" % (key, prs[0].get("number") if isinstance(prs[0], dict) else "?"))
    try:
        self._api("DELETE", self._r("/git/refs/heads/" + branch))
    except forge.ForgeError as e:
        if e.status == 403:
            raise forge.CapabilityOff("github", "branch_delete")
        if e.status == 404:
            return {"branch": branch, "result": "gone"}
        if e.status == 422:
            _, gone = lookup(self._r("/branches/" + branch))
            if gone:
                return {"branch": branch, "result": "gone"}
        raise
    return {"branch": branch, "result": "deleted"}


_register(ci_runs, ci_rerun, ci_logs, site_publish, branch_push, branch_delete)
