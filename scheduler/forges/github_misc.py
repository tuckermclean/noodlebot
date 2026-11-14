"""Part of the GitHub backend (forges/github.py): a workflow's runs for a commit, the site's publishing, a branch's push.

Not a module of its own: github.py compiles this file into its own namespace the first time a call needs one of these
operations (so a process compiles only the families it uses), and the functions named in _register at the end become
methods of its Backend. Everything github.py defines is in scope here; `gh` itself is run only by github.py's _run.
"""
import subprocess


def ci_runs(self, workflow, sha, branch=None, event=None):
    extra = ["-f", "head_sha=" + sha]
    if event:
        extra += ["-f", "event=" + event]
    if branch:
        extra += ["-f", "branch=" + branch]
    got = self._api("GET", self._r("/actions/workflows/%s/runs" % workflow), None, extra)
    if not isinstance(got, dict) or not isinstance(got.get("workflow_runs"), list):
        raise forge.ForgeError("the answer for the runs of %s does not parse: no workflow_runs list" % workflow)
    return [{"id": o["id"], "status": o.get("status"), "conclusion": o.get("conclusion"),
             "head_sha": o.get("head_sha"), "created_at": o.get("created_at")}
            for o in got["workflow_runs"] if isinstance(o, dict)]


def site_publish(self, target, input):
    self._gh(["api", "-X", "PATCH", "gists/" + target, "--input", input], None, "gh api -X PATCH gists",
             PATCH_TIMEOUT)
    return {}


def branch_push(self, path, branch):
    helper = '!f() { echo username=x-access-token; echo "password=$NOODLEBOT_PUSH_TOKEN"; }; f'
    cmd = ["git", "-C", path]
    env, tok = self._env()
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


_register(ci_runs, site_publish, branch_push)
