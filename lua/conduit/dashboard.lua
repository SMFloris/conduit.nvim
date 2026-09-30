local M = {}

local dashboards = {}
local autocmds_installed = false
local transcript_ns = vim.api.nvim_create_namespace("ConduitTranscript")

local function setup_highlights()
  local links = {
    ConduitTurn = "Title",
    ConduitUser = "DiagnosticInfo",
    ConduitThinking = "Comment",
    ConduitAssistant = "Identifier",
    ConduitToolRunning = "DiagnosticWarn",
    ConduitToolSuccess = "DiagnosticOk",
    ConduitToolFailed = "DiagnosticError",
    ConduitComplete = "DiagnosticOk",
    ConduitError = "DiagnosticError",
    ConduitMuted = "NonText",
  }
  for name, link in pairs(links) do
    vim.api.nvim_set_hl(0, name, { default = true, link = link })
  end
end

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function close_win(win)
  if valid_win(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
end

local function scroll_to_bottom(dashboard)
  vim.schedule(function()
    if valid_win(dashboard.watch_win) and dashboard.watch_buf
        and vim.api.nvim_buf_is_valid(dashboard.watch_buf) then
      local line_count = vim.api.nvim_buf_line_count(dashboard.watch_buf)
      pcall(vim.api.nvim_win_set_cursor, dashboard.watch_win, { math.max(1, line_count), 0 })
    end
  end)
end

local function add_item(dashboard, item)
  dashboard.transcript_items = dashboard.transcript_items or {}
  table.insert(dashboard.transcript_items, item)
  if item.key then
    dashboard.transcript_blocks[item.key] = item
  end
  if #dashboard.transcript_items > 500 then
    for _ = 1, 100 do
      table.remove(dashboard.transcript_items, 1)
    end
    dashboard.transcript_blocks = {}
    for _, current in ipairs(dashboard.transcript_items) do
      if current.key then
        dashboard.transcript_blocks[current.key] = current
      end
    end
  end
  return item
end

local function block(dashboard, key, kind)
  local item = dashboard.transcript_blocks[key]
  if not item then
    item = add_item(dashboard, { key = key, kind = kind, text = "" })
  end
  return item
end

local function text_value(value)
  if type(value) == "string" then
    return value
  end
  if type(value) ~= "table" then
    return value == nil and "" or tostring(value)
  end
  if type(value.text) == "string" then
    return value.text
  end
  local ok, encoded = pcall(vim.json.encode, value)
  return ok and encoded or vim.inspect(value)
end

local function content_text(content)
  if type(content) ~= "table" then
    return text_value(content)
  end
  if content.type then
    return text_value(content)
  end
  local parts = {}
  for _, value in ipairs(content) do
    local text = text_value(value)
    if text ~= "" then
      table.insert(parts, text)
    end
  end
  return table.concat(parts, "\n")
end

local function compact_detail(value, limit)
  local text = text_value(value):gsub("\r", "")
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  if #text > limit then
    text = text:sub(1, limit - 1) .. "…"
  end
  return text
end

local function render_transcript(dashboard)
  if not dashboard.watch_buf or not vim.api.nvim_buf_is_valid(dashboard.watch_buf) then
    return
  end
  local lines, highlights = {}, {}
  local function line(text, highlight)
    table.insert(lines, text)
    if highlight then
      table.insert(highlights, { #lines - 1, highlight })
    end
  end
  local function body(text, highlight, prefix)
    prefix = prefix or "  "
    local body_lines = vim.split((text or ""):gsub("\r", ""), "\n", { plain = true })
    for _, value in ipairs(body_lines) do
      line(prefix .. value, highlight)
    end
  end
  local rendered = 0
  for _, item in ipairs(dashboard.transcript_items or {}) do
    if not item.hidden then
      if rendered > 0 then
        line("")
      end
      rendered = rendered + 1
    end
    if item.hidden then
      -- Protocol-only turns stay out of the transcript.
    elseif item.kind == "turn" then
      line("━━ TURN  " .. (item.id or ""), "ConduitTurn")
    elseif item.kind == "user" then
      line("YOU", "ConduitUser")
      body(item.text, nil)
    elseif item.kind == "thinking" then
      line("THINKING", "ConduitThinking")
      body(item.text, "ConduitThinking")
    elseif item.kind == "assistant" then
      line("ASSISTANT", "ConduitAssistant")
      body(item.text, nil)
    elseif item.kind == "tool" then
      local status = item.status or "in_progress"
      local icon, highlight = "●", "ConduitToolRunning"
      if status == "completed" then
        icon, highlight = "✓", "ConduitToolSuccess"
      elseif status == "failed" or status == "cancelled" then
        icon, highlight = "✗", "ConduitToolFailed"
      end
      line(string.format("%s %s", icon, item.title or item.name or "Tool"), highlight)
      local input = compact_detail(item.raw_input, 240)
      if input ~= "" then
        body(input, "ConduitMuted", "  › ")
      end
      local output = compact_detail(item.raw_output, 600)
      if output ~= "" and (status == "failed" or item.show_output) then
        body(output, status == "failed" and "ConduitError" or "ConduitMuted", "  │ ")
      end
    elseif item.kind == "complete" then
      local reason = item.reason and (" · " .. item.reason) or ""
      line("✓ COMPLETED" .. reason, "ConduitComplete")
    elseif item.kind == "error" then
      line("✗ ERROR", "ConduitError")
      body(item.text, "ConduitError")
    elseif item.kind == "notice" then
      line(item.text or "", "ConduitMuted")
    end
  end
  if #lines == 0 then
    lines = { "Waiting for agent activity…" }
    highlights = { { 0, "ConduitMuted" } }
  end
  vim.bo[dashboard.watch_buf].modifiable = true
  vim.api.nvim_buf_set_lines(dashboard.watch_buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(dashboard.watch_buf, transcript_ns, 0, -1)
  for _, value in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(dashboard.watch_buf, transcript_ns, value[2], value[1], 0, -1)
  end
  vim.bo[dashboard.watch_buf].modifiable = false
  scroll_to_bottom(dashboard)
end

local function schedule_transcript_render(dashboard)
  if dashboard.render_pending then
    return
  end
  dashboard.render_pending = true
  vim.schedule(function()
    dashboard.render_pending = false
    render_transcript(dashboard)
  end)
end

local function meaningful_error(value)
  local message = text_value(value)
  if message:lower():find("no rollout found for thread id", 1, true) then
    return nil
  end
  return message ~= "" and message or nil
end

local function mark_turn_meaningful(dashboard, request_id)
  local turn = dashboard.turns[request_id]
  if turn then
    turn.meaningful = true
    turn.item.hidden = false
  end
end

local function apply_session_update(dashboard, request_id, update)
  local kind = update.sessionUpdate
  local message_id = update.messageId or "stream"
  if kind == "agent_message_chunk" or kind == "agent_thought_chunk" then
    local item_kind = kind == "agent_message_chunk" and "assistant" or "thinking"
    local key = table.concat({ request_id or "", message_id, item_kind }, ":")
    local item = block(dashboard, key, item_kind)
    item.text = item.text .. content_text(update.content)
    mark_turn_meaningful(dashboard, request_id)
  elseif kind == "tool_call" or kind == "tool_call_update" then
    local key = "tool:" .. tostring(update.toolCallId or update.title or #dashboard.transcript_items + 1)
    local item = block(dashboard, key, "tool")
    item.title = update.title or item.title
    item.name = update.name or item.name
    item.status = update.status or item.status
    item.raw_input = update.rawInput ~= nil and update.rawInput or item.raw_input
    item.raw_output = update.rawOutput ~= nil and update.rawOutput or item.raw_output
    item.show_output = update.rawOutput ~= nil or item.show_output or item.status == "failed"
    mark_turn_meaningful(dashboard, request_id)
  end
end

local function apply_watch_event(dashboard, event)
  local event_type = event.type
  local request_id = event.requestId or ""
  if event_type == "turn_started" then
    local item = add_item(dashboard, { kind = "turn", id = request_id:sub(1, 8), hidden = true })
    dashboard.turns[request_id] = { item = item, meaningful = false }
  elseif event_type == "turn_result" then
    local result = event.result or {}
    local turn = dashboard.turns[request_id]
    if result.status == "completed" and turn and turn.meaningful then
      add_item(dashboard, { kind = "complete", reason = result.stopReason })
    else
      local err = meaningful_error(result.error or result.message or result.status)
      if err and result.status ~= "completed" then
        mark_turn_meaningful(dashboard, request_id)
        add_item(dashboard, { kind = "error", text = err })
      end
    end
    dashboard.turns[request_id] = nil
  elseif event_type == "error" then
    local err = meaningful_error(event.error or event.message)
    if err then
      mark_turn_meaningful(dashboard, request_id)
      add_item(dashboard, { kind = "error", text = err })
    end
  elseif event_type == "message" and type(event.message) == "table" then
    local message = event.message
    if message.method == "session/prompt" then
      local prompt = content_text((message.params or {}).prompt)
      if prompt ~= "" then
        mark_turn_meaningful(dashboard, request_id)
        add_item(dashboard, { kind = "user", text = prompt })
      end
    elseif message.method == "session/update" then
      local params = message.params or {}
      if type(params.update) == "table" then
        apply_session_update(dashboard, request_id, params.update)
      end
    elseif message.error then
      local err = meaningful_error(message.error.message or message.error)
      if err then
        mark_turn_meaningful(dashboard, request_id)
        add_item(dashboard, { kind = "error", text = err })
      end
    end
  end
  schedule_transcript_render(dashboard)
end

local function consume_watch_data(dashboard, data)
  if not data or #data == 0 then
    return
  end
  local joined = (dashboard.watch_partial or "") .. table.concat(data, "\n")
  local lines = vim.split(joined, "\n", { plain = true })
  if data[#data] == "" then
    dashboard.watch_partial = ""
    table.remove(lines)
  else
    dashboard.watch_partial = table.remove(lines) or ""
  end
  for _, line in ipairs(lines) do
    if line ~= "" then
      local ok, event = pcall(vim.json.decode, line)
      if ok and type(event) == "table" then
        apply_watch_event(dashboard, event)
      end
    end
  end
end

local function hide(dashboard)
  pcall(vim.cmd, "stopinsert")
  close_win(dashboard.watch_win)
  close_win(dashboard.input_win)
  close_win(dashboard.queue_win)
  dashboard.watch_win = nil
  dashboard.input_win = nil
  dashboard.queue_win = nil
end

local function short_prompt(prompt, width)
  prompt = (prompt or ""):gsub("%s+", " ")
  if #prompt > width then
    return prompt:sub(1, math.max(1, width - 1)) .. "…"
  end
  return prompt
end

local function render_queue(dashboard)
  if not dashboard.queue_buf or not vim.api.nvim_buf_is_valid(dashboard.queue_buf) then
    return
  end
  local status = require("conduit.agent").status()
  local width = dashboard.queue_width or 30
  local lines = {
    status.busy and "● working" or (status.state == "starting" and "◐ starting" or "○ " .. status.state),
    "",
    "ACTIVE",
  }
  if status.current_prompt then
    table.insert(lines, short_prompt(status.current_prompt, width - 2))
  else
    table.insert(lines, "—")
  end
  table.insert(lines, "")
  table.insert(lines, string.format("QUEUE (%d)", #(status.queued_prompts or {})))
  for index, prompt in ipairs(status.queued_prompts or {}) do
    table.insert(lines, string.format("%d. %s", index, short_prompt(prompt, width - 5)))
  end
  if #(status.queued_prompts or {}) == 0 then
    table.insert(lines, "—")
  end
  vim.bo[dashboard.queue_buf].modifiable = true
  vim.api.nvim_buf_set_lines(dashboard.queue_buf, 0, -1, false, lines)
  vim.bo[dashboard.queue_buf].modifiable = false
end

local function render_all()
  for _, dashboard in pairs(dashboards) do
    render_queue(dashboard)
  end
end

local function install_autocmds()
  if autocmds_installed then
    return
  end
  autocmds_installed = true
  local group = vim.api.nvim_create_augroup("ConduitDashboard", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = {
      "ConduitAgentStarting",
      "ConduitAgentReady",
      "ConduitAgentExited",
      "ConduitTurnStarted",
      "ConduitTurnComplete",
      "ConduitPromptQueued",
      "ConduitQueueCleared",
    },
    callback = function()
      vim.schedule(render_all)
    end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = setup_highlights,
  })
end

local function insert_reference(dashboard, path)
  if not path or path == "" or not vim.api.nvim_buf_is_valid(dashboard.input_buf) then
    return
  end
  path = vim.fs.normalize(path)
  local prefix = vim.fs.normalize(dashboard.cwd) .. "/"
  if path:sub(1, #prefix) == prefix then
    path = path:sub(#prefix + 1)
  end
  local win = valid_win(dashboard.input_win) and dashboard.input_win or vim.fn.bufwinid(dashboard.input_buf)
  local row, col = 1, #(vim.api.nvim_buf_get_lines(dashboard.input_buf, 0, 1, false)[1] or "")
  if win and win ~= -1 then
    local cursor = vim.api.nvim_win_get_cursor(win)
    row, col = cursor[1], cursor[2]
  end
  local line = vim.api.nvim_buf_get_lines(dashboard.input_buf, row - 1, row, false)[1] or ""
  local reference = "@" .. path
  local before, after = line:sub(1, col), line:sub(col + 1)
  if before ~= "" and not before:match("%s$") then
    reference = " " .. reference
  end
  if after ~= "" and not after:match("^%s") then
    reference = reference .. " "
  else
    reference = reference .. " "
  end
  vim.api.nvim_buf_set_lines(dashboard.input_buf, row - 1, row, false, { before .. reference .. after })
  if win and win ~= -1 and valid_win(win) then
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { row, col + #reference })
    vim.cmd("startinsert")
  end
end

local function fallback_files(dashboard)
  vim.system({ "rg", "--files", "--hidden", "-g", "!.git" }, { cwd = dashboard.cwd, text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        vim.notify("Conduit: unable to list project files", vim.log.levels.ERROR)
        return
      end
      local files = vim.tbl_filter(function(line) return line ~= "" end, vim.split(result.stdout or "", "\n"))
      vim.ui.select(files, { prompt = "Reference project file: " }, function(choice)
        insert_reference(dashboard, choice)
      end)
    end)
  end)
end

local function pick_file(dashboard)
  local ok, snacks = pcall(require, "snacks")
  if ok and snacks.picker and snacks.picker.files then
    snacks.picker.files({
      cwd = dashboard.cwd,
      confirm = function(picker, item)
        picker:close()
        if item then
          vim.schedule(function()
            insert_reference(dashboard, item.file or item.text)
          end)
        end
      end,
    })
    return
  end
  fallback_files(dashboard)
end

local function submit(dashboard)
  local lines = vim.api.nvim_buf_get_lines(dashboard.input_buf, 0, -1, false)
  local prompt = table.concat(lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
  if prompt == "" then
    return
  end
  vim.api.nvim_buf_set_lines(dashboard.input_buf, 0, -1, false, { "" })
  require("conduit").submit(prompt)
  render_queue(dashboard)
end

local function set_keymaps(dashboard)
  local terminal_opts = require("conduit.config").opts.terminal
  local close_key = terminal_opts.close_key or "<C-q>"
  local normal_close_key = terminal_opts.normal_close_key or "q"
  local function close()
    hide(dashboard)
  end
  vim.keymap.set("n", close_key, close, { buffer = dashboard.watch_buf, silent = true, desc = "Hide Conduit" })
  vim.keymap.set("n", normal_close_key, close, { buffer = dashboard.watch_buf, silent = true, desc = "Hide Conduit" })
  vim.keymap.set("n", "<Esc>", close, { buffer = dashboard.watch_buf, silent = true, desc = "Hide Conduit" })
  for _, buf in ipairs({ dashboard.input_buf, dashboard.queue_buf }) do
    vim.keymap.set({ "n", "i" }, close_key, close, { buffer = buf, silent = true, desc = "Hide Conduit" })
    vim.keymap.set("n", normal_close_key, close, { buffer = buf, silent = true, desc = "Hide Conduit" })
    vim.keymap.set({ "n", "i" }, "<Esc>", close, { buffer = buf, silent = true, desc = "Hide Conduit" })
  end
  vim.keymap.set({ "n", "i" }, "<CR>", function()
    submit(dashboard)
  end, { buffer = dashboard.input_buf, silent = true, desc = "Submit Conduit prompt" })
  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    submit(dashboard)
  end, { buffer = dashboard.input_buf, silent = true, desc = "Submit Conduit prompt" })
  vim.keymap.set("i", "@", function()
    pick_file(dashboard)
  end, { buffer = dashboard.input_buf, silent = true, desc = "Reference project file" })
  vim.keymap.set("n", "@", function()
    pick_file(dashboard)
  end, { buffer = dashboard.input_buf, silent = true, desc = "Reference project file" })
end

local function create_buffers(dashboard)
  setup_highlights()
  dashboard.watch_buf = vim.api.nvim_create_buf(false, true)
  dashboard.input_buf = vim.api.nvim_create_buf(false, true)
  dashboard.queue_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[dashboard.watch_buf].bufhidden = "hide"
  vim.bo[dashboard.input_buf].bufhidden = "hide"
  vim.bo[dashboard.queue_buf].bufhidden = "hide"
  vim.bo[dashboard.input_buf].filetype = "conduit_ask"
  vim.bo[dashboard.watch_buf].filetype = "conduit_session"
  vim.bo[dashboard.watch_buf].modifiable = false
  vim.bo[dashboard.queue_buf].filetype = "conduit_queue"
  vim.bo[dashboard.queue_buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, dashboard.watch_buf, "conduit://watch/" .. vim.fn.sha256(dashboard.cwd):sub(1, 12))
  pcall(vim.api.nvim_buf_set_name, dashboard.input_buf, "conduit://prompt/" .. vim.fn.sha256(dashboard.cwd):sub(1, 12))
  pcall(vim.api.nvim_buf_set_name, dashboard.queue_buf, "conduit://queue/" .. vim.fn.sha256(dashboard.cwd):sub(1, 12))
  require("conduit.history").setup_buffer(dashboard.input_buf)
  dashboard.transcript_items = {}
  dashboard.transcript_blocks = {}
  dashboard.turns = {}
  render_transcript(dashboard)
  set_keymaps(dashboard)
end

local function start_watcher(dashboard, command, env)
  if dashboard.watch_job and vim.fn.jobwait({ dashboard.watch_job }, 0)[1] == -1 then
    return
  end
  dashboard.watch_job = vim.fn.jobstart(command, {
    cwd = dashboard.cwd,
    env = env,
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      consume_watch_data(dashboard, data)
    end,
    on_stderr = function(_, data)
      local message = table.concat(data or {}, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
      local err = meaningful_error(message)
      if err then
        add_item(dashboard, { kind = "error", text = err })
        schedule_transcript_render(dashboard)
      end
    end,
    on_exit = function(_, code)
      dashboard.watch_job = nil
      if code ~= 0 then
        add_item(dashboard, { kind = "notice", text = "Session watcher stopped (exit " .. code .. ")" })
        schedule_transcript_render(dashboard)
      end
    end,
  })
  if dashboard.watch_job <= 0 then
    dashboard.watch_job = nil
    vim.notify("Conduit: unable to start acpx session watcher", vim.log.levels.ERROR)
  end
end

local function open_windows(dashboard)
  local opts = require("conduit.config").opts.terminal
  local total_width = math.max(60, math.floor(vim.o.columns * (opts.width or 0.9)))
  local total_height = math.max(12, math.floor((vim.o.lines - vim.o.cmdheight) * (opts.height or 0.88)))
  total_width = math.min(total_width, vim.o.columns - 4)
  total_height = math.min(total_height, vim.o.lines - vim.o.cmdheight - 4)
  local queue_width = math.max(24, math.floor(total_width * 0.28))
  local main_width = total_width - queue_width - 1
  local input_height = math.min(4, math.max(3, total_height - 6))
  local watch_height = total_height - input_height - 1
  local row = math.max(0, math.floor((vim.o.lines - total_height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - total_width) / 2))
  dashboard.queue_width = queue_width

  dashboard.watch_win = vim.api.nvim_open_win(dashboard.watch_buf, false, {
    relative = "editor", row = row, col = col, width = main_width, height = watch_height,
    style = "minimal", border = opts.border, title = " ACP session ", title_pos = "center",
  })
  dashboard.input_win = vim.api.nvim_open_win(dashboard.input_buf, true, {
    relative = "editor", row = row + watch_height + 1, col = col, width = main_width, height = input_height,
    style = "minimal", border = opts.border, title = " Prompt  <CR> send  @ files ", title_pos = "left",
  })
  dashboard.queue_win = vim.api.nvim_open_win(dashboard.queue_buf, false, {
    relative = "editor", row = row, col = col + main_width + 1, width = queue_width, height = total_height,
    style = "minimal", border = opts.border, title = " Queue ", title_pos = "center",
  })
  vim.wo[dashboard.watch_win].winhl = "Normal:NormalFloat,FloatBorder:FloatBorder"
  vim.wo[dashboard.watch_win].scrolloff = 0
  vim.wo[dashboard.watch_win].wrap = true
  vim.wo[dashboard.watch_win].linebreak = true
  vim.wo[dashboard.watch_win].breakindent = true
  vim.wo[dashboard.watch_win].breakindentopt = "shift:2"
  vim.wo[dashboard.input_win].winhl = "Normal:NormalFloat,FloatBorder:FloatBorder"
  vim.wo[dashboard.queue_win].winhl = "Normal:NormalFloat,FloatBorder:FloatBorder"
  vim.wo[dashboard.queue_win].wrap = true
  vim.wo[dashboard.input_win].wrap = true
  render_queue(dashboard)
  scroll_to_bottom(dashboard)
  vim.api.nvim_set_current_win(dashboard.input_win)
  vim.cmd("startinsert")
end

---@param cwd string
---@param command string[]
---@param env? table<string,string>
function M.open(cwd, command, env)
  install_autocmds()
  local dashboard = dashboards[cwd]
  if dashboard and valid_win(dashboard.input_win) then
    vim.api.nvim_set_current_win(dashboard.input_win)
    vim.cmd("startinsert")
    return
  end
  if not dashboard then
    dashboard = { cwd = cwd }
    dashboards[cwd] = dashboard
    create_buffers(dashboard)
  end
  start_watcher(dashboard, command, env)
  open_windows(dashboard)
end

---@param cwd string
function M.hide(cwd)
  local dashboard = dashboards[cwd]
  if dashboard then
    hide(dashboard)
  end
end

---@param cwd string
---@return table|nil
function M.get(cwd)
  return dashboards[cwd]
end

function M.stop_all()
  for _, dashboard in pairs(dashboards) do
    if dashboard.watch_job then
      pcall(vim.fn.jobstop, dashboard.watch_job)
    end
  end
end

return M
