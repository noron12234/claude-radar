#!/usr/bin/env python3
"""Claude Code hook -> 帶「分頁名字」的通知。

用在 Stop / Notification hook，做三件事：
  1. cmux notify 綁到該分頁（點通知會跳到那個分頁）
  2. osascript 補一顆系統通知（cmux 通知權限沒開時的後路）
  3. 寫一行到 ~/.claude/cc-done.log，給 ccq 讀

stdin 吃 Claude Code hook 的 JSON。第一個參數是事件別：done / waiting
"""

import json
import os
import subprocess
import sys
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import terminal as ctx  # noqa: E402

LOG = os.path.expanduser("~/.claude/cc-done.log")


def notify(title, subtitle, body):
    """Best-effort desktop notification.

    Kept only as a courtesy: on macOS this is routinely delivered and never
    shown (Focus mode, the banner landing on a display you are not looking at,
    or the terminal being frontmost). The panel is the reliable channel.
    """
    def esc(s):
        return s.replace("\\", "\\\\").replace('"', '\\"')

    try:
        subprocess.run(
            ["osascript", "-e",
             f'display notification "{esc(body or subtitle)}" '
             f'with title "{esc(title)}" subtitle "{esc(subtitle)}"'],
            capture_output=True, timeout=5)
    except Exception:
        pass


def last_assistant_line(transcript_path, limit=110):
    """從 transcript 撈最後一句助理文字，當通知內文。"""
    if not transcript_path or not os.path.exists(transcript_path):
        return ""
    try:
        with open(transcript_path, "rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - 400_000))
            tail = f.read().decode("utf-8", "ignore").splitlines()
    except Exception:
        return ""

    for line in reversed(tail):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            rec = json.loads(line)
        except Exception:
            continue
        if rec.get("type") != "assistant":
            continue
        for block in rec.get("message", {}).get("content", []) or []:
            if isinstance(block, dict) and block.get("type") == "text":
                text = " ".join(block.get("text", "").split())
                if text:
                    return text[:limit] + ("…" if len(text) > limit else "")
    return ""


def drain_jump_request():
    """橋接不在時的退路。

    橋接只在開新分頁時才會復活，中間可能空窗很久，那段時間點面板等於沒反應。
    但 hook 自己就跑在 cmux 血緣內、有 socket 權限，順手把待處理的請求做掉即可。
    With a dozen sessions open, some hook fires every few seconds,
    so the fallback usually lands within seconds.
    """
    req = os.path.expanduser("~/.claude/cc-jump-request")
    if not os.path.exists(req):
        return
    try:
        with open(req) as f:
            ref = f.read().strip()
        os.remove(req)
    except Exception:
        return
    if not ref.startswith("surface:"):
        return
    for r in ctx.tree():
        if r["surface"] == ref:
            ctx.focus(r)
            return


def main():
    kind = sys.argv[1] if len(sys.argv) > 1 else "done"
    try:
        data = json.loads(sys.stdin.read() or "{}")
    except Exception:
        data = {}

    if kind == "done" and data.get("stop_hook_active"):
        return  # 續跑中，不是真的結束

    cwd = data.get("cwd") or os.getcwd()
    repo = os.path.basename(cwd.rstrip("/")) or cwd
    me = ctx.me()
    tab = me.get("title") or repo
    ws = me.get("workspace_title") or ""

    if kind == "error":
        # PostToolUseFailure：工具呼叫失敗。沒有這個的話，出錯的 session
        # 因為最後一筆事件還是 start，會一直顯示成「在跑」。
        body = (data.get("tool_name", "") or "") + " " + (data.get("error", "") or "")
        body = " ".join(body.split())[:200]
    elif kind == "start":
        # UserPromptSubmit：只記「這個分頁開始跑了」，不發通知。
        # 有這筆才能可靠判斷在跑 —— 原本靠分頁標題的 spinner 符號猜，
        # 那是顯示慣例不是執行狀態，跑完的分頁常被誤判成還在跑。
        body = ""
    elif kind == "waiting":
        # Notification hook 同時涵蓋「問你問題」與「要你授權工具」，
        # 但後者是完全卡住、動都不能動，值得分開一個狀態。
        body = data.get("message", "")
        if "permission" in body.lower() or "授權" in body:
            kind = "permission"
            icon, state = "⛔", "等你授權"
        else:
            icon, state = "🔔", "在等你回覆"
        notify(f"{icon} {tab}",
               " · ".join(x for x in (state, ws, repo) if x), body)
    else:
        icon, state = "✅", "做完了"
        body = last_assistant_line(data.get("transcript_path"))
        notify(f"{icon} {tab}",
               " · ".join(x for x in (state, ws, repo) if x), body)

    # hook 跑在 cmux 內部，正好拿來當面板的 keepalive（launchd 起的沒有 socket 權限）
    ensure = os.path.expanduser("~/.claude/tools/panel-ensure.sh")
    if os.path.exists(ensure):
        try:
            subprocess.Popen(["/bin/zsh", ensure],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
        except Exception:
            pass

    drain_jump_request()

    try:
        with open(LOG, "a") as f:
            f.write("\t".join([
                datetime.now().isoformat(timespec="seconds"),
                kind,
                me.get("surface", "-"),
                me.get("workspace", "-"),
                tab, ws, cwd,
                data.get("session_id", "-"),
                (body or "").replace("\t", " "),
            ]) + "\n")
    except Exception:
        pass


if __name__ == "__main__":
    main()
