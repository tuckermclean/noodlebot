#!/usr/bin/env python3
"""Issues the owner hands to the bot: open issues labelled `noodlebot`, triaged with /noodlebot:triage.

  issues.py next --repo OWNER/NAME --state DIR [--owner LOGIN]   print the first issue to triage, or nothing
  issues.py done --repo OWNER/NAME --number N                    swap `noodlebot` for `noodlebot-triaged`

`next` skips an issue unless the repository owner added the label (checked in the issue's events,
so a collaborator, a template or a workflow cannot hand work to the bot), and skips one whose
$NOODLEBOT_DATA/state/<repo>/issue/<N>/ holds FAILED or an unanswered QUESTION.md. GH_TOKEN must be set; stdlib only.
"""
import argparse, json, os, subprocess, sys

LABEL, DONE = "noodlebot", "noodlebot-triaged"


def gh(method, path, body=None):
    cmd = ["gh", "api", "-X", method, path] + (["--input", "-"] if body is not None else [])
    r = subprocess.run(cmd, input=json.dumps(body) if body is not None else None,
                       capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        raise RuntimeError("gh api %s %s failed: %s" % (method, path, (r.stderr or r.stdout).strip()[:300]))
    return json.loads(r.stdout) if r.stdout.strip() else None


def labelled_by(repo, n):
    """Login of whoever last added LABEL to issue n, or None."""
    who = None
    for e in gh("GET", "repos/%s/issues/%s/events?per_page=100" % (repo, n)) or []:
        if e.get("event") == "labeled" and (e.get("label") or {}).get("name") == LABEL:
            who = (e.get("actor") or {}).get("login")
    return who


def held(state, n):
    d = os.path.join(state, "issue", str(n))
    ex = lambda f: os.path.exists(os.path.join(d, f))
    return ex("FAILED") or (ex("QUESTION.md") and not ex("ANSWER.md"))


def main():
    p = argparse.ArgumentParser()
    p.add_argument("cmd", choices=["next", "done"])
    p.add_argument("--repo", required=True)
    p.add_argument("--state", default="")
    p.add_argument("--owner", default="")
    p.add_argument("--number", type=int)
    a = p.parse_args()
    owner = a.owner or a.repo.split("/")[0]
    if a.cmd == "next":
        issues = gh("GET", "repos/%s/issues?labels=%s&state=open&per_page=50&sort=created&direction=asc" % (a.repo, LABEL)) or []
        for i in issues:
            if "pull_request" in i or held(a.state, i["number"]):
                continue
            if labelled_by(a.repo, i["number"]) == owner:
                print(i["number"])
                return
    else:
        try:
            gh("POST", "repos/%s/labels" % a.repo, {"name": DONE, "color": "c5def5",
                                                  "description": "Triaged by the noodlebot (see its comment)"})
        except RuntimeError as e:
            if "already_exists" not in str(e) and "422" not in str(e):
                raise
        gh("POST", "repos/%s/issues/%d/labels" % (a.repo, a.number), {"labels": [DONE]})
        try:
            gh("DELETE", "repos/%s/issues/%d/labels/%s" % (a.repo, a.number, LABEL))
        except RuntimeError as e:
            if "404" not in str(e) and "Label does not exist" not in str(e):
                raise


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print("issues.py: %s" % e, file=sys.stderr)
        sys.exit(1)
