# claude-radar

**An always-on-top panel that tells you which of your Claude Code sessions needs you — and jumps you there in 50ms.**

If you run one Claude Code session, you don't need this. If you run eight, you spend
your day cycling through tabs asking *"is this one done yet?"* — and missing the one
that quietly asked you a question twenty minutes ago.

```
┌──────────────────────────────────┐
│  CLAUDE                5 waiting │
├──────────────────────────────────┤
│  ● refactor auth      needs perm │  ← purple: blocked on a permission prompt
│  ● fix flaky test     asking you │  ← orange: asked you a question
│  ────────────────────────────────│  ← split matches your terminal layout
│  ● migrate schema        running │  ← blue: actually generating
│  ● write release notes      done │  ← red: finished, waiting on you
│  ○ scratch                  idle │
└──────────────────────────────────┘
        click any row → that tab is focused
```

It floats above fullscreen apps, survives Focus mode, and never steals your keyboard.

---

## Why not just use notifications?

Because they silently don't work, and it takes hours to figure out why. Three
independent channels — the terminal's own notifications, `osascript`, and
`terminal-notifier` — can all be delivered and none of them ever appear:

| Cause | Symptom | Why you don't notice |
|---|---|---|
| **Focus mode** | Notifications land in Notification Center, no banner | Focus is *supposed* to do this. Nothing errors. |
| **Main display** | Banner shows on the display holding the menu bar | If that's the monitor you're *not* looking at, it's invisible |
| **App is frontmost** | macOS suppresses an app's own banners while it's in front | You're staring at the terminal, so the terminal can't notify you |

Every one of these returns success. `osascript` exits 0. The notification *is*
delivered. It's just not shown to you.

claude-radar doesn't use the notification system at all. It draws its own window at
`.statusBar` level with `canJoinAllSpaces` + `fullScreenAuxiliary`, so it sits above
fullscreen apps on every Space and no OS-level setting can swallow it.

## Status comes from the agent, not from guesswork

Each row reflects Claude Code's own lifecycle, captured via hooks:

| Hook | State | Colour |
|---|---|---|
| `UserPromptSubmit` | running | blue |
| `Stop` | done — waiting on you | red |
| `Notification` | asking you a question | orange |
| `Notification` (permission) | **blocked on a permission prompt** | purple |
| — | idle / no agent in this tab | grey |

Two details that took a while to get right:

- **Don't read the spinner in the tab title.** It's a display convention, not run
  state. Finished sessions keep spinning glyphs; you'll show "running" forever.
- **Hooks alone miss resumed work.** A session restarted by a loop, a scheduled
  wake-up, or a background task returning never fires `UserPromptSubmit`. So the
  process CPU is sampled as corroboration — over ~5% means generating, whatever the
  last event said. (Measured a session at 11% CPU being reported as idle before this.)

State is a **state machine, not an inbox**. An earlier version treated "asking you" as
a notification that disappeared once seen — which meant a question raised while you
happened to be looking at that tab was marked read instantly and then vanished. If a
session is waiting, it stays orange until you actually answer it.

## The panel mirrors your layout

Rows appear in exactly your terminal's tab order, grouped by split pane with a
divider. Row 3 is always the same tab, so you can click it without reading it. Sorting
by urgency was tried and removed: it looks clever, but the rows move every time
anything changes, and you lose the muscle memory that makes it fast.

## Install

Requires macOS, [cmux](https://cmux.dev), and Claude Code.

```bash
git clone https://github.com/noron12234/claude-radar.git
cd claude-radar && ./install.sh
```

The installer builds the Swift binary, copies the scripts to `~/.claude/tools/`, adds
the hooks to `~/.claude/settings.json`, and appends a keep-alive line to `~/.zshrc`.
It backs up anything it touches and prints exactly what it changed.

Also included: `ccq`, a terminal version of the same board.

```
 #  STATE          TAB                          LAST
 1  ● asking you   fix flaky test               2m ago
 2  ● running      migrate schema
 3  ○ idle         scratch
```

## Uninstall

```bash
./install.sh --uninstall
```

Removes the hooks, the `.zshrc` line, the binary, and the state files. Your backups
stay.

## How it works

```
Claude Code hooks ──▶ ~/.claude/cc-done.log      (what each session is doing)
cmux session JSON ──▶ tty → terminal UUID        (which tab is which)
              ps ──▶ CPU per session             (corroboration)
                          │
                          ▼
                  claude-radar panel
                          │  click
                          ▼
     AppleScript: focus terminal id "<uuid>"     (~50ms)
```

Jumping goes through cmux's AppleScript interface rather than its control socket. The
socket only accepts processes that are live descendants of the terminal — a
long-running background panel is an orphan (`PPID 1`) and gets
`Broken pipe` forever. AppleScript has no such restriction. A helper process
(`cc_bridge.py`) refreshes the tab cache and exists as a fallback path; jumping does
not depend on it.

## Limitations

- **macOS only.** The panel is AppKit and jumping is AppleScript.
- **cmux only, for now.** The terminal-specific parts are confined to
  `src/cmux_ctx.py` (list tabs, resolve tty → id) and one AppleScript call. tmux
  should be simpler — it lets any process control it, so the bridge isn't needed at
  all. PRs welcome.
- **Permission detection is string-matching** the notification text, so a wording
  change upstream can turn purple rows orange.

## Alternatives

If you want a full dashboard rather than an ambient panel, look at
[claude-control](https://github.com/sverrirsig/claude-control) — it supports eight
terminals, approves permission prompts from the dashboard, and shows git/PR state per
session. It's a different job: a triage station you switch to, versus a panel you
never switch to. Running both is reasonable.

## License

MIT

---

## 中文

多開 Claude Code 時，這個常駐面板告訴你**哪一個在等你**，點一下 50ms 跳過去。

它不走 macOS 通知系統 —— 因為通知會被三層東西無聲吃掉：專注模式（照收但不顯示）、
banner 跑到你沒在看的主顯示器、以及 App 在最前景時不顯示自己的通知。三者都回報成功，
你什麼都看不到。面板自己畫視窗，蓋在全螢幕之上，跨所有桌面。

狀態來自 Claude Code 自己的生命週期 hook，不是猜的：送出訊息=在跑（藍）、
結束一輪=做完了（紅）、問你問題=等你回覆（橘）、要權限=**完全卡住**（紫）。
另外用行程 CPU 佐證，補掉「不經 `UserPromptSubmit` 就繼續跑」的情況。

面板的排列與分組**完全鏡射你的終端機版面**，第幾列永遠是第幾個分頁，
才能不用讀字直接點。依緊急度排序試過，會讓位置一直跳，反而更慢。
