"""共用：從 cmux 讀出「我是哪個分頁」以及整棵分頁樹。

cmux 的階層是 window → workspace → pane → surface(分頁)。
People keep many tabs per workspace, one task each, so the *tab* (surface)
is the unit that matters — not the workspace.
"""

import json
import os
import re
import subprocess
from datetime import datetime

def _find_cmux():
    """launchd / cron 環境沒有 PATH，所以要能退回絕對路徑。"""
    for c in (os.environ.get("CMUX_CLAUDE_HOOK_CMUX_BIN"),
              os.environ.get("CMUX_BUNDLED_CLI_PATH"),
              "/Applications/cmux.app/Contents/Resources/bin/cmux",
              os.path.expanduser("~/Applications/cmux.app/Contents/Resources/bin/cmux")):
        if c and os.path.exists(c):
            return c
    return "cmux"


CMUX = _find_cmux()

# tree --all 的行： │   ├── surface surface:222 [terminal] "⠂ 標題" [selected] ◀ here tty=ttys015
SURFACE_RE = re.compile(
    r'surface (surface:\d+) \[(\w+)\] "(.*?)"(?P<rest>.*?)(?:tty=(\S+))?\s*$')
WORKSPACE_RE = re.compile(r'workspace (workspace:\d+) "(.*?)"')
PANE_RE = re.compile(r'pane (pane:\d+)')
SPINNER = re.compile(r"^[⠀-⣿✳✶✻✽·∗\s]+")


def _socket_password():
    """cmux socket 是 password 模式，密碼存在 cmux.json（600），不另外複製一份。

    面板由 launchd 啟動、在 cmux 外面，沒有密碼會被 socket 直接踢掉
    （Error: Failed to write to socket (Broken pipe)）。
    """
    if os.environ.get("CMUX_SOCKET_PASSWORD"):
        return os.environ["CMUX_SOCKET_PASSWORD"]
    path = os.path.expanduser("~/.config/cmux/cmux.json")
    try:
        raw = re.sub(r"^\s*//.*$", "", open(path).read(), flags=re.M)
        return json.loads(raw).get("automation", {}).get("socketPassword", "") or ""
    except Exception:
        return ""


_PASSWORD = _socket_password()


DEBUG_LOG = os.path.expanduser("~/.claude/cc-cmux-errors.log")


def run(args, timeout=6):
    env = dict(os.environ)
    if _PASSWORD:
        env["CMUX_SOCKET_PASSWORD"] = _PASSWORD
    try:
        r = subprocess.run(args, capture_output=True, text=True,
                           timeout=timeout, env=env)
        if r.returncode == 0:
            return r.stdout.strip()
        _debug(args, r.returncode, r.stdout, r.stderr)
    except Exception as e:
        _debug(args, "exception", "", repr(e))
    return ""


def _debug(args, rc, out, err):
    """cmux 指令失敗時把真正的錯誤留下來。

    早期只回空字串，害人一路猜錯方向（以為是 tty、環境變數、行程血緣）。
    """
    try:
        with open(DEBUG_LOG, "a") as f:
            f.write(f"{datetime.now().isoformat(timespec='seconds')}\t"
                    f"pid={os.getpid()} ppid={os.getppid()}\t"
                    f"{' '.join(args[1:])}\trc={rc}\t"
                    f"out={out.strip()[:200]!r}\terr={err.strip()[:300]!r}\n")
    except Exception:
        pass


def clean(title):
    """拿掉 cmux 在標題前面加的 spinner / 忙碌符號。"""
    return SPINNER.sub("", title or "").strip()


CACHE = os.path.expanduser("~/.claude/cc-tree.json")
SESSION_JSON = os.path.expanduser(
    "~/Library/Application Support/cmux/session-com.cmuxterm.app.json")


def panel_ids():
    """{tty: cmux 的 terminal UUID} —— 直接讀 cmux 的 session 檔，不碰 socket。

    有了 UUID 就能用 AppleScript 聚焦：
        tell application "cmux" to focus terminal id "<uuid>"
    這條路**沒有行程血緣限制**，孤兒行程照樣能跳（實測 0.24s 切到不同分頁），
    所以浮動面板不需要透過橋接就能自己跳轉。
    """
    out = {}

    def walk(o):
        if isinstance(o, dict):
            if o.get("ttyName") and o.get("id"):
                out[o["ttyName"]] = o["id"]
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)

    try:
        with open(SESSION_JSON) as f:
            walk(json.load(f))
    except Exception:
        pass
    return out


def tree():
    """分頁樹。cmux 外面的行程連不上 socket，所以改讀快取。

    cmux 的 socket 預設只接受「從 cmux 內部啟動的行程」（socketControlMode=cmuxOnly），
    launchd 起的浮動面板會被拒絕。但 hook 本身就跑在 cmux 分頁裡，
    所以由 hook 每次觸發時順手寫快取，面板讀快取 —— 不需要動 cmux 權限。
    """
    rows = _tree_from_cmux()
    if rows:
        try:
            with open(CACHE, "w") as f:
                json.dump(rows, f, ensure_ascii=False)
        except Exception:
            pass
        return rows
    try:
        with open(CACHE) as f:
            cached = json.load(f)
    except Exception:
        return []

    # panel_id 只是讀本機的 session JSON，不需要 socket，
    # 所以走快取時也要現補一份 —— 這樣面板不必等橋接刷新就能用 AppleScript 直跳。
    ids = panel_ids()
    for r in cached:
        r["panel_id"] = ids.get(r.get("tty", ""), r.get("panel_id", ""))
    return cached


def _tree_from_cmux():
    rows = []
    ids = panel_ids()
    ws_ref = ws_title = pane_ref = ""
    for line in run([CMUX, "tree", "--all"]).splitlines():
        m = WORKSPACE_RE.search(line)
        if m:
            ws_ref, ws_title = m.group(1), clean(m.group(2))
            pane_ref = ""
            continue
        # 記住分割窗，面板才能照你實際的版面分組
        m = PANE_RE.search(line)
        if m and "surface" not in line:
            pane_ref = m.group(1)
            continue
        m = SURFACE_RE.search(line)
        if not m:
            continue
        raw = m.group(3)
        rows.append({
            "surface": m.group(1),
            "type": m.group(2),
            "title": clean(raw) or "(未命名)",
            "busy": bool(SPINNER.match(raw)),
            "selected": "[selected]" in m.group("rest"),
            # [selected] 只代表「在自己那個分割窗裡被選中」，不代表你正在看它；
            # 兩個分割窗並排時，另一邊的 selected 分頁你可能根本沒看。
            # ◀ active 才是全域唯一的「當前分頁」。
            "active": "◀ active" in m.group("rest"),
            "tty": m.group(5) or "",
            "workspace": ws_ref,
            "workspace_title": ws_title,
            "pane": pane_ref,
            "panel_id": ids.get(m.group(5) or "", ""),
        })
    return rows


def my_tty():
    """這支程式所在的終端機（hook 是 claude 的子行程，共用同一個 tty）。"""
    pid = os.getpid()
    for _ in range(8):  # 往上爬到找得到 tty 的祖先為止
        out = run(["ps", "-o", "ppid=,tty=", "-p", str(pid)]).split()
        if not out:
            break
        parent, tty = out[0], (out[1] if len(out) > 1 else "")
        if tty and tty not in ("??", "-"):
            return tty if tty.startswith("tty") else "tty" + tty
        if parent in ("0", "1", str(pid)):
            break
        pid = parent
    return ""


def me():
    """我在哪個分頁。先用 tty 對，對不到才退回 cmux identify。"""
    rows = tree()
    tty = my_tty()
    if tty:
        for r in rows:
            if r["tty"] and r["tty"].endswith(tty.replace("tty", "")):
                return r

    out = run([CMUX, "identify"])
    if out:
        try:
            ref = json.loads(out).get("caller", {}).get("surface_ref", "")
            for r in rows:
                if r["surface"] == ref:
                    return r
        except Exception:
            pass
    return {}
