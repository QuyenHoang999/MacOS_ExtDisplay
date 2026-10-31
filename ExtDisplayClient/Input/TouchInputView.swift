import UIKit

/// Captures single-finger/Pencil pointer input, hover (Pencil / iPad pointer), two-finger right-click,
/// and two-finger scrolling, converting positions into normalized video-rect coordinates.
final class TouchInputView: UIView, UIGestureRecognizerDelegate {
    var videoSize = CGSize.zero
    var send: (([InputEvent]) -> Void)?

    private weak var activeTouch: UITouch?
    private var suppressedForMultitouch = false
    private var lastScrollTranslation = CGPoint.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(onHover(_:)))
        addGestureRecognizer(hover)

        let rightTap = UITapGestureRecognizer(target: self, action: #selector(onTwoFingerTap(_:)))
        rightTap.numberOfTouchesRequired = 2
        rightTap.delegate = self
        addGestureRecognizer(rightTap)

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(onTwoFingerPan(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        scroll.allowedScrollTypesMask = .all
        scroll.delegate = self
        addGestureRecognizer(scroll)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var videoRect: CGRect {
        DisplayGeometry.aspectFit(videoSize, in: bounds)
    }

    // MARK: Direct touches (1 finger or Apple Pencil)

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let allTouches = event?.allTouches ?? touches
        // Pencil always takes priority and is never part of a two-finger gesture.
        if let pencil = touches.first(where: { $0.type == .pencil }) {
            if activeTouch != nil { send?([makeEvent(.cancel, for: pencil)]) }
            activeTouch = pencil
            suppressedForMultitouch = false
            send?([makeEvent(.down, for: pencil)])
            return
        }
        if allTouches.count >= 2 {
            // Second finger landed: cancel any in-flight primary drag so two-finger tap/scroll cleanly takes over.
            if let t = activeTouch {
                send?([makeEvent(.cancel, for: t)])
                activeTouch = nil
            }
            suppressedForMultitouch = true
            return
        }
        guard !suppressedForMultitouch, activeTouch == nil, let t = touches.first else { return }
        activeTouch = t
        send?([makeEvent(.down, for: t)])
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = activeTouch, touches.contains(t) else { return }
        let samples = event?.coalescedTouches(for: t) ?? [t]
        send?(samples.map { makeEvent(.move, for: $0) })
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let t = activeTouch, touches.contains(t) {
            send?([makeEvent(.up, for: t)])
            activeTouch = nil
        }
        if (event?.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled }.count ?? 0) == 0 {
            suppressedForMultitouch = false
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let t = activeTouch, touches.contains(t) {
            send?([makeEvent(.cancel, for: t)])
            activeTouch = nil
        }
        suppressedForMultitouch = false
    }

    private func makeEvent(_ kind: InputEvent.Kind, for touch: UITouch) -> InputEvent {
        let (x, y) = DisplayGeometry.normalize(touch.preciseLocation(in: self), in: videoRect)
        let isPencil = touch.type == .pencil
        let pressure: Float = isPencil && touch.maximumPossibleForce > 0
            ? Float(touch.force / touch.maximumPossibleForce)
            : 1.0
        return InputEvent(kind: kind, pointer: isPencil ? .pencil : .finger, x: x, y: y, pressure: pressure)
    }

    // MARK: Gestures

    @objc private func onHover(_ gr: UIHoverGestureRecognizer) {
        guard activeTouch == nil else { return }
        switch gr.state {
        case .began, .changed:
            let (x, y) = DisplayGeometry.normalize(gr.location(in: self), in: videoRect)
            send?([InputEvent(kind: .hover, pointer: .mouse, x: x, y: y)])
        default:
            break
        }
    }

    @objc private func onTwoFingerTap(_ gr: UITapGestureRecognizer) {
        guard gr.state == .ended else { return }
        let (x, y) = DisplayGeometry.normalize(gr.location(in: self), in: videoRect)
        send?([InputEvent(kind: .rightClick, pointer: .finger, x: x, y: y)])
    }

    @objc private func onTwoFingerPan(_ gr: UIPanGestureRecognizer) {
        let rect = videoRect
        guard rect.width > 0, rect.height > 0 else { return }
        switch gr.state {
        case .began:
            lastScrollTranslation = .zero
        case .changed:
            let t = gr.translation(in: self)
            let dx = Float((t.x - lastScrollTranslation.x) / rect.width)
            let dy = Float((t.y - lastScrollTranslation.y) / rect.height)
            lastScrollTranslation = t
            let (x, y) = DisplayGeometry.normalize(gr.location(in: self), in: rect)
            send?([InputEvent(kind: .scroll, pointer: .finger, x: x, y: y, dx: dx, dy: dy)])
        default:
            break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}

