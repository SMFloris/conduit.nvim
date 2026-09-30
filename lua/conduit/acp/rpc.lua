local M = {}

---@class conduit.Rpc
---@field job number
---@field next_id number
---@field pending table<number, fun(result: any, err: any)>
---@field partial string
---@field stopped boolean
local Rpc = {}
Rpc.__index = Rpc

local function schedule(fn, ...)
  local args = { ... }
  vim.schedule(function()
    fn(unpack(args))
  end)
end

function Rpc:_send(message)
  if self.stopped or not self.job or self.job <= 0 then
    return false
  end
  local ok, encoded = pcall(vim.json.encode, message)
  if not ok then
    return false
  end
  vim.fn.chansend(self.job, encoded .. "\n")
  return true
end

function Rpc:_respond(id, result, err)
  if err then
    self:_send({ jsonrpc = "2.0", id = id, error = err })
  else
    self:_send({ jsonrpc = "2.0", id = id, result = result or vim.empty_dict() })
  end
end

function Rpc:_message(line)
  if line == "" then
    return
  end
  local ok, message = pcall(vim.json.decode, line)
  if not ok or type(message) ~= "table" then
    if self.opts.on_error then
      schedule(self.opts.on_error, "Invalid ACP message: " .. line)
    end
    return
  end

  if message.id ~= nil and not message.method then
    local callback = self.pending[message.id]
    if callback then
      self.pending[message.id] = nil
      schedule(callback, message.result, message.error)
    end
    return
  end

  if message.method and message.id ~= nil then
    if self.opts.on_request then
      schedule(self.opts.on_request, message.method, message.params or {}, function(result, err)
        self:_respond(message.id, result, err)
      end)
    else
      self:_respond(message.id, nil, { code = -32601, message = "Method not found" })
    end
    return
  end

  if message.method and self.opts.on_notification then
    schedule(self.opts.on_notification, message.method, message.params or {})
  end
end

function Rpc:_data(data)
  if not data then
    return
  end
  for index, chunk in ipairs(data) do
    if index == 1 then
      chunk = self.partial .. chunk
    end
    if index < #data then
      self:_message(chunk)
    else
      self.partial = chunk
    end
  end
end

function Rpc:request(method, params, callback)
  self.next_id = self.next_id + 1
  local id = self.next_id
  self.pending[id] = callback
  if not self:_send({ jsonrpc = "2.0", id = id, method = method, params = params or vim.empty_dict() }) then
    self.pending[id] = nil
    schedule(callback, nil, { code = -32000, message = "ACP transport is not running" })
  end
  return id
end

function Rpc:notify(method, params)
  self:_send({ jsonrpc = "2.0", method = method, params = params or vim.empty_dict() })
end

function Rpc:cancel_request(id)
  self:notify("$/cancel_request", { id = id })
end

function Rpc:stop()
  if self.stopped then
    return
  end
  self.stopped = true
  if self.job and self.job > 0 then
    vim.fn.jobstop(self.job)
  end
end

---@param opts table
---@return conduit.Rpc|nil, string|nil
function M.start(opts)
  local self = setmetatable({
    next_id = 0,
    pending = {},
    partial = "",
    stopped = false,
    opts = opts,
  }, Rpc)

  self.job = vim.fn.jobstart(opts.cmd, {
    cwd = opts.cwd,
    env = opts.env,
    stdin = "pipe",
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      self:_data(data)
    end,
    on_stderr = function(_, data)
      if opts.on_stderr and data then
        local lines = vim.tbl_filter(function(line)
          return line ~= ""
        end, data)
        if #lines > 0 then
          schedule(opts.on_stderr, table.concat(lines, "\n"))
        end
      end
    end,
    on_exit = function(_, code, signal)
      if self.stopped then
        return
      end
      self.stopped = true
      for id, callback in pairs(self.pending) do
        self.pending[id] = nil
        schedule(callback, nil, { code = -32001, message = "ACP agent exited (code " .. code .. ")" })
      end
      if opts.on_exit then
        schedule(opts.on_exit, code, signal)
      end
    end,
  })

  if self.job <= 0 then
    return nil, self.job == 0 and "Invalid ACP command" or "ACP command is not executable"
  end
  return self
end

return M
