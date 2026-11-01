#!/bin/bash
# Claude Float hook: sends Claude Code hook events to the Claude Float app.
#   wait  blocks until you answer in the float, then prints the decision
#   sync  waits briefly for a reply you queued in the float
#   (none) fire and forget
# If the app isn't running it prints nothing, so Claude behaves as normal.
token=$(cat "$HOME/.claude/float/token" 2>/dev/null) || exit 0
input=$(cat)
send() {
  printf '%s' "$input" | curl -sf --connect-timeout 1 --max-time "$1" \
    -H "X-Float-Token: $token" -H "X-Bundle: ${__CFBundleIdentifier:-}" \
    -H "Content-Type: application/json" --data-binary @- "http://127.0.0.1:47821/hook"
}
case "$1" in
  wait) send 3590 2>/dev/null ;;
  sync) send 2 2>/dev/null ;;
  *) send 3 >/dev/null 2>&1 & ;;
esac
exit 0
