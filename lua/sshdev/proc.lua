--- Coroutine-based async primitives for sshdev.nvim.
---
--- Flow functions run inside a coroutine (started with `Proc.launch`) and
--- call `Proc.await{...}` to wait for background jobs. Errors thrown inside
--- a flow propagate to the last resume point and are reported via
--- `Util.report_error`.

local M = {}

local Util = require('sshdev.util')

---libuv handle (vim.uv in >= 0.10, vim.loop as legacy alias).
local uv = vim.uv or vim.loop

local function report_from_resume(co, ok, err)
  if not ok then
    Util.report_error(err)
  end
  return ok
end

--- Wait for a background job. Returns { code, stdout, stderr, timed_out }.
---
--- opts:
---   cmd      string[]  argv (no shell involved)
---   cwd      string?   working directory
---   input    string?   written to stdin, then stdin is closed
---   timeout  number?   milliseconds; job is killed on expiry
---   detach   boolean?   detach job from nvim (survives :connect detaching
---                      and even nvim exiting -- used by the ssh tunnel)
---   label    string?   for log lines
function M.await(opts)
  local co = assert(coroutine.running(), 'sshdev: await() must be called from a coroutine')

  local out, errout = {}, {}
  local done = false
  local timed_out = false
  local job_id = nil

  local function on_exit(_, code)
    if done then
      return
    end
    done = true
    local res = {
      code = code,
      stdout = table.concat(out, '\n'),
      stderr = table.concat(errout, '\n'),
      timed_out = timed_out,
    }
    local ok, a = coroutine.resume(co, res)
    report_from_resume(co, ok, a)
  end

  local job_opts = {
    cwd = opts.cwd,
    detach = opts.detach,
    on_stdout = function(_, data)
      for _, l in ipairs(data) do
        if l ~= '' then
          out[#out + 1] = l
        end
      end
    end,
    on_stderr = function(_, data)
      for _, l in ipairs(data) do
        if l ~= '' then
          errout[#errout + 1] = l
          if opts.label then
            Util.log('[%s] %s', opts.label, l)
          end
        end
      end
    end,
    on_exit = on_exit,
  }

  job_id = vim.fn.jobstart(opts.cmd, job_opts)
  if type(job_id) ~= 'number' or job_id <= 0 then
    return {
      code = -1,
      stdout = '',
      stderr = ('failed to start %s'):format(opts.cmd[1] or '?'),
      timed_out = false,
    }
  end

  if opts.input then
    vim.fn.chansend(job_id, opts.input)
    vim.fn.chanclose(job_id, 'stdin')
  end

  if opts.timeout then
    vim.defer_fn(function()
      if done then
        return
      end
      timed_out = true
      pcall(vim.fn.jobstop, job_id)
    end, opts.timeout)
  end

  return coroutine.yield()
end

--- Probe a TCP endpoint from inside a flow.
--- Returns true when the connection could be established and stayed open
--- for `settle_ms` (an ssh -L forward accepts locally then drops when the
--- remote side refuses, hence the settle window).
function M.await_tcp_probe(host, port, settle_ms, timeout_ms)
  local co = assert(coroutine.running(), 'sshdev: await_tcp_probe() must be called from a coroutine')

  local settled = false
  local handle = uv.new_tcp()
  if not handle then
    return false
  end
  local timer = nil

  local function finish(v)
    if settled then
      return
    end
    settled = true
    if timer and not timer:is_closing() then
      timer:close()
    end
    if not handle:is_closing() then
      pcall(function()
        handle:read_stop()
      end)
      handle:close()
    end
    local ok, a = coroutine.resume(co, v)
    report_from_resume(co, ok, a)
  end

  if timeout_ms then
    vim.defer_fn(function()
      finish(false)
    end, timeout_ms)
  end

  handle:connect(host, port, function(err)
    if err then
      return finish(false)
    end
    timer = uv.new_timer()
    handle:read_start(function(rerr, data)
      -- EOF or error means the tunnel target is gone; real data means alive.
      if rerr or data == '' or data == nil then
        finish(false)
      else
        finish(true)
      end
    end)
    timer:start(settle_ms, 0, function()
      finish(true)
    end)
  end)

  return coroutine.yield()
end

--- Start a flow function in its own coroutine with error reporting.
function M.launch(fn)
  local co = coroutine.create(fn)
  local ok, a = coroutine.resume(co)
  if not ok then
    Util.report_error(a)
  end
end

return M
