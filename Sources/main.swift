import Foundation
import CoreGraphics
import AppKit

// mi-remote: Xiaomi Bluetooth Remote (VID 0x2717 / PID 0x32B8, FW 2671) -> Cursor / Codex controller.
//
// Layer 1 (hidutil, applied by this daemon): per-device key translation
//   Back 0xF1 -> Delete | Home 0x4A -> PageDown | TV 0x35 -> F16 | Power 0x66 -> F17
//   Vol+ 0x80 -> F14 | Vol- 0x81 -> F15 | Voice 0x3E -> RightOption (system sees Option+F5,
//   which Doubao IME records as its hold-to-talk custom shortcut)
// Layer 2 (this daemon, CGEventTap): intercepts F6/F13/F14/F15 and performs app/session actions.
// All other keys keep their Layer-1 (or native) behaviour and pass through untouched.

func log(_ s: String) {
    let line = "[mi-remote] \(s)\n"
    fputs(line, stdout); fflush(stdout)
    if let fh = logFile { fh.write(line.data(using: .utf8)!) }
}
var logFile: FileHandle? = {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
    let url = dir.appendingPathComponent("mi-remote.log")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    return try? FileHandle(forWritingTo: url)
}()

// MARK: - Layer 1: hidutil mapping

// HID pairs are re-read from ~/.config/mi-remote/config.json ("hidMapping": [[src,dst],...],
// usages as decimal or "0x.." strings) on every apply, so key remaps need no rebuild.
func configHidPairs() -> [(UInt64, UInt64)]? {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/mi-remote/config.json")
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let arr = json["hidMapping"] as? [Any], !arr.isEmpty else { return nil }
    func num(_ v: Any) -> UInt64? {
        if let n = v as? NSNumber { return n.uint64Value }
        if let str = v as? String { return UInt64(str.hasPrefix("0x") ? String(str.dropFirst(2)) : str, radix: str.hasPrefix("0x") ? 16 : 10) }
        return nil
    }
    let pairs: [(UInt64, UInt64)] = arr.compactMap { item in
        guard let a = item as? [Any], a.count == 2, let src = num(a[0]), let dst = num(a[1]) else { return nil }
        return (src, dst)
    }
    return pairs.isEmpty ? nil : pairs
}

func applyHidutilMapping() {
    func u(_ x: UInt64) -> UInt64 { (0x07 << 32) | x }
    let pairs: [(UInt64, UInt64)] = configHidPairs() ?? [
        (0xF1, 0x2A), // Back  -> Delete (Backspace)
        (0x35, 0x6B), // TV    -> F16 (no native macOS function; daemon marker)
        (0x4A, 0x4E), // Home  -> PageDown
        (0x66, 0x6C), // Power -> F17 (daemon marker)
        (0x80, 0x6D), // Vol+  -> F18 (daemon marker)
        (0x81, 0x6E), // Vol-  -> F19 (daemon marker)
        (0x3E, 0xE6), // Voice -> Right Option (yields Option+F5; Doubao hold-to-talk)
    ]
    let mapping = pairs.map { ["HIDKeyboardModifierMappingSrc": u($0.0), "HIDKeyboardModifierMappingDst": u($0.1)] }
    guard let data = try? JSONSerialization.data(withJSONObject: ["UserKeyMapping": mapping]),
          let payload = String(data: data, encoding: .utf8) else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
    p.arguments = ["property", "--matching", "{\"VendorID\":10007,\"ProductID\":12984}", "--set", payload]
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit()
}

// MARK: - App actions

let cursorBundle = "com.todesktop.230313mzl4w4u92" // Cursor (verified via NSWorkspace at runtime fallback below)
let codexBundle = "com.openai.codex"                // Codex desktop app (/Applications/ChatGPT.app)
let cursorPath = "/Applications/Cursor.app"
let codexPath = "/Applications/ChatGPT.app"

func activate(bundleID: String, path: String) {
    if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
        app.activate(options: [.activateAllWindows])
        log("activated \(bundleID)")
    } else {
        let url = URL(fileURLWithPath: path)
        let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, err in
            if let err { log("launch \(path) failed: \(err.localizedDescription)") } else { log("launched \(path)") }
        }
    }
}

var lastPairTarget = cursorBundle
func toggleCursorCodex() {
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
    let target: String
    if front == cursorBundle { target = codexBundle }
    else if front == codexBundle { target = cursorBundle }
    else { target = lastPairTarget }
    lastPairTarget = (target == cursorBundle) ? codexBundle : cursorBundle
    activate(bundleID: target, path: target == cursorBundle ? cursorPath : codexPath)
}

// MARK: - Synthetic keystrokes

struct Combo { var keycode: CGKeyCode; var flags: CGEventFlags }
let kBracketL: CGKeyCode = 33, kBracketR: CGKeyCode = 30
// Defaults are browser-style tab switching; adjust after live testing with each app.
// Live-verified on this machine (2026-11-02): Cursor switches Agent sessions with
// Cmd+Option arrows; Codex switches threads with Cmd+Option Left/Right.
// (prev/next direction user-corrected on 2026-11-02: Vol+ moves toward the newer session.)
let kArrowUp: CGKeyCode = 126, kArrowDown: CGKeyCode = 125, kArrowLeft: CGKeyCode = 123, kArrowRight: CGKeyCode = 124
let kReturn: CGKeyCode = 36
// Cursor's Cmd+Option arrows only move the highlight in the session list, so a
// following Return is required to actually open the highlighted session.
var sessionCombos: [String: (prev: [Combo], next: [Combo])] = [
    cursorBundle: ([Combo(keycode: kArrowDown, flags: [.maskCommand, .maskAlternate]), Combo(keycode: kReturn, flags: [])],
                   [Combo(keycode: kArrowUp, flags: [.maskCommand, .maskAlternate]), Combo(keycode: kReturn, flags: [])]),
    codexBundle:  ([Combo(keycode: kArrowRight, flags: [.maskCommand, .maskAlternate])],
                   [Combo(keycode: kArrowLeft, flags: [.maskCommand, .maskAlternate])]),
]

func loadConfig() {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/mi-remote/config.json")
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let sess = json["sessionCombos"] as? [String: Any] else { return }
    func parse(_ v: Any?) -> Combo? {
        guard let d = v as? [String: Any], let kc = d["keycode"] as? Int else { return nil }
        var flags: CGEventFlags = []
        for m in (d["modifiers"] as? [String]) ?? [] {
            switch m.lowercased() {
            case "command", "cmd": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "option", "alt": flags.insert(.maskAlternate)
            case "control", "ctrl": flags.insert(.maskControl)
            default: break
            }
        }
        return Combo(keycode: CGKeyCode(kc), flags: flags)
    }
    func parseSeq(_ v: Any?) -> [Combo]? {
        if let arr = v as? [Any] { let cs = arr.compactMap(parse); return cs.isEmpty ? nil : cs }
        if let c = parse(v) { return [c] }
        return nil
    }
    for (bundle, v) in sess {
        guard let d = v as? [String: Any], let p = parseSeq(d["prev"]), let n = parseSeq(d["next"]) else { continue }
        sessionCombos[bundle] = (p, n)
        log("config: session combos overridden for \(bundle)")
    }
}

let syntheticTag: Int64 = 0x4D49524D // "MIRM"
func sendCombo(_ combo: Combo) {
    guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: combo.keycode, keyDown: down) else { continue }
        e.flags = combo.flags
        e.setIntegerValueField(.eventSourceUserData, value: syntheticTag)
        e.post(tap: .cghidEventTap)
    }
}

func flagsChanged(keycode: CGKeyCode, flags: CGEventFlags) {
    guard let src = CGEventSource(stateID: .combinedSessionState),
          let e = CGEvent(keyboardEventSource: src, virtualKey: keycode, keyDown: true) else { return }
    e.type = .flagsChanged
    e.flags = flags
    e.setIntegerValueField(.eventSourceUserData, value: syntheticTag)
    e.post(tap: .cghidEventTap)
}

// Cursor's session picker is a Cmd+Tab-style switcher: Cmd+Option+Arrow only moves
// the highlight; the switch commits when the modifiers are RELEASED. Emulate the
// full physical sequence: modifiers down -> arrow -> modifiers up.
func sendSwitcher(arrow: CGKeyCode) {
    let kCmd: CGKeyCode = 55, kOpt: CGKeyCode = 58
    flagsChanged(keycode: kCmd, flags: [.maskCommand]); usleep(40_000)
    flagsChanged(keycode: kOpt, flags: [.maskCommand, .maskAlternate]); usleep(40_000)
    sendCombo(Combo(keycode: arrow, flags: [.maskCommand, .maskAlternate])); usleep(90_000)
    flagsChanged(keycode: kOpt, flags: [.maskCommand]); usleep(40_000)
    flagsChanged(keycode: kCmd, flags: [])
}

func sessionSwitch(next: Bool) {
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
    if front == cursorBundle {
        // Direction user-corrected: Vol+ (next) = Up, Vol- (prev) = Down.
        sendSwitcher(arrow: next ? kArrowUp : kArrowDown)
        log("session switcher \(next ? "next" : "prev") sent to Cursor")
        return
    }
    guard let pair = sessionCombos[front] else {
        log("session switch ignored: frontmost \(front) not Cursor/Codex")
        return
    }
    for c in (next ? pair.next : pair.prev) { sendCombo(c); usleep(30_000) }
    log("session \(next ? "next" : "prev") sent to \(front)")
}

// MARK: - Layer 2: event tap

let kF6: CGKeyCode = 106, kF13: CGKeyCode = 64, kF14: CGKeyCode = 79, kF15: CGKeyCode = 80 // F16,F17,F18,F19

func handleKey(keycode: CGKeyCode, flags: CGEventFlags) -> Bool {
    // F-key events also carry Fn / nonCoalesced / numericPad bits; only real modifiers disqualify.
    let mods: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl, .maskAlphaShift]
    guard flags.intersection(mods).isEmpty else { return false }
    switch keycode {
    case kF6: toggleCursorCodex(); return true
    case kF13: activate(bundleID: codexBundle, path: codexPath); return true
    case kF14: sessionSwitch(next: true); return true
    case kF15: sessionSwitch(next: false); return true
    default: return false
    }
}

func startTap() {
    let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
        eventsOfInterest: mask, callback: { _, type, event, _ in
            if event.getIntegerValueField(.eventSourceUserData) == syntheticTag {
                return Unmanaged.passUnretained(event)
            }
            let kc = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            if [kF6, kF13, kF14, kF15].contains(kc) {
                log("tap saw marker keycode=\(kc) type=\(type.rawValue) flags=\(event.flags.rawValue)")
            }
            // Only swallow the keyDown; matching keyUp of an intercepted key is also swallowed
            // by re-checking handleKey would re-trigger actions, so track via keyUp pass for our keys:
            if type == .keyDown {
                if handleKey(keycode: kc, flags: event.flags) { return nil }
            } else if type == .keyUp, [kF6, kF13, kF14, kF15].contains(kc) {
                let mods: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl, .maskAlphaShift]
                if event.flags.intersection(mods).isEmpty { return nil }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: nil) else {
        log("TAP_CREATE_FAILED: grant Accessibility to MiRemote.app (System Settings > Privacy & Security > Accessibility), then relaunch")
        return
    }
    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    log("event tap ready")
}

// MARK: - Main

log("starting (pid \(ProcessInfo.processInfo.processIdentifier))")
if !AXIsProcessTrusted() {
    log("WARNING: not Accessibility-trusted yet; event tap will fail until granted")
}
loadConfig()
applyHidutilMapping()
// Re-apply on a timer: hidutil per-device mapping resets when the remote reconnects / Mac reboots.
Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in applyHidutilMapping() }
startTap()
NSApplication.shared.run()
