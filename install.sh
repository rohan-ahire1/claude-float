#!/bin/bash
# Builds Claude Float into ~/Applications, installs the hook, and adds it to ~/.claude/settings.json.
# Run it again to update.
set -euo pipefail
cd "$(dirname "$0")"

die() { echo "Error: $1" >&2; exit 1; }

[ "$(uname)" = Darwin ] || die "Claude Float only runs on macOS."
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ] || die "Claude Float needs macOS 14 or later."
xcode-select -p >/dev/null 2>&1 || die "The Xcode Command Line Tools are missing. Install them with: xcode-select --install"
[ -z "${CLAUDE_CONFIG_DIR:-}" ] || die "Claude Float only works with the default ~/.claude folder, and CLAUDE_CONFIG_DIR is set."
claude_bin=$(command -v claude || true)
for candidate in "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
  [ -n "$claude_bin" ] || { [ -x "$candidate" ] && claude_bin="$candidate"; } || true
done
[ -n "$claude_bin" ] || die "Claude Code isn't installed, or isn't on your PATH."
/usr/bin/python3 scripts/settings.py check

app="$HOME/Applications/Claude Float.app"
mkdir -p build
swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos14.0" -o build/ClaudeFloat Sources/*.swift

# Replaces the whole app: writing over a signed binary in place can get it killed at launch.
pkill -f "$app/Contents/MacOS/ClaudeFloat" 2>/dev/null || true
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$HOME/.claude/float"
chmod 700 "$HOME/.claude/float"
cp build/ClaudeFloat "$app/Contents/MacOS/ClaudeFloat"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Claude Float</string>
  <key>CFBundleIdentifier</key><string>io.github.rohan-ahire1.claudefloat</string>
  <key>CFBundleExecutable</key><string>ClaudeFloat</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign -s - --force "$app" >/dev/null 2>&1 || true

install -m 755 hook.sh "$HOME/.claude/float/hook.sh"
printf '%s\n' "$claude_bin" > "$HOME/.claude/float/claude-path"
/usr/bin/python3 scripts/settings.py install

# The Float mod: lets the float type into idle chats. Installed from a local marketplace.
rm -rf "$HOME/.claude/float/marketplace"
cp -R mod "$HOME/.claude/float/marketplace"
"$claude_bin" plugin marketplace add "$HOME/.claude/float/marketplace" >/dev/null 2>&1 \
  || "$claude_bin" plugin marketplace update float-local >/dev/null 2>&1 || true
"$claude_bin" plugin uninstall float-bridge@float-local >/dev/null 2>&1 || true
if ! "$claude_bin" plugin install float-bridge@float-local >/dev/null 2>&1; then
  echo "Warning: the Float mod didn't install, so replies to idle chats will be copied for you to paste. Everything else works." >&2
fi

echo "Installed. Open it with: open \"$app\""
