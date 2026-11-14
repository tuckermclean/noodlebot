#!/usr/bin/env python3
"""Credential scenarios for scheduler/forge.test.sh (G04-AC-3), run in one Python process: cred.py <scenario>.
  many     several calls on one forge, a second forge.open of the same repository, more calls (the token script must
           run once)
  repos    calls on two repositories (once each; the second repository's calls fail at gh, which is fine)
  fail     a call when the token script fails: must raise ForgeError saying the token script failed
  empty    a call when the token script prints nothing: must raise ForgeError (or work without a token), not crash
Prints one line `done` on success; a failure of the scenario's own expectation exits 1 with a line on stderr."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
import forge

scenario = sys.argv[1]
if scenario == "many":
    f = forge.open("acme/widgets")
    f.repo_default_branch()
    f.label_list()
    f.issue_view(number=1)
    g = forge.open("acme/widgets")
    g.issue_comments(number=1)
    f.pr_view(number=5)
elif scenario == "repos":
    for spec in ("acme/widgets", "acme/other", "acme/widgets", "acme/other"):
        try:
            forge.open(spec).repo_default_branch()
        except forge.ForgeError:
            pass
elif scenario == "fail":
    try:
        forge.open("acme/widgets").repo_default_branch()
    except forge.ForgeError as e:
        if "token script" not in str(e).lower():
            sys.exit("the error does not say the token script failed: %s" % e)
    else:
        sys.exit("no ForgeError although the token script failed")
elif scenario == "empty":
    try:
        forge.open("acme/widgets").repo_default_branch()
    except forge.ForgeError:
        pass
print("done")
