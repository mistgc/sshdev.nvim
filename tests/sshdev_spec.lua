--- Unit tests for sshdev.nvim pure functions.
---
--- Run:  nvim --headless -l tests/run.lua

local Util = require('sshdev.util')
local Config = require('sshdev.config')

local T = require('tests.harness')
local eq, ok, not_ok = T.eq, T.ok, T.not_ok

------------------------------------------------------------------ util

T.describe('util.join_remote', function()
  eq(Util.join_remote('/home/me', '.sshdev.nvim', 'p', 'nvim-config'),
    '/home/me/.sshdev.nvim/p/nvim-config')
  eq(Util.join_remote('~', 'x', '', 'y/'), '~/x/y')
  eq(Util.join_remote('/a/', '/b//', 'c'), '/a/b/c')
end)

T.describe('util.expand_remote_home', function()
  eq(Util.expand_remote_home('~', '/home/me'), '/home/me')
  eq(Util.expand_remote_home('~/proj', '/home/me'), '/home/me/proj')
  eq(Util.expand_remote_home('/abs', '/home/me'), '/abs')
end)

T.describe('util.shquote / shsafe', function()
  eq(Util.shquote('plain'), "'plain'")
  eq(Util.shquote("it's"), [['it'\''s']])
  ok(not pcall(Util.shsafe, "has'quote", 'x'), 'shsafe must reject single quotes')
  ok(not pcall(Util.shsafe, 'line\nbreak', 'x'), 'shsafe must reject newlines')
  eq(Util.shsafe('fine/path', 'p'), 'fine/path')
end)

T.describe('util.render', function()
  eq(Util.render('a {{X}} b {{Y}}', { X = 1, Y = 'two' }), 'a 1 b two')
  -- keys with underscores must match too
  eq(Util.render('{{WS_DIR}}/x', { WS_DIR = '/home/me' }), '/home/me/x')
  eq(Util.render('{{INSTALL_CMDS}}', { INSTALL_CMDS = ' -c x' }), ' -c x')
  eq(Util.render('{{A}} {{UNKNOWN}}', { A = 'x' }), 'x {{UNKNOWN}}')
  eq(Util.render('{{V}}', { V = 'a%sb%%c' }), 'a%sb%%c')
end)

T.describe('util.parse_keyvals', function()
  local kv = Util.parse_keyvals('noise\nSSHDEV:HOME=/root\nSSHDEV:SYS=Linux\n')
  eq(kv.HOME, '/root')
  eq(kv.SYS, 'Linux')
  eq(next(Util.parse_keyvals(nil)), nil)
end)

T.describe('util.parse_dest', function()
  local function t(s, want)
    local p, err = Util.parse_dest(s)
    if want == nil then
      ok(p == nil, ('expected parse failure for %q'):format(s))
      ok(err ~= nil, 'error message expected')
      return
    end
    ok(p ~= nil, ('parse failed for %q: %s'):format(s, tostring(err)))
    if p then
      eq(p.user, want.user, ('user of %q'):format(s))
      eq(p.host, want.host, ('host of %q'):format(s))
      eq(p.port, want.port, ('port of %q'):format(s))
      eq(p.path, want.path, ('path of %q'):format(s))
    end
  end
  t('host', { user = nil, host = 'host' })
  t('me@host', { user = 'me', host = 'host' })
  t('host:2222', { host = 'host', port = 2222 })
  t('me@host:2222', { user = 'me', host = 'host', port = 2222 })
  t('host:~/proj', { host = 'host', path = '~/proj' })
  t('me@host:2222:~/proj', { user = 'me', host = 'host', port = 2222, path = '~/proj' })
  t('a@b@c', nil)
  t('', nil)
end)

T.describe('util.sanitize_segment', function()
  eq(Util.sanitize_segment('proj'), 'proj')
  eq(Util.sanitize_segment('my proj!'), 'my-proj')
  eq(Util.sanitize_segment('..'), 'default')
  eq(Util.sanitize_segment('...'), 'default')
  eq(Util.sanitize_segment('  '), 'default')
  eq(Util.sanitize_segment(nil), 'default')
  ok(Util.sanitize_segment('.-.') ~= '.' and Util.sanitize_segment('.-.') ~= '..')
  local a = Util.sanitize_segment(('x'):rep(200) .. 'a', 40)
  local b = Util.sanitize_segment(('x'):rep(200) .. 'b', 40)
  ok(#a <= 40, 'length respected')
  not_ok(a == b, 'long names do not collide')
end)

T.describe('util.profile_key: --<local-hostname>--<workspace-path>--', function()
  eq(Util.profile_key('laptop', '/home/me/src/app'), '--laptop--home-me-src-app--')
  eq(Util.profile_key('DESKTOP-1', '/home/cjj/proj-sshdev'), '--DESKTOP-1--home-cjj-proj-sshdev--')
  eq(Util.profile_key('h', '/a/b/'), '--h--a-b--')
  eq(Util.profile_key('h', '/'), '--h--default--')
  -- the delimiter makes the two halves unambiguous
  ok(Util.profile_key('h', '/a/b'):find('^%-%-h%-%-') ~= nil, 'leading "--<host>--"')
  ok(Util.profile_key('h', '/a/b'):find('%-%-$') ~= nil, 'trailing "--"')
  not_ok(Util.profile_key('h', '/a/b') == Util.profile_key('h', '/a/bc'))
  not_ok(Util.profile_key('laptop1', '/x') == Util.profile_key('laptop2', '/x'))
end)

T.describe('util.os_hostname', function()
  local h = Util.os_hostname()
  ok(type(h) == 'string' and #h > 0, 'hostname is a non-empty string')
  ok(h:match('^[%w._-]+$') ~= nil, 'hostname is path-safe: ' .. h)
end)

T.describe('util ports: determinism and range', function()
  local p1 = Util.local_port('me@host', 'prof')
  ok(p1 >= 20000 and p1 <= 39999, 'local port in range')
  eq(p1, Util.local_port('me@host', 'prof'), 'deterministic')
  not_ok(Util.local_port('me@host', 'a') == Util.local_port('me@host', 'b'))
  not_ok(Util.remote_port('me@host', 'p') == Util.local_port('me@host', 'p'))
end)

T.describe('util glob excludes', function()
  local globs = { '.git', 'lua/private*', '*.secret.lua' }
  ok(Util.excluded('.git/config', globs))
  not_ok(Util.excluded('init.lua', globs))
  ok(Util.excluded('lua/private/init.lua', globs))
  not_ok(Util.excluded('lua/public/init.lua', globs))
  ok(Util.excluded('a.secret.lua', globs))
  not_ok(Util.excluded('secret.lua', globs))
  ok(Util.excluded('init.lua', { 'init.lua' }))
  not_ok(Util.excluded('initXlua', { 'init.lua' }))
end)

T.describe('util versions', function()
  local tag = Util.nvim_version_tag()
  ok(tag:match('^v%d+%.%d+%.%d+$') ~= nil, 'version tag format: ' .. tostring(tag))
  local parsed = Util.parse_nvim_version('NVIM v0.11.3')
  eq(parsed.minor, 11)
  eq(Util.parse_nvim_version('garbage'), nil)
  ok(Util.nvim_at_least(0, 11), 'test env must run on nvim >= 0.11')
  local v = vim.version()
  if v.build and tostring(v.build):match('^v?%d+%.%d+%.%d+$') and not v.prerelease then
    local _, dev = Util.nvim_version_tag()
    ok(dev == false, 'a release build must not be treated as dev')
  end
end)

T.describe('util.tail', function()
  eq(Util.tail(nil), '(no output)')
  eq(Util.tail('a\nb\nc', 2), 'b\nc')
end)

T.describe('util.config_fingerprint', function()
  local cfg = Config.build({})
  local a = Util.config_fingerprint(cfg)
  eq(a, Util.config_fingerprint(cfg), 'fingerprint is stable')
  ok(a:match('^%x+$') ~= nil, 'fingerprint is hex')
  local c = Util.config_fingerprint(Config.build({ excludes = { '.git', '*.lua' } }))
  not_ok(a == c, 'excludes affect the fingerprint')
end)

--------------------------------------------------------------- config

T.describe('util.format_dest keeps the port', function()
  eq(Util.format_dest({ dest = 'me@host', port = nil }), 'me@host')
  eq(Util.format_dest({ dest = 'me@host', port = 2222 }), 'me@host:2222')
  eq(Util.format_dest({ host = 'host', port = 2200 }), 'host:2200')
  -- a round trip must not lose the port (it would reconnect to port 22)
  local parsed = Util.parse_dest('cjj@cpu0.top:6322')
  eq(Util.format_dest(parsed), 'cjj@cpu0.top:6322')
  local again = Util.parse_dest(Util.format_dest(parsed))
  eq(again.host, 'cpu0.top')
  eq(again.port, 6322)
end)

T.describe('config defaults (new semantics)', function()
  local cfg, err = Config.setup({ host = 'me@host' })
  eq(err, nil)
  eq(cfg.attach, 'auto')
  eq(cfg.session, true)
  eq(cfg.restore_session, true)
  eq(cfg.history, true)
  eq(cfg.history_limit, 50)
  eq(cfg.workspace, nil)
  eq(cfg.profile, nil)
end)

T.describe('config deprecated remote_dir alias', function()
  local cfg = Config.build({ remote_dir = '~/proj' })
  eq(cfg.workspace, '~/proj')
end)

T.describe('config hijack_quit was removed', function()
  -- quit hijacking is gone: session save/restore replaced it
  local cfg = Config.build({ hijack_quit = true })
  eq(cfg.hijack_quit, nil)
  ok(Config.build({}).hijack_quit == nil, 'no hijack_quit option')
end)

T.describe('remote scripts never hijack quit', function()
  local Bootstrap = require('sshdev.bootstrap')
  for name, tpl in pairs(Bootstrap._script_templates) do
    ok(tpl:find('HIJACK', 1, true) == nil, ('%s script has no quit hijack'):format(name))
    ok(tpl:find('cnoreabbrev', 1, true) == nil, ('%s script has no cnoreabbrev'):format(name))
  end
end)

T.describe('config validation: rejects', function()
  local bad = {
    { { host = 42 }, 'host type' },
    { { host = 'a@b@c' }, 'host parse' },
    { { remotes = { w = 7 } }, 'remote value type' },
    { { workspace = 'rel/path' }, 'workspace relative' },
    { { workspace = '' }, 'workspace empty' },
    { { proxy = 'http://noslash' }, 'proxy missing port' },
    { { nvim_version = '' }, 'nvim_version empty' },
    { { ssh_args = { '-i', 3 } }, 'ssh_args mixed' },
    { { install_commands = { 'ok', 'has\nnewline' } }, 'install_commands newline' },
    { { excludes = { 'ok', 5 } }, 'excludes mixed' },
    { { timeouts = { ssh = 0 } }, 'zero timeout' },
    { { attach = 'bogus' }, 'bad attach' },
    { { history_limit = 0 }, 'bad history_limit' },
    { { session = 'yes' }, 'session type' },
  }
  for _, case in ipairs(bad) do
    local _, err = Config.setup(case[1])
    ok(err ~= nil, ('expected a validation error for: %s'):format(case[2]))
    if err then
      ok(err:match('^setup: ') ~= nil, 'error is user-facing')
    end
  end
end)

T.describe('config.get falls back to defaults', function()
  local cfg = Config.get()
  eq(cfg.remote_root, '~/.sshdev.nvim')
  eq(cfg.nvim_version, 'auto')
  eq(cfg.session, true)
end)

------------------------------------------------------------ bootstrap

local Bootstrap = require('sshdev.bootstrap')

T.describe('bootstrap.asset_name', function()
  eq(Bootstrap.asset_name('Linux', 'x86_64'), 'nvim-linux-x86_64')
  eq(Bootstrap.asset_name('Linux', 'aarch64'), 'nvim-linux-aarch64')
  eq(Bootstrap.asset_name('Darwin', 'arm64'), 'nvim-macos-arm64')
  eq(Bootstrap.asset_name('Linux', 'riscv64'), nil)
end)

T.describe('bootstrap.profile_ctx layout', function()
  local cfg = Config.build({})
  local probe = { home = '/home/me', sys = 'Linux', machine = 'x86_64' }
  local ctx, err = Bootstrap.profile_ctx(cfg, { dest = 'me@host' }, probe, '~/src/app')
  eq(err, nil)
  eq(ctx.workspace, '/home/me/src/app')
  eq(ctx.key, Util.profile_key(Util.os_hostname(), '/home/me/src/app'))
  eq(ctx.profile, '/home/me/.sshdev.nvim/' .. ctx.key)
  local ctx2 = Bootstrap.profile_ctx(cfg, { dest = 'me@host' }, probe, nil)
  eq(ctx2.workspace, '/home/me')
  local ctx3, err3 = Bootstrap.profile_ctx(cfg, { dest = 'me@host' }, probe, 'rel/path')
  eq(ctx3, nil)
  ok(err3 ~= nil)
  local ctx4 = Bootstrap.profile_ctx(Config.build({ profile = 'fixed' }), { dest = 'me@host' }, probe, '~/x')
  eq(ctx4.key, 'fixed')
end)

T.describe('bootstrap.resolve_version', function()
  eq(Bootstrap.resolve_version(Config.build({ nvim_version = 'v0.11.3' })), 'v0.11.3')
  eq(Bootstrap.resolve_version(Config.build({ nvim_version = '0.12.0' })), 'v0.12.0')
  eq(Bootstrap.resolve_version(Config.build({ nvim_version = 'nightly' })), 'nightly')
end)

T.describe('bootstrap templates render completely', function()
  local ctx = {
    root = '/home/me/.sshdev.nvim',
    key = 'laptop-home-me-app',
    profile = '/home/me/.sshdev.nvim/laptop-home-me-app',
    workspace = '/home/me/app',
    version = 'v0.12.6',
    bin = '/home/me/.sshdev.nvim/_bin/v0.12.6-nvim-linux-x86_64/bin/nvim',
  }
  local cfg = Config.build({
    proxy = 'http://127.0.0.1:7890',
    install_commands = { 'Lazy! restore' },
  })

  local ensure = Util.render(Bootstrap._script_templates.ensure, {
    ROOT = ctx.root,
    VERSION = ctx.version,
    MIRROR = cfg.download_mirror,
    PROXY = cfg.proxy,
    PROFILE = ctx.profile,
    SYS = 'Linux',
    MACHINE = 'x86_64',
    FIND_RUNNING = Bootstrap._find_running_sh,
  })

  local extra = ''
  for _, c in ipairs(cfg.install_commands) do
    extra = extra .. ' -c ' .. Util.shquote(c)
  end

  local install = Util.render(Bootstrap._script_templates.install, {
    PROFILE = ctx.profile,
    WORKSPACE = ctx.workspace,
    BIN = ctx.bin,
    INSTALL_CMDS = extra,
  })

  local start = Util.render(Bootstrap._script_templates.start, {
    PROFILE = ctx.profile,
    WORKSPACE = ctx.workspace,
    BIN = ctx.bin,
    RPORT = '21234',
    SESSION = ctx.profile .. '/session.vim',
    RESTORE = '1',
    SHIM = ctx.profile .. '/session.lua',
    FIND_RUNNING = Bootstrap._find_running_sh,
  })

  local rendered = {
    probe = Bootstrap._script_templates.probe,
    ensure = ensure,
    prepare = Util.render(Bootstrap._script_templates.prepare, {
      PROFILE = ctx.profile,
      WORKSPACE = ctx.workspace,
    }),
    mark_sync = Util.render(Bootstrap._script_templates.mark_sync, {
      PROFILE = ctx.profile,
      FINGERPRINT = 'deadbeef',
    }),
    install = install,
    start = start,
    status = Util.render(Bootstrap._script_templates.status, {
      PROFILE = ctx.profile,
      FIND_RUNNING = Bootstrap._find_running_sh,
    }),
    stop = Util.render(Bootstrap._script_templates.stop, {
      PROFILE = ctx.profile,
      FIND_RUNNING = Bootstrap._find_running_sh,
    }),
  }
  for name, text in pairs(rendered) do
    ok(text:find('{{', 1, true) == nil, ('no placeholder left in "%s"'):format(name))
  end

  ok(install:find("XDG_CONFIG_HOME='" .. ctx.profile .. "'", 1, true) ~= nil,
    'config under the profile dir')
  ok(install:find("XDG_DATA_HOME='" .. ctx.profile .. "/data'", 1, true) ~= nil,
    'plugins/data under the profile dir')
  ok(install:find('NVIM_APPNAME=nvim-config', 1, true) ~= nil, 'appname nvim-config')
  ok(install:find("'Lazy! restore'", 1, true) ~= nil, 'install command quoted')

  ok(start:find("SESSION='" .. ctx.profile .. "/session.vim'", 1, true) ~= nil,
    'session path set')
  ok(start:find('export SSHDEV_SESSION="$SESSION"', 1, true) ~= nil,
    'session path exported')
  ok(start:find("RESTORE='1'", 1, true) ~= nil, 'restore flag set')
  ok(start:find('export SSHDEV_RESTORE="$RESTORE"', 1, true) ~= nil, 'restore flag exported')
  ok(start:find('--headless --listen 127.0.0.1:"$RPORT"', 1, true) ~= nil, 'server listens')
  ok(start:find('luafile ' .. ctx.profile .. '/session.lua', 1, true) ~= nil,
    'session helper loaded')
  -- no quit hijacking anywhere in the new design
  ok(start:find('HIJACK', 1, true) == nil, 'no hijack env in start script')
  -- a lost pid file must not spawn a second server
  ok(start:find('FIND_RUNNING', 1, true) ~= nil, 'pid file recovery in start script')
  ok(start:find('PORT_LISTENING', 1, true) ~= nil, 'waits for the port to listen')

  ok(ensure:find('BIN_DIR="$ROOT/_bin/$VERSION-$ASSET"', 1, true) ~= nil, 'bin under _bin')
  ok(ensure:find([[http_proxy="$PROXY"]], 1, true) ~= nil, 'proxy applied to curl')
  ok(ensure:find('--silent --show-error', 1, true) ~= nil, 'curl progress suppressed')
  ok(ensure:find('SSHDEV:SYNCED=', 1, true) ~= nil, 'sync fingerprint reported')
  ok(ensure:find('FIND_RUNNING', 1, true) ~= nil, 'pid file recovery in ensure script')

  local kv = Util.parse_keyvals('SSHDEV:SERVER=running\nSSHDEV:PID=42\nSSHDEV:ADDR=127.0.0.1:21234\n')
  eq(kv.SERVER, 'running')
  eq(tonumber(kv.ADDR:match(':(%d+)$')), 21234)
end)

T.describe('session helper (scripts/remote_session.lua)', function()
  local root = Util.plugin_root()
  local f = io.open(root .. '/scripts/remote_session.lua', 'r')
  ok(f ~= nil, 'session helper exists')
  if f then
    local src = f:read('*a')
    f:close()
    ok(src:find('mksession!', 1, true) ~= nil, 'saves the session')
    ok(src:find('source ', 1, true) ~= nil, 'restores the session')
    ok(src:find('VimLeavePre', 1, true) ~= nil, 'saves on exit')
    ok(src:find('SSHDEV_REMOTE', 1, true) ~= nil, 'guarded by env')
    -- session persistence replaced quit hijacking entirely
    ok(src:find('cnoreabbrev', 1, true) == nil, 'no quit hijacking')
    ok(src:find('Detach', 1, true) == nil, 'no detach commands')
    ok(src:find('VimEnter', 1, true) ~= nil, 'restores on startup')
  end
end)

-------------------------------------------------------------- history

local History = require('sshdev.history')

T.describe('history: record / list / remove', function()
  local data = vim.fs.joinpath(vim.fn.stdpath('cache'), 'sshdev-test-data')
  local orig = History.path
  History.path = function()
    return vim.fs.joinpath(data, 'history.json')
  end

  local cfg = Config.build({ history_limit = 3 })
  History.record(cfg, { dest = 'a@h1', workspace = '/w1', profile_key = 'k1' })
  History.record(cfg, { dest = 'b@h2', workspace = '/w2', profile_key = 'k2' })
  local list = History.list()
  eq(#list, 2)
  eq(list[1].dest, 'b@h2', 'newest first')

  History.record(cfg, { dest = 'a@h1', workspace = '/w1', profile_key = 'k1' })
  list = History.list()
  eq(#list, 2)
  eq(list[1].dest, 'a@h1')
  eq(list[1].count, 2)

  History.record(cfg, { dest = 'c@h3', workspace = '/w3', profile_key = 'k3' })
  History.record(cfg, { dest = 'd@h4', workspace = '/w4', profile_key = 'k4' })
  eq(#History.list(), 3, 'history_limit respected')

  History.remove({ dest = 'a@h1', workspace = '/w1' })
  for _, e in ipairs(History.list()) do
    not_ok(e.dest == 'a@h1', 'removed entry is gone')
  end

  ok(History.display({ dest = 'a@h', workspace = '/w', count = 2, last_used = os.time() }):find('a@h') ~= nil)
  eq(History.relative_time(os.time()), 'just now')
  ok(History.relative_time(os.time() - 120):find('2m') ~= nil)

  Util.rmrf(data)
  History.path = orig
end)

----------------------------------------------------------------- misc

T.describe('session.ui_kind', function()
  local Session = require('sshdev.session')
  eq(Session.ui_kind(), 'headless', 'tests run headless')
end)

T.describe('attach strategy matrix', function()
  local Session = require('sshdev.session')
  -- headless can never attach: report the command instead
  eq(Session.attach_strategy('auto', 'headless'), 'command')
  -- explicit settings win
  eq(Session.attach_strategy('terminal', 'headless'), 'terminal')
  eq(Session.attach_strategy('connect', 'external'), 'connect')
  eq(Session.attach_strategy('command', 'tui'), 'command')
  -- with :connect available (Nvim >= 0.12, the test env) both TUI and GUI
  -- attach in place (verified: the builtin TUI is a UI client since 0.12)
  if vim.fn.exists(':connect') == 2 then
    eq(Session.attach_strategy('auto', 'tui'), 'connect')
    eq(Session.attach_strategy('auto', 'external'), 'connect')
  else
    eq(Session.attach_strategy('auto', 'tui'), 'terminal')
  end
end)

T.describe('the :connect address has no scheme (regression)', function()
  -- `:connect tcp://host:port` is invalid: nvim parses a bare "host:port".
  -- Getting this wrong silently detaches the UI and exits the process, which
  -- is exactly what made :connect look unsupported in a TUI.
  local root = Util.plugin_root()
  local f = io.open(root .. '/lua/sshdev/session.lua', 'r')
  ok(f ~= nil)
  if f then
    local src = f:read('*a')
    f:close()
    ok(src:find("('connect %s')", 1, true) ~= nil, 'connect uses a bare host:port')
    ok(src:find("'connect tcp://", 1, true) == nil, 'no tcp:// connect command')
    ok(src:find('"connect tcp://', 1, true) == nil, 'no tcp:// connect command (double quotes)')
    -- and the remote-server address we hand it is host:port
    ok(src:find("('127.0.0.1:%d'):format(lport)", 1, true) ~= nil, 'tunnel address is host:port')
  end
end)

T.describe('picker falls back to vim.ui.select', function()
  local Picker = require('sshdev.picker')
  local History = require('sshdev.history')
  local data = vim.fs.joinpath(vim.fn.stdpath('cache'), 'sshdev-picker-data')
  local orig_path = History.path
  History.path = function()
    return vim.fs.joinpath(data, 'history.json')
  end
  local cfg = Config.build({})
  History.record(cfg, { dest = 'me@host:2222', workspace = '/w1', profile_key = 'k1' })

  -- no telescope in the test env -> the fallback must be used
  local had_telescope = Picker.has_telescope()
  if had_telescope then
    Util.rmrf(data)
    History.path = orig_path
    return
  end

  local picked = nil
  local orig_select = vim.ui.select
  vim.ui.select = function(items, opts, on_choice)
    eq(type(items), 'table')
    ok(#items >= 2, 'history entries + new-connection entry')
    ok(type(opts.format_item), 'function')
    ok(opts.format_item(items[1]):find('me@host:2222') ~= nil, 'entry label shows the destination')
    -- choose the first entry (the remembered connection)
    on_choice(items[1])
  end
  Picker.select(cfg, function(entry)
    picked = entry
  end)
  vim.ui.select = orig_select
  ok(picked ~= nil, 'selection callback fired')
  eq(picked.dest, 'me@host:2222')
  eq(picked.workspace, '/w1')

  Util.rmrf(data)
  History.path = orig_path
end)

return T
