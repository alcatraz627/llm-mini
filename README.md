# llm-mini

Fast, local-first AI query tool. Uses Ollama for sub-second responses with automatic cloud (Haiku) fallback.

```
llm-mini "what does jq -r do?"          # quick question
git diff | llm-mini summarize           # pipe + template
llm-mini chat                           # interactive session
llm-mini engine status                  # manage Ollama
```

## Install

```bash
git clone https://github.com/alcatraz627/llm-mini.git
cd llm-mini
bash install.sh
```

Requires: bash 3.2+, curl, jq. Optional: [Ollama](https://ollama.com) (local inference), [gum](https://github.com/charmbracelet/gum) (styled output).

## Usage

### Quick queries

```bash
llm-mini "explain async/await in 2 sentences"
llm-mini --quality "what's the difference between PUT and PATCH?"   # force cloud
llm-mini --local "summarize this"                                    # force local
```

### Pipe input

```bash
cat README.md | llm-mini summarize
git log --oneline -10 | llm-mini "what changed recently?"
curl -s api.example.com/health | llm-mini "is this healthy?"
```

### Templates

Reusable prompt templates in `templates/`:

```bash
llm-mini --list                            # show available templates
llm-mini --template session-title "..."    # use a template
llm-mini summarize FILE                    # shorthand for summarize template
```

### Interactive chat

Multi-turn conversation with context retention:

```bash
llm-mini chat                       # default backend
llm-mini chat --local               # Ollama only
llm-mini chat --quality             # cloud only
llm-mini chat --tools               # enable tool use (cloud API only)
```

Chat commands: `/help`, `/clear`, `/exit`, `/tools`, `/model <name>`, `/backend <local|cloud>`, `/history`

### Engine management

```bash
llm-mini engine status               # Ollama running? which model?
llm-mini engine start                # start Ollama
llm-mini engine stop                 # stop Ollama
llm-mini engine models               # list installed models
llm-mini engine pull mistral          # download a model
llm-mini engine rm codellama          # remove a model
llm-mini engine switch phi3           # change active model
llm-mini engine stats                 # performance stats
```

## Configuration

Config file: `~/.claude/llm-mini.conf`

```bash
llm-mini config show                 # view current config
llm-mini config edit                 # open in editor
llm-mini config set key=value        # set a value
llm-mini config set key value        # also works
```

Key settings:

| Key | Default | Description |
|-----|---------|-------------|
| `default_backend` | `auto` | `auto`, `local`, or `cloud` |
| `default_model` | `llama3.2` | Ollama model name |
| `cloud_model` | `claude-haiku-4-5-20251001` | Cloud model identifier |
| `cloud_method` | `cli` | `auto`, `cli` (subscription), or `api` (credits) |
| `max_tokens` | `200` | Max output tokens |
| `timeout_s` | `8` | Request timeout (auto-increased for large inputs) |
| `auto_start` | `ask` | Auto-start Ollama: `ask`, `yes`, `no` |
| `idle_timeout_min` | `30` | Auto-stop Ollama after N minutes (0 = never) |
| `show_timing` | `false` | Show latency after response |

## Surfaces

llm-mini is accessible from multiple contexts:

| Surface | How |
|---------|-----|
| CLI | `llm-mini "question"` |
| Pipe | `echo text \| llm-mini summarize` |
| Chat | `llm-mini chat` |
| MCP | `mcp__llm-mini__ask` tool in Claude Code |
| Hook | `source llm-mini-hook.sh; mini_quick "question"` |

## Architecture

```
llm-mini.sh          → CLI entry point (exec → core)
llm-mini-core.sh     → Main dispatcher (config, backends, routing)
llm-mini-engine.sh   → Ollama lifecycle (start/stop/models/pull/rm)
llm-mini-chat.sh     → Interactive multi-turn REPL
llm-mini-hook.sh     → Sourceable functions for Claude hooks
llm-mini-mcp-server.js → MCP stdio server wrapper
templates/*.prompt   → Reusable prompt templates
```

## Tool use (chat mode)

When chat is started with `--tools` (requires cloud API backend), the model can:

- **shell**: Execute safe shell commands (dangerous commands blocked)
- **read_file**: Read file contents (first 200 lines)
- **list_dir**: List directory contents

## License

MIT
