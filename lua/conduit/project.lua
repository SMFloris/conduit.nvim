local M = {}

local function contains(root, path)
  root = vim.fs.normalize(root)
  path = vim.fs.normalize(path)
  if root == "/" then
    return path:sub(1, 1) == "/"
  end
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function lsp_root(buf, path)
  if not vim.lsp or not vim.lsp.get_clients then
    return nil
  end
  local roots = {}
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
    if type(client.config.root_dir) == "string" and contains(client.config.root_dir, path) then
      table.insert(roots, client.config.root_dir)
    end
    for _, folder in ipairs(client.workspace_folders or {}) do
      if folder.uri then
        local root = vim.uri_to_fname(folder.uri)
        if contains(root, path) then
          table.insert(roots, root)
        end
      end
    end
  end
  table.sort(roots, function(a, b)
    return #a > #b
  end)
  return roots[1]
end

local function context_buffer()
  local current = vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_get_name(current) ~= "" and vim.bo[current].buftype == "" then
    return current
  end
  local selected = current
  local latest = -1
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf) ~= "" then
      local info = vim.fn.getbufinfo(buf)[1]
      if info and info.lastused > latest then
        selected = buf
        latest = info.lastused
      end
    end
  end
  return selected
end

---@param agent_opts? table
---@return string
function M.root(agent_opts)
  agent_opts = agent_opts or (require("conduit.config").opts.agent or {})
  local configured = agent_opts.cwd
  if type(configured) == "function" then
    configured = configured()
  end
  if configured and configured ~= "" then
    local root = vim.fn.fnamemodify(configured, ":p")
    return #root > 1 and root:gsub("/$", "") or root
  end

  local buf = context_buffer()
  local name = vim.api.nvim_buf_get_name(buf)
  local path = name ~= "" and vim.fs.normalize(name) or vim.fn.getcwd()
  local root = lsp_root(buf, path)
  if not root then
    root = vim.fs.root(path, require("conduit.config").opts.root_markers)
  end
  root = root or vim.fn.getcwd()
  root = vim.fn.fnamemodify(root, ":p")
  return #root > 1 and root:gsub("/$", "") or root
end

function M.contains(root, path)
  return contains(root, path)
end

return M
