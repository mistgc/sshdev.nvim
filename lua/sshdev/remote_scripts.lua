--- POSIX sh script templates executed ON THE REMOTE HOST.
---
--- Every template is rendered by `sshdev.bootstrap` with `Util.render()` and
--- fed to `ssh host sh -s` on stdin (zero client-side quoting hazards). The
--- scripts report machine-readable `SSHDEV:KEY=VALUE` lines, and the ones
--- that need tabular data (profile listings) use `SSHDEV:WS=` /
--- `SSHDEV:NP=` rows with TAB separators.
---
--- Placeholder convention: every value is embedded by the caller through
--- `Util.shsafe()` (no single quotes / newlines / tabs), which keeps the
--- scripts free of injection while still allowing arbitrary spaces in
--- workspace paths (always referenced as "$VAR", never inlined).
---
--- This module only holds text + pure parsers so tests can render a template,
--- check it with `sh -n` and even execute the parameterized listing scripts
--- against a throwaway directory tree.

local M = {}

local Util = require('sshdev.util')

-----------------------------------------------------------------------
-- Remote environment prologue
-----------------------------------------------------------------------

---POSIX sh fragment that prepends the configured tool directories to PATH.
---
---Why this exists: sshdev starts the remote nvim (and runs every remote
---script) through a NON-interactive, non-login shell (`ssh host sh -s`).
---That shell does not read ~/.bashrc / ~/.profile, so the PATH is the sshd
---default and misses the per-user directories an interactive login gets --
---most visibly ~/.cargo/bin, where `cargo install tree-sitter-cli` lands.
---nvim-treesitter then fails with
---`ENOENT: no such file or directory (cmd): 'tree-sitter'` even though the
---CLI is installed. LSP servers / formatters in ~/.local/bin are hidden by
---the same difference.
---
---Only directories that EXIST are added, an entry already on PATH is left
---alone (no duplicates), and the relative order of the entries is kept.
---Runs before a template's own `set -eu`, so `PATH` may even be unset.
---Entries: "~", "~/..." or absolute paths (Config validates the list).
---@param entries string[]|nil
---@return string fragment ('' when there is nothing to prepend)
function M.path_augment(entries)
  if not entries or #entries == 0 then
    return ''
  end
  local words = {}
  for _, entry in ipairs(entries) do
    if entry == '~' then
      words[#words + 1] = '"$HOME"'
    elseif entry:sub(1, 2) == '~/' then
      words[#words + 1] = '"$HOME"/' .. Util.shquote(entry:sub(3))
    else
      words[#words + 1] = Util.shquote(entry)
    end
  end
  return table.concat({
    '# sshdev: expose login-shell tool dirs to this non-interactive shell',
    "_sshdev_add=''",
    'for _sshdev_dir in ' .. table.concat(words, ' ') .. '; do',
    '  if [ -d "$_sshdev_dir" ]; then',
    '    case ":$PATH:$_sshdev_add" in',
    '      *":$_sshdev_dir:"*) ;;',
    '      *) _sshdev_add="$_sshdev_add$_sshdev_dir:" ;;',
    '    esac',
    '  fi',
    'done',
    'if [ -n "$_sshdev_add" ]; then',
    '  PATH="$_sshdev_add$PATH"',
    'fi',
    'unset _sshdev_dir _sshdev_add',
    'export PATH',
    '',
  }, '\n')
end

-----------------------------------------------------------------------
-- Templates
-----------------------------------------------------------------------

---Remote environment probe.
M.probe = [[
set -eu
printf 'SSHDEV:HOME=%s\n' "$HOME"
printf 'SSHDEV:PATH=%s\n' "$PATH"
printf 'SSHDEV:SYS=%s\n' "$(uname -s 2>/dev/null || echo unknown)"
printf 'SSHDEV:MACHINE=%s\n' "$(uname -m 2>/dev/null || echo unknown)"
command -v curl >/dev/null 2>&1 && printf 'SSHDEV:CURL=yes\n' || printf 'SSHDEV:CURL=no\n'
command -v tar  >/dev/null 2>&1 && printf 'SSHDEV:TAR=yes\n'  || printf 'SSHDEV:TAR=no\n'
printf 'SSHDEV:SH=ok\n'
]]

---Locate the server of the workspace profile even when the pid file was lost
---(crash / concurrent connect): pid file first, then the unique command line
---"<workspace profile>/session.lua".
---Expects $WS_PROFILE and $PID_FILE from the caller.
M.find_running = [[
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
    P=$(pgrep -f -- "$WS_PROFILE/session.lua" 2>/dev/null | head -n 1 || true)
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

---Ensure the versioned nvim binary, then report (read-only!) the state of
---both profiles plus the running server. Never creates a profile directory:
---the client decides which nvim profile to use only after seeing the report
---(an explicit --nvim-profile may point at a profile that does not exist).
M.ensure = [==[
set -eu
ROOT='{{ROOT}}'
VERSION='{{VERSION}}'
MIRROR='{{MIRROR}}'
PROXY='{{PROXY}}'
NP='{{NP}}'
AUTO_NP='{{AUTO_NP}}'
WS_PROFILE='{{WS_PROFILE}}'
PLATFORM='{{PLATFORM}}'
PID_FILE="$WS_PROFILE/server.pid"

{{FIND_RUNNING}}

# --- resolve release asset ----------------------------------------------
LOWER_SYS=$(printf '%s' '{{SYS}}' | tr '[:upper:]' '[:lower:]')
LOWER_MACHINE=$(printf '%s' '{{MACHINE}}' | tr '[:upper:]' '[:lower:]')
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

BIN_DIR="$ROOT/nvim-bins/$VERSION"
PLATFORM_FILE="$BIN_DIR/.platform"
printf 'SSHDEV:ASSET=%s\n' "$ASSET"
printf 'SSHDEV:BIN_DIR=%s\n' "$BIN_DIR"
printf 'SSHDEV:PLATFORM=%s\n' "$PLATFORM"

# --- ensure the binary ---------------------------------------------------
BIN_OK='no'
if [ -x "$BIN_DIR/bin/nvim" ] && [ -f "$PLATFORM_FILE" ]; then
  if [ "$(cat "$PLATFORM_FILE" 2>/dev/null || true)" = "$PLATFORM" ]; then
    BIN_OK='yes'
  fi
fi
if [ "$BIN_OK" = 'no' ]; then
  # one-time upgrade path: the old layout kept "<root>/_bin/<version>-<asset>"
  LEGACY="$ROOT/_bin/$VERSION-$ASSET"
  if [ -x "$LEGACY/bin/nvim" ] && [ ! -e "$BIN_DIR" ]; then
    printf 'SSHDEV:PHASE=migrate-bin\n'
    mkdir -p "$ROOT/nvim-bins"
    mv "$LEGACY" "$BIN_DIR"
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
  fi
  printf '%s\n' "$PLATFORM" > "$PLATFORM_FILE"
fi
printf 'SSHDEV:BIN=%s\n' "$BIN_DIR/bin/nvim"
printf 'SSHDEV:BINVERSION=%s\n' "$("$BIN_DIR/bin/nvim" -v | head -n 1)"

# --- profile readiness (read-only; a missing dir is NOT created) ---------
PROFILE_EXISTS() {
  if [ -d "$1" ]; then printf 'yes'; else printf 'no'; fi
}
READY_HASH() {
  if [ -f "$1/.ready" ]; then cat "$1/.ready" 2>/dev/null || true; fi
}
printf 'SSHDEV:NP_EXISTS=%s\n' "$(PROFILE_EXISTS "$NP")"
printf 'SSHDEV:NP_READY_HASH=%s\n' "$(READY_HASH "$NP")"
printf 'SSHDEV:AUTO_EXISTS=%s\n' "$(PROFILE_EXISTS "$AUTO_NP")"
printf 'SSHDEV:AUTO_READY_HASH=%s\n' "$(READY_HASH "$AUTO_NP")"

# --- server status -------------------------------------------------------
if P=$(FIND_RUNNING); then
  # the profile dir may have been deleted manually while the server runs
  printf '%s\n' "$P" > "$PID_FILE" 2>/dev/null || true
  printf 'SSHDEV:SERVER=running\n'
  printf 'SSHDEV:PID=%s\n' "$P"
  if [ -f "$WS_PROFILE/server.addr" ]; then
    printf 'SSHDEV:ADDR=%s\n' "$(cat "$WS_PROFILE/server.addr")"
  fi
else
  printf 'SSHDEV:SERVER=stopped\n'
fi
if [ -f "$WS_PROFILE/session.vim" ]; then
  printf 'SSHDEV:SESSION=yes\n'
fi

# best effort recency marker for the workspace picker
if [ -d "$WS_PROFILE" ]; then
  printf '%s\n' "$(date +%s 2>/dev/null || echo 0)" > "$WS_PROFILE/last_used" 2>/dev/null || true
fi
]==]

---Create/refresh the profile directories, links and metadata files.
---Separate from `ensure` because the client may switch to the auto profile
---when an explicitly requested one does not exist.
---
---OWN=1 : the client owns the nvim profile (auto-derived key): create it and
---        (re)write its bin link + version/host metadata.
---OWN=0 : the profile is being REUSED as-is (explicit --nvim-profile); never
---        touch its bin link or metadata, only relink the workspace profile.
---STAGING empty: no config upload follows, so no staging dir is created.
M.prepare = [[
set -eu
ROOT='{{ROOT}}'
NP='{{NP}}'
NP_KEY='{{NP_KEY}}'
WS_PROFILE='{{WS_PROFILE}}'
WS_KEY='{{WS_KEY}}'
WORKSPACE='{{WORKSPACE}}'
STAGING='{{STAGING}}'
VERSION='{{VERSION}}'
HOST='{{HOST}}'
NP_BIN_TARGET='{{NP_BIN_TARGET}}'
NP_LINK_TARGET='{{NP_LINK_TARGET}}'
OWN='{{OWN}}'

case "$NP" in
  "$ROOT"/nvim-profiles/*) ;;
  *) printf 'SSHDEV:ERROR=bad-profile-path\n'; exit 1 ;;
esac
case "$WS_PROFILE" in
  "$ROOT"/workspace-profiles/*) ;;
  *) printf 'SSHDEV:ERROR=bad-workspace-path\n'; exit 1 ;;
esac

mkdir -p "$ROOT/nvim-bins" "$ROOT/nvim-profiles" "$ROOT/workspace-profiles"
mkdir -p "$WS_PROFILE"

if [ "$OWN" = '1' ]; then
  mkdir -p "$NP" "$NP/nvim-config"
  mkdir -p "$NP/xdg/share" "$NP/xdg/state" "$NP/xdg/cache"
  # heal a real directory (from a damaged/old layout) before creating the link
  if [ -e "$NP/nvim-bin" ] && [ ! -L "$NP/nvim-bin" ]; then
    rm -rf "$NP/nvim-bin"
  fi
  ln -sfn "$NP_BIN_TARGET" "$NP/nvim-bin"
  printf '%s\n' "$VERSION" > "$NP/nvim-version"
  printf '%s\n' "$HOST" > "$NP/client-host"
fi

if [ -e "$WS_PROFILE/nvim-profile" ] && [ ! -L "$WS_PROFILE/nvim-profile" ]; then
  rm -rf "$WS_PROFILE/nvim-profile"
fi
ln -sfn "$NP_LINK_TARGET" "$WS_PROFILE/nvim-profile"
printf '%s\n' "$NP_KEY" > "$WS_PROFILE/nvim-profile.txt"
printf '%s\n' "$WORKSPACE" > "$WS_PROFILE/workspace.txt"
printf '%s\n' "$HOST" > "$WS_PROFILE/client-host"

# one-time upgrade path: carry the old per-workspace session over, so the
# first connect after the refactor still restores the user's buffers
OLD="$ROOT/$WS_KEY"
if [ -f "$OLD/session.vim" ] && [ ! -f "$WS_PROFILE/session.vim" ]; then
  cp "$OLD/session.vim" "$WS_PROFILE/session.vim" 2>/dev/null || true
fi

if [ -n "$STAGING" ]; then
  mkdir -p "$STAGING"
fi

if [ ! -x "$NP/nvim-bin/bin/nvim" ]; then
  printf 'SSHDEV:ERROR=bin-link\n'
  exit 1
fi

# drop stale upload staging dirs (best effort; a failed scp can leave them)
if command -v find >/dev/null 2>&1; then
  find "$NP" -maxdepth 1 -name '.staging-*' -mmin +1440 -exec rm -rf {} + 2>/dev/null || true
fi

printf 'SSHDEV:PREPARED=1\n'
]]

---Swap the uploaded config into place and install the plugins ONCE per nvim
---profile. A mkdir lock serializes concurrent bootstraps of the same profile;
---waiters poll for `.ready` and steal the lock only when its owner is dead.
---
---Two integrity guards protect against a silently broken profile:
---  * leftover plugin trees from an interrupted install (network drop, a
---    killed nvim, a timeout) are removed before installing: vim.pack only
---    looks at "directory exists + lockfile entry", so a half-checked-out
---    worktree would otherwise be reused forever and break `require()` at
---    startup;
---  * `nvim --headless` exits 0 even when `init.lua` raises (it only prints
---    E5113), so a config that cannot load would still be marked `.ready`.
---    The install output is scanned and a config error fails the install.
M.commit = [==[
set -eu
ROOT='{{ROOT}}'
NP='{{NP}}'
STAGING='{{STAGING}}'
BIN='{{BIN}}'
HASH='{{HASH}}'
LOCK_WAIT='{{LOCK_WAIT}}'
FORCE='{{FORCE}}'
LOCK="$NP/.bootstrap.lock"

case "$NP" in
  "$ROOT"/nvim-profiles/*) ;;
  *) printf 'SSHDEV:ERROR=bad-profile-path\n'; exit 1 ;;
esac

READY_MATCHES() {
  if [ -f "$NP/.ready" ]; then
    if [ "$(cat "$NP/.ready" 2>/dev/null || true)" = "$HASH" ]; then
      return 0
    fi
  fi
  return 1
}

# Already installed (and not a forced reinstall): nothing to do even when the
# caller already uploaded a (redundant) staging copy.
if [ "$FORCE" != '1' ] && READY_MATCHES; then
  rm -rf "$STAGING"
  printf 'SSHDEV:NP=ready\n'
  exit 0
fi

if [ ! -d "$STAGING/nvim-config" ]; then
  printf 'SSHDEV:ERROR=no-config\n'
  exit 1
fi

LOCK_HELD=''
RELEASE_LOCK() {
  if [ -n "$LOCK_HELD" ]; then
    rm -rf "$LOCK" 2>/dev/null || true
    LOCK_HELD=''
  fi
}
ACQUIRE_LOCK() {
  if mkdir "$LOCK" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK/pid" 2>/dev/null || true
    LOCK_HELD=1
    return 0
  fi
  return 1
}

if ! ACQUIRE_LOCK; then
  WAITED=0
  while [ "$WAITED" -lt "$LOCK_WAIT" ]; do
    if [ "$FORCE" != '1' ] && READY_MATCHES; then
      rm -rf "$STAGING"
      printf 'SSHDEV:NP=ready\n'
      exit 0
    fi
    LOCK_PID=$(cat "$LOCK/pid" 2>/dev/null || true)
    if [ -n "$LOCK_PID" ] && ! kill -0 "$LOCK_PID" 2>/dev/null; then
      # the owner died mid-install: take the lock over
      rm -rf "$LOCK" 2>/dev/null || true
      if ACQUIRE_LOCK; then
        break
      fi
    fi
    sleep 1
    WAITED=$(( WAITED + 1 ))
  done
  if [ -z "$LOCK_HELD" ]; then
    printf 'SSHDEV:ERROR=locked\n'
    exit 0
  fi
fi

trap 'RELEASE_LOCK' EXIT HUP INT TERM

# someone else may have finished while we were waiting for the lock
if [ "$FORCE" != '1' ] && READY_MATCHES; then
  rm -rf "$STAGING"
  printf 'SSHDEV:NP=ready\n'
  exit 0
fi

printf 'SSHDEV:PHASE=install\n'
rm -rf "$NP/nvim-config"
mv "$STAGING/nvim-config" "$NP/nvim-config"
rm -rf "$STAGING"
printf '%s\n' "$HASH" > "$NP/config-hash"

export XDG_CONFIG_HOME="$NP"
export XDG_DATA_HOME="$NP/xdg/share"
export XDG_STATE_HOME="$NP/xdg/state"
export XDG_CACHE_HOME="$NP/xdg/cache"
export NVIM_APPNAME=nvim-config
export SSHDEV_REMOTE=1
export SSHDEV_NVIM_PROFILE="$NP"

# A failed or interrupted previous install can leave a plugin directory whose
# worktree is incomplete (e.g. `git clone --no-checkout` that never got its
# `checkout`, or files removed by a killed process). vim.pack decides
# "installed" from the directory + the lockfile entry only, so it would reuse
# that tree forever and the plugin's `require()` fails at every startup.
# Drop incomplete trees here; the lockfile installs them again below.
PACK_OPT="$NP/xdg/share/nvim-config/site/pack/core/opt"
if [ -d "$PACK_OPT" ] && command -v git >/dev/null 2>&1; then
  for d in "$PACK_OPT"/*; do
    [ -d "$d" ] || continue
    if [ ! -d "$d/.git" ] \
      || git -C "$d" status --porcelain --untracked-files=no 2>/dev/null | grep -q '^ D'; then
      rm -rf "$d"
    fi
  done
fi

INSTALL_LOG="$NP/.install.log"
INSTALL_RC=0
"$BIN" --headless{{INSTALL_CMDS}} +qa! >"$INSTALL_LOG" 2>&1 || INSTALL_RC=$?
if [ "$INSTALL_RC" -ne 0 ]; then
  printf 'SSHDEV:ERROR=install\n'
  tail -n 40 "$INSTALL_LOG" 2>/dev/null || true
  exit 1
fi

# Neovim exits 0 when init.lua raises an error -- the message is only printed.
# Marking `.ready` in that state pins a profile whose config cannot load (a
# missing/broken plugin, e.g. nvim-treesitter) and every later connect starts
# a broken server. Treat any config-load error as a failed install.
CONFIG_ERROR_RE='^Error in .*(init\.vim|init\.lua):|^Error detected while processing|E5113: Lua chunk:'
if grep -qE "$CONFIG_ERROR_RE" "$INSTALL_LOG"; then
  printf 'SSHDEV:ERROR=config\n'
  tail -n 40 "$INSTALL_LOG" 2>/dev/null || true
  exit 1
fi

printf '%s\n' "$HASH" > "$NP/.ready"
printf 'SSHDEV:NP=installed\n'
RELEASE_LOCK
]==]

---Start the detached remote server in the workspace.
M.start = [==[
set -eu
WS_PROFILE='{{WS_PROFILE}}'
NP='{{NP}}'
WORKSPACE='{{WORKSPACE}}'
BIN='{{BIN}}'
RPORT='{{RPORT}}'
SESSION='{{SESSION}}'
RESTORE='{{RESTORE}}'
HELPER='{{HELPER}}'
PID_FILE="$WS_PROFILE/server.pid"
LOG="$WS_PROFILE/server.log"

{{FIND_RUNNING}}

# Already running (even if the pid file was lost): adopt it instead of
# starting a second server on the same deterministic port.
if P=$(FIND_RUNNING); then
  printf '%s\n' "$P" > "$PID_FILE"
  printf '127.0.0.1:%s\n' "$RPORT" > "$WS_PROFILE/server.addr"
  printf 'SSHDEV:SERVER=running\n'
  printf 'SSHDEV:PID=%s\n' "$P"
  printf 'SSHDEV:ADDR=127.0.0.1:%s\n' "$RPORT"
  exit 0
fi
rm -f "$PID_FILE" "$WS_PROFILE/server.addr"

mkdir -p "$WORKSPACE"
cd "$WORKSPACE" || { printf 'SSHDEV:ERROR=workspace\n'; exit 1; }

export XDG_CONFIG_HOME="$NP"
export XDG_DATA_HOME="$NP/xdg/share"
export XDG_STATE_HOME="$NP/xdg/state"
export XDG_CACHE_HOME="$NP/xdg/cache"
export NVIM_APPNAME=nvim-config
export SSHDEV_REMOTE=1
export SSHDEV_NVIM_PROFILE="$NP"
export SSHDEV_WORKSPACE_PROFILE="$WS_PROFILE"
export SSHDEV_SESSION="$SESSION"
export SSHDEV_RESTORE="$RESTORE"
# key manifest of the injected environment: lets a later runtime push unset
# variables removed from env.txt (values are exported by the client's prefix)
export SSHDEV_ENV_KEYS='{{ENV_KEYS}}'

nohup "$BIN" --headless --listen 127.0.0.1:"$RPORT" \
  -c "luafile $HELPER" </dev/null >"$LOG" 2>&1 &
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
  rm -f "$PID_FILE" "$WS_PROFILE/server.addr"
  exit 1
fi
if [ "$LISTEN" != 'yes' ]; then
  # Neither ss nor netstat available: give nvim a moment and re-check.
  sleep 1
  if ! kill -0 "$PID" 2>/dev/null; then
    printf 'SSHDEV:SERVER=dead\n'
    cat "$LOG" 2>/dev/null || true
    rm -f "$PID_FILE" "$WS_PROFILE/server.addr"
    exit 1
  fi
fi

printf '%s\n' "$PID" >"$PID_FILE"
printf '127.0.0.1:%s\n' "$RPORT" > "$WS_PROFILE/server.addr"
printf '%s\n' "$(date +%s 2>/dev/null || echo 0)" > "$WS_PROFILE/last_used" 2>/dev/null || true
printf 'SSHDEV:SERVER=started\n'
printf 'SSHDEV:PID=%s\n' "$PID"
printf 'SSHDEV:ADDR=127.0.0.1:%s\n' "$RPORT"
]==]

---Report server + profile state for :SshDevStatus.
M.status = [==[
set -eu
WS_PROFILE='{{WS_PROFILE}}'
NP='{{NP}}'
PID_FILE="$WS_PROFILE/server.pid"

{{FIND_RUNNING}}

if P=$(FIND_RUNNING); then
  printf '%s\n' "$P" > "$PID_FILE" 2>/dev/null || true
  printf 'SSHDEV:SERVER=running\n'
  printf 'SSHDEV:PID=%s\n' "$P"
else
  printf 'SSHDEV:SERVER=stopped\n'
fi
if [ -f "$WS_PROFILE/server.addr" ]; then
  printf 'SSHDEV:ADDR=%s\n' "$(cat "$WS_PROFILE/server.addr")"
fi
if [ -f "$WS_PROFILE/session.vim" ]; then
  printf 'SSHDEV:SESSION=yes\n'
fi
if [ -d "$NP" ]; then
  printf 'SSHDEV:NP_EXISTS=yes\n'
else
  printf 'SSHDEV:NP_EXISTS=no\n'
fi
if [ -f "$NP/.ready" ]; then
  printf 'SSHDEV:NP_READY_HASH=%s\n' "$(cat "$NP/.ready" 2>/dev/null || true)"
fi
]==]

---Stop the server (SIGTERM first so nvim runs VimLeavePre -> session.vim).
M.stop = [==[
set -eu
WS_PROFILE='{{WS_PROFILE}}'
PID_FILE="$WS_PROFILE/server.pid"

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
rm -f "$PID_FILE" "$WS_PROFILE/server.addr"
printf 'SSHDEV:SERVER=stopped\n'
]==]

---List the workspace profiles owned by THIS client host (user isolation).
---`client-host` must match exactly; old profiles without the metadata file
---fall back to the "--<host>--" key prefix.
M.list_workspace = [[
set -eu
ROOT='{{ROOT}}'
HOST='{{HOST}}'
DIR="$ROOT/workspace-profiles"

if [ ! -d "$DIR" ]; then
  exit 0
fi
for d in "$DIR"/*/; do
  if [ ! -d "$d" ]; then
    continue
  fi
  key=$(basename "$d")
  CH=''
  if [ -f "$d/client-host" ]; then
    CH=$(cat "$d/client-host" 2>/dev/null || true)
  fi
  if [ -n "$CH" ]; then
    if [ "$CH" != "$HOST" ]; then
      continue
    fi
  else
    case "$key" in
      --"$HOST"--*) ;;
      *) continue ;;
    esac
  fi
  WS=''
  if [ -f "$d/workspace.txt" ]; then
    WS=$(cat "$d/workspace.txt" 2>/dev/null || true)
  fi
  if [ -z "$WS" ]; then
    continue
  fi
  NP=''
  if [ -f "$d/nvim-profile.txt" ]; then
    NP=$(cat "$d/nvim-profile.txt" 2>/dev/null || true)
  fi
  LU=''
  if [ -f "$d/last_used" ]; then
    LU=$(cat "$d/last_used" 2>/dev/null || true)
  fi
  SS='no'
  if [ -f "$d/session.vim" ]; then
    SS='yes'
  fi
  printf 'SSHDEV:WS=%s\t%s\t%s\t%s\t%s\n' "$key" "$WS" "$NP" "$LU" "$SS"
done
]]

---List the nvim profiles owned by THIS client host (reuse candidates).
---Also counts how many workspace profiles reference each key.
M.list_nvim = [[
set -eu
ROOT='{{ROOT}}'
HOST='{{HOST}}'
DIR="$ROOT/nvim-profiles"

if [ ! -d "$DIR" ]; then
  exit 0
fi
for d in "$DIR"/*/; do
  if [ ! -d "$d" ]; then
    continue
  fi
  key=$(basename "$d")
  CH=''
  if [ -f "$d/client-host" ]; then
    CH=$(cat "$d/client-host" 2>/dev/null || true)
  fi
  if [ "$CH" != "$HOST" ]; then
    continue
  fi
  VER=''
  if [ -f "$d/nvim-version" ]; then
    VER=$(cat "$d/nvim-version" 2>/dev/null || true)
  fi
  READY=''
  if [ -f "$d/.ready" ]; then
    READY=$(cat "$d/.ready" 2>/dev/null || true)
  fi
  CFG=''
  if [ -f "$d/config-hash" ]; then
    CFG=$(cat "$d/config-hash" 2>/dev/null || true)
  fi
  COUNT=0
  for w in "$ROOT"/workspace-profiles/*/; do
    if [ ! -d "$w" ]; then
      continue
    fi
    if [ ! -f "$w/nvim-profile.txt" ]; then
      continue
    fi
    if [ "$(cat "$w/nvim-profile.txt" 2>/dev/null || true)" = "$key" ]; then
      COUNT=$(( COUNT + 1 ))
    fi
  done
  printf 'SSHDEV:NP=%s\t%s\t%s\t%s\t%s\n' "$key" "$VER" "$READY" "$CFG" "$COUNT"
done
]]

---Read the workspace profile's forward.txt (READ-ONLY) for :SshDevForward.
---
---Reports `SSHDEV:FORWARD=yes|no`, and on "yes" the EXACT file content
---between `SSHDEV:BEGIN-<TOKEN>` / `SSHDEV:END-<TOKEN>` markers (TOKEN is a
---client-generated random token, so content that happens to look like a
---marker cannot confuse the extraction).
---Expects $WS_PROFILE and $TOKEN from the caller.
M.forward_fetch = [[
set -eu
WS_PROFILE='{{WS_PROFILE}}'
TOKEN='{{TOKEN}}'
FWD_FILE="$WS_PROFILE/forward.txt"
if [ -f "$FWD_FILE" ]; then
  printf 'SSHDEV:FORWARD=yes\n'
  printf 'SSHDEV:BEGIN-%s\n' "$TOKEN"
  cat "$FWD_FILE"
  # a file without a trailing newline must not swallow the END marker --
  # and a file WITH one must not gain a blank line per round trip
  # ($(...) strips the newline, so only a real last byte counts)
  if [ -n "$(tail -c 1 "$FWD_FILE" 2>/dev/null || true)" ]; then
    printf '\n'
  fi
  printf 'SSHDEV:END-%s\n' "$TOKEN"
else
  printf 'SSHDEV:FORWARD=no\n'
fi
]]

---Ensure the workspace profile directory exists before forward.txt is
---scp'd into it (:SshDevForward on a workspace that was never connected).
---Guards the path like Scripts.prepare does. Expects $ROOT and $WS_PROFILE.
M.forward_prepare = [[
set -eu
ROOT='{{ROOT}}'
WS_PROFILE='{{WS_PROFILE}}'

case "$WS_PROFILE" in
  "$ROOT"/workspace-profiles/*) ;;
  *) printf 'SSHDEV:ERROR=bad-workspace-path\n'; exit 1 ;;
esac

mkdir -p "$WS_PROFILE"
printf 'SSHDEV:FORWARD_DIR=ok\n'
]]

---Read the workspace profile's env.txt (READ-ONLY) for :SshDevEnv.
---
---Reports `SSHDEV:FILE=yes|no`; on "yes" the EXACT file content is sent
---between `SSHDEV:BEGIN-<TOKEN>` / `SSHDEV:END-<TOKEN>` markers.
---Expects $WS_PROFILE and $TOKEN from the caller.
M.env_fetch = [[
set -eu
WS_PROFILE='{{WS_PROFILE}}'
TOKEN='{{TOKEN}}'
ENV_FILE="$WS_PROFILE/env.txt"
if [ -f "$ENV_FILE" ]; then
  printf 'SSHDEV:FILE=yes\n'
  printf 'SSHDEV:BEGIN-%s\n' "$TOKEN"
  cat "$ENV_FILE"
  # a file without a trailing newline must not swallow the END marker --
  # and a file WITH one must not gain a blank line per round trip
  if [ -n "$(tail -c 1 "$ENV_FILE" 2>/dev/null || true)" ]; then
    printf '\n'
  fi
  printf 'SSHDEV:END-%s\n' "$TOKEN"
else
  printf 'SSHDEV:FILE=no\n'
fi
]]

---Ensure the workspace profile directory exists before env.txt is scp'd
---into it (:SshDevEnv on a workspace that was never connected).
---Guards the path like Scripts.prepare does. Expects $ROOT and $WS_PROFILE.
M.env_prepare = [[
set -eu
ROOT='{{ROOT}}'
WS_PROFILE='{{WS_PROFILE}}'

case "$WS_PROFILE" in
  "$ROOT"/workspace-profiles/*) ;;
  *) printf 'SSHDEV:ERROR=bad-workspace-path\n'; exit 1 ;;
esac

# env.txt may hold secrets: create/lock the profile directory down
umask 077
mkdir -p "$WS_PROFILE"
chmod 700 "$WS_PROFILE" 2>/dev/null || true
printf 'SSHDEV:ENV_DIR=ok\n'
]]

---Force the mode of an uploaded workspace-profile file (env.txt).
---
---scp does NOT carry the intended 0600 across platforms: the local mirror is
---created 0600 through libuv, but on Windows libuv/stat reports 0666 and
---`scp -p` copies that verbatim onto the remote file (the previous, safe mode
---of an existing file is not preserved). env.txt may hold secrets, so the
---mode is asserted explicitly on the remote after the upload instead of
---trusting the client platform's stat()/scp behavior.
---
---Expects $PATH (absolute remote file) and $MODE (a digit mode, e.g. 0600)
---from the caller. A missing target or a bad mode is an error, not a silent
---no-op, so the caller can report it.
M.env_chmod = [[
set -eu
P='{{PATH}}'
MODE='{{MODE}}'

case "$MODE" in
  [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) ;;
  *) printf 'SSHDEV:ERROR=bad-mode\n'; exit 1 ;;
esac

if [ ! -f "$P" ]; then
  printf 'SSHDEV:ERROR=no-file\n'
  exit 1
fi

chmod "$MODE" "$P"
printf 'SSHDEV:CHMOD=ok\n'
]]

---All templates by name, for rendering + tests.
M._templates = {
  probe = M.probe,
  ensure = M.ensure,
  prepare = M.prepare,
  commit = M.commit,
  start = M.start,
  status = M.status,
  stop = M.stop,
  list_workspace = M.list_workspace,
  list_nvim = M.list_nvim,
  forward_fetch = M.forward_fetch,
  forward_prepare = M.forward_prepare,
  env_fetch = M.env_fetch,
  env_prepare = M.env_prepare,
  env_chmod = M.env_chmod,
}

---Shared fragments injected into several templates.
M._fragments = {
  find_running = M.find_running,
}

-----------------------------------------------------------------------
-- Pure parsers for the listing scripts
-----------------------------------------------------------------------

---Parse `SSHDEV:WS=` rows produced by list_workspace.
---@param stdout string|nil
---@return table[] entries { key, workspace, nvim_profile_key, last_used, has_session }
function M.parse_workspace_list(stdout)
  local entries = {}
  for line in tostring(stdout or ''):gmatch('[^\r\n]+') do
    local key, ws, np, lu, ss =
      line:match('^SSHDEV:WS=([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$')
    if key and key ~= '' and ws and ws ~= '' then
      entries[#entries + 1] = {
        key = key,
        workspace = ws,
        nvim_profile_key = (np ~= nil and np ~= '' and np or nil),
        last_used = tonumber(lu),
        has_session = ss == 'yes',
      }
    end
  end
  return entries
end

---Parse `SSHDEV:NP=` rows produced by list_nvim.
---@param stdout string|nil
---@return table[] entries { key, version, ready_hash, config_hash, workspace_count }
function M.parse_nvim_list(stdout)
  local entries = {}
  for line in tostring(stdout or ''):gmatch('[^\r\n]+') do
    local key, ver, ready, cfg, count =
      line:match('^SSHDEV:NP=([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$')
    if key and key ~= '' then
      entries[#entries + 1] = {
        key = key,
        version = (ver ~= nil and ver ~= '' and ver or nil),
        ready_hash = (ready ~= nil and ready ~= '' and ready or nil),
        config_hash = (cfg ~= nil and cfg ~= '' and cfg or nil),
        workspace_count = tonumber(count) or 0,
      }
    end
  end
  return entries
end

return M
