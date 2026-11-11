# W05 — site-links

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | U02, W04 | none | M |

**Owns:** in `scheduler/report.py`: the status-site address (`--site`), the site links it builds and their place in the log issue's body, its morning overview, its closing summary, its event comments and the units' home issues; in `scheduler/loop.sh`: reading `~/.config/noodlebot/site`, the condition for site links, passing `--site` to `report.py` and the site line rendered into session prompts; the site line of each session template `scheduler/unattended*.md`; in `site/`: what the repository view shows for a node link to a node it does not have, and its tests in `site/test/`; the site-address part of the README's status-site section; their cases in `scheduler/report.test.sh` and `scheduler/loop.test.sh`.
**Resolves:** #83

## Purpose
After this node, what the bot writes on GitHub links to the status site wherever the site has a view of the thing named. Node IDs link to the node in the repository's explorer. The log issue also links the repository's page, the throttle and the activity view. Sessions are told to link nodes the same way in their PR bodies and comments. Links appear only when the site is set up and shows the repository: the owner has given its address, the loop publishes it, and the repository is public. Otherwise every text stays as it is today.

## Tests
- `scheduler/report.test.sh` (extended), against the fake `gh api` with a graph fixture:
  - with `--site`: the log issue's body, its overview, its closing summary and its event comments; a Build issue and a node unit's milestones on an existing issue; a triage unit's milestones; a question copied from a QUESTION.md that names a node, posted unchanged;
  - without `--site`: the same runs post the same texts as before this node.
- `scheduler/loop.test.sh` (extended): with the fake `claude` recording its prompt and the arguments `report.py` is run with recorded, the cases for links on and links off (each condition of change 1 in turn). A node, triage, follow-up and update prompt is checked in each case.
- `site/test/` (extended, `node:test`): a repository route with `?node=` naming a node of the graph, a ghost of an open spec PR, and an ID in neither; the hash `buildHash` gives for a node.

## Changes
1. **The site's address, and when links are on.** The owner writes the site's address in `~/.config/noodlebot/site` (one line, for example `https://<owner>.github.io/noodlebot/`). The loop reads it at each tick. Links are on for a repository when all of these hold:
   - the file's first line is an `https://` URL with no whitespace, `(`, `)`, `<`, `>` or `"`;
   - the loop publishes the status site (W02's gist and gist token are present and `SCHED_SITE` is not 0);
   - the repository's `state/<name>/visibility` holds `public`, so the site has its data.

   Then the loop passes `--site <address>` to `report.py`, without any trailing `/`, and renders the site line into session prompts (change 5). Otherwise it passes neither. A file that holds no valid address is said once in the status log (`status site links off: <reason>`). The README's status-site section says how to set the address and when links appear. *W05-AC-1.*
2. **The links.** With `--site <s>` for repository `<o>/<n>`, `report.py` builds these links:
   - the repository: `<s>/#/repo/<o>/<n>`;
   - a node: `<s>/#/repo/<o>/<n>?node=<ID>`, the hash W04's `buildHash` gives for a selected node;
   - the throttle: `<s>/#/throttle`;
   - the repository's activity: `<s>/#/activity?repo=<o>/<n>`.

   A **node mention** is an ID of a node in the repository's graph, written as a whole word in the loop's own text, outside a code span, a link or a URL. It becomes `[<ID>](<node link>)`. Text the loop copies from a session's files (a QUESTION.md, a session's closing summary, its narration) is posted as it is. *W05-AC-2, W05-AC-3.*
3. **The log issue.** Its body has a line under the title: `**Status site:** [<o>/<n>](<repository link>) · [throttle](<throttle link>) · [activity](<activity link>)`. Every node mention is linked in its body (the running sessions' headings and the waiting items), in its morning overview (waiting items and the nodes ready next), in its closing summary (the FAILED units) and in its event comments. *W05-AC-2.*
4. **The units' home issues.** A Build issue's body has a line `On the status site: [<ID> <name>](<node link>)`. A node unit's first milestone on an existing issue (its first Resolves issue) has the same line. A triage unit's first milestone has `On the status site: [triage issues of <o>/<n>](<activity link>)`. Every node mention in a milestone's stage line and the loop's own text in it is linked. *W05-AC-3.*
5. **Sessions.** Each session template `scheduler/unattended*.md` gets a placeholder for the site line. While links are on, the loop renders it as one line in every node, triage, follow-up and update prompt: the site's address, and that a node of this repository named in a PR body or a GitHub comment links its ID to `<s>/#/repo/<o>/<n>?node=<ID>`. While links are off it renders to nothing, leaving no blank line and no `@…@` placeholder. *W05-AC-5.*
6. **A link to a node the site does not have.** The node may be added by an open spec PR, or not yet published. The repository view of `#/repo/<o>/<n>?node=<ID>` then works as follows:
   - when `<ID>` is a ghost node added by an open spec PR, the view selects it and its details show the PR;
   - when `<ID>` is in neither the graph nor the ghosts, the view shows a note above the explorer, `No node <ID> in <o>/<n>'s published graph yet`, and selects nothing;
   - a node of the graph is selected as before.

   *W05-AC-6.*

## Gate
- **W05-AC-1** — The loop passes `--site <address>` to `report.py` and renders the site line into session prompts exactly when `~/.config/noodlebot/site` holds a valid `https://` address, the loop publishes the status site, and the repository's visibility record is `public`. A trailing `/` of the address is dropped. With any one of these false it passes no `--site` and renders no site line. An invalid address is said once in the status log. The README's status-site section says how to set the address. *Verify:* `scheduler/loop.test.sh`, `README.md`.
- **W05-AC-2** — With `--site`, the log issue's body has the status-site line linking the repository, throttle and activity views as change 2 gives them. Every node mention is a link to its node in the body, the morning overview, the closing summary and every event comment. No ID inside a code span or an existing link is changed. *Verify:* `scheduler/report.test.sh`.
- **W05-AC-3** — With `--site`, a Build issue's body, and a node unit's first milestone on an existing issue, link the node's view. A triage unit's first milestone links the repository's activity view. Every node mention in a milestone's own text is linked, and a QUESTION.md or closing summary copied into a milestone is posted byte for byte as written. *Verify:* `scheduler/report.test.sh`.
- **W05-AC-4** — Without `--site`, every body and comment `report.py` posts is byte for byte what it posts before this node, and every existing case of `scheduler/report.test.sh` passes unchanged. *Verify:* `scheduler/report.test.sh`.
- **W05-AC-5** — While links are on, every node, triage, follow-up and update prompt the loop renders has exactly one site line, naming the address and the node link form for the loop's repository. While links are off, the rendered prompt has no site line, no blank line where the placeholder was, and no unrendered `@…@` placeholder. *Verify:* `scheduler/loop.test.sh`.
- **W05-AC-6** — `buildHash('<o>/<n>', {node: '<ID>'})` gives `#/repo/<o>/<n>?node=<ID>`, the form `report.py` writes. From the fixture data, `?node=` naming a graph node selects it. Naming a ghost added by the fixture's open spec PR selects the ghost, and its details link that PR. Naming an ID in neither shows the note of change 6 with the ID escaped, and selects nothing. *Verify:* `site/site.test.sh`.

## Risks
- The site is about a minute behind. A link posted right after a node is added can open before the site has the node, which is why change 6 explains it instead of showing nothing.
- A private repository gets no links: W01 publishes only public repositories, and a link to its data would open an empty page. A repository whose visibility is `unknown` gets none until the loop learns it.
- Sessions link nodes because their prompt says so, and nothing checks it. A PR body without the links is still a valid PR.
- The address is the owner's to set. A wrong but well-formed address gives dead links, and nothing here fetches the page to check it.
- Linked IDs make the log issue's body longer. The body's size limit (65,536 characters) is far off for today's graphs, but the explorer links add about 60 characters per mention.
