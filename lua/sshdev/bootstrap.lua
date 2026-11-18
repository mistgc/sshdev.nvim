--- Everything sshdev.nvim does ON THE REMOTE HOST:
---
--- * probe the platform ($HOME, uname, curl availability)
--- * create the ~/.sshdev.nvim/<workspace>/ layout
--- * ensure a release of nvim matching the LOCAL version exists
---   (downloads through a proxy/mirror when configured)
--- * scp the uploaded config + the remote shim
--- * run the remote nvim headless so your plugin manager installs the
---   plugins declared in the uploaded config
--- * start / stop / inspect the detached `nvim --headless --listen` server
---
--- Remote scripts are POSIX sh, rendered from templates below and executed
--- via `ssh host sh -s` with the script on stdin (zero quoting hazards).
--- They report machine-readable `SSHDEV:KEY=VALUE` lines.

local M = {}

local Ssh = require('sshdev.ssh')
local Util = require('sshdev.util')

------------------------------------------------------------------------
-- Script templates
------------------------------------------------------------------------

local PROBE_SCRIPT = [[
set -eu
printf 'SSHDEV:HOME=%s\n' "$HOME"
printf 'SSHDEV:SYS=%s\n' "$(uname -s 2>/dev/null || echo unknown)"
printf 'SSHDEV:MACHINE=%s\n' "$(uname -m 2>/dev/null || echo unknown)"
command -v curl >/dev/null 2>&1 && printf 'SSHDEV:CURL=yes\n' || printf 'SSHDEV:CURL=no\n'
command -v tar  >/dev/null 2>&1 && printf 'SSHDEV:TAR=yes\n'  || printf 'SSHDEV:TAR=no\n'
printf 'SSHDEV:SH=ok\n'
]]

local ENSURE_NVIM_SCRIPT = [[
set -eu
ROOT='{{ROOT}}'
URL='{{URL}}'
PROXY='{{PROXY}}'
EXTRA_ENV='{{EXTRA_ENV}}'
BIN_DIR='{{BIN_DIR}}'

if [ -x "$BIN_DIR/bin/nvim" ]; then
  printf 'SSHDEV:BIN=%s\n' "$BIN_DIR/bin/nvim"
  printf 'SSHDEV:BINVERSION=%s\n' "$("$BIN_DIR/bin/nvim" -v | head -n 1)"
  exit 0
fi

command -v curl >/dev/null 2>&1 || { printf 'SSHDEV:ERROR=curl-missing\n'; exit 1; }
command -v tar  >/dev/null 2>&1 || { printf 'SSHDEV:ERROR=tar-missing\n';  exit 1; }

printf 'SSHDEV:PHASE=download\n'
rm -rf "$BIN_DIR"
mkdir -p "$BIN_DIR"
TMP="$BIN_DIR.tmp.$$"
rm -rf "$TMP"
mkdir -p "$TMP"
if [ -n "$EXTRA_ENV" ]; then
  eval "export $EXTRA_ENV"
fi
if [ -n "$PROXY" ]; then
  http_proxy="$PROXY" https_proxy="$PROXY" all_proxy="$PROXY" \
    curl --fail --location --retry 3 --connect-timeout 20 -o "$TMP/nvim.tar.gz" "$URL"
else
  curl --fail --location --retry 3 --connect-timeout 20 -o "$TMP/nvim.tar.gz" "$URL"
fi
tar -xzf "$TMP/nvim.tar.gz" -C "$TMP"
rm -f "$TMP/nvim.tar.gz"
N=0
TOP=''
for f in "$TMP"/*; do
  N=$(( N + 1 ))
  TOP="$f"
done
if [ "$N" -eq 1 ] && [ -d "$TOP" ]; then
  mv "$TOP" "$BIN_DIR"
  rm -rf "$TMP"
else
  mv "$TMP" "$BIN_DIR"
fi
if [ ! -x "$BIN_DIR/bin/nvim" ]; then
  printf 'SSHDEV:ERROR=bad-archive\n'
  rm -rf "$BIN_DIR"
  exit 1
fi
printf 'SSHDEV:BIN=%s\n' "$BIN_DIR/bin/nvim"
printf 'SSHDEV:BINVERSION=%s\n' "$("$BIN_DIR/bin/nvim" -v | head -n 1)"
]]

local PREPARE_WS_SCRIPT = [[
set -eu
WS_DIR='{{WS_DIR}}'
mkdir -p "$WS_DIR"
rm -rf "$WS_DIR/nvim-config"
printf 'SSHDEV:WS_DIR=%s\n' "$WS_DIR"
]]

local INSTALL_SCRIPT = [[
set -eu
WS_DIR='{{WS_DIR}}'
CWD='{{CWD}}'
BIN='{{BIN}}'
cd "$CWD" || { printf 'SSHDEV:ERROR=cwd\n'; exit 1; }
export XDG_CONFIG_HOME='{{WS_DIR}}'
export XDG_DATA_HOME='{{WS_DIR}}/xdg/share'
export XDG_STATE_HOME='{{WS_DIR}}/xdg/state'
export XDG_CACHE_HOME='{{WS_DIR}}/xdg/cache'
export NVIM_APPNAME=nvim-config
export SSHDEV_WORKSPACE='{{WS}}'
printf 'SSHDEV:PHASE=install\n'
"$BIN" --headless{{INSTALL_CMDS}} +qa!
printf 'SSHDEV:INSTALL=ok\n'
]]

local START_SCRIPT = [[
set -eu
WS_DIR='{{WS_DIR}}'
CWD='{{CWD}}'
BIN='{{BIN}}'
RPORT='{{RPORT}}'
HIJACK='{{HIJACK}}'
PID_FILE="$WS_DIR/server.pid"
LOG="$WS_DIR/server.log"

if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  printf 'SSHDEV:SERVER=running\n'
  printf 'SSHDEV:PID=%s\n' "$(cat "$PID_FILE")"
  if [ -f "$WS_DIR/server.addr" ]; then
    printf 'SSHDEV:ADDR=%s\n' "$(cat "$WS_DIR/server.addr")"
  fi
  exit 0
fi
rm -f "$PID_FILE" "$WS_DIR/server.addr"

cd "$CWD" || { printf 'SSHDEV:ERROR=cwd\n'; exit 1; }

export XDG_CONFIG_HOME="$WS_DIR"
export XDG_DATA_HOME="$WS_DIR/xdg/share"
export XDG_STATE_HOME="$WS_DIR/xdg/state"
export XDG_CACHE_HOME="$WS_DIR/xdg/cache"
export NVIM_APPNAME=nvim-config
export SSHDEV_REMOTE=1
export SSHDEV_WORKSPACE='{{WS}}'
export SSHDEV_HIJACK='{{HIJACK}}'

nohup "$BIN" --headless --listen 127.0.0.1:"$RPORT" \
  -c 'luafile {{SHIM}}' </dev/null >"$LOG" 2>&1 &
PID=$!
printf '%s\n' "$PID" >"$PID_FILE"
printf '127.0.0.1:%s\n' "$RPORT" >"$WS_DIR/server.addr"

sleep 1
if ! kill -0 "$PID" 2>/dev/null; then
  printf 'SSHDEV:SERVER=dead\n'
  cat "$LOG" 2>/dev/null || true
  rm -f "$PID_FILE" "$WS_DIR/server.addr"
  exit 1
fi
printf 'SSHDEV:SERVER=started\n'
printf 'SSHDEV:PID=%s\n' "$PID"
printf 'SSHDEV:ADDR=127.0.0.1:%s\n' "$RPORT"
]]

local STATUS_SCRIPT = [[
set -eu
WS_DIR='{{WS_DIR}}'
PID_FILE="$WS_DIR/server.pid"
if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  printf 'SSHDEV:SERVER=running\n'
  printf 'SSHDEV:PID=%s\n' "$(cat "$PID_FILE")"
else
  printf 'SSHDEV:SERVER=stopped\n'
  rm -f "$PID_FILE"
fi
if [ -f "$WS_DIR/server.addr" ]; then
  printf 'SSHDEV:ADDR=%s\n' "$(cat "$WS_DIR/server.addr")"
fi
]]

local STOP_SCRIPT = [[
set -eu
WS_DIR='{{WS_DIR}}'
PID_FILE="$WS_DIR/server.pid"
if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  PID="$(cat "$PID_FILE")"
  kill "$PID" 2>/dev/null || true
  sleep 1
  if kill -0 "$PID" 2>/dev/null; then
    kill -9 "$PID" 2>/dev/null || true
  fi
  printf 'SSHDEV:KILLED=%s\n' "$PID"
fi
rm -f "$PID_FILE" "$WS_DIR/server.addr"
printf 'SSHDEV:SERVER=stopped\n'
]]

-- Exposed for tests: every remote script template, so the unit tests can
-- render them with representative values and assert no {{placeholder}}
-- is left behind (a missing key would silently ship broken shell).
M._script_templates = {
  probe = PROBE_SCRIPT,
  ensure = ENSURE_NVIM_SCRIPT,
  prepare = PREPARE_WS_SCRIPT,
  install = INSTALL_SCRIPT,
  start = START_SCRIPT,
  status = STATUS_SCRIPT,
  stop = STOP_SCRIPT,
}

------------------------------------------------------------------------
-- Platform mapping
------------------------------------------------------------------------

---Neovim release asset for a remote platform. Returns nil for unsupported
---platforms (the caller turns this into a readable error).
---@param sys string  e.g. "Linux", "Darwin"
---@param machine string  e.g. "x86_64", "aarch64", "arm64"
---@return string? asset
function M.asset_name(sys, machine)
  local s = sys:lower()
  local m = machine:lower()
  if s:find('linux') then
    if m == 'x86_64' or m == 'amd64' then
      return 'nvim-linux-x86_64'
    elseif m == 'aarch64' or m == 'arm64' then
      return 'nvim-linux-aarch64'
    end
  elseif s:find('darwin') then
    if m == 'arm64' or m == 'aarch64' then
      return 'nvim-macos-arm64'
    elseif m == 'x86_64' or m == 'amd64' then
      return 'nvim-macos-x86_64'
    end
  end
  return nil
end

---Resolve which nvim release to install on the remote.
---Returns (tag, is_dev_fallback, warn_message?).
---@param cfg table
---@return string tag
---@return boolean dev_fallback
---@return string? warn
function M.resolve_version(cfg)
  local wanted = cfg.nvim_version or 'auto'
  if wanted ~= 'auto' then
    if wanted == 'nightly' or wanted == 'stable' then
      return wanted, false, nil
    end
    if not wanted:match('^v') then
      wanted = 'v' .. wanted
    end
    return wanted, false, nil
  end
  local tag, dev = Util.nvim_version_tag()
  if dev then
    return 'nightly', true, ('local nvim %s is a dev build; installing the remote from the "nightly" release (pin cfg.nvim_version to control this)'):format(tag)
  end
  return tag, false, nil
end

------------------------------------------------------------------------
-- Probe
------------------------------------------------------------------------

---Probe the remote host: $HOME, platform, tools. Must run in a flow.
---Returns a probe table or (nil, err).
---@param cfg table
---@param parsed table
---@return table? probe
---@return string? err
function M.probe(cfg, parsed)
  local res = Ssh.run_script(cfg, parsed, PROBE_SCRIPT, {
    timeout = cfg.timeouts.ssh,
    label = 'ssh',
  })
  if res.code ~= 0 then
    return nil, ('ssh connection to %s failed (exit %s)%s'):format(
      parsed.dest,
      res.code,
      res.stderr ~= '' and (':\n' .. Util.tail(res.stderr, 5)) or ''
    )
  end
  local kv = Util.parse_keyvals(res.stdout)
  if kv.SH ~= 'ok' then
    return nil, 'the remote host did not run POSIX sh (is it a Linux/macOS box?)'
  end
  if not kv.HOME or kv.HOME == '' then
    return nil, 'the remote host did not report $HOME'
  end
  return {
    home = kv.HOME,
    sys = kv.SYS or 'unknown',
    machine = kv.MACHINE or 'unknown',
    curl = kv.CURL == 'yes',
    tar = kv.TAR == 'yes',
  }
end

------------------------------------------------------------------------
-- Workspace context
------------------------------------------------------------------------

---Build the workspace context for a connection: resolved remote root,
---workspace name and the remote cwd (the user-designated remote folder).
---
---Workspace name priority: cfg.workspace > remotes key used > basename of
---the (explicitly given) remote dir > "default".
---@param cfg table
---@param parsed table
---@param probe table
---@param path_arg string|nil  remote dir from the command line
---@param ws_hint string|nil  workspace name when the dest was a remotes key
---@return table ctx  { dest, home, sys, machine, root, ws, cwd, ws_dir }
---@return string? err
function M.workspace_ctx(cfg, parsed, probe, path_arg, ws_hint)
  local root = Util.remote_root_abs(cfg, probe.home)
  local cwd = path_arg or cfg.remote_dir or probe.home
  cwd = Util.expand_remote_home(cwd, probe.home)
  if cwd:sub(1, 1) ~= '/' then
    return nil, ('remote dir %q must be absolute or "~/..."'):format(cwd)
  end
  local explicit = path_arg or cfg.remote_dir
  local ws
  if cfg.workspace then
    ws = Util.sanitize_ws(cfg.workspace)
  elseif ws_hint then
    ws = Util.sanitize_ws(ws_hint)
  elseif explicit and cwd ~= probe.home then
    ws = Util.sanitize_ws(vim.fs.basename(cwd))
  else
    ws = 'default'
  end
  local ctx = {
    dest = parsed.dest,
    home = probe.home,
    sys = probe.sys,
    machine = probe.machine,
    root = root,
    ws = ws,
    cwd = cwd,
    ws_dir = Util.join_remote(root, ws),
  }
  return ctx, nil
end

------------------------------------------------------------------------
-- Steps (all run inside a flow coroutine)
------------------------------------------------------------------------

---Ensure a nvim binary of the requested release exists under
---~/.sshdev.nvim/_bin/<version>-<asset>/bin/nvim; download it when missing.
---Returns { bin, version_line } or (nil, err).
---@param cfg table
---@param parsed table
---@param ctx table  needs: root, ws, sys, machine, version, asset
---@return table? result
---@return string? err
function M.ensure_binary(cfg, parsed, ctx)
  local version = ctx.version
  local asset = ctx.asset
  local bin_dir = Util.join_remote(ctx.root, '_bin', version .. '-' .. asset)
  local url = ('%s/%s/%s.tar.gz'):format(cfg.download_mirror, version, asset)

  local extra_env = {}
  if cfg.proxy then
    table.insert(extra_env, ('http_proxy=%s'):format(cfg.proxy))
    table.insert(extra_env, ('https_proxy=%s'):format(cfg.proxy))
    table.insert(extra_env, ('all_proxy=%s'):format(cfg.proxy))
  end
  -- install_commands are NOT part of the env; join env pairs for `eval`.
  local extra_env_str = table.concat(extra_env, ' ')

  local script = Util.render(ENSURE_NVIM_SCRIPT, {
    ROOT = Util.shsafe(ctx.root, 'remote root'),
    URL = Util.shsafe(url, 'download url'),
    PROXY = cfg.proxy and Util.shsafe(cfg.proxy, 'proxy') or '',
    EXTRA_ENV = Util.shsafe(extra_env_str, 'proxy env'),
    BIN_DIR = Util.shsafe(bin_dir, 'nvim install dir'),
  })

  local res = Ssh.run_script(cfg, parsed, script, {
    timeout = cfg.timeouts.download,
    label = 'ssh',
  })
  local kv = Util.parse_keyvals(res.stdout)
  if kv.ERROR == 'curl-missing' then
    return nil, 'the remote host has no curl; install nvim there manually and set cfg.nvim_bin'
  end
  if kv.ERROR == 'tar-missing' then
    return nil, 'the remote host has no tar; install nvim there manually and set cfg.nvim_bin'
  end
  if kv.ERROR == 'bad-archive' then
    return nil, ('the downloaded archive %s did not contain bin/nvim (check download_mirror)'):format(url)
  end
  if res.code ~= 0 or not kv.BIN then
    return nil, ('downloading nvim %s on the remote failed (exit %s):\n%s'):format(
      version,
      res.code,
      Util.log_tail(res.stderr .. res.stdout, 10)
    )
  end
  return { bin = kv.BIN, version_line = kv.BINVERSION or '?' }
end

---scp the remote shim (scripts/remote_shim.lua) into the workspace.
function M.upload_shim(cfg, parsed, ctx)
  local root = Util.plugin_root()
  if not root then
    return nil, 'cannot locate the sshdev.nvim plugin directory'
  end
  local cwd = Util.fs_join(root, 'scripts')
  local target = Util.join_remote(ctx.ws_dir, 'shim.lua')
  local res = Ssh.upload_file(cfg, parsed, cwd, 'remote_shim.lua', target, cfg.timeouts.ssh)
  if res.code ~= 0 then
    return nil, ('uploading the remote shim failed (exit %s):\n%s'):format(res.code, Util.log_tail(res.stderr, 10))
  end
  return true
end

---Prepare the workspace dir and upload the local nvim config via scp
---(staged locally first so excludes apply).
function M.upload_config(cfg, parsed, ctx)
  -- mkdir + wipe previous nvim-config
  local prep = Util.render(PREPARE_WS_SCRIPT, {
    WS_DIR = Util.shsafe(ctx.ws_dir, 'workspace dir'),
  })
  local res = Ssh.run_script(cfg, parsed, prep, { timeout = cfg.timeouts.ssh, label = 'ssh' })
  if res.code ~= 0 then
    return nil, ('preparing %s failed (exit %s):\n%s'):format(ctx.ws_dir, res.code, Util.log_tail(res.stderr, 10))
  end

  -- stage locally, then scp the staged directory
  local parent, derr = Util.stage_config(cfg, ctx.ws)
  if not parent then
    return nil, ('staging your config failed: %s'):format(tostring(derr))
  end
  local up = Ssh.upload_dir(cfg, parsed, parent, 'nvim-config', ctx.ws_dir, cfg.timeouts.ssh)
  if up.code ~= 0 then
    return nil, ('scp of your config failed (exit %s):\n%s'):format(up.code, Util.log_tail(up.stderr, 10))
  end
  return true
end

---Run the remote nvim headless so plugins declared in the uploaded config
---get installed (your plugin manager's bootstrap does the cloning; extra
---commands from cfg.install_commands run after your init is sourced).
function M.install_plugins(cfg, parsed, ctx)
  local extra = ''
  for _, c in ipairs(cfg.install_commands or {}) do
    extra = extra .. ' -c ' .. Util.shquote(c)
  end
  local script = Util.render(INSTALL_SCRIPT, {
    WS_DIR = Util.shsafe(ctx.ws_dir, 'workspace dir'),
    CWD = Util.shsafe(ctx.cwd, 'remote dir'),
    BIN = Util.shsafe(ctx.bin, 'remote nvim binary'),
    WS = Util.shsafe(ctx.ws, 'workspace name'),
    INSTALL_CMDS = extra,
  })
  local res = Ssh.run_script(cfg, parsed, script, {
    timeout = cfg.timeouts.install,
    label = 'install',
  })
  if res.stdout ~= '' then
    Util.log('[install] %s', res.stdout)
  end
  if res.code ~= 0 then
    return nil, ('remote plugin install failed (exit %s) — output is in :SSHdevLog'):format(res.code)
  end
  return true
end

---Start the detached remote server. Returns
---{ running = true, addr = "127.0.0.1:port", pid = "..." , fresh = bool }
---or (nil, err).
---@param cfg table
---@param parsed table
---@param ctx table  needs: ws_dir, cwd, ws, bin, hijack
---@param rport integer
---@return table? server
---@return string? err
function M.start_server(cfg, parsed, ctx, rport)
  local script = Util.render(START_SCRIPT, {
    WS_DIR = Util.shsafe(ctx.ws_dir, 'workspace dir'),
    CWD = Util.shsafe(ctx.cwd, 'remote dir'),
    BIN = Util.shsafe(ctx.bin, 'remote nvim binary'),
    WS = Util.shsafe(ctx.ws, 'workspace name'),
    RPORT = tostring(rport),
    HIJACK = ctx.hijack and '1' or '0',
    SHIM = Util.shsafe(Util.join_remote(ctx.ws_dir, 'shim.lua'), 'shim path'),
  })
  local res = Ssh.run_script(cfg, parsed, script, {
    timeout = cfg.timeouts.ssh,
    label = 'ssh',
  })
  if res.code ~= 0 then
    return nil, ('starting the remote server failed (exit %s):\n%s'):format(
      res.code,
      Util.log_tail(res.stdout .. res.stderr, 15)
    )
  end
  local kv = Util.parse_keyvals(res.stdout)
  if kv.SERVER == 'running' then
    return { running = true, addr = kv.ADDR, pid = kv.PID, fresh = false }
  end
  if kv.SERVER == 'started' then
    return { running = true, addr = kv.ADDR, pid = kv.PID, fresh = true }
  end
  if kv.SERVER == 'dead' then
    return nil, 'the remote nvim server died immediately after start:\n' .. Util.log_tail(res.stdout, 15)
  end
  return nil, 'unexpected response from the remote start script:\n' .. Util.log_tail(res.stdout, 15)
end

---Check whether the workspace's server is running.
---Returns { running, pid, addr } or (nil, err).
function M.server_status(cfg, parsed, ctx)
  local script = Util.render(STATUS_SCRIPT, {
    WS_DIR = Util.shsafe(ctx.ws_dir, 'workspace dir'),
  })
  local res = Ssh.run_script(cfg, parsed, script, { timeout = cfg.timeouts.ssh, label = 'ssh' })
  if res.code ~= 0 then
    return nil, ('checking the remote server failed (exit %s)'):format(res.code)
  end
  local kv = Util.parse_keyvals(res.stdout)
  return { running = kv.SERVER == 'running', pid = kv.PID, addr = kv.ADDR }
end

---Stop the workspace's server (SIGTERM, then SIGKILL).
function M.stop_server(cfg, parsed, ctx)
  local script = Util.render(STOP_SCRIPT, {
    WS_DIR = Util.shsafe(ctx.ws_dir, 'workspace dir'),
  })
  local res = Ssh.run_script(cfg, parsed, script, { timeout = cfg.timeouts.ssh, label = 'ssh' })
  if res.code ~= 0 then
    return nil, ('stopping the remote server failed (exit %s)'):format(res.code)
  end
  return true
end

return M
