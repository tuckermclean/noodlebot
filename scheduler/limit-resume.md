The usage limit stopped this session while it was idle, and the limit window has reset (the reset time is given below). Your process was stopped and this conversation resumed in a new one.

The background agents, background commands and watchers you had started were killed when the process stopped. Whatever they were doing was cut off mid-way, and any planned resume is gone.

Check what they left: the files in the worktree, the commits, the CI runs. Re-dispatch only what you still need; do not repeat work that is already done.

Then carry on with your task from where you were.

The forge is still reached through "$NOODLEBOT_FORGE", the forge CLI, which fetches credentials itself.
