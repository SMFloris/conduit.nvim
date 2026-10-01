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
    vim.keymap.set("n", keymaps.ask, M.ask, { desc = "Prompt Conduit agent" })
    vim.keymap.set("v", keymaps.ask, function()
      M.ask("@selection: ")
    end, { desc = "Prompt Conduit agent about selection" })
  end
  if keymaps.toggle then
    vim.keymap.set("n", keymaps.toggle, M.open_agent, { desc = "Open Conduit agent" })
  end
  if keymaps.prompts then
    vim.keymap.set({ "n", "v" }, keymaps.prompts, M.select_prompt, { desc = "Select Conduit prompt" })
  end
  if keymaps.modified_files then
    vim.keymap.set("n", keymaps.modified_files, M.modified_files, { desc = "Latest files modified by Conduit agent" })
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
  local files = status.last_changed_files or {}
  if #files == 0 then
    vim.notify("Conduit: the latest agent turn did not modify project files", vim.log.levels.INFO)
    return
  end
  local root = status.cwd or require("conduit.project").root()
  vim.ui.select(files, {
    prompt = "Latest agent-modified files: ",
    format_item = function(path)
      local relative = path
      local prefix = vim.fs.normalize(root) .. "/"
      if path:sub(1, #prefix) == prefix then
        relative = path:sub(#prefix + 1)
      end
      return vim.uv.fs_stat(path) and relative or (relative .. " (deleted)")
    end,
  }, function(path)
    if not path then
      return
    end
    if not vim.uv.fs_stat(path) then
      vim.notify("Conduit: file no longer exists: " .. path, vim.log.levels.WARN)
      return
    end
    vim.cmd.edit(vim.fn.fnameescape(path))
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
