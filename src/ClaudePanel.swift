// ClaudePanel — 螢幕角落常駐的浮動面板，顯示哪個 Claude Code 分頁做完了。
//
// 不靠 macOS 通知，所以專注模式擋不到。永遠置頂、跨所有桌面、蓋在全螢幕 App 上。
// 點任一列直接跳到那個 cmux 分頁。拖曳可移動，位置會記住。
//
// 編譯：swiftc -O ClaudePanel.swift -o bin/claude-panel

import Cocoa

// MARK: - 資料

struct Row: Decodable {
    let surface: String
    let title: String
    let workspace_title: String
    let state: String
    let ts: String
    let summary: String
    let here: Bool
    let active: Bool?      // cmux 的 ◀ active：全域唯一的當前分頁
    let pane: String?      // 屬於哪個分割窗，面板照這個分組
    let panel_id: String?  // cmux terminal UUID，用 AppleScript 直接聚焦
    let backend: String?   // "cmux" 或 "tmux"，決定用哪條路跳
    let workspace: String? // tmux 的 session 名稱
}

/// 介面語言。預設英文；個人使用可切中文：
///     defaults write claude-panel lang zh
enum L {
    static let zh = UserDefaults.standard.string(forKey: "lang") == "zh"
    static func t(_ en: String, _ cn: String) -> String { zh ? cn : en }
}

enum Style {
    static let width: CGFloat = 320
    static let rowHeight: CGFloat = 34
    static let headerHeight: CGFloat = 30
    static let padding: CGFloat = 8
    static let maxRows = 18       // 分頁全列出來，順序照 cmux 排列
    static let dividerHeight: CGFloat = 9   // 分割窗之間的分隔
    static let timerHeight: CGFloat = 30    // 底部工時列

    static func tint(_ state: String) -> NSColor {
        switch state {
        case "permission": return NSColor.systemPurple   // 完全卡住，最該先處理
        case "waiting":    return NSColor.systemOrange
        case "done":       return NSColor.systemRed
        case "busy":       return NSColor.systemBlue
        default:           return NSColor.quaternaryLabelColor
        }
    }

    static func label(_ state: String) -> String {
        switch state {
        case "permission": return L.t("needs you", "等你授權")
        case "waiting":    return L.t("asking you", "等你回覆")
        case "done":       return L.t("done", "做完了")
        case "busy":       return L.t("running", "在跑")
        case "noclaude":   return L.t("no agent", "無 Claude")
        default:           return L.t("idle", "閒置")
        }
    }

    static func needsAttention(_ state: String) -> Bool {
        state == "waiting" || state == "done" || state == "permission"
    }
}

func ago(_ iso: String) -> String {
    guard !iso.isEmpty else { return "" }
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
    var date = fmt.date(from: iso)
    if date == nil {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        date = df.date(from: iso)
    }
    guard let d = date else { return "" }
    let s = Int(Date().timeIntervalSince(d))
    if s < 60 { return L.t("just now", "剛剛") }
    if s < 3600 { return L.t("\(s / 60)m ago", "\(s / 60) 分前") }
    if s < 86400 { return L.t("\(s / 3600)h ago", "\(s / 3600) 小時前") }
    return L.t("\(s / 86400)d ago", "\(s / 86400) 天前")
}

// MARK: - 狀態圓點

/// 要注意的填實心、其他只留描邊 —— 一眼掃下來紅點就是待辦。
final class DotView: NSView {
    private let color: NSColor
    private let filled: Bool

    init(color: NSColor, filled: Bool) {
        self.color = color
        self.filled = filled
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75))
        if filled {
            color.setFill()
            path.fill()
        } else {
            color.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }
}

// MARK: - 單列

final class RowView: NSView {
    private let row: Row
    private let onClick: (Row) -> Void
    private var hovering = false
    private var track: NSTrackingArea?

    init(row: Row, onClick: @escaping (Row) -> Void) {
        self.row = row
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        // 待處理的整列上底色（顏色跟著狀態走），掃一眼就看得到
        layer?.backgroundColor = restingBackground
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        // 一行到底：狀態圓點 + 分頁名 + 右側狀態字。全部分頁都列，所以要夠緊湊。
        // 閒置才是空心；在跑與待處理都填實心，否則兩者一眼分不出來
        let dot = DotView(color: Style.tint(row.state),
                          filled: row.state != "idle")
        dot.translatesAutoresizingMaskIntoConstraints = false
        let dotSize: CGFloat = Style.needsAttention(row.state) ? 8
                             : (row.state == "busy" ? 7 : 4)

        let title = NSTextField(labelWithString: row.title)
        title.font = .systemFont(ofSize: 12,
                                 weight: Style.needsAttention(row.state) ? .semibold : .regular)
        title.textColor = row.state == "idle" ? .tertiaryLabelColor : .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let attention = Style.needsAttention(row.state)
        let tint = Style.tint(row.state)
        let meta = NSTextField(labelWithString: "")
        meta.attributedStringValue = {
            let text = NSMutableAttributedString()
            text.append(NSAttributedString(
                string: Style.label(row.state),
                attributes: [.font: NSFont.systemFont(ofSize: 10,
                                                      weight: attention ? .semibold : .medium),
                             .foregroundColor: tint]))
            if attention, !ago(row.ts).isEmpty {
                text.append(NSAttributedString(
                    string: " · " + ago(row.ts),
                    attributes: [.font: NSFont.systemFont(ofSize: 9.5),
                                 .foregroundColor: tint.withAlphaComponent(0.6)]))
            }
            return text
        }()
        meta.setContentCompressionResistancePriority(.required, for: .horizontal)
        meta.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [dot, title, meta])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 9, bottom: 0, right: 9)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: dotSize),
            dot.heightAnchor.constraint(equalToConstant: dotSize),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        if row.here {
            let here = NSView()
            here.wantsLayer = true
            here.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
            here.layer?.cornerRadius = 1
            here.translatesAutoresizingMaskIntoConstraints = false
            addSubview(here)
            NSLayoutConstraint.activate([
                here.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
                here.widthAnchor.constraint(equalToConstant: 2),
                here.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                here.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            ])
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = track { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways],
                               owner: self)
        addTrackingArea(t)
        track = t
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.09).cgColor
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        layer?.backgroundColor = restingBackground
        NSCursor.arrow.set()
    }

    private var restingBackground: CGColor {
        Style.needsAttention(row.state)
            ? Style.tint(row.state).withAlphaComponent(0.13).cgColor
            : NSColor.clear.cgColor
    }

    /// 面板是 non-activating panel、視窗又設了 isMovableByWindowBackground。
    /// 不實作 mouseDown 的話事件會被丟回視窗去做拖曳，這一列永遠收不到 mouseUp。
    /// acceptsFirstMouse 則是讓面板沒有 key focus 時第一下點擊就生效。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // 吃掉，不往上傳
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p) else { return }
        flash()
        onClick(row)
    }

    /// 立刻給回饋。跳轉本身是背景執行的，不閃一下會覺得點了沒反應。
    private func flash() {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            animator().layer?.backgroundColor = hovering
                ? NSColor.labelColor.withAlphaComponent(0.09).cgColor
                : restingBackground
        }
    }
}


// MARK: - 工時計時

/// 累計工作時間，並在連續工作太久時提醒休息眼睛。
///
/// 提醒不走系統通知 —— 這整個專案存在的原因就是通知不會顯示。
/// 改成讓計時那一列自己變色，反正面板本來就一直在你眼前。
final class WorkTimer {
    static let breakAfter: TimeInterval = 20 * 60   // 20-20-20 法則
    static let breakLength: TimeInterval = 20       // 看遠方 20 秒

    private let defaults = UserDefaults.standard
    private let kAccumulated = "timerAccumulated"
    private let kStartedAt = "timerStartedAt"
    private let kSinceBreak = "timerSinceBreak"

    /// 累計總工時（含目前這段）
    var total: TimeInterval {
        var t = defaults.double(forKey: kAccumulated)
        if let started = startedAt { t += Date().timeIntervalSince(started) }
        return t
    }

    /// 距離上次休息累積了多久
    var sinceBreak: TimeInterval {
        var t = defaults.double(forKey: kSinceBreak)
        if let started = startedAt { t += Date().timeIntervalSince(started) }
        return t
    }

    var running: Bool { startedAt != nil }
    var needsBreak: Bool { running && sinceBreak >= Self.breakAfter }

    private var startedAt: Date? {
        get { defaults.object(forKey: kStartedAt) as? Date }
        set { defaults.set(newValue, forKey: kStartedAt) }
    }

    func toggle() {
        if let started = startedAt {
            let span = Date().timeIntervalSince(started)
            defaults.set(defaults.double(forKey: kAccumulated) + span, forKey: kAccumulated)
            defaults.set(defaults.double(forKey: kSinceBreak) + span, forKey: kSinceBreak)
            startedAt = nil
            // 暫停就當成休息了：夠長才把眼睛的計時歸零
            if span >= 0 || true { }
        } else {
            // 重新開始 = 剛休息完，眼睛計時歸零
            defaults.set(0.0, forKey: kSinceBreak)
            startedAt = Date()
        }
    }

    /// 整個歸零（option-click）
    func reset() {
        defaults.set(0.0, forKey: kAccumulated)
        defaults.set(0.0, forKey: kSinceBreak)
        startedAt = nil
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(max(0, t))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// 底部那一列：工時 + 點擊暫停/繼續 + 休息提醒。
final class TimerRow: NSView {
    private let timer: WorkTimer
    private let onToggle: () -> Void
    private let onReset: () -> Void
    private let icon = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private let note = NSTextField(labelWithString: "")

    init(timer: WorkTimer, onToggle: @escaping () -> Void, onReset: @escaping () -> Void) {
        self.timer = timer
        self.onToggle = onToggle
        self.onReset = onReset
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        build()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        icon.font = .systemFont(ofSize: 11)
        time.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        note.font = .systemFont(ofSize: 9.5)
        note.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [icon, time, note])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 9, bottom: 0, right: 9)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func refresh() {
        time.stringValue = WorkTimer.format(timer.total)

        if timer.needsBreak {
            icon.stringValue = "👁"
            time.textColor = .systemYellow
            note.stringValue = L.t("look 20ft away for 20s", "看遠方 20 秒，休息眼睛")
            note.textColor = .systemYellow
            layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.16).cgColor
        } else if timer.running {
            icon.stringValue = "▮▮"
            time.textColor = .labelColor
            let left = WorkTimer.breakAfter - timer.sinceBreak
            note.stringValue = L.t("working · break in \(Int(left / 60))m",
                                   "工作中 · 還有 \(Int(left / 60)) 分該休息")
            note.textColor = .tertiaryLabelColor
            layer?.backgroundColor = NSColor.clear.cgColor
        } else {
            icon.stringValue = "▶"
            time.textColor = .secondaryLabelColor
            note.stringValue = L.t("paused · click to resume", "已暫停 · 點一下繼續")
            note.textColor = .tertiaryLabelColor
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if event.modifierFlags.contains(.option) {
            onReset()
        } else {
            onToggle()
        }
    }
}

// MARK: - 面板

final class Panel: NSPanel {
    /// .nonactivatingPanel 的重點就是「可以成為 key window，但不會把 App 搶到前景」。
    /// 這裡若寫死 false，視窗永遠不是 key，滑鼠事件不會派送到 subview，點了沒反應。
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class Controller: NSObject, NSApplicationDelegate {
    private var panel: Panel!
    private var content: NSStackView!
    private var countLabel: NSTextField!
    private var timer: Timer?
    private var lastPayload = ""
    private var lastStale = false
    private var lastRows: [Row] = []
    private let workTimer = WorkTimer()
    private var timerRow: TimerRow!
    private var tick: Timer?
    private var signalSource: DispatchSourceSignal?

    private let ccq = NSHomeDirectory() + "/.claude/tools/ccq.py"
    private let originKey = "panelOrigin"

    /// 收到 SIGUSR1 就對「不是當前分頁」的第一列跑一次真正的點擊流程。
    /// 用來在沒有滑鼠的情況下實測點擊路徑本身，而不是只測底層的寫檔。
    ///   kill -USR1 $(pgrep -x claude-panel)
    private func installSelfTest() {
        signal(SIGUSR1, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        src.setEventHandler { [weak self] in
            guard let self,
                  let row = self.lastRows.first(where: { $0.active != true }) else { return }
            self.log("自我測試：模擬點擊「\(row.title)」")
            self.jump(row)
        }
        src.resume()
        signalSource = src
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildPanel()
        installSelfTest()
        refresh()
        // 每次輪詢會 spawn python + 跑 ps -A（機器上有近 300 個行程），
        // 2 秒一次太密會讓面板一頓一頓的，3 秒足夠即時又不吃 CPU。
        tick = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.timerRow.refresh()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: 建立視窗

    private func buildPanel() {
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: Style.width, height: 120),
                      styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar                       // 蓋得過全螢幕 App
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.borderWidth = 0.5
        blur.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        panel.contentView = blur

        // 標題列
        let brand = NSTextField(labelWithString: "CLAUDE")
        brand.font = .systemFont(ofSize: 9.5, weight: .semibold)
        brand.textColor = .tertiaryLabelColor

        countLabel = NSTextField(labelWithString: "")
        countLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        countLabel.textColor = .secondaryLabelColor

        let header = NSStackView(views: [brand, NSView(), countLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)

        content = NSStackView(views: [])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 1

        timerRow = TimerRow(timer: workTimer,
                            onToggle: { [weak self] in
                                self?.workTimer.toggle()
                                self?.timerRow.refresh()
                            },
                            onReset: { [weak self] in
                                self?.workTimer.reset()
                                self?.timerRow.refresh()
                            })
        timerRow.translatesAutoresizingMaskIntoConstraints = false

        let root = NSStackView(views: [header, content, timerRow])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 4
        root.edgeInsets = NSEdgeInsets(top: 9, left: 4, bottom: 9, right: 4)
        root.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            root.topAnchor.constraint(equalTo: blur.topAnchor),
            header.heightAnchor.constraint(equalToConstant: Style.headerHeight - 12),
            header.widthAnchor.constraint(equalTo: root.widthAnchor),
            content.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -8),
            timerRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -8),
            timerRow.heightAnchor.constraint(equalToConstant: Style.timerHeight),
        ])

        panel.setFrameOrigin(savedOrigin())
        panel.orderFrontRegardless()

        // 拔插外接螢幕、改解析度時把面板拉回可見範圍
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.panel.setFrame(self.clamped(self.panel.frame), display: true)
            self.saveOrigin()
        }
    }

    /// 夾回螢幕可見範圍內。
    ///
    /// 面板高度會隨分頁數變動，而版面是「固定頂端往下長」，分頁一多 y 就被推成負的、
    /// 整個掉出畫面底部（實測存到 y=-40）。而且 saveOrigin() 還會把壞掉的位置存起來。
    /// 拔掉外接螢幕、解析度改變時同理。
    private func clamped(_ frame: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return frame }
        var f = frame
        f.origin.x = min(max(f.origin.x, visible.minX + 8), visible.maxX - f.width - 8)
        f.origin.y = min(max(f.origin.y, visible.minY + 8), visible.maxY - f.height - 8)
        return f
    }

    /// 預設放在「滑鼠所在那台螢幕」的右下角 —— 主顯示器不一定是你正在看的那台。
    private func savedOrigin() -> NSPoint {
        if let s = UserDefaults.standard.string(forKey: originKey) {
            let p = NSPointFromString(s)
            if NSScreen.screens.contains(where: { $0.frame.contains(p) }) { return p }
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let f = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: f.maxX - Style.width - 20, y: f.minY + 20)
    }

    private func saveOrigin() {
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: originKey)
    }

    // MARK: 資料更新

    /// 出問題時寫進 /tmp/claude-panel.log，不然 launchd 底下完全看不出哪裡壞。
    private func log(_ msg: String) {
        let line = "[\(Date())] \(msg)\n"
        if let d = line.data(using: .utf8),
           let fh = FileHandle(forWritingAtPath: "/tmp/claude-panel.log") {
            fh.seekToEndOfFile()
            fh.write(d)
            try? fh.close()
        }
    }

    private func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            guard let data = self.shell(["/usr/bin/python3", self.ccq, "--json"]) else {
                self.log("shell 執行失敗: \(self.ccq)")
                return
            }
            guard let rows = try? JSONDecoder().decode([Row].self, from: data) else {
                let raw = String(data: data, encoding: .utf8) ?? "<非 UTF-8>"
                self.log("JSON 解析失敗，ccq 實際輸出: \(raw.prefix(400))")
                return
            }
            let payload = String(data: data, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                // 橋接死掉時 payload 會凍住不變，只比對 payload 的話標頭
                // 永遠不會更新成「橋接停止」，所以狀態翻轉也要重畫。
                let stale = self.bridgeStale()
                guard payload != self.lastPayload || stale != self.lastStale else { return }
                self.lastPayload = payload
                self.lastStale = stale
                self.lastRows = rows
                self.render(rows)
            }
        }
    }

    /// 橋接每 1.5 秒會刷新分頁樹快取；超過 15 秒沒動就是它不在了。
    private func bridgeStale() -> Bool {
        let cache = NSHomeDirectory() + "/.claude/cc-tree.json"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: cache),
              let modified = attrs[.modificationDate] as? Date else { return true }
        return Date().timeIntervalSince(modified) > 15
    }

    private func render(_ all: [Row]) {
        // 全部分頁都列，順序照 cmux 排列，第幾列永遠對應第幾個分頁。
        let shown = Array(all.prefix(Style.maxRows))
        let pending = all.filter { Style.needsAttention($0.state) }.count

        // 橋接停了的話清單會變舊、點了也不會跳。與其靜默失效，不如講出來。
        if bridgeStale() {
            countLabel.stringValue = L.t("bridge stopped · open a new tab", "橋接停止 · 開新分頁即復原")
            countLabel.textColor = .systemOrange
        } else {
            countLabel.stringValue = pending > 0
                ? L.t("\(pending) waiting", "\(pending) 個等你")
                : L.t("\(all.count) tabs", "\(all.count) 個分頁")
            countLabel.textColor = pending > 0 ? .systemRed : .tertiaryLabelColor
        }

        content.arrangedSubviews.forEach {
            content.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        if shown.isEmpty {
            let empty = NSTextField(labelWithString: L.t("no tabs", "沒有分頁"))
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .tertiaryLabelColor
            let wrap = NSView()
            wrap.translatesAutoresizingMaskIntoConstraints = false
            empty.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(empty)
            content.addArrangedSubview(wrap)   // 先進 hierarchy 再綁 constraint
            NSLayoutConstraint.activate([
                empty.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 10),
                empty.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
                wrap.heightAnchor.constraint(equalToConstant: 28),
                wrap.widthAnchor.constraint(equalTo: content.widthAnchor),
            ])
        }

        // 依分割窗分組：cmux 怎麼切版面，面板就怎麼分段
        var dividers = 0
        var lastPane: String? = shown.first?.pane
        for row in shown {
            if row.pane != lastPane {
                lastPane = row.pane
                let line = NSView()
                line.wantsLayer = true
                line.layer?.backgroundColor = NSColor.labelColor
                    .withAlphaComponent(0.14).cgColor
                line.translatesAutoresizingMaskIntoConstraints = false
                content.addArrangedSubview(line)
                NSLayoutConstraint.activate([
                    line.heightAnchor.constraint(equalToConstant: Style.dividerHeight),
                    line.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -18),
                ])
                dividers += 1
            }
            let v = RowView(row: row) { [weak self] r in self?.jump(r) }
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addArrangedSubview(v)
            NSLayoutConstraint.activate([
                v.heightAnchor.constraint(equalToConstant: Style.rowHeight),
                v.widthAnchor.constraint(equalTo: content.widthAnchor),
            ])
        }

        let bodyHeight = shown.isEmpty
            ? 28
            : CGFloat(shown.count) * (Style.rowHeight + 1)
              + CGFloat(dividers) * (Style.dividerHeight + 1)
        let height = Style.headerHeight + bodyHeight + Style.timerHeight + Style.padding * 2 + 4
        let top = panel.frame.maxY
        let wanted = NSRect(x: panel.frame.origin.x, y: top - height,
                            width: Style.width, height: height)
        panel.setFrame(clamped(wanted), display: true)
        saveOrigin()
    }

    /// 跳轉丟到背景做 —— 在主執行緒跑 shell 會凍住整個面板，點起來就是卡。
    ///
    /// cmux 的前景切換必須在 cmux 內部切完分頁「之後」才做：
    /// 先做的話，緊接著面板成為 key window 又會把 cmux 踢回背景，
    /// 結果是分頁確實切了、但畫面還停在別的 App，看起來像完全沒反應。
    /// 點擊要快，所以直接用 in-process AppleScript 聚焦。
    ///
    /// 走過的兩條慢路：
    ///   1. spawn `ccq --jump` —— ccq 會先跑 collect()（ps -A + 整棵樹）
    ///      再試三個註定失敗的 cmux 指令，實測 9.5 秒
    ///   2. 寫請求檔給橋接代跑 —— 好一點但仍要 150~500ms，偶爾卡到 2 秒
    ///
    /// cmux 的 socket 只認活著的後代行程，但它的 **AppleScript 介面沒有這個限制**，
    /// 孤兒行程照樣能聚焦（實測 osascript 子行程 0.24s，in-process 更快）。
    /// 所以面板自己跳就好，橋接只負責刷新快取。
    private func jump(_ row: Row) {
        let started = Date()

        // tmux 讓任何行程控制它，沒有 cmux 那種血緣限制，直接下指令即可
        if row.backend == "tmux", let pane = row.panel_id, !pane.isEmpty {
            let tmux = Self.tmuxPath
            if let session = row.workspace, !session.isEmpty {
                _ = shell([tmux, "switch-client", "-t", session])
            }
            _ = shell([tmux, "select-window", "-t", pane])
            _ = shell([tmux, "select-pane", "-t", pane])
            lastPayload = ""
            refresh()
            log("點擊「\(row.title)」→ tmux 已跳轉 \(Int(Date().timeIntervalSince(started) * 1000))ms")
            return
        }

        // cmux：走 AppleScript。它的 socket 只認活著的後代行程，
        // 但 AppleScript 介面沒有這個限制，孤兒行程照樣能聚焦。
        if row.backend != "tmux", let uuid = row.panel_id, !uuid.isEmpty {
            let script = NSAppleScript(
                source: "tell application \"cmux\" to focus terminal id \"\(uuid)\"")
            var err: NSDictionary?
            script?.executeAndReturnError(&err)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            if err == nil {
                lastPayload = ""
                refresh()
                log("點擊「\(row.title)」→ AppleScript 已跳轉 \(ms)ms")
                return
            }
            log("AppleScript 失敗(\(ms)ms)，改走橋接")
        }

        // 後路：拿不到 ID 或上面失敗時，交給橋接
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var landed = false
            do {
                try row.surface.write(toFile: self.requestPath, atomically: true, encoding: .utf8)
                for _ in 0..<100 {
                    Thread.sleep(forTimeInterval: 0.05)
                    if !FileManager.default.fileExists(atPath: self.requestPath) {
                        landed = true
                        break
                    }
                }
            } catch {
                self.log("寫入跳轉請求失敗: \(error)")
            }
            DispatchQueue.main.async {
                if landed { self.bringCmuxToFront() }
                self.lastPayload = ""
                self.refresh()
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                self.log("點擊「\(row.title)」→ 橋接 "
                         + (landed ? "已跳轉 \(ms)ms" : "逾時"))
            }
        }
    }

    private var requestPath: String { NSHomeDirectory() + "/.claude/cc-jump-request" }

    /// 絕對路徑找 tmux。面板若不是從 shell 啟動（Finder、登入項目），
    /// PATH 不會包含 Homebrew，`/usr/bin/env tmux` 就會找不到。
    private static let tmuxPath: String = {
        for candidate in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return "/usr/bin/tmux"
    }()

    private func bringCmuxToFront() {
        panel.resignKey()
        guard let cmux = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == "com.cmuxterm.app" }) else { return }
        cmux.activate()
        // 面板剛被點過，第一次 activate 常會被搶回去，補一次。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { cmux.activate() }
    }

    @discardableResult
    private func shell(_ args: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return out
    }
}

// 單一實例。多個 cmux 分頁的 hook 會同時觸發 panel-ensure.sh，
// 光靠 pgrep 判斷會有 race，實測一次開出三個。file lock 才是原子的。
let lockPath = "/tmp/claude-panel.lock"
let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o644)
if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    exit(0)   // 已經有一個在跑了，安靜退出
}

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.run()
