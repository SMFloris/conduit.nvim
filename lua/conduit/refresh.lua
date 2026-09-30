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

local function command_files(command, root)
  local result = vim.system(command, { cwd = root, text = false }):wait()
  if result.code ~= 0 then
    return nil
  end
  return vim.tbl_filter(function(path)
    return path ~= ""
  end, vim.split(result.stdout or "", "\0", { plain = true }))
end

local function project_files(root)
  local relative = command_files({ "git", "ls-files", "-co", "--exclude-standard", "-z" }, root)
  if not relative then
    relative = command_files({ "rg", "--files", "--hidden", "-g", "!.git", "-0" }, root) or {}
  end
  local result = {}
  for _, path in ipairs(relative) do
    result[vim.fs.normalize(root .. "/" .. path)] = true
  end
  return result
end

function M.snapshot(root)
  local result = {}
  for path in pairs(project_files(root)) do
    result[path] = signature(path)
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

  local after = M.snapshot(root)
  local changed_set = {}
  for path, current in pairs(after) do
    if before[path] ~= current then
      changed_set[path] = true
    end
  end
  for path in pairs(before) do
    if after[path] == nil then
      changed_set[path] = true
    end
  end

  local changed = vim.tbl_keys(changed_set)
  table.sort(changed)
  local skipped = {}
  for _, item in ipairs(project_buffers(root)) do
    if changed_set[item.path] then
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
