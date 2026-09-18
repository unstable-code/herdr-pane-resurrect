# herdr-pane-resurrect

**English** | [한국어](README.ko.md)

A [herdr](https://herdr.dev) plugin that brings back the programs that were running in your panes,
the way [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) does for tmux.

## Why

herdr already restores a session: the layout, each pane's directory, and — with
`[session] resume_agents_on_restore` — the agent conversations. What it does not restore is whatever
was *running* inside those panes. They come back as empty shells.

| After a restart | |
|---|---|
| Layout: splits, ratios, tabs, names, focus | restored by herdr |
| Each pane's directory | restored by herdr |
| Agent conversations | restored by herdr |
| **The command running in a pane** | **gone — this plugin** |
| Scrollback | gone |

This is the tmux-resurrect half that herdr is missing; nothing here duplicates what herdr already
does well.

## How it works

- **save** records the command running in each pane — the process group leader, so a pipeline is
  recorded as the one command that was typed rather than as its parts. Two kinds of pane are left
  out on purpose: panes sitting at a prompt (there is nothing to bring back) and agent panes (herdr
  resumes those itself, and replaying them would start a second copy of the agent).
  There is no list of programs to configure the way `@resurrect-processes` has to be: whatever was
  actually running is what gets written.
- **restore** replays each record into the pane it belongs to. It only ever writes into a pane that
  is sitting at a prompt, and it skips a record whose command is already running, so restoring twice
  starts nothing the second time.
- A record is keyed by **workspace id + tab number + the pane's position in that tab**. Workspace ids
  and tab numbers survive a restart (herdr keeps them in `session.json`); pane ids do not — they are
  handed out afresh. Matching on the tab's *name* alone would not work either: an unnamed tab's label
  is just its number, so every unnamed tab in a session looks alike.
- When the restored pane is not in the directory the command was started from, the plugin prepends a
  `cd` so the command runs where it used to.
- A small daemon (`bin/autosave`) keeps the snapshot current. Saving at shutdown instead would be the
  obvious design and it cannot work: logging out of a graphical session terminates the whole process
  tree at once, so there is no moment left in which a hook could run. On a timer, the worst case is
  losing the commands started since the last tick. It runs once (`flock`), starts from the
  `[[startup]]` hook and from any action, and stops when the herdr server does.
- The daemon never clears the snapshot; only a save you ask for does. Shutdown is otherwise a race it
  cannot win — the panes' processes and the daemon are killed together, and a tick landing in between
  would see an empty session and overwrite the snapshot meant to survive it.

## Requirements

- herdr ≥ 0.9.0 (Linux / macOS)
- `bash`, `jq`, `flock` (util-linux) on the herdr server's `PATH`

## Installation

```sh
herdr plugin install unstable-code/herdr-pane-resurrect
```

For development, link a local clone instead; the working tree is used directly, so `git pull` is the
update:

```sh
git clone https://github.com/unstable-code/herdr-pane-resurrect.git
herdr plugin link ./herdr-pane-resurrect
```

Then bind the two actions in `~/.config/herdr/config.toml`. `prefix+ctrl+s` and `prefix+ctrl+r` are
where tmux-resurrect puts them, and herdr leaves both free:

```toml
[[keys.command]]
key = "prefix+ctrl+s"
type = "plugin_action"
command = "unstable-code.herdr-pane-resurrect.save"
description = "save pane commands"

[[keys.command]]
key = "prefix+ctrl+r"
type = "plugin_action"
command = "unstable-code.herdr-pane-resurrect.restore"
description = "restore pane commands"
```

Apply with `herdr server reload-config` (or your reload key).

Each action reports a summary as a herdr notification; the per-pane detail goes to
`herdr plugin log`.

## Configuration

Optional, in `config.toml` inside this plugin's config directory
(`herdr plugin config-dir unstable-code.herdr-pane-resurrect`):

```toml
autosave = true   # run the background save daemon
interval = 60     # seconds between automatic saves
notify   = true   # show a notification when an action finishes
exclude  = ""     # command names never saved, space separated: "cargo make"
```

`exclude` matches the program's base name. Panes sitting at a prompt are already skipped, so this is
for programs that should not come back — something long and expensive, or something that prompts on
start.

## Verification

Checked on an isolated herdr 0.9.0 server with three workspaces: `alpha` (a named tab holding two
panes) plus `beta` and `gamma`, whose tabs are both unnamed and therefore both labelled `1`.

| Case | Result |
|---|---|
| `sleep 500`, `bash -c 'sleep 400 \| cat'`, `sleep 300` in `/tmp` | saved with the exact argv of each process group leader; the pipeline recorded as the single command that was typed |
| Server stopped and started again, all panes idle | all three restored byte-identically, the `/tmp` one back in `/tmp` |
| Two tabs both labelled `1`, in different workspaces | each command restored into its own workspace |
| Restore run a second time | `restored 0, already running 3, skipped 0` — nothing started twice |
| Saved workspace closed before restore | reported as skipped, nothing started elsewhere |
| Five concurrent `bin/autosave --spawn` | exactly one daemon |
| A command ended in a pane | snapshot updated within one interval |
| Server stopped | daemon exited on its own and removed its pid file |

## Limitations

- It restores *programs*, not their state: `nvim file` reopens the file, it does not bring back an
  unsaved buffer, and a build starts from the beginning. Scrollback is not restored either.
- Commands started since the last automatic save are not in the snapshot; the `save` action is there
  for when that matters.
- A command typed into a shell running inside another shell is recorded as that inner shell's
  command, which is what was actually running.
- Agent panes are never recorded, so herdr's own agent resume is the only thing that brings them back.

## License

[MIT](LICENSE)
