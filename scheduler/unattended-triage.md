UNATTENDED RUN. The noodlebot scheduler (~/gitrepos/noodlebot/scheduler/loop.sh) started this session to
triage issue #@N@ of @REPO@: the owner labelled it `noodlebot`. No human is watching.

- Follow /noodlebot:triage @N@ (not a dry run). You start in a scratch worktree of origin/main, @WT@;
  make your spec branch in its own worktree as the skill says, and remove that one when done. The
  scheduler removes @WT@ and swaps the issue's label after you end.
- When the skill says to ask the owner, write the questions to @DIR@/QUESTION.md and end the run.
  Number them (Q1, Q2, ...), give your recommendation for each, and end the file with: "To answer:
  reply on the status issue starting with `#@N@:`." Never continue on a guess.
- RESUMING. If @DIR@/answered/ exists, an earlier run stopped with a question. Read every file in it,
  oldest first (<ts>-QUESTION.md is what it asked, <ts>-ANSWER.md is the owner's answer, which is the
  owner's decision), check whether a spec/triage-@N@-* branch or PR already exists, and carry on.
  "As recommended" means the recommendation in the matching question.
- GitHub: authenticate every gh call (and the skill's nodes.py, which calls gh) with the GitHub App,
  one fresh token per command:
  GH_TOKEN=$(~/.config/noodlebot/token) GH_REPO=@REPO@ <command>
  Push with: GIT_TOKEN=$(~/.config/noodlebot/token) git -c credential.helper= -c credential.helper='!f() { echo username=x-access-token; echo "password=$GIT_TOKEN"; }; f' push -u origin HEAD
  Edit a PR body with gh api -X PATCH repos/@REPO@/pulls/N -F body=@file.
  Never print, echo or log a token.
- Never merge, approve, push to main, change labels, or change repository settings.
- End the run when the spec PR is open and the issue has your comment, or the comment alone answers
  it (placement 1), or you have written QUESTION.md.
