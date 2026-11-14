#!/usr/bin/env python3
"""Issues the owner hands to the bot: open issues labelled `noodlebot`, triaged with /noodlebot:triage.

  issues.py next --repo OWNER/NAME --state DIR [--owner LOGIN]   print the first issue to triage, or nothing
  issues.py done --repo OWNER/NAME --number N                    swap `noodlebot` for `noodlebot-triaged`

`next` skips an issue unless the repository owner added the label (checked in the issue's events,
so a collaborator, a template or a workflow cannot hand work to the bot), and skips one whose
$NOODLEBOT_DATA/state/<repo>/issue/<N>/ holds FAILED or an unanswered QUESTION.md.
`next` also writes every non-PR issue it read to <state>/issues.json (number, title, whether the owner labelled it; a held issue is written with "labelled": null, gh is not asked about it). The forge is reached through forge.py (the token script named by $NOODLEBOT_FORGE_TOKEN_SCRIPT, or a GH_TOKEN in the environment); stdlib only.
"""
import argparse, json, os, sys, tempfile, time

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import forge   # the one interface to the code forge (G04)

LABEL, DONE = "noodlebot", "noodlebot-triaged"


def labelled_by(f, n):
    """Login of whoever last added LABEL to issue n, or None."""
    who = None
    for e in f.issue_events(number=n):
        if e["event"] == "labeled" and e["label"] == LABEL:
            who = e["actor"]
    return who


def held(state, n):
    d = os.path.join(state, "issue", str(n))
    ex = lambda f: os.path.exists(os.path.join(d, f))
    return ex("FAILED") or (ex("QUESTION.md") and not ex("ANSWER.md"))


def write_cache(state, seen):
    """$state/issues.json, the open issues read, for the API: a temporary file renamed. A failure is logged and goes no further."""
    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(prefix=".issues.json.", dir=state)
        with os.fdopen(fd, "w") as f:
            json.dump({"updated": int(time.time()), "issues": seen}, f)
        os.chmod(tmp, 0o644)
        os.replace(tmp, os.path.join(state, "issues.json"))
    except OSError as e:
        print("issues.py: could not write issues.json: %s" % e, file=sys.stderr)
        if tmp:
            try:
                os.unlink(tmp)
            except OSError:
                pass


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
        f = forge.open(a.repo)
        issues = f.issue_list(label=LABEL, state="open", oldest_first=True)
        first, seen = None, []
        for i in issues:
            if i["is_pr"]:
                continue
            if held(a.state, i["number"]):
                seen.append({"number": i["number"], "title": i["title"], "labelled": None})   # not asked: it is not a candidate
                continue
            try:
                lab = labelled_by(f, i["number"]) == owner
            except forge.ForgeError as e:
                if first is None:
                    raise
                print("issues.py: %s" % e, file=sys.stderr)   # after the issue to print: only the cache loses this entry
                continue
            seen.append({"number": i["number"], "title": i["title"], "labelled": lab})
            if first is None and lab:
                first = i["number"]
        if a.state:
            write_cache(a.state, seen)
        if first is not None:
            print(first)
    else:
        f = forge.open(a.repo)
        try:
            f.label_ensure(name=DONE, color="c5def5", description="Triaged by the noodlebot (see its comment)")
        except forge.ForgeError as e:
            if e.status != 422:  # an existing label (422) is no failure
                raise
        f.label_add(number=a.number, name=DONE)
        try:
            f.label_remove(number=a.number, name=LABEL)
        except forge.ForgeError as e:
            if e.status != 404 and "404" not in str(e) and "Label does not exist" not in str(e):
                raise


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print("issues.py: %s" % e, file=sys.stderr)
        sys.exit(1)
