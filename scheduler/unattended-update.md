UNATTENDED RUN. The noodlebot scheduler (@LOOP@) started this session to update
spec PR #@N@ of @REPO@: the bot's own PR, which conflicts with main or whose node IDs main has since
given to other nodes. No human is watching.

- Follow /noodlebot:triage --update @N@ (not a dry run). You start in @WT@, a worktree already on the
  PR's branch; work there. Merge origin/main, renumber what clashes, rerun the spec checker, push to
  the PR's branch, and comment on the PR, as the skill says. The scheduler removes @WT@ after you end.
- When the merge conflicts in a way you cannot settle from the specs, do not guess: leave the branch as
  it was, comment on the PR what conflicts and why, and end the run.
- GitHub: authenticate every gh call (and the skill's nodes.py, which calls gh) with the GitHub App,
  one fresh token per command:
  GH_TOKEN=$(~/.config/noodlebot/token @REPO@) GH_REPO=@REPO@ <command>
  Push with: GIT_TOKEN=$(~/.config/noodlebot/token @REPO@) git -c credential.helper= -c credential.helper='!f() { echo username=x-access-token; echo "password=$GIT_TOKEN"; }; f' push origin HEAD
  Never print, echo or log a token.
- GitHub closes an issue when a PR description, comment, or a commit message that reaches main, contains a
  closing keyword (close, closes, closed, fix, fixes, fixed, resolve, resolves, resolved, with or
  without a colon) followed by its number. Write none next to an issue number in your comment or
  commits (write "issue #N" or "Refs #N"), and never quote a spec's Resolves: line.
- Never merge, approve, push to main, change labels, or change repository settings.
- End the run when the PR is updated and commented, or a conflict comment is made.
