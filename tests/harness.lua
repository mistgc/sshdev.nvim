--- Tiny assert harness for sshdev.nvim tests (no external dependencies).

local M = {}

M.count = 0
M.failures = 0
M._sections = {}

local function loc()
  if #M._sections > 0 then
    return table.concat(M._sections, ' / ')
  end
  return '?'
end

---Group assertions; prints one PASS/FAILED line per group.
function M.describe(name, fn)
  M._sections[#M._sections + 1] = name
  local before = M.failures
  local ok, err = pcall(fn)
  if not ok then
    M.failures = M.failures + 1
    print(('  ERROR in "%s": %s'):format(name, tostring(err)))
  end
  if M.failures > before then
    print(('FAILED: %s'):format(name))
  else
    print(('PASS:   %s'):format(name))
  end
  M._sections[#M._sections] = nil
end

---Assert deep equality.
function M.eq(actual, expected, msg)
  M.count = M.count + 1
  if not vim.deep_equal(actual, expected) then
    M.failures = M.failures + 1
    print(('  FAIL %s: expected %s, got %s'):format(
      msg or loc(),
      vim.inspect(expected),
      vim.inspect(actual)
    ))
  end
end

---Assert truthiness.
function M.ok(cond, msg)
  M.count = M.count + 1
  if not cond then
    M.failures = M.failures + 1
    print(('  FAIL %s'):format(msg or loc()))
  end
end

---Assert falsiness.
function M.not_ok(cond, msg)
  M.ok(not cond, msg)
end

---Finish the run; exits nvim with the right code.
function M.done()
  print(('\n%d checks, %d failure(s)'):format(M.count, M.failures))
  return M.failures
end

return M
