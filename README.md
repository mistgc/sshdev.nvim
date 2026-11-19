# sshdev.nvim

Edit remote projects with **your local Neovim config**, through SSH, with a
persistent remote server and session restore.

```
local UI / --remote-ui client  ⇄  ssh -N -L  ⇄  remote nvim --headless --listen
```

The state on the remote host is split into two independent levels:

- a **nvim profile** — *your config + the plugin instances* (plus a link to one
  nvim release). It is reusable: every workspace with the same config content
  and nvim version shares it, so plugins are installed **once**, not once per
  workspace.
- a **workspace profile** — the per-`(client machine, project dir)` session and
  server state. It links to a nvim profile.

## Terminology

- **workspace** — the remote **project directory** the server runs in
  (e.g. `~/src/app`).
- **nvim profile** — an immutable, reusable bundle of the uploaded config and
  the plugin data, keyed by

  ```
  <remote_root>/nvim-profiles/--<local-hostname>-<nvim-version>-<hash8-config-content>--/
  ```

  The key contains the local hostname (isolation between laptops sharing one
  remote account), the nvim version and the first 8 hex characters of the
  **content hash** of the uploaded config. Two workspaces using the same config
  therefore share one installed profile.
- **workspace profile** — the session/server state for one
  (client machine, workspace) pair:

  ```
  <remote_root>/workspace-profiles/--<local-hostname>--<workspace-path>--/
  ```

  It holds `session.vim`, the server pid/address/log and a relative symlink to
  the nvim profile (`nvim-profile -> ../../nvim-profiles/<nvim-profile-key>`).

## What it does

1. **Installs a Neovim release matching your local version** under
   `<remote_root>/nvim-bins/<nvim-version>/` (Linux x86_64/aarch64, macOS
   arm64/x86_64; downloads via an optional **proxy** or mirror). The profile
   links to it with `nvim-bin -> ../../nvim-bins/<nvim-version>`.
2. **Uploads your `stdpath("config")`** into the nvim profile and runs a
   headless install **once per config content hash**, so your plugin manager
   clones the plugins once.
3. **Reuses that nvim profile for any other workspace** — the second, third, …
   workspace with the same config skips both the upload and the plugin install
   and starts in seconds.
4. **Starts a detached remote server** in the workspace (session saved per
   workspace), forwards it with `ssh -N -L`, and **attaches** a UI.
5. **Saves and restores the Neovim session**: the server writes
   `<workspace-profile>/session.vim` when it exits, so the next connection
   brings back the same buffers, windows and layout. `:q` behaves normally —
   there is no quit hijacking.

MIT licensed.

## Requirements

- **Local**: Neovim ≥ **0.12** (`:connect` was added in 0.12 — 0.11 only has
  `:detach`), `ssh` and `scp` (OpenSSH ≥ 7.6).
- **Remote** (Linux/macOS): `sh`, `tar`, `curl`, `sshd` allowing TCP
  forwarding.
- Key-based authentication is recommended. Hosts that only accept
  passwords are handled automatically (key first, password fallback —
  needs an OpenSSH client ≥ 8.4, see
  [Password authentication](#password-authentication)).

## Installing

With `lazy.nvim`:

```lua
{
  'mistgc/sshdev.nvim',
  cmd = { 'SSHdevConnect', 'SSHdevAttach', 'SSHdevInstall', 'SSHdevSync',
          'SSHdevStop', 'SSHdevStatus', 'SSHdevHistory', 'SSHdevProfiles',
          'SSHdevLog' },
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

With telescope (optional — enables the fuzzy pickers):

```lua
{ 'mistgc/sshdev.nvim', dependencies = { 'nvim-telescope/telescope.nvim' } }
-- setup() loads the extension automatically when telescope is present
```

## Usage

```
:SSHdevConnect                       " picker: remembered connections (+ new)
:SSHdevConnect me@myhost             " any [user@]host[:port]
:SSHdevConnect me@myhost:2222 ~/src/app
:SSHdevConnect work                  " a destination named in setup({ remotes = ... })
:SSHdevConnect me@myhost:2222 ~/src/app --auth=password
                                     " force password mode for this connection
:SSHdevConnect me@myhost ~/src/app --nvim-profile=--laptop-v0.12.6-1a2b3c4d--
                                     " new workspace reusing an existing nvim profile
:SSHdevConnect!                      " restart server, re-sync into the profile
:SSHdevAttach                        " attach to a RUNNING server, no bootstrap
:SSHdevInstall                       " bootstrap the nvim profile only, no server
:SSHdevSync                          " re-upload config + reinstall plugins
:SSHdevStop                          " stop the server (saves session) + tunnel
:SSHdevStatus                        " session / profiles / tunnel / server report
:SSHdevHistory [dest]                " remote workspace picker (client-host scoped)
:SSHdevProfiles [dest]               " list reusable nvim profiles on the remote
:SSHdevLog                           " open the log
:checkhealth sshdev                  " verify local + remote environment
```

On the remote session `:q` behaves normally: the server quits and saves
`session.vim`. Reconnect with `:SSHdevConnect` and the session is restored.

### Reusing an nvim profile

The default `nvim_profile = 'auto'` derives the key from
`(local hostname, nvim version, config content hash)`. Because the key *is* the
config identity:

- editing your config produces a new key and a fresh one-time install;
- **`touch`ing files does not** (the hash is content-based);
- connecting a **new workspace** with an unchanged config reuses the existing
  profile — no scp, no plugin install.

To reuse a profile that was installed from a different config state (for
example "pin this project to the plugins it was set up with"), pass the key
explicitly:

```vim
" discover the keys available for this client host
:SSHdevProfiles me@myhost

" create a new workspace that reuses an existing profile
:SSHdevConnect me@myhost ~/src/second --nvim-profile=--laptop-v0.12.6-1a2b3c4d--
```

```lua
require('sshdev').connect({
  dest = 'me@myhost',
  workspace = '~/src/second',
  nvim_profile = '--laptop-v0.12.6-1a2b3c4d--',
})
```

An explicitly reused profile is used **as-is**: its config and plugins are
never overwritten (that would break the "key = content hash" invariant). If the
requested key does not exist or never finished installing, sshdev falls back to
the auto profile with a warning.

`:SSHdevConnect` with no arguments offers the same choice interactively: pick
"new connection", type `dest` and `workspace`, then choose `auto` or one of the
existing nvim profiles.

### Workspace history (`:SSHdevHistory`)

The history picker asks the remote host for **all workspace profiles whose
`client-host` equals this machine's local hostname**, merges them with the
local connection history (recency/counts) and lets you reconnect. Because the
remote scan is host-filtered, several laptops sharing one remote account never
see or adopt each other's workspaces/session state. `<C-d>` forgets a local
entry.

### Telescope

```vim
:Telescope sshdev connections
```

or `:lua require('telescope').extensions.sshdev.connections()`.

## How it works

```
~/.sshdev.nvim/
├── nvim-bins/
│   └── <nvim-version>/                          nvim releases (shared)
│       ├── bin/nvim
│       └── .platform                            OS/arch marker
├── nvim-profiles/
│   └── --<local-hostname>-<nvim-version>-<hash8-config-content>--/
│       ├── nvim-bin -> ../../nvim-bins/<nvim-version>/   (relative symlink)
│       ├── nvim-config/                        uploaded config (NVIM_APPNAME)
│       ├── xdg/share/                          XDG_DATA_HOME (plugins)
│       ├── xdg/state/  xdg/cache/              XDG state/cache
│       ├── nvim-version  config-hash  client-host
│       └── .ready                              bootstrap-complete marker
└── workspace-profiles/
    └── --<local-hostname>--<workspace-path>--/
        ├── nvim-profile -> ../../nvim-profiles/<nvim-profile-key>/
        ├── nvim-profile.txt  workspace.txt  client-host
        ├── session.lua                         server-side session helper
        ├── session.vim  last_used
        └── server.pid  server.addr  server.log
```

- The server runs with `XDG_CONFIG_HOME=<nvim-profile>`,
  `XDG_DATA_HOME=<nvim-profile>/xdg/share`,
  `XDG_STATE_HOME=<nvim-profile>/xdg/state`,
  `XDG_CACHE_HOME=<nvim-profile>/xdg/cache` and
  `NVIM_APPNAME=nvim-config`, so the config is exactly
  `<nvim-profile>/nvim-config` and the plugins land in
  `<nvim-profile>/xdg/share/nvim-config/`.
- **Reuse rule**: a config upload + headless plugin install runs only when
  `<nvim-profile>/.ready` does not equal the local config content hash (or
  `:SSHdevConnect!`/`:SSHdevSync` forces it). A second workspace with the same
  config skips the expensive path entirely.
- **Atomic bootstrap**: the config is scp'd into
  `<nvim-profile>/.staging-<token>/nvim-config`, then a single remote script
  takes a `mkdir` lock, swaps it into place, runs the headless install and
  writes `.ready` last. Concurrent connects to two new workspaces serialize on
  that lock (waiting up to `timeouts.lock`), so plugins are never installed
  twice in parallel.
- Each **workspace profile** has its own session and server runtime files; the
  nvim profile has its own plugin/state dirs. State never collides with the
  remote user's own nvim.
- The server listens on `127.0.0.1:<port>` (reachable only through the
  tunnel). The local port is deterministic per (destination, workspace
  profile).
- Server liveness is found through `server.pid`, with a fallback to matching
  the unique `<workspace-profile>/session.lua` command line — a lost pid file
  never starts a second server on the same port.

### Session persistence (no quit hijacking)

| event | what happens |
| --- | --- |
| `:q`, `:wq`, `:qa`, `SIGTERM` (`:SSHdevStop`) | server exits → `session.vim` written (VimLeavePre) |
| `FocusLost` / `VimSuspend` | best-effort snapshot |
| next `:SSHdevConnect` | server restarts and `session.vim` is restored (VimEnter) |

Restored buffers get their `FileType` re-established explicitly: session
sourcing loads their content with the read events suppressed, which would
otherwise leave them without filetype detection — no syntax highlighting,
no LSP, no treesitter. The re-fire happens right after the restore and
again when the first UI attaches (lazy-loaded plugins register their
handlers only then).

Sessions live in the workspace profile: two workspaces can share one nvim
profile (config + plugins) while keeping independent buffers/layouts.

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

## Password authentication

The default `auth = 'auto'` tries key/ssh-agent first, fully
non-interactive. When the server rejects that (`Permission denied
(publickey,…)`), sshdev asks for the password once (`inputsecret()`,
masked), retries and keeps it **only in memory** for the rest of the nvim
session — never on disk, in history or in the log. From then on every
ssh/scp/tunnel call of the session authenticates through `SSH_ASKPASS`.
A working key keeps working: ssh tries keys first, the askpass helper is
only consulted when a password is actually needed.

Explicit modes, when you want to skip the failed non-interactive round
trip (known password-only host) or forbid prompts entirely:

```lua
require('sshdev').setup({
  host = 'me@myhost',
  auth = 'password',  -- ask BEFORE the first ssh call
  -- auth = 'key',    -- strictly non-interactive: never prompt
})
```

or per invocation (`auto` / `password` / `key`; also works for
`:SSHdevAttach`, `:SSHdevInstall`, `:SSHdevSync` and the pickers):

```vim
:SSHdevConnect me@myhost:2222 ~/src/app --auth=password
```

How the password travels:

- the first attempt of the auto mode (and every `key`-mode call) runs
  with `BatchMode=yes` — strictly key/agent — so a password-needing host
  fails **fast** with a `Permission denied` signature (without askpass or
  a console, ssh would otherwise hang on the prompt until the timeout);
- once a password is in play, every ssh/scp/tunnel call receives
  `SSH_ASKPASS` — a tiny helper script under `stdpath('cache')/sshdev/`
  that prints `$SSHDEV_PASS` — plus `SSH_ASKPASS_REQUIRE=force`, so
  OpenSSH authenticates without a terminal. The helper itself contains
  **no secret**. Verified against Windows OpenSSH 9.5, including
  detached `ssh -N -L` tunnel processes;
- a rejected password (`Permission denied (publickey,password)`) is
  detected and the cached entry dropped, so the next `:SSHdevConnect`
  asks again.

Requirements & caveats:

- the password fallback needs an OpenSSH **≥ 8.4** client
  (`SSH_ASKPASS_REQUIRE`; the Windows inbox client has it since 8.6 — 9.5
  verified). `:checkhealth sshdev` reports the capability and the helper
  status.
- a headless nvim cannot ask for a password: the connection fails with
  the original ssh error plus a note (run from a TUI/GUI, or use key
  auth).
- the password is visible in the environment of the spawned ssh/scp
  children (including a tunnel kept alive after nvim exits) — the
  accepted trade-off of this mode.
- single-factor passwords only: 2FA / keyboard-interactive prompts cannot
  be answered (use key auth for those).
- on Windows, a `!` in the password cannot be passed (cmd delayed
  expansion); sshdev warns when it sees one.

## Upgrading from the old single-profile layout

Before this refactor every `(client, workspace)` had one directory containing
config, plugins, session and server files. The new layout reuses
`<remote_root>/_bin/<version>-<asset>/` by moving it to
`<remote_root>/nvim-bins/<version>/` when the asset matches (no re-download),
and copies an old `session.vim` into the new workspace profile on the first
connect. Old plugin trees are not migrated: the first connect installs the
nvim profile once.

Stop old servers before upgrading (`:SSHdevStop`, or `kill` the remote nvim);
they are not adopted by the new layout. Old profile directories can be removed
with `rm -rf <remote_root>/--*` once you no longer need them.

## Configuration

All options (see `:h sshdev-setup`):

```lua
require('sshdev').setup({
  host = 'me@myhost',
  remotes = { work = 'me@work.example.com:2222' },

  workspace = '~/src/app',   -- default remote project directory
  workspace_profile = nil,   -- force the workspace profile dir name
  nvim_profile = 'auto',     -- 'auto' | '--<host>-<version>-<hash8>--' (reuse)

  session = true,            -- save <workspace-profile>/session.vim on exit
  restore_session = true,    -- restore it when the server starts

  ssh_bin = 'ssh', scp_bin = 'scp',
  ssh_args = { '-i', '~/.ssh/id_ed25519' },
  auth = 'auto',             -- "auto" (key first, password fallback) | "password" | "key"

  remote_root = '~/.sshdev.nvim',

  nvim_version = 'auto',     -- "auto" | "v0.12.6" | "nightly" | "stable"
  proxy = 'socks5://127.0.0.1:1080',   -- used on the remote host
  download_mirror = 'https://github.com/neovim/neovim/releases/download',
  install_commands = { 'Lazy! restore' },
  excludes = { '.git', '.github' },

  attach = 'auto',           -- "auto" | "terminal" | "connect" | "command"
  history = true,            -- remember connections for the picker
  history_limit = 50,

  timeouts = { ssh = 60, download = 600, install = 900, attach = 30, lock = 120 },
})
```

Notes:

- `nvim_version = 'auto'` installs the release matching your local nvim
  (`v0.12.6` etc.; dev builds fall back to `nightly` with a warning).
- `proxy` applies to the **remote** nvim download — the common case for
  GitHub-restricted networks. Set `download_mirror` for a mirror.
- `install_commands` run after your uploaded `init` is sourced during the
  headless install run.
- `excludes` are globbed against config-relative paths and are part of the
  content hash: changing them creates a new nvim profile (a one-time install).
- `nvim_profile` is normally `'auto'`; pin a key to reuse a specific existing
  profile for a new workspace.
- History entries keep the **full destination including the ssh port**, so
  picking one reconnects to the right port.

## FAQ

**Why did my second workspace connect so fast?**
Because the nvim profile key is the config content hash: the profile from the
first workspace is reused, so there is no scp and no plugin install. Check
`:SSHdevLog` — the install phase only appears when the config (or nvim version)
changed.

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

**Why is the whole config uploaded instead of plugin specs?**
You want the remote session to behave exactly like home. The upload skips
`excludes` entries, lands in a content-addressed profile and is reused by every
workspace with the same config.

**How do I connect to a host that only accepts passwords?**
Nothing to configure: the default `auth = 'auto'` detects the rejected
non-interactive attempt, asks for the password once and retries. Set
`auth = 'password'` to skip the failed round trip, or `--auth=password`
for one connection. `:checkhealth sshdev` verifies your client supports
the fallback.

**How do I get rid of old nvim profiles?**
Each config edit creates a new `nvim-profiles/--…--` directory (the old one is
kept for reuse/pinning). `:SSHdevProfiles` lists them; delete unused ones with
`rm -rf <remote_root>/nvim-profiles/<key>` when no workspace links to them.

## License

MIT — see [LICENSE](LICENSE).
