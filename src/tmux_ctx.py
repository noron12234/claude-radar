"""tmux backend.

Much simpler than the cmux one: tmux lets any process drive it, so there is no
control-socket ancestry restriction and no bridge process is needed. The panel
can focus a pane directly.

A tmux "pane" is the unit here — it is what actually holds a running agent.
Panes are grouped by window so the panel mirrors your split layout.
"""

import os
import subprocess

BACKEND = "tmux"

FORMAT = "|".join([
    "#{session_name}",
    "#{window_index}",
    "#{window_name}",
    "#{pane_id}",
    "#{pane_tty}",
    "#{pane_title}",
    "#{window_active}",
    "#{pane_active}",
    "#{session_attached}",
])


def _find_tmux():
    """Absolute path: hooks and background processes do not inherit a login PATH."""
    for candidate in ("/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"):
        if os.path.exists(candidate):
            return candidate
    return "tmux"


TMUX = _find_tmux()


def _tmux(args, timeout=5):
    try:
        r = subprocess.run([TMUX] + args, capture_output=True,
                           text=True, timeout=timeout)
        return r.stdout.strip() if r.returncode == 0 else ""
    except Exception:
        return ""


def available():
    """True when a tmux server is actually running with at least one pane."""
    return bool(_tmux(["list-panes", "-a", "-F", "#{pane_id}"]))


def tree():
    rows = []
    for line in _tmux(["list-panes", "-a", "-F", FORMAT]).splitlines():
        parts = line.split("|")
        if len(parts) < 9:
            continue
        sess, win, win_name, pane, tty, pane_title, w_act, p_act, attached = parts[:9]
        rows.append({
            "surface": pane,                      # e.g. "%3"
            "backend": BACKEND,
            "type": "terminal",
            # window name is what people rename per task; fall back to pane title
            "title": win_name or pane_title or pane,
            "busy": False,                        # state comes from hooks + CPU
            "selected": p_act == "1",
            "active": (w_act == "1" and p_act == "1" and attached == "1"),
            "tty": os.path.basename(tty),         # /dev/ttys004 -> ttys004
            "workspace": sess,
            "workspace_title": sess,
            "pane": f"{sess}:{win}",              # group rows by window
            "panel_id": pane,
        })
    return rows


def focus(row):
    """Bring a pane to the front. Returns True if tmux accepted it."""
    sess = row.get("workspace", "")
    pane = row.get("surface", "")
    if not pane:
        return False
    # switch-client only matters when a client is attached to another session
    if sess:
        _tmux(["switch-client", "-t", sess])
    _tmux(["select-window", "-t", pane])
    ok = _tmux(["select-pane", "-t", pane]) is not None
    for r in tree():
        if r["surface"] == pane:
            return r["selected"]
    return ok


def me():
    """The pane this process is running in, resolved via $TMUX_PANE."""
    pane = os.environ.get("TMUX_PANE", "")
    if not pane:
        return {}
    return next((r for r in tree() if r["surface"] == pane), {})
