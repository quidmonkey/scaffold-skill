# scaffold

A world is coming, and will soon be here when the tools and processes that were previously used in a pre-agentic world will no longer be with us.

CI is a relic, SDLC no longer makes sense, and the checks and balances of a compliant codebase will come and go, if not the concepts of git and a codebase.

This skill exists to scaffold a Python project with `uv` and wires lint, type checks, security scans, tests and an AI code review into git hooks. 

It also adds a `/ship` skill whose intent is to ensure you never have to log into a website again and press buttons to ship code.

When the process becomes automated, then necessity of the process is in question.

## Install

```bash
git clone git@github.com:quidmonkey/scaffold-skill.git \
  ~/.claude/skills/scaffold
```

Requires [Claude Code](https://claude.ai/code), [uv](https://github.com/astral-sh/uv), Git and Python 3.12 or later.

## Usage

In a Claude Code session, run `/scaffold my-agent` or ask to "create a new python project called my-agent".

The skill asks one question first: not GCP, GCP, or GCP via Google's [agent-starter-pack](https://github.com/GoogleCloudPlatform/agent-starter-pack).

- Without agent-starter-pack, it asks for a layout: a single package in `src/<name>/`, or a monorepo under `packages/<name>/`.
- With agent-starter-pack, it asks for the agent template, deployment target and scaffold depth. It then layers this skill's tooling on top of the generated project.
- GCP projects also get `docs/finops.md` and `docs/infra.md`.

## What you get

| Tool | Job |
|------|-----|
| [ruff](https://github.com/astral-sh/ruff) | Lint, format, and complexity (C90) |
| [ty](https://github.com/astral-sh/ty) | Type checking |
| [bandit](https://github.com/PyCQA/bandit) | Security scanning |
| [pytest](https://pytest.org) | Tests |
| [pre-commit](https://pre-commit.com) | Runs the above as git hooks |

The hooks run in three stages:

- On commit: ruff, ty, bandit and the standard file checks.
- On push: pytest, `make run-check` (confirms the app still starts), then the code review. `fail_fast` is on, so the review is skipped if an earlier hook already failed.
- In the commit message editor: the recorded decisions for the staged files, as comments.

The scaffold also writes `CLAUDE.md`, `.claude/settings.json`, a `docs/` folder, the `/ship` skill, and the scripts behind them in `scripts/`. `uv.lock` is committed. The default branch is `develop`. If its marketplace is registered, the scaffold also installs the `google-agents-cli` project plugin.

## Keeping the agent honest

`CLAUDE.md` tells the agent to run pre-commit after each change and fix failures at the root cause. It also sets the source of truth: `docs/` first, then tests, then code. A failing test therefore sends the agent to the spec, not to the test file. The file is short on purpose. Hooks do the enforcing, so `CLAUDE.md` doesn't repeat what a hook already checks.

`.claude/settings.json` adds two `Stop` hooks that run when the agent tries to finish:

- `precommit-check.sh` runs pre-commit on the changed files. A clean working tree skips it.
- `docs-sync-check.sh` blocks on stale docs. Examples: `design.md` changed but `design.mmd` didn't, a spec isn't linked from the design doc, or the deployable footprint changed but `finops.md` didn't.

Both exit 2 and write to stderr, because that is the only channel the model sees. The docs gate fires at most once per turn so it can't loop.

The same file sets the permissions:

- Read-only `gcloud`, `terraform` and `docker` commands are pre-approved.
- These always prompt: `terraform apply` and `destroy`, secret reads, auth changes, `docker run`/`exec`/`build`, `make deploy` and `make ship`.
- The project starts in auto mode. Set `defaultMode` to `default` to go back to manual prompts.

Claude Code ignores project `allow` rules in an untrusted directory, so the skill marks the new directory as trusted in `~/.claude.json`. To undo it, set `hasTrustDialogAccepted` back to `false`.

If you edit the rules, remember that `deny` beats `ask`, and `ask` beats `allow`. A broad `Bash(gcloud *)` in `ask` silently disables every specific `gcloud` allow rule.

## Docs: one design doc, then specs

A new project has a single `docs/design.md`. Once it passes 400 lines or covers three flows, each flow moves to `docs/specs/<flow>.md` with a diagram beside it. `design.md` keeps the overview and a Flows index that links each spec. Starter files for both are in `docs/templates/`. The docs gate enforces the split and the links.

## Code review on push

Every `git push` runs `scripts/code-review.sh` as a pre-push hook. Two review passes run in parallel over the branch diff:

1. A general review: correctness, security, missing tests, duplication, and hand-rolled code where a library exists. Ruff covers style.
2. A spec check against `docs/` and the recorded decisions on the changed files.

Any REQUIRED finding blocks the push. The full report is in `working/code-review-report.md`.

On a failure, a fix agent fixes each REQUIRED finding in the working tree or disputes it with evidence. A verification pass then checks only the fix. The push stays blocked even when every fix lands, because the fixes are uncommitted. Review them, commit and push again.

Each commit is reviewed once. The last passing commit per branch is recorded in `.git/code-review-ledger`, so later pushes review only new commits.

Settings live in `.codereviewrc`, which is gitignored, so each developer has their own. Its comments explain every key: models, effort levels, auto-fix, timeouts, and a custom agent command. Override any key for one push with `CR_<KEY>`, for example `CR_REVIEW_MODEL=sonnet git push`. To skip a review, use `SKIP_CODE_REVIEW=true git push` for one push, or set `enabled=false` for the repo. If the `claude` CLI isn't installed, the hook warns and lets the push through. A bad config blocks the push.

## Decision history

The project keeps its Architecture Decision Records (ADRs) as commit trailers instead of a `docs/adr/` folder. Each decision is recorded as `Decision:`, `Rejected:` and `Agent:` trailers on the commit that makes it, so the record lives with the change it explains. `scripts/decisions.sh <path>` lists them for a file. They come back up when that file changes:

- The agent sees them after its first edit to the file.
- The commit editor lists them.
- The review's spec pass blocks a reversal that doesn't record a new decision.

Squash merges from the host's web UI drop trailers, so turn squash merging off for `develop`. See [docs/specs/decision-trailers.md](docs/specs/decision-trailers.md).

## Shipping with /ship

`/ship` ships the current branch into `develop` in the background while you keep working. It freezes HEAD as a snapshot branch and works in its own worktree (`../<repo>.ship-<id>`). It runs the same pre-push review there. Unlike a manual push, it commits a converged auto-fix and pushes again, up to `ship_fix_retries` times.

How far it goes is set by `ship_stage`, and each stage includes the ones before it:

| Stage | What it does |
|-------|--------------|
| `push` | Push the snapshot branch |
| `open_pr` (default) | Open a PR into `develop` |
| `merge` | Self-approve, arm auto-merge, wait for the merge |
| `verify_deploy` | Wait for the dev deploy, check health, run the smoke test |

`/ship` only targets `develop`, so it can't deploy to prod. `make ship-plan` runs every preflight check without changing anything. `/ship status` and `/ship stop` check on or cancel a running ship. The permission prompt on `make ship` is the one confirmation. Full details are in [docs/specs/ship-skill.md](docs/specs/ship-skill.md).

The scaffold creates no remote. After you add one, push both branches and make `develop` the default:

```bash
git push -u origin main develop
gh repo edit --default-branch develop   # or: az repos update --repository <repo> --default-branch develop
git remote set-head origin develop
```

### Adding /ship to an existing repo

1. Copy `templates/skills/ship/` to `.claude/skills/ship/`, and copy `scripts/ship.sh`, `scripts/set-ship-stage.sh` and `scripts/lib/` from `templates/`. If `.gitignore` ignores `.claude/skills/`, add `!.claude/skills/ship/`.
2. If the repo has no review gate, copy `scripts/code-review.sh` and add its pre-push hook from `templates/pre-commit-config.yaml`.
3. Add the ship keys from `templates/.codereviewrc` to `.codereviewrc`, and gitignore `.codereviewrc`.
4. Copy the `ship*` targets and their helpers from `templates/Makefile`. Add `Bash(make ship)`, `Bash(make ship *)`, `Bash(bash scripts/ship.sh*)` and `Bash(./scripts/ship.sh*)` to `ask` in `.claude/settings.json`.
5. Run `/ship push` once. Preflight lists anything still missing.

A repo whose default branch is still `main` works too. `ship.sh` bases the first review on `develop` either way.

## Notes

The opinions live in [templates/](./templates/): which tools, how they're configured, and what the agent is told. Treat them as a baseline, not rules. Everything installs locally through `uv`, docs live in the repo so the agent can read and update them, and setup stays small because a crowded context makes agents worse.
