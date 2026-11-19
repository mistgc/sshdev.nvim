--- Everything sshdev.nvim does ON THE REMOTE HOST.
---
--- Remote layout:
---
---   ~/.sshdev.nvim/
---   ├── _bin/<version>-<asset>/          nvim releases, shared by profiles
---   └── --<local-hostname>--<ws-path>--/      one profile per (client, workspace)
---       ├── nvim-config/                 uploaded config (NVIM_APPNAME)
---       ├── data/                        XDG_DATA_HOME (plugins, shada)
---       ├── state/                       XDG_STATE_HOME
---       ├── cache/                       XDG_CACHE_HOME
---       ├── session.lua                  server-side session helper
---       ├── session.vim                  saved nvim session
---       ├── .synced                      fingerprint of the uploaded config
---       ├── server.pid / server.addr
---       └── server.log
---
--- Remote scripts are POSIX sh, rendered from templates and executed via
--- `ssh host sh -s` with the script on stdin (zero quoting hazards). They
--- report machine-readable `SSHDEV:KEY=VALUE` lines.

local Ssh = require('sshdev.ssh')
local Util = require('sshdev.util')

local M = {}

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

---Shell fragment: locate the server for this profile even when the pid file
---was lost (e.g. a crash or a concurrent connect). Uses the pid file first,
---then falls back to matching the unique command line
---"<profile>/session.lua".
local FIND_RUNNING_SH = [[
FIND_RUNNING() {
  P=''
  if [ -f "$PID_FILE" ]; then
    P=$(cat "$PID_FILE" 2>/dev/null || true)
    if [ -n "$P" ] && kill -0 "$P" 2>/dev/null; then
      printf '%s' "$P"
      return 0
    fi
  fi
  if command -v pgrep >/dev/null 2>&1; then
    P=$(pgrep -f -- "$PROFILE/session.lua" 2>/dev/null | head -n 1 || true)
    if [ -n "$P" ] && kill -0 "$P" 2>/dev/null; then
      printf '%s' "$P"
      return 0
    fi
  fi
  return 1
}

# Is the server's address accepting connections yet?
PORT_LISTENING() {
  PORT="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -q "127.0.0.1:$PORT" && return 0
    return 1
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | grep -q "127.0.0.1:$PORT" && return 0
    return 1
  fi
  return 2
}
]]

-- One round trip that does everything cheap: check/download the nvim
-- binary, report whether the server is running, and report the fingerprint
-- of the last successful config sync.
local ENSURE_SCRIPT = [==[
set -eu
ROOT='{{ROOT}}'
VERSION='{{VERSION}}'
MIRROR='{{MIRROR}}'
PROXY='{{PROXY}}'
PROFILE='{{PROFILE}}'
SYS='{{SYS}}'
MACHINE='{{MACHINE}}'
PID_FILE="$PROFILE/server.pid"

{{FIND_RUNNING}}

# --- resolve release asset ------------------------------------------------
LOWER_SYS=$(printf '%s' "$SYS" | tr '[:upper:]' '[:lower:]')
LOWER_MACHINE=$(printf '%s' "$MACHINE" | tr '[:upper:]' '[:lower:]')
ASSET=''
case "$LOWER_SYS" in
  *linux*)
    case "$LOWER_MACHINE" in
      x86_64|amd64)    ASSET='nvim-linux-x86_64' ;;
      aarch64|arm64)   ASSET='nvim-linux-aarch64' ;;
    esac ;;
  *darwin*)
    case "$LOWER_MACHINE" in
      arm64|aarch64)   ASSET='nvim-macos-arm64' ;;
      x86_64|amd64)    ASSET='nvim-macos-x86_64' ;;
    esac ;;
esac
if [ -z "$ASSET" ]; then
  printf 'SSHDEV:ERROR=unsupported-platform\n'
  exit 0
fi
BIN_DIR="$ROOT/_bin/$VERSION-$ASSET"
printf 'SSHDEV:ASSET=%s\n' "$ASSET"
printf 'SSHDEV:BIN_DIR=%s\n' "$BIN_DIR"

# --- ensure the binary ---------------------------------------------------
if [ -x "$BIN_DIR/bin/nvim" ]; then
  printf 'SSHDEV:BIN=%s\n' "$BIN_DIR/bin/nvim"
else
  command -v curl >/dev/null 2>&1 || { printf 'SSHDEV:ERROR=curl-missing\n'; exit 0; }
  command -v tar  >/dev/null 2>&1 || { printf 'SSHDEV:ERROR=tar-missing\n';  exit 0; }
  URL="$MIRROR/$VERSION/$ASSET.tar.gz"
  printf 'SSHDEV:PHASE=download\n'
  printf 'SSHDEV:URL=%s\n' "$URL"
  TMP="$ROOT/.nvim-download.$$"
  rm -rf "$TMP"
  mkdir -p "$TMP"
  if [ -n "$PROXY" ]; then
    http_proxy="$PROXY" https_proxy="$PROXY" all_proxy="$PROXY" \
      curl --fail --location --silent --show-error --retry 3 \
        --connect-timeout 20 --max-time 900 -o "$TMP/nvim.tar.gz" "$URL"
  else
    curl --fail --location --silent --show-error --retry 3 \
      --connect-timeout 20 --max-time 900 -o "$TMP/nvim.tar.gz" "$URL"
  fi
  tar -xzf "$TMP/nvim.tar.gz" -C "$TMP"
  rm -f "$TMP/nvim.tar.gz"
  N=0
  TOP=''
  for f in "$TMP"/*; do
    N=$(( N + 1 ))
    TOP="$f"
  done
  # BIN_DIR must NOT exist here: `mv dir existing-dir` would nest the tree
  # and leave bin/nvim one level too deep.
  rm -rf "$BIN_DIR"
  mkdir -p "$(dirname "$BIN_DIR")"
  if [ "$N" -eq 1 ] && [ -d "$TOP" ]; then
    mv "$TOP" "$BIN_DIR"
    rm -rf "$TMP"
  else
    mv "$TMP" "$BIN_DIR"
  fi
  if [ ! -x "$BIN_DIR/bin/nvim" ]; then
    printf 'SSHDEV:ERROR=bad-archive\n'
    rm -rf "$BIN_DIR"
    exit 0
  fi
  printf 'SSHDEV:BIN=%s\n' "$BIN_DIR/bin/nvim"
fi
printf 'SSHDEV:BINVERSION=%s\n' "$("$BIN_DIR/bin/nvim" -v | head -n 1)"

# --- server status (recovers a lost pid file) ----------------------------
if P=$(FIND_RUNNING); then
  printf '%s\n' "$P" > "$PID_FILE"
  printf 'SSHDEV:SERVER=running\n'
  printf 'SSHDEV:PID=%s\n' "$P"
  if [ -f "$PROFILE/server.addr" ]; then
    printf 'SSHDEV:ADDR=%s\n' "$(cat "$PROFILE/server.addr")"
  fi
else
  printf 'SSHDEV:SERVER=stopped\n'
fi

# --- last config sync fingerprint ---------------------------------------
if [ -f "$PROFILE/.synced" ]; then
  printf 'SSHDEV:SYNCED=%s\n' "$(cat "$PROFILE/.synced")"
fi
]==]

local PREPARE_WS_SCRIPT = [[
set -eu
PROFILE='{{PROFILE}}'
WORKSPACE='{{WORKSPACE}}'
mkdir -p "$PROFILE"
# the designated remote workspace (project dir) may not exist yet
mkdir -p "$WORKSPACE"
rm -rf "$PROFILE/nvim-config"
printf 'SSHDEV:PROFILE=%s\n' "$PROFILE"
]]

-- Marks a successful sync with the local config fingerprint.
local MARK_SYNC_SCRIPT = [[
set -eu
PROFILE='{{PROFILE}}'
printf '%s\n' '{{FINGERPRINT}}' > "$PROFILE/.synced"
printf 'SSHDEV:SYNCED=%s\n' '{{FINGERPRINT}}'
]]

local INSTALL_SCRIPT = [[
set -eu
PROFILE='{{PROFILE}}'
WORKSPACE='{{WORKSPACE}}'
BIN='{{BIN}}'
cd "$WORKSPACE" || { printf 'SSHDEV:ERROR=workspace\n'; exit 1; }
export XDG_CONFIG_HOME='{{PROFILE}}'
export XDG_DATA_HOME='{{PROFILE}}/data'
export XDG_STATE_HOME='{{PROFILE}}/state'
export XDG_CACHE_HOME='{{PROFILE}}/cache'
export NVIM_APPNAME=nvim-config
export SSHDEV_REMOTE=1
export SSHDEV_PROFILE='{{PROFILE}}'
printf 'SSHDEV:PHASE=install\n'
"$BIN" --headless{{INSTALL_CMDS}} +qa!
printf 'SSHDEV:INSTALL=ok\n'
]]

local START_SCRIPT = [==[
set -eu
PROFILE='{{PROFILE}}'
WORKSPACE='{{WORKSPACE}}'
BIN='{{BIN}}'
RPORT='{{RPORT}}'
SESSION='{{SESSION}}'
RESTORE='{{RESTORE}}'
PID_FILE="$PROFILE/server.pid"
LOG="$PROFILE/server.log"

{{FIND_RUNNING}}

# Already running (even if the pid file was lost): adopt it instead of
# starting a second server on the same deterministic port.
if P=$(FIND_RUNNING); then
  printf '%s\n' "$P" > "$PID_FILE"
  printf '127.0.0.1:%s\n' "$RPORT" > "$PROFILE/server.addr"
  printf 'SSHDEV:SERVER=running\n'
  printf 'SSHDEV:PID=%s\n' "$P"
  printf 'SSHDEV:ADDR=127.0.0.1:%s\n' "$RPORT"
  exit 0
fi
rm -f "$PID_FILE" "$PROFILE/server.addr"

cd "$WORKSPACE" || { printf 'SSHDEV:ERROR=workspace\n'; exit 1; }

export XDG_CONFIG_HOME="$PROFILE"
export XDG_DATA_HOME="$PROFILE/data"
export XDG_STATE_HOME="$PROFILE/state"
export XDG_CACHE_HOME="$PROFILE/cache"
export NVIM_APPNAME=nvim-config
export SSHDEV_REMOTE=1
export SSHDEV_PROFILE="$PROFILE"
export SSHDEV_SESSION="$SESSION"
export SSHDEV_RESTORE="$RESTORE"

nohup "$BIN" --headless --listen 127.0.0.1:"$RPORT" \
  -c 'luafile {{SHIM}}' </dev/null >"$LOG" 2>&1 &
PID=$!

# Wait for the port to accept connections: reporting success merely because
# the process exists would hide a bind failure.
i=0
LISTEN=''
while [ "$i" -lt 25 ]; do
  if ! kill -0 "$PID" 2>/dev/null; then
    break
  fi
  if PORT_LISTENING "$RPORT"; then
    LISTEN='yes'
    break
  fi
  sleep 0.2
  i=$(( i + 1 ))
done

if ! kill -0 "$PID" 2>/dev/null; then
  printf 'SSHDEV:SERVER=dead\n'
  cat "$LOG" 2>/dev/null || true
  rm -f "$PID_FILE" "$PROFILE/server.addr"
  exit 1
fi
if [ "$LISTEN" != 'yes' ]; then
  # Neither ss nor netstat available: give nvim a moment and re-check.
  sleep 1
  if ! kill -0 "$PID" 2>/dev/null; then
    printf 'SSHDEV:SERVER=dead\n'
    cat "$LOG" 2>/dev/null || true
    rm -f "$PID_FILE" "$PROFILE/server.addr"
    exit 1
  fi
fi

printf '%s\n' "$PID" >"$PID_FILE"
printf '127.0.0.1:%s\n' "$RPORT" >"$PROFILE/server.addr"
printf 'SSHDEV:SERVER=started\n'
printf 'SSHDEV:PID=%s\n' "$PID"
printf 'SSHDEV:ADDR=127.0.0.1:%s\n' "$RPORT"
]==]

local STATUS_SCRIPT = [==[
set -eu
PROFILE='{{PROFILE}}'
PID_FILE="$PROFILE/server.pid"

{{FIND_RUNNING}}

if P=$(FIND_RUNNING); then
  printf '%s\n' "$P" > "$PID_FILE"
  printf 'SSHDEV:SERVER=running\n'
  printf 'SSHDEV:PID=%s\n' "$P"
else
  printf 'SSHDEV:SERVER=stopped\n'
fi
if [ -f "$PROFILE/server.addr" ]; then
  printf 'SSHDEV:ADDR=%s\n' "$(cat "$PROFILE/server.addr")"
fi
if [ -f "$PROFILE/session.vim" ]; then
  printf 'SSHDEV:SESSION=yes\n'
fi
]==]

local STOP_SCRIPT = [==[
set -eu
PROFILE='{{PROFILE}}'
PID_FILE="$PROFILE/server.pid"

{{FIND_RUNNING}}

if P=$(FIND_RUNNING); then
  PID="$P"
  # SIGTERM lets nvim run VimLeavePre, which saves session.vim
  kill "$PID" 2>/dev/null || true
  i=0
  while [ "$i" -lt 20 ]; do
    if ! kill -0 "$PID" 2>/dev/null; then
      break
    fi
    sleep 0.5
    i=$(( i + 1 ))
  done
  if kill -0 "$PID" 2>/dev/null; then
    kill -9 "$PID" 2>/dev/null || true
  fi
  printf 'SSHDEV:KILLED=%s\n' "$PID"
fi
rm -f "$PID_FILE" "$PROFILE/server.addr"
printf 'SSHDEV:SERVER=stopped\n'
]==]

-- Exposed for tests: every remote script template.
M._find_running_sh = FIND_RUNNING_SH
M._script_templates = {
  probe = PROBE_SCRIPT,
  ensure = ENSURE_SCRIPT,
  prepare = PREPARE_WS_SCRIPT,
  mark_sync = MARK_SYNC_SCRIPT,
  install = INSTALL_SCRIPT,
  start = START_SCRIPT,
  status = STATUS_SCRIPT,
  stop = STOP_SCRIPT,
}

------------------------------------------------------------------------
-- Platform helpers
------------------------------------------------------------------------

---Neovim release asset for a remote platform (mirrors the shell logic).
---@param sys string
---@param machine string
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
    return 'nightly', true, ('local nvim %s is a dev build; installing "nightly" remotely '
      .. '(pin cfg.nvim_version to control this)'):format(tag)
  end
  return tag, false, nil
end

------------------------------------------------------------------------
-- Probe / profile context
------------------------------------------------------------------------

---Probe the remote host. Must run in a flow.
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
  }
end

---Build the profile context: remote profile dir keyed by the LOCAL hostname
---and the remote workspace (project) path.
---
---Layout under profile_dir: nvim-config/ data/ state/ cache/ session.vim ...
---@param cfg table
---@param parsed table
---@param probe table
---@param workspace_arg string|nil remote project dir from the command line
---@return table? ctx
---@return string? err
function M.profile_ctx(cfg, parsed, probe, workspace_arg)
  local root = Util.remote_root_abs(cfg, probe.home)
  local workspace = workspace_arg or cfg.workspace or probe.home
  workspace = Util.expand_remote_home(workspace, probe.home)
  if workspace:sub(1, 1) ~= '/' then
    return nil, ('workspace %q must be an absolute remote path or "~/..."'):format(workspace)
  end
  workspace = workspace:gsub('/+$', '')
  if workspace == '' then
    workspace = '/'
  end

  local key
  if cfg.profile then
    key = Util.sanitize_segment(cfg.profile, 100)
  else
    key = Util.profile_key(Util.os_hostname(), workspace)
  end

  local profile = Util.join_remote(root, key)
  return {
    dest = parsed.dest,
    port = parsed.port,
    home = probe.home,
    sys = probe.sys,
    machine = probe.machine,
    root = root,
    key = key,
    profile = profile,
    workspace = workspace,
  }
end

------------------------------------------------------------------------
-- Steps (run inside a flow coroutine)
------------------------------------------------------------------------

---Ensure the nvim binary, and report server status + last sync fingerprint.
---Returns (info, err) where info = { bin, version_line, server, pid, addr, synced }.
---@param cfg table
---@param parsed table
---@param ctx table
---@return table? info
---@return string? err
function M.ensure(cfg, parsed, ctx)
  local script = Util.render(ENSURE_SCRIPT, {
    ROOT = Util.shsafe(ctx.root, 'remote root'),
    VERSION = Util.shsafe(ctx.version, 'nvim version'),
    MIRROR = Util.shsafe(cfg.download_mirror, 'download mirror'),
    PROXY = cfg.proxy and Util.shsafe(cfg.proxy, 'proxy') or '',
    PROFILE = Util.shsafe(ctx.profile, 'profile dir'),
    SYS = Util.shsafe(ctx.sys, 'remote sys'),
    MACHINE = Util.shsafe(ctx.machine, 'remote machine'),
    FIND_RUNNING = FIND_RUNNING_SH,
  })

  local res = Ssh.run_script(cfg, parsed, script, {
    timeout = cfg.timeouts.download,
    label = 'ssh',
  })
  local kv = Util.parse_keyvals(res.stdout)

  if kv.ERROR == 'unsupported-platform' then
    return nil, ('the remote platform (%s %s) has no official nvim release; '
      .. 'install Neovim >= 0.11 there manually'):format(ctx.sys, ctx.machine)
  end
  if kv.ERROR == 'curl-missing' or kv.ERROR == 'tar-missing' then
    return nil, ('the remote host has no %s; cannot download nvim'):format(
      kv.ERROR:gsub('%-missing', '')
    )
  end
  if kv.ERROR == 'bad-archive' then
    return nil, ('the downloaded archive for %s did not contain bin/nvim '
      .. '(check download_mirror: %s)'):format(ctx.version, cfg.download_mirror)
  end
  if res.code ~= 0 or not kv.BIN then
    return nil, ('preparing nvim %s on the remote failed (exit %s):\n%s'):format(
      ctx.version,
      res.code,
      Util.tail(res.stderr .. res.stdout, 10)
    )
  end

  ctx.bin = kv.BIN
  ctx.asset = kv.ASSET
  return {
    bin = kv.BIN,
    version_line = kv.BINVERSION or '?',
    server = kv.SERVER,
    pid = kv.PID,
    addr = kv.ADDR,
    synced = kv.SYNCED,
  }
end

---Upload the remote session helper (scripts/remote_session.lua).
function M.upload_session_helper(cfg, parsed, ctx)
  local root = Util.plugin_root()
  if not root then
    return nil, 'cannot locate the sshdev.nvim plugin directory'
  end
  local target = Util.join_remote(ctx.profile, 'session.lua')
  local res = Ssh.upload_file(cfg, parsed, Util.fs_join(root, 'scripts'), 'remote_session.lua', target, cfg.timeouts.ssh)
  if res.code ~= 0 then
    return nil, ('uploading the remote session helper failed (exit %s):\n%s'):format(
      res.code,
      Util.tail(res.stderr, 10)
    )
  end
  return true
end

---scp the local config into <profile>/nvim-config.
function M.upload_config(cfg, parsed, ctx)
  local prep = Util.render(PREPARE_WS_SCRIPT, {
    PROFILE = Util.shsafe(ctx.profile, 'profile dir'),
    WORKSPACE = Util.shsafe(ctx.workspace, 'workspace'),
  })
  local res = Ssh.run_script(cfg, parsed, prep, { timeout = cfg.timeouts.ssh, label = 'ssh' })
  if res.code ~= 0 then
    return nil, ('preparing %s failed (exit %s):\n%s'):format(
      ctx.profile,
      res.code,
      Util.tail(res.stderr, 10)
    )
  end

  local parent, derr = Util.stage_config(cfg)
  if not parent then
    return nil, ('staging your config failed: %s'):format(tostring(derr))
  end
  local up = Ssh.upload_dir(cfg, parsed, parent, 'nvim-config', ctx.profile, cfg.timeouts.ssh)
  if up.code ~= 0 then
    return nil, ('scp of your config failed (exit %s):\n%s'):format(up.code, Util.tail(up.stderr, 10))
  end
  return true
end

---Run the remote nvim headless so plugins declared in the config install.
function M.install_plugins(cfg, parsed, ctx)
  local extra = ''
  for _, c in ipairs(cfg.install_commands or {}) do
    extra = extra .. ' -c ' .. Util.shquote(c)
  end
  local script = Util.render(INSTALL_SCRIPT, {
    PROFILE = Util.shsafe(ctx.profile, 'profile dir'),
    WORKSPACE = Util.shsafe(ctx.workspace, 'workspace'),
    BIN = Util.shsafe(ctx.bin, 'remote nvim binary'),
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
    return nil, ('remote plugin install failed (exit %s) — see :SSHdevLog'):format(res.code)
  end
  return true
end

---Record the config fingerprint that is now live on the remote.
function M.mark_synced(cfg, parsed, ctx, fingerprint)
  local script = Util.render(MARK_SYNC_SCRIPT, {
    PROFILE = Util.shsafe(ctx.profile, 'profile dir'),
    FINGERPRINT = Util.shsafe(fingerprint, 'fingerprint'),
  })
  local res = Ssh.run_script(cfg, parsed, script, { timeout = cfg.timeouts.ssh, label = 'ssh' })
  if res.code ~= 0 then
    Util.log('could not record the sync fingerprint (exit %s)', res.code)
  end
end

---Start the detached remote server. Returns (server, err).
---@param cfg table
---@param parsed table
---@param ctx table needs: profile, workspace, bin
---@param rport integer
---@param restore boolean restore session.vim on start
---@return table? server { running, addr, pid, fresh }
---@return string? err
function M.start_server(cfg, parsed, ctx, rport, restore)
  local session_file = Util.join_remote(ctx.profile, 'session.vim')
  local script = Util.render(START_SCRIPT, {
    PROFILE = Util.shsafe(ctx.profile, 'profile dir'),
    WORKSPACE = Util.shsafe(ctx.workspace, 'workspace'),
    BIN = Util.shsafe(ctx.bin, 'remote nvim binary'),
    RPORT = tostring(rport),
    FIND_RUNNING = FIND_RUNNING_SH,
    SESSION = Util.shsafe(cfg.session and session_file or '', 'session file'),
    RESTORE = (cfg.session and restore ~= false) and '1' or '0',
    SHIM = Util.shsafe(Util.join_remote(ctx.profile, 'session.lua'), 'session helper'),
  })
  local res = Ssh.run_script(cfg, parsed, script, {
    timeout = cfg.timeouts.ssh,
    label = 'ssh',
  })
  if res.code ~= 0 then
    return nil, ('starting the remote server failed (exit %s):\n%s'):format(
      res.code,
      Util.tail(res.stdout .. res.stderr, 15)
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
    return nil, 'the remote nvim server died immediately after start:\n' .. Util.tail(res.stdout, 15)
  end
  return nil, 'unexpected response from the remote start script:\n' .. Util.tail(res.stdout, 15)
end

---Server status: { running, pid, addr, has_session }.
function M.server_status(cfg, parsed, ctx)
  local script = Util.render(STATUS_SCRIPT, {
    PROFILE = Util.shsafe(ctx.profile, 'profile dir'),
    FIND_RUNNING = FIND_RUNNING_SH,
  })
  local res = Ssh.run_script(cfg, parsed, script, { timeout = cfg.timeouts.ssh, label = 'ssh' })
  if res.code ~= 0 then
    return nil, ('checking the remote server failed (exit %s)'):format(res.code)
  end
  local kv = Util.parse_keyvals(res.stdout)
  return {
    running = kv.SERVER == 'running',
    pid = kv.PID,
    addr = kv.ADDR,
    has_session = kv.SESSION == 'yes',
  }
end

---Stop the server (SIGTERM first so nvim can save session.vim).
function M.stop_server(cfg, parsed, ctx)
  local script = Util.render(STOP_SCRIPT, {
    PROFILE = Util.shsafe(ctx.profile, 'profile dir'),
    FIND_RUNNING = FIND_RUNNING_SH,
  })
  local res = Ssh.run_script(cfg, parsed, script, { timeout = cfg.timeouts.ssh, label = 'ssh' })
  if res.code ~= 0 then
    return nil, ('stopping the remote server failed (exit %s)'):format(res.code)
  end
  return true
end

return M
