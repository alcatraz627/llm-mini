#!/usr/bin/env bash
# llm-mini-chat.sh — Interactive multi-turn chat with mini models.
#
# Features:
#   - Multi-turn conversation with automatic context management
#   - Local (Ollama) and cloud (Haiku) backends
#   - Optional tool use: shell commands, file reading, directory listing
#   - In-session commands: /exit, /clear, /tools, /model, /backend
#
# Usage:
#   llm-mini chat [--tools] [--local|--cloud] [--model MODEL]

set -uo pipefail

# ─── Paths ────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${HOME}/.claude/llm-mini.conf"
ENGINE="${SCRIPT_DIR}/llm-mini-engine.sh"
CLAUDE_BIN="${CLAUDE_BIN:-${HOME}/.local/bin/claude}"

# ─── Defaults ─────────────────────────────────────────────────────

OLLAMA_MODEL="llama3.2"
CLOUD_MODEL="claude-haiku-4-5-20251001"
BACKEND="auto"
MAX_TOKENS=1024
CLOUD_METHOD="auto"
TOOLS_ENABLED=false

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
            default_backend) BACKEND="$value" ;;
            default_model)   OLLAMA_MODEL="$value" ;;
            cloud_model)     CLOUD_MODEL="$value" ;;
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
fi

# ─── ANSI ─────────────────────────────────────────────────────────

C_RESET='\033[0m'; C_BOLD='\033[1m'; C_DIM='\033[2m'
C_CYAN='\033[36m'; C_WHITE='\033[97m'; C_GREEN='\033[32m'

# ─── Messages ─────────────────────────────────────────────────────

MESSAGES_FILE=$(mktemp)
echo '[]' > "$MESSAGES_FILE"

_add_message() {
    local role="$1" content="$2"
    local tmp
    tmp=$(mktemp)
    jq --arg role "$role" --arg content "$content" \
        '. + [{"role": $role, "content": $content}]' \
        "$MESSAGES_FILE" > "$tmp" && mv "$tmp" "$MESSAGES_FILE"
}

_add_raw_message() {
    local role="$1" content_json="$2"
    local tmp
    tmp=$(mktemp)
    jq --arg role "$role" --argjson content "$content_json" \
        '. + [{"role": $role, "content": $content}]' \
        "$MESSAGES_FILE" > "$tmp" && mv "$tmp" "$MESSAGES_FILE"
}

_pop_last_message() {
    local tmp
    tmp=$(mktemp)
    jq '.[:-1]' "$MESSAGES_FILE" > "$tmp" && mv "$tmp" "$MESSAGES_FILE"
}

_message_count() {
    jq 'length' "$MESSAGES_FILE"
}

# ─── Tool Definitions (Anthropic format) ──────────────────────────

TOOL_DEFS='[
  {"name":"shell","description":"Run a shell command and return stdout+stderr. Max 4KB output.","input_schema":{"type":"object","properties":{"command":{"type":"string","description":"Shell command to execute"}},"required":["command"]}},
  {"name":"read_file","description":"Read contents of a file (first N lines)","input_schema":{"type":"object","properties":{"path":{"type":"string","description":"File path"},"lines":{"type":"integer","description":"Max lines to read (default 50)"}},"required":["path"]}},
  {"name":"list_dir","description":"List directory contents with details","input_schema":{"type":"object","properties":{"path":{"type":"string","description":"Directory path (default: current dir)"}}}}
]'

# ─── Tool Execution ──────────────────────────────────────────────

_execute_tool() {
    local name="$1" input_json="$2"

    case "$name" in
        shell)
            local cmd
            cmd=$(printf '%s' "$input_json" | jq -r '.command // empty')
            [[ -z "$cmd" ]] && { echo "Error: empty command"; return 1; }
            if printf '%s' "$cmd" | grep -qiE '^\s*(rm |sudo |chmod |chown |mkfs |dd )'; then
                echo "Blocked for safety: $cmd"
                return 1
            fi
            timeout 10 bash -c "$cmd" 2>&1 | head -c 4000
            ;;
        read_file)
            local path lines
            path=$(printf '%s' "$input_json" | jq -r '.path // empty')
            lines=$(printf '%s' "$input_json" | jq -r '.lines // 50')
            [[ -f "$path" ]] || { echo "File not found: $path"; return 1; }
            head -n "$lines" "$path" | head -c 4000
            ;;
        list_dir)
            local path
            path=$(printf '%s' "$input_json" | jq -r '.path // "."')
            [[ -d "$path" ]] || { echo "Directory not found: $path"; return 1; }
            ls -la "$path" 2>&1 | head -30
            ;;
        *)
            echo "Unknown tool: $name"
            return 1
            ;;
    esac
}

# ─── Chat: Ollama ────────────────────────────────────────────────

_chat_ollama() {
    local tmp_msg
    tmp_msg=$(mktemp)
    cat "$MESSAGES_FILE" > "$tmp_msg"

    local payload
    payload=$(jq -cn \
        --arg model "$OLLAMA_MODEL" \
        --rawfile msgs "$tmp_msg" \
        --argjson num_predict "$MAX_TOKENS" \
        '{model: $model, messages: ($msgs | fromjson), stream: false,
         options: {num_predict: $num_predict, temperature: 0.7}}') || {
        rm -f "$tmp_msg"; return 1
    }
    rm -f "$tmp_msg"

    local response
    response=$(curl -s --max-time 30 "http://localhost:11434/api/chat" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null) || return 1

    printf '%s' "$response" | jq -r '.message.content // empty' 2>/dev/null
}

# ─── Chat: Cloud (Anthropic API) ─────────────────────────────────

_chat_cloud_api() {
    local with_tools="${1:-false}"

    [[ -n "${ANTHROPIC_API_KEY:-}" ]] || return 1

    local tmp_msg
    tmp_msg=$(mktemp)
    cat "$MESSAGES_FILE" > "$tmp_msg"

    local payload
    if [[ "$with_tools" == "true" ]]; then
        payload=$(jq -cn \
            --arg model "$CLOUD_MODEL" \
            --rawfile msgs "$tmp_msg" \
            --argjson max_tokens "$MAX_TOKENS" \
            --argjson tools "$TOOL_DEFS" \
            '{model: $model, messages: ($msgs | fromjson),
              max_tokens: $max_tokens, tools: $tools}')
    else
        payload=$(jq -cn \
            --arg model "$CLOUD_MODEL" \
            --rawfile msgs "$tmp_msg" \
            --argjson max_tokens "$MAX_TOKENS" \
            '{model: $model, messages: ($msgs | fromjson),
              max_tokens: $max_tokens}')
    fi
    rm -f "$tmp_msg"

    [[ -z "$payload" ]] && return 1

    curl -s --max-time 30 "https://api.anthropic.com/v1/messages" \
        -H "x-api-key: ${ANTHROPIC_API_KEY}" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d "$payload" 2>/dev/null
}

# ─── Chat: Cloud (CLI — subscription) ────────────────────────────

_chat_cloud_cli() {
    local history
    history=$(jq -r '.[] | select(.content | type == "string") |
        (if .role == "user" then "User: " else "Assistant: " end) + .content' \
        "$MESSAGES_FILE" 2>/dev/null)

    "$CLAUDE_BIN" -p "${history}

Continue as the assistant. Reply directly without any prefix." \
        --model "haiku" 2>/dev/null
}

# ─── Chat: Dispatch ──────────────────────────────────────────────

_chat_cloud_simple() {
    local result text
    case "$CLOUD_METHOD" in
        api)
            result=$(_chat_cloud_api false) || return 1
            printf '%s' "$result" | jq -r '.content[0].text // empty' 2>/dev/null
            ;;
        cli)
            _chat_cloud_cli
            ;;
        auto|*)
            if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
                result=$(_chat_cloud_api false) || { _chat_cloud_cli; return $?; }
                printf '%s' "$result" | jq -r '.content[0].text // empty' 2>/dev/null
            else
                _chat_cloud_cli
            fi
            ;;
    esac
}

_chat_send_with_tools() {
    local max_rounds=5 round=0

    while [[ $round -lt $max_rounds ]]; do
        round=$((round + 1))

        local response
        response=$(_chat_cloud_api true) || return 1

        local stop_reason
        stop_reason=$(printf '%s' "$response" | jq -r '.stop_reason // "end_turn"')

        # Extract text blocks
        local text
        text=$(printf '%s' "$response" | jq -r \
            '[.content[] | select(.type=="text") | .text] | join("")' 2>/dev/null)

        if [[ "$stop_reason" != "tool_use" ]]; then
            # No tools — done
            _add_message "assistant" "$text"
            printf '%s' "$text"
            return 0
        fi

        # Show thinking text before tool calls
        [[ -n "$text" ]] && printf '%b%s%b\n' "$C_DIM" "$text" "$C_RESET" >&2

        # Add full assistant content (with tool_use blocks) to history
        local content_arr
        content_arr=$(printf '%s' "$response" | jq -c '.content')
        _add_raw_message "assistant" "$content_arr"

        # Execute each tool call
        local tool_results='[]'
        local tc_count
        tc_count=$(printf '%s' "$response" | jq '[.content[] | select(.type=="tool_use")] | length')

        local i
        for ((i=0; i<tc_count; i++)); do
            local tc_id tc_name tc_input
            tc_id=$(printf '%s' "$response" | jq -r "[.content[] | select(.type==\"tool_use\")][$i].id")
            tc_name=$(printf '%s' "$response" | jq -r "[.content[] | select(.type==\"tool_use\")][$i].name")
            tc_input=$(printf '%s' "$response" | jq -c "[.content[] | select(.type==\"tool_use\")][$i].input")

            # Display tool call to user
            printf '%b  ⚙ %s' "$C_DIM" "$tc_name" >&2
            if [[ "$tc_name" == "shell" ]]; then
                printf ': %s' "$(printf '%s' "$tc_input" | jq -r '.command')" >&2
            elif [[ "$tc_name" == "read_file" ]]; then
                printf ': %s' "$(printf '%s' "$tc_input" | jq -r '.path')" >&2
            fi
            printf '%b\n' "$C_RESET" >&2

            # Execute
            local output
            output=$(_execute_tool "$tc_name" "$tc_input" 2>&1) || true

            tool_results=$(printf '%s' "$tool_results" | jq \
                --arg id "$tc_id" --arg out "${output:-}" \
                '. + [{"type":"tool_result","tool_use_id":$id,"content":$out}]')
        done

        # Add tool results as user message
        _add_raw_message "user" "$tool_results"
    done

    gum_warn "Tool limit reached (${max_rounds} rounds)" >&2
    return 1
}

_chat_send() {
    case "$BACKEND" in
        local)
            _chat_ollama
            ;;
        cloud)
            if $TOOLS_ENABLED && [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
                _chat_send_with_tools
            else
                _chat_cloud_simple
            fi
            ;;
    esac
}

# ─── Help ─────────────────────────────────────────────────────────

_show_chat_help() {
    echo >&2
    printf '  %b/exit%b        Quit chat\n' "$C_CYAN" "$C_RESET" >&2
    printf '  %b/clear%b       Clear conversation history\n' "$C_CYAN" "$C_RESET" >&2
    printf '  %b/tools%b       Toggle tool use (shell, read_file, list_dir)\n' "$C_CYAN" "$C_RESET" >&2
    printf '  %b/model X%b     Switch Ollama model\n' "$C_CYAN" "$C_RESET" >&2
    printf '  %b/backend X%b   Switch backend (local | cloud)\n' "$C_CYAN" "$C_RESET" >&2
    printf '  %b/history%b     Show exchange count\n' "$C_CYAN" "$C_RESET" >&2
    echo >&2
}

# ─── Main ─────────────────────────────────────────────────────────

main() {
    # Parse flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tools)   TOOLS_ENABLED=true; shift ;;
            --local)   BACKEND="local"; shift ;;
            --cloud)   BACKEND="cloud"; shift ;;
            --model)   OLLAMA_MODEL="$2"; shift 2 ;;
            -h|--help) _show_chat_help; exit 0 ;;
            *)         shift ;;
        esac
    done

    # Resolve backend
    if [[ "$BACKEND" == "auto" ]]; then
        if bash "$ENGINE" ensure 2>/dev/null; then
            BACKEND="local"
        else
            BACKEND="cloud"
        fi
    fi

    local model_display
    [[ "$BACKEND" == "local" ]] && model_display="$OLLAMA_MODEL" || model_display="$CLOUD_MODEL"

    # Welcome
    echo >&2
    if $HAS_GUM; then
        gum style --foreground 212 --border-foreground 212 --border rounded \
            --align center --width 50 --padding "0 2" \
            "llm-mini chat" >&2
    else
        printf '%b═══ llm-mini chat ═══%b\n' "$C_BOLD" "$C_RESET" >&2
    fi
    printf '\n  %bBackend: %s · Model: %s%b\n' "$C_DIM" "$BACKEND" "$model_display" "$C_RESET" >&2
    $TOOLS_ENABLED && printf '  %bTools: enabled (shell, read_file, list_dir)%b\n' "$C_GREEN" "$C_RESET" >&2
    printf '  %bType /help for commands, /exit to quit%b\n\n' "$C_DIM" "$C_RESET" >&2

    # Warnings
    if $TOOLS_ENABLED && [[ "$BACKEND" == "local" ]]; then
        gum_warn "Tools require cloud backend (API). Use /backend cloud" >&2
        echo >&2
    fi
    if $TOOLS_ENABLED && [[ "$BACKEND" == "cloud" ]] && [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
        gum_warn "Tools require ANTHROPIC_API_KEY (direct API, not CLI)" >&2
        echo >&2
    fi

    # REPL
    while true; do
        printf '%b❯%b ' "$C_CYAN" "$C_RESET" >&2
        local input
        IFS= read -r input < /dev/tty || break

        [[ -z "$input" ]] && continue

        # Commands
        case "$input" in
            /exit|/quit|/q)
                gum_info "Bye!" >&2; break ;;
            /clear|/reset)
                echo '[]' > "$MESSAGES_FILE"
                gum_success "Conversation cleared" >&2; continue ;;
            /tools)
                if $TOOLS_ENABLED; then TOOLS_ENABLED=false; else TOOLS_ENABLED=true; fi
                gum_info "Tools: $($TOOLS_ENABLED && echo on || echo off)" >&2
                if $TOOLS_ENABLED && [[ "$BACKEND" != "cloud" ]]; then
                    gum_warn "Tools need cloud backend. Run: /backend cloud" >&2
                fi
                continue ;;
            /model\ *)
                OLLAMA_MODEL="${input#/model }"
                gum_success "Model → $OLLAMA_MODEL" >&2; continue ;;
            /model)
                gum_info "Model: $([[ "$BACKEND" == "local" ]] && echo "$OLLAMA_MODEL" || echo "$CLOUD_MODEL")" >&2; continue ;;
            /backend\ *)
                local nb="${input#/backend }"
                if [[ "$nb" =~ ^(local|cloud)$ ]]; then
                    BACKEND="$nb"
                    gum_success "Backend → $nb" >&2
                else
                    gum_warn "Usage: /backend local|cloud" >&2
                fi; continue ;;
            /backend)
                gum_info "Backend: $BACKEND" >&2; continue ;;
            /history|/count)
                local count
                count=$(_message_count)
                gum_info "$((count / 2)) exchanges" >&2; continue ;;
            /help)
                _show_chat_help; continue ;;
            /*)
                gum_warn "Unknown: $input — type /help" >&2; continue ;;
        esac

        # Add user message
        _add_message "user" "$input"

        # Send
        local response
        response=$(_chat_send 2>/dev/null)

        if [[ -z "$response" ]]; then
            gum_error "No response — check connection or try /backend" >&2
            _pop_last_message
            continue
        fi

        # Add assistant message (tool path manages its own messages)
        if ! $TOOLS_ENABLED || [[ "$BACKEND" == "local" ]] || [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
            _add_message "assistant" "$response"
        fi

        # Display
        echo
        echo "$response"
        echo

        # Touch watchdog
        bash "$ENGINE" touch 2>/dev/null &
    done

    # Cleanup
    rm -f "$MESSAGES_FILE"
}

main "$@"
