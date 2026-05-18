// XeneonAnalyzer.swift
// 제논 엣지 HID 분석기 - segfault 수정 버전
//
// swiftc XeneonAnalyzer.swift -o XeneonAnalyzer -framework IOKit -framework Foundation

import Foundation
import IOKit
import IOKit.hid

let kVID: Int32 = 0x27c0
let kPID: Int32 = 0x0859

var maxX: Int = 0
var maxY: Int = 0
var devIdx = 0

func ts() -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

print("""
╔════════════════════════════════════════════════════════╗
║        Xeneon Edge HID 분석기                          ║
║  터치해보고 Ctrl+C 로 종료하세요                        ║
╚════════════════════════════════════════════════════════╝
""")

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let match: [String: Any] = [kIOHIDVendorIDKey: kVID, kIOHIDProductIDKey: kPID]
IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)

IOHIDManagerRegisterDeviceMatchingCallback(manager, { _, _, _, device in
    devIdx += 1
    let idx  = devIdx
    let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
    let pg   = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
    let us   = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0
    let loc  = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? Int ?? 0

    print(String(format: "\n[%@] ✅ IF#%d: %@  Page=0x%02X Usage=0x%02X Loc=0x%X",
                 ts(), idx, name, pg, us, loc))

    // 요소 열거 - CFArray 직접 사용 (캐스팅 segfault 방지)
    let matchAll: CFDictionary? = nil
    if let cfArr = IOHIDDeviceCopyMatchingElements(device, matchAll, IOOptionBits(kIOHIDOptionsTypeNone)) {
        let count = CFArrayGetCount(cfArr)
        print("   요소 수: \(count)개")
        for i in 0..<min(count, 200) {
            guard let ptr = CFArrayGetValueAtIndex(cfArr, i) else { continue }
            let el = unsafeBitCast(ptr, to: IOHIDElement.self)
            let ePage = IOHIDElementGetUsagePage(el)
            let eUsage = IOHIDElementGetUsage(el)
            let eMin  = IOHIDElementGetLogicalMin(el)
            let eMax  = IOHIDElementGetLogicalMax(el)
            let eRpt  = IOHIDElementGetReportID(el)
            let eType = IOHIDElementGetType(el).rawValue
            print(String(format: "     [%d] RptID=%2d  Page=0x%04X  Usage=0x%04X  Type=%d  Range=[%d,%d]",
                         i, eRpt, ePage, eUsage, eType, eMin, eMax))
        }
    }

    // 값 콜백 - 클래스로 박스해서 ctx 전달
    class Ctx { let label: String; init(_ s: String) { label = s } }
    let box = Ctx("IF#\(idx)")
    let ctx = Unmanaged.passRetained(box).toOpaque()

    IOHIDDeviceRegisterInputValueCallback(device, { ctx, _, _, value in
        let box   = Unmanaged<Ctx>.fromOpaque(ctx!).takeUnretainedValue()
        let el    = IOHIDValueGetElement(value)
        let page  = IOHIDElementGetUsagePage(el)
        let usage = IOHIDElementGetUsage(el)
        let v     = IOHIDValueGetIntegerValue(value)
        if usage == 0x30 && v > 0 { maxX = max(maxX, v) }
        if usage == 0x31 && v > 0 { maxY = max(maxY, v) }
        print(String(format: "[%@] %@  Page=0x%04X  Usage=0x%04X  Val=%d",
                     ts(), box.label, page, usage, v))
    }, ctx)

}, nil)

IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
let ret = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
guard ret == kIOReturnSuccess else {
    print("❌ 열기 실패 err=\(ret) — 입력 모니터링 권한 확인")
    exit(1)
}
print("✅ 실행 중. 터치하세요...\n")

signal(SIGINT) { _ in
    print("\nX최대=\(maxX)  Y최대=\(maxY)")
    print("  let kRawMaxX: CGFloat = \(maxX > 0 ? maxX : 32767).0")
    print("  let kRawMaxY: CGFloat = \(maxY > 0 ? maxY : 32767).0")
    exit(0)
}
CFRunLoopRun()
