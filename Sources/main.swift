import Foundation
import CoreGraphics
import AppKit
import IOKit.hid

// ============================================================================
// MiRemote v2.0 — Xiaomi Bluetooth Voice Remote 2 / 2 Pro (0x2717 / 0x32B8)
// Full-featured ergonomic workflow controller for Cursor & Codex on macOS.
//
// Architecture:
//   1. hidutil per-device mapping isolates 12 physical keys to NoEvent (0x700000000)
//      so macOS never fires stray keystrokes/brightness/sleep, while mapping Voice
//      (0x3E) -> Right Option (0xE6) so macOS sees Option+F5 for Doubao IME hold-to-talk.
//   2. IOHIDManager (matched strictly to VendorID 0x2717, ProductID 0x32B8) receives
//      raw buttonDown (value=1) and buttonUp (value=0) events directly from the remote,
//      completely isolated from the Mac's built-in keyboard.
//   3. Multi-gesture state machine per button (Single Tap / Double Tap / Long Press /
//      Continuous Hold) + Dual Control Mode (Directional ⌨️ vs Pointer 🖱) + HUD overlay.
// ============================================================================

func log(_ s: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] [mi-remote] \(s)\n"
    fputs(line, stdout); fflush(stdout)
    if let data = line.data(using: .utf8) { try? logFile?.write(contentsOf: data) }
}

var logFile: FileHandle? = {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
    let url = dir.appendingPathComponent("mi-remote.log")
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    let fh = try? FileHandle(forWritingTo: url)
    _ = try? fh?.seekToEnd()
    return fh
}()

// MARK: - Constants & Keycodes

let cursorBundle = "com.todesktop.230313mzl4w4u92"
let codexBundle  = "com.openai.codex"
let cursorPath   = "/Applications/Cursor.app"
let codexPath    = "/Applications/ChatGPT.app"

let kReturn: CGKeyCode     = 36
let kBackspace: CGKeyCode  = 51
let kEscape: CGKeyCode     = 53
let kSpace: CGKeyCode      = 49
let kKeyA: CGKeyCode       = 0
let kKeyB: CGKeyCode       = 11
let kKeyC: CGKeyCode       = 8
let kKeyL: CGKeyCode       = 37
let kKeyN: CGKeyCode       = 45
let kSemicolon: CGKeyCode  = 41
let kPageUp: CGKeyCode     = 116
let kPageDown: CGKeyCode   = 121
let kArrowLeft: CGKeyCode  = 123
let kArrowRight: CGKeyCode = 124
let kArrowDown: CGKeyCode  = 125
let kArrowUp: CGKeyCode    = 126
let kCmd: CGKeyCode        = 55
let kOpt: CGKeyCode        = 58

enum RemoteButton: UInt32, CaseIterable {
    case dpadUp    = 0x52
    case dpadDown  = 0x51
    case dpadLeft  = 0x50
    case dpadRight = 0x4F
    case centerOK  = 0x28
    case back      = 0xF1
    case home      = 0x4A
    case menu      = 0x65
    case tv        = 0x35
    case power     = 0x66
    case volUp     = 0x80
    case volDown   = 0x81
    case voice     = 0x3E
}

enum ControlMode: String {
    case directional = "directional"
    case pointer     = "pointer"
}

struct Combo {
    var keycode: CGKeyCode
    var flags: CGEventFlags
}

// MARK: - Runtime Config (~/.config/mi-remote/config.json)

struct RuntimeConfig {
    var focusCombos: [String: Combo] = [
        cursorBundle: Combo(keycode: kKeyL, flags: [.maskCommand]),      // Cmd+L
        codexBundle:  Combo(keycode: kSemicolon, flags: [.maskCommand]), // Cmd+;
    ]
    var newChatCombos: [String: Combo] = [
        cursorBundle: Combo(keycode: kKeyN, flags: [.maskCommand]),      // Cmd+N
        codexBundle:  Combo(keycode: kKeyN, flags: [.maskCommand]),      // Cmd+N
    ]
    var sessionCombos: [String: (prev: [Combo], next: [Combo])] = [
        codexBundle: (
            prev: [Combo(keycode: kArrowRight, flags: [.maskCommand, .maskAlternate])],
            next: [Combo(keycode: kArrowLeft,  flags: [.maskCommand, .maskAlternate])]
        )
    ]
    var doubleClickInterval: TimeInterval = 0.26
    var longPressInterval: TimeInterval   = 0.36
}

var config = RuntimeConfig()

func parseCombo(_ any: Any?) -> Combo? {
    guard let d = any as? [String: Any], let kc = d["keycode"] as? Int else { return nil }
    var flags: CGEventFlags = []
    for m in (d["modifiers"] as? [String]) ?? [] {
        switch m.lowercased() {
        case "command", "cmd":  flags.insert(.maskCommand)
        case "shift":           flags.insert(.maskShift)
        case "option", "alt":   flags.insert(.maskAlternate)
        case "control", "ctrl": flags.insert(.maskControl)
        default: break
        }
    }
    return Combo(keycode: CGKeyCode(kc), flags: flags)
}

func parseComboSeq(_ any: Any?) -> [Combo]? {
    if let arr = any as? [Any] {
        let cs = arr.compactMap(parseCombo)
        return cs.isEmpty ? nil : cs
    }
    if let c = parseCombo(any) { return [c] }
    return nil
}

func reloadConfig() {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/mi-remote/config.json")
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

    if let fc = json["focusCombos"] as? [String: Any] {
        for (k, v) in fc { if let c = parseCombo(v) { config.focusCombos[k] = c } }
    }
    if let nc = json["newChatCombos"] as? [String: Any] {
        for (k, v) in nc { if let c = parseCombo(v) { config.newChatCombos[k] = c } }
    }
    if let sc = json["sessionCombos"] as? [String: Any] {
        for (k, v) in sc {
            guard let d = v as? [String: Any],
                  let p = parseComboSeq(d["prev"]),
                  let n = parseComboSeq(d["next"]) else { continue }
            config.sessionCombos[k] = (p, n)
        }
    }
    if let dc = json["doubleClickMs"] as? Double, dc >= 120, dc <= 600 {
        config.doubleClickInterval = dc / 1000.0
    }
    if let lp = json["longPressMs"] as? Double, lp >= 200, lp <= 1000 {
        config.longPressInterval = lp / 1000.0
    }
}

// MARK: - Layer 1: hidutil Per-Device Isolation

func applyHidutilMapping() {
    func u(_ x: UInt64) -> UInt64 { (0x07 << 32) | x }
    let noEvent = u(0x00)
    // All 12 non-voice buttons map to NoEvent (0x700000000) so macOS produces no stray
    // key events; IOHIDManager still receives every raw press/release from the remote.
    // Voice (0x3E) maps to Right Option (0xE6) -> macOS sees Option+F5 for Doubao IME.
    let suppressed: [UInt64] = [
        0x52, 0x51, 0x50, 0x4F, // D-pad Up/Down/Left/Right
        0x28,                   // Center OK
        0xF1,                   // Back <
        0x4A,                   // Home ⌂
        0x65,                   // Menu ≡
        0x35,                   // TV [TV]
        0x66,                   // Power ⏻
        0x80, 0x81,             // Volume + / -
    ]
    var mapping: [[String: UInt64]] = suppressed.map {
        ["HIDKeyboardModifierMappingSrc": u($0), "HIDKeyboardModifierMappingDst": noEvent]
    }
    mapping.append(["HIDKeyboardModifierMappingSrc": u(0x3E), "HIDKeyboardModifierMappingDst": u(0xE6)])

    guard let data = try? JSONSerialization.data(withJSONObject: ["UserKeyMapping": mapping]),
          let payload = String(data: data, encoding: .utf8) else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
    p.arguments = ["property", "--matching", "{\"VendorID\":10007,\"ProductID\":12984}", "--set", payload]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
}

// MARK: - Floating Non-Activating HUD Overlay & Menu Bar

final class HUDController {
    static let shared = HUDController()
    private var panel: NSPanel?
    private var label: NSTextField?
    private var hideWorkItem: DispatchWorkItem?

    func show(_ text: String, duration: TimeInterval = 1.15) {
        DispatchQueue.main.async {
            self.ensurePanel()
            guard let panel = self.panel, let label = self.label else { return }
            label.stringValue = text
            label.sizeToFit()
            let width = max(180, label.frame.width + 44)
            let height: CGFloat = 44
            let screen = NSScreen.main ?? NSScreen.screens.first
            let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let x = screenFrame.midX - width / 2
            let y = screenFrame.minY + 72
            panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
            label.frame = NSRect(x: (width - label.frame.width) / 2,
                                 y: (height - label.frame.height) / 2 - 1,
                                 width: label.frame.width,
                                 height: label.frame.height)
            panel.alphaValue = 1.0
            panel.orderFrontRegardless()

            self.hideWorkItem?.cancel()
            let item = DispatchWorkItem { [weak panel] in
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.22
                    panel?.animator().alphaValue = 0.0
                }, completionHandler: {
                    panel?.orderOut(nil)
                })
            }
            self.hideWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let vev = NSVisualEffectView(frame: p.contentView!.bounds)
        vev.autoresizingMask = [.width, .height]
        vev.material = .hudWindow
        vev.blendingMode = .behindWindow
        vev.state = .active
        vev.wantsLayer = true
        vev.layer?.cornerRadius = 22
        vev.layer?.masksToBounds = true

        let lbl = NSTextField(labelWithString: "")
        lbl.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        lbl.textColor = .white
        lbl.alignment = .center
        vev.addSubview(lbl)
        p.contentView = vev

        self.panel = p
        self.label = lbl
    }
}

final class StatusBarManager: NSObject {
    static let shared = StatusBarManager()
    private var statusItem: NSStatusItem?
    private var modeMenuItem: NSMenuItem?

    func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "⌨️"
        item.button?.toolTip = "MiRemote 小米遥控器助手（点击查看/切换模式）"

        let menu = NSMenu()
        let modeItem = NSMenuItem(title: "当前模式：方向键模式 (按 ≡ 切换)", action: #selector(toggleModeClicked), keyEquivalent: "")
        modeItem.target = self
        menu.addItem(modeItem)
        self.modeMenuItem = modeItem

        menu.addItem(.separator())
        let cheat = [
            "🎤 语音键：按住豆包说话，松手上屏",
            "⏻ 电源键：单击 Esc 取消｜长按 ⌃C 强制中断",
            "⭕ 圆环/OK：方向或移鼠｜OK 发送(长按⇧⏎换行)",
            "< 返回键：单击/按住 ⌫ 删字｜双击清空整框",
            "⌂ 小房子：单击聚焦输入框｜双击 ⌘N 新建会话｜长按 ⌘B 侧栏",
            "≡ 菜单键：单击切换 ⌨️/🖱｜双击光标归中｜按住+上下滚屏",
            "± 音量键：单击上下切会话｜长按 PageUp/Down 翻页",
            "📺 TV 键：单击切 Cursor↔Codex 并落点输入框｜双击回上个外部应用"
        ]
        for line in cheat {
            let m = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            m.isEnabled = false
            menu.addItem(m)
        }
        menu.addItem(.separator())
        let reloadItem = NSMenuItem(title: "重新加载配置 (config.json)", action: #selector(reloadClicked), keyEquivalent: "r")
        reloadItem.target = self
        menu.addItem(reloadItem)

        item.menu = menu
        self.statusItem = item
    }

    func updateMode(_ mode: ControlMode) {
        DispatchQueue.main.async {
            self.statusItem?.button?.title = (mode == .directional) ? "⌨️" : "🖱"
            self.modeMenuItem?.title = (mode == .directional)
                ? "当前模式：⌨️ 方向键模式（点击或按 ≡ 切鼠标）"
                : "当前模式：🖱 鼠标指针模式（点击或按 ≡ 切方向键）"
        }
    }

    @objc private func toggleModeClicked() {
        ControllerEngine.shared.toggleControlMode()
    }

    @objc private func reloadClicked() {
        reloadConfig()
        applyHidutilMapping()
        HUDController.shared.show("🔄 配置已重新加载")
    }
}

// MARK: - Synthetic Keyboard & Mouse Helpers

func sendKey(_ keycode: CGKeyCode, isDown: Bool, flags: CGEventFlags = []) {
    guard let src = CGEventSource(stateID: .hidSystemState),
          let e = CGEvent(keyboardEventSource: src, virtualKey: keycode, keyDown: isDown) else { return }
    e.flags = flags
    e.post(tap: .cghidEventTap)
}

func sendCombo(_ combo: Combo) {
    sendKey(combo.keycode, isDown: true, flags: combo.flags)
    sendKey(combo.keycode, isDown: false, flags: combo.flags)
}

func flagsChanged(keycode: CGKeyCode, flags: CGEventFlags) {
    guard let src = CGEventSource(stateID: .combinedSessionState),
          let e = CGEvent(keyboardEventSource: src, virtualKey: keycode, keyDown: true) else { return }
    e.type = .flagsChanged
    e.flags = flags
    e.post(tap: .cghidEventTap)
}

// Cursor's session picker is a Cmd+Tab-style switcher: Cmd+Option+Arrow moves highlight;
// releasing modifiers commits the switch.
func sendCursorSessionSwitcher(arrow: CGKeyCode) {
    flagsChanged(keycode: kCmd, flags: [.maskCommand]); usleep(35_000)
    flagsChanged(keycode: kOpt, flags: [.maskCommand, .maskAlternate]); usleep(35_000)
    sendCombo(Combo(keycode: arrow, flags: [.maskCommand, .maskAlternate])); usleep(85_000)
    flagsChanged(keycode: kOpt, flags: [.maskCommand]); usleep(35_000)
    flagsChanged(keycode: kCmd, flags: [])
}

func postScroll(linesY: Int32, linesX: Int32 = 0) {
    guard let src = CGEventSource(stateID: .hidSystemState) else { return }
    CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 2, wheel1: linesY, wheel2: linesX, wheel3: 0)?
        .post(tap: .cghidEventTap)
}

func postMouseClick(button: CGMouseButton, downType: CGEventType, upType: CGEventType, clickCount: Int64 = 1) {
    guard let pos = CGEvent(source: nil)?.location,
          let src = CGEventSource(stateID: .hidSystemState) else { return }
    for (t, isDown) in [(downType, true), (upType, false)] {
        guard let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: pos, mouseButton: button) else { continue }
        e.setIntegerValueField(.mouseEventClickState, value: clickCount)
        e.post(tap: .cghidEventTap)
        if isDown { usleep(15_000) }
    }
}

// MARK: - App Tracking & Focus Actions

final class AppNavigator {
    static let shared = AppNavigator()
    private(set) var lastAIAppBundle: String = cursorBundle
    private(set) var lastExternalAppBundle: String?

    func startObserving() {
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            recordActivation(front)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bid = app.bundleIdentifier else { return }
            self?.recordActivation(bid)
        }
    }

    private func recordActivation(_ bid: String) {
        if bid == cursorBundle || bid == codexBundle {
            lastAIAppBundle = bid
        } else if bid != "com.miremote.daemon" {
            lastExternalAppBundle = bid
        }
    }

    func activateApp(bundleID: String, path: String? = nil, completion: (() -> Void)? = nil) {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            app.activate(options: [.activateAllWindows])
            log("activated \(bundleID)")
            if let completion {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: completion)
            }
        } else if let path {
            let url = URL(fileURLWithPath: path)
            let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, err in
                if let err { log("launch \(path) failed: \(err.localizedDescription)") }
                else {
                    log("launched \(path)")
                    if let completion {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: completion)
                    }
                }
            }
        }
    }

    /// ⌂ Single Click: Focus the chat input of the current AI app (or activate the last AI app and focus).
    func focusCurrentOrLastAIInput() {
        reloadConfig()
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if front == cursorBundle || front == codexBundle {
            let combo = config.focusCombos[front] ?? Combo(keycode: kKeyL, flags: [.maskCommand])
            sendCombo(combo)
            let name = (front == cursorBundle) ? "Cursor" : "Codex"
            HUDController.shared.show("🎯 聚焦 \(name) 输入框")
            log("focused input in active \(name)")
        } else {
            let target = lastAIAppBundle
            let path = (target == cursorBundle) ? cursorPath : codexPath
            let name = (target == cursorBundle) ? "Cursor" : "Codex"
            HUDController.shared.show("🎯 回到 \(name) 输入框")
            activateApp(bundleID: target, path: path) {
                let combo = config.focusCombos[target] ?? Combo(keycode: kKeyL, flags: [.maskCommand])
                sendCombo(combo)
                log("activated & focused input in \(name)")
            }
        }
    }

    /// [TV] Single Click: Toggle Cursor <-> Codex AND automatically focus its input box.
    func toggleAIAppAndFocusInput(focusInput: Bool = true) {
        reloadConfig()
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let target: String
        if front == cursorBundle { target = codexBundle }
        else if front == codexBundle { target = cursorBundle }
        else { target = lastAIAppBundle }

        let path = (target == cursorBundle) ? cursorPath : codexPath
        let name = (target == cursorBundle) ? "Cursor" : "Codex"
        HUDController.shared.show(focusInput ? "⇄ \(name) · 输入框" : "⇄ 切换到 \(name)")
        activateApp(bundleID: target, path: path) {
            guard focusInput else { return }
            let combo = config.focusCombos[target] ?? Combo(keycode: kKeyL, flags: [.maskCommand])
            sendCombo(combo)
            log("TV switched to \(name) and focused input")
        }
    }

    /// [TV] Double Click: Toggle back to the last external app (e.g., Chrome, Terminal, Lark).
    func switchToLastExternalApp() {
        guard let ext = lastExternalAppBundle,
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == ext }) else {
            HUDController.shared.show("⇄ 无最近外部应用")
            return
        }
        let appName = app.localizedName ?? ext
        app.activate(options: [.activateAllWindows])
        HUDController.shared.show("⇄ \(appName)")
        log("TV double-click activated external app \(ext)")
    }

    /// ⌂ Double Click: New chat/session in active AI app.
    func newChatInCurrentApp() {
        reloadConfig()
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let target = (front == cursorBundle || front == codexBundle) ? front : lastAIAppBundle
        let combo = config.newChatCombos[target] ?? Combo(keycode: kKeyN, flags: [.maskCommand])
        sendCombo(combo)
        HUDController.shared.show("🆕 新建会话")
        log("new chat sent to \(target)")
    }

    /// ⌂ Long Press: Toggle sidebar (Cmd+B).
    func toggleSidebar() {
        sendCombo(Combo(keycode: kKeyB, flags: [.maskCommand]))
        HUDController.shared.show("◧ 展开/收起侧栏")
        log("toggle sidebar Cmd+B")
    }

    /// Vol+ / Vol- Single Tap: Next / Prev session.
    func switchSession(next: Bool) {
        reloadConfig()
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if front == cursorBundle {
            sendCursorSessionSwitcher(arrow: next ? kArrowUp : kArrowDown)
            HUDController.shared.show(next ? "↑ 下一个会话" : "↓ 上一个会话", duration: 0.75)
            log("Cursor session \(next ? "next" : "prev")")
            return
        }
        if let pair = config.sessionCombos[front] {
            for c in (next ? pair.next : pair.prev) { sendCombo(c); usleep(25_000) }
            HUDController.shared.show(next ? "→ 下一个会话" : "← 上一个会话", duration: 0.75)
            log("session \(next ? "next" : "prev") sent to \(front)")
            return
        }
        // Fallback when in browser/other app: scroll page up/down
        sendCombo(Combo(keycode: next ? kPageUp : kPageDown, flags: []))
    }
}

// MARK: - Layer 2: Multi-Gesture & Dual-Mode Controller Engine

final class ControllerEngine {
    static let shared = ControllerEngine()

    private(set) var mode: ControlMode = .directional
    private var pressedAt: [RemoteButton: Date] = [:]
    private var longPressFired: Set<RemoteButton> = []
    private var pendingSingleTap: [RemoteButton: DispatchWorkItem] = [:]
    private var lastTapAt: [RemoteButton: Date] = [:]

    // 60Hz ticker state for continuous D-pad / pointer / backspace / volume scroll
    private var tickTimer: Timer?
    private var lastTickAt = Date()
    private var lastArrowRepeatAt = Date.distantPast
    private var lastBackRepeatAt  = Date.distantPast
    private var lastVolRepeatAt   = Date.distantPast
    private var lastMenuComboUsed = false

    func start() {
        lastTickAt = Date()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func toggleControlMode() {
        mode = (mode == .directional) ? .pointer : .directional
        StatusBarManager.shared.updateMode(mode)
        if mode == .pointer {
            _ = CGDisplayShowCursor(CGMainDisplayID())
            HUDController.shared.show("🖱 鼠标指针模式（圆环移鼠 · OK点击）")
        } else {
            HUDController.shared.show("⌨️ 方向键模式（圆环方向 · OK回车）")
        }
        log("mode switched to \(mode.rawValue)")
    }

    func centerCursorInActiveWindow() {
        if mode != .pointer {
            mode = .pointer
            StatusBarManager.shared.updateMode(mode)
        }
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // CGDisplay coordinates have origin at top-left of main display
        let center = CGPoint(x: screenFrame.midX, y: screenFrame.height / 2)
        CGWarpMouseCursorPosition(center)
        _ = CGDisplayShowCursor(CGMainDisplayID())
        HUDController.shared.show("🎯 光标已归中（🖱 鼠标模式）")
        log("cursor centered at (\(Int(center.x)), \(Int(center.y)))")
    }

    // MARK: Button Down / Up Entry Points

    func buttonDown(_ btn: RemoteButton) {
        guard btn != .voice else { return } // Voice is handled via hidutil Option+F5 -> Doubao IME
        guard pressedAt[btn] == nil else { return } // ignore duplicate down
        let now = Date()
        pressedAt[btn] = now
        longPressFired.remove(btn)

        // Hold `≡` (Menu) + D-pad = instant 2D scroll in any mode!
        if pressedAt[.menu] != nil && [.dpadUp, .dpadDown, .dpadLeft, .dpadRight].contains(btn) {
            lastMenuComboUsed = true
            fireMenuScroll(btn)
            lastVolRepeatAt = now
            return
        }

        switch btn {
        case .dpadUp, .dpadDown, .dpadLeft, .dpadRight:
            if mode == .directional {
                if let kc = Self.arrowKeycode(for: btn) {
                    sendKey(kc, isDown: true)
                    lastArrowRepeatAt = now
                }
            } else {
                _ = CGDisplayShowCursor(CGMainDisplayID())
                stepPointer(dt: 0.018, heldSeconds: 0.0)
            }

        case .back:
            // Zero-latency single tap: delete 1 char immediately on press!
            // If a second press arrives within doubleClickInterval, select all + delete!
            if let prev = lastTapAt[.back], now.timeIntervalSince(prev) <= config.doubleClickInterval {
                lastTapAt[.back] = nil
                longPressFired.insert(.back) // prevent repeat from firing right after clear
                sendCombo(Combo(keycode: kKeyA, flags: [.maskCommand]))
                usleep(20_000)
                sendCombo(Combo(keycode: kBackspace, flags: []))
                HUDController.shared.show("🧹 已清空输入")
                log("back double-tap: cleared input (Cmd+A -> Backspace)")
            } else {
                lastTapAt[.back] = now
                sendCombo(Combo(keycode: kBackspace, flags: []))
                lastBackRepeatAt = now
                log("back tap -> Backspace")
            }

        case .centerOK, .home, .menu, .tv, .power, .volUp, .volDown, .voice:
            // Handled on release (tap / double-tap) or in tick() when held >= longPressInterval
            break
        }
    }

    func buttonUp(_ btn: RemoteButton) {
        guard btn != .voice else { return }
        guard let downAt = pressedAt.removeValue(forKey: btn) else { return }
        let held = Date().timeIntervalSince(downAt)
        let wasLongFired = longPressFired.remove(btn) != nil

        if btn == .menu && lastMenuComboUsed {
            lastMenuComboUsed = false
            return
        }

        switch btn {
        case .dpadUp, .dpadDown, .dpadLeft, .dpadRight:
            if mode == .directional, let kc = Self.arrowKeycode(for: btn) {
                sendKey(kc, isDown: false)
            }

        case .back:
            break // Already acted on keyDown / continuous repeat

        case .centerOK:
            guard !wasLongFired else { return }
            if mode == .directional {
                sendCombo(Combo(keycode: kReturn, flags: []))
                log("OK tap -> Return")
            } else {
                let now = Date()
                if let prev = lastTapAt[.centerOK], now.timeIntervalSince(prev) <= config.doubleClickInterval {
                    lastTapAt[.centerOK] = nil
                    postMouseClick(button: .left, downType: .leftMouseDown, upType: .leftMouseUp, clickCount: 2)
                    log("OK pointer double-click")
                } else {
                    lastTapAt[.centerOK] = now
                    postMouseClick(button: .left, downType: .leftMouseDown, upType: .leftMouseUp, clickCount: 1)
                    log("OK pointer left-click")
                }
            }

        case .power:
            guard !wasLongFired else { return }
            let now = Date()
            if let prev = lastTapAt[.power], now.timeIntervalSince(prev) <= config.doubleClickInterval {
                lastTapAt[.power] = nil
                sendCombo(Combo(keycode: kEscape, flags: []))
                usleep(25_000)
                sendCombo(Combo(keycode: kEscape, flags: []))
                HUDController.shared.show("⎋⎋ 双击 Esc")
                log("power double-tap -> Esc x2")
            } else {
                lastTapAt[.power] = now
                sendCombo(Combo(keycode: kEscape, flags: []))
                HUDController.shared.show("⎋ Esc", duration: 0.7)
                log("power tap -> Esc")
            }

        case .volUp:
            guard !wasLongFired && held < config.longPressInterval else { return }
            AppNavigator.shared.switchSession(next: true)

        case .volDown:
            guard !wasLongFired && held < config.longPressInterval else { return }
            AppNavigator.shared.switchSession(next: false)

        case .home:
            guard !wasLongFired else { return }
            scheduleSingleOrDouble(
                btn: .home,
                single: { AppNavigator.shared.focusCurrentOrLastAIInput() },
                double: { AppNavigator.shared.newChatInCurrentApp() }
            )

        case .tv:
            guard !wasLongFired else { return }
            scheduleSingleOrDouble(
                btn: .tv,
                single: { AppNavigator.shared.toggleAIAppAndFocusInput(focusInput: true) },
                double: { AppNavigator.shared.switchToLastExternalApp() }
            )

        case .menu:
            guard !wasLongFired else { return }
            scheduleSingleOrDouble(
                btn: .menu,
                single: { [weak self] in self?.toggleControlMode() },
                double: { [weak self] in self?.centerCursorInActiveWindow() }
            )

        case .voice:
            break
        }
    }

    private func scheduleSingleOrDouble(btn: RemoteButton, single: @escaping () -> Void, double: @escaping () -> Void) {
        if let pending = pendingSingleTap.removeValue(forKey: btn) {
            pending.cancel()
            double()
            return
        }
        let item = DispatchWorkItem { [weak self] in
            self?.pendingSingleTap.removeValue(forKey: btn)
            single()
        }
        pendingSingleTap[btn] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + config.doubleClickInterval, execute: item)
    }

    // MARK: 60Hz Ticker for Long-Press, Key Repeat & Smooth Pointer

    private func tick() {
        let now = Date()
        let dt = min(0.05, max(0.001, now.timeIntervalSince(lastTickAt)))
        lastTickAt = now
        guard !pressedAt.isEmpty else { return }

        // 1. Hold Menu (≡) + D-pad = continuous smooth scroll
        if pressedAt[.menu] != nil {
            let dirs: [RemoteButton] = [.dpadUp, .dpadDown, .dpadLeft, .dpadRight]
            if let dir = dirs.first(where: { pressedAt[$0] != nil }) {
                if now.timeIntervalSince(lastVolRepeatAt) >= 0.08 {
                    fireMenuScroll(dir)
                    lastVolRepeatAt = now
                }
                return
            }
        }

        // 2. D-pad movement / repeat
        let dpadHeld = [RemoteButton.dpadUp, .dpadDown, .dpadLeft, .dpadRight].compactMap { pressedAt[$0] }
        if let earliestDpad = dpadHeld.min() {
            let held = now.timeIntervalSince(earliestDpad)
            if mode == .pointer {
                stepPointer(dt: dt, heldSeconds: held)
            } else if held >= 0.32 && now.timeIntervalSince(lastArrowRepeatAt) >= 0.055 {
                for dir in [RemoteButton.dpadUp, .dpadDown, .dpadLeft, .dpadRight] where pressedAt[dir] != nil {
                    if let kc = Self.arrowKeycode(for: dir) { sendKey(kc, isDown: true) }
                }
                lastArrowRepeatAt = now
            }
        }

        // 3. Backspace (<) continuous repeat
        if let backDown = pressedAt[.back], !longPressFired.contains(.back) {
            let held = now.timeIntervalSince(backDown)
            if held >= 0.30 && now.timeIntervalSince(lastBackRepeatAt) >= 0.055 {
                sendCombo(Combo(keycode: kBackspace, flags: []))
                lastBackRepeatAt = now
            }
        }

        // 4. Volume +/- long-press -> continuous PageUp / PageDown
        for (btn, kc, label) in [(RemoteButton.volUp, kPageUp, "⇞ 向上翻页"), (RemoteButton.volDown, kPageDown, "⇟ 向下翻页")] {
            if let down = pressedAt[btn] {
                let held = now.timeIntervalSince(down)
                if held >= config.longPressInterval && now.timeIntervalSince(lastVolRepeatAt) >= 0.14 {
                    if !longPressFired.contains(btn) {
                        longPressFired.insert(btn)
                        HUDController.shared.show(label, duration: 0.8)
                    }
                    sendCombo(Combo(keycode: kc, flags: []))
                    lastVolRepeatAt = now
                }
            }
        }

        // 5. One-shot Long-Press actions (OK, Power, Home, TV)
        if let okDown = pressedAt[.centerOK], !longPressFired.contains(.centerOK),
           now.timeIntervalSince(okDown) >= config.longPressInterval {
            longPressFired.insert(.centerOK)
            if mode == .directional {
                sendCombo(Combo(keycode: kReturn, flags: [.maskShift]))
                HUDController.shared.show("↵ 换行 (⇧Return)", duration: 0.85)
                log("OK long-press -> Shift+Return")
            } else {
                postMouseClick(button: .right, downType: .rightMouseDown, upType: .rightMouseUp, clickCount: 1)
                HUDController.shared.show("🖱 右键点击", duration: 0.85)
                log("OK pointer long-press -> Right Click")
            }
        }

        if let pwrDown = pressedAt[.power], !longPressFired.contains(.power),
           now.timeIntervalSince(pwrDown) >= config.longPressInterval {
            longPressFired.insert(.power)
            sendCombo(Combo(keycode: kKeyC, flags: [.maskControl]))
            usleep(20_000)
            sendCombo(Combo(keycode: kEscape, flags: []))
            HUDController.shared.show("⛔ 强制中断 (⌃C + Esc)")
            log("power long-press -> Ctrl+C + Esc")
        }

        if let homeDown = pressedAt[.home], !longPressFired.contains(.home),
           now.timeIntervalSince(homeDown) >= config.longPressInterval {
            longPressFired.insert(.home)
            AppNavigator.shared.toggleSidebar()
        }

        if let tvDown = pressedAt[.tv], !longPressFired.contains(.tv),
           now.timeIntervalSince(tvDown) >= config.longPressInterval {
            longPressFired.insert(.tv)
            AppNavigator.shared.toggleAIAppAndFocusInput(focusInput: false)
        }
    }

    private func fireMenuScroll(_ dir: RemoteButton) {
        switch dir {
        case .dpadUp:    postScroll(linesY: 3)
        case .dpadDown:  postScroll(linesY: -3)
        case .dpadLeft:  postScroll(linesY: 0, linesX: 3)
        case .dpadRight: postScroll(linesY: 0, linesX: -3)
        default: break
        }
    }

    private func stepPointer(dt: Double, heldSeconds: Double) {
        guard let cur = CGEvent(source: nil)?.location else { return }
        // Smooth acceleration curve: 220 px/s initial precision -> ramps up to 1050 px/s
        let speed = min(1050.0, 220.0 + max(0.0, heldSeconds) * 680.0)
        let step = speed * dt
        var dx = 0.0, dy = 0.0
        if pressedAt[.dpadLeft]  != nil { dx -= step }
        if pressedAt[.dpadRight] != nil { dx += step }
        if pressedAt[.dpadUp]    != nil { dy -= step }
        if pressedAt[.dpadDown]  != nil { dy += step }
        guard dx != 0 || dy != 0 else { return }
        if dx != 0 && dy != 0 {
            dx *= 0.70710678
            dy *= 0.70710678
        }
        let target = CGPoint(x: cur.x + dx, y: cur.y + dy)
        CGWarpMouseCursorPosition(target)
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    private static func arrowKeycode(for btn: RemoteButton) -> CGKeyCode? {
        switch btn {
        case .dpadUp:    return kArrowUp
        case .dpadDown:  return kArrowDown
        case .dpadLeft:  return kArrowLeft
        case .dpadRight: return kArrowRight
        default:         return nil
        }
    }
}

// MARK: - IOHIDManager Direct Remote Listener

var hidManager: IOHIDManager?

func startHIDListener() {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    hidManager = manager
    IOHIDManagerSetDeviceMatching(manager, [
        kIOHIDVendorIDKey: 0x2717,
        kIOHIDProductIDKey: 0x32B8,
    ] as CFDictionary)

    let cb: IOHIDValueCallback = { _, _, _, value in
        let el = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(el) == 7 else { return }
        let usage = IOHIDElementGetUsage(el)
        guard let btn = RemoteButton(rawValue: usage) else { return }
        let isDown = (IOHIDValueGetIntegerValue(value) != 0)
        if isDown {
            ControllerEngine.shared.buttonDown(btn)
        } else {
            ControllerEngine.shared.buttonUp(btn)
        }
    }
    IOHIDManagerRegisterInputValueCallback(manager, cb, nil)
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    let ret = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    if ret != kIOReturnSuccess {
        log("HID listener failed ret=\(ret): grant Input Monitoring to MiRemote.app, then relaunch")
    } else {
        log("HID listener ready (all 13 buttons via IOHIDManager)")
    }
}

// MARK: - Main Entry

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // Menu bar icon + HUD overlay, no Dock icon
log("starting MiRemote v2.0 (pid \(ProcessInfo.processInfo.processIdentifier))")
if !AXIsProcessTrusted() {
    log("WARNING: not Accessibility-trusted yet; synthetic events will fail until granted")
}
reloadConfig()
applyHidutilMapping()
Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in applyHidutilMapping() }
StatusBarManager.shared.setup()
AppNavigator.shared.startObserving()
ControllerEngine.shared.start()
startHIDListener()
app.run()
