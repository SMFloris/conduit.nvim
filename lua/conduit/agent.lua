local M = {}

local instances = {}

local function emit(pattern, data)
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = pattern,
    data = data or {},
  })
end

local function notify(message, level)
  if require("conduit.config").opts.notify then
    vim.notify(message, level or vim.log.levels.INFO)
  end
end

local function cwd_for(opts)
  return require("conduit.project").root(opts)
end

local function error_message(err)
  if type(err) == "table" then
    return err.message or vim.inspect(err)
  end
  return tostring(err)
end

local function fail(instance, message)
  instance.state = "stopped"
  if instance.rpc then
    instance.rpc:stop()
    instance.rpc = nil
  end
  notify("Conduit: " .. message, vim.log.levels.ERROR)
  local callbacks = instance.waiters or {}
  instance.waiters = {}
  for _, callback in ipairs(callbacks) do
    callback(nil, message)
  end
  emit("ConduitAgentExited", { cwd = instance.cwd, error = message })
end

local function permission_request(params, respond)
  local options = params.options or {}
  local title = params.toolCall and params.toolCall.title or "Agent permission request"
  vim.ui.select(options, {
    prompt = title .. ": ",
    format_item = function(option)
      return option.name or option.optionId
    end,
  }, function(choice)
    if choice then
      respond({ outcome = { outcome = "selected", optionId = choice.optionId } })
    else
      respond({ outcome = { outcome = "cancelled" } })
    end
  end)
end

local function on_request(method, params, respond)
  if method == "session/request_permission" then
    permission_request(params, respond)
    return
  end
  respond(nil, { code = -32601, message = "Conduit does not implement " .. method })
end

local function initialize(instance)
  instance.rpc:request("initialize", {
    protocolVersion = 1,
    clientCapabilities = {
      fs = { readTextFile = false, writeTextFile = false },
      terminal = false,
      auth = { terminal = false },
    },
    clientInfo = { name = "conduit.nvim", version = "0.2.0" },
  }, function(result, err)
    if err then
      fail(instance, "ACP initialization failed: " .. error_message(err))
      return
    end
    instance.capabilities = result and result.agentCapabilities or {}
    instance.steering_supported = result
        and result._meta
        and result._meta.steering
        and result._meta.steering.supported == true
    instance.rpc:request("session/new", {
      cwd = instance.cwd,
      mcpServers = {},
    }, function(session, session_err)
      if session_err then
        fail(instance, "Could not create ACP session: " .. error_message(session_err))
        return
      end
      if not session or not session.sessionId then
        fail(instance, "ACP agent returned a session without an ID")
        return
      end
      instance.session_id = session.sessionId
      instance.state = "ready"
      emit("ConduitAgentReady", { cwd = instance.cwd, session_id = instance.session_id })
      local callbacks = instance.waiters
      instance.waiters = {}
      for _, callback in ipairs(callbacks) do
        callback(instance)
      end
    end)
  end)
end

local function start(instance)
  emit("ConduitAgentStarting", { cwd = instance.cwd })
  local Rpc = require("conduit.acp.rpc")
  local rpc, err = Rpc.start({
    cmd = instance.adapter.acp_command,
    cwd = instance.cwd,
    env = instance.adapter.env,
    on_request = on_request,
    on_notification = function(method, params)
      if method == "session/update" then
        instance.last_update = params.update
      end
    end,
    on_stderr = function(line)
      instance.stderr = line
    end,
    on_error = function(message)
      notify("Conduit: " .. message, vim.log.levels.ERROR)
    end,
    on_exit = function(code)
      local session_id = instance.session_id
      if instance.active_native_prompt then
        instance.active_native_prompt.cancelled = true
      end
      for _, entry in ipairs(instance.native_queue) do
        entry.cancelled = true
      end
      instance.active_native_prompt = nil
      instance.native_queue = {}
      instance.queue = {}
      instance.rpc = nil
      instance.session_id = nil
      instance.state = "stopped"
      instance.current_prompt = nil
      emit("ConduitAgentExited", { cwd = instance.cwd, session_id = session_id, code = code })
      if code ~= 0 then
        local suffix = instance.stderr and (": " .. instance.stderr) or ""
        notify("Conduit ACP agent exited with code " .. code .. suffix, vim.log.levels.WARN)
      end
    end,
  })
  if not rpc then
    fail(instance, err)
    return
  end
  instance.rpc = rpc
  initialize(instance)
end

local function get_instance()
  local opts = require("conduit.config").opts.agent
  if not opts then
    return nil, "No agent configured"
  end
  local cwd = cwd_for(opts)
  if instances[cwd] then
    return instances[cwd]
  end
  local adapter, err = require("conduit.agent.adapters").resolve(opts)
  if not adapter then
    return nil, err
  end
  local instance = {
    cwd = cwd,
    adapter = adapter,
    state = "stopped",
    waiters = {},
    queue = {},
    native_queue = {},
  }
  instances[cwd] = instance
  return instance
end

local function ensure(callback)
  local instance, err = get_instance()
  if not instance then
    callback(nil, err)
    return
  end
  if instance.state == "ready" or instance.state == "busy" then
    callback(instance)
    return
  end
  table.insert(instance.waiters, callback)
  if instance.state == "starting" then
    return
  end
  instance.state = "starting"
  start(instance)
end

local function refresh(instance, stop_reason, before, turn_error, on_complete)
  vim.schedule(function()
    local ok, changed, skipped = pcall(require("conduit.refresh").run, instance.cwd, before)
    if not ok then
      notify("Conduit refresh failed: " .. tostring(changed), vim.log.levels.ERROR)
      changed, skipped = {}, {}
    end
    if #skipped > 0 then
      notify("Conduit: kept " .. #skipped .. " modified buffer(s) unchanged", vim.log.levels.WARN)
    end
    instance.refreshing = false
    instance.finishing = true
    emit("ConduitTurnComplete", {
      cwd = instance.cwd,
      session_id = instance.session_id,
      stop_reason = stop_reason,
      changed_files = changed,
      skipped_files = skipped,
      error = turn_error,
    })
    if turn_error then
      notify("Conduit prompt failed: " .. turn_error, vim.log.levels.ERROR)
    else
      notify("Conduit: agent finished (" .. stop_reason .. ")")
    end
    instance.finishing = false
    if on_complete then
      on_complete()
    end
  end)
end

local run_next
local finish_native_prompt

local function turn_started(instance, queue_length)
  emit("ConduitTurnStarted", {
    cwd = instance.cwd,
    session_id = instance.session_id,
    queue_length = queue_length,
    queue_owner = instance.adapter.queue_mode,
  })
  notify("Conduit: agent is working")
end

local function send_prompt(instance, prompt)
  instance.state = "busy"
  instance.current_prompt = prompt
  local before = require("conduit.refresh").snapshot(instance.cwd)
  turn_started(instance, #instance.queue)
  instance.rpc:request("session/prompt", {
    sessionId = instance.session_id,
    prompt = { { type = "text", text = prompt } },
  }, function(result, err)
    instance.state = "ready"
    instance.refreshing = true
    instance.current_prompt = nil
    if err then
      refresh(instance, "error", before, error_message(err), function()
        run_next(instance)
      end)
    else
      local reason = result and result.stopReason or "end_turn"
      refresh(instance, reason, before, nil, function()
        run_next(instance)
      end)
    end
  end)
end

local function activate_native_prompt(instance, entry)
  instance.active_native_prompt = entry
  instance.state = "busy"
  instance.current_prompt = entry.prompt
  turn_started(instance, #instance.native_queue)
  if entry.done then
    finish_native_prompt(instance, entry, entry.result, entry.err)
  end
end

finish_native_prompt = function(instance, entry, result, err)
  if entry.cancelled then
    return
  end
  if instance.active_native_prompt ~= entry then
    entry.done = true
    entry.result = result
    entry.err = err
    return
  end

  instance.state = "ready"
  instance.refreshing = true
  instance.current_prompt = nil
  local reason = err and "error" or (result and result.stopReason or "end_turn")
  refresh(instance, reason, entry.before, err and error_message(err) or nil, function()
    if instance.state == "stopped" or not instance.rpc then
      instance.active_native_prompt = nil
      return
    end
    instance.active_native_prompt = nil
    local next_entry = table.remove(instance.native_queue, 1)
    if next_entry then
      activate_native_prompt(instance, next_entry)
    else
      instance.state = "ready"
    end
  end)
end

local function submit_native(instance, prompt)
  local entry = {
    prompt = prompt,
    -- The agent owns the start time, so snapshot on acceptance. This may
    -- conservatively include changes from an earlier queued turn, but cannot
    -- miss a file changed before Conduit observes the next turn starting.
    before = require("conduit.refresh").snapshot(instance.cwd),
  }
  local queued = instance.active_native_prompt ~= nil
  if queued then
    table.insert(instance.native_queue, entry)
  else
    activate_native_prompt(instance, entry)
  end

  entry.request_id = instance.rpc:request("session/prompt", {
    sessionId = instance.session_id,
    prompt = { { type = "text", text = prompt } },
  }, function(result, err)
    finish_native_prompt(instance, entry, result, err)
  end)

  if queued then
    local count = #instance.native_queue
    notify("Conduit: prompt queued by agent (" .. count .. " waiting)")
    emit("ConduitPromptQueued", {
      cwd = instance.cwd,
      session_id = instance.session_id,
      queue_length = count,
      queue_owner = "agent",
      request_id = entry.request_id,
    })
  end
end

run_next = function(instance)
  if instance.state ~= "ready" or instance.refreshing or instance.finishing or #instance.queue == 0 then
    return
  end
  send_prompt(instance, table.remove(instance.queue, 1))
end

---@param prompt string
function M.submit(prompt)
  ensure(function(instance, err)
    if not instance then
      notify("Conduit: " .. err, vim.log.levels.ERROR)
      return
    end
    if instance.adapter.queue_mode == "agent" then
      submit_native(instance, prompt)
      return
    end
    table.insert(instance.queue, prompt)
    if instance.state == "busy" or instance.refreshing or instance.finishing then
      local count = #instance.queue
      notify("Conduit: prompt queued (" .. count .. " waiting)")
      emit("ConduitPromptQueued", {
        cwd = instance.cwd,
        session_id = instance.session_id,
        queue_length = count,
        queue_owner = "client",
      })
    end
    run_next(instance)
  end)
end

function M.open_terminal()
  ensure(function(instance, err)
    if not instance then
      notify("Conduit: " .. err, vim.log.levels.ERROR)
      return
    end
    if instance.adapter.kind ~= "local" then
      notify("Conduit: remote agents do not have a local terminal", vim.log.levels.WARN)
      return
    end
    local command = instance.adapter.terminal_command(instance.session_id)
    if not command or #command == 0 then
      notify("Conduit: this agent has no terminal command", vim.log.levels.ERROR)
      return
    end
    require("conduit.terminal").open(instance.cwd, command, instance.cwd, instance.session_id)
  end)
end

function M.cancel()
  local instance = get_instance()
  if instance and instance.rpc and instance.session_id and instance.state == "busy" then
    instance.rpc:notify("session/cancel", { sessionId = instance.session_id })
    notify("Conduit: cancellation requested")
  end
end

function M.clear_queue()
  local instance = get_instance()
  if not instance then
    return 0
  end
  local count = #instance.queue + #instance.native_queue
  instance.queue = {}
  for _, entry in ipairs(instance.native_queue) do
    entry.cancelled = true
    if entry.request_id then
      instance.rpc:cancel_request(entry.request_id)
    end
  end
  instance.native_queue = {}
  if count > 0 then
    notify("Conduit: cleared " .. count .. " queued prompt(s)")
    emit("ConduitQueueCleared", {
      cwd = instance.cwd,
      session_id = instance.session_id,
      queue_length = 0,
      queue_owner = instance.adapter.queue_mode,
      cleared = count,
    })
  end
  return count
end

function M.stop_all()
  for _, instance in pairs(instances) do
    if instance.rpc then
      instance.rpc:stop()
    end
  end
  require("conduit.terminal").stop_all()
end

function M.status()
  local instance, err = get_instance()
  if not instance then
    return { state = "unconfigured", error = err }
  end
  return {
    state = instance.refreshing and "refreshing" or instance.state,
    cwd = instance.cwd,
    session_id = instance.session_id,
    queue_length = #instance.queue + #instance.native_queue,
    queue_owner = instance.adapter.queue_mode,
    busy = instance.state == "busy" or instance.refreshing or false,
    steering_supported = instance.steering_supported or false,
  }
end

return M
