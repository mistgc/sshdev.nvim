# sshdev.nvim

Edit remote projects with **your local Neovim config**, through SSH, with a
persistent remote server and session restore.

![How sshdev.nvim works](assets/how-it-works.svg)

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
  <remote_root>/nvim-profiles/--<local-hostname>--<nvim-version>--<hash8-config-content>--/
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

  It holds `session.vim`, the optional workspace files `forward.txt` and
  `env.txt`, the server pid/address/log and a relative symlink to the nvim
  profile (`nvim-profile -> ../../nvim-profiles/<nvim-profile-key>`).

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
6. **Forwards workspace services** (`:SshDevForward`) and **injects workspace
   environment variables** (`:SshDevEnv`): both files live in the remote
   workspace profile, are edited locally, and are re-applied on reconnect.

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
  cmd = { 'SshDevConnect', 'SshDevAttach', 'SshDevInstall', 'SshDevSync',
          'SshDevStop', 'SshDevStatus', 'SshDevForward', 'SshDevEnv',
          'SshDevHistory', 'SshDevProfiles', 'SshDevLog' },
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
:SshDevConnect                       " picker: remembered connections (+ new)
:SshDevConnect me@myhost             " any [user@]host[:port]
:SshDevConnect me@myhost:2222 ~/src/app
:SshDevConnect work                  " a destination named in setup({ remotes = ... })
:SshDevConnect me@myhost:2222 ~/src/app --auth=password
                                     " force password mode for this connection
:SshDevConnect me@myhost ~/src/app --nvim-profile=--laptop--v0.12.6--1a2b3c4d--
                                     " new workspace reusing an existing nvim profile
:SshDevConnect!                      " restart server, re-sync into the profile
:SshDevAttach                        " attach to a RUNNING server, no bootstrap
:SshDevInstall                       " bootstrap the nvim profile only, no server
:SshDevSync                          " re-upload config + reinstall plugins
:SshDevStop                          " stop the server (saves session) + tunnel
:SshDevStatus                        " session / profiles / tunnel / server report
:SshDevForward [dest] [workspace]    " edit port forwards (save = apply)
:SshDevEnv [dest] [workspace]        " edit env variables (save = apply)
:SshDevHistory [dest]                " remote workspace picker (client-host scoped)
:SshDevProfiles [dest]               " list reusable nvim profiles on the remote
:SshDevLog                           " open the log
:checkhealth sshdev                  " verify local + remote environment
```

On the remote session `:q` behaves normally: the server quits and saves
`session.vim`. Reconnect with `:SshDevConnect` and the session is restored.

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
:SshDevProfiles me@myhost

" create a new workspace that reuses an existing profile
:SshDevConnect me@myhost ~/src/second --nvim-profile=--laptop--v0.12.6--1a2b3c4d--
```

```lua
require('sshdev').connect({
  dest = 'me@myhost',
  workspace = '~/src/second',
  nvim_profile = '--laptop--v0.12.6--1a2b3c4d--',
})
```

An explicitly reused profile is used **as-is**: its config and plugins are
never overwritten (that would break the "key = content hash" invariant). If the
requested key does not exist or never finished installing, sshdev falls back to
the auto profile with a warning.

`:SshDevConnect` with no arguments offers the same choice interactively: pick
"new connection", type `dest` and `workspace`, then choose `auto` or one of the
existing nvim profiles.

### Workspace history (`:SshDevHistory`)

The history picker asks the remote host for **all workspace profiles whose
`client-host` equals this machine's local hostname**, merges them with the
local connection history (recency/counts) and lets you reconnect. Because the
remote scan is host-filtered, several laptops sharing one remote account never
see or adopt each other's workspaces/session state. `<C-d>` forgets a local
entry.

### Port forwards (`:SshDevForward`)

A workspace can declare extra SSH forwards so that services reachable only
from the **server** appear on your **local** `127.0.0.1`. The declaration is
a per-workspace file in the remote workspace profile —
`<workspace-profile>/forward.txt` — and is edited through a local mirror:

```vim
:SshDevForward                       " active session's workspace (fastest, no probe)
:SshDevForward me@myhost             " that destination; workspace from setup()
:SshDevForward me@myhost ~/src/app   " fully explicit, no active session needed
```

```lua
require('sshdev').forward({ dest = 'me@myhost', workspace = '~/src/app' })
```

`[dest]` and `[workspace]` resolve like the connect commands, including named
`remotes` entries. Without an active session, the missing pieces come from
`setup({ host = ..., workspace = ... })` or from the arguments;
`--auth=password` is accepted, and `--nvim-profile` is accepted but irrelevant
(forward.txt belongs to the workspace profile, not the nvim profile). If the
file does not exist yet, an all-commented template is created — uncomment the
lines you need and save the buffer:

```text
# one forward per line: <local-port> = <remote-host>:<remote-port>
# (127.0.0.1 means the server's own loopback; other hosts are resolved there)
3080 = 127.0.0.1:3080
8080 = 127.0.0.1:8080
5432 = db.internal:5432
```

Inline `#` comments after a forward are **not** supported — put comments on
their own line.

- The **local port** is bound on this machine's `127.0.0.1` (loopback only,
  never exposed to the network).
- The **target** is resolved on the server: `127.0.0.1:3080` means the
  server's own loopback, and `db.internal:5432` is reached from the server's
  network — the right way to bring remote-only internal services to your desk.
- `#` lines and blank lines are ignored; whitespace and CRLF files are
  tolerated; an **empty file stops all forwards**.
- IPv6 target literals are not supported (the same limitation as
  destinations).
- A single invalid line is reported with its line number and applies
  **nothing**: malformed lines, ports outside 1–65535 and duplicate local
  ports are rejected.

Saving (`:w`) runs the apply as one unit:

1. parse the buffer (on errors nothing is uploaded and nothing changes);
2. upload it to `<workspace-profile>/forward.txt` (the source of truth);
3. check the local ports and kill the previous forward tunnel;
4. start **one** detached `ssh -N` carrying a `-L` per line, with
   `ExitOnForwardFailure=yes`;
5. wait until the tunnel verifiably accepts connections. If ssh dies (a busy
   port, a reserved port, rejected auth), the **previous forward set is
   restored** and ssh's own stderr is reported.

Ports are checked before the old tunnel is killed, so an obvious conflict
leaves the old forwards running; a bind failure that only surfaces while ssh
starts is rolled back to the previous set. Either way there is no
half-applied state — all forwards live in one `ssh -N` process. Example: a
dev server listening on the remote `127.0.0.1:3000`:

```text
3000 = 127.0.0.1:3000
```

Save, then open `http://127.0.0.1:3000` locally. `:SshDevStatus` reports the
current set, e.g.
`forwards: up (3080 -> 127.0.0.1:3080, 5432 -> db.internal:5432)`.

The forward tunnel is stopped by `:SshDevStop` and when the local nvim exits
— except when the UI attached via `:connect` (the local nvim server stops as
the UI attaches, and the detached tunnel must survive). With
`forward_on_connect = true` (default) every `:SshDevConnect` / `:SshDevAttach`
re-reads forward.txt and re-applies the forwards automatically; when every
port is already listening, the set is assumed to be leftovers from the
previous session and kept (force a clean re-apply with `:SshDevForward` +
`:w`). The forwards are ordinary client-side ssh processes, independent of
the nvim server, so the file can also be reopened and re-applied while the
remote server is not running (pass `[dest] [workspace]` when no session is
active).

**Inside the attached session** (`:SshDevConnect` with the default
`attach = "auto"`) the same command just works: the typed command runs in the
remote nvim, where `:SshDevForward` opens the very same forward.txt (it lives
on the server) and each save is pushed over an RPC control channel to the
client, which applies it and reports the outcome back into the attached UI.
If that channel is unavailable, the fallback is: `:detach` (the server keeps
running), run `:SshDevForward` + `:w` in a new local nvim, then
`:SshDevAttach`.

Common failures:

| Symptom | Meaning / fix |
| --- | --- |
| `cannot forward: local port(s) … already in use` | a foreign process holds the port (often an ssh left by a crash); the old forwards keep running. Find it with `ss -ltn` / `netstat -an`, then save again |
| `the forward tunnel … died (exit N): …` | authoritative ssh error (unbindable port, rejected auth). A rejected password already dropped the cache; the next connect asks again |
| `the forwards … did not answer within 30s` | very slow link: the tunnel is not dead; check `:SshDevStatus` |
| `5432 = db.internal:5432` does not connect | the target is resolved **on the server** — verify it there with `nc -vz db.internal 5432`; check the local listener on port 5432 |
| forwards did not come back after reconnecting | `forward_on_connect = false`, or every port was already listening (kept as leftovers); force a save |

Full implementation notes: [docs/port-forwarding.md](docs/port-forwarding.md).

### Environment variables (`:SshDevEnv`)

A workspace can declare environment variables in
`<workspace-profile>/env.txt`, next to forward.txt. `:SshDevEnv` opens a local
mirror of that file:

```vim
:SshDevEnv                           " active session's workspace (fastest, no probe)
:SshDevEnv me@myhost                 " that destination; workspace from setup()
:SshDevEnv me@myhost ~/src/app       " fully explicit, no active session needed
```

```lua
require('sshdev').env({ dest = 'me@myhost', workspace = '~/src/app' })
```

`[dest]` / `[workspace]` follow the same rules as `:SshDevForward` (named
`remotes` entries work; `--auth=password` is accepted; `--nvim-profile` is
irrelevant). A new workspace gets an all-commented template. One variable per
line:

```text
# one variable per line: KEY=VALUE (values are used verbatim)
NODE_ENV=development
DATABASE_URL=postgres://127.0.0.1:5432/app
PATH=/opt/tools/bin:/usr/bin:/bin
```

Format rules:

- `KEY` must match `[A-Za-z_][A-Za-z0-9_]*`.
- A value is **everything after the first `=`**, used verbatim: spaces, `#`,
  `=` and quotes are kept, `$VAR` is **not** expanded and quotes are **not**
  stripped. A value may be empty.
- `#` lines and blank lines are ignored; CRLF line endings and a UTF-8 BOM are
  tolerated.
- One invalid line reports its line number and applies **nothing** (the
  remote file and the running environment stay unchanged). Values are never
  echoed in error messages — a malformed line may be a mistyped secret.
- Duplicate keys are rejected, and so are the keys sshdev needs itself:
  `SSHDEV_*`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`,
  `XDG_CACHE_HOME`, `NVIM_APPNAME`, `SSH_ASKPASS`, `SSH_ASKPASS_REQUIRE` and
  `HOME`.

Saving applies the variables everywhere sshdev can reach:

- **future ssh/scp scripts** for this workspace export them at the top of the
  remote script (so the nvim download, plugin install and server start all
  see them);
- a **server started later** inherits them **before** your config loads, so
  config-time `vim.env` reads work on the next `:SshDevConnect`;
- a **running server** receives them through the RPC control channel:
  `vim.env` is updated, so LSPs, `:terminal` and `jobstart` children started
  from now on inherit them. Already-running LSPs need a restart; values read
  during nvim startup need a server restart (`:SshDevConnect!`).

Without a running server (or when no control channel is available), the file
is only persisted; the next `:SshDevConnect` starts the server with it. With
`env_on_connect = true` (default) every `:SshDevConnect` / `:SshDevAttach`
re-reads env.txt and injects it; lines removed from the file unset the
variable at runtime (a server started by an older sshdev has no key manifest
for that — restart it with `:SshDevConnect!`). `env_on_connect = false` limits
injection to explicit saves in the current nvim session.

Example: point a remote process at a service forwarded by
`:SshDevForward`:

```text
DATABASE_URL=postgres://127.0.0.1:5432/app
```

Save, then restart the LSP (or `:SshDevConnect!` for config-time reads) and
processes started from the remote session see the variable. `:SshDevStatus`
shows `env: N variable(s) injected (<dest>)`.

**Inside the attached session**, `:SshDevEnv` opens the very same file on the
server; a save applies it there immediately and pushes the update back to the
client through the control channel (refreshing the local mirror and the
active map). If the channel is gone, the server-side save still applies; the
client catches up on the next connect.

The file may hold secrets: the local mirror and the remote copy are written
with mode **0600** (the remote copy is explicitly re-`chmod`ed after every
upload), the buffer uses no swap/undo file, and values are never logged. The
values do appear in the environment of the local ssh/scp children sshdev
spawns for this workspace (a documented trade-off); the remote commands
receive them through the exported script prefix.

Troubleshooting:

| Symptom | Meaning / fix |
| --- | --- |
| a new variable is not visible in a running LSP | the LSP was started with the old environment; restart the LSP client |
| a removed variable is still set | the server predates the key manifest; restart with `:SshDevConnect!` |
| nothing was applied after a save | the notification lists the invalid lines; fix them and `:w` again |
| `HOME` / `XDG_*_HOME` / `SSHDEV_*` rejected | reserved: they would break the transport or the profile isolation |
| the variable exists in the remote shell but not in `vim.env` | the command ran before the runtime push; reconnect or restart the server |

Full implementation notes: [docs/environment.md](docs/environment.md).

### Remote tool PATH (cargo, pipx, nvim-treesitter)

`ssh` runs sshdev's scripts (and therefore the remote nvim server) in a
**non-interactive, non-login** shell, which does not read `~/.bashrc` /
`~/.profile`. Tools installed into a per-user directory are then invisible to
the remote session even when your interactive shell finds them. The classic
symptom is nvim-treesitter failing to build a parser right after
`cargo install tree-sitter-cli` succeeded:

```text
[nvim-treesitter/install/toml] error: Error during "tree-sitter build":
vim/_core/system:324: ENOENT: no such file or directory (cmd): 'tree-sitter'
```

sshdev therefore prepends the usual per-user tool directories to the PATH of
the remote server and of every remote script it runs (nvim download, headless
plugin install, `:terminal`, LSPs, jobs):

```lua
require('sshdev').setup({
  remote_path_prepend = { '~/.cargo/bin', '~/.local/bin', '~/bin' },  -- default
})
```

- Entries may be `~`, `~/...` or absolute paths (e.g. `'/opt/llvm/bin'`).
- Only directories that **exist** are added, in list order, once each; a
  directory already on PATH is left alone.
- Set `remote_path_prepend = {}` to keep ssh's PATH exactly as it is.
- The list is not part of the config content hash: changing it never triggers
  a config upload or plugin reinstall.
- An **already running** server receives the new PATH through the RPC control
  channel on the next `:SshDevConnect` / `:SshDevAttach`, so processes started
  afterwards (a new LSP, `:terminal`, `:TSInstall`) see it; an LSP that is
  already running keeps its old environment and needs a restart. A **stopped**
  server gets it from the start script on the next start.
- `PATH=` in the workspace `env.txt` (`:SshDevEnv`) still applies: it becomes
  the base and `remote_path_prepend` is prepended on top of it.
- Your uploaded config runs on the **remote** host, so platform-specific
  `vim.env` settings inside it (for example `vim.env.CC = 'clang.exe'` on
  Windows) apply there too. Guard them with `vim.fn.has('win32') == 1` (or
  `vim.env.SSHDEV_REMOTE == '1'`) if they are client-only.

| Symptom | Meaning / fix |
| --- | --- |
| `ENOENT ... (cmd): 'tree-sitter'` from nvim-treesitter | the remote PATH lacks the CLI's directory. `:SshDevLog` shows the `remote PATH:` line; add the directory to `remote_path_prepend` and reconnect (`:SshDevConnect!` for a server started before the update) |
| a remote LSP / formatter is reported as missing | same cause: its install directory is not in `remote_path_prepend`; add it there, or declare `PATH=...` in `env.txt` |
| `cargo` works in a remote shell but not in the session | the cargo env is loaded by `~/.profile`, which the non-interactive ssh shell never reads — that is exactly what `remote_path_prepend` restores |
| `tree-sitter build` fails with `Failed to execute the C compiler ... clang.exe` | the uploaded config sets a client-only `CC`/`CXX`; the config runs on the remote OS. Guard the assignment with `vim.fn.has('win32')` (see the bullet above) |

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
│   └── --<local-hostname>--<nvim-version>--<hash8-config-content>--/
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
        ├── session.vim  forward.txt  env.txt  last_used
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
  `:SshDevConnect!`/`:SshDevSync` forces it). A second workspace with the same
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
- The connect flowchart at the top of this README lives in
  [assets/how-it-works.mmd](assets/how-it-works.mmd); re-render it with
  `npx -y @mermaid-js/mermaid-cli -i assets/how-it-works.mmd -o assets/how-it-works.svg -b transparent -c assets/mermaid-render.json`
  (the config pins the classic look and `flowchart.wrappingWidth`; pass `-p` a
  puppeteer config with your local Chrome `executablePath`).

### Session persistence (no quit hijacking)

| event | what happens |
| --- | --- |
| `:q`, `:wq`, `:qa`, `SIGTERM` (`:SshDevStop`) | server exits → `session.vim` written (VimLeavePre) |
| `FocusLost` / `VimSuspend` | best-effort snapshot |
| next `:SshDevConnect` | server restarts and `session.vim` is restored (VimEnter) |

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
`:SshDevAttach`, `:SshDevInstall`, `:SshDevSync` and the pickers):

```vim
:SshDevConnect me@myhost:2222 ~/src/app --auth=password
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
  detected and the cached entry dropped, so the next `:SshDevConnect`
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

Stop old servers before upgrading (`:SshDevStop`, or `kill` the remote nvim);
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
  nvim_profile = 'auto',     -- 'auto' | '--<host>--<version>--<hash8>--' (reuse)

  session = true,            -- save <workspace-profile>/session.vim on exit
  restore_session = true,    -- restore it when the server starts
  forward_on_connect = true, -- re-apply forward.txt on (re)connect
  env_on_connect = true,     -- re-inject env.txt on (re)connect

  ssh_bin = 'ssh', scp_bin = 'scp',
  ssh_args = { '-i', '~/.ssh/id_ed25519' },
  auth = 'auto',             -- "auto" (key first, password fallback) | "password" | "key"

  remote_root = '~/.sshdev.nvim',

  nvim_version = 'auto',     -- "auto" | "v0.12.6" | "nightly" | "stable"
  proxy = 'socks5://127.0.0.1:1080',   -- used on the remote host
  download_mirror = 'https://github.com/neovim/neovim/releases/download',
  install_commands = { 'Lazy! restore' },
  excludes = { '.git', '.github' },

  remote_path_prepend = { '~/.cargo/bin', '~/.local/bin', '~/bin' },

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
- `remote_path_prepend` is the remote PATH for the server and every remote
  script; only directories that exist are added (see
  [Remote tool PATH](#remote-tool-path-cargo-pipx-nvim-treesitter)).
- `nvim_profile` is normally `'auto'`; pin a key to reuse a specific existing
  profile for a new workspace.
- `forward_on_connect` / `env_on_connect` (both default `true`) replay
  `forward.txt` / `env.txt` after every connect/attach; disable them to apply
  only explicit saves in the current nvim session.
- History entries keep the **full destination including the ssh port**, so
  picking one reconnects to the right port.
- `env.txt` values are injected into every ssh-run script and into the remote
  server. Keys sshdev reserves (`SSHDEV_*`, `XDG_*_HOME`, `NVIM_APPNAME`,
  `SSH_ASKPASS*`, `HOME`) are rejected; a saved variable reaches a running
  LSP/terminal only after restarting it, and config-time reads need a server
  restart (`:SshDevConnect!`).

## FAQ

**Why did my second workspace connect so fast?**
Because the nvim profile key is the config content hash: the profile from the
first workspace is reused, so there is no scp and no plugin install. Check
`:SshDevLog` — the install phase only appears when the config (or nvim version)
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

**How do I reach a service running on the remote host?**
Use `:SshDevForward`, add `3000 = 127.0.0.1:3000`, save, then open
`http://127.0.0.1:3000`. The target is resolved on the server, so a service
on the server's private network works too (`5432 = db.internal:5432`).

**Where do I set environment variables for the remote session?**
`:SshDevEnv` (or edit `env.txt` in the remote workspace profile directly).
Saving applies the variables to a running server's `vim.env` and to every
later ssh-run script. The file is not part of the nvim profile, so editing it
never triggers a config upload or plugin reinstall.

**Do `:SshDevForward` / `:SshDevEnv` need a running server?**
No. Both edit files in the workspace profile; forwards are client-side ssh
processes and env changes take effect at the next server start. Inside an
attached session the commands transparently use the control channel.

**Why do quotes / `$VAR` in `env.txt` not behave like a shell?**
Values are used verbatim: quotes are kept and variables are not expanded. The
file is a plain `KEY=VALUE` list, not a shell script — quote/expansion
semantics would differ between the local mirror, the remote export and
`vim.env`.

**How do I get rid of old nvim profiles?**
Each config edit creates a new `nvim-profiles/--…--` directory (the old one is
kept for reuse/pinning). `:SshDevProfiles` lists them; delete unused ones with
`rm -rf <remote_root>/nvim-profiles/<key>` when no workspace links to them.

## License

MIT — see [LICENSE](LICENSE).
