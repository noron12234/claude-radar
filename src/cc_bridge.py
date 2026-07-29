#!/usr/bin/env python3
"""cc_bridge — 浮動面板與 cmux 之間的橋。

為什麼需要它：cmux 的 socket 只接受「活著的 cmux 後代行程」。
面板是長駐的背景程式，父行程一結束就被 launchd 收養（PPID=1），
socket 立刻回 Broken pipe。所以面板永遠不可能自己跟 cmux 講話。

這支橋接由 cc_notify hook 啟動 —— hook 是 claude 的子行程，
而 claude 活在 cmux 分頁裡，所以橋接是貨真價實的活後代，socket 通。

它做兩件事：
  1. 每 1.5 秒刷新分頁樹快取（面板讀快取，不需要 socket）
  2. 收面板丟過來的跳轉請求並代為執行

失去權限（父 claude 結束）時自己退出，讓下一個 hook 重新啟動一個有權限的。
"""

import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import terminal as ctx  # noqa: E402
import ccq  # noqa: E402

REQUEST = os.path.expanduser("~/.claude/cc-jump-request")
LOCK = "/tmp/claude-bridge.lock"
IDLE_EXIT = 3600  # 一小時沒事做就退場，交給下一個 hook 重啟


def socket_ok():
    return bool(ctx.tree())


LOG = os.path.expanduser("~/.claude/cc-bridge.log")


def log(msg):
    try:
        with open(LOG, "a") as f:
            f.write(f"{time.strftime('%H:%M:%S')} {msg}\n")
    except Exception:
        pass


def active_surface():
    for r in ctx.tree():
        if r.get("active"):
            return f"{r['surface']} {r['title']}"
    return "?"


def handle_request():
    """面板寫下一個 surface ref，我們代為跳過去。

    請求檔要**跳完才刪**：ccq 是靠「檔案消失」判斷跳轉完成，
    提早刪掉的話它會馬上回報成功，面板接著把 cmux 叫到前景，
    但實際切換還在後面慢慢做 —— 畫面停在舊分頁，看起來就是「按了沒跳」。

    也不要在這裡呼叫 ccq.collect()：它會跑 ps -A 和整棵樹，
    是點擊延遲的主要來源。工作區直接從快取好的樹查就夠了。
    """
    try:
        with open(REQUEST) as f:
            ref = f.read().strip()
    except Exception:
        return
    if not ref.startswith("surface:"):
        try:
            os.remove(REQUEST)
        except Exception:
            pass
        return

    tree = ctx.tree()
    before = next((f"{r['surface']} {r['title']}" for r in tree if r.get("active")), "?")
    row = next((r for r in tree if r["surface"] == ref), None)

    ok = ctx.focus(row) if row else False

    # focus-panel 回來就代表 cmux 已經執行了，這時才放行等待端。
    # 後面的記錄不該擋在點擊延遲上。
    try:
        os.remove(REQUEST)
    except Exception:
        pass

    log(f"jump {ref} ok={ok} | {before} -> {active_surface()}")


def main():
    # 單一實例：flock 才是原子的，pgrep 有 race
    import fcntl
    fd = os.open(LOCK, os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return

    if not socket_ok():
        return  # 沒權限就別佔著 lock

    # 請求要盯得很緊（點擊延遲全來自這裡），但刷新快取很貴，分開節奏：
    # 請求 0.15s 檢查一次（只是 os.path.exists），快取 1.5s 一次。
    last_request = time.time()
    last_refresh = 0.0
    while True:
        now = time.time()

        if os.path.exists(REQUEST):
            handle_request()
            last_request = now

        if now - last_refresh >= 1.5:
            if not socket_ok():
                return  # 父 shell 結束了，退場讓下一個分頁重啟
            ctx.tree()  # 副作用就是刷新 ~/.claude/cc-tree.json
            last_refresh = now

        if now - last_request > IDLE_EXIT:
            return
        time.sleep(0.15)


if __name__ == "__main__":
    main()
