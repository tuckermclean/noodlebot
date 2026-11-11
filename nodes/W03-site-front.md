# W03 — site-front

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | W02 | W04 | M |

**Owns:** `site/` (the page, its scripts and styles, the throttle, activity and repository views, `site/test/`, `site/site.test.sh`), its line in the `Makefile`'s `test` target, the `SITE_TESTS=required` setting in `.github/workflows/test.yml`, `.github/workflows/pages.yml`, the Pages part of the README's status-site section.
**Resolves:** #47

## Purpose
After this node the owner can open one GitHub Pages address from anywhere and see the loops' state about a minute behind. The front end is plain HTML, JavaScript modules and CSS under `site/`, with no build step and no dependencies. A workflow deploys it to Pages only when `site/` changes, so data updates never redeploy it. The page reads the gist that W02 keeps current through `api.github.com/gists/<id>`. It polls once a minute with `If-None-Match`, so an unchanged gist costs a 304 and no body. It pauses while the tab is hidden, backs off when GitHub limits it, and always shows how old its data is. Its views are the throttle, the activity across repositories, and a node table per repository. W04 adds the explorer to that table.

## Tests
- `site/site.test.sh` (new, in the `Makefile`'s `test` target) does two things:
  - It runs `node --test site/test/` when `node` is installed. Without it, it prints `site tests skipped: node not installed` and exits 0, or exits 1 when `SITE_TESTS=required`. `.github/workflows/test.yml` sets that, so CI always runs them.
  - It checks `.github/workflows/pages.yml` with Python and PyYAML: its triggers, permissions, the pinned actions, and that the artifact holds no `site/test/`.
- `site/test/` (new, `node:test`, no packages). Its data is built from W01's fixture by `site.py build`, with a manifest written as W02 writes it, so the views are tested against the publisher's real output. The tests cover:
  - the poller, with a fake `fetch`, a fake clock and a fake visibility state: the conditional requests, 304 handling, the pause while hidden, backoff, the hourly cap and the schema check;
  - the data age and the stale mark;
  - the throttle, activity and repository views, rendered to HTML strings from that data;
  - the page's routes.

## Changes
1. **The page.** `site/index.html` loads `site/app.js` (an ES module) and `site/style.css`. It works from any static host, and a local copy works when served over HTTP (for example `python3 -m http.server`) with `?gist=<id>`; browsers such as Chrome refuse module scripts from `file://`, so there the page says to serve it over HTTP. The gist ID comes from `?gist=<id>`, else from `site/config.json` (`{"gist": "<id>"}`, written by the Pages workflow). Without either, the page says how to set one and makes no request. Every view is a pure function from data to an HTML string, which `app.js` puts in the page, and every text from the data is HTML-escaped. Routes are URL hashes: `#/throttle`, `#/activity`, `#/repo/<owner>/<name>`, and by default the list of repositories with each one's loop state and counts of nodes by state. *W03-AC-1, W03-AC-5.*
2. **The poller.** `site/poll.js` requests `https://api.github.com/gists/<id>` without credentials, with `Accept: application/vnd.github+json`, and sends `If-None-Match` with the last `ETag`. A 304 keeps the current data. A 200 replaces it, reading each file's `content`, or its `raw_url` when the file is marked `truncated`. Data whose `manifest.json` names a different schema major version than the page's is not shown, and the page says it needs a newer front end. The poller follows these rules:
   - It polls every 60 seconds while the page is visible, and not at all while `document.hidden`. On becoming visible, it polls at once if 60 seconds have passed since the last request.
   - On 403 or 429 it waits for `Retry-After`, or, when `X-RateLimit-Remaining` is 0, until `X-RateLimit-Reset`. Otherwise it waits 2 minutes, doubling up to 30, and says so on the page.
   - It never makes more than 55 requests in any 60 minutes, whatever the visibility changes.

   *W03-AC-2, W03-AC-3.*
3. **The data's age.** Every view shows when the data last changed (the manifest's `updated`) and when the loop was last heard from (`seen`), both as "<n> minutes ago" and updated every few seconds without a request. The page is marked stale when `seen` is more than 20 minutes old or the last successful request is more than 5 minutes old. *W03-AC-4.*
4. **Views.**
   - **Throttle:** each window's utilization against its limit and its reset time; held or open, with the reason; the five-hour history as an inline SVG line with time on its axis.
   - **Activity:** the events newest first, filterable by repository; the open PRs of every repository with their mergeable state; the triage issues with their states and links; the deploys (version, previous commit, rejected commits, recent deploy events).
   - **Repository:** the loop state and `STOP` flags; a node table (ID, name, track, state with its details, deps, starts used), sortable by each column; the open PRs. Every PR, issue and node links to GitHub (`https://github.com/<owner>/<name>/pull/<n>`, `…/issues/<n>`, `…/blob/main/nodes/<ID>-<name>.md`).

   *W03-AC-5.*
5. **The deploy workflow.** `.github/workflows/pages.yml` runs on a push to `main` that changes `site/**` or the workflow itself, and on `workflow_dispatch`. It has `permissions: {contents: read, pages: write, id-token: write}` and one concurrency group, and pins every action to a full commit SHA, as `test.yml` does. It writes `site/config.json` from the repository variable `NOODLEBOT_GIST_ID`, failing with a clear message when that variable is unset. It uploads `site/` without `site/test/` and `site.test.sh` as the Pages artifact (`actions/upload-pages-artifact`) and deploys it (`actions/deploy-pages`). No branch is published to and nothing is committed. The README says to enable Pages with GitHub Actions as the source and to set `NOODLEBOT_GIST_ID`. *W03-AC-6.*

## Gate
- **W03-AC-1** — The page takes the gist ID from `?gist=`, else from `config.json`. With neither, it shows how to set one and makes no request. Every route (`#/`, `#/throttle`, `#/activity`, `#/repo/<owner>/<name>`, and an unknown one) renders. A text from the data holding `<script>` or `"` is shown escaped in every view. *Verify:* `site/site.test.sh` (`site/test/`).
- **W03-AC-2** — The poller sends `If-None-Match` with the last `ETag`, keeps its data on a 304, and replaces it on a 200, using `raw_url` for a truncated file. It makes no request while hidden, and polls at once on becoming visible after 60 seconds. It makes at most 55 requests in any 60 minutes under every sequence of visibility changes the test plays. It shows no data with a different schema major version. *Verify:* `site/site.test.sh`.
- **W03-AC-3** — After a 403 or 429, the next request waits for `Retry-After` when given, else until `X-RateLimit-Reset` when the remaining count is 0, else 2, 4, 8 … up to 30 minutes. The page says it is backing off and until when. A success restores the 60-second poll. *Verify:* `site/site.test.sh`.
- **W03-AC-4** — Every view shows the manifest's `updated` and `seen` as ages, and the page is marked stale exactly when `seen` is over 20 minutes old or the last successful request over 5 minutes old (fake clock). *Verify:* `site/site.test.sh`.
- **W03-AC-5** — From the fixture data, the throttle view shows both windows, held or open with the reason, and the history line. The activity view shows the events newest first (and only one repository's when filtered), the open PRs with mergeable state, the triage issues and the deploys. The repository view shows every node with its state and details, sorted by any column, and the open PRs. Every PR, issue and node link points at the URL change 4 gives. *Verify:* `site/site.test.sh`.
- **W03-AC-6** — `pages.yml` triggers only on pushes to `main` changing `site/**` or itself, and on `workflow_dispatch`. It has exactly the permissions of change 5, pins every `uses:` to a 40-character SHA, writes `config.json` from `vars.NOODLEBOT_GIST_ID` (failing when it is empty), and uploads an artifact without `site/test/`. `site/site.test.sh` exits 1 when `node` is missing and `SITE_TESTS=required`, and 0 with the skip line otherwise. `test.yml` sets `SITE_TESTS=required`. *Verify:* `site/site.test.sh`, and the PR's CI run showing the `node` tests ran.

## Risks
- Unverified until merged and set up: the first Pages deploy and the page reading the owner's real gist in a browser. The workflow runs only on `main`, and the `github-pages` environment allows only `main` by default. The owner should record the first deploy's run and open the page once.
- The node's PR adds `.github/workflows/pages.yml`, and pushing it needs the GitHub App's `workflows` permission. Without it, the session's push fails, and the owner must add that permission or push the file.
- Unauthenticated `api.github.com` allows 60 requests an hour per IP, shared by every tab and every other unauthenticated client behind that IP. Several open tabs, or a shared network, reach the limit sooner, and the backoff then shows stale data.
- Whether a 304 counts against the unauthenticated limit is GitHub's behaviour, not tested here. The cap of 55 requests an hour holds either way.
- Node.js is a new test tool. A machine without it (the live checkout's deploy runs `make test`) skips the front-end tests, so only CI holds them.
