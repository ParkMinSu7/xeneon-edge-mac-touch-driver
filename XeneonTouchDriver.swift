// XeneonTouchDriver.swift
// Corsair Xeneon Edge – Multitouch Driver for macOS
//
// HID 구조 (IF#3 RptID=7):
//   0x0001/0x0030 : X  (0~16383)
//   0x0001/0x0031 : Y  (0~9599)
//   0x0009/0x0001 : Button1 (1손가락)
//   0x0009/0x0002 : Button2 (2손가락)
//   0x0009/0x0003 : Button3 (3손가락)
//
// 컴파일:
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

let kVendorID:  Int32   = 0x27c0
let kProductID: Int32   = 0x0859
let kRawMaxX:   CGFloat = 16383.0
let kRawMaxY:   CGFloat = 9599.0

let kTapMaxMove:   CGFloat      = 15.0   // 탭 최대 이동 픽셀
let kTapMaxDur:    TimeInterval = 0.5    // 탭 최대 시간
let kDoubleTapSec: TimeInterval = 0.35   // 더블탭 간격
let kScrollScale:  CGFloat      = 3.2    // 스크롤 배율
let kMomentumDecay: CGFloat     = 0.85   // 모멘텀 감속
let kFlickSpeed:   CGFloat      = 500.0  // 플릭 최소 속도 (px/s)
let kFlickDist:    CGFloat      = 50.0   // 플릭 최소 거리
let kSwipeDist:    CGFloat      = 45.0   // 3손가락 최소 거리

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 디스플레이 관리
// ─────────────────────────────────────────────────────────────────────────────

enum Orientation { case landscape, portrait }

final class DisplayManager {
    private(set) var screen: NSScreen?
    private(set) var orientation: Orientation = .landscape
    var onChanged: (() -> Void)?

    init() {
        refresh()
        CGDisplayRegisterReconfigurationCallback({ _, _, userInfo in
            guard let p = userInfo else { return }
            let dm = Unmanaged<DisplayManager>.fromOpaque(p).takeUnretainedValue()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let prev = dm.orientation
                dm.refresh()
                if dm.orientation != prev { dm.onChanged?() }
            }
        }, Unmanaged.passRetained(self).toOpaque())
    }

    func refresh() {
        let screens = NSScreen.screens
        NSLog("[Xeneon] 화면 \(screens.count)개:")
        for (i, s) in screens.enumerated() {
            let f = s.frame
            let r = max(f.width,f.height)/max(min(f.width,f.height),1)
            NSLog("[Xeneon]   [\(i)] \(s.localizedName) \(f) ratio=\(String(format:"%.2f",r))")
        }
        screen = screens.first(where: {
            let f=$0.frame; let lo=max(f.width,f.height); let sh=min(f.width,f.height)
            return sh>0 && abs(lo/sh - 32.0/9.0) < 0.5
        }) ?? screens.first(where:{$0 != NSScreen.main}) ?? NSScreen.main
        if let s = screen {
            orientation = s.frame.width >= s.frame.height ? .landscape : .portrait
            NSLog("[Xeneon] 선택: \(s.localizedName) \(s.frame) 방향=\(orientation == .portrait ? "세로":"가로")")
        }
    }

    func toScreen(nx: CGFloat, ny: CGFloat) -> CGPoint {
        guard let s = screen else { return .zero }
        let f = s.frame
        let totalH = NSScreen.screens.reduce(CGFloat(0)) { max($0, $1.frame.maxY) }
        let cgMinY = totalH - f.maxY
        switch orientation {
        case .landscape:
            return CGPoint(x: f.minX + nx*f.width,       y: cgMinY + ny*f.height)
        case .portrait:
            return CGPoint(x: f.minX + (1.0-ny)*f.width, y: cgMinY + nx*f.height)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 제스처 엔진
// ─────────────────────────────────────────────────────────────────────────────

final class GestureEngine {
    private let display: DisplayManager

    // ── 상태 ────────────────────────────────────────────────────────────────
    private var activeButtons = 0        // 현재 눌린 버튼 수

    // 1손가락
    private var one_startPt    = CGPoint.zero
    private var one_startTime  = Date()
    private var one_prevPt     = CGPoint.zero
    private var one_prevTime   = Date()
    private var one_velX: CGFloat = 0
    private var one_velY: CGFloat = 0
    private var one_dragging   = false   // 드래그 중 (mouseDown 보낸 상태)
    private var one_scrolling  = false   // 스크롤 중
    private var one_scrollBegan = false

    // 드래그 모드 감지: 탭 직후 재터치
    private var lastTapTime:   Date    = .distantPast
    private var lastTapPt:     CGPoint = .zero
    private var dragModeArmed  = false   // 탭 후 드래그 대기 중

    // 2손가락
    private var two_startPt   = CGPoint.zero
    private var two_startTime = Date()
    private var two_prevPt    = CGPoint.zero
    private var two_velX: CGFloat = 0
    private var two_velY: CGFloat = 0
    private var two_scrolling = false
    private var two_scrollBegan = false

    // 3손가락
    private var three_startPt   = CGPoint.zero
    private var three_startTime = Date()

    // 모멘텀
    private var momentumTimer: Timer?
    private var dragArmTimer:  Timer?   // 드래그 모드 만료 타이머

    init(display: DisplayManager) { self.display = display }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: 메인 진입점 - HID에서 버튼/좌표 변화 시 호출
    // ─────────────────────────────────────────────────────────────────────────

    func onButtonDown(count: Int, at pt: CGPoint) {
        NSLog("[Xeneon] 버튼 다운 \(count)개 (\(Int(pt.x)),\(Int(pt.y)))")
        stopMomentum()

        switch count {
        case 1:
            one_startPt    = pt
            one_startTime  = Date()
            one_prevPt     = pt
            one_prevTime   = Date()
            one_velX       = 0; one_velY = 0
            one_scrolling  = false
            one_scrollBegan = false

            // 탭 직후(0.35초 내) 재터치 → 드래그 모드
            let tapElapsed = Date().timeIntervalSince(lastTapTime)
            let tapDist    = hypot(pt.x - lastTapPt.x, pt.y - lastTapPt.y)
            if dragModeArmed && tapElapsed < kDoubleTapSec && tapDist < 40 {
                // 드래그 시작: mouseDown 전송
                one_dragging = true
                dragModeArmed = false
                dragArmTimer?.invalidate()
                moveCursor(to: pt)
                postMouse(.leftMouseDown, at: pt)
                NSLog("[Xeneon] 드래그 시작 (탭+드래그)")
            } else {
                one_dragging = false
                moveCursor(to: pt)
            }

        case 2:
            two_startPt   = pt
            two_startTime = Date()
            two_prevPt    = pt
            two_velX      = 0; two_velY = 0
            two_scrolling = false
            two_scrollBegan = false

        case 3:
            three_startPt   = pt
            three_startTime = Date()

        default: break
        }

        activeButtons = count
    }

    func onButtonUp(count: Int, at pt: CGPoint) {
        NSLog("[Xeneon] 버튼 업 \(count)개 (\(Int(pt.x)),\(Int(pt.y)))")

        switch count {
        case 1: finishOne(at: pt)
        case 2: finishTwo(at: pt)
        case 3: finishThree(at: pt)
        default: break
        }

        activeButtons = 0
    }

    func onMove(at pt: CGPoint) {
        guard activeButtons > 0 else { return }

        let now = Date()
        let dt  = max(now.timeIntervalSince(one_prevTime), 0.001)

        switch activeButtons {
        case 1:
            let dx = pt.x - one_prevPt.x
            let dy = pt.y - one_prevPt.y
            one_velX = dx / CGFloat(dt)
            one_velY = dy / CGFloat(dt)

            let disp = hypot(pt.x - one_startPt.x, pt.y - one_startPt.y)

            if !one_scrolling && !one_dragging {
                if disp > kTapMaxMove {
                    one_scrolling = true
                    NSLog("[Xeneon] 스크롤 모드")
                }
            }

            if one_dragging {
                moveCursor(to: pt)
                postMouse(.leftMouseDragged, at: pt)
            } else if one_scrolling {
                if !one_scrollBegan {
                    sendScroll(dx: 0, dy: 0, phase: 1, at: pt)
                    one_scrollBegan = true
                }
                sendScroll(dx: dx * kScrollScale, dy: dy * kScrollScale, phase: 2, at: pt)
            } else {
                moveCursor(to: pt)
            }

            one_prevPt   = pt
            one_prevTime = now

        case 2:
            let dx = pt.x - two_prevPt.x
            let dy = pt.y - two_prevPt.y
            let dt2 = max(now.timeIntervalSince(two_prevPt == two_startPt ? two_startTime : one_prevTime), 0.001)
            two_velX = dx / CGFloat(dt2)
            two_velY = dy / CGFloat(dt2)

            let disp = hypot(pt.x - two_startPt.x, pt.y - two_startPt.y)
            if !two_scrolling && disp > kTapMaxMove {
                two_scrolling = true
            }

            if two_scrolling {
                if !two_scrollBegan {
                    sendScroll(dx: 0, dy: 0, phase: 1, at: pt)
                    two_scrollBegan = true
                }
                sendScroll(dx: dx * kScrollScale, dy: dy * kScrollScale, phase: 2, at: pt)
            }

            two_prevPt = pt

        case 3:
            break // 3손가락은 up 시 처리

        default: break
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: 1손가락 종료
    // ─────────────────────────────────────────────────────────────────────────

    private func finishOne(at pt: CGPoint) {
        let disp  = hypot(pt.x - one_startPt.x, pt.y - one_startPt.y)
        let dur   = Date().timeIntervalSince(one_startTime)
        let speed = hypot(one_velX, one_velY)
        NSLog("[Xeneon] 1손가락 종료 disp=\(Int(disp)) dur=\(String(format:"%.2f",dur))s speed=\(Int(speed))")

        if one_dragging {
            postMouse(.leftMouseUp, at: pt)
            one_dragging = false

        } else if one_scrolling {
            if one_scrollBegan {
                sendScroll(dx: 0, dy: 0, phase: 4, at: pt)
            }
            // 수평 플릭 → 뒤로/앞으로
            let ax = abs(pt.x - one_startPt.x)
            let ay = abs(pt.y - one_startPt.y)
            if speed > kFlickSpeed && disp > kFlickDist && ax > ay * 1.5 {
                let src = CGEventSource(stateID: .hidSystemState)
                if pt.x < one_startPt.x {
                    sendKey(33, flags: .maskCommand, src: src)
                    NSLog("[Xeneon] 플릭 왼쪽 → 뒤로")
                } else {
                    sendKey(30, flags: .maskCommand, src: src)
                    NSLog("[Xeneon] 플릭 오른쪽 → 앞으로")
                }
            } else if speed > 60 {
                // 수직 모멘텀
                startMomentum(vx: one_velX * kScrollScale * 0.15,
                              vy: one_velY * kScrollScale * 0.15, at: pt)
            }

        } else {
            // 탭: 이동 없이 뗌
            if disp < kTapMaxMove && dur < kTapMaxDur {
                handleTap(at: pt)
            }
        }

        one_scrolling  = false
        one_scrollBegan = false
        one_dragging   = false
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: 2손가락 종료
    // ─────────────────────────────────────────────────────────────────────────

    private func finishTwo(at pt: CGPoint) {
        let disp  = hypot(pt.x - two_startPt.x, pt.y - two_startPt.y)
        let dur   = Date().timeIntervalSince(two_startTime)
        let speed = hypot(two_velX, two_velY)
        NSLog("[Xeneon] 2손가락 종료 disp=\(Int(disp)) dur=\(String(format:"%.2f",dur))s speed=\(Int(speed))")

        if two_scrolling {
            if two_scrollBegan {
                sendScroll(dx: 0, dy: 0, phase: 4, at: pt)
            }
            // 모멘텀
            if speed > 60 {
                startMomentum(vx: two_velX * kScrollScale * 0.15,
                              vy: two_velY * kScrollScale * 0.15, at: pt)
            }
            // 수평 플릭
            let ax = abs(pt.x - two_startPt.x)
            let ay = abs(pt.y - two_startPt.y)
            if speed > kFlickSpeed && disp > kFlickDist && ax > ay * 1.5 {
                let src = CGEventSource(stateID: .hidSystemState)
                if pt.x < two_startPt.x {
                    sendKey(33, flags: .maskCommand, src: src)
                    NSLog("[Xeneon] 2손가락 플릭 왼쪽 → 뒤로")
                } else {
                    sendKey(30, flags: .maskCommand, src: src)
                    NSLog("[Xeneon] 2손가락 플릭 오른쪽 → 앞으로")
                }
            }
        } else if disp < kTapMaxMove && dur < 0.4 {
            // 2손가락 탭 → 우클릭
            doRightClick(at: pt)
        }

        two_scrolling = false
        two_scrollBegan = false
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: 3손가락 종료
    // ─────────────────────────────────────────────────────────────────────────

    private func finishThree(at pt: CGPoint) {
        let dx   = pt.x - three_startPt.x
        let dy   = pt.y - three_startPt.y
        let dist = hypot(dx, dy)
        NSLog("[Xeneon] 3손가락 종료 dist=\(Int(dist))")

        guard dist >= kSwipeDist else { return }

        let src = CGEventSource(stateID: .hidSystemState)
        if abs(dy) >= abs(dx) {
            if dy < 0 {
                sendKey(126, flags: .maskControl, src: src)  // Ctrl+↑ Mission Control
                NSLog("[Xeneon] 3손가락 위 → Mission Control")
            } else {
                sendKey(125, flags: .maskControl, src: src)  // Ctrl+↓ App Exposé
                NSLog("[Xeneon] 3손가락 아래 → App Exposé")
            }
        } else {
            if dx < 0 {
                sendKey(124, flags: .maskControl, src: src)  // Ctrl+→ 다음 Space
                NSLog("[Xeneon] 3손가락 오른쪽 → 다음 Space")
            } else {
                sendKey(123, flags: .maskControl, src: src)  // Ctrl+← 이전 Space
                NSLog("[Xeneon] 3손가락 왼쪽 → 이전 Space")
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: 탭/더블탭
    // ─────────────────────────────────────────────────────────────────────────

    private func handleTap(at pt: CGPoint) {
        let elapsed = Date().timeIntervalSince(lastTapTime)
        let tdist   = hypot(pt.x - lastTapPt.x, pt.y - lastTapPt.y)
        if elapsed < kDoubleTapSec && tdist < 40 {
            doDoubleClick(at: pt)
            lastTapTime   = .distantPast
            dragModeArmed = false
            dragArmTimer?.invalidate()
        } else {
            doClick(at: pt)
            lastTapTime   = Date()
            lastTapPt     = pt
            // 탭 후 드래그 대기: 0.35초 내 재터치 시 드래그 모드
            dragModeArmed = true
            dragArmTimer?.invalidate()
            dragArmTimer = Timer.scheduledTimer(withTimeInterval: kDoubleTapSec, repeats: false) { [weak self] _ in
                self?.dragModeArmed = false
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: 이벤트 전송
    // ─────────────────────────────────────────────────────────────────────────

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
            dn?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
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
                               wheelCount: 2, wheel1: Int32(-dy), wheel2: Int32(-dx), wheel3: 0) else { return }
        ev.setIntegerValueField(.scrollWheelEventIsContinuous,  value: 1)
        ev.setIntegerValueField(.scrollWheelEventScrollPhase,   value: phase)
        ev.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        ev.location = pt
        ev.post(tap: .cghidEventTap)
    }

    private func sendScrollMomentum(dx: CGFloat, dy: CGFloat, mphase: Int64, at pt: CGPoint) {
        guard let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                               wheelCount: 2, wheel1: Int32(-dy), wheel2: Int32(-dx), wheel3: 0) else { return }
        ev.setIntegerValueField(.scrollWheelEventIsContinuous,  value: 1)
        ev.setIntegerValueField(.scrollWheelEventScrollPhase,   value: 0)
        ev.setIntegerValueField(.scrollWheelEventMomentumPhase, value: mphase)
        ev.location = pt
        ev.post(tap: .cghidEventTap)
    }

    private func sendKey(_ key: CGKeyCode, flags: CGEventFlags, src: CGEventSource?) {
        let dn = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        dn?.flags = flags; up?.flags = flags
        dn?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
    }

    private func startMomentum(vx: CGFloat, vy: CGFloat, at pt: CGPoint) {
        var mvx = vx, mvy = vy
        sendScrollMomentum(dx: mvx, dy: mvy, mphase: 1, at: pt)
        momentumTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            mvx *= kMomentumDecay; mvy *= kMomentumDecay
            if hypot(mvx, mvy) < 0.5 {
                self.sendScrollMomentum(dx: 0, dy: 0, mphase: 3, at: pt)
                t.invalidate(); self.momentumTimer = nil; return
            }
            self.sendScrollMomentum(dx: mvx, dy: mvy, mphase: 2, at: pt)
        }
    }

    private func stopMomentum() { momentumTimer?.invalidate(); momentumTimer = nil }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - HID 레이어
// ─────────────────────────────────────────────────────────────────────────────
// X, Y, Button 값이 같은 리포트에서 거의 동시에 옴 (순서: Y→X→Button 또는 X→Y→Button)
// Button 수신 시 즉시 처리, X/Y 만 수신 시 8ms 후 move 처리

final class HIDLayer {
    private var manager: IOHIDManager?
    private let engine:  GestureEngine
    private let display: DisplayManager

    // 버퍼
    private var bufX: CGFloat = 0
    private var bufY: CGFloat = 0
    private var bufXYDirty = false

    // 버튼 상태 (수신된 값 그대로)
    private var btn1: Bool = false
    private var btn2: Bool = false
    private var btn3: Bool = false

    // 이전 버튼 상태 (변화 감지)
    private var prevCount: Int = 0

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

        let criteria: [[String: Any]] = [[
            kIOHIDVendorIDKey: kVendorID, kIOHIDProductIDKey: kProductID,
            kIOHIDPrimaryUsagePageKey: 0x01, kIOHIDPrimaryUsageKey: 0x02
        ]]
        IOHIDManagerSetDeviceMatchingMultiple(m, criteria as CFArray)

        let ctx = Unmanaged.passRetained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { c, _, _, d in
            Unmanaged<HIDLayer>.fromOpaque(c!).takeUnretainedValue().deviceAdded(d)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { _, _, _, _ in
            NSLog("[Xeneon] 장치 분리")
        }, nil)

        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let ret = IOHIDManagerOpen(m, opt)
        if ret == kIOReturnSuccess {
            NSLog("[Xeneon] ✅ HID 열기 성공 (\(seize ? "독점":"공유") 모드)")
        } else {
            NSLog("[Xeneon] ⚠️  HID 열기 실패 err=\(ret)")
            if seize { IOHIDManagerClose(m, opt); open(seize: false) }
            else { NSLog("[Xeneon] ❌ 최종 실패 – 입력 모니터링 권한 확인") }
        }
    }

    private func deviceAdded(_ device: IOHIDDevice) {
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
        NSLog("[Xeneon] 장치 연결: \(name)")
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
            bufX = CGFloat(v)
            bufXYDirty = true
            scheduleMoveFlush()

        case (0x0001, 0x0031):  // Y
            bufY = CGFloat(v)
            bufXYDirty = true
            scheduleMoveFlush()

        case (0x0009, 0x0001):  // Button1
            btn1 = (v != 0)
            cancelMoveTimer()
            flushButton()

        case (0x0009, 0x0002):  // Button2
            btn2 = (v != 0)
            cancelMoveTimer()
            flushButton()

        case (0x0009, 0x0003):  // Button3
            btn3 = (v != 0)
            cancelMoveTimer()
            flushButton()

        case (0x0001, 0x0038):  // Scroll wheel (무시)
            break

        default: break
        }
    }

    private func flushButton() {
        // 현재 눌린 버튼 수 계산
        let curCount = btn3 ? 3 : btn2 ? 2 : btn1 ? 1 : 0
        guard curCount != prevCount else { return }

        let pt = display.toScreen(nx: bufX / kRawMaxX, ny: bufY / kRawMaxY)

        if curCount > 0 {
            engine.onButtonDown(count: curCount, at: pt)
        } else {
            engine.onButtonUp(count: prevCount, at: pt)
        }

        prevCount = curCount
    }

    private func scheduleMoveFlush() {
        moveTimer?.invalidate()
        moveTimer = Timer.scheduledTimer(withTimeInterval: 0.008, repeats: false) { [weak self] _ in
            guard let self = self, self.bufXYDirty else { return }
            self.bufXYDirty = false
            guard self.prevCount > 0 else { return }
            let pt = self.display.toScreen(nx: self.bufX / kRawMaxX, ny: self.bufY / kRawMaxY)
            self.engine.onMove(at: pt)
        }
    }

    private func cancelMoveTimer() { moveTimer?.invalidate(); moveTimer = nil }
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

displayMgr.onChanged = { NSLog("[Xeneon] 화면 방향 변경 적용") }

NSLog("[Xeneon] 🚀 XeneonTouchDriver 시작")
hidLayer.start()
app.run()
