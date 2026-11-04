# rex-res

Bring back the programs that were running in your Rex panes after Rex restarts.

Rex already saves sessions, tabs, splits, floating panes, labels, and working
directories, and restores them when its server starts. It brings each terminal
back as a plain shell. rex-res remembers what ran in each pane and types it
back into the same pane.

## Setup

Load it from `~/.config/rex/init.lua` and run `rex config reload`:

```lua
dofile(os.getenv("HOME") .. "/repos/projects/rex-res/lua/plugin.lua").setup({
  prefix = false,
})
```

Options:

- `programs`: executable names to save. Defaults to `pi nvim opencode htop btop`.
- `prefix`: a key that, followed by Ctrl+S or Ctrl+R, saves or restores. Defaults to `ctrl+b`; `false` turns it off.
- `state_dir`: where the snapshot goes. Defaults to `$REX_RES_STATE` or `~/.local/state/rex-res`.

## Use

From the command palette:

- **rex-res: Save running programs** before you quit, update, or restart Rex.
- **rex-res: Restore running programs** after Rex comes back.
- **rex-res: Show saved programs** shows what's saved and whether it's waiting to restore.

Save records, for every terminal running a listed program, its block ID,
working directory, and command line. Restore finds each saved block. If that
pane is sitting at a shell prompt, it types the command, after a `cd` when the
shell is in another directory. It leaves busy panes alone and skips panes that
no longer exist, so running it twice is harmless.

After a restart, Save refuses to overwrite a snapshot that hasn't been restored,
so an early save can't wipe out the commands you meant to bring back. Run
`rex do res_save force=true` to replace it anyway.

## Limits

- Rex must restore the sessions itself. Panes are matched by block ID, so a
  server started with `--restore=false` gets nothing back.
- Rex never reports a program's arguments, so rex-res reads them from `ps`.
  Quoting is lost, and a program that rewrites its process title, like `pi`,
  saves only its name. `pi` starts a new conversation.
- Snapshots can hold secrets passed as arguments. The directory is mode 0700.
- Nothing saves or restores automatically. Rex doesn't send events to
  `init.lua`, so that would need a separate long-running `rex do` script.

## Development

Run `python3 tests/integration.py` with Rex installed. It starts isolated
servers, restarts one to check the real restore path, and removes its files.
