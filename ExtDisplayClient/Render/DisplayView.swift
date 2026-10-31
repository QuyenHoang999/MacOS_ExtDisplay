import SwiftUI
import UIKit

/// SwiftUI wrapper hosting the Metal video layer and the touch-input overlay.
struct DisplayView: UIViewRepresentable {
    @EnvironmentObject var model: ClientModel

    func makeUIView(context: Context) -> DisplayUIView {
        let v = DisplayUIView(renderer: model.renderer)
        v.onScreenInfo = { [weak model] info in model?.updateScreen(info) }
        v.input.send = { [weak model] events in model?.send(events) }
        return v
    }

    func updateUIView(_ uiView: DisplayUIView, context: Context) {
        if let cfg = model.config {
            uiView.input.videoSize = CGSize(width: cfg.width, height: cfg.height)
        }
        uiView.input.isUserInteractionEnabled = model.state == .streaming
    }
}

final class DisplayUIView: UIView {
    let renderer: MetalRenderer
    let input = TouchInputView()
    var onScreenInfo: ((ClientModel.ScreenInfo) -> Void)?

    init(renderer: MetalRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(renderer.layer)
        addSubview(input)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.nativeScale ?? traitCollection.displayScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderer.layer.frame = bounds
        renderer.layer.contentsScale = scale
        CATransaction.commit()
        input.frame = bounds

        let pixels = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        renderer.updateDrawableSize(pixels)
        if let screen = window?.screen {
            let screenW = Int((screen.bounds.width * screen.nativeScale).rounded())
            let screenH = Int((screen.bounds.height * screen.nativeScale).rounded())
            if screenW > 0, screenH > 0 {
                onScreenInfo?(ClientModel.ScreenInfo(pixelsWide: screenW, pixelsHigh: screenH,
                                                      scale: Double(screen.nativeScale),
                                                      maxFPS: screen.maximumFramesPerSecond))
            }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
    }
}

