local M = {}

local terminals = {}

local function hide_window(terminal)
  pcall(vim.cmd, "stopinsert")
  if terminal.win and vim.api.nvim_win_is_valid(terminal.win) then
    pcall(vim.api.nvim_win_close, terminal.win, true)
  end
  terminal.win = nil
end

local function dimensions(opts)
  local columns = vim.o.columns
  local lines = vim.o.lines - vim.o.cmdheight
  local width = opts.width <= 1 and math.floor(columns * opts.width) or opts.width
  local height = opts.height <= 1 and math.floor(lines * opts.height) or opts.height
  width = math.max(1, math.min(columns - 2, math.max(20, width)))
  height = math.max(1, math.min(lines - 2, math.max(3, height)))
  return width, height
end

local function open_window(terminal)
  if terminal.win and vim.api.nvim_win_is_valid(terminal.win) then
    vim.api.nvim_set_current_win(terminal.win)
    return
  end
  local opts = require("conduit.config").opts.terminal
  local width, height = dimensions(opts)
  terminal.win = vim.api.nvim_open_win(terminal.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = opts.border,
    title = opts.title,
    title_pos = opts.title_pos,
  })
  vim.wo[terminal.win].winhl = "Normal:NormalFloat,FloatBorder:FloatBorder"
  vim.cmd("startinsert")
end

local function set_hide_keymaps(terminal)
  local opts = require("conduit.config").opts.terminal
  if opts.close_key then
    vim.keymap.set("t", opts.close_key, function()
      hide_window(terminal)
    end, { buffer = terminal.buf, silent = true, desc = "Hide Conduit agent" })
  end
  if opts.normal_close_key then
    vim.keymap.set("n", opts.normal_close_key, function()
      hide_window(terminal)
    end, { buffer = terminal.buf, silent = true, desc = "Hide Conduit agent" })
  end
end

---@param key string
---@param command string[]
---@param cwd string
---@param identity? string
function M.open(key, command, cwd, identity)
  local terminal = terminals[key]
  if terminal and terminal.identity == identity and terminal.job and vim.fn.jobwait({ terminal.job }, 0)[1] == -1 then
    open_window(terminal)
    return
  end

  -- A restarted ACP process owns a new session. Do not leave the visible TUI
  -- attached to the dead session while prompts go somewhere else.
  if terminal then
    if terminal.job then
      pcall(vim.fn.jobstop, terminal.job)
    end
    if terminal.buf and vim.api.nvim_buf_is_valid(terminal.buf) then
      pcall(vim.api.nvim_buf_delete, terminal.buf, { force = true })
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "conduit_agent"
  pcall(vim.api.nvim_buf_set_name, buf, "conduit://agent/" .. vim.fn.sha256(key):sub(1, 12))
  terminal = { buf = buf, identity = identity }
  terminals[key] = terminal
  set_hide_keymaps(terminal)

  vim.api.nvim_buf_call(buf, function()
    terminal.job = vim.fn.termopen(command, {
      cwd = cwd,
      on_exit = function()
        terminal.job = nil
      end,
    })
  end)
  if terminal.job <= 0 then
    terminals[key] = nil
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    vim.notify("Unable to start agent terminal", vim.log.levels.ERROR)
    return
  end
  open_window(terminal)
end

---@param key string
function M.hide(key)
  local terminal = terminals[key]
  if terminal then
    hide_window(terminal)
  end
end

function M.stop_all()
  for _, terminal in pairs(terminals) do
    if terminal.job then
      pcall(vim.fn.jobstop, terminal.job)
    end
  end
end

return M
