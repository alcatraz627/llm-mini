#!/usr/bin/env bash
# install.sh — Install llm-mini into ~/.claude/ and symlink the CLI.
#
# Usage:
#   bash install.sh          # install / update
#   bash install.sh --check  # verify installation
#
# What it does:
#   1. Copies scripts to ~/.claude/scripts/
#   2. Copies prompt templates to ~/.claude/assets/mini-prompts/
#   3. Creates config from example if none exists
#   4. Symlinks llm-mini into ~/.local/bin/
#   5. Registers the MCP server in ~/.claude/.mcp.json (if not present)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="${HOME}/.claude/scripts"
PROMPTS_DIR="${HOME}/.claude/assets/mini-prompts"
CONF_FILE="${HOME}/.claude/llm-mini.conf"
BIN_DIR="${HOME}/.local/bin"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
DIM='\033[2m'
RESET='\033[0m'

ok()   { printf "${GREEN}  ✓${RESET} %s\n" "$1"; }
warn() { printf "${YELLOW}  ⚠${RESET} %s\n" "$1"; }
err()  { printf "${RED}  ✗${RESET} %s\n" "$1"; }
dim()  { printf "${DIM}    %s${RESET}\n" "$1"; }

# ─── Check mode ──────────────────────────────────────────────────
if [[ "${1:-}" == "--check" ]]; then
    echo "llm-mini installation check"
    echo "─────────────────────────────"
    errors=0

    for f in llm-mini-core.sh llm-mini-engine.sh llm-mini-chat.sh llm-mini.sh llm-mini-hook.sh; do
        if [[ -f "${SCRIPTS_DIR}/$f" ]]; then
            ok "$f installed"
        else
            err "$f missing"; errors=$((errors + 1))
        fi
    done

    if [[ -f "${SCRIPTS_DIR}/llm-mini-mcp-server.js" ]]; then
        ok "MCP server installed"
    else
        err "MCP server missing"; errors=$((errors + 1))
    fi

    if [[ -d "$PROMPTS_DIR" ]] && ls "$PROMPTS_DIR"/*.prompt &>/dev/null; then
        ok "Prompt templates present ($(ls "$PROMPTS_DIR"/*.prompt | wc -l | tr -d ' '))"
    else
        err "Prompt templates missing"; errors=$((errors + 1))
    fi

    if [[ -f "$CONF_FILE" ]]; then
        ok "Config file exists"
    else
        warn "No config file (will use defaults)"
    fi

    if command -v llm-mini &>/dev/null; then
        ok "llm-mini on PATH ($(which llm-mini))"
    else
        err "llm-mini not on PATH"; errors=$((errors + 1))
    fi

    if command -v ollama &>/dev/null; then
        ok "Ollama installed"
    else
        warn "Ollama not installed (cloud-only mode)"
    fi

    echo "─────────────────────────────"
    if [[ $errors -eq 0 ]]; then
        ok "All checks passed"
    else
        err "$errors issue(s) found"
    fi
    exit $errors
fi

# ─── Install ─────────────────────────────────────────────────────
echo "Installing llm-mini..."
echo

# 1. Scripts
mkdir -p "$SCRIPTS_DIR"
for f in llm-mini-core.sh llm-mini-engine.sh llm-mini-chat.sh llm-mini.sh llm-mini-hook.sh llm-mini-mcp-server.js; do
    cp "${REPO_DIR}/$f" "${SCRIPTS_DIR}/$f"
    chmod +x "${SCRIPTS_DIR}/$f"
done
ok "Scripts → ${SCRIPTS_DIR}/"

# 2. Prompt templates
mkdir -p "$PROMPTS_DIR"
cp "${REPO_DIR}"/templates/*.prompt "$PROMPTS_DIR/"
ok "Templates → ${PROMPTS_DIR}/"

# 3. Config
if [[ ! -f "$CONF_FILE" ]]; then
    cp "${REPO_DIR}/llm-mini.conf.example" "$CONF_FILE"
    ok "Config created from example"
    dim "Edit with: llm-mini config edit"
else
    ok "Config already exists (kept)"
fi

# 4. Symlink
mkdir -p "$BIN_DIR"
ln -sf "${SCRIPTS_DIR}/llm-mini.sh" "${BIN_DIR}/llm-mini"
ok "Symlink → ${BIN_DIR}/llm-mini"

# 5. PATH check
if ! echo "$PATH" | tr ':' '\n' | grep -q "${BIN_DIR}"; then
    warn "${BIN_DIR} not in PATH"
    dim "Add to ~/.zshrc:  export PATH=\"\${HOME}/.local/bin:\$PATH\""
fi

# 6. MCP server registration check
MCP_JSON="${HOME}/.claude/.mcp.json"
if [[ -f "$MCP_JSON" ]]; then
    if grep -q "llm-mini" "$MCP_JSON" 2>/dev/null; then
        ok "MCP server already registered"
    else
        warn "MCP server not in .mcp.json — add manually or via /add-mcp"
        dim "Server path: ${SCRIPTS_DIR}/llm-mini-mcp-server.js"
    fi
else
    warn "No .mcp.json found"
fi

echo
ok "Installation complete!"
echo
dim "Quick test:  llm-mini 'what is 2+2?'"
dim "Full help:   llm-mini -h"
dim "Chat mode:   llm-mini chat"
