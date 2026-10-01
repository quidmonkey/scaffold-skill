#!/usr/bin/env bash
# PreToolUse hook on Edit and Write: when the target file has decisions
# recorded in commit trailers (README.md, "Decision history"), hands them to
# the agent as additionalContext and shows the developer a one-line notice
# (systemMessage). Fires once per file per session.
#
# Claude Code delivers additionalContext with the tool result, so the agent
# reads the decisions right after its first edit to the file; CLAUDE.md tells
# it what to do when that edit conflicts with one.
#
# Never blocks or changes the permission decision: every exit is 0.
set -uo pipefail

payload=$(cat 2>/dev/null || true)

# json_field <name> — a string field from the flat hook payload. Good enough
# for a session id and a path; a path containing a double quote is skipped.
json_field() {
    printf '%s' "$payload" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n 1 |
        sed 's/.*:[[:space:]]*"//; s/"$//'
}

file=$(json_field file_path)
session=$(json_field session_id)
[ -n "$file" ] && [ -f "$file" ] || exit 0

cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
rel=${file#"$(pwd -P)"/}
rel=${rel#"$(pwd)"/}

seen="${TMPDIR:-/tmp}/claude-decisions-${session:-nosession}"
grep -qxF "$rel" "$seen" 2>/dev/null && exit 0
printf '%s\n' "$rel" >> "$seen"

decisions=$(bash scripts/decisions.sh --limit 10 -- "$rel")
[ -n "$decisions" ] || exit 0

count=$(printf '%s\n' "$decisions" | grep -c '^[0-9a-f]')
first=$(printf '%s\n' "$decisions" | grep -iE -m 1 '^  (Decision|Rejected):' | sed 's/^  //')
sha=$(printf '%s\n' "$decisions" | head -n 1 | cut -d' ' -f1)

# json_str — a JSON string literal: backslashes, quotes, tabs, and newlines
# escaped; carriage returns dropped.
json_str() {
    printf '%s' "$1" | awk 'BEGIN { ORS = ""; print "\"" }
        { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); gsub(/\r/, "")
          if (NR > 1) print "\\n"; print }
        END { print "\"" }'
}

context="Decisions recorded in commit trailers for $rel, newest first:

$decisions

CLAUDE.md (\"Decision history\") covers what to do when a change conflicts with one."

notice="$count prior decision(s) on $rel. Latest: $first ($sha). Run scripts/decisions.sh $rel for all."

printf '{"systemMessage": %s, "hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": %s}}\n' \
    "$(json_str "$notice")" "$(json_str "$context")"
exit 0
