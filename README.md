# noodlebot

Automation that runs as the n00dl3b0t GitHub App (credentials in `~/.config/noodlebot/`, never in this repo).

- `scheduler/`: the v0 node scheduler for tuckermclean/themonolith. `scheduler/loop.sh` explains how to run it.
- `make test`: the ready-node test.
- `repos/`, `worktrees/` and `state/` are runtime directories and are ignored by git.
