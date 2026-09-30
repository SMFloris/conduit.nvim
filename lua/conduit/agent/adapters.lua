local M = {}

local function copy(command)
  return vim.deepcopy(command or {})
end

local function append(command, ...)
  local result = copy(command)
  vim.list_extend(result, { ... })
  return result
end

local adapters = {
  opencode = {
    acp_command = function(opts)
      return opts.acp_cmd or append(opts.cmd or { "opencode" }, "acp")
    end,
    terminal_command = function(opts, session_id)
      return opts.terminal_cmd or append(opts.cmd or { "opencode" }, "--session", session_id)
    end,
  },
  codex = {
    acp_command = function(opts)
      return opts.acp_cmd or { "codex-acp" }
    end,
    terminal_command = function(opts, _)
      return opts.terminal_cmd or copy(opts.cmd or { "codex" })
    end,
  },
}

---@param opts table
---@return table|nil, string|nil
function M.resolve(opts)
  if not opts then
    return nil, "No Conduit agent is configured"
  end

  local kind = opts.type or "local"
  if kind == "remote" then
    if not opts.url then
      return nil, "Remote agents require `agent.url`"
    end
    local command = copy(opts.acp_cmd or { "websocat", "-t" })
    for key, value in pairs(opts.headers or {}) do
      vim.list_extend(command, { "-H", key .. ": " .. value })
    end
    table.insert(command, opts.url)
    return {
      kind = "remote",
      acp_command = command,
      queue_mode = opts.queue_mode or "client",
      env = opts.env,
    }
  end

  local name = opts.name
  if not name and type(opts.cmd) == "table" and opts.cmd[1] then
    name = vim.fn.fnamemodify(opts.cmd[1], ":t")
  end
  local adapter = adapters[name]
  if not adapter and not opts.acp_cmd then
    return nil, "Custom local agents require `agent.acp_cmd`"
  end
  adapter = adapter or {
    acp_command = function(config)
      return config.acp_cmd
    end,
    terminal_command = function(config, session_id)
      if type(config.terminal_cmd) == "function" then
        return config.terminal_cmd(session_id)
      end
      return config.terminal_cmd
    end,
  }

  return {
    kind = "local",
    acp_command = adapter.acp_command(opts),
    queue_mode = opts.queue_mode or (name == "codex" and "agent" or "client"),
    terminal_command = function(session_id)
      if type(opts.terminal_cmd) == "function" then
        return opts.terminal_cmd(session_id)
      end
      return adapter.terminal_command(opts, session_id)
    end,
    env = opts.env,
  }
end

return M
