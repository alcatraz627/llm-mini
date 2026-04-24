#!/usr/bin/env bash
# llm-mini-core.sh — Fast AI query dispatcher.
#
# Single source of truth. All surfaces (CLI, MCP, hook, Python) call this.
# Renamed from mini-core.sh — see llm-mini.sh for the CLI entry point.
#
# Features:
#   - Local-first: Ollama (<500ms warm) with Haiku cloud fallback (~1-2s)
#   - Template system: reusable prompt templates in mini-prompts/
#   - Pipe-friendly: reads stdin eagerly before flag parsing
#   - Cold-start: auto-starts Ollama when needed (configurable)
#   - Auto-stop: shuts down Ollama after idle timeout
#   - File auto-detect: single file arg is read as input
#   - Styled output via gum with plain-text fallback

set -uo pipefail

# ─── Paths ────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPTS_DIR="${HOME}/.claude/assets/mini-prompts"
LOG_FILE="${HOME}/.claude/.mini-log.jsonl"
CONF_FILE="${HOME}/.claude/llm-mini.conf"
ENGINE="${SCRIPT_DIR}/llm-mini-engine.sh"
CHAT_SCRIPT="${SCRIPT_DIR}/llm-mini-chat.sh"
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434/api/generate}"
CLAUDE_BIN="${CLAUDE_BIN:-${HOME}/.local/bin/claude}"

# ─── Defaults ─────────────────────────────────────────────────────

OLLAMA_MODEL="${CLAUDE_MINI_MODEL:-llama3.2}"
CLOUD_MODEL="claude-haiku-4-5-20251001"
BACKEND="${CLAUDE_MINI_BACKEND:-auto}"
MAX_TOKENS=200
TIMEOUT_S=8
SHOW_TIMING=false
CLOUD_METHOD="auto"
USE_JSON=false
CONTEXT_FILE=""
TEMPLATE=""
VERBOSE=false

# ─── Config ───────────────────────────────────────────────────────

_load_config() {
    [[ -f "$CONF_FILE" ]] || return 0
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${key// /}" ]] && continue
        key="${key// /}"
        value="${value%%#*}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        case "$key" in
            default_backend) BACKEND="${CLAUDE_MINI_BACKEND:-$value}" ;;
            default_model)   OLLAMA_MODEL="${CLAUDE_MINI_MODEL:-$value}" ;;
            cloud_model)     CLOUD_MODEL="$value" ;;
            max_tokens)      MAX_TOKENS="$value" ;;
            timeout_s)       TIMEOUT_S="$value" ;;
            show_timing)     SHOW_TIMING="$value" ;;
            cloud_method)    CLOUD_METHOD="$value" ;;
        esac
    done < "$CONF_FILE"
}
_load_config

# ─── Gum TUI ─────────────────────────────────────────────────────

_GUM_TUI="${HOME}/.claude/skills/shared/gum-tui.sh"
if [[ -f "$_GUM_TUI" ]] && source "$_GUM_TUI" 2>/dev/null; then
    HAS_GUM=true
else
    HAS_GUM=false
    gum_info()    { echo "● $*"; }
    gum_success() { echo "✓ $*"; }
    gum_error()   { echo "✗ $*" >&2; }
    gum_warn()    { echo "⚠ $*" >&2; }
    gum_panel()   { local t="$1"; shift; echo "── $t ──"; printf '  %s\n' "$@"; }
    gum_kv()      { printf '  %-20s %s\n' "$1:" "$2"; }
    gum_header()  { echo "═══ $1 ═══"; }
fi

# ─── ANSI (for help — works without gum) ──────────────────────────

C_RESET='\033[0m'; C_BOLD='\033[1m'; C_DIM='\033[2m'
C_CYAN='\033[36m'; C_YELLOW='\033[33m'; C_GREEN='\033[32m'
C_BLUE='\033[34m'; C_MAGENTA='\033[35m'; C_WHITE='\033[97m'

_section() { printf '\n%b%b%s%b\n' "$C_BOLD" "$C_YELLOW" "$1" "$C_RESET"; }
_cmd()     { printf '  %b%-30s%b %b%s%b\n' "$C_CYAN" "$1" "$C_RESET" "$C_DIM" "$2" "$C_RESET"; }
_opt()     { printf '  %b%-20s%b %s\n' "$C_GREEN" "$1" "$C_RESET" "$2"; }
_ex()      { printf '  %b$%b %b%s%b\n' "$C_DIM" "$C_RESET" "$C_WHITE" "$1" "$C_RESET"; }
_exd()     { printf '    %b# %s%b\n' "$C_DIM" "$1" "$C_RESET"; }

# ─── Help ─────────────────────────────────────────────────────────

show_help() {
    echo
    if $HAS_GUM; then
        gum style --foreground 212 --border-foreground 212 --border double \
            --align center --width 58 --margin "0 0" --padding "0 2" \
            "llm-mini — Fast AI Queries"
    else
        printf '  %b%bllm-mini — Fast AI Queries%b\n' "$C_BOLD" "$C_MAGENTA" "$C_RESET"
    fi

    printf '\n  %bLocal-first AI queries: Ollama (<500ms) + Haiku fallback (~1-2s).%b\n' \
        "$C_DIM" "$C_RESET"

    _section "USAGE"
    _cmd 'llm-mini <prompt>'                'Ask a question'
    _cmd 'llm-mini <template> [input|file]' 'Use a prompt template'
    _cmd '<cmd> | llm-mini [template]'      'Pipe input'
    _cmd 'llm-mini engine <subcommand>'     'Manage Ollama runtime'
    _cmd 'llm-mini chat [--tools]'          'Interactive multi-turn session'
    _cmd 'llm-mini history [N]'             'Recent query log'
    _cmd 'llm-mini config [show|edit|set]'  'View or change settings'

    _section "EXAMPLES"
    _ex  'llm-mini "what does jq -r do?"'
    _exd 'Direct question'
    echo
    _ex  'llm-mini summarize README.md'
    _exd 'Summarize a file (auto-detected)'
    echo
    _ex  'git diff | llm-mini summarize'
    _exd 'Pipe any command output'
    echo
    _ex  'llm-mini --quality "explain this error"'
    _exd 'Force cloud backend (Haiku)'
    echo
    _ex  'llm-mini session-title "Fix the auth bug"'
    _exd 'Use a template'
    echo
    _ex  'llm-mini engine start llama3.2'
    _exd 'Start Ollama with a specific model'
    echo
    _ex  'pbpaste | llm-mini "explain this"'
    _exd 'Explain clipboard contents'

    _section "OPTIONS"
    _opt '-h, --help'       'Show this help'
    _opt '--quality'        'Force cloud (Haiku) backend'
    _opt '--local'          'Force local (Ollama) backend'
    _opt '--json'           'Request JSON output from model'
    _opt '--template T'     'Use named prompt template'
    _opt '--max-tokens N'   "Max output tokens (default: $MAX_TOKENS)"
    _opt '--context FILE'   'Append file contents as context'
    _opt '--timing'         'Show response latency after output'
    _opt '--list'           'List available prompt templates'

    _section "TEMPLATES"
    local f name desc
    for f in "$PROMPTS_DIR"/*.prompt; do
        [[ -f "$f" ]] || continue
        name=$(basename "$f" .prompt)
        desc=$(head -1 "$f" | sed 's/^#[[:space:]]*//' | cut -c1-50)
        _opt "$name" "$desc"
    done
    printf '\n  %bCustom:%b %s/*.prompt\n' "$C_DIM" "$C_RESET" "$PROMPTS_DIR"

    _section "ENGINE (Ollama lifecycle)"
    _opt 'engine start [model]'  "Start Ollama (default: $OLLAMA_MODEL)"
    _opt 'engine stop'           'Stop Ollama + idle watchdog'
    _opt 'engine status'         'Running state, model, memory, uptime'
    _opt 'engine switch <model>' 'Hot-swap to a different model'
    _opt 'engine stats'          'Query counts, latency, resources'
    _opt 'engine models'         'List downloaded Ollama models'
    _opt 'engine pull <model>'   'Download a model from Ollama registry'
    _opt 'engine rm <model>'     'Remove a downloaded model'
    printf '\n  %bAuto-start:%b starts Ollama on first query if not running.\n' "$C_DIM" "$C_RESET"
    printf '  %bAuto-stop:%b  shuts down after idle timeout (default: 30 min).\n' "$C_DIM" "$C_RESET"

    _section "CHAT (interactive session)"
    _cmd 'llm-mini chat'              'Start multi-turn chat'
    _cmd 'llm-mini chat --tools'      'Chat with shell/file tools enabled'
    _cmd 'llm-mini chat --local'      'Chat using local Ollama model'
    _cmd 'llm-mini chat --cloud'      'Chat using cloud Haiku'
    printf '\n  %bCommands in chat:%b /exit /clear /tools /model /backend /help\n' "$C_DIM" "$C_RESET"
    printf '  %bTools:%b shell, read_file, list_dir (cloud API only)\n' "$C_DIM" "$C_RESET"

    _section "BACKENDS"
    _opt 'auto'   'Local first, cloud fallback (default)'
    _opt 'local'  'Ollama only — fast, free, private'
    _opt 'cloud'  'Haiku — via CLI (subscription) or API (credits)'

    _section "CONFIGURATION"
    printf '  %bFile:%b  %s\n' "$C_DIM" "$C_RESET" "$CONF_FILE"
    echo
    _opt 'default_backend'   'auto | local | cloud'
    _opt 'default_model'     "$OLLAMA_MODEL"
    _opt 'max_tokens'        "$MAX_TOKENS"
    _opt 'auto_start'        'ask | yes | no'
    _opt 'idle_timeout_min'  '30 (0 = never)'
    _opt 'show_timing'       'true | false'
    _opt 'cloud_method'      'auto | cli | api (cli = subscription, api = credits)'
    printf '\n  %bEnv overrides:%b CLAUDE_MINI_BACKEND, CLAUDE_MINI_MODEL\n' "$C_DIM" "$C_RESET"
    echo
}

# ─── Subcommand: history ─────────────────────────────────────────

_cmd_history() {
    local n="${1:-10}"
    if [[ ! -f "$LOG_FILE" ]]; then
        gum_info "No query history yet"
        return
    fi
    $HAS_GUM && gum_info "Last $n queries:" && echo
    tail -n "$n" "$LOG_FILE" \
        | jq -r '[.ts[:19], .backend, ((.latency_ms // 0) | tostring)+"ms", .template] | @tsv' \
            2>/dev/null \
        | column -t -s$'\t' \
        | while IFS= read -r line; do echo "  $line"; done
}

# ─── Subcommand: config ──────────────────────────────────────────

_cmd_config() {
    case "${1:-show}" in
        show)
            if [[ -f "$CONF_FILE" ]]; then
                $HAS_GUM && gum_info "Config: $CONF_FILE" && echo
                cat "$CONF_FILE"
            else
                gum_warn "No config — creating default"
                cat > "$CONF_FILE" <<'DEFCFG'
default_backend=auto
default_model=llama3.2
cloud_model=claude-haiku-4-5-20251001
max_tokens=200
timeout_s=8
auto_start=ask
idle_timeout_min=30
show_timing=false
# Cloud method: auto (API first, CLI fallback) | cli (subscription) | api (credits)
cloud_method=auto
DEFCFG
                cat "$CONF_FILE"
            fi
            ;;
        edit) "${EDITOR:-vim}" "$CONF_FILE" ;;
        set)
            shift
            [[ $# -eq 0 ]] && { gum_error "Usage: llm-mini config set key=value"; return 1; }
            local kv="$1" key val
            if [[ "$kv" == *=* ]]; then
                key="${kv%%=*}"; val="${kv#*=}"
            elif [[ $# -ge 2 ]]; then
                key="$1"; val="$2"
            else
                gum_error "Usage: llm-mini config set key=value  or  key value"; return 1
            fi
            [[ ! -f "$CONF_FILE" ]] && _cmd_config show >/dev/null
            if grep -q "^${key}=" "$CONF_FILE" 2>/dev/null; then
                sed -i '' "s|^${key}=.*|${key}=${val}|" "$CONF_FILE"
            else
                echo "${key}=${val}" >> "$CONF_FILE"
            fi
            gum_success "Set $key=$val"
            ;;
        *) gum_error "Usage: llm-mini config [show|edit|set key=value]"; return 1 ;;
    esac
}

# ─── Subcommand: templates ───────────────────────────────────────

_cmd_list_templates() {
    $HAS_GUM && gum_info "Available templates:" || echo "Available templates:"
    echo
    local f name desc
    for f in "$PROMPTS_DIR"/*.prompt; do
        [[ -f "$f" ]] || continue
        name=$(basename "$f" .prompt)
        desc=$(head -1 "$f" | sed 's/^#[[:space:]]*//' | cut -c1-60)
        printf "  %-20s %s\n" "$name" "$desc"
    done
    printf "\n  Dir: %s\n" "$PROMPTS_DIR"
}

# ─── Backend functions ────────────────────────────────────────────

# Dynamic timeout — increase for large prompts
_effective_timeout() {
    local len=${#PROMPT}
    if [[ $len -gt 5000 ]]; then
        echo 30
    elif [[ $len -gt 1000 ]]; then
        echo 15
    else
        echo "$TIMEOUT_S"
    fi
}

call_ollama() {
    local timeout
    timeout=$(_effective_timeout)

    # Temp file avoids ARG_MAX limits for large piped inputs
    local tmp_prompt
    tmp_prompt=$(mktemp)
    printf '%s' "$PROMPT" > "$tmp_prompt"

    local payload
    payload=$(jq -cn \
        --arg model "$OLLAMA_MODEL" \
        --rawfile prompt "$tmp_prompt" \
        --argjson num_predict "$MAX_TOKENS" \
        '{model: $model, prompt: $prompt, stream: false,
          options: {num_predict: $num_predict, temperature: 0}}') || {
        rm -f "$tmp_prompt"; return 1
    }
    rm -f "$tmp_prompt"

    local response
    response=$(curl -s --max-time "$timeout" "$OLLAMA_URL" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null) || return 1

    local text
    text=$(printf '%s' "$response" | jq -r '.response // empty' 2>/dev/null) || return 1
    [[ -z "$text" ]] && return 1
    printf '%s' "$text"
}

_call_cloud_api() {
    [[ -n "${ANTHROPIC_API_KEY:-}" ]] || return 1
    local timeout
    timeout=$(_effective_timeout)

    local tmp_prompt
    tmp_prompt=$(mktemp)
    printf '%s' "$PROMPT" > "$tmp_prompt"

    local payload
    payload=$(jq -cn \
        --arg model "$CLOUD_MODEL" \
        --rawfile prompt "$tmp_prompt" \
        --argjson max_tokens "$MAX_TOKENS" \
        '{model: $model, max_tokens: $max_tokens,
          messages: [{role: "user", content: $prompt}]}') || {
        rm -f "$tmp_prompt"; return 1
    }
    rm -f "$tmp_prompt"

    local result
    result=$(curl -s --max-time "$timeout" "https://api.anthropic.com/v1/messages" \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d "$payload" 2>/dev/null) || return 1

    local text
    text=$(printf '%s' "$result" | jq -r '.content[0].text // empty' 2>/dev/null) || return 1
    [[ -z "$text" ]] && return 1
    printf '%s' "$text"
}

_call_cloud_cli() {
    local result
    result=$("$CLAUDE_BIN" -p "$PROMPT" --model "haiku" 2>/dev/null) || return 1
    [[ -z "$result" ]] && return 1
    printf '%s' "$result"
}

call_cloud() {
    case "$CLOUD_METHOD" in
        api)
            _call_cloud_api || return 1
            ;;
        cli)
            _call_cloud_cli || return 1
            ;;
        auto|*)
            # Default: API first (faster), CLI fallback (subscription)
            if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
                _call_cloud_api && return 0
            fi
            _call_cloud_cli
            ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════
# MAIN EXECUTION — everything below is sequential top-level code
# ═══════════════════════════════════════════════════════════════════

# ─── Capture stdin immediately ────────────────────────────────────
# Must happen FIRST — before subcommand routing or flag parsing.
# If stdin is a pipe, slurp it now before any subshell consumes it.

STDIN_DATA=""
if [[ ! -t 0 ]]; then
    STDIN_DATA=$(cat)
fi

# ─── Subcommand routing ──────────────────────────────────────────

if [[ $# -gt 0 ]]; then
    case "$1" in
        engine)    shift; exec bash "$ENGINE" "$@" ;;
        chat)      shift; exec bash "$CHAT_SCRIPT" "$@" ;;
        history)   shift; _cmd_history "${1:-10}"; exit 0 ;;
        config)    shift; _cmd_config "$@"; exit 0 ;;
        help)      show_help; exit 0 ;;
        templates) _cmd_list_templates; exit 0 ;;
    esac
fi

# ─── Flag parsing ────────────────────────────────────────────────

POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --quality)     BACKEND="cloud"; shift ;;
        --local)       BACKEND="local"; shift ;;
        --json)        USE_JSON=true; shift ;;
        --max-tokens)  MAX_TOKENS="$2"; shift 2 ;;
        --template)    TEMPLATE="$2"; shift 2 ;;
        --context)     CONTEXT_FILE="$2"; shift 2 ;;
        --timing)      SHOW_TIMING=true; shift ;;
        --verbose)     VERBOSE=true; shift ;;
        --list)        _cmd_list_templates; exit 0 ;;
        --help|-h)     show_help; exit 0 ;;
        --)            shift; POSITIONAL+=("$@"); break ;;
        *)             POSITIONAL+=("$1"); shift ;;
    esac
done

# ─── Input resolution ────────────────────────────────────────────

INPUT=""

if [[ ${#POSITIONAL[@]} -gt 0 ]]; then
    maybe_template="${POSITIONAL[0]}"
    template_file="$PROMPTS_DIR/${maybe_template}.prompt"

    if [[ -f "$template_file" ]] && [[ -z "$TEMPLATE" ]]; then
        TEMPLATE="$maybe_template"
        if [[ ${#POSITIONAL[@]} -gt 1 ]]; then
            rest=("${POSITIONAL[@]:1}")
            INPUT="${rest[*]}"
        fi
    else
        INPUT="${POSITIONAL[*]}"
    fi
fi

# Validate explicit --template
if [[ -n "$TEMPLATE" ]]; then
    tfile="$PROMPTS_DIR/${TEMPLATE}.prompt"
    if [[ ! -f "$tfile" ]]; then
        gum_error "Template '$TEMPLATE' not found. Run 'llm-mini --list'." >&2
        exit 1
    fi
fi

# File auto-detect: single token that is an existing file → read it
if [[ -n "$INPUT" ]] && [[ ! "$INPUT" =~ [[:space:]] ]] && [[ -f "$INPUT" ]]; then
    $VERBOSE && echo "llm-mini: reading file $INPUT" >&2
    INPUT=$(head -c 32000 "$INPUT")
fi

# Fill from captured stdin (truncate to 32K to avoid API limits)
if [[ -z "$INPUT" ]] && [[ -n "$STDIN_DATA" ]]; then
    INPUT="$STDIN_DATA"
    if [[ ${#INPUT} -gt 32000 ]]; then
        INPUT="${INPUT:0:32000}"
        echo "llm-mini: input truncated to 32000 chars" >&2
    fi
fi

# Nothing to work with → show help
if [[ -z "$INPUT" ]] && [[ -z "$TEMPLATE" ]]; then
    show_help
    exit 1
fi

# ─── Build prompt ────────────────────────────────────────────────

PROMPT=""
if [[ -n "$TEMPLATE" ]]; then
    tfile="$PROMPTS_DIR/${TEMPLATE}.prompt"
    PROMPT=$(cat "$tfile")
    PROMPT="${PROMPT//\{\{input\}\}/$INPUT}"
else
    PROMPT="$INPUT"
fi

# Append context file
if [[ -n "$CONTEXT_FILE" ]] && [[ -f "$CONTEXT_FILE" ]]; then
    ctx=$(head -c 16000 "$CONTEXT_FILE")
    PROMPT="${PROMPT}

---
Context:
${ctx}"
fi

# ─── Execute ─────────────────────────────────────────────────────

START_MS=$(python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || echo 0)
RESULT=""
USED_BACKEND=""

case "$BACKEND" in
    local)
        if ! bash "$ENGINE" ensure 2>/dev/null; then
            gum_error "Local backend unavailable. Try: llm-mini engine start" >&2
            exit 1
        fi
        RESULT=$(call_ollama) || {
            gum_error "Local query failed. Try: llm-mini engine status" >&2
            exit 1
        }
        USED_BACKEND="local"
        ;;
    cloud)
        RESULT=$(call_cloud) || {
            gum_error "Cloud query failed. Check ANTHROPIC_API_KEY." >&2
            exit 1
        }
        USED_BACKEND="cloud"
        ;;
    auto)
        if bash "$ENGINE" ensure 2>/dev/null && RESULT=$(call_ollama 2>/dev/null); then
            USED_BACKEND="local"
        elif RESULT=$(call_cloud 2>/dev/null); then
            USED_BACKEND="cloud"
        else
            gum_error "All backends failed." >&2
            if $VERBOSE; then
                echo "  Local:  $OLLAMA_URL" >&2
                echo "  Cloud:  ANTHROPIC_API_KEY ${ANTHROPIC_API_KEY:+set}${ANTHROPIC_API_KEY:-unset}" >&2
            fi
            exit 1
        fi
        ;;
esac

END_MS=$(python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || echo 0)
ELAPSED=$((END_MS - START_MS))

# ─── Output ──────────────────────────────────────────────────────

# Response → stdout (plain text, safe for piping)
echo "$RESULT"

# Timing → stderr (opt-in via --timing or config)
if [[ "$SHOW_TIMING" == "true" ]]; then
    printf '%b── %dms · %s · %s ──%b\n' \
        "$C_DIM" "$ELAPSED" "$USED_BACKEND" "${TEMPLATE:-direct}" "$C_RESET" >&2
fi

# Touch last-query for idle watchdog
bash "$ENGINE" touch 2>/dev/null &

# Async log
{
    TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "")
    TMPL="${TEMPLATE:-direct}"
    jq -cn \
        --arg ts "$TS" \
        --arg backend "$USED_BACKEND" \
        --arg template "$TMPL" \
        --argjson latency_ms "$ELAPSED" \
        --argjson prompt_len "${#PROMPT}" \
        --argjson result_len "${#RESULT}" \
        '{ts:$ts, backend:$backend, template:$template,
          latency_ms:$latency_ms, prompt_chars:$prompt_len, result_chars:$result_len}' \
        >> "$LOG_FILE"
} 2>/dev/null &
