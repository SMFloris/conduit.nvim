# conduit.nvim

A Neovim client for terminal-based AI coding agents. Conduit keeps a native agent TUI alive in a floating terminal, submits editor-aware prompts through the Agent Client Protocol (ACP), and refreshes buffers when the agent finishes.

Based on [opencode.nvim](https://github.com/NickvanDyke/opencode.nvim) but with a tool-agnostic design.

***Note:** This plugin works standalone but is greatly enhanced when used with [snacks.nvim](https://github.com/folke/snacks.nvim) and [blink.nvim](https://github.com/Saghen/blink.cmp) for an improved input experience.*

## Demo

https://github.com/user-attachments/assets/bc8db443-3c52-4f6f-993c-06bbbdf114ac

## Features

- **Lazy, persistent agents** - Starts one ACP session per working directory and reuses it
- **Native agent terminal** - Opens the same ACP session in the agent's own TUI
- **ACP prompts** - Sends prompts directly instead of using the clipboard
- **Interactive prompt input** with completions, syntax highlighting, and normal-mode support
- **Built-in prompt library** with ability to define custom prompts
- **Automatic context injection** including:
  - Buffer and line-range references
  - Visual selection ranges
  - Cursor position
  - ... and many more; see [Context](#context) below
- **Automatic refresh** - Runs `:checktime` after a completed turn without replacing unsaved buffers
- **Project-aware sessions** - Detects LSP or marker roots and isolates agents and history by project
- **Prompt history** - Use Up/Down in the enhanced prompt window to revisit project prompts
- **Observable lifecycle** - User autocmds expose agent, queue, and turn state
- **Native queueing** - Codex receives waiting prompts immediately and owns their FIFO
- **Sensible defaults** with granular configuration options

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "kitallen23/conduit.nvim",
  opts = {
    agent = {
      type = "local",
      cmd = { "opencode" },
    },
  },
}
```

Using [packer.nvim](https://github.com/wbthomason/packer.nvim):

```lua
use {
  "kitallen23/conduit.nvim",
  config = function()
    require("conduit").setup({
      agent = {
        type = "local",
        cmd = { "opencode" },
      },
    })
  end,
}
```

## Usage

The default mappings are:

| Mapping | Action |
| - | - |
| `<leader>aa` | Enter a prompt and submit it over ACP |
| `<leader>aA` | Open or focus the persistent native agent terminal |
| `<leader>ap` | Select a prompt from the prompt library |
| `<leader>ax` | Cancel the active ACP turn |
| `<leader>aX` | Clear prompts waiting behind the active turn |

The ACP process starts on the first prompt or terminal open. For a local agent, opening the terminal creates the ACP session when needed and attaches the native TUI to it. Closing the floating window only hides it; the terminal job and buffer remain alive.

You can also call the functions directly:

```vim
-- Call directly
:lua require('conduit').ask() -- Open a blank prompt input and submit it
:lua require('conduit').ask('@cursor: ') -- Open the prompt input with a pre-filled value
:lua require('conduit').open_agent() -- Open/focus the native agent TUI
:lua require('conduit').select_prompt() -- Open the prompt picker
:lua require('conduit').select_prompt('review_buffer') -- Submit a named prompt immediately
:lua require('conduit').cancel() -- Cancel the active ACP turn
```

```lua
-- Or map to a key combination (example)
vim.keymap.set('n', '<leader>ai', function() require('conduit').ask('@cursor: ') end, { desc = 'Generate conduit prompt' })
vim.keymap.set('v', '<leader>ai', function() require('conduit').ask('@selection: ') end, { desc = 'Generate conduit prompt about selection' })
vim.keymap.set({ 'n', 'v' }, '<leader>ap', function() require('conduit').select_prompt() end, { desc = 'Select conduit prompt' })
```

### Agent configuration

OpenCode has a built-in adapter:

```lua
agent = {
  type = "local",
  cmd = { "opencode" },
  -- Derived defaults:
  -- acp_cmd = { "opencode", "acp" }
  -- terminal_cmd = { "opencode", "--session", session_id }
}
```

Codex uses the `codex-acp` adapter, which must be installed separately:

```lua
agent = {
  name = "codex",
  type = "local",
  cmd = { "codex" },
  acp_cmd = { "codex-acp" },
  -- Native terminal defaults to: codex resume <session_id>
}
```

The Codex adapter uses its agent-owned prompt FIFO. Waiting prompts are sent immediately as concurrent ACP requests, appear with `queue_owner = "agent"` in status and events, and can be cancelled before they start with `clear_queue()`. Other adapters use Conduit's portable client-side FIFO unless `agent.queue_mode = "agent"` is explicitly configured.

For another local agent, provide both commands. `terminal_cmd` may be a function receiving the ACP session ID:

```lua
agent = {
  name = "custom",
  type = "local",
  acp_cmd = { "my-agent", "--acp" },
  terminal_cmd = function(session_id)
    return { "my-agent", "resume", session_id }
  end,
}
```

Remote WebSocket ACP endpoints are supported through `websocat`:

```lua
agent = {
  type = "remote",
  url = "wss://agent.example.com/acp",
  headers = { Authorization = "Bearer ..." },
}
```

Remote ACP transport is not yet standardized across all agents. Override `acp_cmd` when the endpoint needs a different bridge command. Remote agents do not expose a local native terminal.

### Workflow

1. Press `<leader>aa` and enter a prompt containing any context placeholders.
2. Conduit lazily starts the configured ACP agent and creates a project session.
3. The expanded prompt is submitted with `session/prompt`.
4. When the turn finishes, Conduit safely checks changed project buffers and emits the `User ConduitTurnComplete` autocmd.
5. Press `<leader>aA` to open the native terminal attached to the active Conduit session.

If no agent is configured, `ask` retains the original behavior and copies the expanded prompt to the `+` register.

## API

| Function    | Description |
|-------------|-------------|
| `setup` | Configure Conduit and install its default mappings |
| `ask` | Input and submit a prompt. Highlights and completes contexts. |
| `submit` | Expand and submit a prompt directly |
| `open_agent` | Open or focus the persistent native agent terminal |
| `cancel` | Cancel the active ACP turn |
| `clear_queue` | Remove pending prompts and return how many were removed |
| `status` | Return the current project agent's state and session ID |
| `prompt` | Legacy helper that expands a prompt and copies it to the clipboard |
| `select_prompt` | Open the prompt picker, or submit a prompt by key |

## Context

When your prompt contains placeholders, `conduit.nvim` replaces them with context before sending:

| Placeholder | Context |
| - | - |
| `@buffer` | Current buffer |
| `@buffers` | Open buffers |
| `@cursor` | Cursor position |
| `@selection` | Selected text |
| `@visible` | Visible text |
| `@diagnostic` | Current line diagnostics |
| `@diagnostics` | Current buffer diagnostics |
| `@quickfix` | Quickfix list |
| `@diff` | Git diff |
| `@hunk` | Git diff hunk |

Add custom contexts to `opts.contexts`.

## Configuration

Configure the plugin with `require("conduit").setup(opts)`. See the full config and its defaults [here](./lua/conduit/config.lua). Setting `vim.g.conduit_opts` before requiring Conduit remains supported.

By default, Conduit prefers the attached LSP workspace and then searches upward for `.git`, `pyproject.toml`, `package.json`, `Cargo.toml`, or `go.mod`. Set `agent.cwd` to override detection or replace `root_markers` to customize it.

Prompt history is kept per project in Neovim's state directory. Persistence and size are configurable:

```lua
history = {
  enabled = true,
  persist = true,
  max_entries = 100,
}
```

When a turn finishes, Conduit checks only loaded buffers belonging to that project. Window views and cursor positions are restored after reload; buffers with unsaved changes are left untouched and reported.

### Events

Conduit emits `User` autocmds with details in `event.data`:

| Pattern | When |
| - | - |
| `ConduitAgentStarting` | The ACP process is starting |
| `ConduitAgentReady` | Initialization and session creation finished |
| `ConduitPromptQueued` | A prompt was queued behind an active turn; includes `queue_owner` |
| `ConduitQueueCleared` | Waiting client or agent-owned prompt requests were cancelled |
| `ConduitTurnStarted` | A prompt turn started |
| `ConduitTurnComplete` | Refresh finished; includes changed and skipped files |
| `ConduitAgentExited` | The ACP process exited or initialization failed |

For example:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = { "ConduitTurnStarted", "ConduitTurnComplete" },
  callback = function(event)
    vim.cmd("redrawstatus")
    print(vim.inspect(event.data))
  end,
})
```

You can override any of these options by setting `vim.g.conduit_opts` to a partial configuration. For example:

```lua
vim.g.conduit_opts = {
  notify = false,  -- Disable notifications
  prompts = {
    custom = { -- Add a custom prompt
      description = "My custom prompt",
      prompt = "Do something with @selection",
    },
    optimize = false -- Set a default prompt to false to disable it
  },
}
```

## Credits

This project was bootstrapped from [ellisonleao/nvim-plugin-template](https://github.com/ellisonleao/nvim-plugin-template).

The core functionality is based on [NickvanDyke/opencode.nvim](https://github.com/NickvanDyke/opencode.nvim). Much of the code was adapted from that project.

## License

MIT
