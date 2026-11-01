# Claude Float

A small dot that floats over every window on your Mac and shows what your Claude Code chats are doing. Click it to answer permission prompts and questions, read and reply to today's chats, or start a new chat, all without leaving the app you're in.

This is an unofficial project. It isn't affiliated with or endorsed by Anthropic.

## Requirements

- macOS 14 or later
- Xcode Command Line Tools (`xcode-select --install`). You don't need full Xcode.
- Claude Code, on your `PATH`
- The default `~/.claude` folder. `CLAUDE_CONFIG_DIR` isn't supported.

I've only run it on macOS 26.6.1 on Apple silicon with Claude Code 2.1.310. It compiles for Intel, but I haven't run it there or on macOS 14.

## Install

```bash
git clone https://github.com/rohan-ahire1/claude-float.git
```

```bash
cd claude-float
```

```bash
./install.sh
```

```bash
open ~/Applications/"Claude Float.app"
```

The installer does four things:

- Builds the app into `~/Applications`
- Copies `hook.sh` to `~/.claude/float`
- Adds Float's hooks to `~/.claude/settings.json`, after saving a copy as `settings.json.before-float`
- Installs a small Claude Code mod, `float-bridge`, from a local marketplace

Run `./install.sh` again to update. To start Float when you log in, add it under System Settings > General > Login Items.

## Using it

Drag the dot to move it, and click it to open the panel. Right-click it for New chat and Quit.

The dot is orange with a count when chats need you, green when a chat has finished and you haven't looked at it, blue while chats are working, and gray when nothing is running.

When a chat needs you and you're in another app, the prompt shows up in the float. If Claude is already in front, the prompt stays there. Turn on "Ask here even when Claude is in front" in the right-click menu to always get it in the float. Switching to the chat's app while a prompt is waiting hands it back to that app.

How a reply reaches a chat depends on the chat:

| Chat | What happens |
| --- | --- |
| Started in the float | Goes straight in |
| Working elsewhere | Delivered by a hook at its next step |
| Idle, with the mod loaded | The mod submits it as your message |
| Idle, without the mod | Copied, then the chat opens so you can paste it |
| Ended | Continues in the float |

## Uninstall

```bash
./uninstall.sh
```

This removes the app, Float's hooks, the mod and `~/.claude/float`. It takes out only Float's own entries, so anything else you changed in your settings since installing stays. `settings.json.before-float` is left in place, and you can delete it.

## How it works

`hook.sh` posts Claude Code hook events to a small HTTP server inside the app, on `127.0.0.1:47821`. Hooks for prompts and questions hold their connection open until you answer. If the app isn't running or anything fails, the hook prints nothing and Claude asks you the normal way.

The list of chats comes from the transcripts in `~/.claude/projects` and the running sessions in `~/.claude/sessions`. Chats you start in the float run with `claude -p` in stream-json mode. The mod checks in with the app every 1.5 seconds so it can pick up replies for idle chats.

## Security

Float can approve tool calls for you, so the server only listens on loopback and every request must carry a random token. The token lives in `~/.claude/float/token`, readable only by your account. A prompt shows the tool's full input, up to 20,000 characters, so you can see what you're approving.

Any program running as you can read that token, so Float gives no protection against those. On a Mac shared with other people, another account could listen on port 47821 while Float isn't running, receive your token from a hook, and answer prompts. Don't use it on a Mac you share with people you don't trust.

## What it depends on

Float relies on parts of Claude Code that aren't public or stable: the `~/.claude/sessions` files, the transcript format, `claude://` links and the mod system. A Claude Code update can change any of them, and that part of Float would stop working until it's fixed here.

## License

MIT
