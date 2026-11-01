#!/usr/bin/python3
"""Adds Claude Float's hooks to ~/.claude/settings.json, or takes them out again.

Usage: settings.py check | install | uninstall

Only Float's own entries are touched, so anything you change after installing
survives an uninstall. A file that isn't valid JSON is left exactly as it is.
"""

import json
import os
import shutil
import stat
import sys
import tempfile

HOOK = '"$HOME/.claude/float/hook.sh"'
PLUGIN = "float-bridge@float-local"
MARKETPLACE = "float-local"

TELL = {"type": "command", "command": HOOK, "timeout": 5}
SYNC = {"type": "command", "command": HOOK + " sync", "timeout": 5}
ASK = {
    "type": "command",
    "command": HOOK + " wait",
    "timeout": 3600,
    "statusMessage": "Waiting for your answer in Claude Float",
}
ENTRIES = {
    "UserPromptSubmit": {"hooks": [SYNC]},
    "PostToolUse": {"matcher": "*", "hooks": [SYNC]},
    "Notification": {"hooks": [TELL]},
    "Stop": {"hooks": [SYNC]},
    "SessionEnd": {"hooks": [TELL]},
    "PermissionRequest": {"matcher": "*", "hooks": [ASK]},
    "PreToolUse": {"matcher": "AskUserQuestion", "hooks": [ASK]},
}


def fail(message):
    sys.exit("Error: %s" % message)


def is_ours(hook):
    return isinstance(hook, dict) and str(hook.get("command", "")).startswith(HOOK)


def load(path):
    if not os.path.exists(path):
        return {}
    try:
        with open(path, encoding="utf-8") as f:
            settings = json.load(f)
    except ValueError as error:
        fail("%s isn't valid JSON (%s). Fix it and run this again. Nothing was changed." % (path, error))
    if not isinstance(settings, dict) or not isinstance(settings.get("hooks", {}), dict):
        fail("%s doesn't look like Claude Code settings. Nothing was changed." % path)
    return settings


def save(path, settings):
    # Writes through a symlink, so settings kept in a dotfiles repo stay linked.
    real = os.path.realpath(path)
    mode = stat.S_IMODE(os.stat(real).st_mode) if os.path.exists(real) else 0o600
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(real), prefix=".settings-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(settings, f, indent=2, ensure_ascii=False)
            f.write("\n")
        os.chmod(tmp, mode)
        os.replace(tmp, real)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def has_float(settings):
    return any(
        is_ours(hook)
        for groups in settings.get("hooks", {}).values()
        for group in groups
        for hook in group.get("hooks", [])
    )


def strip(settings):
    """Removes Float's hooks, and whatever that alone left empty."""
    hooks = settings.get("hooks", {})
    for event in list(hooks):
        kept = []
        for group in hooks[event]:
            inner = group.get("hooks", [])
            rest = [hook for hook in inner if not is_ours(hook)]
            if len(rest) == len(inner):
                kept.append(group)
            elif rest:
                kept.append({**group, "hooks": rest})
        if kept != hooks[event]:
            if kept:
                hooks[event] = kept
            else:
                del hooks[event]
                if not hooks:
                    del settings["hooks"]


def forget(settings, key, name):
    """Claude Code removes these itself; this catches a plugin command that failed."""
    entries = settings.get(key)
    if isinstance(entries, dict) and name in entries:
        del entries[name]
        if not entries:
            del settings[key]


def main():
    action = sys.argv[1] if len(sys.argv) == 2 else ""
    if action not in ("check", "install", "uninstall"):
        fail("usage: settings.py check | install | uninstall")
    path = os.path.expanduser("~/.claude/settings.json")
    settings = load(path)
    if action == "install":
        # The backup is always a version without Float, even after a reinstall.
        if os.path.exists(path) and not has_float(settings):
            shutil.copy2(path, path + ".before-float")
        strip(settings)
        hooks = settings.setdefault("hooks", {})
        for event, entry in ENTRIES.items():
            hooks.setdefault(event, []).append(entry)
        save(path, settings)
    elif action == "uninstall" and os.path.exists(path):
        strip(settings)
        forget(settings, "enabledPlugins", PLUGIN)
        forget(settings, "extraKnownMarketplaces", MARKETPLACE)
        save(path, settings)


if __name__ == "__main__":
    main()
