local M = {}

local instances = {}

local function emit(pattern, data)
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = pattern,
    data = data or {},
  })
end

local function notify(message, level, opts)
  if require("conduit.config").opts.notify then
    if opts and opts.background and opts.cwd then
      local dashboard_ok, dashboard = pcall(require, "conduit.dashboard")
      if dashboard_ok and dashboard.is_visible(opts.cwd) then
        return
      end
    end
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

local function model_config_option(config_options)
  local selected, selected_priority
  for _, option in ipairs(config_options or {}) do
    if option.type == "select" and (option.category == "model" or option.id == "model") then
      local priority = option.category == "model" and (option.id == "model" and 2 or 1) or 0
      if not selected or priority > selected_priority then
        selected, selected_priority = option, priority
      end
    end
  end
  return selected
end

local function values_from_option(option)
  if not option then
    return {}, nil
  end
  local models = {}
  for _, entry in ipairs(option.options or {}) do
    if entry.value then
      table.insert(models, { id = entry.value, name = entry.name or entry.value, description = entry.description })
    else
      for _, nested in ipairs(entry.options or {}) do
        if nested.value then
          table.insert(models, {
            id = nested.value,
            name = nested.name or nested.value,
            description = nested.description,
            group = entry.name,
          })
        end
      end
    end
  end
  return models, option.currentValue
end

local function thinking_config_option(config_options)
  for _, option in ipairs(config_options or {}) do
    if option.type == "select"
        and (option.category == "thought_level" or option.id == "reasoning_effort" or option.id == "thought_level") then
      return option
    end
  end
end

local function remember_session_files(instance, changed)
  local files = {}
  local seen = {}
  for _, path in ipairs(changed or {}) do
    if not seen[path] then
      table.insert(files, path)
      seen[path] = true
    end
  end
  for _, path in ipairs(instance.session_changed_files or {}) do
    if not seen[path] then
      table.insert(files, path)
      seen[path] = true
    end
  end
  instance.session_changed_files = files
end

local function models_from_legacy(state)
  if not state or type(state.availableModels) ~= "table" then
    return {}, nil
  end
  local models = {}
  for _, model in ipairs(state.availableModels) do
    if type(model) == "table" and model.modelId then
      table.insert(models, {
        id = model.modelId,
        name = model.name or model.modelId,
        description = model.description,
      })
    end
  end
  return models, state.currentModelId
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

local function permission_request(instance, params, respond)
  local options = params.options or {}
  local title = params.toolCall and params.toolCall.title or "Agent permission request"
  notify("Conduit: agent needs permission", vim.log.levels.WARN, {
    background = true,
    cwd = instance.cwd,
  })
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

local function on_request(instance, method, params, respond)
  if method == "session/request_permission" then
    permission_request(instance, params, respond)
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
      instance.config_options = session.configOptions or {}
      instance.legacy_models = session.models
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
    on_request = function(method, params, respond)
      on_request(instance, method, params, respond)
    end,
    on_notification = function(method, params)
      if method == "session/update" then
        instance.last_update = params.update
        if params.update and params.update.sessionUpdate == "config_option_update" then
          instance.config_options = params.update.configOptions or {}
        end
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
    acpx_waiters = {},
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
      notify("Conduit refresh failed: " .. tostring(changed), vim.log.levels.ERROR, {
        background = true,
        cwd = instance.cwd,
      })
      changed, skipped = {}, {}
    end
    if #skipped > 0 then
      notify("Conduit: kept " .. #skipped .. " modified buffer(s) unchanged", vim.log.levels.WARN, {
        background = true,
        cwd = instance.cwd,
      })
    end
    instance.last_changed_files = vim.deepcopy(changed)
    remember_session_files(instance, changed)
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
      notify("Conduit prompt failed: " .. turn_error, vim.log.levels.ERROR, {
        background = true,
        cwd = instance.cwd,
      })
    else
      notify("Conduit: agent finished (" .. stop_reason .. ")", nil, {
        background = true,
        cwd = instance.cwd,
      })
    end
    instance.finishing = false
    if on_complete then
      on_complete()
    end
  end)
end

local run_acpx_next
local turn_started

local function acpx_command(instance, ...)
  local command = vim.deepcopy(instance.adapter.client_command)
  vim.list_extend(command, {
    "--cwd", instance.cwd,
    "--" .. instance.adapter.permission_mode,
    "--format", "json",
    "--json-strict",
    instance.adapter.agent_name,
  })
  vim.list_extend(command, { ... })
  return command
end

local function acpx_watch_command(instance)
  local command = vim.deepcopy(instance.adapter.client_command)
  vim.list_extend(command, {
    "--cwd", instance.cwd,
    "--format", "json",
    "--json-strict",
    instance.adapter.agent_name,
    "sessions", "watch",
  })
  return command
end

local function acpx_json_command(instance, arguments, callback)
  local stdout, stderr = {}, {}
  local command = acpx_command(instance)
  vim.list_extend(command, arguments)
  local job = vim.fn.jobstart(command, {
    cwd = instance.cwd,
    env = instance.adapter.env,
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      vim.list_extend(stdout, data or {})
    end,
    on_stderr = function(_, data)
      vim.list_extend(stderr, data or {})
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        local errors = table.concat(vim.tbl_filter(function(line) return line ~= "" end, stderr), "\n")
        local result
        for index = #stdout, 1, -1 do
          if stdout[index] ~= "" then
            local ok, value = pcall(vim.json.decode, stdout[index])
            if ok and type(value) == "table" then
              result = value
              break
            end
          end
        end
        if code ~= 0 then
          local json_error = result and result.error
          local message = type(json_error) == "table" and json_error.message or json_error
          callback(nil, message or (errors ~= "" and errors) or ("acpx exited with code " .. code))
          return
        end
        if result then
          callback(result)
          return
        end
        callback(nil, errors ~= "" and errors or "acpx returned no JSON result")
      end)
    end,
  })
  if job <= 0 then
    callback(nil, "acpx is not executable")
  end
end

local function acpx_config_options(instance, callback)
  acpx_json_command(instance, { "sessions", "show" }, function(result, err)
    if not result then
      callback(nil, err)
      return
    end
    local options = result.acpx and result.acpx.config_options
    if type(options) ~= "table" then
      callback(nil, "agent session did not advertise configuration options", result)
      return
    end
    instance.config_options = options
    callback(options, nil, result)
  end)
end

local function finish_acpx_ensure(instance, err)
  local callbacks = instance.acpx_waiters
  instance.acpx_waiters = {}
  instance.acpx_ensuring = false
  if err then
    instance.state = "stopped"
    for _, callback in ipairs(callbacks) do
      callback(nil, err)
    end
    return
  end
  instance.acpx_ensured = true
  instance.state = "ready"
  emit("ConduitAgentReady", { cwd = instance.cwd, session_id = instance.session_id, transport = "acpx" })
  for _, callback in ipairs(callbacks) do
    callback(instance)
  end
end

local function ensure_acpx(instance, callback)
  if instance.acpx_ensured then
    callback(instance)
    return
  end
  table.insert(instance.acpx_waiters, callback)
  if instance.acpx_ensuring then
    return
  end
  instance.acpx_ensuring = true
  instance.state = "starting"
  emit("ConduitAgentStarting", { cwd = instance.cwd, transport = "acpx" })
  local stdout = {}
  local stderr = {}
  local job = vim.fn.jobstart(acpx_command(instance, "sessions", "ensure"), {
    cwd = instance.cwd,
    env = instance.adapter.env,
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      vim.list_extend(stdout, data or {})
    end,
    on_stderr = function(_, data)
      vim.list_extend(stderr, data or {})
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        instance.acpx_ensure_job = nil
        if code ~= 0 then
          local message = table.concat(vim.tbl_filter(function(line) return line ~= "" end, stderr), "\n")
          finish_acpx_ensure(instance, message ~= "" and message or ("acpx session ensure exited with code " .. code))
          return
        end
        for _, line in ipairs(stdout) do
          local ok, value = pcall(vim.json.decode, line)
          if ok and type(value) == "table" and value.acpxSessionId then
            instance.session_id = value.acpxSessionId
          end
        end
        finish_acpx_ensure(instance)
      end)
    end,
  })
  if job <= 0 then
    finish_acpx_ensure(instance, "acpx is not executable")
    return
  end
  instance.acpx_ensure_job = job
end

run_acpx_next = function(instance)
  if instance.state == "busy" or instance.refreshing or instance.finishing or #instance.queue == 0 then
    return
  end
  ensure_acpx(instance, function(ready, ensure_err)
    if not ready then
      notify("Conduit: " .. ensure_err, vim.log.levels.ERROR)
      return
    end
    if ready.state == "busy" or ready.refreshing or ready.finishing or #ready.queue == 0 then
      return
    end
    local prompt = table.remove(ready.queue, 1)
    local before = require("conduit.refresh").snapshot(ready.cwd)
    ready.state = "busy"
    ready.current_prompt = prompt
    turn_started(ready, #ready.queue)
    local stderr = {}
    local job = vim.fn.jobstart(acpx_command(ready, "prompt", "--file", "-"), {
      cwd = ready.cwd,
      env = ready.adapter.env,
      stdin = "pipe",
      stdout_buffered = false,
      stderr_buffered = true,
      on_stdout = function(_, data)
        for _, line in ipairs(data or {}) do
          if line ~= "" then
            local ok, value = pcall(vim.json.decode, line)
            if ok and type(value) == "table" then
              ready.last_update = value.params and value.params.update or value
            end
          end
        end
      end,
      on_stderr = function(_, data)
        vim.list_extend(stderr, data or {})
      end,
      on_exit = function(_, code)
        vim.schedule(function()
          ready.acpx_prompt_job = nil
          ready.state = "ready"
          ready.current_prompt = nil
          ready.refreshing = true
          local message
          if code ~= 0 then
            message = table.concat(vim.tbl_filter(function(line) return line ~= "" end, stderr), "\n")
            if message == "" then
              message = "acpx prompt exited with code " .. code
            end
          end
          refresh(ready, code == 0 and "end_turn" or "error", before, message, function()
            run_acpx_next(ready)
          end)
        end)
      end,
    })
    if job <= 0 then
      ready.state = "ready"
      ready.current_prompt = nil
      notify("Conduit: acpx is not executable", vim.log.levels.ERROR)
      run_acpx_next(ready)
      return
    end
    ready.acpx_prompt_job = job
    vim.fn.chansend(job, prompt)
    vim.fn.chanclose(job, "stdin")
  end)
end

local run_next
local finish_native_prompt

turn_started = function(instance, queue_length)
  emit("ConduitTurnStarted", {
    cwd = instance.cwd,
    session_id = instance.session_id,
    queue_length = queue_length,
    queue_owner = instance.adapter.transport == "acpx" and "acpx" or instance.adapter.queue_mode,
  })
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
  local acpx_instance, acpx_err = get_instance()
  if acpx_instance and acpx_instance.adapter.transport == "acpx" then
    table.insert(acpx_instance.queue, prompt)
    if acpx_instance.state == "starting" or acpx_instance.state == "busy" or acpx_instance.refreshing
        or acpx_instance.finishing or #acpx_instance.queue > 1 then
      local count = #acpx_instance.queue
      emit("ConduitPromptQueued", {
        cwd = acpx_instance.cwd,
        session_id = acpx_instance.session_id,
        queue_length = count,
        queue_owner = "client",
      })
    end
    run_acpx_next(acpx_instance)
    return
  elseif not acpx_instance then
    notify("Conduit: " .. acpx_err, vim.log.levels.ERROR)
    return
  end
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
  local instance, err = get_instance()
  if not instance then
    notify("Conduit: " .. err, vim.log.levels.ERROR)
    return
  end
  if instance.adapter.kind ~= "local" then
    notify("Conduit: remote agents do not have a local terminal", vim.log.levels.WARN)
    return
  end
  if instance.adapter.transport == "acpx" then
    ensure_acpx(instance, function(ready, ensure_err)
      if not ready then
        notify("Conduit: " .. ensure_err, vim.log.levels.ERROR)
        return
      end
      require("conduit.dashboard").open(ready.cwd, acpx_watch_command(ready), ready.adapter.env)
    end)
    return
  end
  local command = instance.adapter.terminal_command(instance.session_id)
  if not command or #command == 0 then
    notify("Conduit: this agent has no terminal command", vim.log.levels.ERROR)
    return
  end
  local identity = instance.session_id
  if instance.adapter.terminal_identity then
    identity = instance.adapter.terminal_identity(instance.session_id)
  end
  require("conduit.terminal").open(instance.cwd, command, instance.cwd, identity)
end

function M.cancel()
  local instance = get_instance()
  if instance and instance.adapter.transport == "acpx" and instance.state == "busy" then
    vim.fn.jobstart(acpx_command(instance, "cancel"), {
      cwd = instance.cwd,
      env = instance.adapter.env,
      detach = true,
    })
    notify("Conduit: cancellation requested")
    return
  end
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

---@param callback fun(models: table[]|nil, current: string|nil, err: string|nil)
function M.models(callback)
  local instance, err = get_instance()
  if not instance then
    callback(nil, nil, err)
    return
  end
  if instance.adapter.transport == "acpx" then
    ensure_acpx(instance, function(ready, ensure_err)
      if not ready then
        callback(nil, nil, ensure_err)
        return
      end
      acpx_config_options(ready, function(options, command_err, session)
        if not options then
          local acpx = session and session.acpx or {}
          local models = {}
          for _, id in ipairs(acpx.available_models or {}) do
            local names = acpx.available_model_names or {}
            table.insert(models, { id = id, name = names[id] or id })
          end
          if #models == 0 then
            callback(nil, nil, command_err)
            return
          end
          ready.model = acpx.current_model_id
          callback(models, acpx.current_model_id)
          return
        end
        local models, current = values_from_option(model_config_option(options))
        ready.model = current
        callback(models, current)
      end)
    end)
    return
  end
  ensure(function(ready, ensure_err)
    if not ready then
      callback(nil, nil, ensure_err)
      return
    end
    local option = model_config_option(ready.config_options)
    local models, current = values_from_option(option)
    if not option then
      models, current = models_from_legacy(ready.legacy_models)
    end
    ready.model = current
    callback(models, current)
  end)
end

---@param callback fun(levels: table[]|nil, current: string|nil, err: string|nil)
function M.thinking_levels(callback)
  local instance, err = get_instance()
  if not instance then
    callback(nil, nil, err)
    return
  end
  local function respond(ready, options)
    local levels, current = values_from_option(thinking_config_option(options))
    ready.thinking_level = current
    callback(levels, current)
  end
  if instance.adapter.transport == "acpx" then
    ensure_acpx(instance, function(ready, ensure_err)
      if not ready then
        callback(nil, nil, ensure_err)
        return
      end
      acpx_config_options(ready, function(options, command_err)
        if not options then
          callback(nil, nil, command_err)
          return
        end
        respond(ready, options)
      end)
    end)
    return
  end
  ensure(function(ready, ensure_err)
    if not ready then
      callback(nil, nil, ensure_err)
      return
    end
    respond(ready, ready.config_options)
  end)
end

---@param model_id string
---@param callback? fun(ok: boolean, err: string|nil)
function M.set_model(model_id, callback)
  callback = callback or function() end
  local instance, err = get_instance()
  if not instance then
    notify("Conduit: " .. err, vim.log.levels.ERROR)
    callback(false, err)
    return
  end
  local function changed(ready, result)
    ready.model = model_id
    if result and result.configOptions then
      ready.config_options = result.configOptions
    else
      local option = model_config_option(ready.config_options)
      if option then
        option.currentValue = model_id
      end
    end
    if ready.legacy_models then
      ready.legacy_models.currentModelId = model_id
    end
    emit("ConduitModelChanged", { cwd = ready.cwd, session_id = ready.session_id, model = model_id })
    notify("Conduit: model set to " .. model_id)
    callback(true)
  end
  if instance.adapter.transport == "acpx" then
    ensure_acpx(instance, function(ready, ensure_err)
      if not ready then
        notify("Conduit: " .. ensure_err, vim.log.levels.ERROR)
        callback(false, ensure_err)
        return
      end
      acpx_json_command(ready, { "set", "model", model_id }, function(result, command_err)
        if not result then
          notify("Conduit: could not set model: " .. command_err, vim.log.levels.ERROR)
          callback(false, command_err)
          return
        end
        changed(ready, result)
      end)
    end)
    return
  end
  ensure(function(ready, ensure_err)
    if not ready then
      notify("Conduit: " .. ensure_err, vim.log.levels.ERROR)
      callback(false, ensure_err)
      return
    end
    local option = model_config_option(ready.config_options)
    if not option and not ready.legacy_models then
      local message = "this agent did not advertise model selection"
      notify("Conduit: " .. message, vim.log.levels.WARN)
      callback(false, message)
      return
    end
    local method = option and "session/set_config_option" or "session/set_model"
    local params = option and {
      sessionId = ready.session_id,
      configId = option.id,
      value = model_id,
    } or {
      sessionId = ready.session_id,
      modelId = model_id,
    }
    ready.rpc:request(method, params, function(result, set_err)
      vim.schedule(function()
        if set_err then
          local message = error_message(set_err)
          notify("Conduit: could not set model: " .. message, vim.log.levels.ERROR)
          callback(false, message)
          return
        end
        changed(ready, result)
      end)
    end)
  end)
end

---@param level_id string
---@param callback? fun(ok: boolean, err: string|nil)
function M.set_thinking_level(level_id, callback)
  callback = callback or function() end
  local instance, err = get_instance()
  if not instance then
    notify("Conduit: " .. err, vim.log.levels.ERROR)
    callback(false, err)
    return
  end
  local function changed(ready, option, result)
    ready.thinking_level = level_id
    if result and result.configOptions then
      ready.config_options = result.configOptions
    else
      option.currentValue = level_id
    end
    emit("ConduitThinkingLevelChanged", {
      cwd = ready.cwd,
      session_id = ready.session_id,
      thinking_level = level_id,
    })
    notify("Conduit: thinking level set to " .. level_id)
    callback(true)
  end
  local function set_direct(ready, option)
    if not option then
      local message = "this agent did not advertise thinking-level selection"
      notify("Conduit: " .. message, vim.log.levels.WARN)
      callback(false, message)
      return
    end
    ready.rpc:request("session/set_config_option", {
      sessionId = ready.session_id,
      configId = option.id,
      value = level_id,
    }, function(result, set_err)
      vim.schedule(function()
        if set_err then
          local message = error_message(set_err)
          notify("Conduit: could not set thinking level: " .. message, vim.log.levels.ERROR)
          callback(false, message)
          return
        end
        changed(ready, option, result)
      end)
    end)
  end
  if instance.adapter.transport == "acpx" then
    ensure_acpx(instance, function(ready, ensure_err)
      if not ready then
        notify("Conduit: " .. ensure_err, vim.log.levels.ERROR)
        callback(false, ensure_err)
        return
      end
      acpx_config_options(ready, function(options, options_err)
        local option = options and thinking_config_option(options)
        if not option then
          local message = options_err or "this agent did not advertise thinking-level selection"
          notify("Conduit: " .. message, vim.log.levels.WARN)
          callback(false, message)
          return
        end
        acpx_json_command(ready, { "set", option.id, level_id }, function(result, command_err)
          if not result then
            notify("Conduit: could not set thinking level: " .. command_err, vim.log.levels.ERROR)
            callback(false, command_err)
            return
          end
          changed(ready, option, result)
        end)
      end)
    end)
    return
  end
  ensure(function(ready, ensure_err)
    if not ready then
      notify("Conduit: " .. ensure_err, vim.log.levels.ERROR)
      callback(false, ensure_err)
      return
    end
    set_direct(ready, thinking_config_option(ready.config_options))
  end)
end

---@param callback? fun(instance: table|nil, err: string|nil)
function M.new_session(callback)
  callback = callback or function() end
  local instance, err = get_instance()
  if not instance then
    notify("Conduit: " .. err, vim.log.levels.ERROR)
    callback(nil, err)
    return
  end
  if instance.state == "busy" or instance.state == "starting" or instance.refreshing or instance.finishing
      or #instance.queue > 0 or #instance.native_queue > 0 then
    local message = "wait for the active turn and queue before creating a new session"
    notify("Conduit: " .. message, vim.log.levels.WARN)
    callback(nil, message)
    return
  end
  local function created(ready, session)
    ready.session_id = session.sessionId or session.acpxSessionId or session.agentSessionId
    ready.config_options = session.configOptions or {}
    ready.legacy_models = session.models
    ready.model = nil
    ready.thinking_level = nil
    ready.last_changed_files = {}
    ready.session_changed_files = {}
    ready.state = "ready"
    ready.acpx_ensured = ready.adapter.transport == "acpx" or nil
    emit("ConduitSessionCreated", { cwd = ready.cwd, session_id = ready.session_id })
    notify("Conduit: created a new agent session")
    callback(ready)
  end
  if instance.adapter.transport == "acpx" then
    instance.state = "starting"
    acpx_json_command(instance, { "sessions", "new" }, function(result, command_err)
      if not result then
        instance.state = instance.acpx_ensured and "ready" or "stopped"
        notify("Conduit: could not create session: " .. command_err, vim.log.levels.ERROR)
        callback(nil, command_err)
        return
      end
      created(instance, result)
    end)
    return
  end
  ensure(function(ready, ensure_err)
    if not ready then
      notify("Conduit: " .. ensure_err, vim.log.levels.ERROR)
      callback(nil, ensure_err)
      return
    end
    ready.rpc:request("session/new", { cwd = ready.cwd, mcpServers = {} }, function(session, session_err)
      vim.schedule(function()
        if session_err or not session or not session.sessionId then
          local message = session_err and error_message(session_err) or "agent returned a session without an ID"
          notify("Conduit: could not create session: " .. message, vim.log.levels.ERROR)
          callback(nil, message)
          return
        end
        created(ready, session)
      end)
    end)
  end)
end

function M.stop_all()
  for _, instance in pairs(instances) do
    if instance.rpc then
      instance.rpc:stop()
    end
    if instance.acpx_ensure_job then
      pcall(vim.fn.jobstop, instance.acpx_ensure_job)
    end
    if instance.acpx_prompt_job then
      pcall(vim.fn.jobstop, instance.acpx_prompt_job)
    end
  end
  require("conduit.terminal").stop_all()
  require("conduit.dashboard").stop_all()
end

---@param cwd? string
function M.status(cwd)
  local instance, err
  if cwd then
    instance = instances[cwd]
    if not instance then
      return { state = "stopped", cwd = cwd, session_changed_files = {}, queued_prompts = {} }
    end
  else
    instance, err = get_instance()
  end
  if not instance then
    return { state = "unconfigured", error = err }
  end
  return {
    state = instance.refreshing and "refreshing" or instance.state,
    cwd = instance.cwd,
    session_id = instance.session_id,
    queue_length = #instance.queue + #instance.native_queue,
    queue_owner = instance.adapter.queue_mode,
    queued_prompts = vim.deepcopy(instance.queue),
    current_prompt = instance.current_prompt,
    model = instance.model,
    thinking_level = instance.thinking_level,
    last_changed_files = vim.deepcopy(instance.last_changed_files or {}),
    session_changed_files = vim.deepcopy(instance.session_changed_files or {}),
    busy = instance.state == "busy" or instance.refreshing or false,
    steering_supported = instance.steering_supported or false,
    transport = instance.adapter.transport or "direct",
  }
end

return M
