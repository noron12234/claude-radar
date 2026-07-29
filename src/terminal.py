"""Terminal backend dispatch.

Both backends are used at once rather than picking one: people do run Claude
Code in cmux tabs and in tmux panes on the same machine, and a panel that
silently hides half of them is worse than useless.

Rows carry a `backend` field; `focus()` dispatches on it.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import cmux_ctx  # noqa: E402
import tmux_ctx  # noqa: E402

BACKENDS = (cmux_ctx, tmux_ctx)


def active_backends():
    return [b for b in BACKENDS if b.available()]


def tree():
    rows = []
    for backend in active_backends():
        try:
            rows.extend(backend.tree())
        except Exception:
            continue
    return rows


def me():
    for backend in active_backends():
        try:
            found = backend.me()
        except Exception:
            continue
        if found:
            return found
    return {}


def focus(row):
    name = row.get("backend", cmux_ctx.BACKEND)
    for backend in BACKENDS:
        if backend.BACKEND == name:
            try:
                return backend.focus(row)
            except Exception:
                return False
    return False
