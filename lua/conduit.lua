local M = {}

local configured = false

local function set_keymaps()
  if configured then
    return
  end
  configured = true
  local keymaps = require("conduit.config").opts.keymaps
  if keymaps == false then
    return
  end
  if keymaps.ask then
    vim.keymap.set("n", keymaps.ask, function()
      M.ask("@cursor: ")
    end, { desc = "Prompt Conduit agent at cursor" })
    vim.keymap.set("v", keymaps.ask, function()
      M.ask("@selection: ")
    end, { desc = "Prompt Conduit agent about selection" })
  end
  if keymaps.ai_comments then
    vim.keymap.set("n", keymaps.ai_comments, M.resolve_ai_comments, { desc = "Resolve @ai comments with Conduit" })
  end
  if keymaps.toggle then
    vim.keymap.set("n", keymaps.toggle, M.open_agent, { desc = "Open Conduit agent" })
  end
  if keymaps.prompts then
    vim.keymap.set({ "n", "v" }, keymaps.prompts, M.select_prompt, { desc = "Select Conduit prompt" })
  end
  if keymaps.modified_files then
    vim.keymap.set("n", keymaps.modified_files, M.modified_files, { desc = "Files modified in Conduit session" })
  end
  if keymaps.models then
    vim.keymap.set("n", keymaps.models, M.select_model, { desc = "Select Conduit model and thinking level" })
  end
  if keymaps.cancel then
    vim.keymap.set("n", keymaps.cancel, M.cancel, { desc = "Cancel Conduit agent turn" })
  end
  if keymaps.clear_queue then
    vim.keymap.set("n", keymaps.clear_queue, M.clear_queue, { desc = "Clear queued Conduit prompts" })
  end
end

---@param opts? conduit.Opts
function M.setup(opts)
  require("conduit.config").setup(opts)
  configured = false
  set_keymaps()
  if vim.fn.exists(":ConduitHealth") == 0 then
    vim.api.nvim_create_user_command("ConduitHealth", function()
      vim.cmd("checkhealth conduit")
    end, { desc = "Check Conduit agent configuration and runtime" })
  end
  local group = vim.api.nvim_create_augroup("ConduitLifecycle", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      require("conduit.agent").stop_all()
    end,
  })
end

--- Process a prompt with context injection and copy to clipboard.
--- This function takes a raw prompt string, injects context placeholders
--- (like @buffer, @cursor, @diagnostics) with actual editor state,
--- and copies the final prompt to the system clipboard ('+' register).
---
---@param prompt string The raw prompt string containing context placeholders
function M.prompt(prompt)
  prompt = require("conduit.context").inject(prompt)
  local notify = require("conduit.config").opts.notify
  if prompt and prompt ~= "" then
    vim.fn.setreg('+', prompt)
    if notify then
      vim.notify("Prompt copied to clipboard", vim.log.levels.INFO)
    end
  end
end

---Expand a prompt and submit it to the configured ACP agent. If no agent is
---configured, preserve the original clipboard-based behaviour.
---@param prompt string
function M.submit(prompt)
  require("conduit.history").add(prompt)
  if require("conduit.config").opts.agent then
    prompt = require("conduit.context").inject(prompt)
    require("conduit.agent").submit(prompt)
  else
    M.prompt(prompt)
  end
end

---Input a prompt to copy to the '+' register.
--- - Highlights `opts.contexts` in the input.
---@param default? string Text to prefill the input with.
function M.ask(default)
  require("conduit.input").input(
    default, function(value)
      if value and value ~= "" then
        M.submit(value)
      end
    end
  )
end

---Select a prompt from `opts.prompts` to copy to the '+' register.
---Filters prompts based on visual mode: shows only @selection prompts when text is selected,
---and only non-@selection prompts when no text is selected.
---@param default? string Prompt to use.
function M.select_prompt(default)
  if default and default ~= "" then
    ---@type conduit.Prompt
    local choice = require("conduit.config").opts.prompts[default]
    if choice then
      M.submit(choice.prompt)
    else
      vim.notify("Prompt '" .. default .. "' not found", vim.log.levels.WARN)
    end
  else
    ---@type conduit.Prompt[]
    local prompts = vim.tbl_filter(function(prompt)
      if not prompt then
        return false
      end
      local is_visual = vim.fn.mode():match("[vV\22]")
      -- WARNING: Technically depends on user using built-in `@selection` context by name...
      local does_prompt_use_visual = prompt.prompt:match("@selection")
      if is_visual then
        return does_prompt_use_visual
      else
        return not does_prompt_use_visual
      end
    end, vim.tbl_values(require("conduit.config").opts.prompts))

    vim.ui.select(
      prompts,
      {
        prompt = "Prompt conduit: ",
        ---@param item conduit.Prompt
        format_item = function(item)
          return item.description
        end
      },
      ---@param choice conduit.Prompt
      function(choice)
        if choice then
          M.submit(choice.prompt)
        end
      end
    )
  end
end

---Open or focus the persistent native terminal for the configured local agent.
function M.open_agent()
  require("conduit.agent").open_terminal()
end

function M.cancel()
  require("conduit.agent").cancel()
end

function M.clear_queue()
  return require("conduit.agent").clear_queue()
end

---Submit every `@ai:` comment in the current file as an agent task.
function M.resolve_ai_comments()
  local bufnr = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" or vim.bo[bufnr].buftype ~= "" then
    vim.notify("Conduit: @ai comments require a named file buffer", vim.log.levels.WARN)
    return
  end

  local directives = require("conduit.ai_comments").scan(bufnr)
  if #directives == 0 then
    vim.notify("Conduit: no @ai: comments found in this buffer", vim.log.levels.INFO)
    return
  end
  if vim.bo[bufnr].modified or not vim.uv.fs_stat(path) then
    vim.notify("Conduit: save the buffer before resolving @ai comments", vim.log.levels.WARN)
    return
  end

  local root = require("conduit.project").root()
  path = vim.fs.normalize(path)
  local prefix = vim.fs.normalize(root) .. "/"
  local target = path:sub(1, #prefix) == prefix and path:sub(#prefix + 1) or path
  target = (require("conduit.config").opts.file_prefix or "") .. target

  local tasks = {}
  for _, item in ipairs(directives) do
    table.insert(tasks, string.format("- line %d: %s", item.line, item.text ~= "" and item.text or "(no description)"))
  end

  M.submit(table.concat({
    "Resolve every @ai: directive in " .. target .. ".",
    "Treat each directive as a coding task. Implement the requested changes in the file or project, "
      .. "then remove the entire comment containing that directive. Do not leave any @ai: markers behind. "
      .. "Preserve unrelated behavior.",
    "",
    "Directives:",
    table.concat(tasks, "\n"),
  }, "\n"))
end

function M.new_session()
  require("conduit.agent").new_session(function(instance)
    if instance then
      require("conduit.dashboard").restart(instance.cwd)
    end
  end)
end

function M.status()
  return require("conduit.agent").status()
end

function M.modified_files()
  local status = require("conduit.agent").status()
  local files = status.session_changed_files or {}
  if #files == 0 then
    vim.notify("Conduit: the current agent session has not modified project files", vim.log.levels.INFO)
    return
  end
  local root = status.cwd or require("conduit.project").root()
  local git_available = false
  if vim.fn.executable("git") == 1 then
    local result = vim.system(
      { "git", "rev-parse", "--is-inside-work-tree" },
      { cwd = root, text = true }
    ):wait()
    git_available = result.code == 0 and vim.trim(result.stdout or "") == "true"
  end
  local function open(path)
    if not path then
      return
    end
    if not vim.uv.fs_stat(path) then
      vim.notify("Conduit: file no longer exists: " .. path, vim.log.levels.WARN)
      return
    end
    vim.cmd.edit(vim.fn.fnameescape(path))
  end
  local snacks_ok, snacks = pcall(require, "snacks")
  if snacks_ok and snacks.picker and snacks.picker.pick then
    local items = {}
    for index, path in ipairs(files) do
      local absolute = vim.fs.normalize(path)
      local relative = absolute
      local prefix = vim.fs.normalize(root) .. "/"
      if absolute:sub(1, #prefix) == prefix then
        relative = absolute:sub(#prefix + 1)
      end
      table.insert(items, {
        idx = index,
        text = relative,
        -- Snacks resolves `file` against `cwd`, so it must stay relative.
        -- Keep the absolute path separately for filesystem checks and opening.
        file = relative,
        absolute_path = absolute,
        git_path = relative,
        cwd = root,
        deleted = not vim.uv.fs_stat(absolute),
      })
    end
    snacks.picker.pick({
      title = "Files modified in this agent session",
      cwd = root,
      finder = function() return items end,
      format = function(item, picker)
        if item.deleted then
          return { { "󰆴 ", "DiagnosticError" }, { item.text .. " (deleted)", "DiagnosticError" } }
        end
        return snacks.picker.format.file(item, picker)
      end,
      preview = function(ctx)
        if git_available then
          if not ctx.item.git_diff_checked then
            local result = vim.system(
              { "git", "diff", "--no-ext-diff", "--quiet", "HEAD", "--", ctx.item.git_path },
              { cwd = root, text = true }
            ):wait()
            ctx.item.has_git_diff = result.code == 1
            ctx.item.git_diff_checked = true
          end
          if ctx.item.has_git_diff then
            local diff_ctx = vim.tbl_extend("force", {}, ctx)
            diff_ctx.item = vim.tbl_extend("force", {}, ctx.item, { file = ctx.item.git_path })
            snacks.picker.preview.git_diff(diff_ctx)
            return
          end
        end
        if ctx.item.deleted then
          ctx.preview:notify("File was deleted during this agent session", "warn")
          return
        end
        snacks.picker.preview.file(ctx)
      end,
      layout = { preset = "default" },
      confirm = function(picker, item)
        picker:close()
        vim.schedule(function()
          open(item and item.absolute_path)
        end)
      end,
    })
    return
  end
  vim.ui.select(files, {
    prompt = "Files modified in this agent session: ",
    format_item = function(path)
      local relative = path
      local prefix = vim.fs.normalize(root) .. "/"
      if path:sub(1, #prefix) == prefix then
        relative = path:sub(#prefix + 1)
      end
      return vim.uv.fs_stat(path) and relative or (relative .. " (deleted)")
    end,
  }, function(path)
    open(path)
  end)
end

function M.select_model()
  require("conduit.agent").models(function(models, current, err)
    if err then
      vim.notify("Conduit: " .. err, vim.log.levels.ERROR)
      return
    end
    if not models or #models == 0 then
      vim.notify("Conduit: this agent did not advertise any models", vim.log.levels.WARN)
      return
    end
    vim.ui.select(models, {
      prompt = "Conduit model: ",
      format_item = function(model)
        local marker = model.id == current and "● " or "  "
        local label = model.name or model.id
        if label ~= model.id then
          label = label .. " (" .. model.id .. ")"
        end
        return marker .. label
      end,
    }, function(model)
      if not model then
        return
      end
      if model.id == current then
        M.select_thinking_level()
        return
      end
      require("conduit.agent").set_model(model.id, function(ok)
        if ok then
          M.select_thinking_level()
        end
      end)
    end)
  end)
end

function M.select_thinking_level()
  require("conduit.agent").thinking_levels(function(levels, current, err)
    if err then
      vim.notify("Conduit: " .. err, vim.log.levels.ERROR)
      return
    end
    if not levels or #levels == 0 then
      vim.notify("Conduit: this agent did not advertise thinking levels", vim.log.levels.WARN)
      return
    end
    vim.ui.select(levels, {
      prompt = "Conduit thinking level: ",
      format_item = function(level)
        local marker = level.id == current and "● " or "  "
        return marker .. (level.name or level.id)
      end,
    }, function(level)
      if level and level.id ~= current then
        require("conduit.agent").set_thinking_level(level.id)
      end
    end)
  end)
end

return M
