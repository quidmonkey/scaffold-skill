#!/usr/bin/env bash
# Ship the current branch into develop from a separate git worktree, so none of
# it touches the developer's checkout. See docs in README.md ("Shipping").
#
#   plan      read .codereviewrc and overrides, check the repo and every tool the
#             stage needs, print the config block. Creates nothing.
#   kickoff   freeze HEAD as ship/<branch>-<sha7>, seed its review-ledger entry,
#             create the worktree ../<repo>.ship-<id>, and .git/ship/<id>/.
#   stages    in the worktree: push (the pre-push review runs there, and an
#             auto-fix is committed and pushed again up to ship_fix_retries
#             times), then as far as ship_stage says: open_pr, merge,
#             verify_deploy. Each stage transition is a line in
#             .git/ship/<id>/events.
#
# Usage:
#   ship.sh --plan [--stage S] [--set k=v ...] [--sets 'k=v;k=v']
#   ship.sh [--stage S] [--set ...] [--detach] [--yes]
#           [--id ID --expect-sha SHA --expect-config HASH]
#   ship.sh --status [ID] | --stop [ID] | --watch [ID]
#
# Settings resolve as --set, then CR_<KEY>, then .codereviewrc, then the
# built-in default (lib/common.sh). Overrides are exported as CR_<KEY>, so the
# pre-push review in the worktree sees them too. They're never written back.
#
# Without --id, kickoff shows the plan and asks Proceed? [y/N] on a terminal,
# and refuses without one unless --yes. With --id (what /ship passes after its
# plan), it refuses if HEAD or any resolved setting changed since that plan.

# shellcheck disable=SC2154 # cfg_<key> is assigned by resolve_config via printf -v
set -u

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"
# shellcheck source=lib/ship-status.sh
source "$script_dir/lib/ship-status.sh"
# shellcheck source=lib/ship-deploy.sh
source "$script_dir/lib/ship-deploy.sh"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# --- arguments -------------------------------------------------------------------

mode=run
detach=false
assume_yes=false
ship_id=""
expect_sha=""
expect_config=""
set_keys=" "

# add_set <key=value> — a one-run override, exported as CR_<KEY>.
add_set() {
    local key value
    case "$1" in
        *=*) ;;
        *) die "--set expects key=value, got '$1'." ;;
    esac
    key=$(printf '%s' "${1%%=*}" | tr -d '[:space:]')
    value=$(printf '%s' "${1#*=}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    rc_is_known "$key" || die "unknown setting '$key'. Did you mean '$(rc_closest_key "$key")'?"
    export "$(rc_env_name "$key")=$value"
    set_keys="$set_keys$key "
}

while [ $# -gt 0 ]; do
    case "$1" in
        --plan) mode=plan ;;
        --status | --stop | --watch | --resume)
            mode=${1#--}
            ship_id=${2:-}
            [ $# -gt 1 ] && shift
            ;;
        --detach) detach=true ;;
        --yes) assume_yes=true ;;
        --id) ship_id=${2:?--id needs a value}; shift ;;
        --expect-sha) expect_sha=${2:?--expect-sha needs a value}; shift ;;
        --expect-config) expect_config=${2:?--expect-config needs a value}; shift ;;
        --stage) add_set "ship_stage=${2:?--stage needs a value}"; shift ;;
        --set) add_set "${2:?--set needs key=value}"; shift ;;
        --sets)
            # make ship SET='k=v;k=v'. A value containing ; must come from
            # CR_<KEY> or .codereviewrc instead.
            IFS=';' read -r -a pairs <<< "${2:-}"
            for pair in ${pairs[@]+"${pairs[@]}"}; do
                [ -n "$(printf '%s' "$pair" | tr -d '[:space:]')" ] && add_set "$pair"
            done
            shift
            ;;
        -h | --help) sed -n '2,/^# plan), it refuses/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument '$1' (see --help)." ;;
    esac
    shift
done

cd "$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository."

case "$mode" in
    status) ship_status_report "$ship_id"; exit ;;
    stop) ship_stop "$ship_id"; exit ;;
    watch) ship_watch "$ship_id"; exit ;;
esac

# --- configuration ---------------------------------------------------------------

# resolve_config — sets cfg_<key> for every known key.
resolve_config() {
    local key legacy
    # shellcheck disable=SC2086 # word-splitting the key list is the point
    for key in $rc_known_keys; do
        printf -v "cfg_$key" '%s' "$(rc_value "$key")"
    done
    # Migration: pr_automation predates ship_stage. Honored only while nothing
    # sets ship_stage.
    migrated_stage=""
    legacy=$(sed -n 's/^pr_automation=//p' .codereviewrc 2>/dev/null | tail -n 1 | sed 's/[[:space:]].*//')
    if [ -n "$legacy" ] && [ "$(cfg_source ship_stage)" = default ]; then
        case "$legacy" in
            true) migrated_stage=merge ;;
            *) migrated_stage=push ;;
        esac
        cfg_ship_stage=$migrated_stage
    fi
}

# cfg_source <key> — where <key>'s value came from.
cfg_source() {
    local env_name
    case "$set_keys" in *" $1 "*) echo "--set"; return ;; esac
    env_name=$(rc_env_name "$1")
    if [ -n "${!env_name+x}" ]; then
        echo "env $env_name"
    elif [ "$1" = ship_stage ] && [ -n "${migrated_stage:-}" ]; then
        echo ".codereviewrc (pr_automation)"
    elif grep -q "^$1=" .codereviewrc 2>/dev/null; then
        echo ".codereviewrc"
    else
        echo default
    fi
}

cfg() {
    local name="cfg_$1"
    printf '%s' "${!name}"
}

# config_hash — a hash of every resolved setting. The plan prints it; kickoff
# refuses if it no longer matches, so the approved config is the one that runs.
config_hash() {
    local key
    # shellcheck disable=SC2086 # word-splitting the key list is the point
    for key in $rc_known_keys; do
        printf '%s=%s\n' "$key" "$(cfg "$key")"
    done | git hash-object --stdin | cut -c1-12
}

# config_json — every setting with its source, for status.json.
config_json() {
    local key sep=""
    printf '{'
    # shellcheck disable=SC2086 # word-splitting the key list is the point
    for key in $rc_known_keys; do
        printf '%s"%s": {"value": "%s", "source": "%s"}' "$sep" "$key" \
            "$(json_escape "$(cfg "$key")")" "$(json_escape "$(cfg_source "$key")")"
        sep=", "
    done
    printf '}'
}

# stage_rank <stage> — stages are cumulative; a higher rank includes the lower.
stage_rank() {
    case "$1" in
        push) echo 1 ;;
        open_pr) echo 2 ;;
        merge) echo 3 ;;
        verify_deploy) echo 4 ;;
        *) echo 0 ;;
    esac
}

stage_at_least() {
    [ "$(stage_rank "$cfg_ship_stage")" -ge "$(stage_rank "$1")" ]
}

# --- preflight -------------------------------------------------------------------
# Every check the resolved stage needs, before anything is created or pushed.
# Collects every failure rather than stopping at the first.

pf_fails=""
pf_warns=""
pf_oks=""
accounts=""
nl='
'
pf_fail() { pf_fails="$pf_fails$1$nl"; }
pf_warn() { pf_warns="$pf_warns$1$nl"; }
pf_ok() { pf_oks="$pf_oks$1$nl"; }
pf_account() { accounts="$accounts$(printf '  %-24s %s' "$1" "$2")$nl"; }

check_enum() {
    local key=$1 value allowed
    shift
    value=$(cfg "$key")
    for allowed in "$@"; do
        [ "$value" = "$allowed" ] && return 0
    done
    pf_fail "$key='$value' ($(cfg_source "$key")) isn't valid. Use one of: $*."
}

check_int() {
    local key=$1 min=$2 value
    value=$(cfg "$key")
    case "$value" in
        '' | *[!0-9]*) ;;
        *) [ "$value" -ge "$min" ] && return 0 ;;
    esac
    pf_fail "$key='$value' ($(cfg_source "$key")) must be an integer >= $min."
}

check_env_keys() {
    local name key
    for name in $(env | sed -n 's/^\(CR_[A-Za-z0-9_]*\)=.*/\1/p'); do
        key=$(printf '%s' "${name#CR_}" | tr '[:upper:]' '[:lower:]')
        rc_is_known "$key" \
            || pf_fail "Unknown setting in environment variable $name. Did you mean $(rc_env_name "$(rc_closest_key "$key")")? Unset it, then /ship again."
    done
}

validate_config() {
    check_env_keys
    check_enum ship_stage push open_pr merge verify_deploy
    check_enum review_agent claude custom
    check_enum fix_agent claude custom
    check_enum review_effort low medium high xhigh max default
    check_enum review_spec_effort low medium high xhigh max default
    check_enum fix_effort low medium high xhigh max default
    check_enum enabled true false
    check_enum fix_enabled true false
    check_enum pr_self_approve true false
    check_enum ship_notify none desktop
    check_enum pr_host gh az
    check_enum pr_merge_method squash merge rebase
    check_enum deploy_proxy true false
    check_enum deploy_match sha time
    check_int agent_timeout 1
    check_int fix_max_iterations 1
    check_int ship_fix_retries 0
    check_int ship_log_retention_days 0
    check_int pr_poll_interval 1
    check_int pr_poll_timeout 1
    check_int deploy_run_grace 0
    check_int deploy_poll_timeout 1
    check_int deploy_smoke_timeout 1
    [ "$cfg_review_agent" = custom ] && [ -z "$cfg_command" ] \
        && pf_fail "review_agent=custom needs command= in .codereviewrc."
    [ "$cfg_fix_enabled" = true ] && [ "$cfg_fix_agent" = custom ] && [ -z "$cfg_fix_command" ] \
        && pf_fail "fix_agent=custom needs fix_command= in .codereviewrc."
    return 0
}

# reviewer_list — pr_reviewers split on commas, one per line, trimmed.
reviewer_list() {
    printf '%s\n' "$cfg_pr_reviewers" | tr ',' '\n' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$'
}

# host_auth_ok — the PR host's CLI is logged in. Used at preflight and again
# when a PR command fails mid-run, to tell expired auth from other failures.
host_auth_ok() {
    case "$cfg_pr_host" in
        gh) gh auth status >/dev/null 2>&1 ;;
        az) az account show >/dev/null 2>&1 ;;
    esac
}

preflight_host() {
    local account defaults r org team project
    case "$cfg_pr_host" in
        gh)
            if ! command -v gh >/dev/null 2>&1; then
                pf_fail "gh isn't installed. Install it from https://cli.github.com, then /ship again."
                return
            fi
            if ! host_auth_ok; then
                pf_fail "gh isn't logged in. Run \`! gh auth login\` in the session, then /ship again."
                return
            fi
            account=$(gh api user --jq .login 2>/dev/null)
            pf_account gh "${account:-(unknown)}"
            pf_ok "gh logged in"
            ;;
        az)
            if ! command -v az >/dev/null 2>&1; then
                pf_fail "az isn't installed. Install the Azure CLI, then /ship again."
                return
            fi
            if ! host_auth_ok; then
                pf_fail "az isn't logged in. Run \`! az login\` in the session, then /ship again."
                return
            fi
            if ! az extension show --name azure-devops >/dev/null 2>&1; then
                pf_fail "The azure-devops extension is missing. Run: az extension add --name azure-devops"
                return
            fi
            defaults=$(az devops configure --list 2>/dev/null)
            if ! printf '%s\n' "$defaults" | grep -q '^organization = ..*' \
                || ! printf '%s\n' "$defaults" | grep -q '^project = ..*'; then
                pf_fail "az devops has no default organization and project. Run: az devops configure --defaults organization=https://dev.azure.com/<org> project=<project>"
                return
            fi
            account=$(az account show --query user.name -o tsv 2>/dev/null)
            pf_account az "${account:-(unknown)}"
            pf_ok "az logged in, azure-devops defaults set"
            ;;
        *) return ;;
    esac

    [ -n "$cfg_pr_reviewers" ] || return 0
    while IFS= read -r r; do
        case "$cfg_pr_host" in
            gh)
                case "$r" in
                    */*)
                        org=${r%%/*}
                        team=${r#*/}
                        gh api "orgs/$org/teams/$team" >/dev/null 2>&1 \
                            || pf_fail "Reviewer '$r' isn't a GitHub team you can see (org/team). Fix pr_reviewers."
                        ;;
                    *)
                        gh api "users/$r" >/dev/null 2>&1 \
                            || pf_fail "Reviewer '$r' isn't a GitHub user. Fix pr_reviewers."
                        ;;
                esac
                ;;
            az)
                case "$r" in
                    *\\*)
                        project=${r%%\\*}
                        project=${project#[}
                        project=${project%]}
                        team=${r#*\\}
                        az devops team show --team "$team" --project "$project" >/dev/null 2>&1 \
                            || pf_fail "Reviewer '$r' isn't an Azure DevOps team ([Project]\\Team). Fix pr_reviewers."
                        ;;
                    *)
                        az devops user show --user "$r" >/dev/null 2>&1 \
                            || pf_fail "Reviewer '$r' isn't an Azure DevOps user (email or UPN). Fix pr_reviewers."
                        ;;
                esac
                ;;
        esac
    done <<< "$(reviewer_list)"
    pf_ok "reviewers resolve: $cfg_pr_reviewers"
}

# ship_owning <snapshot-branch> — the directory of the ship that created it.
ship_owning() {
    local d
    for d in $(ship_dirs); do
        [ "$(status_get "$d/status.json" snapshot_branch)" = "$1" ] && echo "$d"
    done | tail -n 1
}

preflight() {
    local t ahead origin_head d owner hook
    branch=""
    head_sha=$(git rev-parse HEAD 2>/dev/null)
    sha7=$(printf '%s' "$head_sha" | cut -c1-7)

    if ! branch=$(git symbolic-ref -q --short HEAD); then
        branch=""
        pf_fail "HEAD is detached. Check out the branch you want to ship, then /ship again."
    elif [ "$branch" = "$ship_base" ] || [ "$branch" = main ]; then
        pf_fail "You're on $branch. /ship ships a feature branch into $ship_base: check one out first."
    fi

    if ! git rev-parse -q --verify "refs/remotes/origin/$ship_base" >/dev/null; then
        pf_fail "origin/$ship_base doesn't exist. Push it (git push -u origin $ship_base), or git fetch origin if it's new. README.md has the first-push steps."
    elif [ -n "$branch" ]; then
        ahead=$(git rev-list --count "origin/$ship_base..HEAD")
        if [ "$ahead" -eq 0 ]; then
            pf_fail "$branch has no commits ahead of origin/$ship_base. Nothing to ship."
        else
            pf_ok "$branch is $ahead commit(s) ahead of origin/$ship_base"
        fi
        origin_head=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
        [ "$origin_head" = "origin/$ship_base" ] \
            || pf_warn "origin/HEAD is '${origin_head:-unset}', not origin/$ship_base. Make $ship_base the default: gh repo edit --default-branch $ship_base (or az repos update --repository <repo> --default-branch $ship_base), then git remote set-head origin $ship_base."
    fi

    [ -n "$(git status --porcelain)" ] \
        && pf_warn "Uncommitted changes in your checkout aren't part of this ship. Only commits up to $sha7 ship."

    for t in claude uv git; do
        command -v "$t" >/dev/null 2>&1 || pf_fail "$t isn't on PATH. Install it, then /ship again."
    done
    hook=$(git rev-parse --git-path hooks/pre-push)
    if [ -f "$hook" ]; then
        pf_ok "pre-push hook installed"
    else
        pf_fail "The pre-push hook isn't installed, so nothing would review the push. Run: uv run pre-commit install"
    fi

    snapshot="ship/$branch-$sha7"
    for d in $(ship_dirs); do
        if ship_is_running "$d" \
            && [ "$(status_get "$d/status.json" source_branch)" = "$branch" ] \
            && [ "$(status_get "$d/status.json" snapshot_sha)" = "$head_sha" ]; then
            pf_fail "Ship ${d##*/} is already shipping $branch at $sha7. Check it with /ship status."
        fi
    done
    leftover=""
    if [ -n "$branch" ] && git rev-parse -q --verify "refs/heads/$snapshot" >/dev/null; then
        owner=$(ship_owning "$snapshot")
        if [ -z "$owner" ]; then
            pf_fail "Branch $snapshot already exists and no ship owns it. Delete it (git branch -D $snapshot), then /ship again."
        elif ! ship_is_running "$owner"; then
            leftover=$owner
            pf_warn "Replaces the worktree and branch $snapshot kept by ship ${owner##*/}."
        fi
    fi

    validate_config
    [ -n "$migrated_stage" ] \
        && pf_warn "pr_automation is deprecated: read as ship_stage=$migrated_stage. Run make ship-stage STAGE=<stage> to replace it."

    if stage_at_least open_pr; then
        preflight_host
    fi
    if stage_at_least merge && [ -n "$cfg_pr_reviewers" ]; then
        pf_warn "pr_reviewers is set, but at ship_stage=$cfg_ship_stage the PR is approved and auto-completed right away, so reviewers may never see it. Use open_pr to wait for them."
    fi
    if stage_at_least verify_deploy; then
        deploy_preflight
    fi
}

# --- the config block --------------------------------------------------------------

setting_line() {
    local key=$1 value source marker
    value=$(cfg "$key")
    source=$(cfg_source "$key")
    case "$source" in
        --set | env*) marker="← $source" ;;
        *) marker=$source ;;
    esac
    printf '  %-24s %-20s %s\n' "$key" "${value:-(none)}" "$marker"
}

print_block() {
    local key shown
    shown="ship_stage pr_host pr_merge_method pr_self_approve pr_reviewers review_agent
review_model review_effort review_spec_model review_spec_effort fix_enabled
fix_model fix_effort fix_max_iterations ship_fix_retries agent_timeout pr_poll_interval pr_poll_timeout"
    stage_at_least verify_deploy \
        && shown="$shown deploy_pipeline deploy_provider deploy_project deploy_region deploy_name
deploy_match deploy_proxy deploy_smoke deploy_run_grace deploy_poll_timeout deploy_smoke_timeout"
    echo "Ship $ship_id"
    printf '  %-24s %s\n' source "${branch:-(detached)} @ $sha7"
    printf '  %-24s %s\n' snapshot "$snapshot"
    printf '  %-24s %s\n' worktree "$worktree"
    printf '  %-24s %s\n' target "$ship_base"
    printf '  %-24s %s\n' log "$(ship_root)/$ship_id/ship.log"
    echo "Settings"
    # shellcheck disable=SC2086 # word-splitting the key lists is the point
    for key in $shown; do
        setting_line "$key"
    done
    # Any other override, so nothing overridden is hidden.
    # shellcheck disable=SC2086
    for key in $rc_known_keys; do
        in_list "$key" "$shown" && continue
        case "$(cfg_source "$key")" in --set | env*) setting_line "$key" ;; esac
    done
    if [ -n "$accounts" ]; then
        echo "Accounts"
        printf '%s' "$accounts"
    fi
    echo "Preflight"
    [ -n "$pf_oks" ] && printf '%s' "$pf_oks" | sed 's/^/  ok    /'
    [ -n "$pf_fails" ] && printf '%s' "$pf_fails" | sed 's/^/  FAIL  /'
    if [ -n "$pf_warns" ]; then
        echo "Warnings"
        printf '%s' "$pf_warns" | sed 's/^/  - /'
    fi
}

# plan — resolve, preflight, and name everything this ship would create.
plan() {
    resolve_config
    preflight
    ship_id=${ship_id:-$(date +%Y%m%d-%H%M%S)-$sha7}
    repo_root=$(pwd -P)
    worktree="$(dirname "$repo_root")/$(basename "$repo_root").ship-$ship_id"
    plan_hash=$(config_hash)
}

print_plan_footer() {
    echo ""
    echo "SHIP_ID=$ship_id"
    echo "SHIP_SHA=$head_sha"
    echo "SHIP_CONFIG=$plan_hash"
    if [ -n "$pf_fails" ]; then
        echo "SHIP_PREFLIGHT=failed"
    else
        echo "SHIP_PREFLIGHT=passed"
    fi
}

if [ "$mode" = plan ]; then
    plan
    print_block
    print_plan_footer
    [ -z "$pf_fails" ]
    exit
fi

# --- stages (run in the worktree) --------------------------------------------------

# fail_stage <stage> <message> — records the failure and ends the ship. A PR
# or deploy command failing because a login expired says so: a background run
# can't log in again, and whatever is already armed stays armed.
fail_stage() {
    local stage=$1 msg=$2
    case "$stage" in
        open_pr | merge)
            host_auth_ok || msg="auth expired at $stage ($cfg_pr_host isn't logged in). $msg"
            ;;
        verify_deploy)
            deploy_auth_ok || msg="auth expired at $stage (gcloud has no active account). $msg"
            ;;
    esac
    ship_event "$ship_dir" "$stage" failed "$msg"
    finish failed "failed at $stage"
}

copy_report() {
    [ -f working/code-review-report.md ] && cp working/code-review-report.md "$ship_dir/code-review-report.md"
    return 0
}

stage_push() {
    local attempt=0 retries=$cfg_ship_fix_retries msg
    cur_stage=push
    ship_event "$ship_dir" push running "pushing $snapshot (the pre-push review runs first and can take several minutes)"
    while :; do
        # Cleared before every attempt: only a marker written by this push's
        # hook run counts as evidence of what just happened.
        rm -f "$autofix_marker"
        if git push -u origin "$snapshot"; then
            copy_report
            ship_event "$ship_dir" push passed "pushed $snapshot"
            return 0
        fi
        copy_report
        if [ -f "$autofix_marker" ] && [ "$attempt" -lt "$retries" ]; then
            git add -A
            if ! git commit -q -m "Apply code review auto-fix" \
                -m "Auto-fix resolved the REQUIRED findings from the pre-push code review."; then
                fail_stage push "the auto-fix left nothing to commit; see $ship_dir/code-review-report.md"
            fi
            attempt=$((attempt + 1))
            ship_event "$ship_dir" push running "committed the review auto-fix, pushing again (retry $attempt of $retries)"
            continue
        fi
        if [ -f "$autofix_marker" ]; then
            msg="the review auto-fix is ready but ship_fix_retries=$retries is used up; the fix is uncommitted in the worktree"
        elif [ -f working/code-review-report.md ]; then
            msg="the review blocked the push with REQUIRED findings open; see $ship_dir/code-review-report.md"
        else
            msg="git push failed; see $ship_dir/ship.log"
        fi
        fail_stage push "$msg"
    done
}

pr_body() {
    local decisions
    echo "Shipped from \`$source_branch\` at $(printf '%s' "$snapshot_sha" | cut -c1-7) by /ship ($ship_id)."
    echo ""
    echo "## Commits"
    echo ""
    git log --reverse --format='- %s' "origin/$ship_base..HEAD"
    echo ""
    decisions=$(bash "$script_dir/decisions.sh" --range "origin/$ship_base..HEAD")
    if [ -n "$decisions" ]; then
        echo "## Decisions"
        echo ""
        echo '```'
        echo "$decisions"
        echo '```'
        echo ""
    fi
    echo "## Code review"
    echo ""
    if [ -f "$ship_dir/code-review-report.md" ]; then
        echo "The pre-push review passed."
        sed -n '/^## /q;/^- /p' "$ship_dir/code-review-report.md"
        echo ""
        echo "Full report on the shipper's machine: \`.git/ship/$ship_id/code-review-report.md\`"
    else
        echo "Every commit was already reviewed by an earlier passing push."
    fi
}

stage_open_pr() {
    local body url id r
    local reviewers=() reviewer_args=()
    cur_stage=open_pr
    ship_event "$ship_dir" open_pr running "opening a PR from $snapshot into $ship_base"
    body=$(pr_body)
    while IFS= read -r r; do
        [ -n "$r" ] && reviewers+=("$r")
    done <<< "$(reviewer_list)"
    case "$cfg_pr_host" in
        gh)
            [ -n "$cfg_pr_reviewers" ] && reviewer_args=(--reviewer "$(reviewer_list | paste -sd, -)")
            url=$(gh pr create --base "$ship_base" --head "$snapshot" --title "$source_branch" --body "$body" \
                ${reviewer_args[@]+"${reviewer_args[@]}"}) \
                || fail_stage open_pr "gh pr create failed; see $ship_dir/ship.log"
            id=${url##*/}
            ;;
        az)
            # ADO reviewers are added as optional.
            [ -n "$cfg_pr_reviewers" ] && reviewer_args=(--reviewers "${reviewers[@]}")
            id=$(az repos pr create --source-branch "$snapshot" --target-branch "$ship_base" \
                --title "$source_branch" --description "$body" \
                ${reviewer_args[@]+"${reviewer_args[@]}"} \
                --query pullRequestId -o tsv) \
                || fail_stage open_pr "az repos pr create failed; see $ship_dir/ship.log"
            url="$(az repos pr show --id "$id" --query repository.webUrl -o tsv)/pullrequest/$id"
            ;;
    esac
    status_set "$ship_dir/status.json" pr_url "$url"
    status_set "$ship_dir/status.json" pr_id "$id"
    status_set "$ship_dir/status.json" pr_reviewers "$cfg_pr_reviewers"
    ship_event "$ship_dir" open_pr passed "PR $url${cfg_pr_reviewers:+ (reviewers: $cfg_pr_reviewers)}"
}

# pr_poll — one poll of the PR: sets pr_state (open | merged | closed),
# merged_sha, and blocking.
pr_poll() {
    local out state merge_state policies
    pr_state=open
    merged_sha=""
    blocking=""
    case "$cfg_pr_host" in
        gh)
            out=$(gh pr view "$pr_url" --json state,mergeStateStatus,mergeCommit \
                --jq '[.state, .mergeStateStatus, (.mergeCommit.oid // "")] | @tsv' 2>/dev/null) || return 1
            IFS=$'\t' read -r state merge_state merged_sha <<< "$out"
            case "$state" in
                MERGED) pr_state=merged ;;
                CLOSED) pr_state=closed ;;
                *)
                    case "$merge_state" in
                        DIRTY) blocking="merge conflicts with $ship_base" ;;
                        BEHIND) blocking="branch is behind $ship_base" ;;
                        BLOCKED) blocking="blocked by branch protection (required review or check)" ;;
                        UNSTABLE) blocking="a required check is failing" ;;
                        *) blocking="waiting for auto-merge (mergeStateStatus=$merge_state)" ;;
                    esac
                    ;;
            esac
            ;;
        az)
            # Fields go newline-per-value or tab-separated depending on the az
            # version, so normalize; the nullable commit ID stays last.
            out=$(az repos pr show --id "$pr_id" \
                --query "[status, mergeStatus, lastMergeCommit.commitId]" -o tsv 2>/dev/null | tr '\n' '\t') || return 1
            IFS=$'\t' read -r state merge_state merged_sha <<< "$out"
            case "$state" in
                completed) pr_state=merged ;;
                abandoned) pr_state=closed ;;
                *)
                    if [ "$merge_state" = conflicts ]; then
                        blocking="merge conflicts with $ship_base"
                    else
                        policies=$(az repos pr policy list --id "$pr_id" \
                            --query "[?status!='approved' && status!='notApplicable'].configuration.type.displayName" \
                            -o tsv 2>/dev/null | paste -sd, - | sed 's/,/, /g')
                        blocking="waiting on policies: ${policies:-none reported yet}"
                    fi
                    ;;
            esac
            ;;
    esac
}

# squash_body — the squash commit's body when the branch recorded decisions:
# the commit list, then every Decision/Rejected trailer as the final paragraph,
# where scripts/decisions.sh reads them. Empty when there are none, which
# leaves the host's default message. Without this a squash merge drops them.
squash_body() {
    local trailers
    trailers=$(bash "$script_dir/decisions.sh" --trailers --range "origin/$ship_base..HEAD")
    [ -n "$trailers" ] || return 0
    git log --reverse --format='* %s' "origin/$ship_base..HEAD"
    echo ""
    echo "$trailers"
}

stage_merge() {
    local method_flag elapsed=0 last_blocking="" squash=true body=""
    local body_args=()
    cur_stage=merge
    pr_url=$(status_get "$ship_dir/status.json" pr_url)
    pr_id=$(status_get "$ship_dir/status.json" pr_id)
    ship_event "$ship_dir" merge running "approving and arming auto-merge ($cfg_pr_merge_method, delete source branch)"
    case "$cfg_pr_host" in
        gh)
            if [ "$cfg_pr_self_approve" = true ]; then
                gh pr review "$pr_url" --approve \
                    || echo "WARNING: self-approval was rejected (branch protection?); auto-merge waits for a human review instead."
            fi
            method_flag="--$cfg_pr_merge_method"
            [ "$cfg_pr_merge_method" = squash ] && body=$(squash_body)
            [ -n "$body" ] && body_args=(--body "$body")
            gh pr merge "$pr_url" --auto "$method_flag" --delete-branch ${body_args[@]+"${body_args[@]}"} \
                || fail_stage merge "couldn't arm auto-merge on $pr_url; it's open, merge it manually"
            ;;
        az)
            if [ "$cfg_pr_self_approve" = true ]; then
                az repos pr set-vote --id "$pr_id" --vote approve >/dev/null \
                    || echo "WARNING: self-approval was rejected (branch policy?); auto-complete waits for a human review instead."
            fi
            [ "$cfg_pr_merge_method" = squash ] || squash=false
            $squash && body=$(squash_body)
            [ -n "$body" ] && body_args=(--merge-commit-message "Merged PR $pr_id: $source_branch

$body")
            az repos pr update --id "$pr_id" --auto-complete true --squash "$squash" \
                --delete-source-branch true ${body_args[@]+"${body_args[@]}"} >/dev/null \
                || fail_stage merge "couldn't arm auto-complete on PR $pr_id; it's open, complete it manually"
            ;;
    esac
    status_set "$ship_dir/status.json" auto_merge armed

    while :; do
        if pr_poll; then
            case "$pr_state" in
                merged) break ;;
                closed) fail_stage merge "$pr_url was closed without merging" ;;
            esac
            if [ "$blocking" != "$last_blocking" ]; then
                status_set "$ship_dir/status.json" blocking_reason "$blocking"
                ship_event "$ship_dir" merge waiting "$blocking"
                last_blocking=$blocking
            fi
        fi
        if [ "$elapsed" -ge "$cfg_pr_poll_timeout" ]; then
            fail_stage merge "not merged after ${cfg_pr_poll_timeout}s (pr_poll_timeout)${last_blocking:+: $last_blocking}. Auto-merge stays armed on $pr_url"
        fi
        sleep "$cfg_pr_poll_interval"
        elapsed=$((elapsed + cfg_pr_poll_interval))
    done

    status_set "$ship_dir/status.json" blocking_reason ""
    status_set "$ship_dir/status.json" merge_sha "$merged_sha"
    # Updates remote refs only; the developer's checkout and branches are
    # never touched.
    git fetch -q origin "$ship_base" || echo "WARNING: git fetch origin $ship_base failed."
    ship_event "$ship_dir" merge passed "merged into $ship_base as $(printf '%s' "$merged_sha" | cut -c1-12)"
}

stage_verify_deploy() {
    local rc=0
    cur_stage=verify_deploy
    merged_sha=$(status_get "$ship_dir/status.json" merge_sha)
    ship_event "$ship_dir" verify_deploy running "looking for the $cfg_deploy_pipeline run on $(printf '%s' "$merged_sha" | cut -c1-12)"
    deploy_verify "$merged_sha" || rc=$?
    case "$rc" in
        0) ship_event "$ship_dir" verify_deploy passed "$deploy_msg" ;;
        2) ship_event "$ship_dir" verify_deploy skipped "$deploy_msg" ;;
        *) fail_stage verify_deploy "$deploy_msg" ;;
    esac
}

# finish <state> <message> — records the end of the ship and exits. A passed
# ship removes its worktree and local snapshot branch; any other keeps both for
# inspection.
finish() {
    local state=$1 msg=$2
    trap - EXIT INT TERM
    if [ "$state" = passed ]; then
        cd "$repo_root" || true
        ship_remove_leftovers "$ship_dir"
        case "$cfg_ship_stage" in
            push) msg="$msg. Pushed $snapshot: open a PR from it into $ship_base yourself" ;;
            open_pr) msg="$msg. PR: $(status_get "$ship_dir/status.json" pr_url)" ;;
            *) msg="$msg. If you're done with $source_branch: git branch -d $source_branch" ;;
        esac
    else
        msg="$msg. Kept for inspection: worktree $worktree, branch $snapshot, log $ship_dir/ship.log"
    fi
    # The finish event lands before finished_at, so anything that stops
    # watching at finished_at has already seen it.
    ship_event "$ship_dir" finish "$state" "$msg"
    status_set "$ship_dir/status.json" finished_at "$(iso_now)"
    rm -f "$ship_dir/pid"
    [ "$state" = passed ]
    exit
}

# shellcheck disable=SC2329 # invoked by trap
on_signal() {
    ship_event "$ship_dir" "${cur_stage:-push}" stopped "stopped by /ship stop or a signal"
    finish stopped "stopped at ${cur_stage:-push}"
}

# shellcheck disable=SC2329 # invoked by trap
on_exit() {
    ship_event "$ship_dir" "${cur_stage:-push}" failed "ship.sh exited unexpectedly"
    finish failed "failed at ${cur_stage:-push}"
}

# run_stages — everything after kickoff, in the worktree. The ship's own
# process, whether it's the foreground run or the detached one.
run_stages() {
    echo "$$" > "$ship_dir/pid"
    trap on_signal INT TERM
    trap on_exit EXIT
    cd "$worktree" || die "worktree $worktree is gone."
    resolve_config
    export REVIEW_BASE_BRANCH=$ship_base
    stage_push
    stage_at_least open_pr || finish passed "shipped to push"
    stage_open_pr
    stage_at_least merge || finish passed "shipped to open_pr"
    stage_merge
    stage_at_least verify_deploy || finish passed "shipped to merge"
    stage_verify_deploy
    finish passed "shipped to verify_deploy"
}

# load_ship <id> — the ship's names and paths, from its status.json.
load_ship() {
    ship_dir=$(ship_resolve_dir "$1") || die "no ship with ID '$1'."
    ship_id=$(status_get "$ship_dir/status.json" id)
    source_branch=$(status_get "$ship_dir/status.json" source_branch)
    snapshot=$(status_get "$ship_dir/status.json" snapshot_branch)
    snapshot_sha=$(status_get "$ship_dir/status.json" snapshot_sha)
    worktree=$(status_get "$ship_dir/status.json" worktree)
    repo_root=$(status_get "$ship_dir/status.json" repo_root)
}

if [ "$mode" = resume ]; then
    load_ship "$ship_id"
    exec >> "$ship_dir/ship.log" 2>&1
    run_stages
fi

# --- kickoff (in the developer's checkout) -----------------------------------------

# rollback <message> — undoes a kickoff that failed before the ship dir existed.
rollback() {
    [ -d "$worktree" ] && git worktree remove --force "$worktree" >/dev/null 2>&1
    git branch -D "$snapshot" >/dev/null 2>&1
    ledger_set "$snapshot" "" 2>/dev/null
    die "$1 Nothing was shipped; the snapshot branch and worktree were removed."
}

planned_id=$ship_id
plan

if [ -n "$planned_id" ]; then
    # /ship planned already and the developer approved that plan.
    [ -z "$expect_sha" ] || [ "$expect_sha" = "$head_sha" ] \
        || die "HEAD moved since the plan (planned ${expect_sha:0:7}, now $sha7). Run /ship again to plan this commit."
    [ -z "$expect_config" ] || [ "$expect_config" = "$plan_hash" ] \
        || die "a setting resolves differently than in the plan (config $expect_config, now $plan_hash). Run /ship again to see the new config."
    [ ! -d "$(ship_root)/$ship_id" ] || die "ship $ship_id already exists. Run /ship again for a new plan."
fi
if [ -n "$pf_fails" ]; then
    print_block
    echo ""
    echo "Preflight failed; nothing was created. Fix the FAIL items above, then run it again." >&2
    exit 1
fi
if [ "$assume_yes" != true ]; then
    print_block
    if [ ! -t 0 ]; then
        die "no terminal to confirm on. Run make ship YES=1 (or ship.sh --yes) to ship without the prompt."
    fi
    printf 'Proceed? [y/N] '
    read -r reply
    case "$reply" in
        y | Y) ;;
        *) echo "Not shipped; nothing was created."; exit 0 ;;
    esac
fi

ship_prune "$cfg_ship_log_retention_days"
if [ -n "$leftover" ]; then
    ship_remove_leftovers "$leftover"
fi

git branch "$snapshot" "$head_sha" || die "couldn't create $snapshot."
# Seeded from the source branch's entry, so commits already reviewed there
# aren't reviewed again.
prev=$(ledger_get "$branch")
if [ -n "$prev" ]; then
    ledger_set "$snapshot" "$prev" || rollback "couldn't seed the review ledger."
fi
git worktree add -q "$worktree" "$snapshot" || rollback "git worktree add failed."
# .codereviewrc is gitignored, so the worktree doesn't have it.
[ -f .codereviewrc ] && cp .codereviewrc "$worktree/.codereviewrc"
mkdir -p "$worktree/working"
echo "Syncing dependencies in the worktree..."
(cd "$worktree" && uv sync -q) || rollback "uv sync failed in $worktree."

ship_dir="$(ship_root)/$ship_id"
mkdir -p "$ship_dir"
status_init "$ship_dir/status.json" "$(config_json)"
status_set "$ship_dir/status.json" id "$ship_id"
status_set "$ship_dir/status.json" source_branch "$branch"
status_set "$ship_dir/status.json" snapshot_branch "$snapshot"
status_set "$ship_dir/status.json" snapshot_sha "$head_sha"
status_set "$ship_dir/status.json" worktree "$worktree"
status_set "$ship_dir/status.json" repo_root "$repo_root"
status_set "$ship_dir/status.json" target_branch "$ship_base"
status_set "$ship_dir/status.json" ship_stage "$cfg_ship_stage"
status_set "$ship_dir/status.json" log "$ship_dir/ship.log"
status_set "$ship_dir/status.json" started_at "$(iso_now)"
print_block > "$ship_dir/ship.log"
ln -sfn "$ship_id" "$(ship_root)/latest"
source_branch=$branch
snapshot_sha=$head_sha
ship_event "$ship_dir" kickoff passed "snapshot $snapshot, worktree $worktree" >> "$ship_dir/ship.log"

if [ "$detach" = true ]; then
    # The worktree's copy is the snapshot's own and nobody edits it mid-run;
    # the checkout's copy is the fallback when ship.sh isn't committed.
    runner="$worktree/scripts/ship.sh"
    [ -f "$runner" ] || runner="$script_dir/ship.sh"
    cd "$worktree" || die "worktree $worktree is gone."
    nohup bash "$runner" --resume "$ship_id" > /dev/null 2>&1 &
    echo $! > "$ship_dir/pid"
    echo "Ship $ship_id started in the background."
    echo "SHIP_ID=$ship_id"
    echo "Events: $ship_dir/events"
    echo "Log:    $ship_dir/ship.log"
    exit 0
fi

exec > >(tee -a "$ship_dir/ship.log") 2>&1
run_stages
