#!/usr/bin/env bash
# Two-pass agentic code review, run by the pre-push hook.
#   Pass 1: general review — correctness, security, missing tests, DRY,
#           YAGNI, library leverage, fit with the codebase.
#   Pass 2: spec conformance against the documents in docs/ and the
#           decisions recorded in commit trailers (scripts/decisions.sh).
# The passes are independent and run in parallel.
#
# Commits are reviewed once: the last passing commit per branch is recorded in
# .git/code-review-ledger (shared by every worktree, written under a lock), and
# later pushes review only new commits since.
# The full report is written to $report (gitignored).
#
# fix_enabled defaults to true: a failed review hands its REQUIRED findings
# (both passes combined) to a single fix agent that fixes or disputes each one,
# then a verification pass checks the fix, in a loop (fix_max_iterations
# rounds). Fixes are left uncommitted for review; the push stays blocked either
# way — a passing working tree isn't a passing commit yet.
#
# Config: .codereviewrc (key=value) — review_agent, review_model,
#         review_effort, review_spec_model, review_spec_effort, enabled,
#         command, fix_enabled, fix_agent, fix_model, fix_effort, fix_command,
#         agent_timeout. Any key can be
#         overridden for one push with CR_<KEY>, e.g. CR_REVIEW_MODEL=sonnet.
# Skip:   SKIP_CODE_REVIEW=true git push, or enabled=false in .codereviewrc.
# Base:   REVIEW_BASE_BRANCH replaces the default branch as a branch's
#         first-review base (ship.sh sets it to develop).
#
# `make ship` (scripts/ship.sh) runs this same hook from its own worktree, then
# opens a PR against the pushed commits. If the fix loop below resolves every
# REQUIRED finding, this hook still blocks the push (see $autofix_marker in
# lib/common.sh); ship.sh commits that fix and pushes again, up to
# ship_fix_retries times. A plain `git push` never does.
set -u

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

rc_file=".codereviewrc"
report="working/code-review-report.md"

# --- skip checks -------------------------------------------------------------

case "${SKIP_CODE_REVIEW:-}" in
    1 | true | TRUE | yes | YES)
        echo "SKIP_CODE_REVIEW set — skipping code review."
        exit 0
        ;;
esac

review_agent=$(rc_value review_agent)
# Set explicitly rather than inheriting the CLI's default model. Aliases
# (opus, sonnet) still move to each new release; a full model ID pins exactly.
# Pass 1 hunts for bugs nobody has named yet, the hardest job in the gate, so
# it gets the strongest model and a higher effort; a missed bug is invisible,
# and a false REQUIRED costs a fix and a verification round.
review_model=$(rc_value review_model)
review_effort=$(rc_value review_effort)
# Pass 2 and fix verification compare code against a stated doc or finding.
# Every call gets an explicit effort: the CLI default moves between releases,
# and effort levels don't mean the same amount of thinking across models.
review_spec_model=$(rc_value review_spec_model)
review_spec_effort=$(rc_value review_spec_effort)
enabled=$(rc_value enabled)
custom_cmd=$(rc_value command)

# Auto-fix: after a failed review, hand the REQUIRED findings to a fix agent
# that edits the working tree. On by default so a push keeps looping fix ->
# verify until nothing is open; fixes are always left uncommitted.
fix_enabled=$(rc_value fix_enabled)
fix_agent=$(rc_value fix_agent)
# The fixer works from findings that already name the file, the failure, and
# the change needed, and a verification pass checks its work.
fix_model=$(rc_value fix_model)
# Not low: at low effort a fixer is more likely to report a fix done without
# running the checks that exercise it.
fix_effort=$(rc_value fix_effort)
fix_cmd=$(rc_value fix_command)
fix_max_iterations=$(rc_value fix_max_iterations)
# Seconds any one agent call may run before it's killed and counted as failed.
agent_timeout=$(rc_value agent_timeout)

if [ "$enabled" = "false" ]; then
    echo "Code review disabled in $rc_file — skipping."
    exit 0
fi

# --- agent validation ---------------------------------------------------------
# Misconfiguration fails closed: a bad rc file must block the push and surface,
# not silently disable the gate. Only a missing CLI for a valid agent fails
# open, so one machine without the tool doesn't block everyone's pushes.

case "$review_agent" in
    claude) ;;
    custom)
        if [ -z "$custom_cmd" ]; then
            echo "ERROR: review_agent=custom requires command= in $rc_file — blocking push." >&2
            exit 1
        fi
        ;;
    *)
        echo "ERROR: unknown review_agent '$review_agent' in $rc_file (claude | custom) — blocking push." >&2
        exit 1
        ;;
esac

case "$agent_timeout" in
    '' | *[!0-9]* | 0)
        echo "ERROR: agent_timeout must be a positive integer (seconds) in $rc_file — blocking push." >&2
        exit 1
        ;;
esac

for effort_key in review_effort review_spec_effort fix_effort; do
    case "${!effort_key}" in
        low | medium | high | xhigh | max | default) ;;
        *)
            echo "ERROR: unknown $effort_key '${!effort_key}' in $rc_file (low | medium | high | xhigh | max | default) — blocking push." >&2
            exit 1
            ;;
    esac
done

# Validate the fix agent up front on the same fail-closed terms, but only when
# auto-fix is on. A missing claude CLI is handled at fix time (fail-open).
if [ "$fix_enabled" = "true" ]; then
    case "$fix_agent" in
        claude) ;;
        custom)
            if [ -z "$fix_cmd" ]; then
                echo "ERROR: fix_agent=custom requires fix_command= in $rc_file — blocking push." >&2
                exit 1
            fi
            ;;
        *)
            echo "ERROR: unknown fix_agent '$fix_agent' in $rc_file (claude | custom) — blocking push." >&2
            exit 1
            ;;
    esac
    case "$fix_max_iterations" in
        '' | *[!0-9]*)
            echo "ERROR: fix_max_iterations must be a positive integer in $rc_file — blocking push." >&2
            exit 1
            ;;
    esac
    if [ "$fix_max_iterations" -lt 1 ]; then
        echo "ERROR: fix_max_iterations must be >= 1 in $rc_file — blocking push." >&2
        exit 1
    fi
fi

if [ "$review_agent" = "claude" ] && ! command -v claude >/dev/null 2>&1; then
    echo "WARNING: 'claude' not found — skipping code review (fail-open)." >&2
    echo "Install it, or set review_agent=custom with command= in $rc_file." >&2
    exit 0
fi

# effort_flags_for <effort> sets $effort_flags: --effort <effort>, or nothing
# for "default", which leaves the CLI's own.
effort_flags_for() {
    effort_flags=()
    [ -n "${1:-}" ] && [ "$1" != default ] && effort_flags=(--effort "$1")
}

# run_review_agent <prompt> <model> <effort> prints the review to stdout; the
# review must end with "VERDICT: PASS" or "VERDICT: FAIL" as its final line. A custom command receives
# the prompt on stdin and ignores model and effort.
# git status is allowed: the verification prompt needs it to see untracked files
# the fixer added, and a headless -p run has no prompt to approve it with.
#
# Both agents are sandboxed the same way (claude_sandbox_flags):
#   --setting-sources user  keeps .claude/settings.json out: its Stop hooks would
#                           run pre-commit and the docs gate inside every pass,
#                           and its auto mode + allow rules would widen the tools.
#   --tools                 limits which built-in tools exist at all;
#                           --allowed-tools only pre-approves.
#   --permission-mode dontAsk  denies anything --allowed-tools doesn't cover.
# The prompt is an argument, so stdin is closed: otherwise -p waits on it.
claude_sandbox_flags=(--setting-sources user --permission-mode dontAsk)

run_review_agent() {
    local effort_flags
    effort_flags_for "$3"
    case "$review_agent" in
        claude)
            # ${a[@]+...}: bash 3.2 treats an empty array as unbound under set -u.
            with_timeout "$agent_timeout" claude -p "$1" --model "$2" ${effort_flags[@]+"${effort_flags[@]}"} "${claude_sandbox_flags[@]}" \
                --tools "Read,Grep,Glob,Bash" \
                --allowed-tools "Read,Grep,Glob,Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(git status:*)" < /dev/null
            ;;
        custom)
            printf '%s\n' "$1" | with_timeout "$agent_timeout" sh -c "$custom_cmd"
            ;;
    esac
}

# run_fix_agent reads the fix prompt as $1 and edits the working tree in place.
# Unlike the review agent it gets write tools, plus the checks it must not break;
# a custom command receives the prompt on stdin instead.
run_fix_agent() {
    local effort_flags
    effort_flags_for "$fix_effort"
    case "$fix_agent" in
        claude)
            with_timeout "$agent_timeout" claude -p "$1" --model "$fix_model" ${effort_flags[@]+"${effort_flags[@]}"} "${claude_sandbox_flags[@]}" \
                --tools "Read,Edit,Write,Grep,Glob,Bash" \
                --allowed-tools "Read,Edit,Write,Grep,Glob,Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(git status:*),Bash(uv run pytest:*),Bash(uv run pre-commit:*),Bash(make run-check:*)" < /dev/null
            ;;
        custom)
            printf '%s\n' "$1" | with_timeout "$agent_timeout" sh -c "$fix_cmd"
            ;;
    esac
}

# --- diff range --------------------------------------------------------------

zero_sha=0000000000000000000000000000000000000000
# Empty-tree hash: diff base for a brand-new repository's first push.
empty_tree=4b825dc642cb6eb9a060e54bf8d69288fbee4904

# Under pre-push, pre-commit exports the refs being pushed; prefer them so the
# review covers what actually goes to the remote, not the checked-out branch.
# Pin HEAD once up front: the passes run minutes apart, and a commit made
# mid-review must never be recorded as reviewed.
to_ref="${PRE_COMMIT_TO_REF:-}"
if [ "$to_ref" = "$zero_sha" ]; then
    echo "Ref deletion — nothing to review."
    exit 0
fi
head_sha=${to_ref:-$(git rev-parse HEAD)}
branch="${PRE_COMMIT_LOCAL_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"
branch=${branch#refs/heads/}
base_branch=${REVIEW_BASE_BRANCH:-$(default_branch)}

last_reviewed=$(ledger_get "$branch")

from_ref="${PRE_COMMIT_FROM_REF:-}"
[ "$from_ref" = "$zero_sha" ] && from_ref=""
# A remote sha we don't have locally (diverged force-push) can't be a base.
if [ -n "$from_ref" ] && ! git cat-file -e "$from_ref" 2>/dev/null; then
    from_ref=""
fi

if [ -n "$last_reviewed" ] && git merge-base --is-ancestor "$last_reviewed" "$head_sha" 2>/dev/null; then
    # Reviewed before: only new commits since the last passing review.
    base=$last_reviewed
elif [ -n "$from_ref" ]; then
    # pre-push: exactly the commits the remote doesn't have yet.
    base=$from_ref
elif [ -z "$to_ref" ] && base=$(git rev-parse -q --verify '@{upstream}' 2>/dev/null); then
    # Manual run (make review): everything not yet pushed upstream.
    :
elif base=$(git merge-base "origin/$base_branch" "$head_sha" 2>/dev/null) \
    || base=$(git merge-base "$base_branch" "$head_sha" 2>/dev/null); then
    # First review of a branch: the whole branch vs the default branch.
    :
elif [ -z "$(git for-each-ref refs/remotes)" ]; then
    # Brand-new repository with no remote branches: everything is new.
    base=$empty_tree
else
    echo "ERROR: cannot determine a review base — branch '$base_branch' not found." >&2
    echo "Set the remote default branch (git remote set-head origin -a) and retry." >&2
    exit 1
fi
range="$base..$head_sha"

# An error here must block, not skip: an unresolvable range looks identical to
# an empty diff on stdout, and silence would wave unreviewed commits through.
if ! changed=$(git diff --name-only "$range" 2>&1); then
    echo "ERROR: git diff $range failed — blocking push (cannot tell what is unreviewed):" >&2
    echo "$changed" >&2
    exit 1
fi
if [ -z "$changed" ]; then
    echo "No unreviewed changes in $range — skipping code review."
    exit 0
fi

# --- review passes -----------------------------------------------------------

mkdir -p working
# Cleared unconditionally so a stale marker from an earlier, unrelated blocked
# push can never be mistaken for this run's outcome — see common.sh.
rm -f "$autofix_marker"
{
    echo "# Code review report"
    echo
    echo "- Branch: \`$branch\`"
    echo "- Range: \`$range\`"
    echo "- Review agent: \`$review_agent\`"
    [ "$review_agent" = "claude" ] && echo "- Models: pass 1 \`$review_model\` (effort \`$review_effort\`), pass 2 and verification \`$review_spec_model\` (effort \`$review_spec_effort\`), fix \`$fix_model\` (effort \`$fix_effort\`)"
    [ "$fix_enabled" = "true" ] && echo "- Fix agent: \`$fix_agent\`"
    echo "- Date: $(date '+%Y-%m-%d %H:%M:%S')"
} > "$report"

# finish_pass <title> <output-file> <agent-exit-status> — appends the pass
# output to the report. Returns 0 only if the agent exited 0 and the LAST
# NON-EMPTY line of the output is "VERDICT: PASS" — a verdict quoted or drafted
# mid-output must not count. Markdown emphasis and backticks are stripped first,
# so "**VERDICT: PASS**" counts; a verdict anywhere but the end does not.
finish_pass() {
    local title=$1 file=$2 status=$3 output
    output=$(cat "$file")
    {
        echo
        echo "## $title"
        echo
        echo "$output"
    } >> "$report"
    if [ "$status" -eq 124 ]; then
        echo "Agent timed out after ${agent_timeout}s (agent_timeout) during $title — see $report" >&2
        return 1
    fi
    if [ "$status" -ne 0 ]; then
        echo "Agent failed (exit $status) during $title — see $report" >&2
        return 1
    fi
    printf '%s\n' "$output" | grep -v '^[[:space:]]*$' | tail -n 1 | tr -d '*`' |
        grep -q '^[[:space:]]*VERDICT: PASS[[:space:]]*$'
}

# show_pass <title> <output-file> <ok> — prints a pass's review so the results
# are readable in the terminal, pass or fail, not just in the report. Capped:
# a finding-heavy review can overflow stdout, and agent harnesses truncate
# long hook output — losing the verdict and "push blocked" lines printed
# after the passes. The full text is always in the report.
show_limit=100
show_pass() {
    local verdict=FAILED
    [ "$3" = 1 ] && verdict=PASSED
    echo ""
    echo "==== $1 — $verdict ===="
    head -n "$show_limit" "$2"
    if [ "$(wc -l < "$2")" -gt "$show_limit" ]; then
        echo "[... truncated at $show_limit lines — full pass output in $report]"
    fi
}

# The most recent review's or verification's open findings, and the fixer's
# latest summary. Stable gitignored files rather than temp
# files: the agents read them, and a path inside the project needs no extra
# directory access in a headless run.
findings_file="working/code-review-findings.md"
fix_summary_file="working/code-review-fix-summary.md"

# The REQUIRED bar for code findings, shared by pass 1 and the fix verification
# so a fix is judged by the same standard as the code it fixes.
read -r -d '' required_bar <<'EOF' || true
REQUIRED is limited to:
- a correctness bug
- a security vulnerability
- data loss or corruption
- a critical flow or core logic left untested, per CLAUDE.md

Every REQUIRED finding must state a concrete failure scenario: the input or
state, and the wrong result it produces (for a missing test, the untested flow
and what could regress unnoticed). A finding with no concrete scenario is
SUGGESTED.
EOF

# Closing instruction for every review-agent prompt; finish_pass enforces it.
read -r -d '' verdict_rule <<'EOF' || true
End with your verdict, as plain text with no bold, backticks, or other
formatting. The very last line of your output must be exactly VERDICT: PASS if
there are no REQUIRED or OPEN findings, otherwise exactly VERDICT: FAIL. Write
nothing after it — no summary sentence, no closing remark. A verdict placed
anywhere but the last line, or wrapped in formatting, is read as FAIL and
blocks the push.
EOF

# run_review runs both passes over the committed range, prints and reports the
# outcome, and writes $findings_file.
#   $1 — the git range to review (e.g. "A..B")
# The passes are independent (each only reads the diff and repo files), so run
# them concurrently and append their report sections in order. Returns 0 only if
# both passes pass.
run_review() {
    local range=$1
    local p1 p2 o1 o2 s1 s2 ok1 ok2 pid1 pid2 decisions
    local paths=()

    # Inlined rather than left to the agent: it only has git log, and the
    # trailer query is easy to get subtly wrong.
    while IFS= read -r f; do
        [ -n "$f" ] && paths+=("$f")
    done <<< "$(git diff --name-only "$range")"
    decisions=$(bash "$script_dir/decisions.sh" --limit 40 -- ${paths[@]+"${paths[@]}"})
    [ -n "$decisions" ] || decisions="None recorded."

    # read -d '' (not $(cat <<EOF)): bash 3.2 mis-parses quotes inside heredocs
    # nested in command substitutions.
    read -r -d '' p1 <<EOF || true
You are performing pass 1 of 2 of a pre-push code review for this repository.

Scope: the changes in git range $range. Start with:
    git diff $range
Read surrounding source files as needed for context, and read CLAUDE.md for
this project's coding and testing guidelines.

Review the changes for, in priority order:
- Correctness: logic errors, wrong conditions or boundaries, unhandled None or
  empty inputs, broken error handling, race conditions, callers the change breaks
- Security (injection, secrets in code, unsafe deserialization, path traversal, etc.)
- Missing tests: gaps per the testing guidance in CLAUDE.md (critical flows and core logic need tests; handlers and unexpected paths do not)
- DRY: duplicated logic that should be extracted or should reuse an existing function
- YAGNI: speculative abstractions, unused flexibility, code with no current need
- Library leverage: hand-rolled code where the stdlib or an already-installed dependency does the job
- Whether the change makes sense in the context of the codebase

Style and formatting are out of scope: ruff, ty, and bandit already gate them.

Report every finding as a markdown bullet:
- **REQUIRED** or **SUGGESTED** — \`file:line\` — what is wrong, the failure scenario (REQUIRED only), and what change is needed

$required_bar
DRY, YAGNI, library-leverage, and fit findings are SUGGESTED unless they also
cause one of the failures above.
If there are no findings, say so.

$verdict_rule
EOF

    read -r -d '' p2 <<EOF || true
You are performing pass 2 of 2 of a pre-push code review for this repository:
spec conformance.

Scope: the changes in git range $range. Start with:
    git diff $range
Then read docs/design.md. If docs/specs/ holds per-flow specs, read the ones
covering the flows this change touches (design.md's Flows index maps them);
each is the source of truth for its own flow. Read any other document in docs/
that bears on the change.

Check that the changed code conforms to the intent laid out in the specs:
- Architecture and component boundaries match docs/design.md
- Per-flow behavior matches the flow's spec under docs/specs/
- Data flow and integration points match the documented design
- Nothing contradicts documented decisions or constraints
- Nothing reverses a recorded decision below, or brings back an alternative it
  rejected, unless a commit in $range records a new Decision trailer that
  supersedes it
- If the change alters design, architecture, or public API, the docs were updated in the same change

Decisions recorded in commit trailers on the changed paths, newest first
(README.md, "Decision history"). Entries from commits inside $range are this
change's own. When a recorded decision and docs/ disagree, docs/ wins.

$decisions

Where the specs are silent on an area, that is not a finding. Only deviations
from documented intent count.

Report every finding as a markdown bullet:
- **REQUIRED** or **SUGGESTED** — \`file:line\` (or doc section) — the spec statement, the deviation, and what change is needed

REQUIRED is limited to code that directly contradicts a documented statement,
code that reverses a recorded decision with no superseding Decision trailer in
the range, or a design, architecture, or public API change with no matching
doc update. Quote the statement or the trailer and its commit. Anything weaker, or resting on your reading of intent
rather than on what the doc says, is SUGGESTED.
If there are no findings, say so.

$verdict_rule
EOF

    o1=$(mktemp)
    o2=$(mktemp)
    echo ""
    echo "Running pass 1 (general review) and pass 2 (spec conformance) in parallel"
    echo "(this can take a few minutes)..."
    run_review_agent "$p1" "$review_model" "$review_effort" > "$o1" 2>&1 &
    pid1=$!
    run_review_agent "$p2" "$review_spec_model" "$review_spec_effort" > "$o2" 2>&1 &
    pid2=$!

    s1=0
    wait "$pid1" || s1=$?
    s2=0
    wait "$pid2" || s2=$?

    ok1=0
    ok2=0
    finish_pass "Pass 1: general review" "$o1" "$s1" && ok1=1
    finish_pass "Pass 2: spec conformance" "$o2" "$s2" && ok2=1
    show_pass "Pass 1: general review" "$o1" "$ok1"
    show_pass "Pass 2: spec conformance" "$o2" "$ok2"

    { cat "$o1"; echo; cat "$o2"; } > "$findings_file"
    rm -f "$o1" "$o2"
    [ "$ok1" = 1 ] && [ "$ok2" = 1 ]
}

# apply_fixes hands the open findings in $findings_file to a single fix agent
# (both passes combined — coupled fixes and shared root causes need one
# coherent pass, not one agent per finding). The agent fixes each finding or
# disputes it with evidence, edits the working tree, and leaves the changes
# uncommitted. Its summary goes to $fix_summary_file for the verifier, is
# appended to the report, and is printed to the terminal, capped like the
# review passes so it can't overflow and get truncated. $1 is a label suffix for
# the section/console line. Returns non-zero if the fixer could not run, so the
# loop can stop.
apply_fixes() {
    local label=$1 fix_prompt status=0
    if [ "$fix_agent" = "claude" ] && ! command -v claude >/dev/null 2>&1; then
        echo "WARNING: 'claude' not found — cannot auto-fix. Fix REQUIRED findings manually." >&2
        return 1
    fi

    read -r -d '' fix_prompt <<EOF || true
You are the fix pass of a pre-push code review for this repository.

A code review of these changes failed. Read the findings in:
    $findings_file
and read CLAUDE.md for this project's coding and testing guidelines.

Handle every finding marked REQUIRED or OPEN. Ignore SUGGESTED, RESOLVED, and
DISPUTE ACCEPTED findings.

Check each finding against the code before acting on it. Then either:
- fix it, or
- dispute it, when it is wrong: its failure scenario can't happen, or the
  behavior it flags is what docs/ specifies. A dispute needs evidence another
  reviewer can check: a file:line, a quoted doc statement, or test output.
  Change no code for a disputed finding. Don't dispute a finding just because
  the fix is hard.

Rules:
- Fix at the root cause. If several findings share one root cause, fix it once.
- Make the minimal, localized change that resolves each finding.
- Edit files in the working tree. Do NOT stage, commit, amend, or push — leave
  all changes uncommitted for human review.
- Verify before finishing: run \`uv run pre-commit run --files <changed files>\`
  and \`uv run pytest\`. A fix that breaks lint or tests is not a fix.
- If a finding is valid but cannot be fixed safely and automatically, leave it
  and say why.

End with a report titled "Fix summary" with one entry per finding you handled,
each starting with FIXED, DISPUTED, or UNFIXED: the finding (file:line and what
was wrong), then exactly what you changed, the evidence for the dispute, or why
it could not be fixed. Keep it concise.
EOF

    echo ""
    echo "fix_enabled=true — applying fixes for REQUIRED findings with '$fix_agent'$label"
    echo "(this can take a few minutes)..."
    run_fix_agent "$fix_prompt" > "$fix_summary_file" 2>&1 || status=$?
    # Carry on to verification either way: it judges whatever the fixer left.
    [ "$status" -eq 124 ] && echo "WARNING: fix agent timed out after ${agent_timeout}s (agent_timeout)." >&2

    {
        echo
        echo "## Auto-fix$label"
        echo
        cat "$fix_summary_file"
    } >> "$report"

    echo ""
    echo "==== Auto-fix$label — REQUIRED findings ===="
    head -n "$show_limit" "$fix_summary_file"
    if [ "$(wc -l < "$fix_summary_file")" -gt "$show_limit" ]; then
        echo "[... truncated at $show_limit lines — full fix summary in $report]"
    fi
}

# verify_fixes checks the fix pass instead of re-reviewing the whole branch: a
# fresh full review turns up new findings each round and may never converge.
# It judges each open finding RESOLVED, DISPUTE ACCEPTED, or OPEN, and reviews
# only the fix diff for new REQUIRED issues. It replaces $findings_file with
# what is still open, which is what the next fix pass reads. The committed fix
# still gets a full review on the next push. $1 is a label suffix. Returns 0
# only if nothing is left open.
verify_fixes() {
    local label=$1 prompt out status=0 ok=0

    read -r -d '' prompt <<EOF || true
You are verifying the fix pass of a pre-push code review for this repository.

A review found REQUIRED issues, and a fix agent has since edited the working
tree. Read:
    $findings_file — the findings to judge (REQUIRED or OPEN ones)
    $fix_summary_file — the fix agent's summary: FIXED, DISPUTED, or UNFIXED per finding
The fixes are uncommitted. See them with:
    git diff HEAD
    git status --porcelain
and read any new untracked files; they are part of the fix. Read surrounding
source, CLAUDE.md, and docs/ as needed.

Judge each REQUIRED or OPEN finding from the findings file:
- RESOLVED: the fix removes the failure scenario, or makes the code match the doc.
- DISPUTE ACCEPTED: the fix agent disputed it, and its evidence holds up when
  you check it yourself. The finding was wrong.
- OPEN: not fixed, fixed incompletely, or disputed without evidence that holds up.

Then review the fix diff (git diff HEAD plus new untracked files, not the rest
of the branch) for problems the fix itself introduces. $required_bar

Report as markdown bullets:
- **RESOLVED**, **DISPUTE ACCEPTED**, or **OPEN** — \`file:line\` — the original finding and your judgment
- **REQUIRED** — \`file:line\` — a new issue in the fix diff, its failure scenario, and the change needed

Restate each OPEN finding in full, with its failure scenario and the change
needed: the next fix pass reads only this report.

$verdict_rule
EOF

    out=$(mktemp)
    echo ""
    echo "Verifying the fixes$label (this can take a few minutes)..."
    run_review_agent "$prompt" "$review_spec_model" "$review_spec_effort" > "$out" 2>&1 || status=$?
    finish_pass "Fix verification$label" "$out" "$status" && ok=1
    show_pass "Fix verification$label" "$out" "$ok"
    mv "$out" "$findings_file"
    [ "$ok" = 1 ]
}

# --- initial review ----------------------------------------------------------
# Reviews the committed range that is actually being pushed. A pass here is the
# only outcome that records the ledger and lets the push through.

if run_review "$range"; then
    if ! ledger_set "$branch" "$head_sha"; then
        echo "Code review PASSED, but the ledger write failed — the next push reviews these commits again." >&2
    fi
    echo ""
    echo "Code review PASSED. Recorded for '$branch' — only new commits will be reviewed next push."
    echo "Report: $report"
    exit 0
fi

echo ""
echo "Code review FAILED — push blocked."
echo "Full report: $report"

if [ "$fix_enabled" != "true" ]; then
    echo "Fix the REQUIRED findings, commit, and push again."
    exit 1
fi

# --- fix / verify loop -------------------------------------------------------
# Fixes are uncommitted, so a verified fix is never recorded in the ledger (the
# passing state isn't a commit) and never lets this push through: the fixes
# must be committed and pushed, where they get one honest full review.

iteration=1
while :; do
    if ! apply_fixes " (iteration $iteration)"; then
        echo "Auto-fix could not run — push blocked. Fix the REQUIRED findings manually."
        exit 1
    fi

    if verify_fixes " (iteration $iteration)"; then
        echo ""
        if [ -z "$(git status --porcelain)" ]; then
            # Nothing to commit: every finding was disputed and the dispute
            # upheld. Getting past the gate from here is a human decision.
            echo "Every REQUIRED finding was disputed and the verifier accepted the disputes;"
            echo "no code changed, so this push is still blocked. Read $report and decide:"
            echo "push again for a fresh review, or skip the review for this push yourself."
            exit 1
        fi
        echo "Auto-fix cleared all REQUIRED findings after $iteration iteration(s)."
        echo "The fixes are in the working tree, uncommitted — this push is still blocked."
        echo "Review the diff, commit the fixes, and push again. If this push came from"
        echo "make ship, it commits the fix and pushes again on its own (ship_fix_retries)."
        echo "Report: $report"
        touch "$autofix_marker"
        exit 1
    fi

    if [ "$iteration" -ge "$fix_max_iterations" ]; then
        echo ""
        echo "Auto-fix stopped after $iteration iteration(s) (fix_max_iterations=$fix_max_iterations) with findings still open."
        echo "Review the working tree and $report, finish the fixes, commit, and push again."
        exit 1
    fi

    iteration=$((iteration + 1))
done
