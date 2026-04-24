#!/usr/bin/env bash
# llm-mini — CLI wrapper around llm-mini-core.sh.
#
# Install:
#   ln -sf ~/.claude/scripts/llm-mini.sh ~/.local/bin/llm-mini
#
# Usage:
#   llm-mini "what does jq -r do?"
#   llm-mini summarize README.md
#   git diff | llm-mini summarize
#   llm-mini --quality "explain this diff"
#   llm-mini engine status
#   llm-mini --list
#   llm-mini -h
#
# All flags and subcommands are passed through to llm-mini-core.sh.

exec bash "${HOME}/.claude/scripts/llm-mini-core.sh" "$@"
