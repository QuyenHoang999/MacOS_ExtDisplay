import Foundation
import Metal
import QuartzCore
import CoreVideo
import UIKit

/// Renders NV12 frames to a CAMetalLayer as soon as they arrive (latest-frame-wins, no queue).
final class MetalRenderer: @unchecked Sendable {
    let layer = CAMetalLayer()

    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?
    private let renderQueue = DispatchQueue(label: "extdisplay.render", qos: .userInteractive)

    private let lock = NSLock()
    private var pending: CVPixelBuffer?
    private var last: CVPixelBuffer?
    private var rendering = false
    private var drawableSize = CGSize.zero

    init() {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 2
        layer.allowsNextDrawableTimeout = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.isOpaque = true
        layer.backgroundColor = UIColor.black.cgColor
        if let device {
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
            pipeline = try? Self.makePipeline(device: device)
        }
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 pos [[position]]; float2 uv; };

    // rect = (originX, originY, width, height) in NDC.
    vertex VOut vmain(uint vid [[vertex_id]], constant float4 &rect [[buffer(0)]]) {
        float2 p = float2((vid & 1) ? 1.0 : 0.0, (vid & 2) ? 1.0 : 0.0);
        VOut o;
        o.pos = float4(rect.xy + p * rect.zw, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }

    // BT.709 video-range YCbCr → RGB.
    fragment half4 fmain(VOut in [[stage_in]],
                         texture2d<float> yTex [[texture(0)]],
                         texture2d<float> cTex [[texture(1)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float y = (yTex.sample(s, in.uv).r - 16.0 / 255.0) * (255.0 / 219.0);
        float2 c = (cTex.sample(s, in.uv).rg - 128.0 / 255.0) * (255.0 / 224.0);
        float3 rgb = float3(y + 1.5748 * c.y,
                            y - 0.1873 * c.x - 0.4681 * c.y,
                            y + 1.8556 * c.x);
        return half4(half3(saturate(rgb)), 1.0h);
    }
    """

    private static func makePipeline(device: MTLDevice) throws -> MTLRenderPipelineState {
        let library = try device.makeLibrary(source: shaderSource, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "vmain")
        desc.fragmentFunction = library.makeFunction(name: "fmain")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try device.makeRenderPipelineState(descriptor: desc)
    }

    /// Must be called on the main thread when the hosting view lays out.
    func updateDrawableSize(_ size: CGSize) {
        guard size != layer.drawableSize, size.width > 0, size.height > 0 else { return }
        layer.drawableSize = size
        lock.lock()
        drawableSize = size
        let redraw = last
        lock.unlock()
        if let redraw { enqueue(redraw) }
    }

    /// Thread-safe. Replaces any frame that hasn't been drawn yet.
    func enqueue(_ buffer: CVPixelBuffer) {
        lock.lock()
        pending = buffer
        let start = !rendering
        if start { rendering = true }
        lock.unlock()
        if start { renderQueue.async { [weak self] in self?.drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let buffer = pending else {
                rendering = false
                lock.unlock()
                return
            }
            pending = nil
            last = buffer
            let size = drawableSize
            lock.unlock()
            autoreleasepool { draw(buffer, drawableSize: size) }
        }
    }

    private func draw(_ buffer: CVPixelBuffer, drawableSize: CGSize) {
        guard let queue, let pipeline, let cache = textureCache, drawableSize.width > 0,
              CVPixelBufferGetPlaneCount(buffer) >= 2,
              let yTex = makeTexture(buffer, plane: 0, format: .r8Unorm, cache: cache),
              let cTex = makeTexture(buffer, plane: 1, format: .rg8Unorm, cache: cache),
              let drawable = layer.nextDrawable(),
              let cmd = queue.makeCommandBuffer() else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store

        let videoSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let fit = DisplayGeometry.aspectFit(videoSize, in: CGRect(origin: .zero, size: drawableSize))
        // Convert pixel rect (top-left origin) to NDC (bottom-left origin, -1…1).
        var rect = SIMD4<Float>(Float(fit.minX / drawableSize.width * 2 - 1),
                                Float(1 - fit.maxY / drawableSize.height * 2),
                                Float(fit.width / drawableSize.width * 2),
                                Float(fit.height / drawableSize.height * 2))

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        enc.setFragmentTexture(CVMetalTextureGetTexture(yTex.0), index: 0)
        enc.setFragmentTexture(CVMetalTextureGetTexture(cTex.0), index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        // Keep CoreVideo textures (and their IOSurface) alive until the GPU is done.
        cmd.addCompletedHandler { _ in withExtendedLifetime((yTex, cTex, buffer)) {} }
        cmd.present(drawable)
        cmd.commit()
    }

    private func makeTexture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat,
                             cache: CVMetalTextureCache) -> (CVMetalTexture, Void)? {
        var tex: CVMetalTexture?
        let w = CVPixelBufferGetWidthOfPlane(buffer, plane)
        let h = CVPixelBufferGetHeightOfPlane(buffer, plane)
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, nil, format,
                                                               w, h, plane, &tex)
        guard status == kCVReturnSuccess, let tex else { return nil }
        return (tex, ())
    }

    /// Clears the screen (on disconnect).
    func clear() {
        lock.lock()
        pending = nil
        last = nil
        lock.unlock()
        renderQueue.async { [weak self] in
            guard let self, let queue = self.queue, let drawable = self.layer.nextDrawable(),
                  let cmd = queue.makeCommandBuffer() else { return }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            pass.colorAttachments[0].storeAction = .store
            cmd.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            cmd.present(drawable)
            cmd.commit()
        }
    }
}

