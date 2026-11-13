# Forges

`scheduler/forge.py` is the one interface the scheduler's core uses to reach the code forge (G04). A backend is a class
`Backend(path)` with a method per operation, named `<family>_<op>` with `-` as `_`; GitHub's is `forges/github.py`
(the `gh` CLI), the fake forge's is `testdata/forge/fake.py` (a folder of JSON files). A forge is named `owner/name` or
`github:owner/name` (GitHub) or `fake:<state folder>`; any other `<x>:...` is an unknown forge (exit 2).

Python: `f = forge.open(spec)`, then `f.<family>_<op>(**kwargs)`. CLI: `python3 -I scheduler/forge.py [--repo SPEC]
<family> <op> [--opt value ...]` prints one JSON document. Exit 1: the call failed (one line on stderr, nothing on
stdout, never an empty result); 2: usage error or unknown forge; 3: the forge lacks a capability
(`forge <name> lacks <capability>`). Capabilities: `visibility` (repo visibility), `pin` (issue pin, issue unpin),
`resolve_threads` (pr resolve-thread), `site` (site publish); every other operation is always available, and the core
refuses an operation whose capability is off before the backend is called.

Credentials (GitHub): a `GH_TOKEN` in the caller's environment is used as given; else the token script named by
`NOODLEBOT_FORGE_TOKEN_SCRIPT` runs once per process and repository (`<script> <owner/name>`), the token kept in memory;
else no token (`gh` uses its own login). The token reaches `gh` and `git` only through the child's environment, never an
argument, output, log, file or Git configuration.

## Inventory

Every place the core (everything under `scheduler/` and `plugin/` but tests, test data and these backends) reaches the
forge or names a forge URL, at this node's base (G02 and G03 merged), with the interface operation that replaces it.

| Call site | Operation | Reads |
|---|---|---|
| `scheduler/loop.sh:123` | `repo default-branch` | no call today (`git clone` on this line checks out the default branch itself); an interface operation sessions use to name the branch, listed against the clone it accompanies |
| `scheduler/loop.sh:123` | `repo clone-url` | the repository's clone URL (git clone) |
| `scheduler/loop.sh:211` | `repo visibility` | `private` of the repository (vis_ask) |
| `scheduler/loop.sh:1374` | `pr list` | merged PRs: number, head branch (merged-prs.tsv) |
| `scheduler/loop.sh:1376` | `pr list` | open PRs: number, head branch, head SHA, author is a bot, mergeable (open-prs.tsv) |
| `scheduler/loop.sh:1380` | `pr list` | closed PRs: number, head branch, closed time, merged or not (closed-prs.tsv) |
| `scheduler/loop.sh:992` | `site publish` | the site's files, sent to the gist (site.py publish, with the gist token) |
| `scheduler/deploy.sh:218` | `ci runs` | the CI workflow's push runs for a commit and branch: status, conclusion, id |
| `scheduler/status.sh:97` | `pr list` | open PRs but dependabot's: number, title |
| `plugin/skills/triage/nodes.py:62` | `pr list` | open PRs: number, head branch (spec PRs) |
| `plugin/skills/triage/nodes.py:111` | `pr list` | all PRs: number, state, head branch (node PR state) |
| `scheduler/report.py:673` | `issue list` | issues with the status label, by state |
| `scheduler/report.py:687` | `issue view` | an issue's state |
| `scheduler/report.py:698` | `issue list` | open issues with the status label |
| `scheduler/report.py:709` | `label ensure` | the status label |
| `scheduler/report.py:714` | `issue create` | the day's log issue |
| `scheduler/report.py:740` | `issue view` | an issue's node id (for pin) |
| `scheduler/report.py:741` | `issue pin` | pin the new log issue (GraphQL pinIssue) |
| `scheduler/report.py:741` | `issue unpin` | unpin the replaced log issue (GraphQL unpinIssue, the same line) |
| `scheduler/report.py:787` | `issue close` | the rolled-over log issue |
| `scheduler/report.py:844` | `issue list` | open issues with the status label |
| `scheduler/report.py:857` | `issue close` | a stale log issue |
| `scheduler/report.py:893` | `issue comments` | an issue's comments since a time |
| `scheduler/report.py:1019` | `issue comment` | a comment on an issue |
| `scheduler/report.py:1061` | `label ensure` | the unit label |
| `scheduler/report.py:1067` | `issue list` | open issues with the unit label |
| `scheduler/report.py:1073` | `issue create` | a unit issue |
| `scheduler/report.py:1255` | `issue comments` | an issue's comments |
| `scheduler/report.py:1349` | `issue react` | a +1 reaction on an answered comment |
| `scheduler/report.py:1361` | `issue comments` | an issue's comments since a time |
| `scheduler/report.py:1399` | `issue react` | a +1 reaction on a comment |
| `scheduler/report.py:1411` | `issue comments` | an issue's comments since a time |
| `scheduler/report.py:1592` | `issue view` | an issue's state |
| `scheduler/report.py:1596` | `issue reopen` | reopen an issue |
| `scheduler/report.py:1628` | `issue view` | an issue's state |
| `scheduler/report.py:1638` | `issue close` | close an issue |
| `scheduler/report.py:1710` | `issue comments` | a PR's conversation comments, page by page |
| `scheduler/report.py:1756` | `commit checks` | the check runs of a commit: name, status, conclusion |
| `scheduler/report.py:1841` | `pr list` | open PRs (REST list) |
| `scheduler/report.py:1865` | `issue comments` | an issue's comments |
| `scheduler/report.py:1920` | `issue edit` | an issue's body |
| `scheduler/issues.py:29` | `issue events` | an issue's events: who labelled it |
| `scheduler/issues.py:69` | `issue list` | open issues with the noodlebot label, oldest first |
| `scheduler/issues.py:93` | `label ensure` | the done label |
| `scheduler/issues.py:98` | `label add` | the done label on an issue |
| `scheduler/issues.py:100` | `label remove` | the noodlebot label from an issue |
| `scheduler/labels.py:42` | `label list` | the repository's labels, page by page |
| `scheduler/labels.py:59` | `label ensure` | the noodlebot labels |
| `scheduler/feedback.py:120` | `pr comments` | a PR's conversation comments (every page) |
| `scheduler/feedback.py:120` | `pr line-comments` | a PR's line comments (every page) |
| `scheduler/feedback.py:120` | `pr reviews` | a PR's reviews (every page) |
| `scheduler/site.py:362` | `repo url` | an issue's web URL |
| `scheduler/site.py:499` | `repo url` | an issue's web URL |
| `scheduler/site.py:612` | `site publish` | the gist PATCH with the site's files (gh_patch) |
| `scheduler/api.py:423` | `repo url` | an issue's web URL (a pure function, no call) |
| `scheduler/api.py:731` | `repo url` | an issue's web URL (a pure function, no call) |
| `scheduler/nbctl.py:233` | `repo url` | an issue's web URL (a pure function, no call) |
| `scheduler/status.sh:22` | `repo url` | an issue's web URL |
| `scheduler/version.sh:24` | `repo url` | a commit's web URL (from the remote URL) |

## Credentials

Where the core fetches a token or runs a helper with one today; each becomes the interface's one rule (a caller's
`GH_TOKEN`, else the token script once per process, else none). The loop stops holding a tick token.

- Token script calls: `scheduler/loop.sh:218` (label step), `scheduler/loop.sh:1370` (the tick's PR lists),
  `scheduler/deploy.sh:214` (D07's CI-run lookup), `scheduler/status.sh:97` (open PRs).
- Helpers run with `GH_TOKEN`: `scheduler/loop.sh:220` (labels.py), `scheduler/loop.sh:411` and `scheduler/loop.sh:1427`
  (issues.py), `scheduler/loop.sh:972` (report.py), `scheduler/loop.sh:1626` (`fb_launch`: feedback.py), and
  `scheduler/loop.sh:992` (site.py publish with the gist token, the one `GH_TOKEN` a caller puts in the environment
  on purpose).

## GitHub argv forms

The GitHub backend keeps each call site's `gh` argv as it was, choosing among forms by the arguments of `pr list`; the
fields below are the arguments (not result keys: callers read the guaranteed keys only, `author`'s `is_bot` among them).

- `state=merged`, `fields=[number, head]`: `gh pr list --state merged --json number,headRefName -q ...` (loop.sh).
- `state=open`, `fields=[number, head, head_sha, author_is_bot, mergeable]`: `gh pr list --state open --json
  number,headRefName,headRefOid,author,mergeable -q ...` (loop.sh). `author_is_bot` is a field of this form only.
- `state=closed`, `fields=[number, head, closed_at, merged]`: `gh pr list --state closed --json
  number,headRefName,closedAt,mergedAt -q ...` (loop.sh). `merged` is a field of this form only; it gives `state`.
- `state=open`, `fields=[number, title]`: `gh pr list --state open --json number,title,author -q ...` (status.sh).
- other `fields` without `author` (nodes.py): `gh pr list --json` of the matching gh fields, no `-q`.
- no `fields`, or `author` among them (report.py): `gh api -X GET repos/R/pulls?state=S&per_page=100` (further pages
  `&page=P`); `author_association` gives `is_owner`. `merged` and `closed` map to REST `closed`; `merged` keeps the pulls
  with a `merged_at`. `gh pr list` has no `authorAssociation` field, so it is never asked for.
- `limit` omitted (`None`): no `--limit` for `gh pr list`, every page for REST.

## Operations

One row per operation of `forge.OPERATIONS`: the call each forge makes, linked to its API documentation. GitLab, Gitea
and Forgejo are on paper only (no backend until a node adds one); nothing here runs against them. GitLab calls a PR a
merge request (`iid`), Gitea and Forgejo share issue comments with pulls and mark merged pulls with a `merged` flag.

| Operation | GitHub | GitLab | Gitea | Forgejo |
|---|---|---|---|---|
| `repo visibility` | [`GET /repos/R` `.private`](https://docs.github.com/en/rest/repos/repos#get-a-repository) | [`GET /projects/:id` `.visibility`](https://docs.gitlab.com/ee/api/projects.html#get-single-project) | [`GET /repos/{o}/{r}` `.private`](https://docs.gitea.com/api/1.22/#tag/repository/operation/repoGet) | [`GET /repos/{o}/{r}` `.private`](https://codeberg.org/api/swagger#/repository/repoGet) |
| `repo default-branch` | [`GET /repos/R` `.default_branch`](https://docs.github.com/en/rest/repos/repos#get-a-repository) | [`GET /projects/:id` `.default_branch`](https://docs.gitlab.com/ee/api/projects.html#get-single-project) | [`GET /repos/{o}/{r}` `.default_branch`](https://docs.gitea.com/api/1.22/#tag/repository/operation/repoGet) | [`GET /repos/{o}/{r}` `.default_branch`](https://codeberg.org/api/swagger#/repository/repoGet) |
| `repo clone-url` | [`https://github.com/R` (built, no call)](https://docs.github.com/en/rest/repos/repos#get-a-repository) | [`http_url_to_repo` of the project](https://docs.gitlab.com/ee/api/projects.html#get-single-project) | [`clone_url` of the repository](https://docs.gitea.com/api/1.22/#tag/repository/operation/repoGet) | [`clone_url` of the repository](https://codeberg.org/api/swagger#/repository/repoGet) |
| `repo url` | [`html_url` forms `/issues/N`, `/pull/N`, `/commit/SHA` (built, no call)](https://docs.github.com/en/rest/repos/repos#get-a-repository) | [`web_url` forms `/-/issues/N`, `/-/merge_requests/N`, `/-/commit/SHA`](https://docs.gitlab.com/ee/api/projects.html#get-single-project) | [`html_url` forms `/issues/N`, `/pulls/N`, `/commit/SHA`](https://docs.gitea.com/api/1.22/#tag/repository/operation/repoGet) | [`html_url` forms `/issues/N`, `/pulls/N`, `/commit/SHA`](https://codeberg.org/api/swagger#/repository/repoGet) |
| `repo identities` | [owner from `owner/name`; bots carry `type: Bot`](https://docs.github.com/en/rest/users/users#get-a-user) | [`GET /user` of the token; `namespace.path`](https://docs.gitlab.com/ee/api/users.html#for-normal-users) | [`GET /user` of the token; `owner.login`](https://docs.gitea.com/api/1.22/#tag/user/operation/userGetCurrent) | [`GET /user` of the token; `owner.login`](https://codeberg.org/api/swagger#/user/userGetCurrent) |
| `pr list` | [`GET /repos/R/pulls?state=` (or `gh pr list --json`)](https://docs.github.com/en/rest/pulls/pulls#list-pull-requests) | [`GET /projects/:id/merge_requests?state=opened, merged or closed`](https://docs.gitlab.com/ee/api/merge_requests.html#list-project-merge-requests) | [`GET /repos/{o}/{r}/pulls?state=` (`merged` flag on closed)](https://docs.gitea.com/api/1.22/#tag/repository/operation/repoListPullRequests) | [`GET /repos/{o}/{r}/pulls?state=` (`merged` flag on closed)](https://codeberg.org/api/swagger#/repository/repoListPullRequests) |
| `pr view` | [`GET /repos/R/pulls/N`](https://docs.github.com/en/rest/pulls/pulls#get-a-pull-request) | [`GET /projects/:id/merge_requests/:iid`](https://docs.gitlab.com/ee/api/merge_requests.html#get-single-mr) | [`GET /repos/{o}/{r}/pulls/{index}`](https://docs.gitea.com/api/1.22/#tag/repository/operation/repoGetPullRequest) | [`GET /repos/{o}/{r}/pulls/{index}`](https://codeberg.org/api/swagger#/repository/repoGetPullRequest) |
| `pr create` | [`POST /repos/R/pulls`](https://docs.github.com/en/rest/pulls/pulls#create-a-pull-request) | [`POST /projects/:id/merge_requests`](https://docs.gitlab.com/ee/api/merge_requests.html#create-mr) | [`POST /repos/{o}/{r}/pulls`](https://docs.gitea.com/api/1.22/#tag/repository/operation/repoCreatePullRequest) | [`POST /repos/{o}/{r}/pulls`](https://codeberg.org/api/swagger#/repository/repoCreatePullRequest) |
| `pr edit` | [`PATCH /repos/R/pulls/N`](https://docs.github.com/en/rest/pulls/pulls#update-a-pull-request) | [`PUT /projects/:id/merge_requests/:iid`](https://docs.gitlab.com/ee/api/merge_requests.html#update-mr) | [`PATCH /repos/{o}/{r}/pulls/{index}`](https://docs.gitea.com/api/1.22/#tag/repository/operation/repoEditPullRequest) | [`PATCH /repos/{o}/{r}/pulls/{index}`](https://codeberg.org/api/swagger#/repository/repoEditPullRequest) |
| `pr comment` | [`POST /repos/R/issues/N/comments`](https://docs.github.com/en/rest/issues/comments#create-an-issue-comment) | [`POST /projects/:id/merge_requests/:iid/notes`](https://docs.gitlab.com/ee/api/notes.html#create-new-merge-request-note) | [`POST /repos/{o}/{r}/issues/{index}/comments` (pulls share issue comments)](https://docs.gitea.com/api/1.22/#tag/issue/operation/issueCreateComment) | [`POST /repos/{o}/{r}/issues/{index}/comments` (pulls share issue comments)](https://codeberg.org/api/swagger#/issue/issueCreateComment) |
| `pr comments` | [`GET /repos/R/issues/N/comments` (paginated)](https://docs.github.com/en/rest/issues/comments#list-issue-comments) | [`GET /projects/:id/merge_requests/:iid/notes`](https://docs.gitlab.com/ee/api/notes.html#list-all-merge-request-notes) | [`GET /repos/{o}/{r}/issues/{index}/comments`](https://docs.gitea.com/api/1.22/#tag/issue/operation/issueGetComments) | [`GET /repos/{o}/{r}/issues/{index}/comments`](https://codeberg.org/api/swagger#/issue/issueGetComments) |
| `pr reviews` | [`GET /repos/R/pulls/N/reviews` (paginated)](https://docs.github.com/en/rest/pulls/reviews#list-reviews-for-a-pull-request) | [`GET /projects/:id/merge_requests/:iid/approvals` and review notes](https://docs.gitlab.com/ee/api/merge_request_approvals.html#get-configuration-1) | [`GET /repos/{o}/{r}/pulls/{index}/reviews`](https://docs.gitea.com/api/1.22/#tag/repository/operation/repoListPullReviews) | [`GET /repos/{o}/{r}/pulls/{index}/reviews`](https://codeberg.org/api/swagger#/repository/repoListPullReviews) |
| `pr line-comments` | [`GET /repos/R/pulls/N/comments` (paginated)](https://docs.github.com/en/rest/pulls/comments#list-review-comments-on-a-pull-request) | [`GET /projects/:id/merge_requests/:iid/discussions` (diff notes)](https://docs.gitlab.com/ee/api/discussions.html#list-project-merge-request-discussion-items) | [`GET /repos/{o}/{r}/pulls/{index}/reviews/{id}/comments`](https://docs.gitea.com/api/1.22/#tag/repository/operation/repoGetPullReviewComments) | [`GET /repos/{o}/{r}/pulls/{index}/reviews/{id}/comments`](https://codeberg.org/api/swagger#/repository/repoGetPullReviewComments) |
| `pr reply` | [`POST /repos/R/pulls/N/comments/ID/replies`](https://docs.github.com/en/rest/pulls/comments#create-a-reply-for-a-review-comment) | [`POST /projects/:id/merge_requests/:iid/discussions/:id/notes`](https://docs.gitlab.com/ee/api/discussions.html#add-note-to-existing-merge-request-thread) | [`POST /repos/{o}/{r}/pulls/{index}/reviews` with a comment on the same line](https://docs.gitea.com/api/1.22/#tag/repository/operation/repoCreatePullReview) | [`POST /repos/{o}/{r}/pulls/{index}/reviews` with a comment on the same line](https://codeberg.org/api/swagger#/repository/repoCreatePullReview) |
| `pr resolve-thread` | [GraphQL `resolveReviewThread`](https://docs.github.com/en/graphql/reference/mutations#resolvereviewthread) | [`PUT /projects/:id/merge_requests/:iid/discussions/:id` `resolved=true`](https://docs.gitlab.com/ee/api/discussions.html#resolve-a-merge-request-thread) | none: capability off (the API has no endpoint to resolve a review thread; [API](https://docs.gitea.com/api/next/)) | none: capability off (the API has no endpoint to resolve a review thread; [API](https://codeberg.org/api/swagger)) |
| `issue list` | [`GET /repos/R/issues?labels=&state=` (`per_page`, `sort`, `direction`)](https://docs.github.com/en/rest/issues/issues#list-repository-issues) | [`GET /projects/:id/issues?labels=&state=opened or closed`](https://docs.gitlab.com/ee/api/issues.html#list-project-issues) | [`GET /repos/{o}/{r}/issues?labels=&state=&type=issues`](https://docs.gitea.com/api/1.22/#tag/issue/operation/issueListIssues) | [`GET /repos/{o}/{r}/issues?labels=&state=&type=issues`](https://codeberg.org/api/swagger#/issue/issueListIssues) |
| `issue view` | [`GET /repos/R/issues/N`](https://docs.github.com/en/rest/issues/issues#get-an-issue) | [`GET /projects/:id/issues/:iid`](https://docs.gitlab.com/ee/api/issues.html#single-project-issue) | [`GET /repos/{o}/{r}/issues/{index}`](https://docs.gitea.com/api/1.22/#tag/issue/operation/issueGetIssue) | [`GET /repos/{o}/{r}/issues/{index}`](https://codeberg.org/api/swagger#/issue/issueGetIssue) |
| `issue comments` | [`GET /repos/R/issues/N/comments?per_page=&page=&since=`](https://docs.github.com/en/rest/issues/comments#list-issue-comments) | [`GET /projects/:id/issues/:iid/notes`](https://docs.gitlab.com/ee/api/notes.html#list-project-issue-notes) | [`GET /repos/{o}/{r}/issues/{index}/comments?since=`](https://docs.gitea.com/api/1.22/#tag/issue/operation/issueGetComments) | [`GET /repos/{o}/{r}/issues/{index}/comments?since=`](https://codeberg.org/api/swagger#/issue/issueGetComments) |
| `issue create` | [`POST /repos/R/issues`](https://docs.github.com/en/rest/issues/issues#create-an-issue) | [`POST /projects/:id/issues`](https://docs.gitlab.com/ee/api/issues.html#new-issue) | [`POST /repos/{o}/{r}/issues`](https://docs.gitea.com/api/1.22/#tag/issue/operation/issueCreateIssue) | [`POST /repos/{o}/{r}/issues`](https://codeberg.org/api/swagger#/issue/issueCreateIssue) |
| `issue edit` | [`PATCH /repos/R/issues/N`](https://docs.github.com/en/rest/issues/issues#update-an-issue) | [`PUT /projects/:id/issues/:iid`](https://docs.gitlab.com/ee/api/issues.html#edit-an-issue) | [`PATCH /repos/{o}/{r}/issues/{index}`](https://docs.gitea.com/api/1.22/#tag/issue/operation/issueEditIssue) | [`PATCH /repos/{o}/{r}/issues/{index}`](https://codeberg.org/api/swagger#/issue/issueEditIssue) |
| `issue comment` | [`POST /repos/R/issues/N/comments`](https://docs.github.com/en/rest/issues/comments#create-an-issue-comment) | [`POST /projects/:id/issues/:iid/notes`](https://docs.gitlab.com/ee/api/notes.html#create-new-issue-note) | [`POST /repos/{o}/{r}/issues/{index}/comments`](https://docs.gitea.com/api/1.22/#tag/issue/operation/issueCreateComment) | [`POST /repos/{o}/{r}/issues/{index}/comments`](https://codeberg.org/api/swagger#/issue/issueCreateComment) |
| `issue close` | [`PATCH /repos/R/issues/N` `state=closed`](https://docs.github.com/en/rest/issues/issues#update-an-issue) | [`PUT /projects/:id/issues/:iid` `state_event=close`](https://docs.gitlab.com/ee/api/issues.html#edit-an-issue) | [`PATCH /repos/{o}/{r}/issues/{index}` `state=closed`](https://docs.gitea.com/api/1.22/#tag/issue/operation/issueEditIssue) | [`PATCH /repos/{o}/{r}/issues/{index}` `state=closed`](https://codeberg.org/api/swagger#/issue/issueEditIssue) |
| `issue reopen` | [`PATCH /repos/R/issues/N` `state=open`](https://docs.github.com/en/rest/issues/issues#update-an-issue) | [`PUT /projects/:id/issues/:iid` `state_event=reopen`](https://docs.gitlab.com/ee/api/issues.html#edit-an-issue) | [`PATCH /repos/{o}/{r}/issues/{index}` `state=open`](https://docs.gitea.com/api/1.22/#tag/issue/operation/issueEditIssue) | [`PATCH /repos/{o}/{r}/issues/{index}` `state=open`](https://codeberg.org/api/swagger#/issue/issueEditIssue) |
| `issue pin` | [GraphQL `pinIssue` (node id from `GET /repos/R/issues/N`)](https://docs.github.com/en/graphql/reference/mutations#pinissue) | none: capability off | [`POST /repos/{o}/{r}/issues/{index}/pin` (Gitea 1.21+; Forgejo)](https://docs.gitea.com/api/1.22/#tag/issue/operation/pinIssue) | [`POST /repos/{o}/{r}/issues/{index}/pin` (Gitea 1.21+; Forgejo)](https://codeberg.org/api/swagger#/issue/pinIssue) |
| `issue unpin` | [GraphQL `unpinIssue`](https://docs.github.com/en/graphql/reference/mutations#unpinissue) | none: capability off | [`DELETE /repos/{o}/{r}/issues/{index}/pin`](https://docs.gitea.com/api/1.22/#tag/issue/operation/unpinIssue) | [`DELETE /repos/{o}/{r}/issues/{index}/pin`](https://codeberg.org/api/swagger#/issue/unpinIssue) |
| `issue events` | [`GET /repos/R/issues/N/events`](https://docs.github.com/en/rest/issues/events#list-issue-events) | [`GET /projects/:id/issues/:iid/resource_label_events`](https://docs.gitlab.com/ee/api/resource_label_events.html#list-project-issue-label-events) | [`GET /repos/{o}/{r}/issues/{index}/timeline` (label events)](https://docs.gitea.com/api/1.22/#tag/issue/operation/issueGetCommentsAndTimeline) | [`GET /repos/{o}/{r}/issues/{index}/timeline` (label events)](https://codeberg.org/api/swagger#/issue/issueGetCommentsAndTimeline) |
| `issue react` | [`POST /repos/R/issues/comments/ID/reactions` `content=+1`](https://docs.github.com/en/rest/reactions/reactions#create-reaction-for-an-issue-comment) | [`POST /projects/:id/issues/:iid/notes/:id/award_emoji` `name=thumbsup`](https://docs.gitlab.com/ee/api/emoji_reactions.html#add-a-new-emoji-reaction) | [`POST /repos/{o}/{r}/issues/comments/{id}/reactions` `content=+1`](https://docs.gitea.com/api/1.22/#tag/issue/operation/issuePostCommentReaction) | [`POST /repos/{o}/{r}/issues/comments/{id}/reactions` `content=+1`](https://codeberg.org/api/swagger#/issue/issuePostCommentReaction) |
| `label list` | [`GET /repos/R/labels?per_page=100&page=`](https://docs.github.com/en/rest/issues/labels#list-labels-for-a-repository) | [`GET /projects/:id/labels`](https://docs.gitlab.com/ee/api/labels.html#list-labels) | [`GET /repos/{o}/{r}/labels`](https://docs.gitea.com/api/1.22/#tag/issue/operation/issueListLabels) | [`GET /repos/{o}/{r}/labels`](https://codeberg.org/api/swagger#/issue/issueListLabels) |
| `label ensure` | [`POST /repos/R/labels` (a 422 `already_exists` = present; any other 422 fails)](https://docs.github.com/en/rest/issues/labels#create-a-label) | [`POST /projects/:id/labels` (an existing name is refused)](https://docs.gitlab.com/ee/api/labels.html#create-a-new-label) | [`POST /repos/{o}/{r}/labels` (an existing name is refused)](https://docs.gitea.com/api/1.22/#tag/issue/operation/issueCreateLabel) | [`POST /repos/{o}/{r}/labels` (an existing name is refused)](https://codeberg.org/api/swagger#/issue/issueCreateLabel) |
| `label add` | [`POST /repos/R/issues/N/labels`](https://docs.github.com/en/rest/issues/labels#add-labels-to-an-issue) | [`PUT /projects/:id/issues/:iid` `add_labels=`](https://docs.gitlab.com/ee/api/issues.html#edit-an-issue) | [`POST /repos/{o}/{r}/issues/{index}/labels`](https://docs.gitea.com/api/1.22/#tag/issue/operation/issueAddLabel) | [`POST /repos/{o}/{r}/issues/{index}/labels`](https://codeberg.org/api/swagger#/issue/issueAddLabel) |
| `label remove` | [`DELETE /repos/R/issues/N/labels/NAME`](https://docs.github.com/en/rest/issues/labels#remove-a-label-from-an-issue) | [`PUT /projects/:id/issues/:iid` `remove_labels=`](https://docs.gitlab.com/ee/api/issues.html#edit-an-issue) | [`DELETE /repos/{o}/{r}/issues/{index}/labels/{id}`](https://docs.gitea.com/api/1.22/#tag/issue/operation/issueRemoveLabel) | [`DELETE /repos/{o}/{r}/issues/{index}/labels/{id}`](https://codeberg.org/api/swagger#/issue/issueRemoveLabel) |
| `commit checks` | [`GET /repos/R/commits/SHA/check-runs`](https://docs.github.com/en/rest/checks/runs#list-check-runs-for-a-git-reference) | [`GET /projects/:id/repository/commits/:sha/statuses`](https://docs.gitlab.com/ee/api/commits.html#list-the-statuses-of-a-commit) | [`GET /repos/{o}/{r}/commits/{ref}/statuses`](https://docs.gitea.com/api/1.22/#tag/repository/operation/repoListStatuses) | [`GET /repos/{o}/{r}/commits/{ref}/statuses`](https://codeberg.org/api/swagger#/repository/repoListStatuses) |
| `ci runs` | [`GET /repos/R/actions/workflows/WF/runs?head_sha=&event=&branch=`](https://docs.github.com/en/rest/actions/workflow-runs#list-workflow-runs-for-a-workflow) | [`GET /projects/:id/pipelines?sha=&ref=&source=push`](https://docs.gitlab.com/ee/api/pipelines.html#list-project-pipelines) | [`GET /repos/{o}/{r}/actions/runs?head_sha=&event=&branch=` (Gitea 1.24+)](https://docs.gitea.com/api/next/) | none: capability off (no run-list endpoint this table can vouch for; [API](https://codeberg.org/api/swagger)) |
| `site publish` | [`PATCH /gists/ID`](https://docs.github.com/en/rest/gists/gists#update-a-gist) | [`PUT /snippets/:id`](https://docs.gitlab.com/ee/api/snippets.html#update-snippet) | none: capability off | none: capability off |
| `branch push` | [`git push <clone-url> BRANCH` with the token from the environment](https://docs.github.com/en/get-started/git-basics/about-remote-repositories) | [`git push <clone-url> BRANCH` with the token from the environment](https://docs.gitlab.com/ee/user/project/repository/) | [`git push <clone-url> BRANCH` with the token from the environment](https://docs.gitea.com/development/api-usage) | [`git push <clone-url> BRANCH` with the token from the environment](https://forgejo.org/docs/latest/user/api-usage/) |
