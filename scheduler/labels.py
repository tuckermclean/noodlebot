#!/usr/bin/env python3
"""The labels the bot relies on, created in a repository when missing.

  labels.py ensure --repo OWNER/NAME    create `noodlebot`, `noodlebot-triaged`, `noodlebot-status`, `noodlebot-unit` if absent

Lists the repository's labels (every page); an existing label is left as it is, whatever its colour
or description. Prints one line per label created. A create that reports the label already exists
counts as success. Exits non-zero with the error on stderr when the forge call fails. The forge is reached through forge.py
(the token script named by $NOODLEBOT_FORGE_TOKEN_SCRIPT, or a GH_TOKEN in the environment); stdlib only.
"""
import argparse, os, sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import forge   # the one interface to the code forge (G04)

LABELS = [
    ("noodlebot", "fbca04", "Hand this issue to the n00dl3b0t: it triages it into the graph (only the owner's label counts)"),
    ("noodlebot-triaged", "c5def5", "Triaged by the noodlebot (see its comment)"),
    ("noodlebot-status", "5319e7", "Kept up to date by the noodlebot scheduler"),
    ("noodlebot-unit", "0e8a16", "A unit of noodlebot work, while it is built"),
]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("cmd", choices=["ensure"])
    p.add_argument("--repo", required=True)
    a = p.parse_args()
    f = forge.open(a.repo)
    have = {l["name"].lower() for l in f.label_list() if l["name"]}
    for name, color, desc in LABELS:
        if name.lower() in have:
            continue
        if f.label_ensure(name=name, color=color, description=desc)["created"]:  # an "already exists" answer is success
            print("created label %s" % name)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print("labels.py: %s" % e, file=sys.stderr)
        sys.exit(1)
