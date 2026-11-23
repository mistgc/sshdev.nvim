--- Msgpack-RPC framing helpers for the local UI reconnect proxy.
---
--- The proxy (`scripts/ui_proxy.lua`) relays the msgpack-RPC stream between a
--- local UI client (nvim's builtin TUI, attached with |:connect|) and the
--- remote nvim server. It never re-encodes forwarded bytes: these helpers are
--- only used on the paths that must inspect or synthesize messages:
---
---   * the UI's `nvim_ui_attach` is captured once and replayed verbatim on
---     every new upstream after a reconnect (the UI channel itself never
---     closes, so the client never sends another attach);
---   * `nvim_ui_try_resize` updates the captured geometry;
---   * while the upstream is down, INPUT notifications (`nvim_input` /
---     `nvim_paste`) are dropped instead of replayed after a reconnect (a
---     frozen UI must not deliver the user's frustrated ":q" minutes later);
---   * a synthetic UI event sets the terminal title to "reconnecting…".
---
--- UI events are not standalone RPC notifications: the server packs them in a
--- `[2, "redraw", events]` notification, where every event is
--- `[name, [args...]]` (see `nvim/api/ui.c: prepare_call()`), so encoding them
--- for the UI client has to follow that shape.
---
--- Pure functions only (no I/O), so this module is unit-testable.

local M = {}

---Maximum nesting depth accepted by the frame scanner. Real RPC messages
---(even nested redraw payloads) are far below this; the cap bounds the
---recursion of a malformed peer.
local MAX_DEPTH = 64

local value_length
local container_length
local sized_length
local read_count

---Length in bytes of the msgpack value that starts at `pos`.
---
---Returns nil while the buffer is incomplete (the caller waits for more
---data) and `false` for a malformed/unparseable byte. `pos` is 1-based.
---@param buf string
---@param pos integer|nil
---@param depth integer|nil
---@return integer|nil|boolean
function value_length(buf, pos, depth)
  depth = depth or 0
  if depth > MAX_DEPTH then
    return false
  end
  local n = #buf
  if pos > n then
    return nil
  end
  local b = buf:byte(pos)
  if b == nil then
    return nil
  end

  -- positive fixint
  if b <= 0x7f then
    return 1
  end
  -- negative fixint
  if b >= 0xe0 then
    return 1
  end
  -- fixmap
  if b >= 0x80 and b <= 0x8f then
    return container_length(buf, pos, (b - 0x80) * 2, depth, 1)
  end
  -- fixarray
  if b >= 0x90 and b <= 0x9f then
    return container_length(buf, pos, b - 0x90, depth, 1)
  end
  -- fixstr
  if b >= 0xa0 and b <= 0xbf then
    local len = b - 0xa0
    if #buf < pos + len then
      return nil
    end
    return 1 + len
  end

  -- fixed-width scalars
  if b == 0xc0 or b == 0xc2 or b == 0xc3 then -- nil / false / true
    return 1
  end
  if b == 0xca then -- float32
    return #buf >= pos + 4 and 5 or nil
  end
  if b == 0xcb then -- float64
    return #buf >= pos + 8 and 9 or nil
  end
  if b == 0xcc then -- uint8
    return #buf >= pos + 1 and 2 or nil
  end
  if b == 0xcd then -- uint16
    return #buf >= pos + 2 and 3 or nil
  end
  if b == 0xce then -- uint32
    return #buf >= pos + 4 and 5 or nil
  end
  if b == 0xcf then -- uint64
    return #buf >= pos + 8 and 9 or nil
  end
  if b == 0xd0 then -- int8
    return #buf >= pos + 1 and 2 or nil
  end
  if b == 0xd1 then -- int16
    return #buf >= pos + 2 and 3 or nil
  end
  if b == 0xd2 then -- int32
    return #buf >= pos + 4 and 5 or nil
  end
  if b == 0xd3 then -- int64
    return #buf >= pos + 8 and 9 or nil
  end
  -- fixext
  if b == 0xd4 then
    return #buf >= pos + 2 and 3 or nil
  end
  if b == 0xd5 then
    return #buf >= pos + 3 and 4 or nil
  end
  if b == 0xd6 then
    return #buf >= pos + 5 and 6 or nil
  end
  if b == 0xd7 then
    return #buf >= pos + 9 and 10 or nil
  end
  if b == 0xd8 then
    return #buf >= pos + 17 and 18 or nil
  end
  -- str8/16/32
  if b == 0xd9 then
    return sized_length(buf, pos, 1, depth)
  end
  if b == 0xda then
    return sized_length(buf, pos, 2, depth)
  end
  if b == 0xdb then
    return sized_length(buf, pos, 4, depth)
  end
  -- array16/32, map16/32
  if b == 0xdc or b == 0xdd then
    local width = b == 0xdc and 2 or 4
    local count = read_count(buf, pos, width)
    if count == nil then
      return nil
    end
    return container_length(buf, pos, count, depth, 1 + width)
  end
  if b == 0xde or b == 0xdf then
    local width = b == 0xde and 2 or 4
    local count = read_count(buf, pos, width)
    if count == nil then
      return nil
    end
    return container_length(buf, pos, count * 2, depth, 1 + width)
  end
  -- bin8/16/32
  if b == 0xc4 then
    return sized_length(buf, pos, 1, depth)
  end
  if b == 0xc5 then
    return sized_length(buf, pos, 2, depth)
  end
  if b == 0xc6 then
    return sized_length(buf, pos, 4, depth)
  end
  -- ext8/16/32: length byte(s) + 1-byte type + payload
  if b == 0xc7 then
    return sized_length(buf, pos, 1, depth, 1)
  end
  if b == 0xc8 then
    return sized_length(buf, pos, 2, depth, 1)
  end
  if b == 0xc9 then
    return sized_length(buf, pos, 4, depth, 1)
  end

  return false
end

---Read an unsigned big-endian count of `width` bytes at `pos + 1`.
---@param buf string
---@param pos integer
---@param width integer
---@return integer|nil
function read_count(buf, pos, width)
  if #buf < pos + width then
    return nil
  end
  local count = 0
  for i = 1, width do
    count = count * 256 + buf:byte(pos + i)
  end
  return count
end

---Length of a str/bin/ext payload whose length header is `width` bytes.
---@param buf string
---@param pos integer
---@param width integer
---@param depth integer
---@param extra integer|nil extra bytes after the payload (ext type byte)
---@return integer|nil|boolean
function sized_length(buf, pos, width, depth, extra)
  extra = extra or 0
  local len = read_count(buf, pos, width)
  if len == nil then
    return nil
  end
  local total = 1 + width + extra + len
  if #buf < pos + total - 1 then
    return nil
  end
  return total
end

---Length of the container (array/map) starting at `pos`.
---@param buf string
---@param pos integer
---@param items integer|nil number of child values (nil = header incomplete)
---@param depth integer
---@param header integer header size in bytes (1, 3 or 5)
---@return integer|nil|boolean
function container_length(buf, pos, items, depth, header)
  if items == nil then
    return nil
  end
  local cursor = pos + (header or 1)
  for _ = 1, items do
    local len = value_length(buf, cursor, depth + 1)
    if len == nil then
      return nil
    end
    if len == false then
      return false
    end
    cursor = cursor + len
  end
  return cursor - pos
end

---Length of the complete msgpack value at `pos` (1-based).
---@param buf string
---@param pos integer|nil
---@return integer|nil len nil = incomplete
---@return boolean ok false = malformed bytes
function M.frame_length(buf, pos)
  local len = value_length(buf, pos or 1, 0)
  if len == nil then
    return nil, true
  end
  if len == false then
    return nil, false
  end
  return len, true
end

---Split the next complete msgpack value off the front of `buf`.
---
---Returns the raw frame, the remaining buffer and an error flag. A nil frame
---with `ok = true` means "need more data"; `ok = false` means the bytes are
---not valid msgpack and can never be framed.
---@param buf string
---@return string|nil frame
---@return string rest
---@return boolean ok
function M.next_frame(buf)
  local len, ok = M.frame_length(buf, 1)
  if not len then
    return nil, buf, ok
  end
  return buf:sub(1, len), buf:sub(len + 1), true
end

---Decoded message description: { kind, id, method, args } or nil.
---kind is "request" (0), "response" (1) or "notification" (2).
---@param frame string
---@return table|nil info
function M.message_info(frame)
  local ok, msg = pcall(vim.mpack.decode, frame)
  if not ok or type(msg) ~= 'table' then
    return nil
  end
  local t = msg[1]
  if t == 0 or t == 1 then
    return { kind = t, id = msg[2], method = msg[3], args = msg[4] }
  end
  if t == 2 then
    return { kind = t, method = msg[2], args = msg[3] }
  end
  return { kind = t }
end

---Is this a UI input notification that must NOT be replayed after an outage?
---@param info table|nil result of |M.message_info|
---@return boolean
function M.is_input(info)
  if not info or info.kind ~= 2 then
    return false
  end
  return info.method == 'nvim_input' or info.method == 'nvim_paste'
end

---Build a `redraw` notification carrying one UI event.
---@param name string UI event name
---@param args table event arguments
---@return string bytes
function M.encode_ui_event(name, args)
  return vim.mpack.encode({ 2, 'redraw', { { name, args } } })
end

---Set the client's terminal/window title (visible "reconnecting" hint).
---@param title string
---@return string bytes
function M.encode_title(title)
  return M.encode_ui_event('set_title', { title })
end

return M
