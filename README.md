# rex-res

Save and restore a Rex workspace, modeled on tmux-resurrect
One Lua plugin, no helper or background service

## Setup

Clone this repo, then load it from `~/.config/rex/init.lua`:

```lua
dofile(os.getenv("HOME") .. "/repos/projects/rex-res/lua/plugin.lua").setup({
  prefix = false,
})
```

Adjust the path to your clone and run `rex config reload`
Requires Rex on macOS, `ps`, `lsof`, and `/bin/sh`

## Use

Run **Save Rex Workspace** before quitting or updating Rex
Run **Restore Rex Workspace** afterward, from the command palette
**Saved Rex Workspace Status** shows the last save
Nothing saves, restores, or restarts automatically

The plugin saves layouts, directories, labels, focus, zoom, and command lines
Restore creates missing sessions, tabs, and panes, leaving existing programs alone
Sessions match by unique label; tabs, layers, and panes match by position
Save again after reordering your layout

Snapshots go to `~/.local/state/rex-res/workspace.json`, mode 0600
Saves replace the file atomically; failed saves keep the previous snapshot
Set `state_dir` or `REX_RES_STATE` to use another directory, one per Rex server

Only approved programs run in new panes; other panes open plain shells
Defaults: `vi vim nvim emacs man less more tail top htop irssi weechat mutt opencode`
Set `programs = { "nvim", "opencode" }` to replace that list; `{}` disables replay
Set `prefix = "ctrl+b"` for prefix + Ctrl+S/Ctrl+R shortcuts

`ps` loses argument quoting and shell context, so command replay is best-effort
OpenCode reopens a conversation only when its saved command names that session
Memory, scrollback, and conversation switches inside OpenCode are not saved
Snapshots may contain secrets in arguments; restore only trusted files
The approved list is not a sandbox: the shell interprets the full command

## Development

Run `python3 tests/integration.py` with Rex installed
Tests use isolated servers and remove their temporary files on exit
