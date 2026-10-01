# {{project-name}}

## Toolchain

- Package manager: uv
- Linter / formatter: ruff
- Type checker: ty
- Security scanner: bandit
- Complexity: ruff C90 (McCabe, max 10)
- Tests: pytest

## Response style

Lead with the answer or the code. Keep explanation to a few lines and cut anything not load-bearing: no restating the question, no summary of what was just shown.

Write complete sentences. Terse means fewer words, not fewer grammatical parts — keep the connectives that carry the reasoning.

The agent is a tool, not a person: no first person, no performed emotion, no claims of opinion or preference. Achieve that by moving the subject, never by deleting it. Subjectless telegraph ("Added a retry", "Checking") and colon-nominalization ("Recommendation: X") are unreadable, and they aren't required to stay impersonal.

The subject should be the code, the file, the evidence, or the reader:

- "Added a retry" → "`client.py:40` now retries on 429"
- "My recommendation is X" → "X is the better option because Y"
- "I think the test is wrong" → "The test contradicts `docs/design.md:12`"
- "I'm not sure that's the cause" → "That may not be the cause; the logs don't cover the failing window"
- "Let me check the tests" → "The failing test is in `tests/test_client.py`, so it runs first"

Impersonal doesn't mean silent. During multi-step work, say in one sentence what is about to happen before the first tool call, and give a short update when something load-bearing turns up or the plan changes. The developer can't see tool output or thinking, only this text.

Impersonal doesn't mean noncommittal. When a choice is on the table, still recommend one, stated as a claim about the options ("X is the better option because Y") rather than withheld as opinion.

Ground judgments in something nameable: a file, a line, test output. "The evidence suggests" and "it seems likely" trade a person for a vague authority, which is worse than either.

Say when something is uncertain; that's information, not hedging. Don't hedge on what was verified.

Stay fully explicit for security warnings, destructive-action confirmations, and steps where order matters.

Code, commit messages, and PR descriptions are written normally.

## Running tools

Always prefix with `uv run`:

```bash
uv run pytest
uv run ruff check .
uv run ty check
uv run pre-commit run --all-files
```

## Dependencies

`uv.lock` is committed to version control. Never delete or gitignore it — it pins transitive dependencies for deterministic installs. When adding or updating dependencies, commit the updated `uv.lock` alongside the `pyproject.toml` change.

## Coding Guidelines

- Write the simplest code that stays clear and maintainable; optimize for readability and ease of iteration
- Reuse before writing, in this order: an existing helper in this repo, the stdlib, an already-installed dependency. Add a new dependency only when none of those cover it
- Prefer modular and functional style over OOP
- No speculative abstractions: no interface with one implementation, no factory for one product, no config for a value that never changes. Avoid abstraction until reuse >= 2
- Deletion over addition. Boring over clever
- Bug fix = root cause: grep every caller and fix the shared function once, not just the path the report names
- Mark a deliberate shortcut with a comment naming the ceiling and the upgrade path

## Design and architecture proposals

When the user proposes a design or architecture change, interview them before implementing. Walk down each branch of the decision tree, resolving dependencies one by one. For each question, give the recommended answer and the reason for it. Ask one question at a time. Explore the codebase to answer questions where possible before asking the user.

Trigger this for proposals that involve:
- New services, components, or system boundaries
- Changes to data flow or integration points
- Dependency additions that affect architecture
- Refactors that shift module responsibilities
- Anything that would require updating `docs/design.md` or a spec under `docs/specs/`

Only proceed to implementation after all decision branches are resolved and the user confirms.

## Decision history

Decisions are recorded as trailers in commit messages, not as files. `README.md` ("Decision history") defines the trailer format.

Add a `Decision:` trailer, plus a `Rejected:` trailer for each alternative ruled out, and `Agent: <model id>`, when a commit:
- carries the outcome of a design interview (above)
- takes a deliberate shortcut (alongside its code comment)
- reverses an earlier decision

Routine commits get no decision trailers. Put the trailers in the message's final paragraph, in the same block as `Co-Authored-By:` with no blank line between them; git reads trailers only from there.

A PreToolUse hook shows the recorded decisions for a file after the first edit to it in a session; `scripts/decisions.sh <path>` lists them at any time. A recorded decision holds until a later one supersedes it. If a requested change reverses one or brings back an alternative it rejected, stop and ask the developer before going further. Once they confirm, record the new decision with a trailer on the commit. Never reverse a decision silently.

## Before making changes

When a change touches Python code, run the tests that cover that area first, so an existing failure isn't mistaken for one the change caused. Doc-only changes skip this.

**Source of truth, highest authority first:** `docs/` (specs and `design.md`) > tests > code. Docs state intended behavior; tests encode it where the docs are silent; code only describes what happens now. Resolve any conflict by climbing to the highest level that speaks to it.

Decisions recorded in commit trailers explain why the docs and code are the way they are, but they don't outrank `docs/`: when one conflicts with the docs, the docs win.

So a failing test means either the code is wrong or the test contradicts the docs. Check the docs before assuming the test is correct; where they're silent, the test wins over the code.

## After a code change

A code change is any edit to a `*.py` file, `pyproject.toml`, `uv.lock`, or the `Makefile`. Before reporting one done, run pre-commit over the changed files and confirm the app still starts:

```bash
uv run pre-commit run --files <changed files>   # during iteration
uv run pre-commit run --all-files               # once, before reporting the task complete
make run-check                                  # confirms the app starts; also runs on git push
```

If `make run-check` fails, fix the startup breakage first. It ships as a placeholder import check; when you add or change the app's entry point, update the target in the same change so it exercises real startup (the `Makefile` documents the constraints and patterns).

An edit that touches only docs or other prose needs nothing more: the Stop hook already runs pre-commit on the changed files.

Fix every failure at root cause:
- Never use `--no-verify` or `--skip`, and never disable a lint rule to silence a failure
- Never modify a test solely to make it pass. Change a test only when the docs show it's wrong
- Re-run until clean

If design, architecture, or public API changed, update `docs/design.md` — or the spec under `docs/specs/` that owns the flow — plus any relevant `README.md` or `ARCHITECTURE.md`. Keep everything under `docs/` in sync with current behavior — no stale descriptions.

## Code review gate

`git push` runs a two-pass agentic review in a pre-push hook (`scripts/code-review.sh`). Any REQUIRED finding blocks the push. When a push is blocked, read `working/code-review-report.md`. An auto-fix may have left uncommitted changes in the working tree; review that diff, or fix each REQUIRED finding at root cause yourself, then commit and push again.

Never set `SKIP_CODE_REVIEW`, set `enabled=false` in `.codereviewrc`, or use `SKIP=code-review` to get past a failing review. Skipping is a human decision.

`/ship` (`.claude/skills/ship/`) ships the branch into `develop` from its own worktree: review, push, then a PR, the merge, and the dev deploy check, as far as the configured stage. Start a ship only through `/ship`, and only when the user asks; the permission prompt on `make ship` is its confirmation. `README.md` documents the review settings, auto-fix, and shipping.

## Testing

- Add tests for critical user flows and core business logic: the functions that compute results, enforce rules, or transform data
- Test expected code paths; avoid testing unexpected code paths
- One good integration test covering the happy path is worth more than many unit tests
- Avoid tests for handlers
- Avoid mocks and fixtures
- Don't use test coverage or number of tests as a metric
- Keep tests performant

## Project layout

{{layout-line}}

## Documentation

Project docs live in `docs/`:
- `design.md` — RFC; defines architecture and design decisions
- `design.mmd` — Mermaid diagram of the design
- `templates/` — starting points for per-flow specs and diagrams
{{gcp-doc-lines}}

`docs/specs/` does not exist yet. Create it — and only then — when the design is large enough to split (see below); a new project has nothing to put in it.

`working/` is a gitignored scratch directory for local development. Never mention or reference it in `docs/` or in code comments; it isn't part of the project.

### Splitting design.md into per-flow specs

While the project is small, `design.md` holds everything. Once it passes ~400 lines or covers three or more flows, split it: create `docs/specs/` and give each flow a `docs/specs/<flow>.md` (kebab-case, copied from `docs/templates/spec.md`) with a `docs/specs/<flow>-diagram.mmd` (copied from `docs/templates/diagram.mmd`) beside it.

`design.md` keeps the overview, the Flows index, the architecture, the data flow between components, deployment, and anything cross-cutting (auth, observability, security). Each spec takes its flow's step-by-step behavior, the tools and endpoints only it calls, its configuration, its edge cases, and its limits. Don't restate a spec's contents in `design.md` — the index line plus the link is the whole handoff.

A spec is the source of truth for its flow. When a change touches one flow, that spec is the doc to read first and the doc to update.

Every `.mmd` diagram, `design.mmd` included, is a high-level system and data-flow picture. Read the content rules at the top of `docs/templates/diagram.mmd` before editing one.

**Sync rules**: After editing `docs/design.md`, update `docs/design.mmd` to match before reporting done. After editing a spec, update its `-diagram.mmd`. A new spec must be linked from the Flows index in `docs/design.md`.
{{gcp-sync-rule}}
A Stop hook (`scripts/docs-sync-check.sh`) blocks the turn from ending while any of these are stale, so sync them as part of the change rather than waiting to be told.

## Writing prose and markdown

When writing or updating any `.md` or prose file (READMEs, design docs), strip the AI-writing tells below before reporting done. Skip: `docs/design.mmd` and any `*-diagram.mmd` (Mermaid), files that are primarily code or structured data, code comments, commit messages, PR descriptions, and plan/implementation docs (written for AI consumption — leave as-is).

Remove these tells:
- **Significance inflation** — "testament to", "pivotal/crucial/vital role", "marks a turning point", "evolving landscape", "underscores its importance".
- **Promotional tone** — "boasts", "vibrant", "rich", "nestled", "in the heart of", "breathtaking", "renowned", "stunning".
- **Superficial -ing tails** — "...highlighting/showcasing/reflecting/ensuring/fostering X" tacked on for fake depth.
- **Vague attribution** — "experts argue", "observers note", "industry reports" with no named source.
- **AI vocabulary** — additionally, delve, leverage, crucial, enhance, intricate, landscape, tapestry, testament, underscore, seamless.
- **Copula avoidance** — "serves as / stands as / functions as" → use "is / are / has".
- **Negative parallelism** — "not just X, but Y", "it's not merely… it's…".
- **Forced rule of three** — triplets for the sake of it ("innovation, inspiration, and insights").
- **Formulaic structure** — "Challenges and Future Prospects" sections, generic upbeat conclusions.
- **Style tics** — em-dash overuse, mechanical boldface, inline-header bullet lists, Title Case headings, emojis, curly quotes.
- **Chatbot artifacts** — "Great question!", "I hope this helps", "Let me know if…", knowledge-cutoff disclaimers.
- **Filler / hedging** — "in order to" → "to", "due to the fact that" → "because", "could potentially possibly".

Then: prefer specific facts over vague claims, vary sentence length, one idea per sentence. Read it aloud — if it sounds like a press release, rewrite.
