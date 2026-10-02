# shellcheck shell=bash
# Status, event and log helpers for scripts/ship.sh, plus retention pruning.
# Sourced after lib/common.sh, not executed.
#
# Each ship's files live in $(git rev-parse --git-common-dir)/ship/<id>/, which
# every worktree shares and which is never committed:
#   status.json            config block, stage, state, PR, SHAs, timestamps
#   events                 <iso-ts>\t<stage>\t<state>\t<message>, one per transition
#   ship.log               full output of every step
#   code-review-report.md  copy of the last review report
#   pid                    the ship's process ID while it's running
# ship/latest is a symlink to the newest ship directory.
#
# status.json is written by these helpers only, one "key": "value" per line
# with the config object last, so it can be read and updated with sed and awk
# instead of requiring jq.

status_keys="id source_branch snapshot_branch snapshot_sha worktree repo_root
target_branch ship_stage stage state message blocking_reason pr_url pr_id
pr_reviewers auto_merge merge_sha deploy_run_url log started_at finished_at"

# ship_root — absolute path of the directory holding every ship's files.
ship_root() {
    printf '%s/ship\n' "$(cd "$(git rev-parse --git-common-dir)" && pwd)"
}

iso_now() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# iso_to_epoch <yyyy-mm-ddThh:mm:ssZ> — BSD date first (macOS), then GNU.
iso_to_epoch() {
    date -u -j -f %Y-%m-%dT%H:%M:%SZ "$1" +%s 2>/dev/null || date -u -d "$1" +%s 2>/dev/null
}

# json_escape <string> — the string as the inside of a JSON string literal.
json_escape() {
    printf '%s' "$1" | awk 'BEGIN { ORS = "" } {
        gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); gsub(/\r/, "")
        if (NR > 1) printf "\\n"
        printf "%s", $0
    }'
}

# status_init <file> <config-json> — a status.json with every key empty.
status_init() {
    local file=$1 config=$2 key
    {
        echo "{"
        # shellcheck disable=SC2086 # word-splitting the key list is the point
        for key in $status_keys; do
            printf '  "%s": "",\n' "$key"
        done
        printf '  "config": %s\n' "$config"
        echo "}"
    } > "$file"
}

# status_set <file> <key> <value> — replaces one key's value. The value goes
# through the environment: awk -v would interpret its backslashes.
status_set() {
    local file=$1 key=$2 tmp
    tmp=$(mktemp "$file.XXXXXX")
    STATUS_VALUE=$(json_escape "$3") awk -v k="$key" '
        index($0, "  \"" k "\": ") == 1 {
            print "  \"" k "\": \"" ENVIRON["STATUS_VALUE"] "\","
            next
        }
        { print }' "$file" > "$tmp" && mv "$tmp" "$file"
}

# status_get <file> <key> — one key's value, unescaped.
status_get() {
    sed -n "s/^  \"$2\": \"\(.*\)\",\$/\1/p" "$1" 2>/dev/null \
        | sed -e 's/\\"/"/g' -e 's/\\\\/\\/g'
}

# ship_notify <message> — a desktop notification when ship_notify=desktop:
# osascript on macOS, a toast through powershell.exe on Windows (Git Bash or
# WSL), notify-send on Linux. Does nothing when none of them is installed.
ship_notify() {
    [ "$(rc_value ship_notify)" = desktop ] || return 0
    local msg q="'"
    msg=$(printf '%s' "$1" | tr "\"\\\\" "'/")
    if command -v osascript >/dev/null 2>&1; then
        osascript -e "display notification \"$msg\" with title \"ship\""
    elif command -v powershell.exe >/dev/null 2>&1; then
        # The toast is shown under PowerShell's app ID, which Windows always
        # has registered. The message goes in as a text node, so it needs no
        # XML escaping, only PowerShell's '' for a quote.
        powershell.exe -NoProfile -NonInteractive -Command "
            \$null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
            \$xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
            \$text = \$xml.GetElementsByTagName('text')
            \$null = \$text.Item(0).AppendChild(\$xml.CreateTextNode('ship'))
            \$null = \$text.Item(1).AppendChild(\$xml.CreateTextNode('${msg//$q/$q$q}'))
            [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\\WindowsPowerShell\\v1.0\\powershell.exe').Show([Windows.UI.Notifications.ToastNotification]::new(\$xml))"
    elif command -v notify-send >/dev/null 2>&1; then
        notify-send ship "$msg"
    fi >/dev/null 2>&1 || true
}

# ship_event <ship-dir> <stage> <state> <message> — appends to events, updates
# status.json, prints the event to the log, and notifies when the ship finishes.
ship_event() {
    local dir=$1 stage=$2 state=$3 msg
    msg=$(printf '%s' "$4" | tr '\t\n' '  ')
    printf '%s\t%s\t%s\t%s\n' "$(iso_now)" "$stage" "$state" "$msg" >> "$dir/events"
    status_set "$dir/status.json" stage "$stage"
    status_set "$dir/status.json" state "$state"
    status_set "$dir/status.json" message "$msg"
    echo ""
    echo "==> [$stage] $state: $msg"
    [ "$stage" != finish ] || ship_notify "$state: $msg"
}

# ship_pid_alive <ship-dir> — true while the ship's recorded process runs.
ship_pid_alive() {
    local pid
    pid=$(cat "$1/pid" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# ship_is_running <ship-dir> — a live pid and no finished_at.
ship_is_running() {
    [ -z "$(status_get "$1/status.json" finished_at)" ] && ship_pid_alive "$1"
}

# ship_dirs — every ship directory, oldest first (IDs start with a timestamp).
ship_dirs() {
    local root d
    root=$(ship_root)
    [ -d "$root" ] || return 0
    for d in "$root"/*/; do
        d=${d%/}
        [ -L "$d" ] || [ ! -f "$d/status.json" ] || echo "$d"
    done
}

# ship_resolve_dir <id> — the directory of ship <id>; "latest" or empty means
# the newest ship.
ship_resolve_dir() {
    local root id=${1:-latest}
    root=$(ship_root)
    if [ "$id" = latest ]; then
        id=$(readlink "$root/latest" 2>/dev/null) || return 1
    fi
    [ -f "$root/$id/status.json" ] && echo "$root/$id"
}

# ship_remove_leftovers <ship-dir> — removes the worktree and local snapshot
# branch a finished ship kept, plus the snapshot's ledger entry.
ship_remove_leftovers() {
    local file=$1/status.json wt branch
    wt=$(status_get "$file" worktree)
    branch=$(status_get "$file" snapshot_branch)
    [ -n "$wt" ] && [ -d "$wt" ] && git worktree remove --force "$wt" >/dev/null 2>&1
    git worktree prune >/dev/null 2>&1
    if [ -n "$branch" ] && git rev-parse -q --verify "refs/heads/$branch" >/dev/null; then
        git branch -D "$branch" >/dev/null 2>&1
    fi
    [ -n "$branch" ] && ledger_set "$branch" ""
    return 0
}

# ship_prune <retention-days> — deletes ship directories whose finished_at is
# more than <retention-days> old, with anything they left behind. Never touches
# a running ship or whatever latest points to. 0 turns pruning off.
ship_prune() {
    local days=$1 now latest d finished epoch
    [ "$days" -gt 0 ] || return 0
    now=$(date -u +%s)
    latest=$(readlink "$(ship_root)/latest" 2>/dev/null)
    for d in $(ship_dirs); do
        [ "${d##*/}" = "$latest" ] && continue
        ship_pid_alive "$d" && continue
        finished=$(status_get "$d/status.json" finished_at)
        [ -n "$finished" ] || continue
        epoch=$(iso_to_epoch "$finished") || continue
        [ $((now - epoch)) -gt $((days * 86400)) ] || continue
        ship_remove_leftovers "$d"
        rm -rf "$d"
        echo "Pruned ship ${d##*/} (finished $finished)."
    done
}

# ship_descendants <pid> — every descendant process ID, depth first.
ship_descendants() {
    local child
    for child in $(pgrep -P "$1" 2>/dev/null); do
        echo "$child"
        ship_descendants "$child"
    done
}

# ship_summary <ship-dir> — a few lines describing one ship.
ship_summary() {
    local f=$1/status.json state reason
    state=$(status_get "$f" state)
    if [ -z "$(status_get "$f" finished_at)" ] && ! ship_pid_alive "$1"; then
        state="$state (process gone: ship.sh died without finishing)"
    fi
    printf '%s  %s  %s  %s\n' "$(status_get "$f" id)" "$(status_get "$f" stage)" "$state" "$(status_get "$f" message)"
    printf '    %s -> %s, stage %s\n' "$(status_get "$f" source_branch)" "$(status_get "$f" target_branch)" "$(status_get "$f" ship_stage)"
    reason=$(status_get "$f" blocking_reason)
    [ -n "$reason" ] && printf '    waiting on: %s\n' "$reason"
    [ -n "$(status_get "$f" pr_url)" ] && printf '    PR: %s\n' "$(status_get "$f" pr_url)"
    [ -n "$(status_get "$f" merge_sha)" ] && printf '    merge commit: %s\n' "$(status_get "$f" merge_sha)"
    [ -n "$(status_get "$f" deploy_run_url)" ] && printf '    deploy run: %s\n' "$(status_get "$f" deploy_run_url)"
    [ -f "$1/code-review-report.md" ] && printf '    review report: %s\n' "$1/code-review-report.md"
    printf '    log: %s\n' "$(status_get "$f" log)"
}

# ship_status_report [id] — one ship's summary, or every running ship plus the
# last five finished ones.
ship_status_report() {
    local d running=0 finished_dirs=""
    if [ -n "${1:-}" ]; then
        d=$(ship_resolve_dir "$1") || { echo "No ship with ID '$1'." >&2; return 1; }
        ship_summary "$d"
        return
    fi
    for d in $(ship_dirs); do
        if [ -z "$(status_get "$d/status.json" finished_at)" ]; then
            [ "$running" -eq 0 ] && echo "Running:"
            running=$((running + 1))
            ship_summary "$d"
        else
            finished_dirs="$finished_dirs $d"
        fi
    done
    [ "$running" -eq 0 ] && echo "No ships running."
    # shellcheck disable=SC2086 # word-splitting the dir list is the point
    finished_dirs=$(printf '%s\n' $finished_dirs | tail -n 5)
    if [ -n "$finished_dirs" ]; then
        echo ""
        echo "Recently finished:"
        for d in $finished_dirs; do
            ship_summary "$d"
        done
    fi
}

# ship_watch [id] — prints the ship's events as they arrive, one line each,
# and exits when it finishes: 0 if it passed. Also exits if ship.sh died
# without recording a finish. /ship runs this under a Monitor.
ship_watch() {
    local d f shown=0 total
    d=$(ship_resolve_dir "${1:-}") || { echo "No ship with ID '${1:-latest}'." >&2; return 1; }
    f=$d/events
    while :; do
        total=$(wc -l < "$f" | tr -d ' ')
        if [ "$total" -gt "$shown" ]; then
            sed -n "$((shown + 1)),${total}p" "$f" | awk -F '\t' '{ print $2 " " $3 ": " $4; fflush() }'
            shown=$total
        fi
        if [ -n "$(status_get "$d/status.json" finished_at)" ]; then
            # One more pass in case the finish line landed after the count.
            sed -n "$((shown + 1)),\$p" "$f" | awk -F '\t' '{ print $2 " " $3 ": " $4 }'
            [ "$(status_get "$d/status.json" state)" = passed ]
            return
        fi
        if ! ship_pid_alive "$d"; then
            sleep 2
            [ -n "$(status_get "$d/status.json" finished_at)" ] && continue
            echo "ship.sh exited without finishing; see $(status_get "$d/status.json" log)"
            return 1
        fi
        sleep 3
    done
}

# ship_stop [id] — stops a running ship: TERM to ship.sh (its trap records
# `stopped`) and to everything it started (git push, the review agents, the
# smoke test). With no ID, stops the only running ship. Reports what's left.
ship_stop() {
    local d pid pids waited=0 f running="" stage
    if [ -n "${1:-}" ]; then
        d=$(ship_resolve_dir "$1") || { echo "No ship with ID '$1'." >&2; return 1; }
    else
        for d in $(ship_dirs); do
            ship_is_running "$d" && running="$running $d"
        done
        # shellcheck disable=SC2086 # counting words is the point
        set -- $running
        case $# in
            0) echo "No ships running."; return 0 ;;
            1) d=$1 ;;
            *) echo "More than one ship is running; name one: ${running//$(ship_root)\//}" >&2; return 1 ;;
        esac
    fi
    f=$d/status.json
    if ! ship_is_running "$d"; then
        echo "Ship ${d##*/} isn't running (state: $(status_get "$f" state))."
        return 0
    fi
    pid=$(cat "$d/pid")
    stage=$(status_get "$f" stage)
    # Collected before the TERM: once ship.sh exits, its children are
    # reparented and can no longer be found from its PID.
    pids=$(ship_descendants "$pid")
    kill -TERM "$pid" 2>/dev/null
    # shellcheck disable=SC2086 # one PID per word
    [ -n "$pids" ] && kill -TERM $pids 2>/dev/null
    while [ -z "$(status_get "$f" finished_at)" ] && [ "$waited" -lt 15 ]; do
        sleep 1
        waited=$((waited + 1))
    done
    if [ -z "$(status_get "$f" finished_at)" ]; then
        # ship.sh didn't get to record it (killed hard, or stuck): record it here.
        kill -KILL "$pid" 2>/dev/null
        ship_event "$d" "$stage" stopped "stopped by /ship stop" > /dev/null
        ship_event "$d" finish stopped "stopped at $stage" > /dev/null
        status_set "$f" finished_at "$(iso_now)"
        rm -f "$d/pid"
    fi
    echo "Stopped ship ${d##*/} at stage $stage."
    if [ -n "$(status_get "$f" pr_url)" ] && [ -z "$(status_get "$f" merge_sha)" ]; then
        echo "  PR still open: $(status_get "$f" pr_url)"
        [ "$(status_get "$f" auto_merge)" = armed ] \
            && echo "  Auto-merge/auto-complete is still armed: it merges once the PR's checks pass. Cancel it on the PR if that's not wanted."
    fi
    # A prod ship has neither.
    [ -n "$(status_get "$f" worktree)" ] && echo "  Worktree kept: $(status_get "$f" worktree)"
    [ -n "$(status_get "$f" snapshot_branch)" ] && echo "  Snapshot branch kept: $(status_get "$f" snapshot_branch)"
    return 0
}
