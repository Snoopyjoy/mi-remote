#!/usr/bin/env swift
import Foundation
import IOKit.hid

// Standalone HID Button Probe for Xiaomi Bluetooth Remote (or other BLE HID remotes).
// Usage: swift scripts/probe-hid.swift [vendorID_hex] [productID_hex]
// Default: VendorID 0x2717 (Xiaomi), ProductID 0x32B8 (Xiaomi Remote 2 / 2 Pro)

let args = CommandLine.arguments
let vendorID  = args.count > 1 ? (Int(args[1].replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0x2717) : 0x2717
let productID = args.count > 2 ? (Int(args[2].replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0x32B8) : 0x32B8

let knownNames: [UInt32: String] = [
    0x52: "dpad_up (↑)",
    0x51: "dpad_down (↓)",
    0x50: "dpad_left (←)",
    0x4F: "dpad_right (→)",
    0x28: "center_ok (OK)",
    0xF1: "back (<)",
    0x4A: "home (⌂)",
    0x65: "menu (≡)",
    0x35: "tv ([TV])",
    0x66: "power (⏻)",
    0x3E: "voice (🎤)",
    0x80: "volume_up (+)",
    0x81: "volume_down (-)",
]

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [
    kIOHIDVendorIDKey: vendorID,
    kIOHIDProductIDKey: productID,
] as CFDictionary)

let cb: IOHIDValueCallback = { _, _, _, value in
    let el = IOHIDValueGetElement(value)
    let page = IOHIDElementGetUsagePage(el)
    let usage = IOHIDElementGetUsage(el)
    let v = IOHIDValueGetIntegerValue(value)
    guard page == 7, usage > 1, usage < 0x1000 else { return }
    let label = knownNames[usage] ?? "unknown"
    let state = (v != 0) ? "DOWN" : "UP  "
    print(String(format: "[%@] page=0x%02X usage=0x%02X (%3d) -> %@", state, page, usage, usage, label))
    fflush(stdout)
}

IOHIDManagerRegisterInputValueCallback(manager, cb, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
let ret = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
print(String(format: "Opening HID (VID=0x%04X PID=0x%04X) -> ret=%d (0 = OK, -536870174 = Need Input Monitoring permission)", vendorID, productID, ret))
print("Press buttons on your remote now (Ctrl+C to exit)...")
fflush(stdout)
RunLoop.current.run()
