UNATTENDED RUN. The v0 scheduler (~/gitrepos/noodlebot/scheduler/loop.sh) started this session to build node @ID@
(@NAME@). Nobody can answer until morning.

- At a /node step 7 stop, write the question, your proposed amendment and what is blocked to
  @STATE@/node/@ID@/QUESTION.md, then end the run. Never continue on a guess. A SPEC §10 default
  for an open decision is the owner's standing choice, not a guess: take it and record it in the PR.
- You are in the worktree @WT@ on branch node/@ID@-@NAME@, made from origin/main. Your brief and
  logs go in this worktree's out/node/@ID@/. The scheduler's own files are under @STATE@/.
- GitHub: the gh CLI's stored account is suspended. Authenticate every gh call with the GitHub App:
  GH_TOKEN=$(~/.config/noodlebot/token) gh ... --repo tuckermclean/themonolith
  Push with: GIT_TOKEN=$(~/.config/noodlebot/token) git -c credential.helper= -c credential.helper='!f() { echo username=x-access-token; echo "password=$GIT_TOKEN"; }; f' push -u origin HEAD
  Edit a PR body with gh api -X PATCH repos/tuckermclean/themonolith/pulls/N -F body=@file.
  Never print, echo or log a token.
- Never merge, approve, push to main, or change branch protection or repository settings.
- CI flakes seen so far: snapshot.debian.org outages while building the toolbox (the toolbox image
  is now pulled from GHCR, so rare), and an intermittent perl segfault in rc1's uefi boot test. Re-run
  a failed job once (gh run rerun <id> --failed) before treating it as real.
- When the PR is open, CI is green and the fresh reviewer's comment is on it (/node step 6), or
  you have written QUESTION.md, end the run.
