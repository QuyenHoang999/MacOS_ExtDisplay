import Foundation
import CoreGraphics
import ApplicationServices

/// Turns normalized client input into real mouse events on the virtual display.
final class InputInjector {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var isDown = false
    private var lastPoint = CGPoint.zero
    private var lastDownTime: TimeInterval = 0
    private var lastDownPoint = CGPoint.zero
    private var clickCount: Int64 = 1

    /// Returns the display bounds to map into (queried per event so display rearrangement is handled).
    var boundsProvider: () -> CGRect = { .zero }

    static func isTrusted(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    func handle(_ events: [InputEvent]) {
        let bounds = boundsProvider()
        guard bounds.width > 0 else { return }
        for e in events { handle(e, bounds: bounds) }
    }

    private func handle(_ e: InputEvent, bounds: CGRect) {
        let p = DisplayGeometry.globalPoint(x: e.x, y: e.y, in: bounds)
        switch e.kind {
        case .down:
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastDownTime < NSEventDoubleClickInterval && hypot(p.x - lastDownPoint.x, p.y - lastDownPoint.y) < 8 {
                clickCount += 1
            } else {
                clickCount = 1
            }
            lastDownTime = now
            lastDownPoint = p
            post(.mouseMoved, at: p, button: .left)
            post(.leftMouseDown, at: p, button: .left, pressure: e.pressure)
            isDown = true
        case .move:
            post(isDown ? .leftMouseDragged : .mouseMoved, at: p, button: .left, pressure: e.pressure)
        case .up, .cancel:
            if isDown { post(.leftMouseUp, at: p, button: .left) }
            isDown = false
        case .hover:
            if !isDown { post(.mouseMoved, at: p, button: .left) }
        case .rightClick:
            post(.mouseMoved, at: p, button: .right)
            clickCount = 1
            post(.rightMouseDown, at: p, button: .right)
            post(.rightMouseUp, at: p, button: .right)
        case .scroll:
            if lastPoint != p { post(.mouseMoved, at: p, button: .left) }
            let dxPts = Int32((CGFloat(e.dx) * bounds.width).rounded())
            let dyPts = Int32((CGFloat(e.dy) * bounds.height).rounded())
            guard dxPts != 0 || dyPts != 0,
                  let ev = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                   wheel1: dyPts, wheel2: dxPts, wheel3: 0) else { return }
            ev.location = p
            ev.post(tap: .cghidEventTap)
        }
        lastPoint = p
    }

    private func post(_ type: CGEventType, at p: CGPoint, button: CGMouseButton, pressure: Float = 1) {
        guard let ev = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        switch type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp:
            ev.setIntegerValueField(.mouseEventClickState, value: clickCount)
            ev.setDoubleValueField(.mouseEventPressure, value: Double(type == .leftMouseUp ? 0 : max(0.05, min(1, pressure))))
        default:
            break
        }
        ev.post(tap: .cghidEventTap)
    }

    /// Releases a stuck button (e.g. on disconnect mid-drag).
    func reset() {
        if isDown { post(.leftMouseUp, at: lastPoint, button: .left) }
        isDown = false
    }
}

private let NSEventDoubleClickInterval: TimeInterval = 0.4

