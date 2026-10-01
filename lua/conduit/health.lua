local M = {}

local health = vim.health or require("health")
local start = health.start or health.report_start
local ok = health.ok or health.report_ok
local info = health.info or health.report_info
local warn = health.warn or health.report_warn
local error = health.error or health.report_error

local function executable(command)
  return type(command) == "table" and command[1] and vim.fn.executable(command[1]) == 1
end

local function first_line(value)
  return (value or ""):match("[^\r\n]+")
end

local function json_result(value)
  local decoded
  for line in (value or ""):gmatch("[^\r\n]+") do
    local success, candidate = pcall(vim.json.decode, line)
    if success and type(candidate) == "table" then
      decoded = candidate
    end
  end
  return decoded
end

local function check_command(command, cwd, env)
  local result = vim.system(command, {
    cwd = cwd,
    env = env,
    text = true,
    timeout = 7000,
  }):wait()
  return result.code == 0, result
end

local function check_runtime(cwd)
  local status = require("conduit.agent").status()
  info("Runtime state: " .. status.state)
  if status.session_id then
    ok("Session: " .. status.session_id)
  else
    info("No session has been opened in this Neovim process yet")
  end

  local dashboard = require("conduit.dashboard").get(cwd)
  if not dashboard then
    info("Session dashboard has not been opened yet")
    return
  end
  local running = dashboard.watch_job
      and vim.fn.jobwait({ dashboard.watch_job }, 0)[1] == -1
  if running then
    local visibility = require("conduit.dashboard").is_visible(cwd) and " and visible" or " in the background"
    ok("Session watcher is running" .. visibility)
  else
    warn("Session watcher is not running", { "Reopen it with require('conduit').open_agent()" })
  end
end

function M.check()
  start("conduit.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    local version = vim.version()
    ok(string.format("Neovim %d.%d.%d", version.major, version.minor, version.patch))
  else
    error("Neovim 0.10 or newer is required")
  end

  if pcall(require, "render-markdown") then
    ok("render-markdown.nvim is available")
  else
    warn("render-markdown.nvim is not available; dashboard replies will show raw Markdown", {
      "Install MeanderingProgrammer/render-markdown.nvim and the markdown Treesitter parsers",
    })
  end

  local opts = require("conduit.config").opts
  if not opts.agent then
    error("No ACP agent is configured", { "Set `agent` in require('conduit').setup()" })
    return
  end

  local adapter, adapter_error = require("conduit.agent.adapters").resolve(opts.agent)
  if not adapter then
    error(adapter_error)
    return
  end

  local cwd = require("conduit.project").root(opts.agent)
  if vim.uv.fs_stat(cwd) then
    ok("Project root: " .. cwd)
  else
    error("Project root does not exist: " .. cwd)
    return
  end

  if adapter.transport == "acpx" then
    if not executable(adapter.client_command) then
      error("acpx client is not executable: " .. tostring(adapter.client_command[1]), {
        "Install acpx, or set agent.client_cmd to its executable path",
      })
      return
    end

    local version_command = vim.list_extend(vim.deepcopy(adapter.client_command), { "--version" })
    local version_ok, version = check_command(version_command, cwd, adapter.env)
    if version_ok then
      ok("acpx " .. (first_line(version.stdout) or "is executable"))
    else
      warn("Could not read the acpx version")
    end

    local command = vim.deepcopy(adapter.client_command)
    vim.list_extend(command, {
      "--cwd", cwd,
      "--" .. adapter.permission_mode,
      "--format", "json",
      "--json-strict",
      adapter.agent_name,
      "status",
    })
    local probe_ok, probe = check_command(command, cwd, adapter.env)
    if probe_ok then
      ok("Agent profile, ACP connection, and authentication are working")
      local snapshot = json_result(probe.stdout)
      if snapshot then
        info("acpx session: " .. (snapshot.summary or snapshot.status or "available"))
        if snapshot.acpxSessionId then
          info("Persisted session: " .. snapshot.acpxSessionId)
        end
        if snapshot.model then
          info("Model: " .. snapshot.model)
        end
      end
    else
      local detail = first_line(probe.stderr) or first_line(probe.stdout) or "acpx status failed"
      error("ACP status/authentication probe failed: " .. detail, {
        "Run the configured agent in a terminal to authenticate, then retry :checkhealth conduit",
      })
    end
  else
    if executable(adapter.acp_command) then
      ok("ACP command is executable: " .. adapter.acp_command[1])
    else
      error("ACP command is not executable: " .. tostring(adapter.acp_command and adapter.acp_command[1]))
    end
    if adapter.kind == "remote" then
      info("Remote authentication is verified when the ACP connection is opened")
    end
  end

  check_runtime(cwd)
end

return M
