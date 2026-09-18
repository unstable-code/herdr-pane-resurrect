#!/usr/bin/env bash
# Shared helpers for bin/save, bin/restore and bin/autosave.

herdr=${HERDR_BIN_PATH:-herdr}
plugin_root=${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
state_dir=${HERDR_PLUGIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr-pane-resurrect}
config_dir=${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-pane-resurrect}
state_file="$state_dir/panes.json"

# config.toml is read with sed rather than a TOML parser: this plugin is four shell scripts with a
# handful of scalar settings. Unknown keys are ignored.
config_value() {
    local key=$1 default=$2 value
    value=$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$config_dir/config.toml" 2>/dev/null |
        head -1 | sed 's/[[:space:]]*#.*$//' | tr -d '"'"'"'\t\r')
    printf '%s\n' "${value:-$default}"
}

# Command basenames that are never saved, space separated. Idle shells are already skipped, so this
# is for programs that should not come back — a long build, say, or something that prompts on start.
exclude_names=$(config_value exclude "")

truthy() { case "$1" in true | 1 | yes | on) return 0 ;; *) return 1 ;; esac }

notify() {
    truthy "$(config_value notify true)" || return 0
    "$herdr" notification show "$1" --body "$2" >/dev/null 2>&1 || true
}

# A workspace keeps its id across a restart (session.json stores it as "id": "w3"), and so does a
# tab's number (public_tab_numbers). Pane ids do not — they are handed out afresh — which is why a
# record is keyed by workspace id + tab number + the pane's position inside that tab.
#
# Everything a save needs comes from three list calls plus one process-info per pane. Agent panes are
# left out entirely: herdr resumes those itself ([session] resume_agents_on_restore), so replaying
# them would start a second copy of the same agent.
collect() {
    local panes tabs workspaces procs pane_id info
    panes=$("$herdr" pane list 2>/dev/null) || return 1
    tabs=$("$herdr" tab list 2>/dev/null) || return 1
    workspaces=$("$herdr" workspace list 2>/dev/null) || return 1
    [ -n "$panes" ] && [ -n "$tabs" ] && [ -n "$workspaces" ] || return 1

    procs=$(
        while IFS= read -r pane_id; do
            [ -n "$pane_id" ] || continue
            info=$("$herdr" pane process-info --pane "$pane_id" 2>/dev/null) || continue
            jq -c '.result.process_info' <<<"$info" 2>/dev/null
        done < <(jq -r '.result.panes[] | select(has("agent") | not) | .pane_id' <<<"$panes") | jq -s -c .
    )
    [ -n "$procs" ] || return 1

    jq -n -c \
        --argjson panes "$(jq -c '.result.panes' <<<"$panes")" \
        --argjson tabs "$(jq -c '.result.tabs' <<<"$tabs")" \
        --argjson workspaces "$(jq -c '.result.workspaces' <<<"$workspaces")" \
        --argjson procs "$procs" \
        --arg exclude "$exclude_names" \
        --arg root "$plugin_root" '
        ($exclude | split(" ") | map(select(length > 0))) as $excluded
        | ($panes | map({key: .pane_id, value: .}) | from_entries) as $pane_by_id
        | ($tabs | map({key: .tab_id, value: .}) | from_entries) as $tab_by_id
        | ($workspaces | map({key: .workspace_id, value: .}) | from_entries) as $ws_by_id
        | [ $procs[]
            | . as $p
            # The group leader is the command that was typed; the other members are its children
            # (a pipeline, or watch running its argument through a shell). Restoring the leader
            # replays the whole thing, restoring a child would replay a fragment of it.
            | ($p.foreground_processes // []) as $fg
            | (($fg | map(select(.pid == $p.foreground_process_group_id)) | first) // ($fg | first)) as $leader
            | select($leader != null and ($leader.argv | type) == "array" and ($leader.argv | length) > 0)
            # The foreground process group being the shell itself means the pane sits at a prompt.
            | select($p.foreground_process_group_id != $p.shell_pid)
            | select(($leader.argv[0] | split("/") | last) as $name | ($excluded | index($name)) | not)
            # Never record this plugin: a save that runs while restore is working would otherwise
            # write restore itself into the snapshot.
            | select($leader.argv[0] | startswith($root) | not)
            | $pane_by_id[$p.pane_id] as $pane
            | select($pane != null)
            | $tab_by_id[$pane.tab_id] as $tab
            | select($tab != null)
            | {
                ws: $pane.workspace_id,
                ws_label: ($ws_by_id[$pane.workspace_id].label // ""),
                tab: ($tab.number // 0),
                tab_label: ($tab.label // ""),
                idx: ([$panes[] | select(.tab_id == $pane.tab_id) | .pane_id] | index($pane.pane_id) // 0),
                cwd: ($leader.cwd // $pane.foreground_cwd // $pane.cwd // ""),
                argv: $leader.argv,
              } ]
        | sort_by([.ws, .tab, .idx])'
}

# Human-readable form of a record, used by both the save listing and the restore listing.
record_line() {
    jq -r '
        (if (.ws_label // "") == "" then .ws else .ws_label end) as $ws
        | (if (.tab_label // "") == "" then (.tab | tostring) else .tab_label end) as $tab
        | "\($ws)/\($tab)  \(.argv | join(" "))"' <<<"$1"
}

# Write the snapshot only when it differs, so an autosave tick that finds nothing new does not
# rewrite the file every interval.
store() {
    local records=$1 previous
    mkdir -p "$state_dir" 2>/dev/null || return 1
    previous=$(cat "$state_file" 2>/dev/null)
    [ "$records" = "$previous" ] && return 2
    printf '%s\n' "$records" >"$state_file.tmp" && mv "$state_file.tmp" "$state_file"
}

# Start bin/autosave unless it is already running. The [[startup]] hook only fires when the herdr
# server starts, so a plugin installed into a running server would have no daemon until the next
# restart; this also brings it back if it was killed.
ensure_autosave() {
    truthy "$(config_value autosave true)" || return 0
    local pidfile="$state_dir/autosave.pid" pid
    pid=$(cat "$pidfile" 2>/dev/null) || pid=""
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    "$(dirname "${BASH_SOURCE[0]}")/autosave" --spawn >/dev/null 2>&1 &
    return 0
}
