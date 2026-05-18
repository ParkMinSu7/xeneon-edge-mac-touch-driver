// XeneonAnalyzer.swift
// 제논 엣지 멀티터치 패턴 정밀 분석기
// 2손가락 이상 터치 시 어떤 순서/패턴으로 값이 오는지 확인
//
// swiftc XeneonAnalyzer.swift -o XeneonAnalyzer -framework IOKit -framework Foundation
// ./XeneonAnalyzer

import Foundation
import IOKit
import IOKit.hid

let kVID: Int32 = 0x27c0
let kPID: Int32 = 0x0859

var devIdx = 0

// 타임스탬프 (마이크로초 단위로 출력)
func ts() -> String {
    let t = ProcessInfo.processInfo.systemUptime
    return String(format: "%.4f", t)
}

print("""
╔══════════════════════════════════════════════════════════════╗
║  Xeneon Edge 멀티터치 패턴 분석기                            ║
║  1. 먼저 손가락 1개로 탭해보세요                             ║
║  2. 손가락 2개로 동시에 탭해보세요                           ║
║  3. 손가락 2개로 스크롤해보세요                              ║
║  4. Ctrl+C 로 종료                                           ║
╚══════════════════════════════════════════════════════════════╝
""")

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let match: [String: Any] = [kIOHIDVendorIDKey: kVID, kIOHIDProductIDKey: kPID]
IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)

IOHIDManagerRegisterDeviceMatchingCallback(manager, { _, _, _, device in
    devIdx += 1
    let idx   = devIdx
    let name  = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString)          as? String ?? "?"
    let priPg = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int    ?? 0
    let priUs = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString)     as? Int    ?? 0
    let loc   = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString)       as? Int    ?? 0
    print(String(format: "\n[%@] ✅ IF#%d: %@  Page=0x%02X Usage=0x%02X Loc=0x%X",
                 ts(), idx, name, priPg, priUs, loc))

    // 요소 목록 (간략히)
    if let cfArr = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) {
        let count = CFArrayGetCount(cfArr)
        for i in 0..<min(count, 100) {
            guard let ptr = CFArrayGetValueAtIndex(cfArr, i) else { continue }
            let el    = unsafeBitCast(ptr, to: IOHIDElement.self)
            let ePg   = IOHIDElementGetUsagePage(el)
            let eUs   = IOHIDElementGetUsage(el)
            let eMin  = IOHIDElementGetLogicalMin(el)
            let eMax  = IOHIDElementGetLogicalMax(el)
            let eRpt  = IOHIDElementGetReportID(el)
            let eType = IOHIDElementGetType(el).rawValue
            // 의미 있는 요소만 출력 (Type=1 input_misc, Type=2 input_button)
            if eType <= 3 && eMax > 0 {
                print(String(format: "   RptID=%2d Page=0x%04X Usage=0x%04X Type=%d Range=[%d,%d]",
                             eRpt, ePg, eUs, eType, eMin, eMax))
            }
        }
    }

    // 값 콜백 - Report ID 포함해서 출력
    class Box { let label: String; init(_ s: String){ label=s } }
    let box = Box("IF#\(idx)")
    let ctx = Unmanaged.passRetained(box).toOpaque()

    IOHIDDeviceRegisterInputValueCallback(device, { ctx, _, _, value in
        guard let ctx = ctx else { return }
        let box   = Unmanaged<Box>.fromOpaque(ctx).takeUnretainedValue()
        let el    = IOHIDValueGetElement(value)
        let pg    = IOHIDElementGetUsagePage(el)
        let us    = IOHIDElementGetUsage(el)
        let v     = IOHIDValueGetIntegerValue(value)
        let rpt   = IOHIDElementGetReportID(el)
        // 값이 0인 Scroll wheel 은 생략
        if pg == 0x0001 && us == 0x0038 && v == 0 { return }
        print(String(format: "[%@] \(box.label) Rpt=%d Page=0x%04X Usage=0x%04X Val=%d",
                     ts(), rpt, pg, us, v))
    }, ctx)

}, nil)

IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
let ret = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
guard ret == kIOReturnSuccess else {
    print("❌ 열기 실패 err=\(ret) - 입력 모니터링 권한 확인")
    exit(1)
}

print("\n✅ 대기 중. 손가락 1개 → 2개 순서로 터치해보세요...\n")

signal(SIGINT) { _ in print("\n종료"); exit(0) }
CFRunLoopRun()
