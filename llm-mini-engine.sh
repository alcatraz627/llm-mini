#!/usr/bin/env bash
# llm-mini-engine.sh — Ollama lifecycle manager for llm-mini.
#
# Manages Ollama as a cold-start serverless runtime:
# - Auto-starts on first query (with user confirmation or silently)
# - Auto-stops after configurable idle timeout (default 30 min)
# - Model switching, stats, and resource monitoring
#
# Usage:
#   llm-mini-engine.sh start [model]    Start Ollama, load model
#   llm-mini-engine.sh stop             Stop Ollama + watchdog
#   llm-mini-engine.sh status           Running state, model, memory
#   llm-mini-engine.sh switch <model>   Hot-swap model
#   llm-mini-engine.sh stats            Query counts, latency, resources
#   llm-mini-engine.sh models           List downloaded models
#   llm-mini-engine.sh ensure           Internal: cold-start gate
#   llm-mini-engine.sh idle-check       Internal: watchdog tick
#   llm-mini-engine.sh touch            Internal: update last-query ts

set -uo pipefail

# ─── Paths ────────────────────────────────────────────────────────

STATE_DIR="${HOME}/.claude/llm-mini-state"
CONF_FILE="${HOME}/.claude/llm-mini.conf"
LOG_FILE="${HOME}/.claude/.mini-log.jsonl"
LAST_QUERY_FILE="${STATE_DIR}/last-query"
WATCHDOG_PID_FILE="${STATE_DIR}/watchdog.pid"
STARTED_BY_US_FILE="${STATE_DIR}/started-by-us"
OLLAMA_LOG="${STATE_DIR}/ollama.log"

OLLAMA_API="http://localhost:11434"

mkdir -p "$STATE_DIR"

# ─── Gum TUI (with fallbacks) ────────────────────────────────────

_GUM_TUI="${HOME}/.claude/skills/shared/gum-tui.sh"
if [[ -f "$_GUM_TUI" ]] && source "$_GUM_TUI" 2>/dev/null; then
    : # loaded
else
    gum_info()    { echo "● $*"; }
    gum_success() { echo "✓ $*"; }
    gum_error()   { echo "✗ $*" >&2; }
    gum_warn()    { echo "⚠ $*" >&2; }
    gum_panel()   { local t="$1"; shift; echo "── $t ──"; printf '  %s\n' "$@"; }
    gum_kv()      { printf '  %-20s %s\n' "$1:" "$2"; }
fi

# ─── Config ───────────────────────────────────────────────────────

DEFAULT_MODEL="${CLAUDE_MINI_MODEL:-llama3.2}"
AUTO_START="ask"
IDLE_TIMEOUT_MIN=30

_load_config() {
    [[ -f "$CONF_FILE" ]] || return 0
    while IFS='=' read -r key value; do
        # Skip comments and blanks
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${key// /}" ]] && continue
        key="${key// /}"
        # Strip inline comments and whitespace from value
        value="${value%%#*}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        case "$key" in
            default_model)    DEFAULT_MODEL="$value" ;;
            auto_start)       AUTO_START="$value" ;;
            idle_timeout_min) IDLE_TIMEOUT_MIN="$value" ;;
        esac
    done < "$CONF_FILE"
}
_load_config

# ─── Helpers ──────────────────────────────────────────────────────

is_ollama_installed() { command -v ollama &>/dev/null; }

is_ollama_running() {
    curl -sf --max-time 2 "${OLLAMA_API}/api/tags" >/dev/null 2>&1
}

get_loaded_model() {
    curl -s --max-time 2 "${OLLAMA_API}/api/ps" 2>/dev/null \
        | jq -r '.models[0].name // empty' 2>/dev/null
}

get_available_models() {
    curl -s --max-time 2 "${OLLAMA_API}/api/tags" 2>/dev/null \
        | jq -r '.models[].name' 2>/dev/null
}

get_ollama_pid() { pgrep -f 'ollama serve' 2>/dev/null | head -1; }

touch_last_query() { date +%s > "$LAST_QUERY_FILE"; }

# ─── Watchdog (idle auto-stop) ────────────────────────────────────

_start_watchdog() {
    _stop_watchdog  # kill any existing

    local idle_threshold=$((IDLE_TIMEOUT_MIN * 60))
    [[ $idle_threshold -le 0 ]] && return  # auto-stop disabled

    local qf="$LAST_QUERY_FILE"
    local sf="$STARTED_BY_US_FILE"
    local pf="$WATCHDOG_PID_FILE"
    local tmin="$IDLE_TIMEOUT_MIN"

    (
        trap "rm -f '$pf'; exit 0" EXIT TERM INT
        while true; do
            sleep 300  # check every 5 min
            [[ -f "$qf" ]] || continue
            local last now idle
            last=$(cat "$qf" 2>/dev/null || echo 0)
            now=$(date +%s)
            idle=$((now - last))
            if [[ $idle -gt $idle_threshold ]]; then
                pkill -f 'ollama serve' 2>/dev/null
                rm -f "$sf"
                # Desktop notification
                osascript -e \
                    "display notification \"Stopped after ${tmin}m idle\" with title \"llm-mini\"" \
                    2>/dev/null || true
                exit 0
            fi
        done
    ) &
    echo $! > "$WATCHDOG_PID_FILE"
    disown $! 2>/dev/null || true
}

_stop_watchdog() {
    if [[ -f "$WATCHDOG_PID_FILE" ]]; then
        local wpid
        wpid=$(cat "$WATCHDOG_PID_FILE" 2>/dev/null || echo "")
        if [[ -n "$wpid" ]] && kill -0 "$wpid" 2>/dev/null; then
            kill "$wpid" 2>/dev/null || true
        fi
        rm -f "$WATCHDOG_PID_FILE"
    fi
}

# ─── Commands ─────────────────────────────────────────────────────

cmd_start() {
    local model="${1:-$DEFAULT_MODEL}"

    if ! is_ollama_installed; then
        gum_error "Ollama not installed. Install: brew install ollama"
        return 1
    fi

    if is_ollama_running; then
        local loaded
        loaded=$(get_loaded_model)
        if [[ -n "$loaded" ]]; then
            if [[ "$loaded" == "${model}"* ]]; then
                gum_success "Ollama already running with $loaded"
                touch_last_query
                _start_watchdog
                return 0
            fi
            gum_info "Ollama running with $loaded — switching to $model"
            cmd_switch "$model"
            return $?
        fi
        gum_info "Ollama running, loading $model..."
    else
        gum_info "Starting Ollama..."
        nohup ollama serve > "$OLLAMA_LOG" 2>&1 &
        disown $! 2>/dev/null || true

        # Wait for API readiness (max 15s)
        local waited=0
        while ! is_ollama_running; do
            sleep 1
            waited=$((waited + 1))
            if [[ $waited -ge 15 ]]; then
                gum_error "Ollama failed to start (15s timeout)"
                cat "$OLLAMA_LOG" 2>/dev/null | tail -5 >&2
                return 1
            fi
        done
        gum_success "Ollama server ready (${waited}s)"
    fi

    # Pull model if not downloaded
    local models
    models=$(get_available_models 2>/dev/null || echo "")
    if ! echo "$models" | grep -q "^${model}"; then
        gum_info "Pulling $model (first run — may take a while)..."
        ollama pull "$model" 2>&1
    fi

    # Warm up model with a trivial query via API
    gum_info "Loading $model into memory..."
    curl -sf --max-time 30 "${OLLAMA_API}/api/generate" \
        -d "{\"model\":\"${model}\",\"prompt\":\"hi\",\"stream\":false}" \
        >/dev/null 2>&1 \
        || { gum_error "Failed to load model $model"; return 1; }

    gum_success "$model ready"

    echo "$(date +%s)" > "$STARTED_BY_US_FILE"
    touch_last_query
    _start_watchdog

    if [[ $IDLE_TIMEOUT_MIN -gt 0 ]]; then
        gum_kv "Auto-stop" "after ${IDLE_TIMEOUT_MIN}m idle"
    fi
}

cmd_stop() {
    _stop_watchdog

    if ! is_ollama_running; then
        gum_info "Ollama is not running"
        rm -f "$STARTED_BY_US_FILE"
        return 0
    fi

    local loaded
    loaded=$(get_loaded_model)
    gum_info "Stopping Ollama${loaded:+ ($loaded)}..."
    pkill -f 'ollama serve' 2>/dev/null
    sleep 1

    if is_ollama_running; then
        gum_warn "Still running — sending SIGKILL"
        pkill -9 -f 'ollama serve' 2>/dev/null
        sleep 1
    fi

    rm -f "$STARTED_BY_US_FILE"
    gum_success "Ollama stopped"
}

cmd_status() {
    if ! is_ollama_installed; then
        gum_error "Ollama not installed"
        return 1
    fi

    local running="no" model="-" uptime_str="-" idle_str="-"
    local pid="-" mem="-" started_by="external" watchdog="inactive"

    if is_ollama_running; then
        running="yes"
        model=$(get_loaded_model)
        [[ -z "$model" ]] && model="(none loaded)"
        pid=$(get_ollama_pid)

        if [[ -n "$pid" && "$pid" != "-" ]]; then
            mem=$(ps -p "$pid" -o rss= 2>/dev/null \
                | awk '{printf "%.0f MB", $1/1024}' 2>/dev/null || echo "-")
            uptime_str=$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' ' || echo "-")
        fi

        [[ -f "$STARTED_BY_US_FILE" ]] && started_by="llm-mini"

        if [[ -f "$LAST_QUERY_FILE" ]]; then
            local last now idle_sec
            last=$(cat "$LAST_QUERY_FILE" 2>/dev/null || echo 0)
            now=$(date +%s)
            idle_sec=$((now - last))
            if [[ $idle_sec -lt 60 ]]; then
                idle_str="${idle_sec}s ago"
            elif [[ $idle_sec -lt 3600 ]]; then
                idle_str="$((idle_sec / 60))m ago"
            else
                idle_str="$((idle_sec / 3600))h ago"
            fi
        fi

        if [[ -f "$WATCHDOG_PID_FILE" ]]; then
            local wpid
            wpid=$(cat "$WATCHDOG_PID_FILE" 2>/dev/null || echo "")
            if [[ -n "$wpid" ]] && kill -0 "$wpid" 2>/dev/null; then
                watchdog="active (stop after ${IDLE_TIMEOUT_MIN}m idle)"
            fi
        fi
    fi

    gum_panel "llm-mini Engine" \
        "Running:      $running" \
        "Model:        $model" \
        "PID:          $pid" \
        "Memory:       $mem" \
        "Uptime:       $uptime_str" \
        "Last query:   $idle_str" \
        "Started by:   $started_by" \
        "Watchdog:     $watchdog"
}

cmd_switch() {
    local model="${1:-}"
    if [[ -z "$model" ]]; then
        gum_error "Usage: llm-mini engine switch <model>"
        echo >&2
        cmd_models >&2
        return 1
    fi

    if ! is_ollama_running; then
        gum_info "Ollama not running — starting with $model"
        cmd_start "$model"
        return $?
    fi

    local current
    current=$(get_loaded_model)
    if [[ "${current}" == "${model}"* ]]; then
        gum_info "$model is already loaded"
        return 0
    fi

    gum_info "Switching ${current:-none} → $model..."

    # Unload current
    [[ -n "$current" ]] && ollama stop "$current" 2>/dev/null

    # Pull if needed
    local models
    models=$(get_available_models 2>/dev/null || echo "")
    if ! echo "$models" | grep -q "^${model}"; then
        gum_info "Pulling $model..."
        ollama pull "$model" 2>&1
    fi

    # Load via API
    curl -sf --max-time 30 "${OLLAMA_API}/api/generate" \
        -d "{\"model\":\"${model}\",\"prompt\":\"hi\",\"stream\":false}" \
        >/dev/null 2>&1 \
        || { gum_error "Failed to load $model"; return 1; }

    gum_success "Switched to $model"
    touch_last_query
}

cmd_stats() {
    local today total_q today_q avg_lat local_q cloud_q
    today=$(date '+%Y-%m-%d')
    total_q=0; today_q=0; avg_lat=0; local_q=0; cloud_q=0

    if [[ -f "$LOG_FILE" ]]; then
        total_q=$(wc -l < "$LOG_FILE" | tr -d ' ')
        today_q=$(grep -c "\"${today}" "$LOG_FILE" 2>/dev/null) || true
        avg_lat=$(jq -s \
            'if length > 0 then (map(.latency_ms) | add / length | floor) else 0 end' \
            "$LOG_FILE" 2>/dev/null || echo 0)
        local_q=$(jq -s '[.[] | select(.backend=="local")] | length' \
            "$LOG_FILE" 2>/dev/null || echo 0)
        cloud_q=$(jq -s '[.[] | select(.backend=="cloud")] | length' \
            "$LOG_FILE" 2>/dev/null || echo 0)
    fi

    local pid mem cpu
    pid=$(get_ollama_pid)
    if [[ -n "$pid" ]]; then
        mem=$(ps -p "$pid" -o rss= 2>/dev/null \
            | awk '{printf "%.0f MB", $1/1024}' 2>/dev/null || echo "-")
        cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ' || echo "-")
    else
        mem="-"; cpu="-"
    fi

    gum_panel "llm-mini Stats" \
        "Total queries:    $total_q" \
        "Today:            $today_q" \
        "Avg latency:      ${avg_lat}ms" \
        "Local queries:    $local_q" \
        "Cloud queries:    $cloud_q" \
        "" \
        "Ollama memory:    $mem" \
        "Ollama CPU:       ${cpu}%"
}

cmd_models() {
    if ! is_ollama_installed; then
        gum_error "Ollama not installed"
        return 1
    fi

    # Show downloaded models even if server isn't running
    local list_output
    list_output=$(ollama list 2>/dev/null) || {
        gum_warn "Cannot list models (is Ollama installed correctly?)"
        return 1
    }

    local loaded=""
    if is_ollama_running; then
        loaded=$(get_loaded_model)
    fi

    gum_info "Downloaded models:"
    echo
    echo "$list_output" | while IFS= read -r line; do
        # First line is header
        if [[ "$line" == NAME* ]]; then
            printf '  %s\n' "$line"
            continue
        fi
        local name
        name=$(echo "$line" | awk '{print $1}')
        if [[ -n "$loaded" && "$name" == "$loaded" ]]; then
            printf '  %s  ← active\n' "$line"
        else
            printf '  %s\n' "$line"
        fi
    done
}

cmd_pull() {
    local model="${1:-}"
    if [[ -z "$model" ]]; then
        gum_error "Usage: llm-mini engine pull <model>"
        echo "  Examples: llama3.2, mistral, phi3, gemma2, codellama" >&2
        return 1
    fi

    is_ollama_installed || { gum_error "Ollama not installed. Install: brew install ollama"; return 1; }

    # Pull requires the server running
    if ! is_ollama_running; then
        gum_info "Starting Ollama for download..."
        nohup ollama serve > "$OLLAMA_LOG" 2>&1 &
        disown $! 2>/dev/null || true
        local waited=0
        while ! is_ollama_running; do
            sleep 1
            waited=$((waited + 1))
            [[ $waited -ge 15 ]] && { gum_error "Ollama failed to start"; return 1; }
        done
    fi

    gum_info "Pulling $model..."
    if ollama pull "$model" 2>&1; then
        gum_success "Model $model ready"
    else
        gum_error "Failed to pull $model"
        return 1
    fi
}

cmd_rm() {
    local model="${1:-}"
    if [[ -z "$model" ]]; then
        gum_error "Usage: llm-mini engine rm <model>"
        echo >&2
        cmd_models >&2
        return 1
    fi

    is_ollama_installed || { gum_error "Ollama not installed"; return 1; }

    # Warn if deleting the active model
    local loaded
    loaded=$(get_loaded_model 2>/dev/null)
    if [[ -n "$loaded" && "$loaded" == "${model}"* ]]; then
        gum_warn "Model $model is currently loaded" >&2
        if command -v gum &>/dev/null; then
            gum confirm "Remove active model $model?" < /dev/tty 2>/dev/tty || {
                gum_info "Cancelled"; return 0
            }
        else
            printf 'Remove active model %s? [y/N] ' "$model" >&2
            local answer
            read -r answer < /dev/tty 2>/dev/null || return 1
            [[ "$answer" != "y" && "$answer" != "Y" ]] && { gum_info "Cancelled"; return 0; }
        fi
    fi

    if ollama rm "$model" 2>&1; then
        gum_success "Model $model removed"
    else
        gum_error "Failed to remove $model"
        return 1
    fi
}

cmd_ensure() {
    # Gate function: ensures Ollama is ready for a query.
    # Returns 0 = Ollama ready, 1 = caller should use cloud fallback.
    # All user-facing output goes to stderr (stdout reserved for query results).

    if is_ollama_running; then
        touch_last_query
        # Start watchdog if we started Ollama and it's not running
        if [[ -f "$STARTED_BY_US_FILE" ]] && [[ ! -f "$WATCHDOG_PID_FILE" ]]; then
            _start_watchdog
        fi
        return 0
    fi

    is_ollama_installed || return 1

    case "$AUTO_START" in
        yes)
            cmd_start "$DEFAULT_MODEL" >&2
            return $?
            ;;
        no)
            return 1
            ;;
        ask)
            # Interactive: prompt via gum. Non-interactive: cloud fallback.
            if [[ -t 2 ]]; then
                gum_warn "Ollama is not running" >&2

                if command -v gum &>/dev/null; then
                    local choice
                    choice=$(gum choose --header "How should llm-mini proceed?" \
                        "Start Ollama with ${DEFAULT_MODEL}" \
                        "Pick a different model" \
                        "Use cloud (Haiku) this time" \
                        < /dev/tty 2>/dev/tty) || return 1

                    case "$choice" in
                        "Start Ollama with ${DEFAULT_MODEL}")
                            cmd_start "$DEFAULT_MODEL" >&2
                            return $?
                            ;;
                        "Pick a different model")
                            local models model
                            models=$(ollama list 2>/dev/null | tail -n +2 | awk '{print $1}')
                            if [[ -z "$models" ]]; then
                                gum_warn "No downloaded models — using $DEFAULT_MODEL" >&2
                                cmd_start "$DEFAULT_MODEL" >&2
                                return $?
                            fi
                            model=$(echo "$models" \
                                | gum choose --header "Select model:" \
                                < /dev/tty 2>/dev/tty) || return 1
                            cmd_start "$model" >&2
                            return $?
                            ;;
                        "Use cloud (Haiku) this time")
                            return 1
                            ;;
                    esac
                else
                    # No gum — simple prompt
                    printf 'Start Ollama with %s? [Y/n] ' "$DEFAULT_MODEL" >&2
                    local answer
                    read -r answer < /dev/tty 2>/dev/null || return 1
                    if [[ "$answer" != "n" && "$answer" != "N" ]]; then
                        cmd_start "$DEFAULT_MODEL" >&2
                        return $?
                    fi
                    return 1
                fi
            else
                # Non-interactive (pipe, cron, hook) → silent cloud fallback
                return 1
            fi
            ;;
    esac
}

cmd_idle_check() {
    is_ollama_running || return 0
    [[ -f "$LAST_QUERY_FILE" ]] || return 0

    local last now idle_sec threshold
    last=$(cat "$LAST_QUERY_FILE" 2>/dev/null || echo 0)
    now=$(date +%s)
    idle_sec=$((now - last))
    threshold=$((IDLE_TIMEOUT_MIN * 60))

    if [[ $idle_sec -gt $threshold ]]; then
        cmd_stop
    else
        local remaining=$(( (threshold - idle_sec) / 60 ))
        gum_info "Idle ${idle_sec}s — auto-stop in ~${remaining}m"
    fi
}

cmd_touch() { touch_last_query; }

# ─── Dispatch ─────────────────────────────────────────────────────

main() {
    local cmd="${1:-status}"
    shift 2>/dev/null || true

    case "$cmd" in
        start)      cmd_start "$@" ;;
        stop)       cmd_stop ;;
        status)     cmd_status ;;
        switch)     cmd_switch "$@" ;;
        stats)      cmd_stats ;;
        models)     cmd_models ;;
        pull)       cmd_pull "$@" ;;
        rm|remove)  cmd_rm "$@" ;;
        ensure)     cmd_ensure ;;
        idle-check) cmd_idle_check ;;
        touch)      cmd_touch ;;
        -h|--help|help)
            echo "Usage: llm-mini engine <command>"
            echo
            echo "Commands:"
            echo "  start [model]    Start Ollama (default: $DEFAULT_MODEL)"
            echo "  stop             Stop Ollama and idle watchdog"
            echo "  status           Show engine state"
            echo "  switch <model>   Hot-swap to a different model"
            echo "  stats            Query counts and resource usage"
            echo "  models           List downloaded Ollama models"
            echo "  pull <model>     Download a model from Ollama registry"
            echo "  rm <model>       Remove a downloaded model"
            ;;
        *)
            gum_error "Unknown engine command: $cmd"
            echo "Run 'llm-mini engine help' for usage." >&2
            return 1
            ;;
    esac
}

main "$@"
