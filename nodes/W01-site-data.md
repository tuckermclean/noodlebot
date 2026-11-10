# W01 — site-data

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | none | W02 | M |

**Owns:** the `build` command of `scheduler/site.py`, `scheduler/site-schema.json`, `scheduler/site.test.sh`, its line in the `Makefile`'s `test` target, the fixtures `scheduler/testdata/site/`.
**Resolves:** #47

## Purpose
After this node everything the status site shows exists as a few small JSON files, built from what the loops already keep on the machine, with no GitHub call. `scheduler/site.py build` writes one file per repository (`repo.<owner>.<name>.json`) and one per machine-wide view (`throttle.json`, `activity.json`). The files are meant for a public gist (W02), so the builder publishes fields chosen by name, never a dump. `scheduler/site-schema.json` names every file, key and type. Every text goes through one filter that removes local paths and token-shaped strings. The data is the status site's back end, independent of the API of issue #46.

## Tests
- `scheduler/site.test.sh` (new, in the `Makefile`'s `test` target) runs `site.py build` against a runtime root and a `HOME` copied from `scheduler/testdata/site/`, with `--now` fixed, and checks the output. The fixture holds:
  - two repositories in the list. Each has a clone with `origin/main` and one open spec PR's branch, and a state folder. One repository is marked `public` and the other `private`.
  - a graph with a node in each state of change 2, and their markers, sessions, `open-prs.tsv` and `merged-prs.tsv`;
  - triage folders `issue/<N>/` in each state of change 4;
  - `usage.json` with more than 60 five-hour samples, and a `status.log` with more than 100 lines, including deploy events;
  - `deploy/previous` and `deploy/rejected`.

  Planted in it are a fake GitHub token and a fake Anthropic token, in a session log, an env file, a `QUESTION.md` first line, a `FAILED` first line, a status-log line and a fake `~/.config/noodlebot/token`. Absolute local paths are planted in the same places.

  The test checks the following:
  - each file's content against `scheduler/site-schema.json`: no key that the schema does not name, every type as named;
  - the states, the pending changes, the caps and cuts;
  - that neither fake token, nor the runtime root, nor `HOME`, nor any other absolute path appears anywhere in the output;
  - that the private repository has no file;
  - that two builds of the same state are byte-identical;
  - that the build writes nothing outside `--out` and calls no `gh` (a fake `gh` on `PATH` records any call).

## Changes
1. **The command.** `site.py build --data-root DIR --repos FILE --out DIR [--throttle LINE] [--now EPOCH]` reads the repositories in `FILE` (one `owner/name` per line, read as `loops.sh` reads `~/.config/noodlebot/repos`). It builds a file only for a repository whose `state/<name>/visibility` holds `public`. A missing or other value means the repository is left out. The build writes the files to `--out`, replacing its contents, as sorted-key JSON with no spaces, the same bytes for the same state. It uses only local files, never the network, and never reads `~/.config/noodlebot/` beyond the repository list. *W01-AC-1, W01-AC-7.*
2. **Repository file.** `repo.<owner>.<name>.json` holds the following:
   - the repository's name and whether its loop runs (its `loop.lock` held, read from `/proc/locks` as `loops.sh` reads it), and whether `~/STOP` or `~/STOP-<name>` exists;
   - each node of `state/<name>/graph.yaml`: its ID, name, track, deps, unlocks, summary, its size (from its spec's header row), and its criteria (ID and text, each cut to 600 characters), read from the clone's `origin/main:nodes/<ID>-<name>.md`. A node has no spec when that file is missing.
   - each node's state and its details. The state is the first of these that holds:
     - `merged`, with its PR number;
     - `running`, a live session, with its start time;
     - `failed`, with the first line of `FAILED`;
     - `question`, with the first line of `QUESTION.md` and the issue's URL where it is answered;
     - `answered`;
     - `waiting-pr`, with the spec PR's number;
     - `pr-open`, with the PR's number and mergeable state;
     - `held`, a node `ready.py` would start while the given throttle line says hold;
     - `ready`;
     - `waiting`, with the deps not yet merged.

     It also gives the starts used. `ready.py` is run over the files the loop cached at its last tick, as the loop runs it.

     The question's issue URL is that of the unit's home issue when `node/<ID>/issue` exists, otherwise that of the status issue (`report.json`).
   - the open PRs from `open-prs.tsv`: number, branch, mergeable state, whether a bot opened it;
   - each open `spec/*` PR's pending changes. Its graph is read from the clone's `origin/<branch>:docs/graph.yaml` and compared with main's. The result lists nodes added (with their full graph entry), nodes changed (the fields that differ) and nodes removed.

   *W01-AC-2, W01-AC-3.*
3. **Throttle file.** `throttle.json` holds the following:
   - each window of `state/usage.json`: utilization, reset time, status;
   - the time of the last reading;
   - the throttle line given by `--throttle` (`open: …` or `hold: <reason>`), split into held or open and its reason;
   - the five-hour history: the samples of `usage.json`, thinned evenly to at most 60 time and utilization pairs.

   *W01-AC-4.*
4. **Activity file.** `activity.json` holds the following:
   - the last 100 status-log events across all published repositories, newest first. Each event has its time, its repository and its text. The text has the loop's `open=[…] merged-prs=[…]; ` prefix removed and is cut to 300 characters.
   - each published repository's triage issues from `issue/<N>/`: the number, its URL, its state, the first of `running`, `failed` with the first line, `question` with the first line, `answered` that holds, else `idle` (no session and none of these markers: the triage finished or may start again) and its spec PR when `WAITING-PR` names one;
   - deploys: the live checkout's version (`state/<name>/version`), the recorded previous commit and the rejected commits, each cut to its first 12 characters before the text filter (a full commit hash is a run of 40 hex characters, which the filter replaces), and the last 10 deploy events (`deployed`, `not deployed`, `rolled back`).

   *W01-AC-5.*
5. **The text filter.** Every string that comes from a file, as opposed to a fixed key or enum, passes through one function. It replaces the runtime root, `HOME` and any absolute path (a `/`-led path of two or more parts that is not inside a URL) with `…`. It replaces token-shaped strings (`ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_`, `github_pat_`, `sk-ant-` and any run of 40 or more base64 or hex characters) with `[redacted]`. Session logs, `session.stderr`, environment files, prompts and anything under `~/.config/noodlebot/` other than the repository list are never read. *W01-AC-6.*
6. **The schema.** `scheduler/site-schema.json` has `version: 1` and, for each file, every key with its type. Every object of every file has exactly those keys, and the test checks them. W02's manifest names this version, and W03's front end refuses a different major version. *W01-AC-1.*

## Gate
- **W01-AC-1** — `site.py build` on the fixture writes, for each public repository in the list, `repo.<owner>.<name>.json`, plus `throttle.json` and `activity.json`, and nothing else. Every object in them has exactly the keys `scheduler/site-schema.json` names, of the named types. Two builds of the same state are byte-identical. *Verify:* `scheduler/site.test.sh`.
- **W01-AC-2** — Each node in a repository file has its ID, name, track, deps, unlocks, summary, size, criteria (ID and text cut to 600 characters), starts used, and the state of change 2 with its details. Each state's details are checked on a fixture node in that state. *Verify:* `scheduler/site.test.sh`.
- **W01-AC-3** — A repository file lists the open PRs with number, branch, mergeable state and bot author. For each open `spec/*` PR, it lists the nodes the PR adds (with their entry), changes (with the differing fields) and removes, compared with `origin/main`'s graph. *Verify:* `scheduler/site.test.sh`.
- **W01-AC-4** — `throttle.json` gives both windows' utilization, reset time and status, the last reading's time, held or open with the reason from `--throttle`, and at most 60 history points thinned evenly from the five-hour samples (the first and last kept). *Verify:* `scheduler/site.test.sh`.
- **W01-AC-5** — `activity.json` gives the last 100 status-log events of the published repositories, newest first, without the loop's `open=[…]` prefix and cut to 300 characters. It also gives the triage issues with their states and the deploy record (version, previous, rejected, the last 10 deploy events). *Verify:* `scheduler/site.test.sh`.
- **W01-AC-6** — The output contains none of the planted fake tokens, neither the runtime root nor `HOME`, and no absolute local path. URLs are kept intact. No session log, `session.stderr`, environment file or credential file is opened (checked with the files made unreadable, the build still succeeding). *Verify:* `scheduler/site.test.sh`.
- **W01-AC-7** — A repository whose `state/<name>/visibility` is missing or not `public` gets no file, and none of its events, PRs or triage issues appear in `activity.json`. The build writes nothing outside `--out` and makes no `gh` call or other network request. *Verify:* `scheduler/site.test.sh`.

## Risks
- The text filter is a pattern list. A secret of a shape it does not know, written into a status-log line, a `FAILED` or a `QUESTION.md` first line, would be published. The whitelist keeps every other source out, but these free texts come from sessions.
- Node states are computed here a second time, besides `ready.py` and the status issue, and the API of issue #46 (open spec PR #51, P01) computes them a third time. They can drift until one is built on another. Running `ready.py` itself, not a copy of its rules, keeps the main path shared.
- Criteria texts make the repository file grow with the graph. A graph of 50 nodes with 8 criteria each is about 200 KB, over the "tens of KB" the issue expects. If so, the cut length or a separate criteria file would be the change.
- Known gaps of the filter's patterns: a long base64url secret split by `-` or `_` is not one run; inside a URL only the token prefixes, the runtime root and `HOME` are replaced (another local path, or a long secret in a URL's path or query, stays, also where a path follows a URL after `,` or `;`); `~/…` paths are not `/`-led and stay.
- A full commit hash in a free text, such as the old and new commits of a `deployed` status-log line, is a run of 40 hex characters and is published as `[redacted]`; the line's version stays readable.
- The visibility record is written by W02 (at loop start). Before W02, every repository is left out unless the fixture writes it.
