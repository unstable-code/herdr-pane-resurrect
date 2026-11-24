#!/usr/bin/env bash
# Shared helpers for bin/save, bin/restore, bin/autosave and bin/agent-order.

herdr=${HERDR_BIN_PATH:-herdr}
plugin_root=${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
state_dir=${HERDR_PLUGIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr-pane-resurrect}

herdr_config=${XDG_CONFIG_HOME:-$HOME/.config}/herdr
# Without a socket there is no server to ask; herdr's default path is the fallback.
socket=${HERDR_SOCKET_PATH:-$herdr_config/herdr.sock}

# One state directory per herdr session (#4): herdr keys a plugin's state by plugin id alone, so every
# session would share it. A named session's socket is <config>/sessions/<name>/herdr.sock (herdr 0.9.5
# session.rs data_dir_for) and its state goes to sessions/<name>/; any other socket, a relocated
# HERDR_SOCKET_PATH included, is the default session and keeps the directory it always had.
[[ $socket =~ ^"$herdr_config"/sessions/([^/]+)/herdr\.sock$ ]] && state_dir+="/sessions/${BASH_REMATCH[1]}"
# The one place the directory is made, for every script that sources this.
[ -d "$state_dir" ] || mkdir -p "$state_dir" 2>/dev/null

config_dir=${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-pane-resurrect}
state_file="$state_dir/panes.json"
# Present while a freshly started server waits for its restore; bin/autosave explains why.
# shellcheck disable=SC2034  # used by the scripts that source this file
hold_file="$state_dir/hold"

# config.toml is read with sed rather than a TOML parser: this plugin is a few shell scripts with a
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

# A pane's position in its tab, the third part of every key this plugin saves (see collect). Pane ids
# are handed out afresh on restart; workspace ids and tab numbers are not.
# shellcheck disable=SC2016  # jq variables
position_jq='
def position($panes): . as $p | [$panes[] | select(.tab_id == $p.tab_id) | .pane_id] | index($p.pane_id) // 0;
'

truthy() { case "$1" in true | 1 | yes | on) return 0 ;; *) return 1 ;; esac }

# herdr_request <json>: one raw socket API request, for the methods the CLI has no command for
# (agent.view.*). The server answers with one line and closes the connection.
herdr_request() {
    if command -v socat >/dev/null 2>&1; then
        printf '%s\n' "$1" | timeout 5 socat - "UNIX-CONNECT:$socket"
    else
        printf '%s\n' "$1" | timeout 5 nc -U "$socket"
    fi
}

now_ms() {
    local t=${EPOCHREALTIME/[.,]/}
    if [ -n "$t" ]; then printf '%s\n' "${t:0:${#t}-3}"; else date +%s%3N; fi
}

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

# typed_argv <pid> <shell pid>: the command as it was typed, when <pid> was started through a nix
# wrapper — as a JSON array — or nothing, when it was not or the wrapper cannot be read (#5). Save
# records this, and restore compares running commands against it.
#
# A wrapper adds its own flags and execs the real program in the same pid, so the argv herdr reports
# carries flags nobody typed, or (for a shell wrapper without `exec -a`) the unwrapped program's store
# path as argv[0]. Replayed, the first went through the wrapper again and gained a copy per restore.
#
# The wrapper is the file the typed name resolves to on PATH, when that file is not the running
# program itself. The program's own PATH comes first — it is the shell's PATH as it was when the
# command ran, rc-file additions included — and the shell's environ second, for a wrapper that put a
# directory holding the program itself in front. Read as nixpkgs generates them:
#   makeWrapper / wrapProgram (shell)   the last line, exec [-a "$0"] "<program>" <flags> "$@" <flags>
#   makeBinaryWrapper (C binary)        the makeCWrapper command it embeds: --add-flag(s), --append-flag(s)
# The wrapper's flags come off only where they match exactly: at the front as often as they repeat (a
# snapshot replayed before this fix holds several copies), and once at the end. Anything else — a
# flag that differs, one with a shell expansion in it, a wrapper of another shape — leaves the argv as
# it was: a command recorded with too much is better than one cut wrongly.
#
# Store hashes are left out of every comparison here (store_bare, and bare in jq): a package rebuilt
# at the same version moves to a new hash. A program still running from before a switch is the old
# build while PATH already leads to the new wrapper, and the copies an older wrapper left in a
# snapshot differ from today's flags only there. A changed name, version or path still has to match.
typed_argv() {
    local pid=$1 shell=$2 exe name entry from wrapper="" found magic line target kind many text i
    local args=() pre=() post=() words=() lines=()
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || return 1
    mapfile -d '' -t args <"/proc/$pid/cmdline" 2>/dev/null
    [ ${#args[@]} -gt 0 ] || return 1
    name=${args[0]##*/}
    for from in "$pid" "$shell"; do
        while IFS= read -r -d '' entry; do
            [[ $entry == PATH=* ]] || continue
            found=$(PATH=${entry#PATH=} type -P -- "$name") && found=$(readlink -f "$found") &&
                [ "$(store_bare "$found")" != "$(store_bare "$exe")" ] && wrapper=$found
            break
        done 2>/dev/null <"/proc/$from/environ"
        [ -n "$wrapper" ] && break
    done
    [ -n "$wrapper" ] || return 1

    IFS= read -rn2 magic <"$wrapper"
    if [ "$magic" = '#!' ]; then
        mapfile -t lines <"$wrapper"
        for ((i = ${#lines[@]} - 1; i >= 0; i--)); do
            [[ ${lines[i]} == exec\ * ]] && line=${lines[i]} && break
        done
        [[ ${line:-} =~ ^exec\ (-a\ \"\$0\"\ )?\"([^\"]+)\"(.*)\ \"\$@\"(.*)$ ]] || return 1
        target=${BASH_REMATCH[2]}
        mapfile -d '' -t pre < <(wrapper_words "${BASH_REMATCH[3]}")
        mapfile -d '' -t post < <(wrapper_words "${BASH_REMATCH[4]}")
    else
        local doc
        doc=$(tr -c '[:print:]\n' '\n' <"$wrapper" | sed -n "/^makeCWrapper '/,/^\$/p")
        [[ $doc =~ ^makeCWrapper\ \'([^\']+)\' ]] || return 1
        target=${BASH_REMATCH[1]}
        while IFS= read -r line; do
            [[ ${line%\\} =~ --(add|append)-flag(s?)\ (.*)$ ]] || continue
            kind=${BASH_REMATCH[1]} many=${BASH_REMATCH[2]} text=${BASH_REMATCH[3]}
            mapfile -d '' -t words < <(wrapper_words "$text")
            # makeCWrapper splits --*-flags on whitespace; --*-flag is one argument.
            [ -n "$many" ] && read -ra words <<<"${words[*]}"
            if [ "$kind" = add ]; then pre+=("${words[@]}"); else post+=("${words[@]}"); fi
        done <<<"$doc"
    fi
    [ "$(store_bare "$(readlink -f "$target")")" = "$(store_bare "$exe")" ] || return 1

    # Words go to jq NUL-separated on stdin: an argument such as --script=... would be taken for one
    # of jq's own options on its command line. The three parts are copied out ([...[]]) rather than
    # sliced: jq 1.8.2 compares two slices of one array wrongly (["y","z"] == ["a","b"] is true when
    # both are slices of ["a","b","x","y","z"]), which here took every argument off.
    printf '%s\0' "${pre[@]}" "${post[@]}" "${args[@]}" |
        jq -c -Rs --arg name "$name" --argjson np ${#pre[@]} --argjson nq ${#post[@]} '
            def bare: map(gsub("/nix/store/[0-9a-z]{32}-"; "/nix/store/"));
            split("\u0000")[:-1] as $a | ([$a[:$np][]] | bare) as $pre
            | ([$a[$np:$np + $nq][]] | bare) as $post
            | [$a[$np + $nq + 1:][]]
            | until($np == 0 or (.[:$np] | bare) != $pre; .[$np:])
            | if $nq > 0 and (.[-$nq:] | bare) == $post then .[:-$nq] else . end
            | [$name] + .'
}

# store_bare <path>: <path> with its /nix/store hash taken out, for comparing two builds of one
# package (see typed_argv).
store_bare() { [[ $1 =~ ^(.*/nix/store/)[0-9a-z]{32}-(.*)$ ]] && printf '%s' "${BASH_REMATCH[1]}${BASH_REMATCH[2]}" || printf '%s' "$1"; }

# wrapper_words <text>: <text> split like a command line — quotes removed, nothing expanded — as
# NUL-terminated words. xargs does exactly that, and runs nothing it reads.
wrapper_words() { printf '%s' "$1" | xargs -r printf '%s\0' 2>/dev/null; }

# A workspace keeps its id across a restart (session.json stores it as "id": "w3"), and so does a
# tab's number (public_tab_numbers). Pane ids do not — they are handed out afresh — which is why a
# record is keyed by workspace id + tab number + the pane's position inside that tab.
#
# Everything a save needs comes from three list calls plus one process-info per pane. Other agent
# panes are left out entirely: herdr resumes those itself ([session] resume_agents_on_restore), so
# replaying them would start a second copy of the same agent.
collect() {
    local panes tabs workspaces procs pane_id agent info leader shell session typed extra
    panes=$("$herdr" pane list 2>/dev/null) || return 1
    tabs=$("$herdr" tab list 2>/dev/null) || return 1
    workspaces=$("$herdr" workspace list 2>/dev/null) || return 1
    [ -n "$panes" ] && [ -n "$tabs" ] && [ -n "$workspaces" ] || return 1

    procs=$(
        while IFS=$'\t' read -r pane_id agent; do
            [ -n "$pane_id" ] || continue
            info=$("$herdr" pane process-info --pane "$pane_id" 2>/dev/null) || continue
            IFS=$'\t' read -r leader shell < <(jq -r '.result.process_info
                | "\(.foreground_process_group_id // "")\t\(.shell_pid // "")"' <<<"$info" 2>/dev/null)
            extra='{}'
            if [ "$agent" = claude ]; then
                truthy "$claude_resume" || continue
                session=$(claude_session_of "$leader") || continue
                extra="{\"claude_session\":\"$session\"}"  # a UUID, checked by claude_session_of
            elif [ "$leader" != "$shell" ] && typed=$(typed_argv "$leader" "$shell"); then
                # A pane at a prompt is dropped below anyway; only a running command is looked at.
                extra="{\"typed_argv\":$typed}"
            fi
            jq -c --argjson extra "$extra" '.result.process_info + $extra' <<<"$info" 2>/dev/null
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
        --arg root "$plugin_root" "$replayable_jq$position_jq"'
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
                idx: ($pane | position($panes)),
                cwd: ($leader.cwd // $pane.foreground_cwd // $pane.cwd // ""),
                # A Claude pane is recorded by its conversation, whatever it was started with
                # (`claude -r` with the picker leaves no id in the argv).
                # A command started through a nix wrapper is recorded as typed (see typed_argv).
                argv: (if $p.claude_session then ["claude", "--resume", $p.claude_session]
                       elif $p.typed_argv and $leader.pid == $p.foreground_process_group_id then $p.typed_argv
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

# store <records> [file]: write the snapshot (or another state file) only when it differs, so an
# autosave tick that finds nothing new does not rewrite the file every interval.
store() {
    local records=$1 file=${2:-$state_file} previous
    previous=$(cat "$file" 2>/dev/null)
    [ "$records" = "$previous" ] && return 2
    printf '%s\n' "$records" >"$file.tmp" && mv "$file.tmp" "$file"
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
