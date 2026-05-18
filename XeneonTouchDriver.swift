// XeneonTouchDriver.swift
// Corsair Xeneon Edge – macOS 터치 드라이버
//
// ── HID 구조 (분석 결과) ─────────────────────────────────────────────────────
//   VID=0x27c0  PID=0x0859  Interface: Page=0x01 Usage=0x02 (Mouse)
//   RptID=7:  0x01/0x30=X  0x01/0x31=Y  0x09/0x01=Button1
//   실제 전송: Button1(1손가락) 만 전송됨, Button2/3 미전송 (펌웨어 제한)
//
// ── 제스처 ──────────────────────────────────────────────────────────────────
//   빠른 탭          → 클릭
//   빠른 탭 2회      → 더블클릭
//   1초 누르기       → 우클릭
//   이동             → 스크롤 (상하/좌우)
//   이동 후 모멘텀   → 관성 스크롤
//
// ── 피벗 ────────────────────────────────────────────────────────────────────
//   macOS 디스플레이 설정에서 회전 변경 시 좌표 자동 변환
//   (가속도계 미노출로 자동 감지 불가)
//
// ── 컴파일 ──────────────────────────────────────────────────────────────────
//   swiftc XeneonTouchDriver.swift -o XeneonTouchDriver \
//     -framework IOKit -framework CoreGraphics \
//     -framework Foundation -framework AppKit

import Foundation
import IOKit
import IOKit.hid
import CoreGraphics
import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 상수
// ─────────────────────────────────────────────────────────────────────────────

let kVendorID:  Int32 = 0x27c0
let kProductID: Int32 = 0x0859

let kRawMaxX: CGFloat = 16383.0
let kRawMaxY: CGFloat = 9599.0

let kTapMaxMove:    CGFloat      = 14.0   // 탭 최대 이동 (논리픽셀)
let kTapMaxDur:     TimeInterval = 0.40   // 탭 최대 시간
let kDoubleTapSec:  TimeInterval = 0.32   // 더블탭 간격
let kRightClickSec: TimeInterval = 1.00   // 우클릭 롱프레스 시간
let kScrollScale:   CGFloat      = 3.5    // 스크롤 배율
let kMomentumDecay: CGFloat      = 0.82   // 모멘텀 감속
let kMoveThresh:    CGFloat      = 8.0    // 스크롤 진입 임계값

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 디스플레이 관리 (피벗 포함)
// ─────────────────────────────────────────────────────────────────────────────

final class DisplayManager {
    private(set) var screen:   NSScreen?
    private(set) var rotation: Double = 0.0

    init() {
        refresh()
        CGDisplayRegisterReconfigurationCallback({ _, _, ptr in
            guard let ptr = ptr else { return }
            let dm = Unmanaged<DisplayManager>.fromOpaque(ptr).takeUnretainedValue()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { dm.refresh() }
        }, Unmanaged.passRetained(self).toOpaque())
    }

    func refresh() {
        screen = NSScreen.screens.first(where: {
            let f = $0.frame
            let lo = max(f.width, f.height), sh = min(f.width, f.height)
            return sh > 0 && abs(lo / sh - 32.0 / 9.0) < 0.6
        }) ?? NSScreen.screens.first(where: { $0 != NSScreen.main }) ?? NSScreen.main

        if let s = screen {
            if let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                rotation = Double(CGDisplayRotation(n.uint32Value))
            }
            NSLog("[Xeneon] 화면: \(s.localizedName) \(s.frame) 회전=\(Int(rotation))°")
        }
    }

    func toScreen(nx: CGFloat, ny: CGFloat) -> CGPoint {
        guard let s = screen else { return .zero }
        let f      = s.frame
        let totalH = NSScreen.screens.reduce(CGFloat(0)) { max($0, $1.frame.maxY) }
        let cgMinY = totalH - f.maxY

        switch Int(rotation) {
        case 90:  return CGPoint(x: f.minX + (1 - ny) * f.width,   y: cgMinY + nx * f.height)
        case 270: return CGPoint(x: f.minX + ny * f.width,         y: cgMinY + (1 - nx) * f.height)
        case 180: return CGPoint(x: f.minX + (1 - nx) * f.width,   y: cgMinY + (1 - ny) * f.height)
        default:  return CGPoint(x: f.minX + nx * f.width,         y: cgMinY + ny * f.height)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 제스처 엔진
// ─────────────────────────────────────────────────────────────────────────────

final class GestureEngine {
    private let display: DisplayManager

    // holding  : 접촉 시작, 대기
    // dragReady: 0.38s 경과 → mouseDown 유지, 이동하면 drag
    // dragging : dragReady 상태에서 이동 중
    // scrolling: 빠른 이동 감지 → 스크롤
    // idle     : 우클릭 완료 후 손 뗄 때까지 대기
    private enum State { case idle, holding, dragReady, dragging, scrolling }
    private var state       = State.idle
    private var isDown      = false
    private var startPt     = CGPoint.zero
    private var startAt     = Date()
    private var prevPt      = CGPoint.zero
    private var prevAt      = Date()
    private var velX: CGFloat = 0
    private var velY: CGFloat = 0

    private var lastTapAt:  Date    = .distantPast
    private var lastTapPt:  CGPoint = .zero

    private var dragReadyTimer:  Timer?
    private var rightClickTimer: Timer?
    private var momentumTimer:   Timer?

    init(display: DisplayManager) { self.display = display }

    // ── 터치 시작 ────────────────────────────────────────────────────────────

    func onDown(at pt: CGPoint) {
        stopMomentum()
        isDown  = true
        state   = .holding
        startPt = pt; startAt = Date()
        prevPt  = pt; prevAt  = Date()
        velX = 0; velY = 0
        moveCursor(to: pt)

        // 0.38초: dragReady 진입 (mouseDown 유지)
        dragReadyTimer?.invalidate()
        dragReadyTimer = Timer.scheduledTimer(withTimeInterval: 0.38, repeats: false) { [weak self] _ in
            guard let self = self, self.state == .holding else { return }
            self.state = .dragReady
            self.postMouse(.leftMouseDown, at: pt)
            NSLog("[Xeneon] 드래그 준비")
        }

        // 1.0초: 우클릭 (이동이 없었을 때만)
        rightClickTimer?.invalidate()
        rightClickTimer = Timer.scheduledTimer(withTimeInterval: kRightClickSec,
                                               repeats: false) { [weak self] _ in
            guard let self = self else { return }
            switch self.state {
            case .holding:
                self.doRightClick(at: pt)
                self.state = .idle
            case .dragReady:
                // mouseDown 상태이므로 mouseUp 먼저
                self.postMouse(.leftMouseUp, at: pt)
                self.doRightClick(at: pt)
                self.state = .idle
            default:
                break
            }
        }
    }

    // ── 이동 ─────────────────────────────────────────────────────────────────

    func onMove(at pt: CGPoint) {
        guard isDown else { return }
        let now = Date()
        let dt  = max(now.timeIntervalSince(prevAt), 0.001)
        let dx  = pt.x - prevPt.x
        let dy  = pt.y - prevPt.y
        velX = dx / CGFloat(dt)
        velY = dy / CGFloat(dt)

        switch state {
        case .holding:
            if hypot(pt.x - startPt.x, pt.y - startPt.y) > kMoveThresh {
                dragReadyTimer?.invalidate();  dragReadyTimer = nil
                rightClickTimer?.invalidate(); rightClickTimer = nil
                state = .scrolling
                sendScroll(dx: 0, dy: 0, phase: 1, at: pt)
                sendScroll(dx: dx * kScrollScale, dy: dy * kScrollScale, phase: 2, at: pt)
            } else {
                moveCursor(to: pt)
            }
        case .dragReady:
            // 이동 감지 → 드래그 모드 (우클릭 타이머 취소)
            rightClickTimer?.invalidate(); rightClickTimer = nil
            state = .dragging
            moveCursor(to: pt)
            postMouse(.leftMouseDragged, at: pt)
            NSLog("[Xeneon] 드래그 시작")
        case .dragging:
            moveCursor(to: pt)
            postMouse(.leftMouseDragged, at: pt)
        case .scrolling:
            sendScroll(dx: dx * kScrollScale, dy: dy * kScrollScale, phase: 2, at: pt)
        case .idle:
            break
        }

        prevPt = pt; prevAt = now
    }

    // ── 터치 종료 ────────────────────────────────────────────────────────────

    func onUp(at pt: CGPoint) {
        dragReadyTimer?.invalidate();  dragReadyTimer = nil
        rightClickTimer?.invalidate(); rightClickTimer = nil
        isDown = false
        let disp = hypot(pt.x - startPt.x, pt.y - startPt.y)
        let dur  = Date().timeIntervalSince(startAt)
        let spd  = hypot(velX, velY)

        switch state {
        case .holding:
            if disp < kTapMaxMove && dur < kTapMaxDur { handleTap(at: pt) }
        case .dragReady:
            postMouse(.leftMouseUp, at: pt)
        case .dragging:
            postMouse(.leftMouseUp, at: pt)
            NSLog("[Xeneon] 드래그 종료")
        case .scrolling:
            sendScroll(dx: 0, dy: 0, phase: 4, at: pt)
            if spd > 60 {
                startMomentum(vx: velX * kScrollScale * 0.13,
                              vy: velY * kScrollScale * 0.13, at: pt)
            }
        case .idle:
            break
        }
        state = .idle
    }

    // ── 탭 / 더블탭 ──────────────────────────────────────────────────────────

    private func handleTap(at pt: CGPoint) {
        let elapsed = Date().timeIntervalSince(lastTapAt)
        let dist    = hypot(pt.x - lastTapPt.x, pt.y - lastTapPt.y)
        if elapsed < kDoubleTapSec && dist < 40 {
            doDoubleClick(at: pt)
            lastTapAt = .distantPast
        } else {
            doClick(at: pt)
            lastTapAt = Date(); lastTapPt = pt
        }
    }

    // ── 이벤트 전송 ──────────────────────────────────────────────────────────

    private func moveCursor(to pt: CGPoint) {
        CGDisplayMoveCursorToPoint(CGMainDisplayID(), pt)
    }

    private func postMouse(_ type: CGEventType, at pt: CGPoint) {
        let btn: CGMouseButton = (type == .rightMouseDown || type == .rightMouseUp) ? .right : .left
        CGEvent(mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: pt, mouseButton: btn)?.post(tap: .cghidEventTap)
    }

    private func doClick(at pt: CGPoint) {
        moveCursor(to: pt)
        postMouse(.leftMouseDown, at: pt)
        postMouse(.leftMouseUp,   at: pt)
        NSLog("[Xeneon] 클릭 (\(Int(pt.x)),\(Int(pt.y)))")
    }

    private func doDoubleClick(at pt: CGPoint) {
        moveCursor(to: pt)
        for i in 1...2 {
            let dn = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                             mouseCursorPosition: pt, mouseButton: .left)
            let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                             mouseCursorPosition: pt, mouseButton: .left)
            dn?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            up?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            dn?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
        NSLog("[Xeneon] 더블클릭 (\(Int(pt.x)),\(Int(pt.y)))")
    }

    private func doRightClick(at pt: CGPoint) {
        moveCursor(to: pt)
        postMouse(.rightMouseDown, at: pt)
        postMouse(.rightMouseUp,   at: pt)
        NSLog("[Xeneon] 우클릭 (\(Int(pt.x)),\(Int(pt.y)))")
    }

    private func sendScroll(dx: CGFloat, dy: CGFloat, phase: Int64, at pt: CGPoint) {
        guard let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                               wheelCount: 2,
                               wheel1: Int32(-dy), wheel2: Int32(-dx), wheel3: 0) else { return }
        ev.setIntegerValueField(.scrollWheelEventIsContinuous,  value: 1)
        ev.setIntegerValueField(.scrollWheelEventScrollPhase,   value: phase)
        ev.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        ev.location = pt
        ev.post(tap: .cghidEventTap)
    }

    private func sendScrollMomentum(dx: CGFloat, dy: CGFloat, phase: Int64, at pt: CGPoint) {
        guard let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                               wheelCount: 2,
                               wheel1: Int32(-dy), wheel2: Int32(-dx), wheel3: 0) else { return }
        ev.setIntegerValueField(.scrollWheelEventIsContinuous,  value: 1)
        ev.setIntegerValueField(.scrollWheelEventScrollPhase,   value: 0)
        ev.setIntegerValueField(.scrollWheelEventMomentumPhase, value: phase)
        ev.location = pt
        ev.post(tap: .cghidEventTap)
    }

    private func startMomentum(vx: CGFloat, vy: CGFloat, at pt: CGPoint) {
        var mvx = vx, mvy = vy
        sendScrollMomentum(dx: mvx, dy: mvy, phase: 1, at: pt)
        momentumTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            mvx *= kMomentumDecay; mvy *= kMomentumDecay
            if hypot(mvx, mvy) < 0.5 {
                self.sendScrollMomentum(dx: 0, dy: 0, phase: 3, at: pt)
                t.invalidate(); self.momentumTimer = nil; return
            }
            self.sendScrollMomentum(dx: mvx, dy: mvy, phase: 2, at: pt)
        }
    }

    private func stopMomentum() { momentumTimer?.invalidate(); momentumTimer = nil }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - HID 레이어
// ─────────────────────────────────────────────────────────────────────────────

final class HIDLayer {
    private var manager: IOHIDManager?
    private let engine:  GestureEngine
    private let display: DisplayManager

    private var bufX: CGFloat = 0
    private var bufY: CGFloat = 0
    private var xyDirty = false
    private var isDown  = false
    private var moveTimer: Timer?

    init(engine: GestureEngine, display: DisplayManager) {
        self.engine = engine; self.display = display
    }

    func start() { open(seize: true) }

    private func open(seize: Bool) {
        let opt = seize ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
                        : IOOptionBits(kIOHIDOptionsTypeNone)
        let m = IOHIDManagerCreate(kCFAllocatorDefault, opt)
        manager = m

        let criteria: [String: Any] = [
            kIOHIDVendorIDKey as String:  kVendorID,
            kIOHIDProductIDKey as String: kProductID
        ]
        IOHIDManagerSetDeviceMatching(m, criteria as CFDictionary)

        let ctx = Unmanaged.passRetained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { c, _, _, d in
            Unmanaged<HIDLayer>.fromOpaque(c!).takeUnretainedValue().deviceAdded(d)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { _, _, _, _ in
            NSLog("[Xeneon] 장치 분리됨")
        }, nil)

        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let ret = IOHIDManagerOpen(m, opt)
        if ret == kIOReturnSuccess {
            NSLog("[Xeneon] ✅ HID 열기 성공 (\(seize ? "독점" : "공유") 모드)")
        } else {
            NSLog("[Xeneon] ⚠️  HID 열기 실패 err=\(ret)")
            if seize { IOHIDManagerClose(m, opt); open(seize: false) }
        }
    }

    private func deviceAdded(_ device: IOHIDDevice) {
        let name  = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
        let priPg = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
        let priUs = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0
        NSLog("[Xeneon] 장치 연결: \(name) (Page=0x%02X Usage=0x%02X)", priPg, priUs)

        // 실제 데이터를 전송하는 Mouse 인터페이스만 사용
        guard priPg == 0x01 && priUs == 0x02 else {
            NSLog("[Xeneon] ↳ 무시")
            return
        }

        let ctx = Unmanaged.passRetained(self).toOpaque()
        IOHIDDeviceRegisterInputValueCallback(device, { c, _, _, v in
            Unmanaged<HIDLayer>.fromOpaque(c!).takeUnretainedValue().onValue(v)
        }, ctx)
    }

    private func onValue(_ value: IOHIDValue) {
        let el = IOHIDValueGetElement(value)
        let pg = IOHIDElementGetUsagePage(el)
        let us = IOHIDElementGetUsage(el)
        let v  = IOHIDValueGetIntegerValue(value)

        switch (pg, us) {
        case (0x0001, 0x0030):  // X
            bufX = CGFloat(v); xyDirty = true
            scheduleMoveFlush()

        case (0x0001, 0x0031):  // Y
            bufY = CGFloat(v); xyDirty = true
            scheduleMoveFlush()

        case (0x0009, 0x0001):  // Button1
            cancelMoveTimer()
            let wasDown = isDown
            isDown = (v != 0)
            let pt = screenPt()
            if isDown && !wasDown {
                engine.onDown(at: pt)
            } else if !isDown && wasDown {
                engine.onUp(at: pt)
            }

        case (0x0001, 0x0038):  // Scroll wheel — 무시
            break

        default:
            break
        }
    }

    private func scheduleMoveFlush() {
        moveTimer?.invalidate()
        moveTimer = Timer.scheduledTimer(withTimeInterval: 0.008, repeats: false) { [weak self] _ in
            guard let s = self, s.xyDirty, s.isDown else { return }
            s.xyDirty = false
            s.engine.onMove(at: s.screenPt())
        }
    }

    private func cancelMoveTimer() { moveTimer?.invalidate(); moveTimer = nil }

    private func screenPt() -> CGPoint {
        display.toScreen(nx: bufX / kRawMaxX, ny: bufY / kRawMaxY)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 진입점
// ─────────────────────────────────────────────────────────────────────────────

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let trusted = AXIsProcessTrustedWithOptions(
    [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
if !trusted { NSLog("[Xeneon] ⚠️  Accessibility 권한 없음") }

let displayMgr = DisplayManager()
let engine     = GestureEngine(display: displayMgr)
let hidLayer   = HIDLayer(engine: engine, display: displayMgr)

NSLog("[Xeneon] 🚀 XeneonTouchDriver 시작")
hidLayer.start()
app.run()
