#!/bin/bash
# Removes Claude Float: the app, its hooks and mod in Claude Code, and ~/.claude/float.
# Your other settings stay as they are. ~/.claude/settings.json.before-float is kept as a backup.
set -euo pipefail
cd "$(dirname "$0")"

app="$HOME/Applications/Claude Float.app"
/usr/bin/python3 scripts/settings.py check
pkill -f "$app/Contents/MacOS/ClaudeFloat" 2>/dev/null || true

claude_bin=$(cat "$HOME/.claude/float/claude-path" 2>/dev/null || command -v claude || true)
if [ -x "$claude_bin" ]; then
  "$claude_bin" plugin uninstall float-bridge@float-local >/dev/null 2>&1 || true
  "$claude_bin" plugin marketplace remove float-local >/dev/null 2>&1 || true
fi
/usr/bin/python3 scripts/settings.py uninstall

rm -rf "$app" "$HOME/.claude/float"
defaults delete io.github.rohan-ahire1.claudefloat >/dev/null 2>&1 || true

echo "Claude Float is uninstalled."
