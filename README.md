# sshdev.nvim

Edit remote files with **your local Neovim config**, through SSH, with a persistent remote server.

```
local nvim UI  ⇄  ssh -N -L (port forward)  ⇄  remote nvim --headless --listen
```

The local UI attaches to the remote server with the built-in `:connect`
command (Neovim ≥ 0.11), so all editing happens **on the remote host** —
LSP, treesitter parsers, formatters, scripts all run remotely — while the
interface, keymaps and plugins come from your uploaded config.

`sshdev.nvim` takes care of everything around it:

1. **Uploads your `stdpath("config")`** to `~/.sshdev.nvim/<workspace>/nvim-config/`
   with `scp` (respects an `excludes` glob list).
2. **Installs a Neovim release matching your local version** on the remote
   (Linux x86_64/aarch64, macOS arm64/x86_64; downloads via an optional
   **proxy** or mirror).
3. **Installs your plugins** by running the remote nvim headless once so
   your plugin manager's bootstrap (`lazy.nvim`, `packer`, `mini.deps`, …)
   can clone/sync what your config declares.
4. **Starts a detached remote server** in the remote folder you designate
   as the workspace, and **forwards it through an SSH tunnel**.
5. **Hijacks `:q` into `:detach`** on the remote server, so quitting your
   local nvim (or dropping the SSH connection) never kills the remote
   server — `:SSHdevConnect` re-attaches to it.

MIT licensed.

## Requirements

- **Local**: Neovim ≥ 0.11 (`:connect` / `:detach`), `ssh` and `scp`
  (OpenSSH ≥ 7.6 for `StrictHostKeyChecking=accept-new`).
- **Remote** (Linux/macOS): `sh`, `tar`, `curl` (for the nvim download),
  `sshd` allowing TCP forwarding.
- Key-based authentication is strongly recommended (the flows run many
  `ssh` invocations).

## Install

With `lazy.nvim`:

```lua
{
  'you/sshdev.nvim',
  cmd = { 'SSHdevConnect', 'SSHdevAttach', 'SSHdevInstall', 'SSHdevSync', 'SSHdevStop', 'SSHdevStatus', 'SSHdevLog' },
  config = function()
    require('sshdev').setup({
      host = 'me@myhost',              -- default destination
      remotes = { work = 'me@work.example.com' },
      proxy = 'http://127.0.0.1:7890', -- used ON THE REMOTE for nvim downloads
    })
  end,
}
```

With `vim.pack` (Neovim ≥ 0.12):

```lua
vim.pack.add({ 'https://github.com/you/sshdev.nvim' })
require('sshdev').setup({ host = 'me@myhost' })
```

## Usage

```
:SSHdevConnect                    " bootstrap + attach to setup({ host = ... })
:SSHdevConnect me@myhost          " any [user@]host[:port]
:SSHdevConnect me@myhost:2222
:SSHdevConnect work               " a destination named in setup({ remotes = ... })
:SSHdevConnect work ~/projects/x  " designate the remote workspace folder
:SSHdevConnect!                   " resync config + plugins, restart server
:SSHdevAttach                     " attach to a RUNNING server, no bootstrap
:SSHdevInstall                    " bootstrap only, no server / no attach
:SSHdevSync                       " re-upload config + shim only
:SSHdevStop                       " stop the remote server + local tunnel
:SSHdevStatus                     " session / tunnel / server report
:SSHdevLog                        " open the log (run log, ssh stderr, ...)
:checkhealth sshdev               " verify local + remote environment
```

Inside an attached session, on the remote:

- `:q`, `:wq`, `:qa` … are hijacked into `:detach` — the remote server
  keeps running.
- `:SSHdevQuit` / `:SSHdevStop` (or `:cq`) really quit the remote server.
- If the SSH connection drops, the server survives (UIs are marked
  detachable with `:detach!`) — re-run `:SSHdevConnect` to re-attach and
  find everything as you left it.

## How it works

```
~/.sshdev.nvim/                     remote sshdev root (remote_root)
└── <workspace>/
    ├── nvim-config/                your uploaded config (appname "nvim-config")
    ├── xdg/{share,state,cache}/    remote data/state/cache, isolated per workspace
    ├── shim.lua                    the server-side helper (quit hijack, ...)
    ├── server.pid, server.addr     detached server bookkeeping
    └── server.log                  remote nvim output
```

- Each workspace gets its own remote `XDG` dirs, so plugin installs and
  state stay isolated between projects.
- The remote server listens on `127.0.0.1:<port>` (only reachable through
  the tunnel). The local port is deterministic per (destination, workspace).
- The tunnel job is detached from nvim and runs with `ControlMaster=no`, so
  it survives the local server stopping and cannot be torn down by
  short-lived multiplexed ssh masters.

### Attaching: `--remote-ui`, not just `:connect`

`:connect` only re-attaches when the current **UI** implements the
`"connect"` UI event. The builtin TUI does **not** — per `:help :connect`,
"if the current UI hasn't implemented the connect UI event, this command is
equivalent to :detach". On a terminal, `:connect` therefore drops you back
to the shell instead of attaching.

So sshdev.nvim attaches with the documented TUI mechanism, a separate UI
client process over the tunnel:

```sh
nvim --server 127.0.0.1:<port> --remote-ui
```

`attach = 'auto'` picks the strategy per UI:

| UI | strategy | what happens |
| --- | --- | --- |
| builtin TUI | `terminal` | opens a terminal tab running `nvim --server ... --remote-ui`, so the remote UI owns that tab; detaching closes the tab |
| external GUI (nvim-qt, Neovide, …) | `connect` | uses `:connect tcp://…` (these UIs implement the connect event) |
| headless | `command` | just prints the command to run |

Override with `attach = 'terminal' | 'connect' | 'command'`. The remote
server is the same in all cases, and `:q` on it is still hijacked into
`:detach`.

## Configuration

All options (see `:h sshdev-setup` for the full reference):

```lua
require('sshdev').setup({
  host = 'me@myhost',        -- default destination "[user@]host[:port]"
  remotes = { work = 'me@work.example.com:2222' },
  remote_dir = '~/work',     -- default remote workspace folder
  workspace = 'myws',        -- force the workspace name (default: dir basename)

  ssh_bin = 'ssh', scp_bin = 'scp',
  ssh_args = { '-i', '~/.ssh/id_ed25519' },

  remote_root = '~/.sshdev.nvim',
  nvim_version = 'auto',     -- "auto" | "v0.11.3" | "nightly" | "stable"
  proxy = 'socks5://127.0.0.1:1080', -- used on the remote for downloads
  download_mirror = 'https://github.com/neovim/neovim/releases/download',
  install_commands = { 'Lazy! restore' }, -- extra headless ex-commands
  excludes = { '.git', '.github', 'lazy-lock.lua' },
  hijack_quit = true,        -- :q -> :detach on the remote (the default)
  attach = 'auto',           -- "auto" | "terminal" | "connect" | "command"

  timeouts = { ssh = 60, download = 600, install = 900, attach = 30 },
})
```

Notes:

- `nvim_version = 'auto'` installs the release matching your local nvim
  (`v0.11.3` etc.; dev builds fall back to `nightly` with a warning).
- `proxy` applies to the **remote** nvim download — the common case for
  GitHub-restricted networks. Set `download_mirror` if you prefer a mirror.
- `install_commands` run after your uploaded `init` is sourced during the
  headless install run. Add your plugin manager's sync/restore command
  here if its bootstrap alone doesn't install declared plugins.

## FAQ

**Why is the whole config uploaded, not just plugin specs?**
You want the remote session to behave exactly like home: keymaps,
filetypes, LSP settings. The upload skips `excludes` entries (`.git/` by
default, plus whatever you add).

**Why does my local nvim "exit" when connecting?**
`:connect` detaches the UI from the local server and attaches it to the
remote one (upstream `:connect` semantics). Your local nvim process stops
when it has no other UIs; the remote server — and the detached tunnel —
live on. Re-attach any time with `:SSHdevConnect`.

**How do I really quit the remote server?**
`:SSHdevQuit` (or `:cq`) on the remote, or `:SSHdevStop` from a local
session.

## License

MIT — see [LICENSE](LICENSE).
