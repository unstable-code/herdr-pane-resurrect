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
| Agent conversations | restored by herdr — once the agent has reported its session id; Claude panes by this plugin, which does not need that report (see below) |
| **The command running in a pane** | **gone — this plugin** |
| Scrollback | gone |

This is the tmux-resurrect half that herdr is missing; nothing here duplicates what herdr already
does well.

## How it works

- **save** records the command running in each pane — the process group leader, so a pipeline is
  recorded as the one command that was typed rather than as its parts. Some panes are left out on
  purpose:
  - panes sitting at a prompt — there is nothing to bring back;
  - agent panes other than Claude — herdr resumes those itself, and replaying them would start a
    second copy;
  - **interactive shells started inside a pane** (`nix-shell`, `sudo -i`, a nested `bash`) — a prompt
    too, just a nested one, and what made the shell is not in its argv. A shell given something to
    run (`bash -c …`, `bash ./deploy.sh`) is a real command and is kept;
  - **commands whose arguments point into `$XDG_RUNTIME_DIR` or `$TMPDIR`** — a restart empties
    those. This is exactly the shape `nix-shell` leaves behind: it execs into
    `bash --rcfile $TMPDIR/nix-shell-…/rc`, and bash given a missing rcfile does not fail, it just
    opens a stray interactive shell.

  There is no list of programs to configure the way `@resurrect-processes` has to be: whatever was
  actually running is what gets written.
- **restore** replays each record into the pane it belongs to. It only ever writes into a pane that
  is sitting at a prompt, and it skips a record whose command is already running, so restoring twice
  starts nothing the second time. It applies the save rules above once more to what it reads, so a
  snapshot written by an older version cannot replay something the current one refuses to record.
- `herdr pane run` succeeding only means the command was *typed*. restore therefore looks at every
  pane again a moment later and counts only what is still running; a command that failed at once
  (its script gone, say) is reported as *exited right away* rather than as restored.
- **Claude panes come back as their own conversation.** herdr can resume agents itself, but only
  after the agent has reported its session id, and Claude's report comes from a Claude Code hook
  that needs `python3` and quietly does nothing without it — so on such a machine herdr resumes no
  Claude pane at all. Claude Code also keeps a record of every running process in
  `~/.claude/sessions/<pid>.json` (or under `$CLAUDE_CONFIG_DIR`), session id included; save reads
  it and records the pane as `claude --resume <id>`, whatever the pane was started with (`claude -r`
  from the picker leaves no id behind).
  - `--resume <id>`, not `--continue`: `--continue` opens the newest conversation of the directory,
    so two Claude panes in one repository would both come back as the same conversation.
  - That file is Claude Code internals, not an interface. Every step fails closed: no file, an
    unexpected shape, or a file left by an earlier process that had the same pid (its `procStart`
    must equal the kernel's start time for the pid) leaves the pane out, as before.
  - restore skips a conversation that is already open anywhere — resumed by hand, from the picker,
    or by herdr's own resume on a machine where that works — judged by session id, not by argv.
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
- **After the server starts, the daemon writes nothing until the snapshot has been used.** A freshly
  started server is exactly the session the snapshot is meant to repair — herdr has brought the layout
  back as empty shells — so its first tick would record that and replace the commands still waiting
  to be restored. It did, once: after a compositor crash, the snapshot of three `ssh` sessions was
  overwritten with a single stray `bash` before restore was ever pressed. The `[[startup]]` hook now
  puts the snapshot on hold; running **restore**, or a **save** you ask for (the way to say "I will
  not restore that one"), lifts it.

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
verify_delay = 1.5  # seconds restore waits before checking that each command is still running
claude   = true   # record Claude panes by their conversation (see How it works)
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
| Restore run a second time | `command(s): 0 restored, 3 already running` — nothing started twice |
| Saved workspace closed before restore | reported as skipped, nothing started elsewhere |
| Five concurrent `bin/autosave --spawn` | exactly one daemon |
| A command ended in a pane | snapshot updated within one interval |
| Server stopped | daemon exited on its own and removed its pid file |
| Server killed hard with its panes, then started again (plugin linked, `[[startup]]` hook live) | snapshot put on hold; a new command in a pane left it untouched across three ticks |
| restore while on hold | hold lifted, autosave tracked the session again on its next tick |
| save by hand while on hold | hold lifted |
| A real `nix-shell -p hello` in a pane (leader `bash --rcfile $TMPDIR/nix-shell-…/rc`) | not saved; `bash -c 'sleep 600 \| cat'` next to it still saved |
| A snapshot from an older version holding that nix-shell record | skipped as *not replayable*, not typed into the pane |
| `bash /nonexistent/deploy.sh` in the snapshot | typed, failed at once, reported as *exited right away* — `command(s): 1 restored, 0 already running, 1 skipped, 1 failed` |
| Two Claude panes in the same directory (a stand-in that registers `sessions/<pid>.json` the way Claude Code does) | saved as `claude --resume aaaaaaaa-…` and `claude --resume bbbbbbbb-…` |
| Hard restart, then restore | each pane got its own conversation back (p1 → `aaaaaaaa-…`, p2 → `bbbbbbbb-…`); the dead processes' session files were not taken for live ones |
| restore again | `agent(s): 0 restored, 2 already running`, judged by session id |
| Against the live Claude Code 2.1.278 files | all eight open conversations resolved to their session ids; a wrong `procStart`, a dead pid and a malformed id were all refused |

## Limitations

- It restores *programs*, not their state: `nvim file` reopens the file, it does not bring back an
  unsaved buffer, and a build starts from the beginning. Scrollback is not restored either.
- Commands started since the last automatic save are not in the snapshot; the `save` action is there
  for when that matters.
- A command typed into a shell running inside another shell is recorded as that inner shell's
  command, which is what was actually running.
- Agent panes other than Claude are never recorded, so herdr's own agent resume is the only thing
  that brings them back.
- The Claude support reads a file Claude Code does not document. If a Claude Code update changes it,
  Claude panes are quietly left out again — nothing is replayed wrongly, but nothing is replayed.

## License

[MIT](LICENSE)
