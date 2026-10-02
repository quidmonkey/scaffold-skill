# shellcheck shell=bash
# Deploy verification for scripts/ship.sh's verify_deploy stage, dev only:
# find the deploy_pipeline run on the merge commit, wait for it, check the
# target is healthy and running that commit, then run the smoke test.
# Sourced after lib/common.sh; uses ship.sh's cfg_*, pf_* and status helpers.
#
# gcloud calls are read-only. The Agent Runtime checks call the Vertex AI REST
# API with a token fetched here; it goes to curl on stdin, never on a command
# line or into the log.

# cfg_<key>, ship_dir and ship_base are set by ship.sh.
# shellcheck disable=SC2154

deploy_auth_ok() {
    [ -n "$(gcloud config get-value account 2>/dev/null)" ]
}

# deploy_py <code> [args...] — runs python code with the JSON on stdin as d.
# --no-project: parsing JSON needs no project env, and the plan must not sync it.
deploy_py() {
    local code=$1
    shift
    uv run --no-project --quiet python -c "import json, sys
d = json.load(sys.stdin)
$code" "$@"
}

# deploy_after <iso-a> <iso-b> — true if timestamp a is later than b. Accepts
# the formats gcloud, Vertex AI, GitHub and ADO emit (Z or offset, 0-9
# fractional digits).
deploy_after() {
    uv run --no-project --quiet python -c '
import re, sys
from datetime import datetime
def parse(s):
    s = re.sub(r"\.(\d+)", lambda m: "." + (m.group(1) + "000000")[:6], s.strip())
    return datetime.fromisoformat(s.replace("Z", "+00:00"))
sys.exit(0 if parse(sys.argv[1]) > parse(sys.argv[2]) else 1)' "$1" "$2"
}

# deploy_az_pipeline_id — deploy_pipeline as an ADO pipeline ID.
deploy_az_pipeline_id() {
    case "$cfg_deploy_pipeline" in
        *[!0-9]*) az pipelines show --name "$cfg_deploy_pipeline" --query id -o tsv 2>/dev/null ;;
        *) az pipelines show --id "$cfg_deploy_pipeline" --query id -o tsv 2>/dev/null ;;
    esac
}

# deploy_cloud_run_json — the Cloud Run service's description.
deploy_cloud_run_json() {
    gcloud run services describe "$cfg_deploy_name" --project "$cfg_deploy_project" \
        --region "$cfg_deploy_region" --format=json 2>/dev/null
}

# deploy_engine — "<resource>\t<commit label>\t<updateTime>" for the reasoning
# engine whose display name is deploy_name. Reads the first 100 engines only;
# a project with more needs nextPageToken handling here.
deploy_engine() {
    local token url
    token=$(gcloud auth print-access-token 2>/dev/null) || return 1
    url="https://$cfg_deploy_region-aiplatform.googleapis.com/v1/projects/$cfg_deploy_project/locations/$cfg_deploy_region/reasoningEngines?pageSize=100"
    printf 'Authorization: Bearer %s\n' "$token" | curl -fsS -H @- "$url" 2>/dev/null \
        | deploy_py '
e = [x for x in d.get("reasoningEngines", []) if x.get("displayName") == sys.argv[1]]
if not e:
    sys.exit(1)
e = e[0]
print(e["name"], e.get("labels", {}).get("commit", ""), e.get("updateTime", ""), sep="\t")' "$cfg_deploy_name"
}

deploy_preflight() {
    local key missing="" account
    for key in deploy_pipeline deploy_provider deploy_project deploy_region deploy_name deploy_smoke; do
        [ -n "$(cfg "$key")" ] || missing="$missing $key"
    done
    if [ -n "$missing" ]; then
        pf_fail "verify_deploy needs these set in .codereviewrc (or with --set):$missing."
        return
    fi
    # agent_engine is Agent Runtime's earlier name; both read the same API.
    check_enum deploy_provider cloud_run agent_runtime agent_engine

    case "$cfg_pr_host" in
        gh)
            gh workflow view "$cfg_deploy_pipeline" >/dev/null 2>&1 \
                || pf_fail "deploy_pipeline '$cfg_deploy_pipeline' isn't a GitHub workflow in this repo (gh workflow view failed)."
            ;;
        az)
            [ -n "$(deploy_az_pipeline_id)" ] \
                || pf_fail "deploy_pipeline '$cfg_deploy_pipeline' isn't an Azure DevOps pipeline name or ID (az pipelines show failed)."
            ;;
    esac

    if ! command -v gcloud >/dev/null 2>&1; then
        pf_fail "gcloud isn't installed. Install the Google Cloud CLI, then /ship again."
        return
    fi
    account=$(gcloud config get-value account 2>/dev/null)
    if [ -z "$account" ]; then
        pf_fail "gcloud has no active account. Run \`! gcloud auth login\` in the session, then /ship again."
        return
    fi
    pf_account gcloud "$account"
    case "$cfg_deploy_provider" in
        cloud_run)
            deploy_cloud_run_json >/dev/null \
                || pf_fail "gcloud can't read Cloud Run service '$cfg_deploy_name' in $cfg_deploy_project/$cfg_deploy_region. Check deploy_name, deploy_project, deploy_region and your access."
            ;;
        agent_runtime | agent_engine)
            deploy_engine >/dev/null \
                || pf_fail "No Agent Runtime named '$cfg_deploy_name' is readable in $cfg_deploy_project/$cfg_deploy_region. Check deploy_name, deploy_project, deploy_region and your access."
            ;;
    esac
    pf_ok "deploy target readable ($cfg_deploy_provider '$cfg_deploy_name')"
}

# deploy_find_run <sha> — the pipeline run on develop whose source commit is
# <sha>. Sets run_id, run_status, run_start, run_url, run_result.
deploy_find_run() {
    local out
    run_id=""
    case "$cfg_pr_host" in
        gh)
            out=$(gh run list --workflow "$cfg_deploy_pipeline" --commit "$1" --branch "$ship_base" \
                --json databaseId,status,createdAt,url,conclusion \
                --jq '.[0] // empty | [.databaseId, .status, .createdAt, .url, .conclusion] | @tsv' 2>/dev/null)
            ;;
        az)
            out=$(az pipelines runs list --pipeline-ids "$az_pipeline_id" --branch "$ship_base" --top 50 \
                --query "[?sourceVersion=='$1'] | [0].[id, status, startTime || queueTime, _links.web.href, result]" \
                -o tsv 2>/dev/null | tr '\n' '\t')
            ;;
    esac
    # The nullable result/conclusion is last, so an empty one can't shift the
    # fields before it.
    IFS=$'\t' read -r run_id run_status run_start run_url run_result <<< "$out"
    [ -n "$run_id" ]
}

# deploy_az_approval_pending — best-effort: an ADO run waiting on an approval
# check. Failure to tell reads as "no".
deploy_az_approval_pending() {
    local project count
    project=$(az devops configure --list 2>/dev/null | sed -n 's/^project = //p')
    count=$(az devops invoke --area build --resource timeline \
        --route-parameters project="$project" buildId="$run_id" \
        --query "length(records[?type=='Checkpoint.Approval' && state=='inProgress'])" -o tsv 2>/dev/null)
    [ "${count:-0}" -gt 0 ] 2>/dev/null
}

# deploy_wait_run — polls the found run until it completes. Returns 0 if it
# succeeded.
deploy_wait_run() {
    local elapsed=0 reason last=""
    while :; do
        case "$run_status" in
            completed) break ;;
            waiting) reason="deploy run is waiting on an environment approval" ;;
            *)
                reason="deploy run is $run_status"
                [ "$cfg_pr_host" = az ] && deploy_az_approval_pending && reason="deploy run is waiting on an approval check"
                ;;
        esac
        if [ "$reason" != "$last" ]; then
            status_set "$ship_dir/status.json" blocking_reason "$reason"
            ship_event "$ship_dir" verify_deploy waiting "$reason: $run_url"
            last=$reason
        fi
        if [ "$elapsed" -ge "$cfg_deploy_poll_timeout" ]; then
            deploy_msg="deploy run still not finished after ${cfg_deploy_poll_timeout}s (deploy_poll_timeout): $run_url"
            return 1
        fi
        sleep "$cfg_pr_poll_interval"
        elapsed=$((elapsed + cfg_pr_poll_interval))
        deploy_find_run "$merge_sha" || true
    done
    status_set "$ship_dir/status.json" blocking_reason ""
    case "$run_result" in
        success | succeeded) return 0 ;;
    esac
    deploy_msg="deploy run finished as '${run_result:-unknown}': $run_url"
    return 1
}

# deploy_check_health — the target is healthy and running the merge commit.
# Sets deploy_url / deploy_resource for the smoke test.
deploy_check_health() {
    local sha12 out ready latest pct created commit updated
    sha12=$(printf '%s' "$merge_sha" | cut -c1-12)
    deploy_url=""
    deploy_resource=""
    case "$cfg_deploy_provider" in
        cloud_run)
            out=$(deploy_cloud_run_json | deploy_py '
st = d.get("status", {})
latest = st.get("latestReadyRevisionName", "")
ready = any(c.get("type") == "Ready" and c.get("status") == "True" for c in st.get("conditions", []))
pct = sum(t.get("percent", 0) for t in st.get("traffic", [])
          if t.get("revisionName") == latest or t.get("latestRevision"))
print(ready, latest, pct, st.get("url", ""), sep="\t")') \
                || { deploy_msg="couldn't describe Cloud Run service $cfg_deploy_name"; return 1; }
            IFS=$'\t' read -r ready latest pct deploy_url <<< "$out"
            if [ "$ready" != True ] || [ "$pct" != 100 ]; then
                deploy_msg="Cloud Run service $cfg_deploy_name isn't healthy: Ready=$ready, $pct% of traffic on latest ready revision $latest"
                return 1
            fi
            if [ "$cfg_deploy_match" = sha ]; then
                # Either tagging works: a <service>-<sha12> revision name
                # (gcloud --revision-suffix) or a commit=<sha12> label
                # (agents-cli deploy --labels, which has no suffix flag).
                [ "$latest" = "$cfg_deploy_name-$sha12" ] \
                    || [ "$(gcloud run revisions describe "$latest" --project "$cfg_deploy_project" \
                        --region "$cfg_deploy_region" --format='value(metadata.labels.commit)' 2>/dev/null)" = "$sha12" ] \
                    || {
                        deploy_msg="latest ready revision $latest is neither named $cfg_deploy_name-$sha12 nor labeled commit=$sha12 (deploy_match=sha)"
                        return 1
                    }
            else
                created=$(gcloud run revisions describe "$latest" --project "$cfg_deploy_project" \
                    --region "$cfg_deploy_region" --format='value(metadata.creationTimestamp)' 2>/dev/null)
                deploy_after "$created" "$run_start" || {
                    deploy_msg="latest ready revision $latest was created at $created, before the deploy run started ($run_start)"
                    return 1
                }
            fi
            deploy_msg="Cloud Run $cfg_deploy_name healthy on $latest"
            ;;
        agent_runtime | agent_engine)
            out=$(deploy_engine) || { deploy_msg="couldn't read Agent Runtime '$cfg_deploy_name'"; return 1; }
            IFS=$'\t' read -r deploy_resource commit updated <<< "$out"
            if [ "$cfg_deploy_match" = sha ]; then
                [ "$commit" = "$sha12" ] || {
                    deploy_msg="Agent Runtime '$cfg_deploy_name' has commit label '${commit:-none}', not $sha12 (deploy_match=sha)"
                    return 1
                }
            else
                deploy_after "$updated" "$run_start" || {
                    deploy_msg="Agent Runtime '$cfg_deploy_name' was last updated at $updated, before the deploy run started ($run_start)"
                    return 1
                }
            fi
            deploy_msg="Agent Runtime $deploy_resource updated"
            ;;
    esac
}

# deploy_free_port — an unused local TCP port.
deploy_free_port() {
    uv run --no-project --quiet python -c 'import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

# deploy_smoke_run — runs deploy_smoke in the worktree with DEPLOY_URL,
# DEPLOY_RESOURCE and DEPLOY_SHA set; its exit code is the result. With
# deploy_proxy=true, DEPLOY_URL is a local gcloud run services proxy, for
# private services a user credential can't mint an ID token for.
deploy_smoke_run() {
    local url=$deploy_url proxy_pid="" port waited=0 rc=0
    if [ "$cfg_deploy_provider" = cloud_run ] && [ "$cfg_deploy_proxy" = true ]; then
        port=$(deploy_free_port)
        gcloud run services proxy "$cfg_deploy_name" --project "$cfg_deploy_project" \
            --region "$cfg_deploy_region" --port "$port" &
        proxy_pid=$!
        url="http://localhost:$port"
        until curl -s -o /dev/null "$url"; do
            if [ "$waited" -ge 30 ] || ! kill -0 "$proxy_pid" 2>/dev/null; then
                kill "$proxy_pid" 2>/dev/null
                deploy_msg="gcloud run services proxy didn't come up on port $port within 30s"
                return 1
            fi
            sleep 1
            waited=$((waited + 1))
        done
    fi
    echo "Running smoke test: $cfg_deploy_smoke"
    (
        export DEPLOY_URL=$url DEPLOY_RESOURCE=$deploy_resource DEPLOY_SHA=$merge_sha
        with_timeout "$cfg_deploy_smoke_timeout" sh -c "$cfg_deploy_smoke"
    ) || rc=$?
    if [ -n "$proxy_pid" ]; then
        # shellcheck disable=SC2046 # one PID per word
        kill $(ship_descendants "$proxy_pid") "$proxy_pid" 2>/dev/null
    fi
    case "$rc" in
        0) return 0 ;;
        124) deploy_msg="smoke test timed out after ${cfg_deploy_smoke_timeout}s (deploy_smoke_timeout)" ;;
        *) deploy_msg="smoke test failed (exit $rc); see the log" ;;
    esac
    return 1
}

# deploy_verify <merge-sha> — the whole stage. Returns 0 (passed), 2 (skipped:
# no run was triggered) or 1 (failed), with deploy_msg saying why.
deploy_verify() {
    local elapsed=0 health
    merge_sha=$1
    az_pipeline_id=""
    if [ "$cfg_pr_host" = az ]; then
        az_pipeline_id=$(deploy_az_pipeline_id)
        [ -n "$az_pipeline_id" ] || { deploy_msg="couldn't resolve pipeline '$cfg_deploy_pipeline'"; return 1; }
    fi

    # A run that never shows up means the pipeline's path filters excluded
    # this change: nothing to verify.
    until deploy_find_run "$merge_sha"; do
        if [ "$elapsed" -ge "$cfg_deploy_run_grace" ]; then
            deploy_msg="no deploy triggered (no $cfg_deploy_pipeline run on $(printf '%s' "$merge_sha" | cut -c1-12) within ${cfg_deploy_run_grace}s)"
            return 2
        fi
        sleep "$cfg_pr_poll_interval"
        elapsed=$((elapsed + cfg_pr_poll_interval))
    done
    status_set "$ship_dir/status.json" deploy_run_url "$run_url"
    echo "Found deploy run: $run_url"

    deploy_wait_run || return 1
    deploy_check_health || return 1
    health=$deploy_msg
    deploy_smoke_run || return 1
    deploy_msg="$health; smoke test passed"
}
