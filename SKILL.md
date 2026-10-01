---
name: scaffold
version: 3.2.0
description: |
  Create a new Python project using uv with pre-commit, ruff, ty, bandit, and pytest
  configured and ready to use. Prompts for project name and layout (single package or monorepo).
  For GCP projects, optionally scaffolds with Google's agent-starter-pack (ADK/LangGraph
  agent templates, Cloud Run/Agent Engine/GKE deployment, Terraform, CI/CD) and layers this
  skill's tooling on top. Generates CLAUDE.md and .claude/settings.json to enforce pre-commit
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

# Python GCP Agentic Project Skill

Scaffold a Python project with ruff, ty, bandit, pytest, pre-commit, and agent instruction files. For GCP projects, optionally hands base scaffolding to Google's [agent-starter-pack](https://github.com/GoogleCloudPlatform/agent-starter-pack) and layers this skill's lint/pre-commit/code-review/docs tooling on top rather than replacing it.

Templates: `~/.claude/skills/python-gcp-agentic-project-skill/templates/` (plain scaffold), `~/.claude/skills/python-gcp-agentic-project-skill/templates/asp/` (agent-starter-pack addenda)
Placeholders: `{{project-name}}`, `{{package_name}}`, `{{code-dir}}`, `{{test-dir}}`, `{{layout-line}}`, `{{gcp-doc-lines}}`, `{{gcp-sync-rule}}`, `{{lint-target}}`, `{{bandit-exclude-arg}}`, and (ASP mode) `{{asp-agent}}`, `{{asp-deployment-target}}`, `{{asp-depth-flag}}`

## Step 1: Gather inputs

Use project name from args if provided, else ask.

Ask "GCP scope?" via `AskUserQuestion` (single question, one call):
- **Not a GCP project**: no GCP docs, no agent-starter-pack.
- **GCP project**: plain `uv`-scaffolded project, GCP cost/infra docs included.
- **GCP project via agent-starter-pack**: scaffold with Google's [agent-starter-pack](https://github.com/GoogleCloudPlatform/agent-starter-pack) (ADK/LangGraph agent templates, Cloud Run/Agent Engine/GKE deployment, Terraform, CI/CD), then layer this skill's lint/pre-commit/code-review/docs tooling on top.

Set `{{gcp}}` = true for either GCP option, `{{asp}}` = true only for the agent-starter-pack option.

Every project gets the `/ship` pipeline, which opens PRs into and merges into `develop` and verifies the dev deploy. Step 6 makes `develop` the default branch.

### If `{{asp}}`

Ask via `AskUserQuestion` (up to 3 questions, one call):
- **Agent template** (`-a`): offer `adk` (ReAct agent via ADK — recommended default), `langgraph` (ReAct agent via LangGraph), `agentic_rag` (RAG agent, Vertex AI Search/Vector Search), `adk_a2a` (Agent-to-Agent protocol). User can pick "Other" and give any template id agent-starter-pack accepts (a local name, an `adk@`/`adk-py@` shortcut, or a remote Git URL).
- **Deployment target** (`-d`): `agent_engine` (recommended default), `cloud_run`, `gke`, `none`.
- **Scaffold depth**: `Prototype` (recommended for exploration — `--prototype`, no CI/CD or Terraform, fastest to iterate) or `Full` (CI/CD + Terraform via GitHub Actions — production-ready pipeline, more setup).

Skip the layout question entirely — agent-starter-pack owns the directory layout.

If the deployment target is `cloud_run` or `agent_engine`, then ask via `AskUserQuestion`: "Tag deploys with the commit SHA? (Recommended: yes)". Yes lets `/ship`'s `verify_deploy` stage confirm the deployed revision is the merged commit (`deploy_match=sha`); no makes it fall back to timing checks (`deploy_match` unset, meaning `time`). Set `{{sha-tagging}}` from the answer. Skip the question for `gke`, `none`, and the plain scaffold, which has no generated deploy.

Set:
- `{{code-dir}}`: `app` (agent-starter-pack's default agent directory)
- `{{test-dir}}`: `tests/unit` — **not** `tests/integration` or `tests/eval`. Confirmed by dry run: agent-starter-pack's own `tests/integration/` makes live Vertex AI calls and fails with a 403 the moment there's no GCP project/credentials configured, which a fresh scaffold never has. Gating every `git push` on that would block the pre-push hook out of the box. `make test` (agent-starter-pack's own target, unchanged) still runs `tests/unit` + `tests/integration` for whoever has real credentials; only this skill's pre-push pytest hook is scoped down. `tests/eval` holds ADK evalsets, run via `make eval`, and was never in scope for either.
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

**agent-starter-pack (`{{asp}}`):**
```bash
uvx agent-starter-pack create {{project-name}} \
  -a {{asp-agent}} \
  -d {{asp-deployment-target}} \
  --agent-guidance-filename CLAUDE.md \
  -y -s \
  {{asp-depth-flag}}
cd {{project-name}}
```
`{{asp-depth-flag}}` is `--prototype` for Prototype depth, or `--cicd-runner github_actions` for Full (this skill's own `ship.sh` assumes a `gh`/`az repos pr`-reachable host, so GitHub Actions is the consistent default; Cloud Build isn't offered as a choice here). `-s` skips agent-starter-pack's live GCP/Vertex AI auth checks — this is a scaffolding step, not a deploy step. `-y` accepts its own defaults for anything not covered by the flags above.

agent-starter-pack prints its own next steps (`make install`, `make playground`, etc.) — that output is expected and is not this skill's own report.

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

**agent-starter-pack:** its own `pyproject.toml` already carries `pytest` (in `dependency-groups.dev`) and `ruff`/`ty` (in `project.optional-dependencies.lint`, not the dev group — our pre-commit hooks call them with `--no-sync`, so they need to be in the dev group too):
```bash
uv add --dev ruff ty "bandit[toml]" pre-commit
```

**Plain scaffold:**
```bash
uv add --dev ruff ty "bandit[toml]" pytest pre-commit
```

## Step 4: Write config files

Read each template from `~/.claude/skills/python-gcp-agentic-project-skill/templates/`, substitute all placeholders, write to destination.

Notes:
- `uv init` (plain scaffold) and `agent-starter-pack create` (ASP scaffold) both pre-create `.gitignore`, `README.md`, and `pyproject.toml`. To overwrite a file, Read it first (the harness blocks overwrite-without-read), then Write. Where the table below says **append**, use Edit/Read + append instead — never overwrite a file agent-starter-pack owns.
- `pyproject-additions.toml` / `templates/asp/pyproject-bandit.toml` are appended, so each must start with a `[table]` header. Never add a bare top-level key (e.g. `requires-python`) at its top — it would leak into the last existing table and break the parse. Keep the `--python 3.12` flag on `uv init` (plain scaffold only) — without it uv picks whatever interpreter its `python-preference = "managed"` default resolves to, which can be older than 3.12 and silently lowers both `requires-python` and the ruff `target-version` inferred from it.

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

**agent-starter-pack scaffold (`{{asp}}`):** agent-starter-pack already owns `pyproject.toml`, `Makefile`, `README.md`, `CLAUDE.md`, and `.gitignore` — none of those are overwritten. This skill's tooling layers on top of them:

| Template | Destination | Mode |
|----------|------------|------|
| `templates/pre-commit-config.yaml` | `.pre-commit-config.yaml` | write — agent-starter-pack has no pre-commit config |
| `templates/asp/pyproject-bandit.toml` | `pyproject.toml` | append — only `[tool.bandit]`; agent-starter-pack already configures `[tool.ruff]`/`[tool.ty]`/`[tool.pytest.ini_options]`, and a duplicate TOML table header breaks the parse |
| `templates/asp/CLAUDE-addendum.md` | `CLAUDE.md` | append to the file agent-starter-pack generated (`--agent-guidance-filename CLAUDE.md` in Step 2 made this the guaranteed target) |
| `templates/asp/README-addendum.md` | `README.md` | append |
| `templates/asp/Makefile-addendum` | `Makefile` | append |
| `templates/asp/gitignore-addendum` | `.gitignore` | append — only the lines not already covered by agent-starter-pack's own `.gitignore` |
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
| `templates/docs/finops.md` | `docs/finops.md` | write — GCP is always true in ASP mode |
| `templates/docs/infra.md` | `docs/infra.md` | write |

`templates/asp/Makefile-addendum`'s `run-check` target assumes `{{code-dir}}/agent.py` (e.g. `app/agent.py`) is the agent's entry point, matching agent-starter-pack's default layout for the built-in templates. If the chosen template or `--agent-directory` places it elsewhere, fix the target before reporting done.

```bash
mkdir -p .claude/skills/ship docs/templates working scripts/lib
chmod +x scripts/code-review.sh scripts/ship.sh scripts/set-ship-stage.sh scripts/docs-sync-check.sh scripts/precommit-check.sh scripts/decisions.sh scripts/decisions-hook.sh scripts/decisions-commit-msg.sh
```

**Prefilled deploy settings (`{{asp}}` with `cloud_run` or `agent_engine`):** in the written `.codereviewrc`, set `deploy_provider=<deployment target>`, `deploy_region` to the region the generated deploy code uses (agent-starter-pack's default is `us-central1`), and `deploy_name` to the Cloud Run service name or Agent Engine display name that code deploys (read it from the generated `Makefile` `deploy` target or deploy script; it's normally the project name). Set `deploy_match=sha` if `{{sha-tagging}}` is yes. Leave `deploy_pipeline`, `deploy_project` and `deploy_smoke` empty: the scaffold doesn't know them. Skip this for every other target and for the plain scaffold.

**Tag deploys with the commit SHA (`{{sha-tagging}}` yes):** edit agent-starter-pack's generated deploy code so every deploy records the 12-character commit SHA that `/ship` checks against.
- `cloud_run`: add `--revision-suffix=$(git rev-parse --short=12 HEAD)` to each `gcloud ... run deploy` invocation (the `Makefile` `deploy` target, and any CI workflow under `.github/workflows/` that deploys). In a Makefile recipe, write it as `$$(git rev-parse --short=12 HEAD)`. The revision is then `<service>-<sha12>`. A redeploy of the same commit fails because that revision name exists; say so in the report.
- `agent_engine`: where the generated code creates or updates the reasoning engine, add a `commit` label set to the output of `git rev-parse --short=12 HEAD` (in CI, the checked-out commit).

After editing, grep for the flag or label to confirm the edit landed. If the expected deploy code isn't there (a different template or agent-starter-pack version), skip the edit, set `deploy_match` back to unset, and report that SHA tagging wasn't applied and why.

Do not create `docs/specs/`. It comes into existence when the design outgrows one file; `CLAUDE.md` carries the rule for creating it then, and `docs/templates/` carries the spec skeleton and diagram starting shape.

`working/` holds dirty files needed during development but never committed. The `.gitignore` template excludes it. The generated `CLAUDE.md` forbids mentioning `working/` in `docs/` or in code comments.

## Step 5: Install project skills

```bash
claude plugin install google-agents-cli --scope project 2>/dev/null || true
```

Humanizing is baked into `CLAUDE.md` directly (no `humanizer` skill needed).
`google-agents-cli` is best-effort: the install no-ops unless its marketplace is
already registered. Report it as installed only if the command above succeeded;
otherwise tell the user to add the marketplace first. In ASP mode, agent-starter-pack's
own CLI output names `google-agents-cli` as its successor — installing it here is
doubly relevant, not redundant with anything ASP already did.

## Step 6: Init git, install pre-commit hooks, create `develop`

```bash
git init -b main
uv run pre-commit install
git add .
git commit -m "Initial scaffold"
git checkout -b develop
```

`git init` on a directory `agent-starter-pack create` already initialized as a repo is a safe no-op. If that repo's branch isn't `main`, rename it first (`git branch -M main`). If it already has commits, the same steps apply: commit the scaffold on `main`, then branch `develop` from it.

The commit runs the pre-commit hooks. A hook that rewrites files (for example `end-of-file-fixer`) fails the commit; `git add .` and commit again. If git has no user identity configured, stop and report that rather than setting one.

`develop` is the branch `/ship` targets. The scaffold creates no remote, so the report gives the first-push commands that make `develop` the remote default too.

In ASP mode, run `uv run pre-commit run --all-files` once here and fix what it finds before reporting done — confirmed by dry run (agent-starter-pack v0.41.3, `adk` template): the `end-of-file-fixer` hook fixes `deployment_metadata.json` (expected, first-run only), and `ruff-check` fails on a pre-existing `RUF005` violation in agent-starter-pack's own generated `{{code-dir}}/agent_engine_app.py` (`register_operations`) — that file is agent-starter-pack's, not this skill's template, and `--unsafe-fixes` or a one-line manual edit clears it. Different agent-starter-pack templates or versions may generate different code; run the hooks and fix whatever they actually report rather than assuming this exact finding.

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

- **What was created:** `./{{project-name}}/`, and the tools: ruff, ty, bandit, pytest, pre-commit. In ASP mode, say they're layered on the agent-starter-pack stack and name the agent template and deployment target chosen. Also say that `CLAUDE.md` is agent-starter-pack's own file with this skill's governance section appended, not a fresh file.
- **Workspace trust:** recorded in `~/.claude.json`, so the `.claude/settings.json` allowlist is live on first run with no trust dialog. Say this explicitly, because the user is entitled to know a scaffold granted its own pre-approvals. If Step 7 failed, say so and give its fallback.
- **What the agent files enforce,** in a sentence or two: Stop hooks block the agent from finishing while pre-commit fails or docs are stale; `git push` runs a two-pass agentic review that blocks on REQUIRED findings and auto-fixes them by default; `make ship` and `make deploy` always prompt.
- **Fixes applied in Step 6:** what `pre-commit run --all-files` changed, especially in agent-starter-pack's generated files.
- **First push:** the scaffold creates no remote. Give `git push -u origin main develop`, then `gh repo edit --default-branch develop` (or `az repos update --repository <repo> --default-branch develop`), then `git remote set-head origin develop`. `/ship` fails its preflight until `origin/develop` exists.
- **Squash warning,** on its own line: squash merges drop decision trailers unless they're copied into the squash commit. Turn squash off for `develop` (Azure DevOps: "Limit merge types" in the branch policy, clear "Squash merge"; GitHub: clear "Allow squash merging"), then set `pr_merge_method=merge` (or `rebase`) in `.codereviewrc`. `/ship` keeps the trailers when it squashes; a web-UI squash doesn't.
- **Team onboarding:** plain scaffold, clone and run `make setup`. ASP mode, clone and run `make install && uv run pre-commit install`, and use `make ship-stage STAGE=<stage>` to change how far `/ship` goes (default `open_pr`).
- **`google-agents-cli`:** installed, or not installed because its marketplace isn't registered (Step 5).

Include when it applies:

- **Deploy verification** (ASP with `cloud_run` or `agent_engine`): `deploy_provider`, `deploy_region` and `deploy_name` are prefilled in `.codereviewrc`; `deploy_pipeline`, `deploy_project` and `deploy_smoke` still need filling in before `/ship verify_deploy` works. Say whether SHA tagging was applied (and where), skipped because the expected deploy code wasn't found, or declined. For `cloud_run` with tagging, say that redeploying the same commit fails because the revision name already exists.
- **`make run-check`:** in ASP mode, whether the target still points at the right entry point after Step 4's check.

End with one line pointing at `README.md` for the review settings, shipping, and decision history.
