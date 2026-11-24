# M04 — loops-unit

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | M01, P01 | M05 | S |

**Owns:** in `scheduler/loops.sh`: starting the tmux server in a systemd user unit of its own (`start`), the check of where an already running server lives, the lingering line (`start` and `status`), reading `~/.config/noodlebot/units`, and their lines in the header comment; `scheduler/loops-m04.test.sh` (new) and its line in the `Makefile`'s `TESTS`; the README's lines on the units file and lingering in its run instructions.
**Resolves:** #218

## Purpose
After this node the loops and the API no longer live in the login session of the shell that started them. With `~/.config/noodlebot/units` present and a systemd user manager reachable, `loops.sh start` starts the tmux server that holds every loop and the API in a unit of its own, so the end of the login's scope (a logout, or an OOM kill of `session.slice`) does not take them with it. When a tmux server already runs inside a login session, `start` says so and how to move it. `start` and `status` say plainly when lingering is off, which means a logout ends the user manager and everything in it. Without the file, or without a user manager (the container), nothing changes but one line saying where the loops run.

## Tests
- `scheduler/loops-m04.test.sh` (new) runs `loops.sh` with its own fakes on a scratch `PATH` (a `tmux` that logs its arguments and runs a `new -d` command detached and answers `display -p '#{pid}'` and `ls` from a state file the case sets; a `systemd-run` that logs its arguments and execs its command; a `loginctl` that prints `Linger=yes`, `Linger=no` or fails), a scratch `HOME` and runtime root, scratch paths under a folder named `M04`, and shows:
  - units on, no tmux server: the first `tmux new` of `start` (a loop's or the API's) runs through `systemd-run --user --scope` with the unit name `noodlebot-loops` (and `--collect`), the later ones directly, and every listed loop and the API start as before;
  - units on, a tmux server already running whose `/proc/<pid>/cgroup` (read from a fixture path the case points to) names a `session-<n>.scope`: `start` starts the loops in it as before and prints one line saying the loops then end with that login session and how to move them (stop the loops, end the server, start again); a server in a `noodlebot-loops` scope or a user service gets no line;
  - `Linger=no`: `start` and `status` each print one line saying lingering is off, so a logout stops the loops and the API, and naming `loginctl enable-linger`; `Linger=yes` or a failing `loginctl`: no such line; `loginctl` is never called with `enable-linger` or any other change;
  - units off (no file), `systemd-run` missing, or `systemd-run --user` failing (exit 1, no command run): `start` starts tmux as today, the loops run, and one line says they run in the calling shell's session; with `systemd-run` failing, `start` does not try it again for the later sessions;
  - nothing is written under `$HOME/.config/systemd`.
- Every existing `scheduler/loops*.test.sh`, `container/entrypoint.test.sh` and `container/container.test.sh` passes unchanged (no `units` file there).

## Changes
1. **The server in a unit.** `loops.sh` reads `~/.config/noodlebot/units` (S12's switch for the systemd user units). With it present, `start` runs its first `tmux new` through `systemd-run --user --scope --collect --unit noodlebot-loops` when no tmux server runs, so the server it forks stays in that scope after the client exits; the later `tmux new` calls join that server. When `systemd-run --user` fails, `start` starts tmux directly and says so once. *M04-AC-1, M04-AC-3.*
2. **A server already in a login.** With the units on and a tmux server already running, `start` reads the server's pid (`tmux display -p '#{pid}'`) and its cgroup, and when that is a login session's scope prints one line saying so and how to move the loops; it starts the missing loops as before. *M04-AC-1.*
3. **Lingering.** `start` and `status` read `loginctl show-user <user> -p Linger`; `Linger=no` gives one line saying a logout stops the loops and the API, and that `loginctl enable-linger <user>` keeps them. `loops.sh` never changes lingering or any other system setting. *M04-AC-2.*
4. **Without units.** With the file missing or no user manager, `start` behaves as M01 and P01 made it, plus one line saying the loops run in the calling shell's session. The README's run instructions name the units file, lingering and the line. *M04-AC-3.*

## Gate
- **M04-AC-1** — With `~/.config/noodlebot/units` present and `systemd-run --user` working, `loops.sh start` with no tmux server running starts the server through `systemd-run --user --scope` in the unit `noodlebot-loops`, and starts every listed loop and the API in it; with a server already running in a login session's scope it starts them as before and prints one line saying the loops end with that login and how to move them. *Verify:* `scheduler/loops-m04.test.sh`.
- **M04-AC-2** — When `loginctl` reports `Linger=no` for the user, `loops.sh start` and `loops.sh status` each print one line saying lingering is off and a logout stops the loops and the API, naming `loginctl enable-linger`; with `Linger=yes` or no answer they print none; `loops.sh` never changes lingering or writes under `~/.config/systemd`. *Verify:* `scheduler/loops-m04.test.sh`.
- **M04-AC-3** — With the units file missing, `systemd-run` missing or `systemd-run --user` failing, `loops.sh start` starts the loops and the API in tmux as it does today, with one line saying they run in the calling shell's session; every existing `scheduler/loops*.test.sh` and `container/*.test.sh` passes unchanged. *Verify:* `scheduler/loops-m04.test.sh` and the existing tests in `make test`.

## Risks
- A scope under the user manager survives the login's scope but not the user manager itself: with lingering off, a logout still ends the loops, which the lingering line says; turning lingering on is the owner's choice.
- An OOM kill of the whole user manager or of `user.slice` still ends the server; S12's scopes and raised OOM score make that much less likely, and M05 restarts the loops.
- The owner's own interactive tmux sessions share the default tmux server; when that server already runs in a login, the loops land there until it is restarted, as the line says.
- A tmux server started inside a scope keeps the environment `loops.sh` had; the runtime root and settings are already passed to each loop explicitly (M01, T03).
