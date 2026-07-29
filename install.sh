#!/bin/bash
# claude-radar installer.
#
# Everything it touches is backed up first and printed at the end, so you can
# undo it by hand if you ever want to. `./install.sh --uninstall` reverses it.

set -euo pipefail

TOOLS="$HOME/.claude/tools"
BIN="$TOOLS/bin"
SETTINGS="$HOME/.claude/settings.json"
ZSHRC="$HOME/.zshrc"
STAMP="$(date +%Y%m%d-%H%M%S)"
SRC="$(cd "$(dirname "$0")" && pwd)/src"

say()  { printf '  %s\n' "$1"; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ── uninstall ────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--uninstall" ]; then
  step "Removing claude-radar"

  pkill -x claude-panel 2>/dev/null || true
  pkill -f cc_bridge.py 2>/dev/null || true
  say "stopped panel and bridge"

  if [ -f "$SETTINGS" ]; then
    cp "$SETTINGS" "$SETTINGS.bak.$STAMP"
    python3 - "$SETTINGS" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
hooks = data.get("hooks", {})
for event, entries in list(hooks.items()):
    kept = []
    for entry in entries:
        entry["hooks"] = [h for h in entry.get("hooks", [])
                          if "cc_notify.py" not in h.get("command", "")]
        if entry["hooks"]:
            kept.append(entry)
    if kept:
        hooks[event] = kept
    else:
        del hooks[event]
json.dump(data, open(path, "w"), ensure_ascii=False, indent=2)
PY
    say "removed hooks from settings.json (backup: settings.json.bak.$STAMP)"
  fi

  if grep -q "claude-radar" "$ZSHRC" 2>/dev/null; then
    cp "$ZSHRC" "$ZSHRC.bak.$STAMP"
    python3 - "$ZSHRC" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()
text = re.sub(r"\n# claude-radar.*?\n}\n", "\n", text, flags=re.S)
text = re.sub(r"\n# claude-radar[^\n]*\n[^\n]*\n", "\n", text)
open(path, "w").write(text)
PY
    say "removed keep-alive from .zshrc (backup: .zshrc.bak.$STAMP)"
  fi

  rm -f "$BIN/claude-panel" "$TOOLS"/{cmux_ctx.py,cc_notify.py,ccq.py,cc_bridge.py,panel-ensure.sh}
  rm -f "$HOME/.claude"/{cc-done.log,cc-tree.json,cc-jump-request,cc-bridge.log,cc-cmux-errors.log}
  say "removed scripts and state files"

  step "Done. Open a new tab to clear the old shell."
  exit 0
fi

# ── install ──────────────────────────────────────────────────────────────────
step "Checking requirements"
[ "$(uname)" = "Darwin" ] || { echo "macOS only."; exit 1; }
command -v swiftc >/dev/null || { echo "swiftc not found — install Xcode Command Line Tools: xcode-select --install"; exit 1; }
[ -d "/Applications/cmux.app" ] || say "warning: cmux.app not found — the panel will show an empty list"
say "ok"

step "Building the panel"
mkdir -p "$BIN"
swiftc -O "$SRC/ClaudePanel.swift" -o "$BIN/claude-panel"
say "built $BIN/claude-panel"

step "Installing scripts"
mkdir -p "$TOOLS"
cp "$SRC"/{cmux_ctx.py,cc_notify.py,ccq.py,cc_bridge.py,panel-ensure.sh} "$TOOLS/"
chmod +x "$TOOLS"/{cc_notify.py,ccq.py,panel-ensure.sh}
say "installed to $TOOLS"

step "Registering hooks"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak.$STAMP"
python3 - "$SETTINGS" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
hooks = data.setdefault("hooks", {})
wanted = {
    "Stop":             "python3 $HOME/.claude/tools/cc_notify.py done",
    "Notification":     "python3 $HOME/.claude/tools/cc_notify.py waiting",
    "UserPromptSubmit": "python3 $HOME/.claude/tools/cc_notify.py start",
}
added = []
for event, command in wanted.items():
    entries = hooks.setdefault(event, [])
    if any(command in h.get("command", "")
           for e in entries for h in e.get("hooks", [])):
        continue
    entries.append({"hooks": [{"type": "command", "command": command}]})
    added.append(event)
json.dump(data, open(path, "w"), ensure_ascii=False, indent=2)
print("  added: " + (", ".join(added) if added else "nothing (already present)"))
PY
say "backup: settings.json.bak.$STAMP"

step "Adding keep-alive to .zshrc"
if grep -q "claude-radar" "$ZSHRC" 2>/dev/null; then
  say "already present"
else
  cp "$ZSHRC" "$ZSHRC.bak.$STAMP" 2>/dev/null || true
  cat >> "$ZSHRC" <<'EOF'

# claude-radar — must start from inside cmux; its control socket only accepts
# live descendants of the terminal, so a launchd-started process is rejected.
[ -n "$CMUX_PANEL_ID" ] && {
  zsh "$HOME/.claude/tools/panel-ensure.sh"
  /usr/bin/python3 "$HOME/.claude/tools/cc_bridge.py" >/dev/null 2>&1 &
}
EOF
  say "added (backup: .zshrc.bak.$STAMP)"
fi

step "Starting"
zsh "$TOOLS/panel-ensure.sh" || true
sleep 2
if pgrep -x claude-panel >/dev/null; then
  say "panel is running — look at the bottom-right of your screen"
else
  say "panel did not start; run: zsh $TOOLS/panel-ensure.sh"
fi

step "Done"
say "Open a new terminal tab so the bridge starts, then click a row to jump."
say "Terminal version: alias ccq='python3 \$HOME/.claude/tools/ccq.py'"
