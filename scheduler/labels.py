#!/usr/bin/env python3
"""The labels the bot relies on, created in a repository when missing.

  labels.py ensure --repo OWNER/NAME    create `noodlebot`, `noodlebot-triaged`, `noodlebot-status`, `noodlebot-unit` if absent

Lists the repository's labels (every page); an existing label is left as it is, whatever its colour
or description. Prints one line per label created. A create that reports the label already exists
counts as success. Exits non-zero with the error on stderr when gh fails. GH_TOKEN must be set; stdlib only.
"""
import argparse, json, subprocess, sys

LABELS = [
    ("noodlebot", "fbca04", "Hand this issue to the n00dl3b0t: it triages it into the graph (only the owner's label counts)"),
    ("noodlebot-triaged", "c5def5", "Triaged by the noodlebot (see its comment)"),
    ("noodlebot-status", "5319e7", "Kept up to date by the noodlebot scheduler"),
    ("noodlebot-unit", "0e8a16", "A unit of noodlebot work, while it is built"),
]


def gh(method, path, body=None):
    cmd = ["gh", "api", "-X", method, path] + (["--input", "-"] if body is not None else [])
    r = subprocess.run(cmd, input=json.dumps(body) if body is not None else None,
                       capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        e = RuntimeError("gh api %s %s failed: %s" % (method, path, (r.stderr or r.stdout).strip()[:300]))
        e.stdout = r.stdout
        raise e
    return json.loads(r.stdout) if r.stdout.strip() else None


def already_exists(e):
    try:
        errs = json.loads(getattr(e, "stdout", "") or "").get("errors") or []
    except (ValueError, AttributeError):
        return False
    return any(isinstance(x, dict) and x.get("code") == "already_exists" for x in errs)


def existing(repo):
    names, page = set(), 1
    while True:
        got = gh("GET", "repos/%s/labels?per_page=100&page=%d" % (repo, page)) or []
        names.update((l.get("name") or "").lower() for l in got)
        if len(got) < 100:
            return names
        page += 1


def main():
    p = argparse.ArgumentParser()
    p.add_argument("cmd", choices=["ensure"])
    p.add_argument("--repo", required=True)
    a = p.parse_args()
    have = existing(a.repo)
    for name, color, desc in LABELS:
        if name.lower() in have:
            continue
        try:
            gh("POST", "repos/%s/labels" % a.repo, {"name": name, "color": color, "description": desc})
        except RuntimeError as e:
            if not already_exists(e):
                raise
            continue
        print("created label %s" % name)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print("labels.py: %s" % e, file=sys.stderr)
        sys.exit(1)
