#!/bin/bash
# Builds Claude Float into ~/Applications, installs the hook, and adds it to ~/.claude/settings.json.
set -euo pipefail
cd "$(dirname "$0")"
app="$HOME/Applications/Claude Float.app"
mkdir -p build "$app/Contents/MacOS" "$HOME/.claude/float"
swiftc -swift-version 5 -O -target arm64-apple-macos14.0 -o build/ClaudeFloat Sources/*.swift
cp build/ClaudeFloat "$app/Contents/MacOS/ClaudeFloat"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Claude Float</string>
  <key>CFBundleIdentifier</key><string>local.rohan.claudefloat</string>
  <key>CFBundleExecutable</key><string>ClaudeFloat</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign -s - --force "$app" >/dev/null 2>&1 || true
cp hook.sh "$HOME/.claude/float/hook.sh"

settings="$HOME/.claude/settings.json"
[ -f "$settings" ] || echo '{}' > "$settings"
cp "$settings" "$settings.before-float"
hook='"$HOME/.claude/float/hook.sh"'
jq --arg h "$hook" '
  def tell: {type: "command", command: $h, timeout: 5};
  def sync: {type: "command", command: ($h + " sync"), timeout: 5};
  def ask: {type: "command", command: ($h + " wait"), timeout: 3600, statusMessage: "Waiting for your answer in Claude Float"};
  def mine: .hooks | any(.command | startswith($h));
  def add(ev; entry): .hooks[ev] = ([(.hooks[ev] // [])[] | select(mine | not)] + [entry]);
  add("UserPromptSubmit"; {hooks: [sync]})
  | add("PostToolUse"; {matcher: "*", hooks: [sync]})
  | add("Notification"; {hooks: [tell]})
  | add("Stop"; {hooks: [sync]})
  | add("SessionEnd"; {hooks: [tell]})
  | add("PermissionRequest"; {matcher: "*", hooks: [ask]})
  | add("PreToolUse"; {matcher: "AskUserQuestion", hooks: [ask]})
' "$settings.before-float" > "$settings.tmp" && mv "$settings.tmp" "$settings"
# The Float mod: lets the float type into idle chats. Installed from a local marketplace.
rm -rf "$HOME/.claude/float/marketplace"
cp -R mod "$HOME/.claude/float/marketplace"
claude_bin="$HOME/.local/bin/claude"
"$claude_bin" plugin marketplace add "$HOME/.claude/float/marketplace" >/dev/null 2>&1 || "$claude_bin" plugin marketplace update float-local >/dev/null 2>&1 || true
"$claude_bin" plugin uninstall float-bridge@float-local >/dev/null 2>&1 || true
"$claude_bin" plugin install float-bridge@float-local

echo "Installed. Open it with: open \"$app\""
