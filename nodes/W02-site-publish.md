# W02 — site-publish

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | W01 | W03 | M |

**Owns:** the `publish` command of `scheduler/site.py` and its cases in `scheduler/site.test.sh`; the visibility record and the publish step in `scheduler/loop.sh` and their cases in `scheduler/loop.test.sh`; the gist and token part of the README's status-site section.
**Resolves:** #47

## Purpose
After this node the status-site files (W01) reach a public gist about a minute after the state changes, and an unchanged state costs no request. Every loop ends its tick with `site.py publish`. It rebuilds the files and compares their hashes with what was last published. It sends only the changed files, with a small `manifest.json`, in one `PATCH` to the gist the owner made by hand, at most once a minute across all loops of the machine. A GitHub App installation token cannot write gists, so the publish uses an owner token limited to gists. That token is kept in `~/.config/noodlebot/` like the other credentials, read for the one command, and never printed, logged or stored.

## Tests
- `scheduler/site.test.sh` (extended): `site.py publish` against the W01 fixture with a fake `gh` that records each call's arguments, environment and request body, and answers 200, 404, 422, 403 or 500 as told. Its cases:
  - a first publish;
  - a second run with nothing changed;
  - a change in one repository;
  - a change within the minimum interval;
  - a due keepalive;
  - a repository removed from the list;
  - each error answer;
  - two publishes started at once.

  In every case the test checks that the token's value appears in no argument, no output and no file under the runtime root.
- `scheduler/loop.test.sh` (extended): a loop with a fake gist id and token file runs the publish step after its report step on every tick. Without those files it makes no publish and writes one status-log line at start. A publish that starts failing writes one line, and its recovery writes another. The visibility record is written at start. `SCHED_SITE=0` turns the step off.

## Changes
1. **Visibility.** At loop start, in the label step and with that step's token, the loop asks GitHub whether its repository is private (`gh api repos/<owner>/<name> --jq .private`). It writes `public`, `private` or, on a failed call, `unknown` to `state/<name>/visibility`. An `unknown` is asked again on the next tick until it is known. *W02-AC-6.*
2. **The publish command.** `site.py publish --data-root DIR --repos FILE --gist ID [--throttle LINE] [--min-interval 60] [--keepalive 900] [--now EPOCH]` works as follows, with `GH_TOKEN` set by its caller:
   - It takes `$NOODLEBOT_DATA/site/lock` without waiting. If another publish holds the lock, it does nothing and exits 0.
   - It builds the files into `$NOODLEBOT_DATA/site/out/` (W01) and computes each file's SHA-256.
   - It compares the hashes with `$NOODLEBOT_DATA/site/published.json`, which records what the gist last accepted and when.
   - When no hash changed and the last publish is less than `--keepalive` seconds old, it makes no request. It also makes none when a hash changed but the last publish is less than `--min-interval` seconds old: the next tick sends the change.
   - Otherwise it makes one `PATCH gists/<ID>` with `gh api --input <file>`. The body holds the changed files, `manifest.json` and a `null` for each file it published before but no longer builds (a repository removed or made private).
   - The manifest holds the schema version (W01), `updated` (the time any file's content last changed), `seen` (this publish's time) and every file's hash.
   - On a 2xx answer it rewrites `published.json`, writing a new file and renaming it over the old one.

   *W02-AC-1, W02-AC-2, W02-AC-3.*
3. **Errors and the gist's existence.** The publisher never creates a gist: it never calls `POST gists`. A 404 is reported as `gist <ID> not found or not writable with this token`, and any other non-2xx answer or failed call is reported with its status. In both cases `published.json` stays as it was, so the next run sends the change again. The command exits 1 with one line on stderr naming the status and no response body. *W02-AC-4.*
4. **The loop's step.** After `report` on every tick, when `~/.config/noodlebot/gist` (the gist ID, one line) and `~/.config/noodlebot/gist-token` both exist, the loop runs `timeout 60 site.py publish` as follows:
   - with `GH_TOKEN` read from `gist-token` in that one command's environment, never into a shell variable that outlives it, never on a command line, and never into Git configuration;
   - with the repository list `~/.config/noodlebot/repos`, or a list of the loop's own repository when that file is missing;
   - with the throttle line of the tick;
   - with stderr appended to `state/<name>/site.log`.

   The loop adds to the status log as follows:
   - when either file is missing, the step does nothing, and the loop writes one line at start: `status site off: no gist configured`;
   - the first failure after a success (or after the start) is one line `status site: publish failed (<status>)`, and the next success is one line `status site: publishing again`;
   - repeated failures add only to `site.log`.

   `SCHED_SITE=0` turns the step off. A failure never stops or delays the tick's other work, as for `report`. Sessions are not given the gist token. *W02-AC-5.*
5. **The README.** The status-site section says how to make the public gist by hand, how to make a token limited to gists (a classic token with only the `gist` scope, or a fine-grained token with only the Gists account permission), and where to put the ID and the token (`~/.config/noodlebot/gist`, `~/.config/noodlebot/gist-token`, mode 0600). *W02-AC-5.*

## Gate
- **W02-AC-1** — The first publish to an empty `published.json` sends one `PATCH gists/<ID>` holding every built file and `manifest.json`. The manifest has the schema version, `updated`, `seen` and each file's SHA-256, and those hashes match the files' bytes. A second run with nothing changed and the keepalive not due makes no `gh` call at all. *Verify:* `scheduler/site.test.sh`.
- **W02-AC-2** — After a change to one repository's state, the next publish (once `--min-interval` has passed) sends only that repository's file, `manifest.json` and any file whose own hash changed. A change within `--min-interval` of the last publish sends nothing, and the next run past it sends the change. A repository dropped from the list or made private has its file deleted (`null`) in the next `PATCH`. *Verify:* `scheduler/site.test.sh`.
- **W02-AC-3** — With nothing changed, a publish `--keepalive` seconds or more after the last one sends only `manifest.json`, with a new `seen` and an unchanged `updated`. Of two publishes started at once, exactly one makes a request. *Verify:* `scheduler/site.test.sh`.
- **W02-AC-4** — For each of the answers 404, 422, 403 and 500 and a failed call, the publish exits 1 with one stderr line naming the status, leaves `published.json` unchanged, and sends the same change on its next run. It never calls `POST gists`. *Verify:* `scheduler/site.test.sh`.
- **W02-AC-5** — With `~/.config/noodlebot/gist` and `gist-token` present, every tick runs the publish after `report`, with `GH_TOKEN` equal to the token file's contents. The token appears in no command line (the fake `gh` records its arguments), and in nothing under the runtime root (`status.log`, `site.log`, `report.log`, every session's environment and prompt). A missing file gives one `status site off: no gist configured` line per start and no publish. The first failure after a success is one `status site: publish failed (<status>)` line, and the recovery is one `status site: publishing again` line. `SCHED_SITE=0` runs no publish. The README section names the two files and the token's only scope. *Verify:* `scheduler/loop.test.sh` and `scheduler/site.test.sh`.
- **W02-AC-6** — At start the loop writes `public`, `private` or (on a failed call) `unknown` to `state/<name>/visibility`, and an `unknown` is asked again on the next tick. A repository marked `private` or `unknown` is never in a `PATCH`. *Verify:* `scheduler/loop.test.sh`.

## Risks
- Unverified until the owner sets it up: a real gist `PATCH` with a gist-only token, and that GitHub keeps accepting about 60 updates an hour. Each update is a gist revision. If the revision history makes `GET /gists/<id>` slow or large, the publish would need to recreate the gist by hand now and then. Recreating is the owner's step, since the publisher never creates one.
- Visibility is read once per loop start. A repository made private while its loop runs is still published until the loop restarts (a deploy restarts it).
- Every loop publishes every repository, so one loop with a stale clone can briefly publish an older view of another repository's graph. Each loop keeps its own clone on `origin/main` every tick, so the next publish corrects it.
- The keepalive (default 15 minutes) slightly departs from "unchanged ticks make no request" in issue #47. Without it, the page could not tell a quiet loop from a dead machine. `--keepalive 0` turns it off.
