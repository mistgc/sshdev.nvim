# sshdev.nvim

Edit remote projects with **your local Neovim config**, through SSH, with a
persistent remote server and session restore.

```
local UI / --remote-ui client  ⇄  ssh -N -L  ⇄  remote nvim --headless --listen
```

## Terminology

- **workspace** — the remote **project directory** the server runs in
  (e.g. `~/src/app`).
- **profile** — the remote state directory for one (client machine,
  workspace) pair:

  ```
  <remote_root>/--<local-hostname>--<workspace-path>--/
  ```

  The key uses the **local** hostname, so several laptops sharing one
  remote account never overwrite each other's config, plugins, data or
  session.

## What it does

1. **Uploads your `stdpath("config")`** to `<profile>/nvim-config/` with
   `scp` (respects an `excludes` glob list; skipped when the local config
   fingerprint matches the remote `.synced` marker).
2. **Installs a Neovim release matching your local version** under
   `~/.sshdev.nvim/_bin/<version>-<asset>/`
   (Linux x86_64/aarch64, macOS arm64/x86_64; downloads via an optional
   **proxy** or mirror).
3. **Installs your plugins** by running the remote nvim headless once
   (your plugin manager's bootstrap does the cloning).
4. **Starts a detached remote server** in the workspace, forwards it with
   `ssh -N -L`, and **attaches** a UI.
5. **Saves and restores the Neovim session**: the server writes
   `<profile>/session.vim` when it exits, so the next connection brings
   back the same buffers, windows and layout. `:q` behaves normally —
   there is no quit hijacking.

MIT licensed.

## Requirements

- **Local**: Neovim ≥ **0.12** (`:connect` was added in 0.12 — 0.11 only has
  `:detach`), `ssh` and `scp` (OpenSSH ≥ 7.6).
- **Remote** (Linux/macOS): `sh`, `tar`, `curl`, `sshd` allowing TCP
  forwarding.
- Key-based authentication is strongly recommended.

## Install

With `lazy.nvim`:

```lua
{
  'you/sshdev.nvim',
  cmd = { 'SSHdevConnect', 'SSHdevAttach', 'SSHdevInstall', 'SSHdevSync',
          'SSHdevStop', 'SSHdevStatus', 'SSHdevHistory', 'SSHdevLog' },
  config = function()
    require('sshdev').setup({
      host = 'me@myhost',              -- default destination
      remotes = { work = 'me@work.example.com:2222' },
      workspace = '~/src/app',         -- default remote project dir
      proxy = 'http://127.0.0.1:7890', -- used ON THE REMOTE for downloads
    })
  end,
}
```

With telescope (optional — enables the fuzzy connection picker):

```lua
{ 'nvim-telescope/telescope.nvim', dependencies = { 'you/sshdev.nvim' } }
-- setup() loads the extension automatically when telescope is present
```

## Usage

```
:SSHdevConnect                    " picker: remembered connections (+ new)
:SSHdevConnect me@myhost          " any [user@]host[:port]
:SSHdevConnect me@myhost:2222 ~/src/app
:SSHdevConnect work               " a destination named in setup({ remotes = ... })
:SSHdevConnect!                   " resync config + plugins, restart server
:SSHdevAttach                     " attach to a RUNNING server, no bootstrap
:SSHdevInstall                    " bootstrap only, no server / no attach
:SSHdevSync                       " re-upload config + helper only
:SSHdevStop                       " stop the server (saves session) + tunnel
:SSHdevStatus                     " session / tunnel / server / history report
:SSHdevHistory                    " remembered-connection picker
:SSHdevLog                        " open the log
:checkhealth sshdev               " verify local + remote environment
```

On the remote session `:q` behaves normally: the server quits and saves
`session.vim`. Reconnect with `:SSHdevConnect` and the session is restored.

### Telescope

```vim
:Telescope sshdev connections
```

or `:lua require('telescope').extensions.sshdev.connections()`. `<C-d>` in
the picker forgets an entry.

## How it works

```
~/.sshdev.nvim/
├── _bin/                                  nvim releases, shared by profiles
│   └── <version>-<asset>/
└── --<local-hostname>--<workspace-path>--/     one profile per client + workspace
    ├── nvim-config/                       uploaded config (NVIM_APPNAME)
    ├── data/                              XDG_DATA_HOME (plugins, shada)
    ├── state/  cache/                     XDG state/cache
    ├── session.lua                        server-side session helper
    ├── session.vim                        saved Neovim session
    ├── .synced                            fingerprint of the synced config
    ├── server.pid  server.addr
    └── server.log
```

- Each profile has its own XDG dirs, so plugin installs and state stay
  isolated between workspaces and between client machines.
- The server listens on `127.0.0.1:<port>` (reachable only through the
  tunnel). The local port is deterministic per (destination, profile).
- The config upload and plugin install are **skipped** when the local config
  fingerprint matches the remote `.synced` marker, so reconnecting after a
  quit is fast.
- Server liveness is found through `server.pid`, with a fallback to
  matching the unique `<profile>/session.lua` command line — a lost pid
  file never starts a second server on the same port.

### Session persistence (no quit hijacking)

| event | what happens |
| --- | --- |
| `:q`, `:wq`, `:qa`, `SIGTERM` (`:SSHdevStop`) | server exits → `session.vim` written (VimLeavePre) |
| `FocusLost` / `VimSuspend` | best-effort snapshot |
| next `:SSHdevConnect` | server restarts and `session.vim` is restored (VimEnter) |

Disable with `session = false`; start clean while still saving with
`restore_session = false`.

### Attaching: the local UI `:connect`s to the remote server

Since Nvim 0.12, `nvim` starts a builtin **UI client** process plus an
embedded server, and that UI client implements the `"connect"` UI event — so
`:connect` re-attaches the terminal UI **in place**, exactly as intended:

```vim
:connect 127.0.0.1:<port>     " bare host:port -- no scheme!
```

Address format matters: nvim parses a bare `host:port` (or the `ssh://…`
built-in remote-ssh form). A `tcp://host:port` URI is **not** valid — the UI
detaches first, then fails to attach, and the process ends, which looks like
":connect is unsupported".

`attach = 'auto'` picks a strategy:

| UI | strategy | what happens |
| --- | --- | --- |
| builtin TUI / external GUI | `connect` | UI re-attaches in place with `:connect host:port` |
| headless | `command` | just prints the command to run |

`attach = 'terminal'` is still available as an explicit alternative: it opens
a terminal tab with a separate UI client

```sh
nvim --server 127.0.0.1:<port> --remote-ui
```

which keeps your local nvim alive (useful when you want the local session
back after quitting the remote one).

Note: `:connect` was added in **Nvim 0.12**; 0.11 only has `:detach`.

## Configuration

All options (see `:h sshdev-setup`):

```lua
require('sshdev').setup({
  host = 'me@myhost',
  remotes = { work = 'me@work.example.com:2222' },

  workspace = '~/src/app',   -- default remote project directory
  profile = nil,             -- force the profile dir name

  session = true,            -- save <profile>/session.vim on exit
  restore_session = true,    -- restore it when the server starts

  ssh_bin = 'ssh', scp_bin = 'scp',
  ssh_args = { '-i', '~/.ssh/id_ed25519' },
  remote_root = '~/.sshdev.nvim',

  nvim_version = 'auto',     -- "auto" | "v0.12.6" | "nightly" | "stable"
  proxy = 'socks5://127.0.0.1:1080',   -- used on the remote host
  download_mirror = 'https://github.com/neovim/neovim/releases/download',
  install_commands = { 'Lazy! restore' },
  excludes = { '.git', '.github' },

  attach = 'auto',           -- "auto" | "terminal" | "connect" | "command"
  history = true,            -- remember connections for the picker
  history_limit = 50,

  timeouts = { ssh = 60, download = 600, install = 900, attach = 30 },
})
```

Notes:

- `nvim_version = 'auto'` installs the release matching your local nvim
  (`v0.12.6` etc.; dev builds fall back to `nightly` with a warning).
- `proxy` applies to the **remote** nvim download — the common case for
  GitHub-restricted networks. Set `download_mirror` for a mirror.
- `install_commands` run after your uploaded `init` is sourced during the
  headless install run.
- History entries keep the **full destination including the ssh port**, so
  picking one reconnects to the right port.

## FAQ

**Where did the `:q` hijacking go?**
It was replaced by session persistence: `:q` quits normally, and the server
writes `session.vim` on the way out; reconnecting restores it.

**Does `:connect` work in the builtin TUI?**
Yes — since Nvim 0.12 the builtin UI is a UI client process and implements the
`connect` UI event, so `:connect host:port` re-attaches the terminal UI in
place. (It only looks broken if you pass a scheme like `tcp://host:port`:
that is not a valid nvim server address and leaves the UI detached.)

**When would I use `attach = 'terminal'`?**
When you want to keep your local nvim alive while working remotely: it opens a
separate `nvim --server … --remote-ui` client in a terminal tab, so quitting
the remote session returns you to the local one.

**Why upload the whole config instead of plugin specs?**
You want the remote session to behave exactly like home. The upload skips
`excludes` entries and is skipped entirely when the fingerprint is
unchanged.

## License

MIT — see [LICENSE](LICENSE).
