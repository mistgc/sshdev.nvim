--- Unit tests for sshdev.nvim pure functions and remote script templates.
---
--- Run:  nvim --headless -l tests/run.lua
---
--- No network is used: the remote side is represented by rendered POSIX sh
--- text, `sh -n` syntax checks and (when `sh` is available) executed listing
--- scripts against a throwaway fixture tree.

local Util = require('sshdev.util')
local Config = require('sshdev.config')
local Keys = require('sshdev.keys')
local Layout = require('sshdev.layout')
local Scripts = require('sshdev.remote_scripts')
local Bootstrap = require('sshdev.bootstrap')
local Ssh = require('sshdev.ssh')
local Forward = require('sshdev.forward')
local Env = require('sshdev.env')
local History = require('sshdev.history')
local Picker = require('sshdev.picker')
local Session = require('sshdev.session')
local Auth = require('sshdev.auth')

local T = require('tests.harness')
local eq, ok, not_ok = T.eq, T.ok, T.not_ok

local uv = vim.uv or vim.loop
local REPO_ROOT = Util.plugin_root()

---Write a file without platform newline translation (shell scripts!).
local function write_file(path, text)
  Util.mkdir_p(vim.fs.dirname(path))
  local fd = assert(uv.fs_open(path, 'w', 420), 'cannot write ' .. tostring(path))
  uv.fs_write(fd, text, 0)
  uv.fs_close(fd)
end

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
  ok(not pcall(Util.shsafe, 'tab\there', 'x'), 'shsafe must reject tabs')
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

T.describe('util.workspace_profile_key: --<local-hostname>--<workspace-path>--', function()
  eq(Util.workspace_profile_key('laptop', '/home/me/src/app'), '--laptop--home-me-src-app--')
  eq(Util.workspace_profile_key('DESKTOP-1', '/home/cjj/proj-sshdev'), '--DESKTOP-1--home-cjj-proj-sshdev--')
  eq(Util.workspace_profile_key('h', '/a/b/'), '--h--a-b--')
  eq(Util.workspace_profile_key('h', '/'), '--h--default--')
  -- the delimiter makes the two halves unambiguous
  ok(Util.workspace_profile_key('h', '/a/b'):find('^%-%-h%-%-') ~= nil, 'leading "--<host>--"')
  ok(Util.workspace_profile_key('h', '/a/b'):find('%-%-$') ~= nil, 'trailing "--"')
  not_ok(Util.workspace_profile_key('h', '/a/b') == Util.workspace_profile_key('h', '/a/bc'))
  not_ok(Util.workspace_profile_key('laptop1', '/x') == Util.workspace_profile_key('laptop2', '/x'))
  -- deprecated alias still works
  eq(Util.profile_key('h', '/a/b'), Util.workspace_profile_key('h', '/a/b'))
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

T.describe('util.format_dest keeps the port', function()
  eq(Util.format_dest({ dest = 'me@host', port = nil }), 'me@host')
  eq(Util.format_dest({ dest = 'me@host', port = 2222 }), 'me@host:2222')
  eq(Util.format_dest({ host = 'host', port = 2200 }), 'host:2200')
  -- a round trip must not lose the port (it would reconnect to port 22)
  local parsed = Util.parse_dest('cjj@example.com:6322')
  eq(Util.format_dest(parsed), 'cjj@example.com:6322')
  local again = Util.parse_dest(Util.format_dest(parsed))
  eq(again.host, 'example.com')
  eq(again.port, 6322)
end)

T.describe('util.tail', function()
  eq(Util.tail(nil), '(no output)')
  eq(Util.tail('a\nb\nc', 2), 'b\nc')
end)

T.describe('util.merge_env', function()
  eq(Util.merge_env(nil, nil), nil)
  eq(Util.merge_env({}, {}), nil, 'an empty result is nil (jobstart wants nil)')
  eq(Util.merge_env({ A = '1' }, { A = '2', B = '3' }), { A = '2', B = '3' }, 'over wins')
  eq(Util.merge_env({ A = '1' }, nil), { A = '1' })
end)

T.describe('util.extract_marked: token protocol', function()
  local token = 'feedbeef'
  local out = 'SSHDEV:FILE=yes\nSSHDEV:BEGIN-feedbeef\nA=1\n# note\nB=two words\nSSHDEV:END-feedbeef\n'
  eq(Util.extract_marked(out, token), 'A=1\n# note\nB=two words')
  eq(Util.extract_marked(out, 'deadbeef'), nil, 'a different token cannot confuse it')
  eq(Util.extract_marked('SSHDEV:FILE=no\n', token), nil)
  eq(Util.extract_marked(nil, token), nil)
  local crlf = 'SSHDEV:BEGIN-x\nA=1\r\nSSHDEV:END-x\n'
  eq(Util.extract_marked(crlf, 'x'), 'A=1', 'CRLF normalizes to LF')
end)

T.describe('util hash helpers', function()
  eq(Util.hash8('0123456789abcdef'), '01234567')
  eq(Util.hash8('ABC'), nil)
  eq(Util.hash8('ABCDEF0123'), 'abcdef01')
  ok(#Util.sha_hex('x') >= 8, 'sha_hex returns a digest')
  eq(Util.sha_hex('x'), Util.sha_hex('x'), 'deterministic')
  not_ok(Util.sha_hex('x') == Util.sha_hex('y'), 'content sensitive')
end)

T.describe('util.mkdir_p / rmrf', function()
  local dir = vim.fs.joinpath(vim.fn.stdpath('cache'), 'sshdev-test-rmrf')
  Util.rmrf(dir)
  write_file(vim.fs.joinpath(dir, 'a', 'b', 'c.txt'), 'x\n')
  ok(uv.fs_stat(vim.fs.abspath(dir)) ~= nil, 'tree created')
  eq(Util.rmrf(dir), true)
  ok(uv.fs_stat(vim.fs.abspath(dir)) == nil, 'nested tree removed (directories too)')
end)

T.describe('util.stage_config: per-connection staging dirs', function()
  local src = vim.fs.joinpath(vim.fn.stdpath('cache'), 'sshdev-test-cfgsrc')
  Util.rmrf(src)
  write_file(vim.fs.joinpath(src, 'init.lua'), 'x\n')
  write_file(vim.fs.joinpath(src, '.git', 'config'), 'secret\n')
  local cfg = Config.build({ excludes = { '.git' } })
  local p1 = assert(Util.stage_config(cfg, 'aaa', src))
  local p2 = assert(Util.stage_config(cfg, 'bbb', src))
  not_ok(p1 == p2, 'two connections stage into different directories')
  ok(p1:find('stage%-aaa$') ~= nil, 'token used in the stage dir')
  ok(uv.fs_stat(vim.fs.abspath(vim.fs.joinpath(p1, 'nvim-config', 'init.lua'))) ~= nil, 'config staged')
  eq(uv.fs_stat(vim.fs.abspath(vim.fs.joinpath(p1, 'nvim-config', '.git'))), nil, 'excludes respected')
  Util.rmrf(p1)
  Util.rmrf(p2)
  Util.rmrf(src)
end)

T.describe('util.config_content_hash: identity of an nvim profile', function()
  local dir = vim.fs.joinpath(vim.fn.stdpath('cache'), 'sshdev-test-config')
  Util.rmrf(dir)
  write_file(vim.fs.joinpath(dir, 'init.lua'), 'vim.opt.number = true\n')
  write_file(vim.fs.joinpath(dir, 'lua', 'a.lua'), 'return 1\n')
  local cfg = Config.build({})
  local a = Util.config_content_hash(cfg, dir)
  ok(#a == 16 and a:match('^%x+$') ~= nil, 'hash is 16 hex chars: ' .. tostring(a))
  eq(a, Util.config_content_hash(cfg, dir), 'stable')

  -- mtime must NOT matter: otherwise every `touch` would reinstall plugins
  uv.fs_utime(vim.fs.joinpath(dir, 'init.lua'), 1000, 1000)
  eq(a, Util.config_content_hash(cfg, dir), 'mtime insensitive')

  -- content does matter: it is the nvim profile identity
  write_file(vim.fs.joinpath(dir, 'init.lua'), 'vim.opt.number = false\n')
  local b = Util.config_content_hash(cfg, dir)
  not_ok(a == b, 'content sensitive')

  -- excludes participate (the hash describes exactly what is uploaded)
  local c = Util.config_content_hash(Config.build({ excludes = { 'lua/*' } }), dir)
  eq(c, Util.config_content_hash(Config.build({ excludes = { 'lua/*' } }), dir), 'stable with excludes')
  not_ok(c == b, 'excludes change the identity')
  Util.rmrf(dir)
end)

-------------------------------------------------------------- config

T.describe('config defaults (nvim profile + workspace profile)', function()
  local cfg, err = Config.setup({ host = 'me@host' })
  eq(err, nil)
  eq(cfg.attach, 'auto')
  eq(cfg.session, true)
  eq(cfg.restore_session, true)
  eq(cfg.env_on_connect, true)
  eq(cfg.history, true)
  eq(cfg.history_limit, 50)
  eq(cfg.workspace, nil)
  eq(cfg.workspace_profile, nil)
  eq(cfg.nvim_profile, 'auto')
  eq(cfg.timeouts.lock, 120)
end)

T.describe('config deprecated aliases', function()
  eq(Config.build({ remote_dir = '~/proj' }).workspace, '~/proj')
  eq(Config.build({ profile = 'fixed' }).workspace_profile, 'fixed')
  eq(Config.build({ profile = 'fixed' }).profile, nil)
  eq(Config.build({ hijack_quit = true }).hijack_quit, nil)
  eq(Config.build({ force_sync = true }).force_sync, nil)
end)

T.describe('config nvim_profile / workspace_profile', function()
  eq(Config.build({ nvim_profile = 'auto' }).nvim_profile, 'auto')
  local key = '--DESKTOP-1--v0.12.6--1a2b3c4d--'
  eq(Config.build({ nvim_profile = key }).nvim_profile, key)
  eq(Config.build({ workspace_profile = 'fixed' }).workspace_profile, 'fixed')
  for _, bad in ipairs({ 'nope', '--a--/', '--../x--', 42 }) do
    local _, err = Config.setup({ nvim_profile = bad })
    ok(err ~= nil, ('nvim_profile rejects %s'):format(tostring(bad)))
  end
  local _, werr = Config.setup({ workspace_profile = 'a/b' })
  ok(werr ~= nil, 'workspace_profile must be a single segment')
end)

T.describe('config validation: rejects', function()
  local bad = {
    { { host = 42 }, 'host type' },
    { { host = 'a@b@c' }, 'host parse' },
    { { remotes = { w = 7 } }, 'remote value type' },
    { { workspace = 'rel/path' }, 'workspace relative' },
    { { workspace = '' }, 'workspace empty' },
    { { workspace = 'a\tb' }, 'workspace tab' },
    { { proxy = 'http://noslash' }, 'proxy missing port' },
    { { nvim_version = '' }, 'nvim_version empty' },
    { { nvim_version = '../x' }, 'nvim_version traversal' },
    { { ssh_args = { '-i', 3 } }, 'ssh_args mixed' },
    { { install_commands = { 'ok', 'has\nnewline' } }, 'install_commands newline' },
    { { excludes = { 'ok', 5 } }, 'excludes mixed' },
    { { timeouts = { ssh = 0 } }, 'zero timeout' },
    { { timeouts = { lock = 0 } }, 'zero lock timeout' },
    { { attach = 'bogus' }, 'bad attach' },
    { { auth = 'bogus' }, 'bad auth' },
    { { history_limit = 0 }, 'bad history_limit' },
    { { session = 'yes' }, 'session type' },
    { { forward_on_connect = 'yes' }, 'forward_on_connect type' },
    { { env_on_connect = 'yes' }, 'env_on_connect type' },
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
  eq(cfg.forward_on_connect, true)
  eq(cfg.env_on_connect, true)
  eq(cfg.workspace_profile, nil)
end)

---------------------------------------------------------------- auth

T.describe('config.auth', function()
  local cfg, err = Config.build({})
  eq(err, nil, 'default config validates')
  eq(cfg.auth, 'auto', 'auth defaults to "auto"')
  for _, v in ipairs({ 'auto', 'password', 'key' }) do
    local c, e = Config.build({ auth = v })
    eq(e, nil, ('auth=%q validates'):format(v))
    eq(c.auth, v)
  end
end)

T.describe('auth.mode / env matrix: when does the askpass overlay apply', function()
  local parsed = Util.parse_dest('root@10.20.30.40:23')
  local key = Util.format_dest(parsed)
  local auto_cfg = Config.build({})
  local pass_cfg = Config.build({ auth = 'password' })
  local key_cfg = Config.build({ auth = 'key' })

  eq(Auth.mode(auto_cfg), 'auto', 'default mode is auto')
  eq(Auth.mode(pass_cfg), 'password')
  eq(Auth.mode(key_cfg), 'key')
  eq(Auth.mode({}), 'auto', 'missing auth normalizes to auto')

  Auth.forget(key)
  eq(Auth.cached(parsed), nil, 'cache starts empty')
  eq(Auth.env(auto_cfg, parsed), nil, 'auto with nothing cached injects nothing (key/agent first)')
  eq(Auth.env(pass_cfg, parsed, { no_prompt = true }), nil,
    'no_prompt uses the cache only and stays silent')

  Auth._cache_set(key, 'top-secret-pass')
  local env = Auth.env(auto_cfg, parsed, { no_prompt = true })
  ok(type(env) == 'table', 'auto WITH a cached password (after a fallback) uses the overlay')
  if env then
    eq(env.SSHDEV_PASS, 'top-secret-pass', 'the password travels via SSHDEV_PASS')
    eq(env.SSH_ASKPASS_REQUIRE, 'force', 'SSH_ASKPASS_REQUIRE=force')
    ok(type(env.SSH_ASKPASS) == 'string' and #env.SSH_ASKPASS > 0, 'SSH_ASKPASS points at the helper')
    eq(Auth.cached(parsed), 'top-secret-pass', 'cached() reads back the same key')
    local penv = Auth.env(pass_cfg, parsed, { no_prompt = true })
    ok(type(penv) == 'table' and penv.SSHDEV_PASS == 'top-secret-pass',
      'password mode with a cache returns the same overlay')

    -- the helper is a static script: it must exist but hold NO secret
    ok(uv.fs_stat(env.SSH_ASKPASS), 'helper file exists')
    local fd = assert(uv.fs_open(env.SSH_ASKPASS, 'r', 438), 'helper readable')
    local st = uv.fs_fstat(fd)
    local content = uv.fs_read(fd, st.size, 0) or ''
    uv.fs_close(fd)
    ok(content:find('SSHDEV_PASS', 1, true), 'helper prints $SSHDEV_PASS')
    not_ok(content:find('top%-secret%-pass'), 'the password is NOT written into the helper file')
    if vim.fn.has('win32') == 1 then
      ok(content:find('enabledelayedexpansion'), 'Windows helper uses cmd delayed expansion')
      ok(content:find('enabledelayedexpansion\r\necho'), 'every Windows helper line ends in CRLF (regression)')
    else
      eq(vim.fn.executable(env.SSH_ASKPASS), 1, 'unix helper carries the executable bit')
    end

    -- the strict key mode refuses the overlay even with a cache
    eq(Auth.env(key_cfg, parsed, { no_prompt = true }), nil,
      'key mode never injects askpass variables')

    -- forget clears the cache for that destination only
    Auth._cache_set(Util.format_dest(Util.parse_dest('other@host')), 'another')
    Auth.forget(key)
    eq(Auth.cached(parsed), nil, 'forget drops the destination cache')
    eq(Auth.env(auto_cfg, parsed, { no_prompt = true }), nil, 'env is nil after forget')
    Auth.forget(Util.format_dest(Util.parse_dest('other@host')))
  end
end)

T.describe('auth.wants_fallback (auto retry decision)', function()
  local auto_cfg = Config.build({})
  local pass_cfg = Config.build({ auth = 'password' })
  local key_cfg = Config.build({ auth = 'key' })
  local rejected = { code = 255, stderr = 'root@h: Permission denied (publickey,password).' }
  local refused = { code = 255, stderr = 'kex_exchange_identification: Connection closed' }
  ok(Auth.wants_fallback(auto_cfg, rejected), 'auto + auth rejection falls back to a password')
  not_ok(Auth.wants_fallback(pass_cfg, rejected), 'password mode prompts upfront, no probe fallback')
  not_ok(Auth.wants_fallback(key_cfg, rejected), 'key mode never falls back')
  not_ok(Auth.wants_fallback(auto_cfg, refused), 'non-auth failures do not fall back')
  not_ok(Auth.wants_fallback(auto_cfg, nil), 'nil result')
end)

T.describe('auth.needs_batch (strictly non-interactive spawns)', function()
  local parsed = Util.parse_dest('root@10.20.30.40:23')
  local key = Util.format_dest(parsed)
  local auto_cfg = Config.build({})
  local pass_cfg = Config.build({ auth = 'password' })
  local key_cfg = Config.build({ auth = 'key' })

  Auth.forget(key)
  ok(Auth.needs_batch(auto_cfg, parsed), 'auto with nothing cached stays non-interactive (BatchMode)')
  not_ok(Auth.needs_batch(pass_cfg, parsed), 'password mode prompts through env() instead')

  Auth._cache_set(key, 'pw')
  not_ok(Auth.needs_batch(auto_cfg, parsed), 'auto with a cached password drops BatchMode (askpass)')
  not_ok(Auth.needs_batch(pass_cfg, parsed), 'password mode with a cache drops BatchMode')
  ok(Auth.needs_batch(key_cfg, parsed), 'key mode is always non-interactive, even with a cache')

  Auth.forget(key)
end)

T.describe('auth.auth_failure_in / is_auth_failure', function()
  ok(Auth.auth_failure_in('root@h: Permission denied (publickey,password).'), 'connection-level rejection')
  ok(Auth.auth_failure_in('Permission denied (keyboard-interactive).'), 'keyboard-interactive form')
  not_ok(Auth.auth_failure_in('scp: /root/x: Permission denied'), 'a file permission error is not auth')
  not_ok(Auth.auth_failure_in('Connection timed out'), 'timeouts are not auth failures')
  not_ok(Auth.auth_failure_in(''), 'empty output')
  not_ok(Auth.auth_failure_in(nil), 'nil output')
  ok(Auth.is_auth_failure({ code = 255, stderr = 'root@h: Permission denied (publickey).' }),
    'wrong password result detected')
  not_ok(Auth.is_auth_failure({ code = 255, stderr = 'kex_exchange_identification: Connection closed' }),
    'connection errors are not auth failures')
  not_ok(Auth.is_auth_failure(nil), 'nil result')
end)

---------------------------------------------------------------- keys

T.describe('keys: nvim profile key --<host>--<version>--<hash8>--', function()
  eq(Keys.nvim_profile_key('DESKTOP-1', 'v0.12.6', '1a2b3c4d'),
    '--DESKTOP-1--v0.12.6--1a2b3c4d--')
  eq(Keys.nvim_profile_key('laptop', 'nightly', '0123456789abcdef'),
    '--laptop--nightly--01234567--')
  -- the host half is sanitized (dots/underscores are legal path characters),
  -- the version must be path-safe
  eq(Keys.nvim_profile_key('my host.local', 'v0.12.6', 'deadbeef'),
    '--my-host.local--v0.12.6--deadbeef--')
  ok(not pcall(Keys.nvim_profile_key, 'h', 'v1', 'zz'), 'non-hex hash rejected')
  -- the workspace key uses the same "--" segment delimiters
  eq(Keys.workspace_profile_key('laptop', '/home/me/app'), '--laptop--home-me-app--')
end)

T.describe('keys: validation', function()
  ok(Keys.is_valid_version('v0.12.6'))
  ok(Keys.is_valid_version('nightly'))
  ok(Keys.is_valid_version('stable'))
  not_ok(Keys.is_valid_version(''))
  not_ok(Keys.is_valid_version('../x'))
  not_ok(Keys.is_valid_version('a/b'))
  not_ok(Keys.is_valid_version('a\tb'))

  local key = '--DESKTOP-1--v0.12.6--1a2b3c4d--'
  eq(select(1, Keys.validate_nvim_profile_key(key)), true)
  for _, bad in ipairs({ 'nope', '--a--/', '--../x--', '--a b--', '-- ' .. key }) do
    eq(select(1, Keys.validate_nvim_profile_key(bad)), false, ('rejects %q'):format(bad))
  end
end)

-------------------------------------------------------------- layout

T.describe('layout: nvim profile / workspace profile paths', function()
  local l = assert(Layout.build({
    home = '/home/me',
    hostname = 'laptop',
    nvim_version = 'v0.12.6',
    config_hash = '0123456789abcdef',
    workspace = '~/src/app',
    token = 't1',
  }))
  eq(l.root, '/home/me/.sshdev.nvim')
  eq(l.bin_dir, '/home/me/.sshdev.nvim/nvim-bins/v0.12.6')
  eq(l.nvim_profile_key, '--laptop--v0.12.6--01234567--')
  eq(l.nvim_profile, '/home/me/.sshdev.nvim/nvim-profiles/--laptop--v0.12.6--01234567--')
  eq(l.nvim_bin_link, l.nvim_profile .. '/nvim-bin')
  eq(l.nvim_bin_link_target, '../../nvim-bins/v0.12.6')
  eq(l.nvim_config, l.nvim_profile .. '/nvim-config')
  eq(l.xdg_share, l.nvim_profile .. '/xdg/share')
  eq(l.xdg_state, l.nvim_profile .. '/xdg/state')
  eq(l.xdg_cache, l.nvim_profile .. '/xdg/cache')
  -- no separate nvim-data directory in the new layout
  ok(l.nvim_data == nil, 'no nvim-data field')
  eq(l.client_host_file, l.nvim_profile .. '/client-host')
  eq(l.ready_file, l.nvim_profile .. '/.ready')
  eq(l.staging_dir, l.nvim_profile .. '/.staging-t1')

  eq(l.workspace, '/home/me/src/app')
  eq(l.workspace_profile_key, '--laptop--home-me-src-app--')
  eq(l.workspace_profile, '/home/me/.sshdev.nvim/workspace-profiles/--laptop--home-me-src-app--')
  eq(l.nvim_profile_link, l.workspace_profile .. '/nvim-profile')
  eq(l.nvim_profile_link_target, '../../nvim-profiles/--laptop--v0.12.6--01234567--')
  eq(l.workspace_file, l.workspace_profile .. '/workspace.txt')
  eq(l.nvim_profile_key_file, l.workspace_profile .. '/nvim-profile.txt')
  eq(l.ws_client_host_file, l.workspace_profile .. '/client-host')
  eq(l.session_file, l.workspace_profile .. '/session.vim')
  eq(l.helper_file, l.workspace_profile .. '/session.lua')
  eq(l.forward_file, l.workspace_profile .. '/forward.txt')
  eq(l.env_file, l.workspace_profile .. '/env.txt')
  eq(l.last_used_file, l.workspace_profile .. '/last_used')
  eq(l.server_pid, l.workspace_profile .. '/server.pid')

  eq(Layout.bin_path(l), l.nvim_bin_link .. '/bin/nvim')
  eq(Layout.auto_nvim_profile_key(l), l.nvim_profile_key)
end)

T.describe('layout: explicit nvim profile reuse', function()
  local key = '--other-host--v0.11.3--deadbeef--'
  local l = assert(Layout.build({
    home = '/home/me',
    hostname = 'laptop',
    nvim_version = 'v0.12.6',
    config_hash = '0123456789abcdef',
    workspace = '/a',
    nvim_profile_key = key,
  }))
  eq(l.explicit_nvim_profile, true)
  eq(l.nvim_profile_key, key)
  eq(l.nvim_profile, '/home/me/.sshdev.nvim/nvim-profiles/' .. key)
  eq(l.nvim_profile_link_target, '../../nvim-profiles/' .. key)
  -- auto key is still derivable for fallback/reporting
  eq(Layout.auto_nvim_profile_key(l), '--laptop--v0.12.6--01234567--')
end)

T.describe('layout: workspace options and validation', function()
  local base = {
    home = '/home/me',
    hostname = 'laptop',
    nvim_version = 'v0.12.6',
    config_hash = '0123456789abcdef',
    token = 't1',
  }
  -- default workspace = remote $HOME
  eq(assert(Layout.build(base)).workspace, '/home/me')
  -- "~" and trailing slashes normalize
  eq(assert(Layout.build(vim.tbl_extend('force', base, { workspace = '~' }))).workspace, '/home/me')
  eq(assert(Layout.build(vim.tbl_extend('force', base, { workspace = '/srv/app/' }))).workspace, '/srv/app')
  -- custom workspace profile name
  eq(
    assert(Layout.build(vim.tbl_extend('force', base, { workspace_profile_name = 'fixed' }))).workspace_profile_key,
    'fixed'
  )
  -- token is sanitized
  eq(
    assert(Layout.build(vim.tbl_extend('force', base, { token = 'a-b/c d' }))).staging_dir,
    '/home/me/.sshdev.nvim/nvim-profiles/--laptop--v0.12.6--01234567--/.staging-abcd'
  )
  -- invalid inputs
  local function rejects(overrides, why)
    local l, err = Layout.build(vim.tbl_extend('force', base, overrides))
    eq(l, nil, why)
    ok(err ~= nil, why .. ' (error message)')
  end
  rejects({ workspace = 'rel/path' }, 'relative workspace')
  rejects({ workspace = "a'b" }, 'quoted workspace')
  rejects({ workspace = 'a\tb' }, 'tabbed workspace')
  rejects({ nvim_version = '../x' }, 'unsafe version')
  rejects({ nvim_version = 'a/b' }, 'version slash')
  rejects({ config_hash = 'abc' }, 'short config hash')
  rejects({ nvim_profile_key = '--bad--/' }, 'bad explicit key')
  do
    local no_home = vim.deepcopy(base)
    no_home.home = nil
    local l, err = Layout.build(no_home)
    eq(l, nil, 'missing home')
    ok(err ~= nil, 'missing home (error message)')
  end
  -- hostname isolation
  local l1 = assert(Layout.build(base))
  local l2 = assert(Layout.build(vim.tbl_extend('force', base, { hostname = 'other' })))
  not_ok(l1.nvim_profile_key == l2.nvim_profile_key, 'nvim profile is per local hostname')
  not_ok(l1.workspace_profile_key == l2.workspace_profile_key, 'workspace profile is per local hostname')
end)

T.describe('layout: normalize_workspace', function()
  eq(Layout.normalize_workspace('~/proj', '/home/me'), '/home/me/proj')
  eq(Layout.normalize_workspace(nil, '/home/me'), '/home/me')
  eq(Layout.normalize_workspace('/a/b/', '/home/me'), '/a/b')
  eq(Layout.normalize_workspace('rel', '/home/me'), nil)
end)

----------------------------------------------------- remote scripts

---Render every remote script template with a realistic layout.
---@return table<string,string> rendered, table layout
local function render_all()
  local layout = assert(Layout.build({
    home = '/home/me',
    hostname = 'desk-1',
    nvim_version = 'v0.12.6',
    config_hash = '0123456789abcdef',
    workspace = '/home/me/src/app',
    token = 'tok',
  }))
  local auto_np = Util.join_remote(layout.nvim_profiles_root, Layout.auto_nvim_profile_key(layout))
  local vars = {
    ROOT = layout.root,
    VERSION = layout.nvim_version,
    MIRROR = 'https://github.com/neovim/neovim/releases/download',
    PROXY = 'http://127.0.0.1:7890',
    NP = layout.nvim_profile,
    NP_KEY = layout.nvim_profile_key,
    AUTO_NP = auto_np,
    WS_PROFILE = layout.workspace_profile,
    WS_KEY = layout.workspace_profile_key,
    PLATFORM = 'Linux-x86_64',
    SYS = 'Linux',
    MACHINE = 'x86_64',
    WORKSPACE = layout.workspace,
    STAGING = layout.staging_dir,
    HOST = layout.hostname,
    NP_BIN_TARGET = layout.nvim_bin_link_target,
    NP_LINK_TARGET = layout.nvim_profile_link_target,
    OWN = '1',
    BIN = Layout.bin_path(layout),
    HASH = layout.config_hash,
    LOCK_WAIT = '120',
    FORCE = '0',
    INSTALL_CMDS = " -c 'Lazy! restore'",
    RPORT = '23456',
    SESSION = layout.session_file,
    RESTORE = '1',
    HELPER = layout.helper_file,
    ENV_KEYS = 'DATABASE_URL NODE_ENV',
    PATH = layout.env_file,
    MODE = '600',
    FIND_RUNNING = Scripts.find_running,
    TOKEN = 'feedbeef',
  }
  local rendered = {}
  for name, tpl in pairs(Scripts._templates) do
    rendered[name] = Util.render(tpl, vars)
  end
  return rendered, layout
end

T.describe('remote scripts: templates render completely', function()
  local rendered = render_all()
  for name, text in pairs(rendered) do
    ok(text:find('{{', 1, true) == nil, ('no placeholder left in "%s"'):format(name))
    ok(text:find('nvim-data', 1, true) == nil, ('no nvim-data dir in "%s"'):format(name))
    ok(text:find('HIJACK', 1, true) == nil, ('no quit hijack in "%s"'):format(name))
    ok(text:find('cnoreabbrev', 1, true) == nil, ('no cnoreabbrev in "%s"'):format(name))
  end
end)

T.describe('remote scripts: ensure (bin + read-only profile state)', function()
  local rendered, layout = render_all()
  local ensure = rendered.ensure
  ok(ensure:find('BIN_DIR="$ROOT/nvim-bins/$VERSION"', 1, true) ~= nil, 'bins under nvim-bins/<version>')
  ok(ensure:find('PLATFORM_FILE="$BIN_DIR/.platform"', 1, true) ~= nil, 'platform marker')
  ok(ensure:find('LEGACY="$ROOT/_bin/$VERSION-$ASSET"', 1, true) ~= nil, 'legacy <root>/_bin reuse')
  ok(ensure:find('SSHDEV:NP_EXISTS=', 1, true) ~= nil, 'reports explicit profile existence')
  ok(ensure:find('SSHDEV:NP_READY_HASH=', 1, true) ~= nil, 'reports explicit profile readiness')
  ok(ensure:find('SSHDEV:AUTO_READY_HASH=', 1, true) ~= nil, 'reports auto profile readiness')
  ok(ensure:find('SSHDEV:SERVER=', 1, true) ~= nil, 'reports server state')
  ok(ensure:find('FIND_RUNNING', 1, true) ~= nil, 'pid-file recovery')
  ok(ensure:find([[http_proxy="$PROXY"]], 1, true) ~= nil, 'proxy applied to curl')
  ok(ensure:find('--silent --show-error', 1, true) ~= nil, 'curl progress suppressed')
  ok(ensure:find("'" .. layout.nvim_profile .. "'", 1, true) ~= nil, 'explicit profile embedded')
  ok(ensure:find("'" .. layout.workspace_profile .. "'", 1, true) ~= nil, 'workspace profile embedded')
end)

T.describe('remote scripts: prepare (dirs, links, metadata)', function()
  local rendered, layout = render_all()
  local prepare = rendered.prepare
  ok(prepare:find('ln -sfn "$NP_BIN_TARGET" "$NP/nvim-bin"', 1, true) ~= nil, 'bin dir link')
  ok(prepare:find('ln -sfn "$NP_LINK_TARGET" "$WS_PROFILE/nvim-profile"', 1, true) ~= nil,
    'nvim profile dir link')
  ok(prepare:find("NP_BIN_TARGET='" .. layout.nvim_bin_link_target .. "'", 1, true) ~= nil,
    'relative bin link target')
  ok(prepare:find("NP_LINK_TARGET='" .. layout.nvim_profile_link_target .. "'", 1, true) ~= nil,
    'relative profile link target')
  ok(prepare:find('"$NP/xdg/share"', 1, true) ~= nil, 'xdg/share created')
  ok(prepare:find('"$NP/xdg/state"', 1, true) ~= nil, 'xdg/state created')
  ok(prepare:find('"$NP/xdg/cache"', 1, true) ~= nil, 'xdg/cache created')
  ok(prepare:find('workspace.txt', 1, true) ~= nil, 'workspace.txt written')
  ok(prepare:find('nvim-profile.txt', 1, true) ~= nil, 'nvim-profile.txt written')
  ok(prepare:find('client-host', 1, true) ~= nil, 'client-host written (host isolation)')
  ok(prepare:find('OLD="$ROOT/$WS_KEY"', 1, true) ~= nil, 'legacy session carry-over')
  ok(prepare:find('SSHDEV:PREPARED=1', 1, true) ~= nil, 'success marker')

  -- OWN=1 owns the nvim profile; OWN=0 (explicit reuse) must not rewrite its
  -- bin link / metadata, otherwise the reused profile would be mutated.
  ok(prepare:find([[if [ "$OWN" = '1' ]; then]], 1, true) ~= nil, 'ownership guard')
  local reuse = Util.render(Scripts._templates.prepare, {
    ROOT = layout.root,
    NP = layout.nvim_profile,
    NP_KEY = layout.nvim_profile_key,
    WS_PROFILE = layout.workspace_profile,
    WS_KEY = layout.workspace_profile_key,
    WORKSPACE = layout.workspace,
    STAGING = '',
    VERSION = layout.nvim_version,
    HOST = layout.hostname,
    NP_BIN_TARGET = layout.nvim_bin_link_target,
    NP_LINK_TARGET = layout.nvim_profile_link_target,
    OWN = '0',
  })
  ok(reuse:find([[if [ "$OWN" = '1' ]; then]], 1, true) ~= nil, 'reuse keeps the ownership branch')
  ok(reuse:find('if [ -n "$STAGING" ]; then', 1, true) ~= nil, 'staging dir only when uploading')
  ok(reuse:find('SSHDEV:PREPARED=1', 1, true) ~= nil, 'reuse still prepares the workspace profile')
end)

T.describe('remote scripts: commit (lock, staging swap, install)', function()
  local rendered, layout = render_all()
  local commit = rendered.commit
  ok(commit:find('.bootstrap.lock', 1, true) ~= nil, 'mkdir lock')
  ok(commit:find('ACQUIRE_LOCK', 1, true) ~= nil, 'lock acquisition')
  ok(commit:find('LOCK_PID', 1, true) ~= nil, 'stale lock detection')
  ok(commit:find('mv "$STAGING/nvim-config" "$NP/nvim-config"', 1, true) ~= nil, 'atomic config swap')
  ok(commit:find('XDG_CONFIG_HOME="$NP"', 1, true) ~= nil, 'config home = nvim profile')
  ok(commit:find('XDG_DATA_HOME="$NP/xdg/share"', 1, true) ~= nil, 'data home = xdg/share')
  ok(commit:find('XDG_STATE_HOME="$NP/xdg/state"', 1, true) ~= nil, 'state home = xdg/state')
  ok(commit:find('XDG_CACHE_HOME="$NP/xdg/cache"', 1, true) ~= nil, 'cache home = xdg/cache')
  ok(commit:find('NVIM_APPNAME=nvim-config', 1, true) ~= nil, 'appname nvim-config')
  ok(commit:find("--headless -c 'Lazy! restore' +qa!", 1, true) ~= nil, 'install commands quoted')
  ok(commit:find('> "$NP/.ready"', 1, true) ~= nil, 'ready marker written last')
  ok(commit:find('FORCE', 1, true) ~= nil, 'force reinstall supported')
  ok(commit:find("'" .. layout.config_hash .. "'", 1, true) ~= nil, 'config hash embedded')
end)

T.describe('remote scripts: start (server + per-workspace session)', function()
  local rendered, layout = render_all()
  local start = rendered.start
  ok(start:find('--headless --listen 127.0.0.1:"$RPORT"', 1, true) ~= nil, 'server listens')
  ok(start:find('-c "luafile $HELPER"', 1, true) ~= nil, 'session helper loaded')
  ok(start:find("HELPER='" .. layout.helper_file .. "'", 1, true) ~= nil,
    'helper lives in the workspace profile')
  ok(start:find("SESSION='" .. layout.session_file .. "'", 1, true) ~= nil, 'session path set')
  ok(start:find('export SSHDEV_SESSION="$SESSION"', 1, true) ~= nil, 'session path exported')
  ok(start:find("RESTORE='1'", 1, true) ~= nil, 'restore flag set')
  ok(start:find('export SSHDEV_RESTORE="$RESTORE"', 1, true) ~= nil, 'restore flag exported')
  ok(start:find('export SSHDEV_WORKSPACE_PROFILE="$WS_PROFILE"', 1, true) ~= nil,
    'workspace profile exported')
  ok(start:find('export SSHDEV_NVIM_PROFILE="$NP"', 1, true) ~= nil, 'nvim profile exported')
  ok(start:find('mkdir -p "$WORKSPACE"', 1, true) ~= nil, 'workspace created')
  ok(start:find('XDG_DATA_HOME="$NP/xdg/share"', 1, true) ~= nil, 'data home = xdg/share')
  ok(start:find('last_used', 1, true) ~= nil, 'recency marker')
  ok(start:find('_bin', 1, true) == nil, 'no legacy _bin path')
  ok(start:find('PORT_LISTENING', 1, true) ~= nil, 'waits for the port to listen')
  ok(start:find('FIND_RUNNING', 1, true) ~= nil, 'pid file recovery in start script')
end)

T.describe('remote scripts: status/stop use the workspace profile', function()
  local rendered = render_all()
  for _, name in ipairs({ 'status', 'stop' }) do
    local text = rendered[name]
    ok(text:find('WS_PROFILE', 1, true) ~= nil, ('%s references the workspace profile'):format(name))
    ok(text:find('FIND_RUNNING', 1, true) ~= nil, ('%s recovers a lost pid file'):format(name))
  end
  ok(rendered.status:find('SSHDEV:NP_READY_HASH=', 1, true) ~= nil, 'status reports nvim profile')
end)

T.describe('remote scripts: listing scripts filter by client host', function()
  local rendered = render_all()
  ok(rendered.list_workspace:find('client-host', 1, true) ~= nil, 'workspace list uses client-host')
  ok(rendered.list_workspace:find('--"$HOST"--*', 1, true) ~= nil, 'legacy key prefix fallback')
  ok(rendered.list_nvim:find('client-host', 1, true) ~= nil, 'nvim list uses client-host')
  ok(rendered.list_nvim:find('nvim-profile.txt', 1, true) ~= nil, 'counts workspace references')
end)

T.describe('remote scripts: sh -n syntax check', function()
  if vim.fn.executable('sh') ~= 1 then
    print('  SKIP: no POSIX sh in PATH')
    return
  end
  local rendered = render_all()
  local dir = vim.fs.joinpath(vim.fn.stdpath('cache'), 'sshdev-test-sh')
  Util.rmrf(dir)
  for name, text in pairs(rendered) do
    local f = vim.fs.joinpath(dir, name .. '.sh')
    write_file(f, text)
    local res = vim.system({ 'sh', '-n', f }, { text = true }):wait()
    eq(res.code, 0, ('sh -n %s failed: %s'):format(name, tostring(res.stderr)))
  end
  Util.rmrf(dir)
end)

T.describe('remote scripts: listing executes against a fixture tree', function()
  if vim.fn.executable('sh') ~= 1 then
    print('  SKIP: no POSIX sh in PATH')
    return
  end
  local fixture = 'tests/.tmp/fixture'
  Util.rmrf(fixture)
  local root_rel = fixture .. '/root'
  local ws_dir = root_rel .. '/workspace-profiles'
  local np_dir = root_rel .. '/nvim-profiles'
  local function profile(dir, fields)
    Util.mkdir_p(dir)
    if fields.host then
      write_file(dir .. '/client-host', fields.host .. '\n')
    end
    if fields.workspace then
      write_file(dir .. '/workspace.txt', fields.workspace .. '\n')
    end
    if fields.nvim_profile then
      write_file(dir .. '/nvim-profile.txt', fields.nvim_profile .. '\n')
    end
    if fields.last_used then
      write_file(dir .. '/last_used', tostring(fields.last_used) .. '\n')
    end
    if fields.session then
      write_file(dir .. '/session.vim', 'x\n')
    end
  end
  local function nvim_profile(dir, fields)
    Util.mkdir_p(dir)
    if fields.host then
      write_file(dir .. '/client-host', fields.host .. '\n')
    end
    if fields.version then
      write_file(dir .. '/nvim-version', fields.version .. '\n')
    end
    if fields.ready then
      write_file(dir .. '/.ready', fields.ready .. '\n')
    end
    if fields.config_hash then
      write_file(dir .. '/config-hash', fields.config_hash .. '\n')
    end
  end
  local np_key = '--desk-1--v0.12.6--aaaabbbb--'
  profile(ws_dir .. '/--desk-1--home-me-a--', {
    host = 'desk-1', workspace = '/home/me/a', nvim_profile = np_key, last_used = 100, session = true,
  })
  profile(ws_dir .. '/--desk-1--home-me-b--', {
    host = 'desk-1', workspace = '/home/me/b', nvim_profile = np_key, last_used = 200,
  })
  -- another client host: must never leak into this machine's picker
  profile(ws_dir .. '/--desk--home-me-c--', {
    host = 'desk', workspace = '/home/me/c', last_used = 300,
  })
  -- pre-refactor profile without client-host: key prefix fallback
  profile(ws_dir .. '/--desk-1--home-me-legacy--', {
    workspace = '/home/me/legacy', last_used = 50,
  })
  -- managed-looking dir with no metadata: ignored
  profile(ws_dir .. '/--desk-1--home-me-broken--', { host = 'desk-1' })
  Util.mkdir_p(ws_dir .. '/junkdir')
  nvim_profile(np_dir .. '/' .. np_key, {
    host = 'desk-1', version = 'v0.12.6', ready = '0123456789abcdef', config_hash = '0123456789abcdef',
  })
  nvim_profile(np_dir .. '/--desk-1--v0.12.6--eeeeffff--', { host = 'desk-1' })
  nvim_profile(np_dir .. '/--desk--v0.12.6--ccccdddd--', { host = 'desk', version = 'v0.12.6' })

  local dir = vim.fs.joinpath(vim.fn.stdpath('cache'), 'sshdev-test-list')
  Util.rmrf(dir)
  local function run(name, vars)
    local f = vim.fs.abspath(vim.fs.joinpath(dir, name .. '.sh'))
    write_file(f, Util.render(Scripts._templates[name], vars))
    return vim.system({ 'sh', f }, { cwd = REPO_ROOT, text = true }):wait()
  end

  local res = run('list_workspace', { ROOT = root_rel, HOST = 'desk-1' })
  eq(res.code, 0, 'list_workspace exits 0: ' .. tostring(res.stderr))
  local entries = Scripts.parse_workspace_list(res.stdout)
  local by_workspace = {}
  for _, e in ipairs(entries) do
    by_workspace[e.workspace] = e
  end
  eq(#entries, 3, 'three workspaces for desk-1 (other host excluded)')
  ok(by_workspace['/home/me/a'] ~= nil, 'workspace a listed')
  ok(by_workspace['/home/me/legacy'] ~= nil, 'legacy key-prefix fallback listed')
  ok(by_workspace['/home/me/c'] == nil, 'other client host excluded')
  ok(by_workspace['/home/me/broken'] == nil, 'metadata-less dir skipped')
  eq(by_workspace['/home/me/a'].has_session, true, 'session flag parsed')
  eq(by_workspace['/home/me/a'].last_used, 100, 'last_used parsed')
  eq(by_workspace['/home/me/a'].nvim_profile_key, np_key, 'nvim profile key parsed')

  local nres = run('list_nvim', { ROOT = root_rel, HOST = 'desk-1' })
  eq(nres.code, 0, 'list_nvim exits 0: ' .. tostring(nres.stderr))
  local nentries = Scripts.parse_nvim_list(nres.stdout)
  eq(#nentries, 2, 'two nvim profiles for desk-1')
  local by_key = {}
  for _, e in ipairs(nentries) do
    by_key[e.key] = e
  end
  eq(by_key[np_key].version, 'v0.12.6', 'version parsed')
  eq(by_key[np_key].ready_hash, '0123456789abcdef', 'ready hash parsed')
  eq(by_key[np_key].workspace_count, 2, 'workspace reference count')
  ok(by_key['--desk--v0.12.6--ccccdddd--'] == nil, 'other host profile excluded')

  Util.rmrf(fixture)
  Util.rmrf(dir)
end)

T.describe('remote scripts: listing parsers are tolerant', function()
  eq(#Scripts.parse_workspace_list(nil), 0)
  eq(#Scripts.parse_workspace_list('garbage\nSSHDEV:WS=\t\t\t\t\n'), 0)
  eq(#Scripts.parse_nvim_list('garbage'), 0)
  local e = Scripts.parse_workspace_list('SSHDEV:WS=--a--b--\t/w\t--np--\t12\tyes\n')[1]
  eq(e.key, '--a--b--')
  eq(e.workspace, '/w')
  eq(e.nvim_profile_key, '--np--')
  eq(e.last_used, 12)
  eq(e.has_session, true)
end)

----------------------------------------------------------- forward

T.describe('forward.parse: <local-port> = <remote-host>:<remote-port>', function()
  -- the documented example: this client's 3080/8080 -> the server's
  -- 127.0.0.1:3080 / 127.0.0.1:8080
  local specs, errs = Forward.parse('3080 = 127.0.0.1:3080\n8080 = 127.0.0.1:8080\n')
  eq(errs, {})
  eq(specs, {
    { lport = 3080, rhost = '127.0.0.1', rport = 3080 },
    { lport = 8080, rhost = '127.0.0.1', rport = 8080 },
  })

  -- tolerance: leading/trailing whitespace, tabs, CRLF, comments, blanks
  local s2, e2 = Forward.parse(
    '# web dev\r\n\r\n\t3080\t=\t127.0.0.1:3080  \r\n# database\n5432 = db.internal:5432\n'
  )
  eq(e2, {})
  eq(s2, {
    { lport = 3080, rhost = '127.0.0.1', rport = 3080 },
    { lport = 5432, rhost = 'db.internal', rport = 5432 },
  })

  -- every problem is reported with its line, nothing half-applied
  local bad_specs, bad_errs = Forward.parse(
    '3080 = 127.0.0.1\n'
      .. 'abc = 1.2.3.4:80\n'
      .. '99999 = 127.0.0.1:80\n'
      .. '3080 = 127.0.0.1:3080\n'
      .. 'no equals sign\n'
      .. '0 = 127.0.0.1:9\n'
      .. '3080 = no-host-port\n'
  )
  eq(#bad_specs, 1, 'only the valid line becomes a spec')
  eq(#bad_errs, 6, 'all bad lines are reported')
  for i, ln in ipairs({ 1, 2, 3, 5, 6, 7 }) do
    ok(bad_errs[i]:find(('line %d'):format(ln), 1, true) ~= nil, ('error cites line %d'):format(ln))
  end

  -- duplicate local ports point at the first use
  local dup_specs, dup_errs = Forward.parse('3080 = 127.0.0.1:3080\n3080 = 127.0.0.1:80\n')
  eq(#dup_specs, 1)
  eq(#dup_errs, 1)
  ok(dup_errs[1]:find('line 2', 1, true) ~= nil, 'duplicate cites the repeated line')
  ok(dup_errs[1]:find('line 1', 1, true) ~= nil, 'duplicate cites the first use')

  -- a comment-only file (the fresh template) applies nothing
  local none, nerr = Forward.parse('# only comments\n\n# 3080 = 127.0.0.1:3080\n')
  eq(none, {})
  eq(nerr, {})
  local nspecs, nerrs = Forward.parse('')
  eq(nspecs, {})
  eq(nerrs, {})
end)

T.describe('forward: template and describe', function()
  eq(Forward.describe({
    { lport = 3080, rhost = '127.0.0.1', rport = 3080 },
    { lport = 8080, rhost = '127.0.0.1', rport = 8080 },
  }), '3080 -> 127.0.0.1:3080, 8080 -> 127.0.0.1:8080')
  eq(Forward.describe(nil), '')

  -- the fresh-file template must parse to ZERO forwards and ZERO errors
  local tpl = Forward.template('me@host:2222', '/home/me/src/app')
  local specs, errs = Forward.parse(tpl)
  eq(specs, {})
  eq(errs, {})
  ok(tpl:find('# 3080 = 127.0.0.1:3080', 1, true) ~= nil, 'example forward is commented out')
  ok(tpl:find('me@host:2222', 1, true) ~= nil, 'template names the destination')
  ok(tpl:find('/home/me/src/app', 1, true) ~= nil, 'template names the workspace')

  -- the REMOTE side has no client destination string: omit that line
  local rtl = Forward.template(nil, '/home/me/app')
  local rs, re_ = Forward.parse(rtl)
  eq(#rs, 0)
  eq(#re_, 0)
  ok(not rtl:find('destination:', 1, true), 'nil dest omits the destination line')
  ok(rtl:find('# workspace:   /home/me/app', 1, true) ~= nil, 'workspace line kept')

  -- the local mirror keeps the profile key recognizable and stays in cache
  local p = vim.fs.normalize(Forward.local_path('--laptop--home-me-src-app--'))
  ok(p:find('/sshdev/forward/%-%-laptop%-%-home%-me%-src%-app%-%-/forward%.txt$') ~= nil,
    'cache/sshdev/forward/<workspace-profile-key>/forward.txt')
  ok(not pcall(Forward.local_path, '../escape'), 'path separators in a key are rejected')
  ok(not pcall(Forward.local_path, ''), 'empty key is rejected')
end)

T.describe('forward.extract_content: marker protocol', function()
  local token = 'feedbeef'
  local out = 'SSHDEV:FORWARD=yes\nSSHDEV:BEGIN-feedbeef\n3080 = 127.0.0.1:3080\n# note\n8080 = 127.0.0.1:8080\nSSHDEV:END-feedbeef\n'
  eq(Forward.extract_content(out, token), '3080 = 127.0.0.1:3080\n# note\n8080 = 127.0.0.1:8080')
  -- a file without a trailing newline gains one
  local nonl = 'SSHDEV:FORWARD=yes\nSSHDEV:BEGIN-feedbeef\n3080 = 127.0.0.1:3080\nSSHDEV:END-feedbeef\n'
  eq(Forward.extract_content(nonl, token), '3080 = 127.0.0.1:3080')
  -- a different token's markers do not confuse the extraction
  eq(Forward.extract_content(out, 'deadbeef'), nil)
  eq(Forward.extract_content('SSHDEV:FORWARD=no\n', token), nil)
  eq(Forward.extract_content('garbage', token), nil)
  eq(Forward.extract_content(nil, token), nil)
  -- CRLF content normalizes to LF
  local crlf = 'SSHDEV:FORWARD=yes\nSSHDEV:BEGIN-feedbeef\n3080 = 127.0.0.1:3080\r\nSSHDEV:END-feedbeef\n'
  eq(Forward.extract_content(crlf, token), '3080 = 127.0.0.1:3080')
end)

T.describe('ssh.forward_tunnel_args: one -L per forward, dest last', function()
  local cfg = Config.build({})
  local parsed = { dest = 'me@host', user = 'me', host = 'host', port = 2222 }
  local args = Ssh.forward_tunnel_args(cfg, parsed, {
    { lport = 3080, rhost = '127.0.0.1', rport = 3080 },
    { lport = 8080, rhost = '127.0.0.1', rport = 8080 },
  })
  eq(args[1], 'ssh')
  ok(vim.tbl_contains(args, '-p'), 'the destination port is passed through')
  ok(vim.tbl_contains(args, '2222'), 'ssh port 2222')
  ok(vim.tbl_contains(args, '-N'), 'tunnel runs no remote command')
  ok(vim.tbl_contains(args, 'ExitOnForwardFailure=yes'), 'a failed bind kills the tunnel, loudly')
  ok(vim.tbl_contains(args, 'ControlMaster=no'), 'tunnels are never multiplexed')
  local fwd = {}
  for i, a in ipairs(args) do
    if a == '-L' then
      fwd[#fwd + 1] = args[i + 1]
    end
  end
  eq(#fwd, 2, 'one -L per spec')
  eq(fwd[1], '127.0.0.1:3080:127.0.0.1:3080', 'local side binds loopback')
  eq(fwd[2], '127.0.0.1:8080:127.0.0.1:8080')
  eq(args[#args], 'me@host', 'destination is the last argument')
  local empty = Ssh.forward_tunnel_args(cfg, parsed, {})
  ok(not vim.tbl_contains(empty, '-L'), 'no -L without specs')
  ok(vim.tbl_contains(empty, 'ExitOnForwardFailure=yes'), 'stable option order without specs')
end)

T.describe('remote scripts: forward_fetch / forward_prepare', function()
  local rendered = render_all()
  ok(rendered.forward_fetch:find('[ -f "$FWD_FILE" ]', 1, true) ~= nil, 'fetch is read-only')
  ok(rendered.forward_fetch:find('SSHDEV:FORWARD=yes', 1, true) ~= nil, 'presence marker')
  ok(rendered.forward_fetch:find("TOKEN='feedbeef'", 1, true) ~= nil, 'the token travels in a variable')
  ok(rendered.forward_fetch:find('SSHDEV:BEGIN-%s', 1, true) ~= nil, 'begin marker uses the token')
  ok(rendered.forward_fetch:find('SSHDEV:END-%s', 1, true) ~= nil, 'end marker uses the token')
  ok(rendered.forward_fetch:find('tail -c 1', 1, true) ~= nil, 'a no-newline file cannot swallow the end marker')
  ok(rendered.forward_prepare:find('mkdir -p "$WS_PROFILE"', 1, true) ~= nil, 'prepare creates the profile dir')
  ok(rendered.forward_prepare:find('bad-workspace-path', 1, true) ~= nil, 'prepare guards the profile path like Scripts.prepare')
  ok(rendered.forward_prepare:find('SSHDEV:FORWARD_DIR=ok', 1, true) ~= nil, 'prepare reports success')
end)

T.describe('remote scripts: forward_fetch executes against a fixture', function()
  if vim.fn.executable('sh') ~= 1 then
    print('  SKIP: no POSIX sh in PATH')
    return
  end
  local fixture = 'tests/.tmp/fwd'
  Util.rmrf(fixture)
  local ws_dir = fixture .. '/workspace-profiles/--desk-1--home-me-app--'
  Util.mkdir_p(ws_dir)
  -- no trailing newline: the script must terminate the last line itself
  write_file(ws_dir .. '/forward.txt', '3080 = 127.0.0.1:3080\n# web\n8080 = 127.0.0.1:8080')

  local dir = vim.fs.joinpath(vim.fn.stdpath('cache'), 'sshdev-test-fwd')
  Util.rmrf(dir)
  local function run(name, vars)
    local f = vim.fs.abspath(vim.fs.joinpath(dir, name .. '.sh'))
    write_file(f, Util.render(Scripts._templates[name], vars))
    return vim.system({ 'sh', f }, { cwd = REPO_ROOT, text = true }):wait()
  end

  local fwd_vars = { WS_PROFILE = ws_dir, TOKEN = 'feedbeef' }
  local res = run('forward_fetch', fwd_vars)
  eq(res.code, 0, 'forward_fetch exits 0: ' .. tostring(res.stderr))
  eq(Forward.extract_content(res.stdout, 'feedbeef'),
    '3080 = 127.0.0.1:3080\n# web\n8080 = 127.0.0.1:8080',
    'exact content between the markers (final newline added)')

  -- missing file: FORWARD=no, no markers
  Util.rmrf(ws_dir)
  local res2 = run('forward_fetch', fwd_vars)
  eq(res2.code, 0, 'forward_fetch exits 0 without the file')
  eq(Util.parse_keyvals(res2.stdout).FORWARD, 'no')
  eq(Forward.extract_content(res2.stdout, 'feedbeef'), nil)

  -- forward_prepare mkdirs the guarded path
  local prep_vars = {
    ROOT = fixture .. '/root',
    WS_PROFILE = fixture .. '/root/workspace-profiles/--desk-1--home-me-app--',
  }
  local res3 = run('forward_prepare', prep_vars)
  eq(res3.code, 0, 'forward_prepare exits 0: ' .. tostring(res3.stderr))
  ok(uv.fs_stat(prep_vars.WS_PROFILE) ~= nil, 'profile dir created')
  -- the guard refuses paths outside <root>/workspace-profiles
  local res4 = run('forward_prepare', { ROOT = fixture .. '/root', WS_PROFILE = fixture .. '/elsewhere' })
  ok(res4.code ~= 0, 'prepare refuses an unguarded path')
  ok(tostring(res4.stdout):find('bad-workspace-path', 1, true) ~= nil, 'guard error marker')

  Util.rmrf(fixture)
  Util.rmrf(dir)
end)

T.describe('forward: remote-side editor (the attached session)', function()
  local function read_all(path)
    local fd = assert(uv.fs_open(path, 'r', 438), 'cannot read ' .. tostring(path))
    local st = uv.fs_fstat(fd)
    local data = st.size > 0 and uv.fs_read(fd, st.size, 0) or ''
    uv.fs_close(fd)
    return data
  end

  local saved_remote = vim.env.SSHDEV_REMOTE
  local saved_profile = vim.env.SSHDEV_WORKSPACE_PROFILE
  local orig_notify = vim.notify
  local seen = nil
  local function notify_spy()
    seen = nil
    vim.notify = function(msg, level)
      seen = { msg = msg, level = level }
    end
  end

  local dir = vim.fs.joinpath(vim.fn.stdpath('cache'), 'sshdev-test-fwd-remote')
  local ws = vim.fs.joinpath(dir, 'workspace-profiles', '--h--home-me-app--')

  -- the env simulation MUST be undone even when an assertion throws, or it
  -- leaks into every later describe
  local okr, err = pcall(function()
    -- simulate running inside the remote server
    vim.env.SSHDEV_REMOTE = '1'

    -- 1. no control channel: actionable guidance, not a dead end
    _G.SSHDEV_CONTROL_CHANNEL = nil
    vim.env.SSHDEV_WORKSPACE_PROFILE = '/root/.sshdev.nvim/workspace-profiles/--h--w--'
    notify_spy()
    Session.forward({})
    vim.notify = orig_notify
    ok(seen and seen.msg:find('client control channel is not available', 1, true) ~= nil,
      'without a channel the guidance points at the client')
    ok(seen and seen.msg:find(':detach', 1, true) ~= nil, 'the guidance names the workflow')

    -- 2. with a channel id (dead on purpose): the editor opens REMOTELY
    Util.rmrf(dir)
    Util.mkdir_p(ws)
    write_file(ws .. '/workspace.txt', '/home/me/app\n')
    _G.SSHDEV_CONTROL_CHANNEL = 999999 -- no such channel: the push will fail
    vim.env.SSHDEV_WORKSPACE_PROFILE = ws

    notify_spy()
    Session.forward({})
    vim.notify = orig_notify
    local fwd = vim.fs.joinpath(ws, 'forward.txt')
    ok(uv.fs_stat(fwd) ~= nil, 'missing forward.txt created with the template')
    local content = read_all(fwd)
    ok(content:find('# workspace:   /home/me/app', 1, true) ~= nil, 'template names the workspace')
    ok(not content:find('destination:', 1, true),
      'no destination line (the client dest is unknown remotely)')
    ok(seen and seen.msg:find('editing port forwards', 1, true) ~= nil, 'the open is announced')

    -- the buffer is open; a save pushes through the (dead) channel
    local buf
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b) == fwd and vim.api.nvim_buf_is_loaded(b) then
        buf = b
        break
      end
    end
    ok(buf ~= nil, 'the forward.txt buffer is open in this session')
    if buf then
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '4455 = 127.0.0.1:4455' })
      notify_spy()
      local wok, werr = pcall(vim.cmd, 'write')
      vim.notify = orig_notify
      ok(seen and seen.msg:find('client could not be reached', 1, true) ~= nil,
        'a dead control channel falls back to guidance on save')
      ok(wok or tostring(werr):find('client could not be reached', 1, true) ~= nil,
        'the fallback surfaces (headless may raise it through exec)')
      eq(Forward.applied(), nil, 'a remote-side save starts no tunnel in THIS nvim')
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end

    -- 3. a bogus profile is refused
    notify_spy()
    vim.env.SSHDEV_WORKSPACE_PROFILE = 'relative/path'
    Session.forward({})
    vim.notify = orig_notify
    ok(seen and seen.msg:find('no workspace profile', 1, true) ~= nil,
      'a relative profile path is refused')
  end)

  -- unconditional cleanup, even after a failed assertion
  _G.SSHDEV_CONTROL_CHANNEL = nil
  vim.env.SSHDEV_REMOTE = saved_remote
  vim.env.SSHDEV_WORKSPACE_PROFILE = saved_profile
  Util.rmrf(dir)
  if not okr then
    error(err, 0)
  end
end)

----------------------------------------------------------- environment

T.describe('env.parse: strict KEY=VALUE', function()
  -- values are VERBATIM: spaces, "=", "#", empty and surrounding spaces
  local vars, errs = Env.parse(
    '# comment\n'
      .. '\n'
      .. 'PATH=/usr/bin:/bin\n'
      .. 'NODE_ENV=development\n'
      .. 'EMPTY=\n'
      .. 'WITH_EQUALS=a=b=c\n'
      .. 'WITH_HASH=value # not a comment\n'
      .. 'SPACED=  keep me  \r\n'
  )
  eq(errs, {})
  eq(vars.PATH, '/usr/bin:/bin')
  eq(vars.NODE_ENV, 'development')
  eq(vars.EMPTY, '')
  eq(vars.WITH_EQUALS, 'a=b=c')
  eq(vars.WITH_HASH, 'value # not a comment')
  eq(vars.SPACED, '  keep me  ', 'value preserved verbatim (only the CRLF \\r is stripped)')

  -- every problem is reported with its line; a valid line still parses
  local bad, bad_errs = Env.parse(
    'export FOO=1\n'
      .. '1BAD=x\n'
      .. 'NO_EQUALS\n'
      .. 'GOOD=1\n'
      .. 'GOOD=2\n'
      .. 'SSHDEV_REMOTE=0\n'
      .. 'XDG_CONFIG_HOME=/x\n'
      .. 'HOME=/x\n'
      .. 'A B=c\n'
  )
  eq(#bad_errs, 8, 'all bad lines are reported')
  eq(bad.GOOD, '1', 'the valid line still parses')
  for i, ln in ipairs({ 1, 2, 3, 5, 6, 7, 8, 9 }) do
    ok(bad_errs[i]:find(('line %d'):format(ln), 1, true) ~= nil, ('error cites line %d'):format(ln))
  end
  ok(bad_errs[1]:find('invalid variable name', 1, true) ~= nil, 'export is not special-cased')
  ok(bad_errs[4]:find('line 4', 1, true) ~= nil, 'duplicate cites the first use')
  ok(bad_errs[1]:find('export FOO', 1, true) ~= nil, 'the offending key is shown')

  local _, nul_errs = Env.parse('NUL=a\0b\n')
  eq(#nul_errs, 1, 'NUL in a value is rejected')
  ok(nul_errs[1]:find('NUL', 1, true) ~= nil, 'the NUL error names the key')
  local _, cr_errs = Env.parse('CR=a\rb\n')
  eq(#cr_errs, 1, 'an internal carriage return is rejected')

  -- a malformed line may be a secret: errors must never echo the raw line
  local _, secret_errs = Env.parse('super-secret-token-with-no-equals\n')
  eq(#secret_errs, 1)
  ok(secret_errs[1]:find('super-secret', 1, true) == nil, 'the raw line is not echoed')

  -- an editor BOM is not part of the first key
  local bom_vars, bom_errs = Env.parse('\239\187\191FIRST=1\n')
  eq(bom_errs, {})
  eq(bom_vars.FIRST, '1')

  -- a comment-only file (the fresh template) injects nothing
  local none, nerr = Env.parse('# only comments\n\n# X=1\n')
  eq(none, {})
  eq(nerr, {})
  local empty_vars, empty_errs = Env.parse('')
  eq(empty_vars, {})
  eq(empty_errs, {})
end)

T.describe('env: template and local_path', function()
  -- the fresh-file template must parse to ZERO variables and ZERO errors
  local tpl = Env.template('me@host:2222', '/home/me/src/app')
  local vars, errs = Env.parse(tpl)
  eq(vars, {})
  eq(errs, {})
  ok(tpl:find('# NODE_ENV=development', 1, true) ~= nil, 'example variable is commented out')
  ok(tpl:find('me@host:2222', 1, true) ~= nil, 'template names the destination')
  ok(tpl:find('/home/me/src/app', 1, true) ~= nil, 'template names the workspace')

  -- the REMOTE side has no client destination string: omit that line
  local rtl = Env.template(nil, '/home/me/app')
  local rs, re_ = Env.parse(rtl)
  eq(#rs, 0)
  eq(#re_, 0)
  ok(not rtl:find('destination:', 1, true), 'nil dest omits the destination line')
  ok(rtl:find('# workspace:   /home/me/app', 1, true) ~= nil, 'workspace line kept')

  -- the local mirror keeps the profile key recognizable and stays in cache
  local p = vim.fs.normalize(Env.local_path('--laptop--home-me-src-app--'))
  ok(p:find('/sshdev/env/%-%-laptop%-%-home%-me%-src%-app%-%-/env%.txt$') ~= nil,
    'cache/sshdev/env/<workspace-profile-key>/env.txt')
  ok(not pcall(Env.local_path, '../escape'), 'path separators in a key are rejected')
  ok(not pcall(Env.local_path, ''), 'empty key is rejected')
end)

T.describe('env: active map, script_prefix and spawn_overlay', function()
  local parsed = Util.parse_dest('me@host:2222')
  Env.clear()
  eq(Env.script_prefix(parsed), '', 'nothing active -> empty prefix')
  eq(Env.spawn_overlay(parsed), nil)
  eq(Env.status_line(), nil)

  Env.set_active({ PATH = '/opt/bin:/usr/bin', QUOTED = "a'b $c & d", EMPTY = '' }, parsed)
  local prefix = Env.script_prefix(parsed)
  ok(prefix:find('export PATH=', 1, true) ~= nil, 'simple values are exported')
  ok(prefix:find([[export QUOTED='a'\''b $c & d']], 1, true) ~= nil,
    'single quotes are escaped for sh')
  eq(Env.active_keys(parsed), 'EMPTY PATH QUOTED', 'manifest keys are sorted')
  eq(Env.spawn_overlay(parsed).QUOTED, "a'b $c & d", 'the child env gets the raw value')
  ok(Env.status_line():find('3 variable', 1, true) ~= nil, 'status counts the variables')

  -- active is per destination (the port is part of the identity)
  local other = Util.parse_dest('me@host')
  eq(Env.active_for(other), nil, 'another destination sees nothing')
  Env.set_active({}, parsed)
  eq(Env.active_for(parsed), nil, 'an empty map is not active')
  Env.clear()
end)

T.describe('env.script_prefix: values survive sh verbatim', function()
  if vim.fn.executable('sh') ~= 1 then
    print('  SKIP: no POSIX sh in PATH')
    return
  end
  local parsed = Util.parse_dest('me@host')
  local value = "a'b $HOME & c=d  end"
  Env.set_active({ TRICKY = value, EMPTY = '' }, parsed)
  local script = Env.script_prefix(parsed)
    .. 'printf "%s\\n" "$TRICKY"\n'
    .. 'printf "[%s]\\n" "$EMPTY"\n'
  local res = vim.system({ 'sh', '-c', script }, { text = true }):wait()
  eq(res.code, 0, 'the exported script runs: ' .. tostring(res.stderr))
  eq(res.stdout, value .. '\n[]\n', 'quotes, $, &, = and spaces arrive verbatim')
  Env.clear()
end)

T.describe('env: runtime chunk sets and unsets vim.env', function()
  local saved_applied = _G.SSHDEV_ENV_APPLIED
  local saved_keys = vim.env.SSHDEV_ENV_KEYS
  local saved_a, saved_b, saved_c = vim.env.SSHDEV_OLD_A, vim.env.SSHDEV_OLD_B, vim.env.SSHDEV_NEW_V

  _G.SSHDEV_ENV_APPLIED = nil
  vim.env.SSHDEV_ENV_KEYS = 'SSHDEV_OLD_A SSHDEV_OLD_B'
  vim.env.SSHDEV_OLD_A = 'a'
  vim.env.SSHDEV_OLD_B = 'b'

  Env.apply_runtime({ SSHDEV_OLD_B = 'kept', SSHDEV_NEW_V = 'v' })
  eq(vim.env.SSHDEV_OLD_A, nil, 'a manifest key absent from the map is unset')
  eq(vim.env.SSHDEV_OLD_B, 'kept', 'a kept key takes the new value')
  eq(vim.env.SSHDEV_NEW_V, 'v', 'a new key is set')
  eq(_G.SSHDEV_ENV_APPLIED.SSHDEV_NEW_V, 'v', 'the applied map is recorded')

  Env.apply_runtime({})
  eq(vim.env.SSHDEV_OLD_B, nil, 'an empty map unsets previously applied keys')
  eq(vim.env.SSHDEV_NEW_V, nil)

  _G.SSHDEV_ENV_APPLIED = saved_applied
  vim.env.SSHDEV_ENV_KEYS = saved_keys
  vim.env.SSHDEV_OLD_A = saved_a
  vim.env.SSHDEV_OLD_B = saved_b
  vim.env.SSHDEV_NEW_V = saved_c
end)

T.describe('remote scripts: env_fetch / env_prepare', function()
  local rendered = render_all()
  ok(rendered.env_fetch:find('[ -f "$ENV_FILE" ]', 1, true) ~= nil, 'fetch is read-only')
  ok(rendered.env_fetch:find('SSHDEV:FILE=yes', 1, true) ~= nil, 'presence marker')
  ok(rendered.env_fetch:find("TOKEN='feedbeef'", 1, true) ~= nil, 'the token travels in a variable')
  ok(rendered.env_fetch:find('SSHDEV:BEGIN-%s', 1, true) ~= nil, 'begin marker uses the token')
  ok(rendered.env_fetch:find('SSHDEV:END-%s', 1, true) ~= nil, 'end marker uses the token')
  ok(rendered.env_fetch:find('tail -c 1', 1, true) ~= nil, 'a no-newline file cannot swallow the end marker')
  ok(rendered.env_prepare:find('mkdir -p "$WS_PROFILE"', 1, true) ~= nil, 'prepare creates the profile dir')
  ok(rendered.env_prepare:find('bad-workspace-path', 1, true) ~= nil, 'prepare guards the profile path')
  ok(rendered.env_prepare:find('SSHDEV:ENV_DIR=ok', 1, true) ~= nil, 'prepare reports success')
  ok(rendered.env_chmod:find("MODE='600'", 1, true) ~= nil, 'chmod template carries the asserted mode')
  ok(rendered.env_chmod:find('SSHDEV:ERROR=bad-mode', 1, true) ~= nil, 'chmod validates the mode')
  ok(rendered.env_chmod:find('SSHDEV:ERROR=no-file', 1, true) ~= nil, 'chmod requires the target file')
  ok(rendered.env_chmod:find('SSHDEV:CHMOD=ok', 1, true) ~= nil, 'chmod reports success')
  ok(rendered.start:find("export SSHDEV_ENV_KEYS='DATABASE_URL NODE_ENV'", 1, true) ~= nil,
    'the start script carries the injected-key manifest')
end)

T.describe('remote scripts: env_fetch executes against a fixture', function()
  if vim.fn.executable('sh') ~= 1 then
    print('  SKIP: no POSIX sh in PATH')
    return
  end
  local fixture = 'tests/.tmp/env'
  Util.rmrf(fixture)
  local ws_dir = fixture .. '/workspace-profiles/--desk-1--home-me-app--'
  Util.mkdir_p(ws_dir)
  -- no trailing newline: the script must terminate the last line itself
  write_file(ws_dir .. '/env.txt', 'A=1\n# note\nB=two words')

  local dir = vim.fs.joinpath(vim.fn.stdpath('cache'), 'sshdev-test-env')
  Util.rmrf(dir)
  local function run(name, vars)
    local f = vim.fs.abspath(vim.fs.joinpath(dir, name .. '.sh'))
    write_file(f, Util.render(Scripts._templates[name], vars))
    return vim.system({ 'sh', f }, { cwd = REPO_ROOT, text = true }):wait()
  end

  local env_vars = { WS_PROFILE = ws_dir, TOKEN = 'feedbeef' }
  local res = run('env_fetch', env_vars)
  eq(res.code, 0, 'env_fetch exits 0: ' .. tostring(res.stderr))
  eq(Util.extract_marked(res.stdout, 'feedbeef'), 'A=1\n# note\nB=two words',
    'exact content between the markers (final newline added)')

  -- missing file: FILE=no, no markers
  Util.rmrf(ws_dir)
  local res2 = run('env_fetch', env_vars)
  eq(res2.code, 0, 'env_fetch exits 0 without the file')
  eq(Util.parse_keyvals(res2.stdout).FILE, 'no')
  eq(Util.extract_marked(res2.stdout, 'feedbeef'), nil)

  -- env_prepare mkdirs the guarded path
  local prep_vars = {
    ROOT = fixture .. '/root',
    WS_PROFILE = fixture .. '/root/workspace-profiles/--desk-1--home-me-app--',
  }
  local res3 = run('env_prepare', prep_vars)
  eq(res3.code, 0, 'env_prepare exits 0: ' .. tostring(res3.stderr))
  ok(uv.fs_stat(prep_vars.WS_PROFILE) ~= nil, 'profile dir created')
  local res4 = run('env_prepare', { ROOT = fixture .. '/root', WS_PROFILE = fixture .. '/elsewhere' })
  ok(res4.code ~= 0, 'prepare refuses an unguarded path')
  ok(tostring(res4.stdout):find('bad-workspace-path', 1, true) ~= nil, 'guard error marker')

  -- env_chmod forces the mode (scp -p copies the Windows 0666 mirror mode):
  -- an existing world-readable file must become 0600 again
  local target = prep_vars.WS_PROFILE .. '/env.txt'
  write_file(target, 'A=1\n')
  uv.fs_chmod(target, 438) -- 0666
  eq(uv.fs_stat(target).mode % 512, 438, 'fixture starts world-readable')
  local res5 = run('env_chmod', { PATH = target, MODE = '600' })
  eq(res5.code, 0, 'env_chmod exits 0: ' .. tostring(res5.stderr))
  ok(tostring(res5.stdout):find('SSHDEV:CHMOD=ok', 1, true) ~= nil, 'chmod success marker')
  if vim.fn.has('win32') == 0 then
    eq(uv.fs_stat(target).mode % 512, 384, 'the file is 0600 after the chmod')
  else
    -- NTFS has no POSIX mode bits; a MSYS/Git-Bash chmod is a no-op emulation
    print('  SKIP: POSIX permission bits are not meaningful on Windows')
  end
  -- bad mode / missing file are explicit errors (never a silent success)
  local res6 = run('env_chmod', { PATH = target, MODE = '999' })
  ok(res6.code ~= 0, 'a non-octal mode is rejected')
  ok(tostring(res6.stdout):find('bad-mode', 1, true) ~= nil, 'bad-mode marker')
  local res7 = run('env_chmod', { PATH = fixture .. '/missing.txt', MODE = '600' })
  ok(res7.code ~= 0, 'a missing target is rejected')
  ok(tostring(res7.stdout):find('no-file', 1, true) ~= nil, 'no-file marker')

  Util.rmrf(fixture)
  Util.rmrf(dir)
end)

T.describe('env: apply forces 0600 on the remote env.txt', function()
  -- scp cannot carry the 0600 intent on every platform (Windows reports 0666
  -- and `scp -p` copies it), so Env.apply must assert the mode explicitly.
  local cfg = Config.get()
  local parsed = Util.parse_dest('me@host:2222')
  local ws_key = '--desk-1--home-me-src-app--'
  local mirror = Env.local_path(ws_key)
  Util.mkdir_p(vim.fs.dirname(mirror))
  write_file(mirror, 'NODE_ENV=development\n')

  local orig_upload, orig_chmod, orig_notify = Ssh.upload_file, Ssh.chmod_remote, vim.notify
  local chmods, notified = {}, {}
  local function apply_once()
    notified = {}
    return Env.apply({
      cfg = cfg,
      parsed = parsed,
      remote_root = '~/.sshdev.nvim',
      workspace = '/home/me/src/app',
      workspace_profile = '~/.sshdev.nvim/workspace-profiles/' .. ws_key,
      workspace_profile_key = ws_key,
      remote_missing = false,
    })
  end

  local okr, err = pcall(function()
    Ssh.upload_file = function()
      return { code = 0, stdout = '', stderr = '' }
    end
    Ssh.chmod_remote = function(_, _, remote_path, mode)
      chmods[#chmods + 1] = { path = remote_path, mode = mode }
      return { code = 0, stdout = 'SSHDEV:CHMOD=ok\n', stderr = '' }
    end
    vim.notify = function(msg)
      notified[#notified + 1] = msg
    end

    apply_once()
    eq(#chmods, 1, 'the remote env.txt is chmodded after the upload')
    eq(chmods[1].mode, '600', 'the asserted mode is 0600')
    eq(
      chmods[1].path,
      '~/.sshdev.nvim/workspace-profiles/' .. ws_key .. '/env.txt',
      'the remote env.txt path is chmodded'
    )
    ok(not tostring(notified[#notified]):find('WARNING', 1, true), 'no warning when the chmod works')
    ok(tostring(notified[#notified]):find('env saved', 1, true) ~= nil, 'the save is reported')

    -- a failed chmod must be surfaced: the file may hold secrets
    chmods = {}
    Ssh.chmod_remote = function()
      return { code = 1, stdout = 'SSHDEV:ERROR=no-file\n', stderr = 'chmod: missing target' }
    end
    apply_once()
    ok(tostring(notified[#notified]):find('WARNING', 1, true) ~= nil, 'a failed chmod is warned about')
    ok(tostring(notified[#notified]):find('0600', 1, true) ~= nil, 'the warning names the mode')
  end)

  Ssh.upload_file = orig_upload
  Ssh.chmod_remote = orig_chmod
  vim.notify = orig_notify
  Env.clear()
  Util.rmrf(vim.fs.dirname(mirror))
  if not okr then
    error(err)
  end
end)

T.describe('env: remote-side editor (the attached session)', function()
  local function read_all(path)
    local fd = assert(uv.fs_open(path, 'r', 438), 'cannot read ' .. tostring(path))
    local st = uv.fs_fstat(fd)
    local data = st.size > 0 and uv.fs_read(fd, st.size, 0) or ''
    uv.fs_close(fd)
    return data
  end

  local saved_remote = vim.env.SSHDEV_REMOTE
  local saved_profile = vim.env.SSHDEV_WORKSPACE_PROFILE
  local saved_foo = vim.env.FOO
  local saved_applied = _G.SSHDEV_ENV_APPLIED
  local orig_notify = vim.notify
  local seen = nil
  local function notify_spy()
    seen = nil
    vim.notify = function(msg, level)
      seen = { msg = msg, level = level }
    end
  end

  local dir = vim.fs.joinpath(vim.fn.stdpath('cache'), 'sshdev-test-env-remote')
  local ws = vim.fs.joinpath(dir, 'workspace-profiles', '--h--home-me-app--')

  local okr, err = pcall(function()
    -- simulate running inside the remote server
    vim.env.SSHDEV_REMOTE = '1'

    -- 1. no control channel: actionable guidance, not a dead end
    _G.SSHDEV_CONTROL_CHANNEL = nil
    vim.env.SSHDEV_WORKSPACE_PROFILE = '/root/.sshdev.nvim/workspace-profiles/--h--w--'
    notify_spy()
    Session.env({})
    vim.notify = orig_notify
    ok(seen and seen.msg:find('client control channel is not available', 1, true) ~= nil,
      'without a channel the guidance points at the client')
    ok(seen and seen.msg:find(':detach', 1, true) ~= nil, 'the guidance names the workflow')

    -- 2. with a channel id (dead on purpose): the editor opens REMOTELY
    Util.rmrf(dir)
    Util.mkdir_p(ws)
    write_file(ws .. '/workspace.txt', '/home/me/app\n')
    _G.SSHDEV_CONTROL_CHANNEL = 999999 -- no such channel: the push will fail
    vim.env.SSHDEV_WORKSPACE_PROFILE = ws

    notify_spy()
    Session.env({})
    vim.notify = orig_notify
    local envf = vim.fs.joinpath(ws, 'env.txt')
    ok(uv.fs_stat(envf) ~= nil, 'missing env.txt created with the template')
    local content = read_all(envf)
    ok(content:find('# workspace:   /home/me/app', 1, true) ~= nil, 'template names the workspace')
    ok(not content:find('destination:', 1, true),
      'no destination line (the client dest is unknown remotely)')
    ok(seen and seen.msg:find('editing environment variables', 1, true) ~= nil,
      'the open is announced')

    -- the buffer is open; a save pushes through the (dead) channel
    local buf
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b) == envf and vim.api.nvim_buf_is_loaded(b) then
        buf = b
        break
      end
    end
    ok(buf ~= nil, 'the env.txt buffer is open in this session')
    if buf then
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'FOO=bar' })
      if vim.fn.has('win32') == 0 then
        uv.fs_chmod(envf, 438) -- 0666: a widened mode the save must heal
      end
      notify_spy()
      local wok, werr = pcall(vim.cmd, 'write')
      vim.notify = orig_notify
      ok(seen and seen.msg:find('client could not be reached', 1, true) ~= nil,
        'a dead control channel falls back to guidance on save')
      ok(wok or tostring(werr):find('client could not be reached', 1, true) ~= nil,
        'the fallback surfaces (headless may raise it through exec)')
      eq(vim.env.FOO, 'bar', 'the remote save applies to the server itself')
      if vim.fn.has('win32') == 0 then
        eq(uv.fs_stat(envf).mode % 512, 384, 'a remote-side save re-asserts env.txt 0600')
      end
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end

    -- 3. a bogus profile is refused
    notify_spy()
    vim.env.SSHDEV_WORKSPACE_PROFILE = 'relative/path'
    Session.env({})
    vim.notify = orig_notify
    ok(seen and seen.msg:find('no workspace profile', 1, true) ~= nil,
      'a relative profile path is refused')
  end)

  -- unconditional cleanup, even after a failed assertion
  _G.SSHDEV_CONTROL_CHANNEL = nil
  _G.SSHDEV_ENV_APPLIED = saved_applied
  vim.env.SSHDEV_REMOTE = saved_remote
  vim.env.SSHDEV_WORKSPACE_PROFILE = saved_profile
  vim.env.FOO = saved_foo
  Env.clear()
  Util.rmrf(dir)
  if not okr then
    error(err, 0)
  end
end)

----------------------------------------------------------- bootstrap

T.describe('bootstrap.asset_name', function()
  eq(Bootstrap.asset_name('Linux', 'x86_64'), 'nvim-linux-x86_64')
  eq(Bootstrap.asset_name('Linux', 'aarch64'), 'nvim-linux-aarch64')
  eq(Bootstrap.asset_name('Darwin', 'arm64'), 'nvim-macos-arm64')
  eq(Bootstrap.asset_name('Linux', 'riscv64'), nil)
end)

T.describe('bootstrap.resolve_version', function()
  eq(Bootstrap.resolve_version(Config.build({ nvim_version = 'v0.11.3' })), 'v0.11.3')
  eq(Bootstrap.resolve_version(Config.build({ nvim_version = '0.12.0' })), 'v0.12.0')
  eq(Bootstrap.resolve_version(Config.build({ nvim_version = 'nightly' })), 'nightly')
end)

------------------------------------------------------------- history

T.describe('history: v2 record / list / remove', function()
  local data = vim.fs.joinpath(vim.fn.stdpath('cache'), 'sshdev-test-history')
  local orig_path = History.path
  local orig_cache = History._cache_path
  History.path = function()
    return vim.fs.joinpath(data, 'history.json')
  end
  History._cache_path = vim.fs.joinpath(data, 'profile-cache.json')
  Util.rmrf(data)

  local cfg = Config.build({ history_limit = 3 })
  History.record(cfg, {
    dest = 'a@h1',
    workspace = '/w1',
    workspace_profile_key = '--h1--w1--',
    nvim_profile_key = '--h1--v0.12.6--aaaa1111--',
  })
  History.record(cfg, { dest = 'b@h2', workspace = '/w2' })
  local list = History.list()
  eq(#list, 2)
  eq(list[1].dest, 'b@h2', 'newest first')

  History.record(cfg, {
    dest = 'a@h1',
    workspace = '/w1',
    workspace_profile_key = '--h1--w1--',
    nvim_profile_key = '--h1--v0.12.6--aaaa1111--',
  })
  list = History.list()
  eq(#list, 2)
  eq(list[1].dest, 'a@h1')
  eq(list[1].count, 2)
  eq(list[1].workspace_profile_key, '--h1--w1--')
  eq(list[1].nvim_profile_key, '--h1--v0.12.6--aaaa1111--')

  History.record(cfg, { dest = 'c@h3', workspace = '/w3' })
  History.record(cfg, { dest = 'd@h4', workspace = '/w4' })
  eq(#History.list(), 3, 'history_limit respected')

  History.remove({ dest = 'a@h1', workspace = '/w1' })
  for _, e in ipairs(History.list()) do
    not_ok(e.dest == 'a@h1', 'removed entry is gone')
  end

  ok(History.display({ dest = 'a@h', workspace = '/w', count = 2, last_used = os.time() }):find('a@h') ~= nil)
  eq(History.relative_time(os.time()), 'just now')
  ok(History.relative_time(os.time() - 120):find('2m') ~= nil)

  -- list_for is port-insensitive and scoped to one destination
  History.record(cfg, { dest = 'a@h1:2222', workspace = '/w9' })
  eq(#History.list_for('a@h1'), 1, 'list_for ignores the port')
  eq(History.list_for('a@h1')[1].workspace, '/w9')

  History.path = orig_path
  History._cache_path = orig_cache
  Util.rmrf(data)
end)

T.describe('history: legacy v1 files keep working', function()
  local data = vim.fs.joinpath(vim.fn.stdpath('cache'), 'sshdev-test-history-legacy')
  local orig_path = History.path
  History.path = function()
    return vim.fs.joinpath(data, 'history.json')
  end
  Util.rmrf(data)
  write_file(History.path(), vim.json.encode({
    { dest = 'me@host', workspace = '/w', profile_key = '--me--w--', last_used = 10, count = 2 },
  }))
  local list = History.list()
  eq(#list, 1)
  eq(list[1].workspace_profile_key, '--me--w--', 'profile_key read as workspace_profile_key')
  eq(list[1].nvim_profile_key, nil)

  local merged = History.merge_workspaces(History.list_for('me@host'), {}, 'me@host', 'me')
  eq(#merged, 1)
  eq(merged[1].stale, true, 'workspace missing on the remote is marked stale')

  History.path = orig_path
  Util.rmrf(data)
end)

T.describe('history: remote scan merge (user isolation)', function()
  local local_entries = {
    {
      dest = 'me@h:2222',
      workspace = '/w1',
      workspace_profile_key = '--me--w1--',
      nvim_profile_key = '--me--v0.12.6--local111--',
      last_used = 100,
      count = 3,
    },
    { dest = 'me@h', workspace = '/w-gone', workspace_profile_key = '--me--w-gone--', last_used = 50 },
    { dest = 'other@h2', workspace = '/other', workspace_profile_key = '--me--other--', last_used = 999 },
    { dest = 'me@h', workspace = '/leak', workspace_profile_key = '--otherhost--leak--', last_used = 900 },
  }
  local remote_entries = {
    {
      key = '--me--w1--',
      workspace = '/w1',
      nvim_profile_key = '--me--v0.12.6--remote222--',
      last_used = 200,
      has_session = true,
    },
    { key = '--me--w2--', workspace = '/w2', last_used = 300, has_session = false },
  }
  local merged = History.merge_workspaces(local_entries, remote_entries, 'me@h:2222', 'me')
  eq(#merged, 3, 'remote set + stale local entry only')
  eq(merged[1].workspace, '/w2', 'newest remote first')
  eq(merged[1].source, 'remote')
  eq(merged[2].workspace, '/w1')
  eq(merged[2].source, 'remote+history')
  eq(merged[2].count, 3, 'local count kept')
  eq(merged[2].nvim_profile_key, '--me--v0.12.6--remote222--', 'remote profile key wins')
  eq(merged[2].has_session, true)
  eq(merged[3].workspace, '/w-gone')
  eq(merged[3].stale, true)
  for _, e in ipairs(merged) do
    not_ok(e.workspace == '/other', 'other destination filtered')
    not_ok(e.workspace == '/leak', 'other client host entry filtered')
  end
  -- the picker only ever asks for the current destination
  eq(#History.merge_workspaces(local_entries, {}, 'me@h:2222', 'otherhost'), 1,
    'entries recorded for another client host are filtered')
end)

T.describe('history: nvim profile key cache for completion', function()
  local data = vim.fs.joinpath(vim.fn.stdpath('cache'), 'sshdev-test-cache')
  local orig_path = History.path
  local orig_cache = History._cache_path
  History.path = function()
    return vim.fs.joinpath(data, 'history.json')
  end
  History._cache_path = vim.fs.joinpath(data, 'profile-cache.json')
  Util.rmrf(data)

  local cfg = Config.build({})
  History.record(cfg, {
    dest = 'me@h:2222',
    workspace = '/w',
    nvim_profile_key = '--me--v0.12.6--aaaa1111--',
  })
  History.cache_nvim_profiles('me@h', { '--me--v0.12.6--bbbb2222--' })
  local keys = History.nvim_profile_keys('me@h:2222')
  ok(vim.tbl_contains(keys, '--me--v0.12.6--aaaa1111--'), 'recorded key cached')
  ok(vim.tbl_contains(keys, '--me--v0.12.6--bbbb2222--'), 'explicit cache entry found')
  eq(#keys, 2, 'keys deduplicated')
  eq(#History.nvim_profile_keys('other@host'), 0, 'cache is per destination')

  History.path = orig_path
  History._cache_path = orig_cache
  Util.rmrf(data)
end)

-------------------------------------------------------------- picker

T.describe('picker: connection items + history items', function()
  local items = Picker.connection_items({
    { dest = 'me@h', workspace = '/w1', last_used = os.time() },
  })
  eq(#items, 2)
  eq(items[1].kind, 'history')
  eq(items[2].kind, 'new')

  local merged_items = Picker.history_items(Config.build({}), 'me@h', {
    { key = '--me--w--', workspace = '/w', nvim_profile_key = '--me--v0.12.6--aaaa1111--', last_used = 10 },
  })
  eq(#merged_items, 2, 'one remote workspace + new')
  eq(merged_items[1].kind, 'workspace')
  eq(merged_items[1].entry.workspace, '/w')
  eq(merged_items[2].kind, 'new')
end)

T.describe('picker: destination resolution', function()
  eq(Picker.resolve_history_dest({ host = 'me@h', remotes = {} }, nil), 'me@h')
  eq(Picker.resolve_history_dest({ host = nil, remotes = { only = 'me@only' } }, nil), 'me@only')
  eq(Picker.resolve_history_dest({ host = nil, remotes = { a = 'me@a', b = 'me@b' } }, nil), nil)
  eq(Picker.resolve_history_dest({ host = 'me@h', remotes = {} }, 'explicit@h'), 'explicit@h')
end)

T.describe('picker: vim.ui.select fallback', function()
  local orig_has = Picker.has_telescope
  local orig_select = vim.ui.select
  Picker.has_telescope = function()
    return false
  end
  local picked = nil
  vim.ui.select = function(items, opts, on_choice)
    eq(type(items), 'table')
    eq(type(opts.format_item), 'function')
    on_choice(items[1])
  end
  Picker.choose('test', { { display = 'a' }, { display = 'b' } }, function(item)
    picked = item
  end)
  Picker.has_telescope = orig_has
  vim.ui.select = orig_select
  eq(picked.display, 'a')
end)

T.describe('picker: nvim profile reuse choice', function()
  local orig_choose = Picker.choose
  local got = 'unset'
  -- no profiles -> auto, without prompting
  Picker.prompt_nvim_profile({}, function(key)
    got = key
  end)
  eq(got, nil)

  local items_seen
  Picker.choose = function(title, items, on_choice)
    items_seen = items
    on_choice(items[2])
  end
  Picker.prompt_nvim_profile({
    { key = '--me--v0.12.6--aaaa1111--', version = 'v0.12.6', ready_hash = 'x', workspace_count = 2 },
  }, function(key)
    got = key
  end)
  Picker.choose = orig_choose
  eq(got, '--me--v0.12.6--aaaa1111--')
  eq(items_seen[1].kind, 'auto')
  eq(items_seen[2].kind, 'reuse')
  ok(items_seen[2].display:find('2 workspace', 1, true) ~= nil, 'workspace count shown')
end)

------------------------------------------------------------- session

T.describe('session: needs_bootstrap (reuse decision)', function()
  local layout = { config_hash = 'abcdef0123456789' }
  eq(Session.needs_bootstrap({ np_ready = 'abcdef0123456789' }, layout, {}), false)
  eq(Session.needs_bootstrap({ np_ready = 'other' }, layout, {}), true)
  eq(Session.needs_bootstrap({ np_ready = 'abcdef0123456789' }, layout, { force = true }), true)
  eq(Session.needs_bootstrap({ np_ready = '' }, layout, {}), true)
  eq(Session.needs_bootstrap(nil, layout, {}), true)
end)

T.describe('session: reuse decision for explicit nvim profiles', function()
  local base = {
    home = '/home/me',
    hostname = 'me',
    nvim_version = 'v0.12.6',
    config_hash = '0123456789abcdef',
    workspace = '/w',
  }
  local auto = assert(Layout.build(base))
  -- normal auto profile: this client owns it
  eq(Session.reuse_action(auto, { np_exists = true, np_ready = '0123456789abcdef' }), 'own')
  -- an explicit key equal to the auto key is just the normal flow
  local explicit_auto = assert(Layout.build(vim.tbl_extend('force', base, {
    nvim_profile_key = auto.nvim_profile_key,
  })))
  eq(Session.reuse_action(explicit_auto, { np_exists = true, np_ready = 'x' }), 'own')
  -- an existing, complete explicit profile is reused as-is
  local reused = assert(Layout.build(vim.tbl_extend('force', base, {
    nvim_profile_key = '--me--v0.12.6--ffff0000--',
  })))
  eq(Session.reuse_action(reused, { np_exists = true, np_ready = 'ffff0000' }), 'reuse')
  -- missing / incomplete explicit profiles fall back to the auto profile
  eq(Session.reuse_action(reused, { np_exists = false }), 'fallback')
  eq(Session.reuse_action(reused, { np_exists = true, np_ready = '' }), 'fallback')
end)

T.describe('session: auto nvim profile key', function()
  local key = assert(Session.auto_nvim_profile_key(Config.build({})))
  ok(key:match('^%-%-[%w._-]+%-%-v?%d+%.%d+%.%d+%-%-%x%x%x%x%x%x%x%x%-%-$') ~= nil,
    'auto key format: ' .. key)
  ok(key:find(Util.os_hostname(), 1, true) ~= nil, 'key namespaces the local hostname')
end)

T.describe('session.ui_kind', function()
  eq(Session.ui_kind(), 'headless', 'tests run headless')
end)

T.describe('attach strategy matrix', function()
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
  local root = Util.plugin_root()
  local f = io.open(root .. '/lua/sshdev/session.lua', 'r')
  ok(f ~= nil)
  if f then
    local src = f:read('*a')
    f:close()
    ok(src:find("('connect %s')", 1, true) ~= nil, 'connect uses a bare host:port')
    ok(src:find("'connect tcp://", 1, true) == nil, 'no tcp:// connect command')
    ok(src:find('"connect tcp://', 1, true) == nil, 'no tcp:// connect command (double quotes)')
    ok(src:find("('127.0.0.1:%d'):format(lport)", 1, true) ~= nil, 'tunnel address is host:port')
  end
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
    ok(src:find('VimEnter', 1, true) ~= nil, 'restores on startup')
    -- restored buffers get their FileType re-established (session sourcing
    -- suppresses the read events, so treesitter/LSP would never attach)
    ok(src:find('reestablish_filetypes', 1, true) ~= nil, 're-establishes filetypes after restore')
    ok(src:find('vim.filetype.match', 1, true) ~= nil, 'explicit filetype detection')
    ok(src:find('doautocmd FileType', 1, true) ~= nil, 're-fires FileType for late handlers')
    ok(src:find('UIEnter', 1, true) ~= nil, 'second pass at the first UI attach')
    ok(src:find('SSHDEV_REMOTE', 1, true) ~= nil, 'guarded by env')
    ok(src:find('SSHDEV_WORKSPACE_PROFILE', 1, true) ~= nil, 'reads the workspace profile env')
    ok(src:find('SSHDEV_NVIM_PROFILE', 1, true) ~= nil, 'reads the nvim profile env')
    -- session persistence replaced quit hijacking entirely
    ok(src:find('cnoreabbrev', 1, true) == nil, 'no quit hijacking')
    ok(src:find('Detach', 1, true) == nil, 'no detach commands')
  end
end)

T.describe('remote scripts: bootstrap round trip (simulated remote)', function()
  if vim.fn.executable('sh') ~= 1 then
    print('  SKIP: no POSIX sh in PATH')
    return
  end

  local base = 'tests/.tmp/bootstrap'
  Util.rmrf(base)
  local home_rel = base .. '/home'
  -- The workspace path in the *layout* is a realistic absolute remote path;
  -- the rendered script receives a repo-relative one so nothing is created
  -- outside the workspace during the test.
  local layout = assert(Layout.build({
    home = home_rel,
    hostname = 'sim-host',
    nvim_version = 'v0.12.6',
    config_hash = '0123456789abcdef',
    workspace = '/home/sim/work/src/app',
    token = 't1',
  }))
  local sim_workspace = base .. '/work/src/app'
  local fake_log = base .. '/nvim.log'

  local function read_file(path)
    local fd = uv.fs_open(vim.fs.abspath(path), 'r', 438)
    if not fd then
      return nil
    end
    local st = uv.fs_fstat(fd)
    local data = st and uv.fs_read(fd, st.size, 0) or nil
    uv.fs_close(fd)
    return data
  end

  local function exists(path)
    return uv.fs_stat(vim.fs.abspath(path)) ~= nil
  end

  -- POSIX `ln` stub: kernel symlinks are not available on every dev box
  -- (MSYS falls back to recursive copies), so the integration test runs the
  -- real remote scripts against a tiny `ln -sfn TARGET DEST` implementation
  -- that resolves the target relative to DEST and records the call. The exact
  -- symlink commands and relative targets are asserted separately in the
  -- template tests above.
  local stub_dir = base .. '/stub'
  local ln_log = base .. '/ln.log'
  write_file(stub_dir .. '/ln', table.concat({
    '#!/bin/sh',
    'while [ $# -gt 0 ]; do',
    '  case "$1" in',
    '    -sfn|-sf|-s|-f|-n) shift ;;',
    '    --) shift; break ;;',
    '    -*) echo "stub ln: unsupported option $1" >&2; exit 2 ;;',
    '    *) break ;;',
    '  esac',
    'done',
    'if [ $# -ne 2 ]; then echo "stub ln: need TARGET DEST" >&2; exit 2; fi',
    'src=$1',
    'dst=$2',
    "printf '%s\\n' \"$*\" >> '" .. ln_log .. "'",
    'case "$src" in',
    '  /*) abs=$src ;;',
    '  *) abs=$(dirname "$dst")/$src ;;',
    'esac',
    'rm -rf "$dst"',
    'cp -R "$abs" "$dst"',
    '',
  }, '\n'))
  local stub_chmod = vim.system({ 'sh', '-c', "chmod +x '" .. stub_dir .. "/ln'" }, {
    cwd = REPO_ROOT,
    text = true,
  }):wait()
  eq(stub_chmod.code, 0, 'ln stub made executable')

  -- fake nvim: answers `-v` for the ensure step and records the environment of
  -- the headless install run
  write_file(layout.bin_dir .. '/bin/nvim', table.concat({
    '#!/bin/sh',
    [[if [ "$1" = '-v' ]; then printf 'NVIM v0.12.6\n'; exit 0; fi]],
    '{',
    [[  printf 'ARGS=%s\n' "$*"]],
    [[  printf 'XDG_CONFIG_HOME=%s\n' "$XDG_CONFIG_HOME"]],
    [[  printf 'XDG_DATA_HOME=%s\n' "$XDG_DATA_HOME"]],
    [[  printf 'XDG_STATE_HOME=%s\n' "$XDG_STATE_HOME"]],
    [[  printf 'XDG_CACHE_HOME=%s\n' "$XDG_CACHE_HOME"]],
    [[  printf 'NVIM_APPNAME=%s\n' "$NVIM_APPNAME"]],
    [[  printf 'SSHDEV_NVIM_PROFILE=%s\n' "$SSHDEV_NVIM_PROFILE"]],
    [[  printf 'SSHDEV_REMOTE=%s\n' "$SSHDEV_REMOTE"]],
    "} >> '" .. fake_log .. "'",
    'exit 0',
    '',
  }, '\n'))
  write_file(layout.bin_dir .. '/.platform', 'Linux-x86_64\n')
  local chmod = vim.system({ 'sh', '-c', "chmod +x '" .. layout.bin_dir .. "/bin/nvim'" }, {
    cwd = REPO_ROOT,
    text = true,
  }):wait()
  eq(chmod.code, 0, 'fake nvim made executable')

  local auto_np = Util.join_remote(layout.nvim_profiles_root, Layout.auto_nvim_profile_key(layout))
  local base_vars = {
    ROOT = layout.root,
    VERSION = layout.nvim_version,
    MIRROR = 'https://example.invalid/dl',
    PROXY = '',
    NP = layout.nvim_profile,
    NP_KEY = layout.nvim_profile_key,
    AUTO_NP = auto_np,
    WS_PROFILE = layout.workspace_profile,
    WS_KEY = layout.workspace_profile_key,
    PLATFORM = 'Linux-x86_64',
    SYS = 'Linux',
    MACHINE = 'x86_64',
    WORKSPACE = sim_workspace,
    STAGING = '',
    HOST = layout.hostname,
    NP_BIN_TARGET = layout.nvim_bin_link_target,
    NP_LINK_TARGET = layout.nvim_profile_link_target,
    OWN = '1',
    BIN = Layout.bin_path(layout),
    HASH = layout.config_hash,
    LOCK_WAIT = '10',
    FORCE = '0',
    INSTALL_CMDS = " -c 'sshdev-fake'",
    RPORT = '23456',
    SESSION = layout.session_file,
    RESTORE = '1',
    HELPER = layout.helper_file,
    FIND_RUNNING = Scripts.find_running,
  }

  local function run(name, extra)
    local vars = vim.deepcopy(base_vars)
    for k, v in pairs(extra or {}) do
      vars[k] = v
    end
    local path = vim.fs.joinpath(base, 'scripts', name .. '.sh')
    write_file(path, Util.render(Scripts._templates[name], vars))
    local res = vim.system({
      'sh',
      '-c',
      'PATH="$1:$PATH"; sh "$2"',
      'sshdev-test',
      stub_dir,
      vim.fs.abspath(path),
    }, { cwd = REPO_ROOT, text = true }):wait()
    return res, Util.parse_keyvals(res.stdout)
  end

  -- 1. ensure: the shared binary is found, no profile exists yet, no server
  local _, kv = run('ensure')
  eq(kv.BINVERSION, 'NVIM v0.12.6', 'ensure reports the binary version')
  eq(kv.NP_EXISTS, 'no', 'nvim profile does not exist yet')
  eq(kv.AUTO_EXISTS, 'no', 'auto profile does not exist yet')
  eq(kv.SERVER, 'stopped', 'no server yet')

  -- 2. prepare creates the nvim profile + links + metadata
  local _, pkv = run('prepare', { STAGING = layout.staging_dir })
  eq(pkv.PREPARED, '1')
  ok(exists(layout.xdg_share), 'xdg/share created')
  ok(exists(layout.xdg_state), 'xdg/state created')
  ok(exists(layout.xdg_cache), 'xdg/cache created')
  eq(read_file(layout.client_host_file), 'sim-host\n', 'client-host metadata')
  eq(read_file(layout.nvim_version_file), 'v0.12.6\n', 'nvim-version metadata')
  eq(read_file(layout.nvim_profile_key_file), layout.nvim_profile_key .. '\n', 'nvim-profile.txt')
  eq(read_file(layout.workspace_file), sim_workspace .. '\n', 'workspace.txt')
  ok(exists(layout.staging_dir), 'staging dir for the upload')
  ok(exists(layout.nvim_profile_link .. '/nvim-bin/bin/nvim'),
    'workspace profile links to the nvim profile')
  local ln_calls = read_file(ln_log) or ''
  -- the stub receives "-sfn TARGET DEST"; TARGET must be relative to the link
  ok(ln_calls:find(layout.nvim_bin_link_target .. ' ', 1, true) ~= nil,
    'relative nvim-bin link target')
  ok(ln_calls:find(layout.nvim_profile_link_target .. ' ', 1, true) ~= nil,
    'relative workspace -> nvim profile link target')

  -- 3. simulate the scp of the config into the staging dir
  write_file(layout.staging_dir .. '/nvim-config/init.lua', 'vim.opt.number = true\n')

  -- 4. commit: swap + headless install, with the right XDG envs
  local _, ckv = run('commit', { STAGING = layout.staging_dir })
  eq(ckv.NP, 'installed', 'first commit installs')
  eq(read_file(layout.ready_file), layout.config_hash .. '\n', '.ready records the content hash')
  eq(read_file(layout.nvim_config .. '/init.lua'), 'vim.opt.number = true\n', 'config swapped in')
  local log = read_file(fake_log) or ''
  ok(log:find('XDG_DATA_HOME=' .. layout.xdg_share, 1, true) ~= nil, 'plugins live in xdg/share')
  ok(log:find('XDG_STATE_HOME=' .. layout.xdg_state, 1, true) ~= nil, 'state lives in xdg/state')
  ok(log:find('XDG_CACHE_HOME=' .. layout.xdg_cache, 1, true) ~= nil, 'cache lives in xdg/cache')
  ok(log:find('NVIM_APPNAME=nvim-config', 1, true) ~= nil, 'appname nvim-config')
  ok(log:find('SSHDEV_NVIM_PROFILE=' .. layout.nvim_profile, 1, true) ~= nil, 'nvim profile exported')
  ok(log:find('SSHDEV_REMOTE=1', 1, true) ~= nil, 'remote marker exported')
  ok(log:find('sshdev-fake', 1, true) ~= nil, 'install_commands ran')

  -- 5. ensure now reports the finished profile
  local _, kv2 = run('ensure')
  eq(kv2.NP_EXISTS, 'yes')
  eq(kv2.NP_READY_HASH, layout.config_hash, 'explicit profile ready hash')
  eq(kv2.AUTO_READY_HASH, layout.config_hash, 'auto profile ready hash')

  -- 6. a redundant commit is a cheap no-op (this is the cross-workspace reuse)
  write_file(layout.staging_dir .. '/nvim-config/init.lua', 'stale\n')
  local _, ckv2 = run('commit', { STAGING = layout.staging_dir })
  eq(ckv2.NP, 'ready', 'ready profile is reused without installing')

  -- 7. a stale lock (dead pid) is stolen and the force reinstall goes through
  local dead = vim.system({ 'sh', '-c', 'echo $$' }, { text = true }):wait()
  Util.mkdir_p(layout.lock_dir)
  write_file(layout.lock_dir .. '/pid', vim.trim(dead.stdout) .. '\n')
  write_file(layout.staging_dir .. '/nvim-config/init.lua', 'vim.opt.number = false\n')
  local _, ckv3 = run('commit', { STAGING = layout.staging_dir, FORCE = '1', LOCK_WAIT = '5' })
  eq(ckv3.NP, 'installed', 'stale lock stolen')
  not_ok(exists(layout.lock_dir), 'lock released after install')

  -- 8. a live lock makes the caller wait and then report a conflict
  local lock_pid_file = base .. '/live.pid'
  local live_job = vim.fn.jobstart({ 'sh', '-c', "echo $$ > '" .. lock_pid_file .. "'; sleep 30" })
  local live_pid = nil
  for _ = 1, 60 do
    live_pid = read_file(lock_pid_file)
    if live_pid and vim.trim(live_pid) ~= '' then
      live_pid = vim.trim(live_pid)
      break
    end
    vim.wait(50)
  end
  ok(live_pid ~= nil, 'spawned a live process for the lock test')
  Util.mkdir_p(layout.lock_dir)
  write_file(layout.lock_dir .. '/pid', tostring(live_pid) .. '\n')
  write_file(layout.staging_dir .. '/nvim-config/init.lua', 'x\n')
  local _, ckv4 = run('commit', { STAGING = layout.staging_dir, FORCE = '1', LOCK_WAIT = '1' })
  eq(ckv4.ERROR, 'locked', 'live lock is not stolen')
  Util.rmrf(layout.lock_dir)
  pcall(vim.fn.jobstop, live_job)
  pcall(vim.fn.jobwait, { live_job }, 2000)

  -- 9. the listing scripts see exactly this client host's profiles
  local wres = run('list_workspace', { ROOT = layout.root, HOST = layout.hostname })
  local ws_entries = Scripts.parse_workspace_list(wres.stdout)
  eq(#ws_entries, 1, 'one workspace profile for this host')
  eq(ws_entries[1].workspace, sim_workspace)
  eq(ws_entries[1].nvim_profile_key, layout.nvim_profile_key)
  local nres = run('list_nvim', { ROOT = layout.root, HOST = layout.hostname })
  local np_entries = Scripts.parse_nvim_list(nres.stdout)
  eq(#np_entries, 1, 'one nvim profile for this host')
  eq(np_entries[1].key, layout.nvim_profile_key)
  eq(np_entries[1].workspace_count, 1, 'referenced by one workspace profile')
  local other = run('list_workspace', { ROOT = layout.root, HOST = 'another-host' })
  eq(#Scripts.parse_workspace_list(other.stdout), 0, 'other client hosts stay isolated')

  -- 10. OWN=0 (explicit reuse) must not rewrite the nvim profile metadata
  write_file(layout.nvim_version_file, 'sentinel\n')
  local _, rkv = run('prepare', { OWN = '0' })
  eq(rkv.PREPARED, '1')
  eq(read_file(layout.nvim_version_file), 'sentinel\n', 'reused profile metadata untouched')
  ok(exists(layout.nvim_profile_link .. '/nvim-bin/bin/nvim'), 'workspace relinked to the reused profile')

  Util.rmrf(base)
end)

return T
