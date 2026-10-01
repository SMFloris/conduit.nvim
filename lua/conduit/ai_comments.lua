local M = {}

local common_prefixes = {
  "//",
  "--",
  "/*",
  "*",
  "<!--",
}

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function strip_suffix(value, suffix)
  value = trim(value)
  for _, candidate in ipairs({ suffix, "*/", "-->" }) do
    candidate = trim(candidate or "")
    if candidate ~= "" and value:sub(-#candidate) == candidate then
      value = trim(value:sub(1, -#candidate - 1))
      break
    end
  end
  return value
end

local function directive(line, commentstring)
  local configured_prefix, configured_suffix = commentstring:match("^(.*)%%s(.*)$")
  configured_prefix = trim(configured_prefix or "")

  local prefixes = vim.deepcopy(common_prefixes)
  if configured_prefix ~= "" then
    table.insert(prefixes, 1, configured_prefix)
  end

  for _, prefix in ipairs(prefixes) do
    local start = line:match("^%s*" .. vim.pesc(prefix) .. "%s*@ai:%s*()")
    if start then
      return strip_suffix(line:sub(start), configured_suffix)
    end
  end
end

---@param bufnr? number
---@return { line: number, text: string }[]
function M.scan(bufnr)
  bufnr = bufnr or 0
  local commentstring = vim.bo[bufnr].commentstring or ""
  local found = {}
  for line_number, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local text = directive(line, commentstring)
    if text ~= nil then
      table.insert(found, { line = line_number, text = text })
    end
  end
  return found
end

return M
