import Foundation
import CoreGraphics

/// Pure geometry helpers shared by host and client.
public enum DisplayGeometry {
    /// Maps a normalized (0…1) point into a display's global bounds (Mac points, top-left origin).
    public static func globalPoint(x: Float, y: Float, in bounds: CGRect) -> CGPoint {
        let cx = min(max(CGFloat(x), 0), 1)
        let cy = min(max(CGFloat(y), 0), 1)
        // Keep strictly inside the display so the cursor never hops to a neighbouring screen.
        let px = bounds.minX + min(cx * bounds.width, bounds.width - 1)
        let py = bounds.minY + min(cy * bounds.height, bounds.height - 1)
        return CGPoint(x: px, y: py)
    }

    /// Aspect-fit rect of `content` inside `container`.
    public static func aspectFit(_ content: CGSize, in container: CGRect) -> CGRect {
        guard content.width > 0, content.height > 0, container.width > 0, container.height > 0 else { return container }
        let scale = min(container.width / content.width, container.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: container.midX - size.width / 2, y: container.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Normalizes a view point against the visible video rect.
    public static func normalize(_ p: CGPoint, in videoRect: CGRect) -> (Float, Float) {
        guard videoRect.width > 0, videoRect.height > 0 else { return (0, 0) }
        return (Float((p.x - videoRect.minX) / videoRect.width), Float((p.y - videoRect.minY) / videoRect.height))
    }

    public enum ScalePreset: String, CaseIterable, Codable, Sendable, Identifiable {
        case retina      // looks like the device's own UI size (2× HiDPI)
        case moreSpace   // 1.5× – more room, still sharp

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .retina: return "Retina (default)"
            case .moreSpace: return "More Space"
            }
        }

        var divisor: Double {
            switch self {
            case .retina: return 2
            case .moreSpace: return 1.5
            }
        }
    }

    public struct VirtualMode: Equatable, Sendable {
        /// Logical size of the virtual display.
        public var pointsWide: Int
        public var pointsHigh: Int
        public var hiDPI: Bool
        /// Framebuffer size of the virtual display.
        public var backingWide: Int { hiDPI ? pointsWide * 2 : pointsWide }
        public var backingHigh: Int { hiDPI ? pointsHigh * 2 : pointsHigh }
        /// Encoded stream size (never larger than the device panel).
        public var streamWide: Int
        public var streamHigh: Int
    }

    /// Computes the virtual display mode for a device panel of `pixelsWide × pixelsHigh`.
    public static func mode(pixelsWide: Int, pixelsHigh: Int, preset: ScalePreset) -> VirtualMode {
        func even(_ v: Double) -> Int { max(2, Int(v.rounded()) & ~1) }
        let pw = even(Double(pixelsWide) / preset.divisor)
        let ph = even(Double(pixelsHigh) / preset.divisor)
        let hiDPI = true
        let backingW = pw * 2
        let backingH = ph * 2
        // Stream at panel resolution (or less) – sending more pixels than the panel has wastes bandwidth.
        let s = min(1.0, Double(pixelsWide) / Double(backingW))
        return VirtualMode(pointsWide: pw, pointsHigh: ph, hiDPI: hiDPI,
                           streamWide: even(Double(backingW) * s), streamHigh: even(Double(backingH) * s))
    }

    /// Physical size of the panel in millimetres (lets macOS pick sensible UI scaling).
    public static func physicalSize(pixelsWide: Int, pixelsHigh: Int, ppi: Double) -> CGSize {
        let p = ppi > 0 ? ppi : 264
        return CGSize(width: Double(pixelsWide) / p * 25.4, height: Double(pixelsHigh) / p * 25.4)
    }
}

