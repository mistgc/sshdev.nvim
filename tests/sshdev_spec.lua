--- Unit tests for sshdev.nvim pure functions.
---
--- Run:  nvim --headless -l tests/run.lua

local Util = require('sshdev.util')
local Config = require('sshdev.config')

local T = require('tests.harness')
local eq, ok, not_ok = T.eq, T.ok, T.not_ok

------------------------------------------------------------------ util

T.describe('util.join_remote', function()
  eq(Util.join_remote('/home/me', '.sshdev.nvim', 'proj', 'nvim-config'),
    '/home/me/.sshdev.nvim/proj/nvim-config')
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
  -- keys with underscores must match too (regression: %w alone missed them)
  eq(Util.render('{{WS_DIR}}/shim.lua', { WS_DIR = '/home/me' }), '/home/me/shim.lua')
  eq(Util.render('{{INSTALL_CMDS}}', { INSTALL_CMDS = ' -c x' }), ' -c x')
  -- unknown keys stay literal so mistakes are visible
  eq(Util.render('{{A}} {{UNKNOWN}}', { A = 'x' }), 'x {{UNKNOWN}}')
  -- '%' in values must not be interpreted by gsub
  eq(Util.render('{{V}}', { V = 'a%sb%%c' }), 'a%sb%%c')
end)

T.describe('util.parse_keyvals', function()
  local kv = Util.parse_keyvals('noise\nSSHDEV:HOME=/root\nSSHDEV:SYS=Linux x86_64\n')
  eq(kv.HOME, '/root')
  eq(kv.SYS, 'Linux x86_64')
  eq(next(Util.parse_keyvals(nil)), nil)
end)

T.describe('util.parse_dest', function()
  local function t(s, want)
    local p, err = Util.parse_dest(s)
    if want == nil then
      ok(p == nil, ('expected parse failure for %q, got %s'):format(s, vim.inspect(p)))
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
  t('me@host:proj', { user = 'me', host = 'host', path = 'proj' })
  -- failures
  t('a@b@c', nil)
  t('', nil)
end)

T.describe('util.sanitize_ws', function()
  eq(Util.sanitize_ws('proj'), 'proj')
  eq(Util.sanitize_ws('my proj!'), 'my-proj')
  eq(Util.sanitize_ws('..'), 'default')
  eq(Util.sanitize_ws('...'), 'default')
  eq(Util.sanitize_ws('  '), 'default')
  eq(Util.sanitize_ws(nil), 'default')
  eq(Util.sanitize_ws(('x'):rep(100)), ('x'):rep(48))
  -- a name consisting of dots+dashes only must not become "." or ".."
  ok(Util.sanitize_ws('.-.') ~= '.' and Util.sanitize_ws('.-.') ~= '..')
end)

T.describe('util ports: determinism and range', function()
  local p1 = Util.local_port('me@host', 'ws')
  ok(p1 >= 20000 and p1 <= 39999, 'local port in range')
  eq(p1, Util.local_port('me@host', 'ws'), 'deterministic for same inputs')
  not_ok(Util.local_port('me@host', 'ws') == Util.local_port('me@host', 'other'))
  not_ok(Util.remote_port('me@host', 'ws') == Util.local_port('me@host', 'ws'))
end)

T.describe('util glob excludes', function()
  local globs = { '.git', 'lua/private*', '*.secret.lua' }
  ok(Util.excluded('.git/config', globs))
  ok(Util.excluded('.git', globs))
  not_ok(Util.excluded('init.lua', globs))
  ok(Util.excluded('lua/private/init.lua', globs))
  not_ok(Util.excluded('lua/public/init.lua', globs))
  ok(Util.excluded('a.secret.lua', globs))
  not_ok(Util.excluded('secret.lua', globs))
  -- pattern escapes: a glob dot matches a literal dot only
  ok(Util.excluded('init.lua', { 'init.lua' }))
  not_ok(Util.excluded('initXlua', { 'init.lua' }))
end)

T.describe('util versions', function()
  local tag = Util.nvim_version_tag()
  ok(tag:match('^v%d+%.%d+%.%d+$') ~= nil, 'version tag format: ' .. tostring(tag))
  local parsed = Util.parse_nvim_version('NVIM v0.11.3')
  eq(parsed.major, 0)
  eq(parsed.minor, 11)
  eq(parsed.patch, 3)
  eq(Util.parse_nvim_version('garbage'), nil)
  eq(Util.parse_nvim_version(nil), nil)
  ok(Util.nvim_at_least(0, 11), 'test env must run on nvim >= 0.11')
end)

T.describe('util.tail', function()
  eq(Util.tail(nil), '(no output)')
  eq(Util.tail(''), '(no output)')
  eq(Util.tail('a\nb\nc', 2), 'b\nc')
  eq(Util.tail('one', 5), 'one')
end)

--------------------------------------------------------------- config

T.describe('config validation: valid', function()
  local cfg, err = Config.setup({
    host = 'me@host',
    remotes = { work = 'me@work.example.com:2222' },
    proxy = 'http://127.0.0.1:7890',
  })
  eq(err, nil)
  eq(cfg.host, 'me@host')
  eq(cfg.remotes.work, 'me@work.example.com:2222')
  eq(cfg.proxy, 'http://127.0.0.1:7890')
  eq(cfg.nvim_version, 'auto')
  eq(cfg.hijack_quit, true)
  eq(cfg.timeouts.attach, 30)
end)

T.describe('config validation: rejects', function()
  local bad = {
    { { host = 42 }, 'host type' },
    { { host = 'a@b@c' }, 'host with multiple @' },
    { { remotes = { w = 7 } }, 'remote value type' },
    { { remotes = { w = 'a@b@c' } }, 'remote value parse' },
    { { remote_dir = 'rel/path' }, 'remote_dir relative' },
    { { remote_root = 'rel' }, 'remote_root relative' },
    { { proxy = 'http://noslash' }, 'proxy missing port' },
    { { proxy = 42 }, 'proxy type' },
    { { nvim_version = '' }, 'nvim_version empty' },
    { { ssh_args = { '-i', 3 } }, 'ssh_args mixed types' },
    { { ssh_args = { ['-x'] = 'y' } }, 'ssh_args not a list' },
    { { install_commands = { 'ok', 'has\nnewline' } }, 'install_commands newline' },
    { { excludes = { 'ok', 5 } }, 'excludes mixed types' },
    { { timeouts = { ssh = 0 } }, 'zero timeout' },
  }
  for _, case in ipairs(bad) do
    local _, err = Config.setup(case[1])
    ok(err ~= nil, ('expected a validation error for: %s'):format(case[2]))
    if err then
      ok(err:match('^setup: ') ~= nil, 'error is user-facing: ' .. tostring(err))
    end
  end
end)

T.describe('config attach strategy', function()
  for _, v in ipairs({ 'auto', 'terminal', 'connect', 'command' }) do
    local _, err = Config.setup({ attach = v })
    eq(err, nil, ('attach=%s must be accepted'):format(v))
  end
  local _, err = Config.setup({ attach = 'bogus' })
  ok(err ~= nil, 'invalid attach strategy rejected')
  eq(Config.build({}).attach, 'auto')
end)

T.describe('session.ui_kind', function()
  local Session = require('sshdev.session')
  local kind = Session.ui_kind()
  ok(vim.tbl_contains({ 'headless', 'tui', 'external' }, kind), 'ui_kind returns a known kind')
  -- tests run with --headless, so there is no UI
  eq(kind, 'headless')
end)

T.describe('config.get falls back to defaults', function()
  local cfg = Config.get()
  eq(cfg.remote_root, '~/.sshdev.nvim')
  eq(cfg.nvim_version, 'auto')
end)

------------------------------------------------------------- bootstrap

local Bootstrap = require('sshdev.bootstrap')

T.describe('bootstrap.asset_name', function()
  eq(Bootstrap.asset_name('Linux', 'x86_64'), 'nvim-linux-x86_64')
  eq(Bootstrap.asset_name('linux', 'amd64'), 'nvim-linux-x86_64')
  eq(Bootstrap.asset_name('Linux', 'aarch64'), 'nvim-linux-aarch64')
  eq(Bootstrap.asset_name('Darwin', 'arm64'), 'nvim-macos-arm64')
  eq(Bootstrap.asset_name('Darwin', 'x86_64'), 'nvim-macos-x86_64')
  eq(Bootstrap.asset_name('Linux', 'riscv64'), nil)
  eq(Bootstrap.asset_name('Windows', 'x86_64'), nil)
end)

T.describe('bootstrap.resolve_version', function()
  local cfg = Config.build({ nvim_version = 'v0.11.3' })
  eq(Bootstrap.resolve_version(cfg), 'v0.11.3')
  local cfg2 = Config.build({ nvim_version = '0.12.0' })
  eq(Bootstrap.resolve_version(cfg2), 'v0.12.0')
  local cfg3 = Config.build({ nvim_version = 'nightly' })
  eq(Bootstrap.resolve_version(cfg3), 'nightly')
  local cfg4 = Config.build({ nvim_version = 'auto' })
  local tag, dev = Bootstrap.resolve_version(cfg4)
  ok(tag:match('^v%d') or tag == 'nightly', 'auto resolves to a tag or nightly')
  if dev then
    eq(tag, 'nightly', 'dev builds fall back to nightly')
  end
end)

T.describe('bootstrap.resolve_version is pure per-config', function()
  local a = Bootstrap.resolve_version(Config.build({ nvim_version = 'stable' }))
  local b = Bootstrap.resolve_version(Config.build({ nvim_version = 'v0.11.3' }))
  eq(a, 'stable')
  eq(b, 'v0.11.3')
end)

T.describe('bootstrap templates render completely', function()
  -- every {{KEY}} used by the render calls must be provided; render leaves
  -- unknown keys literal, so grep the results for "{{".
  local ws_dir = '/home/me/.sshdev.nvim/proj'
  local ctx = {
    root = '/home/me/.sshdev.nvim',
    ws = 'proj',
    ws_dir = ws_dir,
    cwd = '/home/me/proj',
    version = 'v0.11.3',
    asset = 'nvim-linux-x86_64',
    bin = '/home/me/.sshdev.nvim/_bin/v0.11.3-nvim-linux-x86_64/bin/nvim',
    hijack = true,
  }
  local cfg = Config.build({
    proxy = 'http://127.0.0.1:7890',
    install_commands = { 'Lazy! restore' },
  })

  local ensure = Util.render(Bootstrap._script_templates.ensure, {
    ROOT = ctx.root,
    URL = ('%s/%s/%s.tar.gz'):format(cfg.download_mirror, ctx.version, ctx.asset),
    PROXY = cfg.proxy,
    BIN_DIR = ('%s/_bin/%s-%s'):format(ctx.root, ctx.version, ctx.asset),
  })

  local extra = ''
  for _, c in ipairs(cfg.install_commands) do
    extra = extra .. ' -c ' .. Util.shquote(c)
  end

  local install = Util.render(Bootstrap._script_templates.install, {
    WS_DIR = ws_dir,
    CWD = ctx.cwd,
    BIN = ctx.bin,
    WS = ctx.ws,
    INSTALL_CMDS = extra,
  })

  local start = Util.render(Bootstrap._script_templates.start, {
    WS_DIR = ws_dir,
    CWD = ctx.cwd,
    BIN = ctx.bin,
    WS = ctx.ws,
    RPORT = '21234',
    HIJACK = ctx.hijack and '1' or '0',
    SHIM = ws_dir .. '/shim.lua',
  })

  local rendered = {
    probe = Bootstrap._script_templates.probe,
    ensure = ensure,
    prepare = Util.render(Bootstrap._script_templates.prepare, { WS_DIR = ws_dir, CWD = ctx.cwd }),
    install = install,
    start = start,
    status = Util.render(Bootstrap._script_templates.status, { WS_DIR = ws_dir }),
    stop = Util.render(Bootstrap._script_templates.stop, { WS_DIR = ws_dir }),
  }
  for name, text in pairs(rendered) do
    ok(text:find('{{', 1, true) == nil, ('no placeholder left in "%s" script'):format(name))
  end

  -- spot-check content the flows depend on (plain finds, no patterns)
  ok(ensure:find([[http_proxy="$PROXY"]], 1, true) ~= nil, 'proxy env applied to curl')
  ok(ensure:find("PROXY='http://127.0.0.1:7890'", 1, true) ~= nil, 'proxy value interpolated')
  ok(ensure:find('--silent --show-error', 1, true) ~= nil, 'curl progress suppressed')
  ok(install:find("'Lazy! restore'", 1, true) ~= nil, 'install command quoted')
  ok(install:find('NVIM_APPNAME=nvim-config', 1, true) ~= nil, 'appname isolated')
  ok(start:find('--headless --listen 127.0.0.1:"$RPORT"', 1, true) ~= nil, 'server listens')
  ok(start:find("RPORT='21234'", 1, true) ~= nil, 'listen port parameterized')
  ok(start:find('SSHDEV_REMOTE=1', 1, true) ~= nil, 'server marked as sshdev remote')
  ok(start:find(("luafile %s/shim.lua"):format(ws_dir), 1, true) ~= nil, 'shim loaded by the server')

  -- and the marker protocol end-to-end
  local kv = Util.parse_keyvals('SSHDEV:SERVER=running\nSSHDEV:PID=42\nSSHDEV:ADDR=127.0.0.1:21234\n')
  eq(kv.SERVER, 'running')
  eq(tonumber(kv.ADDR:match(':(%d+)$')), 21234)
end)

return T
