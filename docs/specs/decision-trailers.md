# Spec: decision history in commit trailers

Status: built in skill version 3.1.0. The Claude Code hook, the prepare-commit-msg hook and `scripts/decisions.sh` were tested in a scratch repo. The `/ship` squash message was checked for syntax only, not against a live `gh` or `az` merge.

## Goal

A decision made months ago should reach whoever is about to undo it. Today it doesn't. `docs/design.md` describes the current design and is rewritten to stay in sync, so the reasons behind an old choice, and the alternatives that were ruled out, get edited away. Code comments churn with the code. Git history keeps the reasoning, but nobody reads it before a change, and agent-written commit messages are mostly "fix lint" and "address review".

So decisions are recorded where they happen, in the commit that makes them, and are shown back by path to the agent, the developer and the reviewer when that code changes.

## Decisions already made

- Decisions live in git trailers on commit messages. There's no `docs/decisions/` directory and no JSONL log, both of which grow without bound, conflict when two branches append, and need a scope field to be found.
- `git notes` aren't used. They aren't pushed or fetched by default, and most tools ignore them.
- Lookup is by path, `git log -- <paths>`, so it's scoped to the code being touched without a separate index.
- The trailer keys are `Decision:`, `Rejected:`, `Agent:` and an optional `Session:`. Author and date come from the commit.
- Session references are optional. Claude Code transcripts are local to one machine and expire, so the `Decision:` line has to stand on its own.
- `docs/` stays the source of truth. A recorded decision explains why the docs and code are the way they are, but when it conflicts with `docs/`, the docs win.
- Project-wide decisions still go in the Trade-offs section of `docs/design.md`. Trailers hold the ones scoped to particular code.
- The squash-merge risk is handled with a warning, not by changing `/ship`'s `pr_merge_method=squash` default. `/ship` writes the squash commit message itself so its own merges keep the trailers.
- Only the review blocks. Every other surfacing point informs and never fails.

## Trailer format

The scaffolded `README.md` ("Decision history") is the canonical definition. `CLAUDE.md` states when the agent adds trailers and links to it. The ship skill and `scripts/decisions.sh` link to it rather than restating it.

```
Route all Firestore writes through the repository layer

- Move direct client calls in handlers to repo/

Decision: All Firestore writes go through repo/ so transactions are enforced in one place
Rejected: Per-handler transactions (duplicated retry logic)
Agent: claude-opus-5-5
Co-Authored-By: ...
```

Git parses trailers only from the message's final paragraph, so they sit in the same block as `Co-Authored-By:` with no blank line between them. Key matching is case-insensitive.

A commit gets decision trailers when it carries the outcome of a design interview (the `CLAUDE.md` design-proposal rule), takes a deliberate shortcut, or reverses an earlier decision. Reversing means committing a new `Decision:` that says what changed. The newer entry supersedes the older one, and nothing is edited or deleted.

## Components

| File | Role |
|---|---|
| `scripts/decisions.sh` | The one lookup everything else calls. `[--limit N] [--range R] [--] [<path>...]` prints one entry per commit with a `Decision:` or `Rejected:` trailer, newest first. A single file path adds `--follow`. `--trailers --range R` prints just the unique trailer lines, oldest first, as a block that can end a commit message |
| `scripts/decisions-hook.sh` | Claude Code `PreToolUse` hook on `^(Edit\|Write)$` |
| `scripts/decisions-commit-msg.sh` | pre-commit hook at the `prepare-commit-msg` stage |
| `scripts/code-review.sh` | Pass 2 gets the decisions on the changed paths |
| `scripts/ship.sh` | Adds a Decisions section to the PR description and writes the squash commit message |

## Where decisions surface

### Agent edits a file

`decisions-hook.sh` reads `tool_input.file_path` and `session_id` from the hook payload. It runs once per file per session, tracked in `$TMPDIR/claude-decisions-<session_id>`. If the file has decisions, it returns:

- `hookSpecificOutput.additionalContext`: up to 10 entries and a pointer to `CLAUDE.md` ("Decision history"). The context carries data only. The rule for a conflicting change (stop, ask, record a confirmed reversal with a trailer) lives in `CLAUDE.md`, because text arriving next to a tool result that tells the agent what to do can read as a prompt injection, and these entries come from commit messages.
- `systemMessage`: one line for the developer, with the count, the newest decision and its commit.

It sets no `permissionDecision`, so the normal permission flow is unchanged. The payload is parsed with `grep` and `sed`, like the other hook scripts, because `jq` isn't guaranteed. A path containing a double quote is skipped.

Claude Code delivers `additionalContext` for PreToolUse alongside the tool result, so the agent reads the decisions just after its first edit to the file, not before it. Blocking that first edit (exit 2 with the decisions on stderr) would put them in front of the agent before the edit, but it would show a denied tool call on every first touch of a file with history. The `CLAUDE.md` rule covers the gap: on a conflict, the agent stops and asks.

### Developer writes a commit message

`decisions-commit-msg.sh` runs `decisions.sh --limit 15` on the staged files and adds the output to the message file as comment lines, using `core.commentChar` (with `#` for unset or `auto`). With `git commit -v` the block goes above the scissors line, since git drops everything below it.

It only acts when git will strip comments. That means the message source (`PRE_COMMIT_COMMIT_MSG_SOURCE`) is empty or `template`, and `commit.cleanup` is unset, `default` or `strip`. For `-m`, `-F`, merges, squashes and `--amend`, the message may not be edited, and git would keep the comment lines in the commit. Agents commit with `-m`, so this hook is for humans.

`default_install_hook_types` includes `prepare-commit-msg`, so `pre-commit install` (and `make setup`) installs it with the other stages.

### Code review on push

Before pass 2, `code-review.sh` runs `decisions.sh --limit 40` on the paths changed in the review range and puts the output in the prompt. Doing the lookup in the script, not leaving it to the agent, matters because the review agent's tools allow only plain `git log`, and the trailer format string is easy to get wrong.

Pass 2 gets one more check: nothing reverses a recorded decision, or brings back an alternative it rejected, unless a commit in the range records a superseding `Decision:`. A reversal with no superseding trailer is REQUIRED, and the finding quotes the trailer and its commit. Entries from commits inside the range are the change's own decisions.

### PR and merge

`pr_body` adds a Decisions section, the `decisions.sh` output for `origin/develop..HEAD`, when there is one.

When the merge stage squashes and the branch has trailers, `squash_body` builds the squash commit message: the commit subjects, a blank line, then `decisions.sh --trailers`, so the trailers end up in the final paragraph. `gh` gets it through `gh pr merge --body`; `az` through `az repos pr update --merge-commit-message`, with the subject `Merged PR <id>: <branch>`. With no trailers, nothing is passed and the host's default message stands.

## Squash merges

A squash from the host's web UI keeps only what its message editor holds, and by default that drops the trailers. The scaffolded `README.md` and the scaffold's final report both warn about this. They recommend turning off squash merging for `develop` (ADO: "Limit merge types" in the branch policy; GitHub: clear "Allow squash merging") and setting `pr_merge_method=merge` or `rebase` in `.codereviewrc`, because the `squash` default would otherwise fail to arm auto-merge.

## Out of scope

- A decision index or search across the whole repo. `scripts/decisions.sh` with no paths lists everything, which is enough.
- Adding trailers to existing history.
- Validating the trailer format in a commit-msg hook.
- Cross-cutting decisions that no path captures. Those go in `docs/design.md`.
