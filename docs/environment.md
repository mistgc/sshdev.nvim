# sshdev.nvim Environment Variables — Technical Documentation

This document describes the **environment-variable injection** subsystem:
the `env.txt` file protocol, how values reach the remote nvim server and
every ssh-run script, the runtime push through the RPC control channel,
and the security handling. The connection pipeline is covered in
[remote-connection.md](remote-connection.md); port forwarding in
[port-forwarding.md](port-forwarding.md).

---

## 1. Overview

A workspace's variables are declared in the remote workspace profile:

```text
<remote_root>/workspace-profiles/--<host>--<ws-path>--/env.txt
```

They are injected at three points, all fed from one in-memory **active
map**:

| Point | Mechanism | Visible to |
| --- | --- | --- |
| Every remote script | `export KEY='value'` lines prepended to the script on stdin | the remote shell and everything it starts: nvim download, plugin install, server start |
| Remote nvim server | inherited from the start script's exports **before** user config loads | `vim.env` at config time; LSPs, `:terminal`, `jobstart` |
| A running server | `nvim_exec_lua` through the RPC control channel, assigning `vim.env` | children started after the push |
| Local ssh/scp children | `Union(active map, Auth.env)` passed as the job's `env` | the local ssh client only (not the remote command) |

The split matters:

- **startup injection** is the only way config-time `vim.env` reads see the
  values (the process environment must exist before nvim starts);
- **runtime injection** cannot change a process environment retroactively, so
  an LSP client already started keeps its old variables — it must be restarted;
- **ssh/scp overlays** are local only; OpenSSH does not forward arbitrary
  environment variables (and `SendEnv` is deliberately not used). What the
  remote command actually sees is the script prefix.

## 2. `env.txt`: location and format

Strict, line based, one variable per line:

```text
# comment
KEY=VALUE
NODE_ENV=development
DATABASE_URL=postgres://127.0.0.1:5432/app
PATH=/opt/tools/bin:/usr/bin:/bin
```

Grammar:

```text
line        := blank | comment | assignment
blank       := ""            (CRLF tolerated: one trailing \r is stripped)
comment     := '#' ...
assignment  := KEY '=' VALUE
KEY         := [A-Za-z_][A-Za-z0-9_]*
VALUE       := everything after the FIRST '=' (may be empty)
```

- Values are **verbatim**: spaces, `#`, `=`, quotes and `$VAR` are kept;
  nothing is expanded and no quotes are stripped.
- An optional UTF-8 BOM at the start of the file is ignored.
- `Env.parse` collects every bad line with its line number; a single bad line
  means the whole file is not applied.
- Duplicate keys are errors (both line numbers are reported).
- Reserved keys are errors:
  - prefix `SSHDEV_` (plugin namespace),
  - `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME`,
    `NVIM_APPNAME` (profile isolation),
  - `SSH_ASKPASS`, `SSH_ASKPASS_REQUIRE` (auth),
  - `HOME` (it would move a local ssh child's config, known_hosts and keys).
- A NUL byte or an internal carriage return in a value is rejected.

Error messages cite line numbers and **never echo the raw line**: a malformed
line is often a mistyped secret. `Env.parse` only includes the key part when
it can identify one.

## 3. Active map and quoting

`lua/sshdev/env.lua` keeps the currently injected variables in memory, keyed
by the destination string (`user@host:port`). `connect`/`install`/`sync`
clear it and reload the workspace's `env.txt`; the plugin is single-session,
so only one workspace's map is active at a time.

`Env.script_prefix(parsed)` renders deterministic, sorted lines:

```sh
export DATABASE_URL='postgres://127.0.0.1:5432/app'
export PATH='/opt/tools/bin:/usr/bin:/bin'
```

Each value goes through `Util.shquote` (single quotes, embedded `'` becomes
`'\''`), so spaces, `$`, backticks, `&`, `#` and `=` can never be interpreted
by the remote shell. The prefix is prepended **before** a template's own
`set -eu` and `export XDG_*/SSHDEV_*` lines, so sshdev's internal variables
always win (the parser also rejects the reserved keys).

`Env.spawn_overlay(parsed)` returns a copy of the same map for a local
ssh/scp child; `Ssh` merges it with `Auth.env()` and **auth keys win**, so the
askpass mechanism cannot be overridden.

## 4. Connect flow

```text
prepare()        probe + layout (no env: the profile path is not known yet)
  │
  ▼
Env.load()       read env.txt (read-only ssh), parse, set active
  │              missing file -> empty map; parse errors -> warn, inject none
  │              also refreshes the local mirror
  ▼
Bootstrap.ensure/commit/start
  │              Ssh.run_script prefixes every script with the exports
  ▼
start script     export ... ; nohup "$BIN" --headless ...
  │              the server process inherits the map before config loads
  ▼
run_attach()     open the control channel, then Env.push() (vim.env)
                 covers re-attaching to an already-running server and
                 unsets keys removed from env.txt
```

The first remote probe of a fresh nvim process is the one step that cannot
see `env.txt` (the workspace profile path depends on that probe). Everything
from `Bootstrap.ensure` onward does.

`cfg.env_on_connect = false` skips `Env.load`: only variables explicitly
saved with `:SshDevEnv` in this nvim session are injected.

## 5. Editing and saving

`lua/sshdev/forward.lua`'s editing pattern is reused:

1. `:SshDevEnv` resolves the workspace profile (active session fast path, or
   `prepare(opts)`), fetches `env.txt` read-only (`Scripts.env_fetch`, content
   between token markers), writes the local mirror at
   `stdpath("cache")/sshdev/env/<ws-key>/env.txt`, and opens it.
2. `BufWritePost` triggers `Env.apply`:
   parse the mirror → on errors notify and change nothing →
   `Scripts.env_prepare` if the remote file is new → `Ssh.upload_file` with
   `-p` (keeps the 0600 mode) → update the active map → `Env.push` when a
   control channel exists.
3. Without a running server the file is only persisted; the next
   `:SshDevConnect` starts the server with it.

The local mirror is written with mode 0600; the buffer disables `swapfile`
and `undofile` (it may contain secrets).

## 6. Runtime push

`Env.push` sends a **static** Lua chunk plus the map as an argument:

```lua
vim.fn.rpcnotify(ch, 'nvim_exec_lua', APPLY_CHUNK, { vars })
```

```lua
local vars = select(1, ...)
local old = _G.SSHDEV_ENV_APPLIED
if old == nil then
  old = {}
  for k in (vim.env.SSHDEV_ENV_KEYS or ''):gmatch('%S+') do old[k] = true end
end
for k in pairs(old) do
  if vars[k] == nil then vim.env[k] = nil end
end
for k, v in pairs(vars) do vim.env[k] = v end
_G.SSHDEV_ENV_APPLIED = vars
```

- The chunk is static; values travel as MessagePack arguments, never as Lua
  source.
- `SSHDEV_ENV_KEYS` (exported by the start script) is the initial key manifest,
  so a save that removes a line can unset the variable even in a server that
  only received it at startup. After the first push, `_G.SSHDEV_ENV_APPLIED`
  is authoritative.
- A server started before this feature has no manifest; removed keys then
  survive until `:SshDevConnect!` restarts it.

`Env.apply_runtime(vars)` runs the same chunk locally; the remote-side editor
uses it so a save takes effect even when the client channel is gone.

## 7. Inside the attached session

With the default `:connect` attach, `:SshDevEnv` is executed by the **remote**
nvim (`SSHDEV_REMOTE=1`): `Env.open_remote` opens the env.txt on the server.
On save it:

1. reads and parses the file, applies it to the server with
   `Env.apply_runtime` (immediate, no client needed), and
2. notifies the client (`_remote_env_apply(profile)` over
   `SSHDEV_CONTROL_CHANNEL`), which refreshes its local mirror and active map
   and pushes the same state idempotently.

If the channel is dead, step 1 still applies to the server; the client's
mirror and ssh/scp environment refresh on the next connect.

## 8. Security

- Values may be secrets. They are never logged or shown in notifications;
  errors cite line numbers and keys only.
- A failed `env_fetch` reports the ssh stderr tail, never the captured stdout.
- Local mirror 0600, remote `env.txt` 0600 (`scp -p`), `env_prepare` uses
  `umask 077` and best-effort `chmod 700` on the profile directory.
- No swap/undo file for the `env.txt` buffer.
- The local ssh/scp child environment contains the values (the user asked for
  injection into ssh commands). This is visible to the same user's processes,
  and is the accepted trade-off; it is not sent to the remote except through
  the script prefix.

## 9. Commands and configuration

| Item | Meaning |
| --- | --- |
| `:SshDevEnv [dest] [workspace]` | edit this workspace's `env.txt` (save to apply) |
| `:SshDevEnv` (inside an attached session) | edit the server-side file; save applies there |
| `require('sshdev').env(opts)` | Lua API |
| `env_on_connect` | default `true`; re-read and inject `env.txt` on connect/attach |

`env.txt` is per (client host, workspace), like `forward.txt`; it is not part
of the nvim profile or its content hash, so changing it never triggers a
config upload or plugin reinstall.

## 10. Troubleshooting

- **A new variable is not visible in a running LSP** — the LSP process was
  started with the old environment; restart the LSP client. Config-time
  `vim.env` reads need `:SshDevConnect!` (server restart).
- **A removed variable is still set** — the running server predates the
  `SSHDEV_ENV_KEYS` manifest; restart with `:SshDevConnect!`.
- **Nothing was applied after a save** — the notification lists the invalid
  lines; fix them and save again.
- **`HOME`/`XDG_*`/`SSHDEV_*` rejected** — these are reserved because they
  would break the transport or the profile isolation.
- **The variable exists on the remote command but not in `vim.env`** — the
  command ran before the runtime push; reconnect or restart the server.

## 11. Source index

| Module | Responsibility |
| --- | --- |
| `lua/sshdev/env.lua` | parse/template/local mirror, active map, open/apply/apply_remote/open_remote, runtime chunk |
| `lua/sshdev/ssh.lua` | script prefix, local ssh/scp env overlay, `scp -p` |
| `lua/sshdev/remote_scripts.lua` | `env_fetch`, `env_prepare`, `start` key manifest |
| `lua/sshdev/bootstrap.lua` | renders `ENV_KEYS` into the start script |
| `lua/sshdev/session.lua` | `load_env`, `:SshDevEnv` flow, remote-triggered apply, attach-time push |
| `lua/sshdev/layout.lua` | `<workspace-profile>/env.txt` path |
| `lua/sshdev/config.lua` | `env_on_connect` |
| `lua/sshdev/util.lua` | `extract_marked`, `merge_env`, quoting |
