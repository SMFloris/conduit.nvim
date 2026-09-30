local M = {}

local function signature(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return "missing"
  end
  local mtime = stat.mtime or {}
  return table.concat({ stat.size or 0, mtime.sec or 0, mtime.nsec or 0 }, ":")
end

local function project_buffers(root)
  local result = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local path = vim.api.nvim_buf_get_name(buf)
    if vim.api.nvim_buf_is_loaded(buf) and path ~= "" and require("conduit.project").contains(root, path) then
      table.insert(result, { buf = buf, path = path })
    end
  end
  return result
end

function M.snapshot(root)
  local result = {}
  for _, item in ipairs(project_buffers(root)) do
    result[item.path] = signature(item.path)
  end
  return result
end

function M.run(root, before)
  local views = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    views[win] = {
      buf = vim.api.nvim_win_get_buf(win),
      view = vim.api.nvim_win_call(win, vim.fn.winsaveview),
    }
  end

  local changed = {}
  local skipped = {}
  for _, item in ipairs(project_buffers(root)) do
    if before[item.path] ~= signature(item.path) then
      table.insert(changed, item.path)
      if vim.bo[item.buf].modified then
        table.insert(skipped, item.path)
      else
        pcall(vim.cmd, "silent! checktime " .. item.buf)
      end
    end
  end

  for win, saved in pairs(views) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == saved.buf then
      pcall(vim.api.nvim_win_call, win, function()
        vim.fn.winrestview(saved.view)
      end)
    end
  end

  return changed, skipped
end

return M
