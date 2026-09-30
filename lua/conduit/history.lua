local M = {}

local loaded = false
local histories = {}
local navigation = {}

local function opts()
  return require("conduit.config").opts.history
end

local function history_path()
  return vim.fn.stdpath("state") .. "/conduit/history.json"
end

local function load()
  if loaded then
    return
  end
  loaded = true
  if not opts().persist then
    return
  end
  local ok, lines = pcall(vim.fn.readfile, history_path())
  if not ok or #lines == 0 then
    return
  end
  local decoded_ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if decoded_ok and type(decoded) == "table" then
    histories = decoded
  end
end

local function save()
  if not opts().persist then
    return
  end
  local path = history_path()
  local ok, encoded = pcall(vim.json.encode, histories)
  if not ok then
    return
  end
  pcall(vim.fn.mkdir, vim.fs.dirname(path), "p")
  pcall(vim.fn.writefile, { encoded }, path)
end

local function entries(root)
  load()
  histories[root] = histories[root] or {}
  return histories[root]
end

function M.add(prompt, root)
  if not opts().enabled or not prompt or prompt == "" then
    return
  end
  root = root or require("conduit.project").root()
  local list = entries(root)
  if list[#list] ~= prompt then
    table.insert(list, prompt)
  end
  while #list > opts().max_entries do
    table.remove(list, 1)
  end
  save()
end

local function replace_line(buf, value)
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { value })
  local win = vim.fn.bufwinid(buf)
  if win ~= -1 then
    vim.api.nvim_win_set_cursor(win, { 1, #value })
  end
end

local function move(buf, delta)
  local state = navigation[buf]
  if not state then
    return
  end
  local list = entries(state.root)
  if #list == 0 then
    return
  end
  if state.index == 0 then
    state.draft = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
  end
  state.index = math.max(0, math.min(#list, state.index + delta))
  if state.index == 0 then
    replace_line(buf, state.draft)
  else
    replace_line(buf, list[#list - state.index + 1])
  end
end

function M.setup_buffer(buf)
  if not opts().enabled then
    return
  end
  navigation[buf] = { root = require("conduit.project").root(), index = 0, draft = "" }
  local function completion_visible()
    if vim.fn.pumvisible() == 1 then
      return true
    end
    local blink = package.loaded["blink.cmp"]
    return blink and blink.is_visible and blink.is_visible()
  end
  vim.keymap.set({ "i", "n" }, "<Up>", function()
    if completion_visible() then
      return "<Up>"
    end
    move(buf, 1)
    return ""
  end, { buffer = buf, silent = true, expr = true, desc = "Older Conduit prompt" })
  vim.keymap.set({ "i", "n" }, "<Down>", function()
    if completion_visible() then
      return "<Down>"
    end
    move(buf, -1)
    return ""
  end, { buffer = buf, silent = true, expr = true, desc = "Newer Conduit prompt" })
  vim.api.nvim_create_autocmd("BufWipeout", {
    once = true,
    buffer = buf,
    callback = function()
      navigation[buf] = nil
    end,
  })
end

return M
