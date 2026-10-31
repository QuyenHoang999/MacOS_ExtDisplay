import Foundation
import CoreGraphics

enum HostError: LocalizedError {
    case virtualDisplay(String)
    case capture(String)
    case encoder(OSStatus)
    case usbmux(String)

    var errorDescription: String? {
        switch self {
        case .virtualDisplay(let s): return "Virtual display: \(s)"
        case .capture(let s): return "Screen capture: \(s)"
        case .encoder(let s): return "Video encoder error \(s)"
        case .usbmux(let s): return "USB: \(s)"
        }
    }
}

/// Owns one `CGVirtualDisplay`. Updates modes in-place whenever possible and ensures the
/// display is configured as an extended desktop (never mirrored) so the user never needs ⌘F1.
@MainActor
final class VirtualDisplayManager {
    private(set) var display: CGVirtualDisplay?
    private var currentName: String?
    private var currentMaxWide: Int = 0
    private var currentMaxHigh: Int = 0

    var displayID: CGDirectDisplayID { display?.displayID ?? kCGNullDirectDisplay }
    var isActive: Bool { display != nil }

    /// Creates the virtual display if needed, or updates its resolution/refresh mode in-place
    /// without disconnecting the monitor from WindowServer.
    @discardableResult
    func create(name: String, pointsWide: Int, pointsHigh: Int, hiDPI: Bool,
                refreshRate: Double, sizeInMillimeters: CGSize) throws -> CGDirectDisplayID {
        let pixelsWide = hiDPI ? pointsWide * 2 : pointsWide
        let pixelsHigh = hiDPI ? pointsHigh * 2 : pointsHigh

        let vd: CGVirtualDisplay
        if let existing = display, currentName == name,
           pixelsWide <= currentMaxWide, pixelsHigh <= currentMaxHigh,
           existing.displayID != kCGNullDirectDisplay {
            vd = existing
        } else {
            destroy()
            let maxW = max(pixelsWide, 3840)
            let maxH = max(pixelsHigh, 3840)
            let safeSize = CGSize(
                width: max(sizeInMillimeters.width, 150),
                height: max(sizeInMillimeters.height, 100)
            )

            if let created = Self.makeDisplay(
                name: name,
                maxPixelsWide: maxW,
                maxPixelsHigh: maxH,
                sizeInMillimeters: safeSize,
                serialNum: Self.stableSerial(for: name)
            ) {
                vd = created
                currentMaxWide = maxW
                currentMaxHigh = maxH
            } else if let fallback = Self.makeDisplay(
                name: name,
                maxPixelsWide: pixelsWide,
                maxPixelsHigh: pixelsHigh,
                sizeInMillimeters: safeSize,
                serialNum: UInt32.random(in: 1...UInt32.max)
            ) {
                vd = fallback
                currentMaxWide = pixelsWide
                currentMaxHigh = pixelsHigh
            } else {
                throw HostError.virtualDisplay("CGVirtualDisplay could not be created")
            }

            display = vd
            currentName = name
        }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        var modes: [CGVirtualDisplayMode] = [
            CGVirtualDisplayMode(width: UInt32(pointsWide), height: UInt32(pointsHigh), refreshRate: refreshRate),
        ]
        if hiDPI {
            modes.append(CGVirtualDisplayMode(width: UInt32(pixelsWide), height: UInt32(pixelsHigh), refreshRate: refreshRate))
        }
        if refreshRate > 60 {
            modes.append(CGVirtualDisplayMode(width: UInt32(pointsWide), height: UInt32(pointsHigh), refreshRate: 60))
            if hiDPI {
                modes.append(CGVirtualDisplayMode(width: UInt32(pixelsWide), height: UInt32(pixelsHigh), refreshRate: 60))
            }
        }
        settings.modes = modes
        guard vd.apply(settings) else {
            throw HostError.virtualDisplay("applySettings failed")
        }

        let id = vd.displayID
        ensureExtendedMode(displayID: id)
        return id
    }

    private static func makeDisplay(name: String, maxPixelsWide: Int, maxPixelsHigh: Int,
                                    sizeInMillimeters: CGSize, serialNum: UInt32) -> CGVirtualDisplay? {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(maxPixelsWide)
        descriptor.maxPixelsHigh = UInt32(maxPixelsHigh)
        descriptor.sizeInMillimeters = sizeInMillimeters
        descriptor.vendorID = 0x3456
        descriptor.productID = 0xE0D1
        descriptor.serialNum = serialNum
        descriptor.whitePoint = CGPoint(x: 0.3125, y: 0.3291)
        descriptor.redPrimary = CGPoint(x: 0.6797, y: 0.3203)
        descriptor.greenPrimary = CGPoint(x: 0.2559, y: 0.6983)
        descriptor.bluePrimary = CGPoint(x: 0.1494, y: 0.0557)
        descriptor.queue = DispatchQueue.main
        return CGVirtualDisplay(descriptor: descriptor)
    }

    /// Automatically disables hardware mirroring if macOS defaulted the new virtual display
    /// to mirror the built-in screen, so the user never has to press ⌘F1.
    private func ensureExtendedMode(displayID: CGDirectDisplayID) {
        guard displayID != kCGNullDirectDisplay else { return }
        Self.disableMirroringIfNeeded(displayID: displayID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            Self.disableMirroringIfNeeded(displayID: displayID)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            Self.disableMirroringIfNeeded(displayID: displayID)
        }
    }

    private static func disableMirroringIfNeeded(displayID: CGDirectDisplayID) {
        guard CGDisplayIsInMirrorSet(displayID) != 0 else { return }
        var online = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(online.count), &online, &count) == .success else { return }

        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let configRef else { return }
        for i in 0..<Int(count) {
            let id = online[i]
            if CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay {
                CGConfigureDisplayMirrorOfDisplay(configRef, id, kCGNullDirectDisplay)
            }
        }
        CGConfigureDisplayMirrorOfDisplay(configRef, displayID, kCGNullDirectDisplay)
        CGCompleteDisplayConfiguration(configRef, .permanently)
    }

    private static func stableSerial(for name: String) -> UInt32 {
        var hash: UInt32 = 2166136261
        for b in name.utf8 {
            hash ^= UInt32(b)
            hash &*= 16777619
        }
        return max(1, hash)
    }

    func destroy() {
        display = nil
        currentName = nil
        currentMaxWide = 0
        currentMaxHigh = 0
    }

    /// Global bounds of the virtual display in Mac points (top-left origin).
    var bounds: CGRect {
        guard isActive else { return .zero }
        return CGDisplayBounds(displayID)
    }

    /// Current framebuffer size in pixels.
    var pixelSize: CGSize {
        guard isActive, let mode = CGDisplayCopyDisplayMode(displayID) else { return .zero }
        return CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
    }
}
