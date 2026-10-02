---
name: scaffold
version: 4.0.0
description: |
  Create a new Python project using uv with pre-commit, ruff, ty, bandit, and pytest
  configured and ready to use. Prompts for project name and layout (single package or monorepo).
  For GCP projects, optionally scaffolds with Google's agents-cli (ADK agent templates,
  Cloud Run/Agent Runtime/GKE deployment, Terraform, CI/CD) and layers this skill's
  tooling on top. Generates CLAUDE.md and .claude/settings.json to enforce pre-commit
  checks during agentic development.
  Use when user says "create python project", "new python project", "init python project",
  "scaffold python project", or invokes /scaffold.
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - AskUserQuestion
---

# Scaffold

Scaffold a Python project with ruff, ty, bandit, pytest, pre-commit, and agent instruction files. For GCP projects, optionally hands base scaffolding to Google's [agents-cli](https://github.com/google/agents-cli) and layers this skill's lint/pre-commit/code-review/docs tooling on top rather than replacing it.

Templates: `~/.claude/skills/scaffold/templates/` (plain scaffold), `~/.claude/skills/scaffold/templates/agents-cli/` (agents-cli addenda and governance `Makefile`)
Placeholders: `{{project-name}}`, `{{package_name}}`, `{{code-dir}}`, `{{test-dir}}`, `{{layout-line}}`, `{{gcp-doc-lines}}`, `{{gcp-sync-rule}}`, `{{lint-target}}`, `{{bandit-exclude-arg}}`, and (agents-cli mode) `{{agent-template}}`, `{{deployment-target}}`, `{{depth-flag}}`

## Step 1: Gather inputs

Use project name from args if provided, else ask.

Ask "GCP scope?" via `AskUserQuestion` (single question, one call):
- **Not a GCP project**: no GCP docs, no agents-cli.
- **GCP project**: plain `uv`-scaffolded project, GCP cost/infra docs included.
- **GCP agent via agents-cli**: scaffold with Google's [agents-cli](https://github.com/google/agents-cli) (ADK agent templates, Cloud Run/Agent Runtime/GKE deployment, Terraform, CI/CD), then layer this skill's lint/pre-commit/code-review/docs tooling on top.

Set `{{gcp}}` = true for either GCP option, `{{agents-cli}}` = true only for the agents-cli option.

agents-cli replaced Google's agent-starter-pack, which is in maintenance mode (critical fixes only). Don't scaffold with `agent-starter-pack` even if the user names it; say it's deprecated and use agents-cli.

Every project gets the `/ship` pipeline, which opens PRs into and merges into `develop` and verifies the dev deploy. Step 6 makes `develop` the default branch.

### If `{{agents-cli}}`

Ask via `AskUserQuestion` (up to 3 questions, one call):
- **Agent template** (`-a`): offer `adk` (ADK ReAct agent with A2A support, recommended default) and `adk-samples agent` (an `adk@<sample>` shortcut such as `adk@data-science`; ask for the sample name if the user picks it). "Other" takes any id agents-cli accepts: a local path (`local@/path`) or a remote Git URL. agents-cli 1.8 dropped agent-starter-pack's `langgraph` and `agentic_rag` templates, and `adk_a2a` is now an alias for `adk`. Don't offer `adk_go`, `adk_java`, `adk_ts` or the `empty_*` templates: this skill's tooling is Python-only, and `empty_py` generates no agent directory for `run-check` to import.
- **Deployment target** (`-d`): `agent_runtime` (recommended default; agent-starter-pack called it `agent_engine`), `cloud_run`, `gke`, `none`.
- **Scaffold depth**: `Prototype` (recommended for exploration — `--prototype`, no CI/CD or Terraform, fastest to iterate) or `Full` (CI/CD + Terraform via GitHub Actions — production-ready pipeline, more setup).

Skip the layout question entirely — agents-cli owns the directory layout.

If the depth is Full and the deployment target is `cloud_run` or `agent_runtime`, then ask via `AskUserQuestion`: "Tag deploys with the commit SHA? (Recommended: yes)". Yes lets `/ship`'s `verify_deploy` stage confirm the deployed revision is the merged commit (`deploy_match=sha`); no makes it fall back to timing checks (`deploy_match` unset, meaning `time`). Set `{{sha-tagging}}` from the answer. Skip the question for Prototype depth (no CI deploy for `verify_deploy` to watch), for `gke` and `none`, and for the plain scaffold, which has no generated deploy.

Set:
- `{{code-dir}}`: `app` (agents-cli's default agent directory; after Step 2, confirm it against `agent_directory` in `agents-cli-manifest.yaml` and use that value if it differs)
- `{{test-dir}}`: `tests/unit` — **not** `tests/integration` or `tests/eval`. The generated `tests/integration/` makes live Vertex AI calls and fails with a 403 the moment there's no GCP project/credentials configured, which a fresh scaffold never has. Gating every `git push` on that would block the pre-push hook out of the box. `uv run pytest tests/unit tests/integration` (the command the generated `CLAUDE.md` gives) still runs both for whoever has real credentials; only this skill's pre-push pytest hook is scoped down. `tests/eval` holds ADK evalsets, run via `agents-cli eval run`, and was never in scope for either.
- `{{lint-target}}`: `{{code-dir}}`
- `{{bandit-exclude-arg}}`: empty string

### Otherwise (plain `uv` scaffold, GCP or not)

Ask layout via `AskUserQuestion`:
- **Single package**: `uv init --package`. Code in `src/<name>/`, tests in `tests/`.
- **Monorepo**: `uv init`. Code under `packages/<name>/`, tests colocated under `packages/<name>/tests/`.

Derive `{{package_name}}`: lowercase, hyphens → underscores.

Set:
- `{{code-dir}}`: `src` (single) or `packages` (monorepo)
- `{{test-dir}}`: `tests` (single) or `packages` (monorepo)
- `{{layout-line}}`: `src/{{package_name}}/` with `tests/` (single) or `packages/{{package_name}}/` with `packages/{{package_name}}/tests/` (monorepo)
- `{{lint-target}}`: `{{code-dir}}/{{package_name}}`
- `{{bandit-exclude-arg}}`: ` -x {{code-dir}}/{{package_name}}/tests`

### Shared, for any GCP project (`{{gcp}}`)

- `{{gcp-doc-lines}}`: the two-line block below.
  ```
  - `finops.md` — GCP cost analysis for the design
  - `infra.md` — CI pipeline, IAM accounts and roles
  ```
- `{{gcp-sync-rule}}`: the line below.
  ```
  After any change to the deployed GCP footprint — `docs/design.md`, `docs/infra.md`, `Dockerfile`, `scripts/deploy.sh`, or any `*.tf` — update `docs/finops.md` so the service table and cost estimates match what is actually deployed.
  ```

For a non-GCP project, both are the empty string (drop the blank line that follows each).

## Step 2: Create project

**agents-cli (`{{agents-cli}}`):**
```bash
uvx --from google-agents-cli agents-cli create {{project-name}} \
  -a {{agent-template}} \
  -d {{deployment-target}} \
  --agent-guidance-filename CLAUDE.md \
  -y -s \
  {{depth-flag}}
cd {{project-name}}
```
`{{depth-flag}}` is `--prototype` for Prototype depth, or `--cicd-runner github_actions` for Full (this skill's own `ship.sh` assumes a `gh`/`az repos pr`-reachable host, so GitHub Actions is the consistent default; Cloud Build isn't offered as a choice here). `-s` skips agents-cli's live GCP/Vertex AI auth checks — this is a scaffolding step, not a deploy step. `-y` accepts its own defaults for anything not covered by the flags above (`in_memory` sessions, region `us-east1`).

agents-cli prints its own next steps (`agents-cli install && agents-cli playground`) — that output is expected and is not this skill's own report. It writes `agents-cli-manifest.yaml` (name, agent directory, region, deployment target), which later steps read.

**Single:**
```bash
uv init --package --python 3.12 {{project-name}}
cd {{project-name}}
mkdir -p tests && touch tests/__init__.py
```

**Monorepo:**
```bash
uv init --python 3.12 {{project-name}}
cd {{project-name}}
rm -f hello.py
mkdir -p packages/{{package_name}}/tests
touch packages/{{package_name}}/__init__.py packages/{{package_name}}/tests/__init__.py
```

## Step 3: Add dev dependencies

**agents-cli:** its generated `pyproject.toml` already carries `pytest` (in `dependency-groups.dev`) and `ruff`/`ty` (in `project.optional-dependencies.lint`, not the dev group — our pre-commit hooks call them with `--no-sync`, so they need to be in the dev group too):
```bash
uv add --dev ruff ty "bandit[toml]" pre-commit
```

**Plain scaffold:**
```bash
uv add --dev ruff ty "bandit[toml]" pytest pre-commit
```

## Step 4: Write config files

Read each template from `~/.claude/skills/scaffold/templates/`, substitute all placeholders, write to destination.

Notes:
- `uv init` (plain scaffold) and `agents-cli create` (agents-cli scaffold) both pre-create `.gitignore`, `README.md`, and `pyproject.toml`. To overwrite a file, Read it first (the harness blocks overwrite-without-read), then Write. Where the table below says **append**, use Edit/Read + append instead — never overwrite a file agents-cli owns.
- `pyproject-additions.toml` / `templates/agents-cli/pyproject-bandit.toml` are appended, so each must start with a `[table]` header. Never add a bare top-level key (e.g. `requires-python`) at its top — it would leak into the last existing table and break the parse. Keep the `--python 3.12` flag on `uv init` (plain scaffold only) — without it uv picks whatever interpreter its `python-preference = "managed"` default resolves to, which can be older than 3.12 and silently lowers both `requires-python` and the ruff `target-version` inferred from it.

**Plain scaffold (GCP or not):**

| Template | Destination | Mode |
|----------|------------|------|
| `templates/pre-commit-config.yaml` | `.pre-commit-config.yaml` | write |
| `templates/pyproject-additions.toml` | `pyproject.toml` | append |
| `templates/CLAUDE.md` | `CLAUDE.md` | write |
| `templates/README.md` | `README.md` | write |
| `templates/.codereviewrc` | `.codereviewrc` | write — gitignored, not `git add`ed |
| `templates/scripts/lib/common.sh` | `scripts/lib/common.sh` | write |
| `templates/scripts/code-review.sh` | `scripts/code-review.sh` | write |
| `templates/scripts/lib/ship-status.sh` | `scripts/lib/ship-status.sh` | write |
| `templates/scripts/lib/ship-deploy.sh` | `scripts/lib/ship-deploy.sh` | write |
| `templates/scripts/ship.sh` | `scripts/ship.sh` | write |
| `templates/scripts/set-ship-stage.sh` | `scripts/set-ship-stage.sh` | write |
| `templates/scripts/docs-sync-check.sh` | `scripts/docs-sync-check.sh` | write |
| `templates/scripts/precommit-check.sh` | `scripts/precommit-check.sh` | write |
| `templates/scripts/decisions.sh` | `scripts/decisions.sh` | write |
| `templates/scripts/decisions-hook.sh` | `scripts/decisions-hook.sh` | write |
| `templates/scripts/decisions-commit-msg.sh` | `scripts/decisions-commit-msg.sh` | write |
| `templates/settings.json` | `.claude/settings.json` | write |
| `templates/skills/ship/SKILL.md` | `.claude/skills/ship/SKILL.md` | write |
| `templates/Makefile` | `Makefile` | write |
| `templates/docs/design.md` | `docs/design.md` | write |
| `templates/docs/design.mmd` | `docs/design.mmd` | write |
| `templates/docs/templates/spec.md` | `docs/templates/spec.md` | write |
| `templates/docs/templates/diagram.mmd` | `docs/templates/diagram.mmd` | write |
| `templates/docs/finops.md` | `docs/finops.md` | write — **GCP only** |
| `templates/docs/infra.md` | `docs/infra.md` | write — **GCP only** |
| `templates/.gitignore` | `.gitignore` | write |

Skip the `finops.md` and `infra.md` rows entirely for non-GCP projects.

**agents-cli scaffold (`{{agents-cli}}`):** agents-cli already owns `pyproject.toml`, `README.md`, `CLAUDE.md`, and `.gitignore` — none of those are overwritten. It generates no `Makefile` (its own commands replace one), so this skill writes a governance-only `Makefile`. This skill's tooling layers on top of them:

| Template | Destination | Mode |
|----------|------------|------|
| `templates/pre-commit-config.yaml` | `.pre-commit-config.yaml` | write — agents-cli has no pre-commit config |
| `templates/agents-cli/pyproject-bandit.toml` | `pyproject.toml` | append — only `[tool.bandit]`; agents-cli already configures `[tool.ruff]`/`[tool.ty]`/`[tool.pytest.ini_options]`, and a duplicate TOML table header breaks the parse |
| `templates/agents-cli/CLAUDE-addendum.md` | `CLAUDE.md` | append to the file agents-cli generated (`--agent-guidance-filename CLAUDE.md` in Step 2 made this the guaranteed target) |
| `templates/agents-cli/README-addendum.md` | `README.md` | append |
| `templates/agents-cli/Makefile` | `Makefile` | write — governance targets only (`setup`, `run-check`, `review`, `ship*`) |
| `templates/agents-cli/gitignore-addendum` | `.gitignore` | append — only the lines not already covered by agents-cli's own `.gitignore` |
| `templates/.codereviewrc` | `.codereviewrc` | write — gitignored, not `git add`ed |
| `templates/scripts/lib/common.sh` | `scripts/lib/common.sh` | write |
| `templates/scripts/code-review.sh` | `scripts/code-review.sh` | write |
| `templates/scripts/lib/ship-status.sh` | `scripts/lib/ship-status.sh` | write |
| `templates/scripts/lib/ship-deploy.sh` | `scripts/lib/ship-deploy.sh` | write |
| `templates/scripts/ship.sh` | `scripts/ship.sh` | write |
| `templates/scripts/set-ship-stage.sh` | `scripts/set-ship-stage.sh` | write |
| `templates/scripts/docs-sync-check.sh` | `scripts/docs-sync-check.sh` | write |
| `templates/scripts/precommit-check.sh` | `scripts/precommit-check.sh` | write |
| `templates/scripts/decisions.sh` | `scripts/decisions.sh` | write |
| `templates/scripts/decisions-hook.sh` | `scripts/decisions-hook.sh` | write |
| `templates/scripts/decisions-commit-msg.sh` | `scripts/decisions-commit-msg.sh` | write |
| `templates/settings.json` | `.claude/settings.json` | write |
| `templates/skills/ship/SKILL.md` | `.claude/skills/ship/SKILL.md` | write |
| `templates/docs/design.md` | `docs/design.md` | write |
| `templates/docs/design.mmd` | `docs/design.mmd` | write |
| `templates/docs/templates/spec.md` | `docs/templates/spec.md` | write |
| `templates/docs/templates/diagram.mmd` | `docs/templates/diagram.mmd` | write |
| `templates/docs/finops.md` | `docs/finops.md` | write — GCP is always true in agents-cli mode |
| `templates/docs/infra.md` | `docs/infra.md` | write |

`templates/agents-cli/Makefile`'s `run-check` target assumes `{{code-dir}}/agent.py` (e.g. `app/agent.py`) is the agent's entry point, matching agents-cli's layout for the `adk` template. If the chosen template places it elsewhere, fix the target before reporting done.

```bash
mkdir -p .claude/skills/ship docs/templates working scripts/lib
chmod +x scripts/code-review.sh scripts/ship.sh scripts/set-ship-stage.sh scripts/docs-sync-check.sh scripts/precommit-check.sh scripts/decisions.sh scripts/decisions-hook.sh scripts/decisions-commit-msg.sh
```

**Prefilled deploy settings (`{{agents-cli}}` with `cloud_run` or `agent_runtime`):** in the written `.codereviewrc`, set `deploy_provider=<deployment target>`, `deploy_region` to `region` from `agents-cli-manifest.yaml` (agents-cli's default is `us-east1`), and `deploy_name` to the Cloud Run service name or Agent Runtime display name. `agents-cli deploy` defaults that to the project name, so use `name` from the manifest unless a generated workflow passes `--service-name`. Set `deploy_match=sha` if `{{sha-tagging}}` is yes. Leave `deploy_pipeline`, `deploy_project` and `deploy_smoke` empty: the scaffold doesn't know them. Skip this for every other target and for the plain scaffold.

**Tag deploys with the commit SHA (`{{sha-tagging}}` yes):** the generated `.github/workflows/staging.yaml` and `deploy-to-prod.yaml` deploy with `uvx google-agents-cli@<version> deploy ...`. Add `--labels commit=${GITHUB_SHA::12}` to each of those `deploy` invocations, as one more continuation line. `--labels` sets a resource label on both an Agent Runtime and a Cloud Run revision (`agents-cli deploy` has no revision-suffix flag), and `/ship` checks for a `commit=<sha12>` label on either. Labels are additive, so redeploying the same commit works.

After editing, grep for `commit=` in the workflows to confirm the edit landed. If no `agents-cli deploy` invocation is there (a different template or agents-cli version), skip the edit, set `deploy_match` back to unset, and report that SHA tagging wasn't applied and why.

Do not create `docs/specs/`. It comes into existence when the design outgrows one file; `CLAUDE.md` carries the rule for creating it then, and `docs/templates/` carries the spec skeleton and diagram starting shape.

`working/` holds dirty files needed during development but never committed. The `.gitignore` template excludes it. The generated `CLAUDE.md` forbids mentioning `working/` in `docs/` or in code comments.

## Step 5: Install project skills

```bash
claude plugin install google-agents-cli --scope project 2>/dev/null || true
```

Humanizing is baked into `CLAUDE.md` directly (no `humanizer` skill needed).
`google-agents-cli` is best-effort: the install no-ops unless its marketplace is
already registered. Report it as installed only if the command above succeeded;
otherwise tell the user to add the marketplace first. In agents-cli mode it gives
the session the ADK, eval and deploy skills that the generated `CLAUDE.md` points to;
`uvx google-agents-cli setup` installs the same skills user-wide instead.

## Step 6: Init git, install pre-commit hooks, create `develop`

```bash
git init
git symbolic-ref HEAD refs/heads/main
uv run pre-commit install
git add .
git commit -m "Initial scaffold"
git checkout -b develop
```

**Fix generated code for this skill's hooks (`{{agents-cli}}`):** after `git add .` and before `git commit`, run `uv run pre-commit run --all-files` and fix what bandit, ruff and ty report, since a hook failure blocks the first commit. `--all-files` only sees tracked files, so it has to come after `git add .`. `fail_fast` reports one failing hook per run, so fix, `git add .` and re-run until it passes. Confirmed by dry run (agents-cli v1.8.0, `adk` template, both `cloud_run` and `agent_runtime`): bandit flags `B104` (bind to all interfaces) on `uvicorn.run(app, host="0.0.0.0", ...)` in `{{code-dir}}/fast_api_app.py`. A container has to bind every interface, so add `# nosec B104 - containers must bind all interfaces` to that line. That's a justified suppression, not a disabled rule. Other templates or versions may generate different code; fix whatever the hooks actually report rather than assuming this exact finding. The file fixers (`trailing-whitespace`, `end-of-file-fixer`) also rewrite several generated `.tf` and workflow files; that's expected.

`uv init` already created the repo (on the user's `init.defaultBranch`), and `agents-cli create` creates none, so `git init` is a no-op in the first case and starts a fresh repo in the second. `git symbolic-ref` points the still-unborn branch at `main` either way; `git init -b main` would be ignored on the existing repo.

The commit runs the pre-commit hooks. A hook that rewrites files (for example `end-of-file-fixer`) fails the commit; `git add .` and commit again. `fail_fast` stops at the first failing hook, so each attempt can surface a different fixer; repeat until it passes. If the same non-fixer hook fails twice, fix its finding rather than retrying. If git has no user identity configured, stop and report that rather than setting one.

`develop` is the branch `/ship` targets. The scaffold creates no remote, so the report gives the first-push commands that make `develop` the remote default too.

In agents-cli mode, run `uv run pre-commit run --all-files` once more after the commit to confirm everything passes.

`default_install_hook_types` in `.pre-commit-config.yaml` makes this install the pre-commit, pre-push, and prepare-commit-msg stages — pre-push carries the pytest and code-review hooks, prepare-commit-msg the decision-history listing.

## Step 7: Trust the workspace

Claude Code drops every project-scoped `permissions.allow` entry until the workspace is trusted, so a freshly scaffolded project starts with every pre-approval inert and every `ask` rule live, which is maximally prompt-y. Record trust for the new directory so `.claude/settings.json` takes effect on first use.

Run from the project root. Both path spellings are recorded because Claude Code keys projects by the cwd it was started with, which may be a symlinked path. `uv run python` is used rather than a bare `python3` — uv is already a hard requirement and the project env exists by now, whereas `python3` goes through whatever version manager the user has and can fail inside a directory holding a `.python-version` file.

```bash
uv run python - "$(pwd)" "$(pwd -P)" <<'PY'
import json, os, sys, tempfile

config = os.path.expanduser("~/.claude.json")
keys = list(dict.fromkeys(sys.argv[1:]))

try:
    with open(config) as f:
        data = json.load(f)
except FileNotFoundError:
    data = {}
except json.JSONDecodeError:
    sys.exit(f"~/.claude.json is not valid JSON — leaving it alone. Accept the trust dialog manually in {keys[0]}.")

projects = data.setdefault("projects", {})
for key in keys:
    projects.setdefault(key, {})["hasTrustDialogAccepted"] = True

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(config), suffix=".tmp")
with os.fdopen(fd, "w") as f:
    json.dump(data, f, indent=2)
os.replace(tmp, config)
print("Trusted workspace:", *keys)
PY
```

The write is read-modify-replace on the whole file, so it preserves every other key. It is not concurrency-safe: another Claude Code session running at the same time holds `~/.claude.json` state in memory and will overwrite this on its next flush. If that happens, re-run the block.

If the script exits with the JSON error, report it — do not hand-edit `~/.claude.json`, and tell the user to run `claude` in the project once and accept the dialog instead.

## Step 8: Report

The scaffolded `README.md` documents the review gate, auto-fix, shipping, decision history, and every `.codereviewrc` key, so the report points there rather than restating it. Keep the report to what the user has to know or do now.

Always include:

- **What was created:** `./{{project-name}}/`, and the tools: ruff, ty, bandit, pytest, pre-commit. In agents-cli mode, say they're layered on the agents-cli stack and name the agent template and deployment target chosen. Also say that `CLAUDE.md` is agents-cli's own file with this skill's governance section appended, not a fresh file.
- **Workspace trust:** recorded in `~/.claude.json`, so the `.claude/settings.json` allowlist is live on first run with no trust dialog. Say this explicitly, because the user is entitled to know a scaffold granted its own pre-approvals. If Step 7 failed, say so and give its fallback.
- **What the agent files enforce,** in a sentence or two: Stop hooks block the agent from finishing while pre-commit fails or docs are stale; `git push` runs a two-pass agentic review that blocks on REQUIRED findings and auto-fixes them by default; `make ship` and `make deploy` always prompt, and in agents-cli mode so do `agents-cli deploy`, `infra` and `publish`.
- **Fixes applied in Step 6:** what `pre-commit run --all-files` changed, especially in agents-cli's generated files.
- **First push:** the scaffold creates no remote. Give `git push -u origin main develop`, then `gh repo edit --default-branch develop` (or `az repos update --repository <repo> --default-branch develop`), then `git remote set-head origin develop`. `/ship` fails its preflight until `origin/develop` exists.
- **Squash warning,** on its own line: squash merges drop decision trailers unless they're copied into the squash commit. Turn squash off for `develop` (Azure DevOps: "Limit merge types" in the branch policy, clear "Squash merge"; GitHub: clear "Allow squash merging"), then set `pr_merge_method=merge` (or `rebase`) in `.codereviewrc`. `/ship` keeps the trailers when it squashes; a web-UI squash doesn't.
- **Team onboarding:** clone and run `make setup` (both modes). Use `make ship-stage STAGE=<stage>` to change how far `/ship` goes (default `open_pr`). In agents-cli mode, also install the CLI once (`uv tool install google-agents-cli`) for `agents-cli playground`, `eval` and `deploy`.
- **`google-agents-cli`:** installed, or not installed because its marketplace isn't registered (Step 5).

Include when it applies:

- **Deploy verification** (agents-cli with `cloud_run` or `agent_runtime`): `deploy_provider`, `deploy_region` and `deploy_name` are prefilled in `.codereviewrc`; `deploy_pipeline`, `deploy_project` and `deploy_smoke` still need filling in before `/ship verify_deploy` works. Say whether SHA tagging was applied (and where), skipped because the expected deploy code wasn't found, declined, or not offered (Prototype depth). With Full depth, also say that the generated `staging.yaml` deploys on pushes to `main`, while `/ship` merges into `develop` and looks for the run there; add `develop` to the workflow's `on.push.branches` if `verify_deploy` should find it.
- **`make run-check`:** in agents-cli mode, whether the target still points at the right entry point after Step 4's check.

End with one line pointing at `README.md` for the review settings, shipping, and decision history.
