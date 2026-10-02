
## Repo governance: code review and shipping

On top of the agents-cli commands above (`agents-cli install`, `agents-cli playground`, `agents-cli lint`, `agents-cli eval`, `agents-cli deploy`), this repo adds a `Makefile` with its own governance targets:

```bash
make setup      # one-time post-clone setup: uv sync, git hooks, ship stage
make run-check  # confirm the agent still imports cleanly (also runs on git push)
make review     # run the code review manually (also runs on git push)
make ship       # review, push and ship the branch into develop (or /ship in a session; BRANCH=main for a prod release)
make ship-stage STAGE=open_pr  # how far make ship goes by default
```

After cloning, run `make setup`. `/ship` opens PRs into `develop` and goes as far as `open_pr` by default; `make ship-stage` changes that. See [Shipping a branch](#shipping-a-branch).

The default branch is `develop`. On the repo's first push, make it the remote default too:

```bash
git push -u origin main develop
gh repo edit --default-branch develop   # or: az repos update --repository <repo> --default-branch develop
git remote set-head origin develop
```

### Code review on push

`git push` triggers an agentic code review (`scripts/code-review.sh`, wired in as a pre-push hook). It makes two passes over your branch's diff:

1. General review: correctness bugs, security, missing tests, DRY, YAGNI, use of existing libraries over hand-rolled code.
2. Spec conformance: checks the change against the design documents in `docs/` and the decisions recorded on the changed paths (see [Decision history](#decision-history)).

Each pass reports findings as REQUIRED or SUGGESTED. Any REQUIRED finding blocks the push, and the full report lands in `working/code-review-report.md`. Fix the REQUIRED findings, commit, and push again — or see [Auto-fix](#auto-fix) below.

Reviews are incremental. After a passing review, the reviewed commit is recorded in `.git/code-review-ledger`, and the next push only reviews commits added since. A branch that hasn't changed is never re-reviewed.

### Auto-fix

With `fix_enabled=true` (the default), a failed review hands its REQUIRED findings to a fix agent. Both passes' findings go to a single fix agent — coupled fixes and shared root causes need one coherent pass, not one agent per finding. For each finding the agent either fixes it in the working tree or disputes it with checkable evidence (a `file:line`, a quoted doc statement, or test output), then prints a fix summary (also appended to the report). SUGGESTED findings are left alone.

A verification pass then checks the fix rather than re-reviewing the whole branch: each finding is judged resolved, dispute accepted, or still open, and only the fix diff is reviewed for new problems. A fresh full review each round would turn up new findings and might never converge. Fix -> verify repeats until nothing is open or `fix_max_iterations` is hit. If every finding was disputed and nothing changed, the push stays blocked and the call is yours. The fixes are always left uncommitted and the push always stays blocked, even once the working tree passes — the state that passed is uncommitted, not a commit, so it can't be recorded or shipped; the hook itself never commits or pushes on its own. A plain `git push` leaves it there: review the diff, commit the fixes, and push again — the committed fixes get one full review and the pass is recorded then. `make ship` goes one step further; see [Shipping a branch](#shipping-a-branch).

### Configuration

`.codereviewrc` in the repo root:

```
review_agent=claude    # claude | custom
review_model=opus      # model for pass 1, the general review (alias or full ID)
review_effort=high     # pass 1 effort: low | medium | high | xhigh | max | default
review_spec_model=sonnet # model for pass 2 (spec conformance) and fix verification
review_spec_effort=medium # pass 2 and verification effort, same values
enabled=true           # false disables the review
# command=...          # for review_agent=custom: reads the prompt on stdin, prints the review

fix_enabled=true       # false skips auto-fix and stops at the first failed review
fix_agent=claude       # claude | custom
fix_model=sonnet       # model for the fix pass
fix_effort=medium      # fix pass effort, same values
fix_max_iterations=2   # max fix -> verify rounds before giving up
agent_timeout=900      # seconds any one agent call may run; a timeout fails the pass
# fix_command=...      # for fix_agent=custom: reads the fix prompt on stdin, edits the tree
```

The ship settings are further down, under [Ship settings](#ship-settings).

The models are set explicitly rather than inherited from the `claude` CLI default. Aliases like `opus` and `sonnet` still move to each new release; set a full model ID (for example `claude-opus-5-5`) to pin one exactly. Pass 1 gets the strongest model because finding unreported bugs is the hardest job in the gate. A missed bug goes unnoticed, and a false REQUIRED costs a fix and a verification round. Pass 2, verification, and the fix pass all work from a stated doc or finding, so they run on Sonnet at medium effort. Every call sets its effort explicitly, because the CLI default changes between releases and a level doesn't mean the same amount of thinking on every model. One blocked push with `fix_enabled=true` runs 2 review passes plus up to 2 fix and 2 verification passes.

A custom review command must end its output with `VERDICT: PASS` or `VERDICT: FAIL` as the last non-empty line. Anything after the verdict is read as a failure, so nothing may follow it; surrounding `**` or backticks are tolerated. If the `claude` CLI isn't installed, the hook warns and lets the push through rather than blocking everyone without it; a misconfigured `.codereviewrc` (unknown agent, `custom` without its command) blocks the push instead.

### Skipping a review

```bash
SKIP_CODE_REVIEW=true git push
```

Or set `enabled=false` in `.codereviewrc` to turn it off for the repo. Skipping is for humans; agents working in this repo are instructed not to.

## Decision history

The decisions behind the code are kept in commit messages as git trailers. There's no decision directory to maintain. Each decision is stored with the commit that made it, and `git log` finds it by path.

### Recording a decision

Put the trailers in the last paragraph of the commit message:

```
Route all Firestore writes through the repository layer

- Move direct client calls in handlers to repo/
- Add a transaction wrapper

Decision: All Firestore writes go through repo/ so transactions are enforced in one place
Rejected: Per-handler transactions (duplicated retry logic, caused the March double-write bug)
Agent: claude-opus-5-5
Co-Authored-By: ...
```

| Trailer | Holds |
|---|---|
| `Decision:` | What was decided and why, on one line. Repeat it for each decision in the commit |
| `Rejected:` | An alternative that was ruled out, and the reason |
| `Agent:` | The model or agent that worked on the change, if one did |
| `Session:` | Optional. The agent session ID. Session transcripts are local and expire, so the `Decision:` line has to make sense without it |

Git reads trailers only from the final paragraph. Keep them together at the end, with no blank line between them and `Co-Authored-By:`.

Record a decision when a design discussion settles something, when you take a deliberate shortcut, or when you reverse an earlier decision. Routine commits don't need one. To reverse a decision, commit the change with a new `Decision:` trailer that says what changed and why. The newer entry supersedes the older one.

### Finding decisions

```bash
scripts/decisions.sh src/pkg/repo.py   # one file, following renames
scripts/decisions.sh src/pkg/          # a directory
scripts/decisions.sh --limit 5 src/    # the newest five
```

The same lookup runs at four points without being asked for:

- In Claude Code, the first time an agent edits a file in a session, a hook passes that file's decisions to the agent and shows you a one-line notice. The agent is told to stop and ask you before reversing one.
- When `git commit` opens the message editor, the decisions on the staged files are listed as comment lines. Git strips them from the saved message. `git commit -m` skips this, since no editor opens.
- On `git push`, the code review's spec pass checks the change against the decisions on the changed paths. A change that reverses one without a new `Decision:` trailer is a REQUIRED finding.
- GitLens in VS Code and Annotate in JetBrains IDEs show commit messages, trailers included, on hover.

### Squash merges drop decisions

A squash merge replaces a branch's commits with one new commit, and the host's default squash message loses the trailers. After that, `scripts/decisions.sh` can't find them. Prefer merge or rebase merges into `develop`:

- Azure DevOps: in the branch policies for `develop`, turn on "Limit merge types" and clear "Squash merge".
- GitHub: under Settings, General, Pull Requests, clear "Allow squash merging".

If you turn squash merging off, also set `pr_merge_method=merge` (or `rebase`) in `.codereviewrc`, or `/ship`'s merge stage fails to arm auto-merge.

`/ship` squashes by default. When the branch has decision trailers, it writes the squash commit message itself, listing the commits and then every trailer, so nothing is lost. A squash merge from the host's web UI does not do this.

## Shipping a branch

Run `/ship` in a Claude Code session, or `make ship` in a terminal. The ship runs from its own git worktree, so you can keep editing while it works.

1. A read-only plan prints the resolved settings, each tagged with where its value came from, and checks everything the stage needs: CLI logins, reviewers, the deploy target. Nothing is created yet.
2. You confirm. In a session that's the permission prompt on `make ship`. In a terminal it's `Proceed? [y/N]`. Denying leaves everything as it was.
3. The commit at HEAD is frozen as the branch `ship/<branch>-<sha7>`, checked out in a new worktree at `../<repo>.ship-<id>`. Commits you make afterwards don't join this ship.
4. The worktree pushes the snapshot branch, which runs the pre-push review there. If the auto-fix clears every REQUIRED finding, the ship commits the fix and pushes again, up to `ship_fix_retries` times. If REQUIRED findings are still open, the ship fails and the report is copied to `.git/ship/<id>/code-review-report.md`.
5. The ship then goes as far as `ship_stage`. Each stage includes the ones before it.

| Stage | What runs |
|---|---|
| `push` | Stops after the push |
| `open_pr` | Opens a PR from the snapshot branch into `develop` and adds `pr_reviewers`. The default |
| `merge` | Self-approves, arms auto-merge (squash, delete the source branch), and waits for the merge |
| `verify_deploy` | Waits for the dev pipeline run on the merge commit, checks the service is healthy and running that commit, and runs the smoke test |

A ship targets `develop` unless you name another branch (`/ship staging`, `make ship BRANCH=staging`). Naming `main` or `master` starts a prod release instead; see [Prod releases](#prod-releases). Your checkout and local branches are never touched: after a merge the final message suggests `git branch -d <branch>`, and nothing else changes. A passed ship removes its worktree and local snapshot branch. A failed or stopped one keeps both for inspection.

```bash
/ship                        # plan, confirm, run in the background, report each stage
/ship merge                  # a different stage for this run
/ship staging                # target a branch other than develop
/ship main                   # prod release: PR from develop into main (see below)
/ship review_model=sonnet    # any .codereviewrc key, for this run
/ship status                 # running and recent ships
/ship stop                   # stop a running ship and list what it left (open PR, armed auto-merge)

make ship-plan STAGE=merge SET='review_model=sonnet'   # the plan only
make ship STAGE=merge                                  # plan, prompt, then run in the foreground
make ship-stage STAGE=open_pr                          # change your default stage
```

A background ship keeps running if the session closes. Each ship's `status.json`, `events`, `ship.log` and review report live in `.git/ship/<id>/`. They're deleted `ship_log_retention_days` (default 30) after the ship finishes.

At `open_pr` without named reviewers, `/ship` asks whether to add any. At `merge` and above the PR is approved and merged right away, so the plan warns if `pr_reviewers` is set.

### Prod releases

`/ship main` (or `master`) releases `develop` into it. It asks two things first: whether this is a prod deploy that merges `develop` into `main`, and whether to self-approve and auto-merge. The default answer to the second is no, which stops at an open PR for a human to approve and merge. `ship_stage` in `.codereviewrc` doesn't apply to prod.

The release is `origin/develop` at the commit the plan saw. There's no worktree and no push, because every change was reviewed on its way into `develop`. `/ship` drafts release notes from the commits and recorded decisions since `main` and shows them before the permission prompt. The PR is titled `prod 🚀` with the notes as its description. It merges with a merge commit, so `main` and `develop` don't diverge, and it never deletes `develop`. If `develop` moves while the PR waits, the ship fails rather than release commits nobody planned. `verify_deploy` checks the dev deploy only, so a prod release goes no further than `merge`.

From a terminal, `make ship BRANCH=main NOTES=<file>` does the same with your own notes file. Without `NOTES`, the description is a generated list of commit subjects.

### Overrides

Any `.codereviewrc` key can be changed for one run without editing the file. Highest priority first:

1. `/ship key=value` in a session, `make ship SET='key=value;key=value'`, or `ship.sh --set key=value`. `STAGE=merge` is shorthand for `ship_stage`.
2. The environment variable `CR_<KEY>`, for example `CR_REVIEW_MODEL=sonnet`.
3. `.codereviewrc`.
4. The built-in default.

An unknown key fails the plan and names the closest known one. An empty value means the default. Plain `git push` honors `CR_*` too, so `CR_REVIEW_MODEL=sonnet git push` works. Overrides are never written back; `make ship-stage` is the one command that edits the file.

### Deploy verification

`verify_deploy` checks the dev environment only, after filling in the `deploy_*` keys in `.codereviewrc`. It looks for a `deploy_pipeline` run on `develop` for the merge commit. If none appears within `deploy_run_grace` seconds, the pipeline's path filters excluded the change: the stage is recorded as skipped and the ship passes.

Once the run succeeds, the target has to be healthy. A Cloud Run service needs Ready=True and 100% of traffic on its latest ready revision; an Agent Runtime has to exist under `deploy_name`. It also has to be this commit. With `deploy_match=sha` the Cloud Run revision must be named `<service>-<sha12>` or carry a `commit=<sha12>` label, and the Agent Runtime must carry a `commit=<sha12>` label. Otherwise it must have been created or updated after the run started.

The smoke test (`deploy_smoke`) runs in the ship's worktree with `DEPLOY_URL`, `DEPLOY_RESOURCE` and `DEPLOY_SHA` set, and its exit code decides the result. A smoke test that skips and exits 0 when it can't reach the target makes this check meaningless, so set its require-live flag (for example `SMOKE_TEST_REQUIRE_LIVE=1`). For a private Cloud Run service, `deploy_proxy=true` points `DEPLOY_URL` at a local `gcloud run services proxy`.

### Ship settings

| Key | Values | Default |
|-----|--------|---------|
| `ship_stage` | `push`, `open_pr`, `merge`, `verify_deploy` | `open_pr` |
| `ship_fix_retries` | times one ship commits an auto-fix and pushes again | `1` |
| `ship_log_retention_days` | days to keep finished ship logs; `0` keeps them | `30` |
| `ship_notify` | `none`, `desktop` (macOS notification per stage) | `none` |
| `pr_host` | `gh`, `az` | detected from `origin` |
| `pr_reviewers` | comma-separated GitHub users or `org/team`; ADO emails or `[Project]\Team` | none |
| `pr_merge_method` | `squash`, `merge`, `rebase` | `squash` |
| `pr_self_approve` | `true`, `false`; a host that rejects self-review makes it a no-op | `true` |
| `pr_poll_interval` / `pr_poll_timeout` | seconds between polls / before the merge stage gives up | `15` / `1800` |
| `deploy_pipeline` | ADO pipeline name or ID, or GitHub workflow name | none |
| `deploy_provider` | `cloud_run`, `agent_runtime` (or its earlier name, `agent_engine`) | none |
| `deploy_project` / `deploy_region` | dev GCP project / region | none / `us-central1` |
| `deploy_name` | Cloud Run service or Agent Runtime display name | none |
| `deploy_match` | `sha`, `time` | `time` |
| `deploy_proxy` | `true`, `false` | `false` |
| `deploy_smoke` | smoke test command | none |
| `deploy_run_grace` / `deploy_poll_timeout` / `deploy_smoke_timeout` | seconds | `300` / `3600` / `900` |

`.codereviewrc` is gitignored and personal to your machine. How far your ships go is your call, and it shouldn't change for a teammate because they pulled a commit. Every default is built into the scripts, so a clone with no `.codereviewrc` behaves like the scaffolded file. A file that still has the old `pr_automation` key and no `ship_stage` is read as `merge` (true) or `push` (false), with a notice.

## Documentation

Design docs live in `docs/`, alongside the agents-cli development and deployment guides referenced from `CLAUDE.md`. `design.md` is the source of truth for architecture decisions; the code review's second pass enforces it, so keep it current.

One file holds the whole design at first. Once `design.md` passes ~400 lines or covers three or more flows, create `docs/specs/` and move each flow into its own `docs/specs/<flow>.md` with a `docs/specs/<flow>-diagram.mmd` beside it, leaving `design.md` the overview, the Flows index, the architecture, and the cross-cutting concerns. `docs/templates/` holds the skeleton a new spec starts from and the starting shape and content rules for its diagram. The docs sync gate blocks a turn that adds a spec without its diagram or without linking it from the index.
