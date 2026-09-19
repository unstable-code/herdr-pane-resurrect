#!/usr/bin/env bash
# Shared helpers for bin/save, bin/restore and bin/autosave.

herdr=${HERDR_BIN_PATH:-herdr}
plugin_root=${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
state_dir=${HERDR_PLUGIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr-pane-resurrect}
config_dir=${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-pane-resurrect}
state_file="$state_dir/panes.json"
# Present while a freshly started server waits for its restore; bin/autosave explains why.
# shellcheck disable=SC2034  # used by the scripts that source this file
hold_file="$state_dir/hold"

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

# Directories a restart empties. A command whose arguments point in here names something that will
# not exist when it is replayed.
ephemeral_dirs="${XDG_RUNTIME_DIR:-/run/user/$(id -u)} ${TMPDIR:-}"

# Whether an argv is worth replaying, as a jq function over the argv array. Save uses it to decide
# what to record, and restore applies it again to what was recorded: a snapshot written by an older
# version, or before a rule was added, would otherwise keep replaying something this one refuses.
# Callers pass --arg ephemeral "$ephemeral_dirs" --arg exclude "$exclude_names".
# (No apostrophes in here: the whole thing is one single-quoted shell string.)
# shellcheck disable=SC2016  # jq variables, not shell ones: they must reach jq unexpanded
replayable_jq='
def replayable:
    ($ephemeral | split(" ") | map(select(length > 1) | rtrimstr("/")) | unique) as $dirs
    | ($exclude | split(" ") | map(select(length > 0))) as $excluded
    | (.[0] | split("/") | last | ltrimstr("-")) as $name
    # An interactive shell started inside the pane is a prompt too, just a nested one, and the
    # environment that made it (sudo -i, the packages of a nix-shell) is not in its argv, so there is
    # nothing to replay. "Interactive" means nothing but options follow the name of the shell:
    # `bash -c ...` and `bash ./deploy.sh` are real commands and are kept.
    | ((["bash", "zsh", "sh", "dash", "ksh", "mksh", "fish", "tcsh", "csh", "nu", "elvish", "xonsh"]
        | index($name)) != null and (.[1:] | all(startswith("-")))) as $interactive
    # A command pointing into the runtime or temp directory names something a restart removes. This
    # is the shape nix-shell leaves behind: it execs into `bash --rcfile <TMPDIR>/.../rc`, and bash
    # given a missing rcfile does not fail, it just opens an interactive shell - so replaying it
    # "works" and leaves the pane in a stray bash.
    | (any(.[1:][]; . as $arg | any($dirs[]; . as $dir | $arg | startswith($dir + "/")))) as $ephemeral_arg
    | ($interactive or $ephemeral_arg or (($excluded | index($name)) != null)) | not;
'

truthy() { case "$1" in true | 1 | yes | on) return 0 ;; *) return 1 ;; esac }

notify() {
    truthy "$(config_value notify true)" || return 0
    "$herdr" notification show "$1" --body "$2" >/dev/null 2>&1 || true
}

# Claude panes. herdr can resume an agent conversation itself, but only once the agent has told it
# the session id, and for Claude that report comes from a Claude Code hook
# (~/.claude/hooks/herdr-agent-state.sh) that needs python3 and exits silently without it. Where
# there is no python3 herdr never learns the id and resumes nothing.
#
# Claude Code keeps its own record of every running process, <config>/sessions/<pid>.json, with the
# session id in it - so the id can be read here without any hook. The conversation is replayed as
# `claude --resume <id>`, not `claude --continue`: --continue opens the newest conversation of the
# directory, so two Claude panes in the same repository would both come back as the same one.
#
# The file is Claude Code internals, not an interface, so every step here fails closed: a missing
# file, an unexpected shape or a pid that has been reused leaves the pane out, as before this existed.
claude_dir=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
claude_resume=$(config_value claude true)

# claude_session_of <pid>: the session id of the live Claude process <pid>, or nothing.
claude_session_of() {
    local pid=$1 file stat started recorded id
    file="$claude_dir/sessions/$pid.json"
    [ -r "$file" ] || return 1
    stat=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
    # Fields after the command name, which may itself contain spaces or parentheses. The kernel's
    # start time (field 22) is the 20th of them; Claude records the same value as procStart, so a
    # file left behind by an earlier process that had this pid does not match.
    # shellcheck disable=SC2086  # split into fields on purpose
    set -- ${stat##*") "}
    started=${20:-}
    recorded=$(jq -r '.procStart // empty' "$file" 2>/dev/null)
    [ -n "$started" ] && [ "$started" = "$recorded" ] || return 1
    id=$(jq -r '.sessionId // empty' "$file" 2>/dev/null)
    case "$id" in
        ????????-????-????-????-????????????) printf '%s\n' "$id" ;;
        *) return 1 ;;
    esac
}

# claude_session_live <id>: whether some running Claude process, in any pane or none, already has
# this conversation open. Restore checks this rather than comparing argv, which would miss the same
# conversation opened as `claude -r <id>` or from the picker.
claude_session_live() {
    local file
    for file in "$claude_dir"/sessions/*.json; do
        [ -e "$file" ] || continue
        [ "$(claude_session_of "$(basename "$file" .json)")" = "$1" ] && return 0
    done
    return 1
}

# A workspace keeps its id across a restart (session.json stores it as "id": "w3"), and so does a
# tab's number (public_tab_numbers). Pane ids do not — they are handed out afresh — which is why a
# record is keyed by workspace id + tab number + the pane's position inside that tab.
#
# Everything a save needs comes from three list calls plus one process-info per pane. Other agent
# panes are left out entirely: herdr resumes those itself ([session] resume_agents_on_restore), so
# replaying them would start a second copy of the same agent.
collect() {
    local panes tabs workspaces procs pane_id agent info leader session
    panes=$("$herdr" pane list 2>/dev/null) || return 1
    tabs=$("$herdr" tab list 2>/dev/null) || return 1
    workspaces=$("$herdr" workspace list 2>/dev/null) || return 1
    [ -n "$panes" ] && [ -n "$tabs" ] && [ -n "$workspaces" ] || return 1

    procs=$(
        while IFS=$'\t' read -r pane_id agent; do
            [ -n "$pane_id" ] || continue
            info=$("$herdr" pane process-info --pane "$pane_id" 2>/dev/null) || continue
            if [ "$agent" = claude ]; then
                truthy "$claude_resume" || continue
                leader=$(jq -r '.result.process_info.foreground_process_group_id // empty' <<<"$info")
                session=$(claude_session_of "$leader") || continue
                jq -c --arg session "$session" '.result.process_info + {claude_session: $session}' \
                    <<<"$info" 2>/dev/null
            else
                jq -c '.result.process_info' <<<"$info" 2>/dev/null
            fi
        done < <(jq -r '.result.panes[] | select((has("agent") | not) or .agent == "claude")
                    | "\(.pane_id)\t\(.agent // "")"' <<<"$panes") | jq -s -c .
    )
    [ -n "$procs" ] || return 1

    jq -n -c \
        --argjson panes "$(jq -c '.result.panes' <<<"$panes")" \
        --argjson tabs "$(jq -c '.result.tabs' <<<"$tabs")" \
        --argjson workspaces "$(jq -c '.result.workspaces' <<<"$workspaces")" \
        --argjson procs "$procs" \
        --arg exclude "$exclude_names" \
        --arg ephemeral "$ephemeral_dirs" \
        --arg root "$plugin_root" "$replayable_jq"'
        ($panes | map({key: .pane_id, value: .}) | from_entries) as $pane_by_id
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
            | select($leader.argv | replayable)
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
                # A Claude pane is recorded by its conversation, whatever it was started with
                # (`claude -r` with the picker leaves no id in the argv).
                argv: (if $p.claude_session then ["claude", "--resume", $p.claude_session]
                       else $leader.argv end),
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
