local M = {}

local dashboards = {}
local autocmds_installed = false

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function close_win(win)
  if valid_win(win) then
    pcall(vim.api.nvim_win_close, win, true)
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
  vim.keymap.set("t", close_key, close, { buffer = dashboard.watch_buf, silent = true, desc = "Hide Conduit" })
  vim.keymap.set("n", close_key, close, { buffer = dashboard.watch_buf, silent = true, desc = "Hide Conduit" })
  vim.keymap.set("n", normal_close_key, close, { buffer = dashboard.watch_buf, silent = true, desc = "Hide Conduit" })
  for _, buf in ipairs({ dashboard.input_buf, dashboard.queue_buf }) do
    vim.keymap.set({ "n", "i" }, close_key, close, { buffer = buf, silent = true, desc = "Hide Conduit" })
    vim.keymap.set("n", normal_close_key, close, { buffer = buf, silent = true, desc = "Hide Conduit" })
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
  dashboard.watch_buf = vim.api.nvim_create_buf(false, true)
  dashboard.input_buf = vim.api.nvim_create_buf(false, true)
  dashboard.queue_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[dashboard.watch_buf].bufhidden = "hide"
  vim.bo[dashboard.input_buf].bufhidden = "hide"
  vim.bo[dashboard.queue_buf].bufhidden = "hide"
  vim.bo[dashboard.input_buf].filetype = "conduit_ask"
  vim.bo[dashboard.queue_buf].filetype = "conduit_queue"
  vim.bo[dashboard.queue_buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, dashboard.watch_buf, "conduit://watch/" .. vim.fn.sha256(dashboard.cwd):sub(1, 12))
  pcall(vim.api.nvim_buf_set_name, dashboard.input_buf, "conduit://prompt/" .. vim.fn.sha256(dashboard.cwd):sub(1, 12))
  pcall(vim.api.nvim_buf_set_name, dashboard.queue_buf, "conduit://queue/" .. vim.fn.sha256(dashboard.cwd):sub(1, 12))
  require("conduit.history").setup_buffer(dashboard.input_buf)
  set_keymaps(dashboard)
end

local function start_watcher(dashboard, command, env)
  if dashboard.watch_job and vim.fn.jobwait({ dashboard.watch_job }, 0)[1] == -1 then
    return
  end
  vim.api.nvim_buf_call(dashboard.watch_buf, function()
    dashboard.watch_job = vim.fn.termopen(command, {
      cwd = dashboard.cwd,
      env = env,
      on_exit = function()
        dashboard.watch_job = nil
      end,
    })
  end)
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
  vim.wo[dashboard.input_win].winhl = "Normal:NormalFloat,FloatBorder:FloatBorder"
  vim.wo[dashboard.queue_win].winhl = "Normal:NormalFloat,FloatBorder:FloatBorder"
  vim.wo[dashboard.queue_win].wrap = true
  vim.wo[dashboard.input_win].wrap = true
  render_queue(dashboard)
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
