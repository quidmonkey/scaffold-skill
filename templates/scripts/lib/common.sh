# Shared helpers for scripts/code-review.sh, scripts/ship.sh and
# scripts/set-ship-stage.sh. Sourced, not executed — no shebang, no set -u here
# (each caller sets its own options).

# Constants below are used by the scripts that source this file.
# shellcheck disable=SC2034

# The only branch ship.sh opens PRs into and merges into. main is never a
# target: ship can't trigger a prod deploy.
ship_base=develop

# code-review.sh's fix/verify loop touches this file instead of just
# exiting when it resolves every REQUIRED finding — the fixes are still
# uncommitted (fix_enabled never commits or pushes on its own), but ship.sh
# looks for this file right after a blocked `git push` to know whether it's
# looking at an unfixable failure or a fix sitting in the working tree ready
# to be committed. Gitignored, like the report.
autofix_marker="working/autofix-pending.marker"

# Every key .codereviewrc understands. An override (--set or CR_<KEY>) naming
# anything else is a typo and fails, so it can't be silently ignored.
rc_known_keys="review_agent review_model review_effort review_spec_model
review_spec_effort enabled command fix_enabled fix_agent fix_model fix_effort
fix_command fix_max_iterations
agent_timeout ship_stage ship_fix_retries ship_log_retention_days ship_notify
pr_host pr_merge_method pr_self_approve pr_poll_interval pr_poll_timeout
pr_reviewers deploy_pipeline deploy_provider deploy_project deploy_region
deploy_name deploy_match deploy_proxy deploy_smoke deploy_run_grace
deploy_poll_timeout deploy_smoke_timeout"

# rc_env_name <key> — the environment variable that overrides <key>: CR_ plus
# the key in uppercase. The prefix keeps generic keys like `enabled` and
# `command` from colliding with unrelated variables.
rc_env_name() {
    printf 'CR_%s\n' "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
}

# rc_get <key> [rc-file] — the raw value of <key>: the CR_<KEY> environment
# variable if it's set (even to empty, which means "use the default"),
# otherwise key=value from an rc file (default .codereviewrc), one per line.
# Strips inline comments (whitespace then #) and surrounding whitespace, so a
# line copied with its trailing comment parses. Prints the last matching line
# if a key repeats. Prints nothing for an unset key; see rc_value.
rc_get() {
    local key=$1 file=${2:-.codereviewrc} env_name
    env_name=$(rc_env_name "$key")
    if [ -n "${!env_name+x}" ]; then
        printf '%s\n' "${!env_name}"
        return
    fi
    sed -n "s/^$key=//p" "$file" 2>/dev/null | tail -n 1 \
        | sed -e 's/[[:space:]][[:space:]]*#.*$//' \
              -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# rc_default <key> — the built-in default, used when no override or rc line
# sets a value. An absent .codereviewrc behaves exactly like the scaffolded one.
rc_default() {
    case "$1" in
        review_agent | fix_agent) echo claude ;;
        review_model) echo opus ;;
        review_effort) echo high ;;
        review_spec_effort | fix_effort) echo medium ;;
        review_spec_model | fix_model) echo sonnet ;;
        enabled | fix_enabled | pr_self_approve) echo true ;;
        fix_max_iterations) echo 2 ;;
        agent_timeout | deploy_smoke_timeout) echo 900 ;;
        ship_stage) echo open_pr ;;
        ship_fix_retries) echo 1 ;;
        ship_log_retention_days) echo 30 ;;
        ship_notify) echo none ;;
        pr_host)
            case "$(git remote get-url origin 2>/dev/null)" in
                *github.com*) echo gh ;;
                *) echo az ;;
            esac
            ;;
        pr_merge_method) echo squash ;;
        pr_poll_interval) echo 15 ;;
        pr_poll_timeout) echo 1800 ;;
        deploy_region) echo us-central1 ;;
        deploy_match) echo time ;;
        deploy_proxy) echo false ;;
        deploy_run_grace) echo 300 ;;
        deploy_poll_timeout) echo 3600 ;;
    esac
}

# rc_value <key> — rc_get, falling back to rc_default when empty.
rc_value() {
    local v
    v=$(rc_get "$1")
    if [ -n "$v" ]; then
        printf '%s\n' "$v"
    else
        rc_default "$1"
    fi
}

# in_list <word> <list> — true if <word> is one of the whitespace-separated
# words in <list>.
in_list() {
    local w
    for w in $2; do
        [ "$w" = "$1" ] && return 0
    done
    return 1
}

# rc_is_known <key> — true if <key> is in rc_known_keys.
rc_is_known() {
    in_list "$1" "$rc_known_keys"
}

# rc_closest_key <word> — the known key with the smallest edit distance to
# <word>, for "did you mean" messages.
rc_closest_key() {
    # shellcheck disable=SC2086 # word-splitting the key list is the point
    printf '%s\n' $rc_known_keys | awk -v w="$1" '
        function lev(a, b,   i, j, la, lb, d, c) {
            la = length(a); lb = length(b)
            for (i = 0; i <= la; i++) d[i, 0] = i
            for (j = 0; j <= lb; j++) d[0, j] = j
            for (i = 1; i <= la; i++)
                for (j = 1; j <= lb; j++) {
                    c = (substr(a, i, 1) != substr(b, j, 1))
                    d[i, j] = d[i-1, j] + 1
                    if (d[i, j-1] + 1 < d[i, j]) d[i, j] = d[i, j-1] + 1
                    if (d[i-1, j-1] + c < d[i, j]) d[i, j] = d[i-1, j-1] + c
                }
            return d[la, lb]
        }
        { s = lev(w, $0); if (best == "" || s < bestscore) { best = $0; bestscore = s } }
        END { print best }'
}

# default_branch — the repo's default branch per origin/HEAD, falling back to
# main if the remote HEAD ref isn't set locally (git remote set-head origin -a).
default_branch() {
    local b
    b=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
    echo "${b:-main}"
}

# rc_set <key> <value> [rc-file] — writes key=value into an rc file, replacing
# the existing line for that key if present or appending a new one otherwise.
# Creates the file (with a header comment) if it doesn't exist yet. Used to
# record a personal choice (e.g. ship_stage) without touching other keys.
rc_set() {
    local key=$1 value=$2 file=${3:-.codereviewrc}
    if [ ! -f "$file" ]; then
        printf '# Personal review/ship automation settings (gitignored) -- see scripts/code-review.sh and scripts/ship.sh.\n' > "$file"
    fi
    if grep -q "^$key=" "$file" 2>/dev/null; then
        sed -i.bak "s/^$key=.*/$key=$value/" "$file" && rm -f "$file.bak"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}

# --- review ledger ---------------------------------------------------------------
# The last passing commit per branch, one "<branch> <sha>" line each. It lives in
# the common git dir so every worktree (ship.sh's included) shares it.

ledger_path() {
    printf '%s/code-review-ledger\n' "$(git rev-parse --git-common-dir)"
}

# ledger_get <branch> — the branch's last reviewed sha, or nothing.
ledger_get() {
    local ledger
    ledger=$(ledger_path)
    [ -f "$ledger" ] && awk -v b="$1" '$1 == b { print $2 }' "$ledger"
    return 0
}

# ledger_lock <lock-dir> — takes the ledger lock: a mkdir, since macOS has no
# flock by default. Retries for up to 30 seconds. A lock whose recorded PID is
# no longer alive is stale and is removed.
ledger_lock() {
    local lock=$1 waited=0 pid
    while ! mkdir "$lock" 2>/dev/null; do
        pid=$(cat "$lock/pid" 2>/dev/null)
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
            rm -rf "$lock"
            continue
        fi
        if [ "$waited" -ge 30 ]; then
            echo "ERROR: couldn't take the review ledger lock ($lock) after 30s." >&2
            echo "If no ship or push is running, remove that directory and retry." >&2
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    echo "$$" > "$lock/pid"
}

# ledger_set <branch> <sha> — records <sha> as <branch>'s last reviewed commit,
# or removes <branch>'s entry when <sha> is empty, holding the ledger lock. An EXIT trap removes the lock if the
# caller dies mid-write; the caller's own EXIT trap is restored afterwards.
ledger_set() {
    local branch=$1 sha=$2 ledger lock tmp prev_exit status=0
    ledger=$(ledger_path)
    lock="$ledger.lock"
    ledger_lock "$lock" || return 1
    prev_exit=$(trap -p EXIT)
    # shellcheck disable=SC2064 # expand $lock now: it's local
    trap "rm -rf '$lock'" EXIT
    tmp=$(mktemp "$ledger.XXXXXX")
    {
        [ -f "$ledger" ] && awk -v b="$branch" '$1 != b' "$ledger"
        [ -z "$sha" ] || echo "$branch $sha"
    } > "$tmp" && mv "$tmp" "$ledger" || status=1
    rm -rf "$lock"
    if [ -n "$prev_exit" ]; then
        eval "$prev_exit"
    else
        trap - EXIT
    fi
    return "$status"
}

# with_timeout <seconds> <cmd...> runs cmd and kills it after <seconds>,
# returning 124 like coreutils timeout, which macOS doesn't ship. A hung agent
# or smoke test would otherwise block forever; a timed-out run fails closed.
with_timeout() {
    local secs=$1 pid watchdog status=0 flag
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
        return
    fi
    if command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$secs" "$@"
        return
    fi
    flag=$(mktemp)
    rm -f "$flag"
    # <&0: a background job's stdin is otherwise /dev/null, and custom agents
    # read their prompt from stdin.
    "$@" <&0 &
    pid=$!
    # Polls rather than one long sleep, so the watchdog exits within a second
    # of the command finishing instead of lingering for the full timeout.
    (
        elapsed=0
        while kill -0 "$pid" 2>/dev/null; do
            if [ "$elapsed" -ge "$secs" ]; then
                touch "$flag"
                kill "$pid" 2>/dev/null
                exit 0
            fi
            sleep 1
            elapsed=$((elapsed + 1))
        done
    ) &
    watchdog=$!
    wait "$pid" 2>/dev/null || status=$?
    wait "$watchdog" 2>/dev/null
    if [ -e "$flag" ]; then
        rm -f "$flag"
        return 124
    fi
    return "$status"
}
