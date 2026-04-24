#!/usr/bin/env bash
# llm-mini-hook.sh — sourceable mini-model callable for use inside Claude Code hooks.
#
# Usage (inside a hook script):
#   source ~/.claude/scripts/llm-mini-hook.sh
#   result=$(mini_quick "Summarize in 3 words: $PROMPT")
#
# Enforces a 3s timeout to stay within hook latency budget.
# Falls back to empty string on any failure (hooks must never block).
# Always uses local backend — no cold-start prompts in hook context.

LLM_MINI_CORE="${HOME}/.claude/scripts/llm-mini-core.sh"

mini_quick() {
    local prompt="$1"
    local template="${2:-}"
    local args=("--local" "--max-tokens" "100")
    if [[ -n "$template" ]]; then
        args+=("--template" "$template")
    fi
    local result
    result=$(echo "$prompt" | timeout 3 bash "$LLM_MINI_CORE" "${args[@]}" 2>/dev/null) || result=""
    printf '%s' "$result"
}
