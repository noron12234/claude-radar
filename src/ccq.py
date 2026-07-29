#!/usr/bin/env python3
"""ccq — 一眼看完所有 cmux 分頁裡的 Claude 在幹嘛，敲個編號直接跳過去。

  ccq          列出全部，敲編號跳；Enter 直接跳第一個等你回覆的
  ccq 3        直接跳第 3 個
  ccq -w       每 2 秒重刷，當看板掛著
"""

import json
import os
import subprocess
import sys
import time
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cmux_ctx as ctx  # noqa: E402

LOG = os.path.expanduser("~/.claude/cc-done.log")

STATES = {
    "permission": (0, "\033[35m", "⛔ 等你授權"),
    "waiting":    (1, "\033[33m", "🟠 等你回覆"),
    "done":       (2, "\033[31m", "🔴 做完了"),
    "busy":       (3, "\033[34m", "🔵 在跑"),
    "idle":       (4, "\033[2m",  "·  閒置"),
    "noclaude":   (5, "\033[2m",  "·  無 Claude"),
}


def width(s):
    """終端顯示寬度：CJK 與 emoji 算 2 格，variation selector 算 0。"""
    w = 0
    for c in s:
        o = ord(c)
        if o in (0xFE0F, 0x200D):
            continue
        wide = (o >= 0x1F300 or 0x2600 <= o <= 0x27BF or 0x2B00 <= o <= 0x2BFF
                or 0x23E9 <= o <= 0x23FA or 0x2E80 <= o <= 0xA4CF
                or 0xAC00 <= o <= 0xD7A3 or 0xFF00 <= o <= 0xFF60)
        w += 2 if wide else 1
    return w


def trunc(s, target):
    out = ""
    for c in s:
        if width(out + c) > target:
            return out + "…"
        out += c
    return out


def pad(s, target):
    return trunc(s, target) + " " * max(0, target - width(trunc(s, target)))


def claude_ttys():
    """{tty: CPU%} — 有跑 claude 的終端機與它的 CPU。

    CPU 是「真的在動」的直接證據，用來補事件的漏：session 若不是靠
    UserPromptSubmit 重新啟動（/loop、goal hook 續跑、背景任務回來），
    就不會有 start 事件，光看事件會誤判成閒置。實測抓到 CPU 11% 卻被判閒置。
    """
    try:
        out = subprocess.run(["ps", "-o", "tty=,%cpu=,command=", "-A"],
                             capture_output=True, text=True, timeout=6).stdout
    except Exception:
        return {}
    ttys = {}
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) != 3 or "/claude" not in parts[2] or parts[0] == "??":
            continue
        tty = parts[0] if parts[0].startswith("tty") else "tty" + parts[0]
        try:
            cpu = float(parts[1])
        except ValueError:
            cpu = 0.0
        ttys[tty] = max(ttys.get(tty, 0.0), cpu)
    return ttys


BUSY_CPU = 5.0   # 超過就當作正在生成


def last_events():
    """{surface_ref: (時間, 事件, 摘要)} — 每個分頁最後一次通知。"""
    seen = {}
    if not os.path.exists(LOG):
        return seen
    try:
        with open(LOG) as f:
            lines = f.readlines()[-500:]
    except Exception:
        return seen
    for line in lines:
        p = line.rstrip("\n").split("\t")
        if len(p) >= 9 and p[2].startswith("surface:"):
            seen[p[2]] = (p[0], p[1], p[8])
    return seen


def ago(iso):
    try:
        d = (datetime.now() - datetime.fromisoformat(iso)).total_seconds()
    except Exception:
        return ""
    if d < 60:
        return f"{int(d)} 秒前"
    if d < 3600:
        return f"{int(d // 60)} 分前"
    if d < 86400:
        return f"{int(d // 3600)} 小時前"
    return f"{int(d // 86400)} 天前"


def collect():
    """所有分頁，順序完全照 cmux 的排列 —— 不依狀態重排。

    面板是 cmux 分頁的鏡子：第幾列永遠對應第幾個分頁，位置不會跳動，
    才能靠肌肉記憶直接點。依狀態排序看似聰明，實際上每次都在換位置。
    """
    running = claude_ttys()
    events = last_events()
    me = ctx.me().get("surface", "")
    rows = []
    for s in ctx.tree():
        if s["type"] != "terminal":
            continue
        ref = s["surface"]
        ts, kind, summary = events.get(ref, ("", "", ""))
        cpu = running.get(s["tty"], 0.0)

        # 狀態是「這個分頁現在處於什麼情況」，不是「有沒有讀過通知」。
        #
        # 早期版本把 waiting/done 當成讀過就消失的通知，於是：
        #   · session 問你問題、你剛好在那個分頁 → 立刻被標已讀 → 塌回閒置，
        #     等你切走就再也看不到它在等你（實測漏掉）
        #   · 跑完的分頁被標已讀後也變閒置，跟真正沒事的分頁混在一起
        #
        # 現在改成純狀態機，會自我修正：
        #   start → 在跑；done → 做完了；waiting → 等你回覆；
        #   你回一句話 → 又是 start → 在跑。
        # CPU 高於門檻時一律當在跑，補掉「不經 UserPromptSubmit 就繼續跑」
        # 的情況（/loop、goal hook 續跑、背景任務回來）。
        if s["tty"] not in running:
            state = "noclaude"          # 分頁開著但裡面沒跑 Claude
        elif cpu >= BUSY_CPU:
            state = "busy"
        elif kind == "start":
            state = "busy"
        elif kind in ("permission", "waiting", "done"):
            state = kind
        elif s["busy"]:
            state = "busy"
        else:
            state = "idle"

        rows.append({**s, "state": state, "ts": ts, "summary": summary,
                     "here": ref == me, "cpu": cpu,
                     "has_claude": s["tty"] in running})
    return rows


def render(rows):
    print("\033[1m  #  狀態          分頁                             工作區      最後動作\033[0m")
    print("  " + "─" * 84)
    for i, r in enumerate(rows, 1):
        _, color, label = STATES[r["state"]]
        here = " \033[2m←你在這\033[0m" if r["here"] else ""
        print(f"  {i:>2} {color}{pad(label, 13)}\033[0m {pad(r['title'], 32)} "
              f"\033[2m{pad(r['workspace_title'], 10)}\033[0m {ago(r['ts'])}{here}")
        if r["summary"] and r["state"] in ("done", "waiting"):
            print(f"     \033[2m{trunc(r['summary'], 78)}\033[0m")
    print()


def jump(row):
    """跳到某個分頁，並且真的去確認有跳成功。

    ctx.run() 失敗時只回空字串，早期版本沒檢查就直接印「跳到…」，
    結果 socket 被拒時 log 全是假的成功訊息，害人查錯方向。
    """
    ws, ref = row["workspace"], row["surface"]
    a = ctx.run([ctx.CMUX, "select-workspace", "--workspace", ws])
    b = ctx.run([ctx.CMUX, "focus-panel", "--panel", ref, "--workspace", ws])

    ok = False
    for line in ctx.run([ctx.CMUX, "tree", "--all"]).splitlines():
        if f"surface {ref} " in line and "[selected]" in line:
            ok = True
            break

    if ok:
        print(f"\033[32m→ 跳到「{row['title']}」\033[0m")
        return

    # 連不上 socket（例如從浮動面板呼叫，它不是活著的 cmux 後代），
    # 就把請求丟給跑在 cmux 血緣內的 cc_bridge 代勞。
    #
    # 寫完要等它真的被消化才返回：面板拿到返回值後才會把 cmux 叫到前景，
    # 提早返回的話 cmux 會在切換發生前就上來，畫面還停在舊分頁，
    # 看起來就像「按了沒跳」。
    req = os.path.expanduser("~/.claude/cc-jump-request")
    try:
        with open(req, "w") as f:
            f.write(ref)
    except Exception as e:
        print(f"\033[31m✗ 跳轉失敗「{row['title']}」 {e}\033[0m")
        return

    for _ in range(40):          # 最多等 4 秒
        time.sleep(0.1)
        if not os.path.exists(req):
            print(f"\033[32m→ 橋接已跳到「{row['title']}」\033[0m")
            return
    print(f"\033[33m… 請求已排隊「{row['title']}」但橋接沒回應 "
          f"(select={a!r} focus={b!r})\033[0m")


def main():
    args = sys.argv[1:]

    if args and args[0] == "--json":
        print(json.dumps(collect(), ensure_ascii=False))
        return

    if args and args[0] == "--jump" and len(args) > 1:
        for r in collect():
            if r["surface"] == args[1]:
                jump(r)
                return
        return

    if args and args[0] in ("-w", "--watch"):
        try:
            while True:
                print("\033[2J\033[H", end="")
                print(f"\033[2m{datetime.now():%H:%M:%S} · ctrl-c 離開\033[0m\n")
                render(collect())
                time.sleep(2)
        except KeyboardInterrupt:
            return

    rows = collect()
    if not rows:
        print("找不到在跑 Claude 的 cmux 分頁")
        return

    if args and args[0].isdigit() and 1 <= int(args[0]) <= len(rows):
        jump(rows[int(args[0]) - 1])
        return

    render(rows)
    first = next((r for r in rows if r["state"] in ("waiting", "done")), rows[0])
    try:
        pick = input(f"跳去哪個？ [Enter = {first['title']}]  > ").strip()
    except (EOFError, KeyboardInterrupt):
        print()
        return
    if not pick:
        jump(first)
    elif pick.isdigit() and 1 <= int(pick) <= len(rows):
        jump(rows[int(pick) - 1])
    else:
        print("沒這個編號")


if __name__ == "__main__":
    main()
