import Cocoa

/// HiDPI for panels that macOS does not offer HiDPI modes for (e.g. a 2560x1440 monitor
/// at "looks like 1920x1080"). Creates a virtual display that renders at 2x and mirrors
/// the physical display onto it, so the GPU downsamples a sharp 3840x2160 image to the panel.
final class FlexibleHiDPI {
    static let vendorID: UInt32 = 0x7ABC

    let physicalID: CGDirectDisplayID
    let width: Int, height: Int
    private let refreshRate: Double
    private let name: String
    private var virtualDisplay: CGVirtualDisplay?
    private let queue = DispatchQueue(label: "displaytune.virtualdisplay")
    private var savedOrigin = CGPoint.zero
    private(set) var mirrored = false   // true only once the mirror configuration was committed

    var virtualID: CGDirectDisplayID { virtualDisplay?.displayID ?? 0 }

    init(physicalID: CGDirectDisplayID, name: String, width: Int, height: Int) {
        self.physicalID = physicalID
        self.name = name
        self.width = width
        self.height = height
        let hz = CGDisplayCopyDisplayMode(physicalID)?.refreshRate ?? 60
        self.refreshRate = hz > 0 ? hz : 60
    }

    /// Creates the virtual display and mirrors the physical one onto it. Never blocks the main thread.
    /// `completion` receives nil on success or a human-readable error (the session is already cleaned up then).
    func start(completion: @escaping (String?) -> Void) {
        let desc = CGVirtualDisplayDescriptor()
        desc.queue = queue                      // not main: the wait below must not starve the display's own callbacks
        desc.name = "DisplayTune HiDPI – \(name)"
        desc.maxPixelsWide = UInt32(width * 2)
        desc.maxPixelsHigh = UInt32(height * 2)
        let mm = CGDisplayScreenSize(physicalID)
        desc.sizeInMillimeters = (mm.width > 0 && mm.height > 0) ? mm : CGSize(width: 600, height: 340)
        desc.vendorID = FlexibleHiDPI.vendorID
        desc.productID = 0xD15A
        // Stable across replugs (a changing serial makes macOS treat it as a new screen and forget its position).
        desc.serialNum = FlexibleHiDPI.stableSerial(for: physicalID)

        guard let vd = CGVirtualDisplay(descriptor: desc) else { completion("macOS refused to create the virtual display."); return }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [CGVirtualDisplayMode(width: UInt32(width), height: UInt32(height), refreshRate: refreshRate)]
        guard vd.apply(settings) else { completion("Could not apply HiDPI settings to the virtual display."); return }
        virtualDisplay = vd

        waitForOnline(vd.displayID, attemptsLeft: 40) { [weak self] online in
            guard let self, self.virtualDisplay != nil else { return }   // stopped while waiting
            guard online else { self.stop(); completion("The virtual display did not come online."); return }
            let error = self.mirror()
            if error != nil { self.stop() }
            completion(error)
        }
    }

    /// FNV-1a hash of the panel's EDID vendor / model / serial: the same monitor always yields the same value.
    static func stableSerial(for id: CGDirectDisplayID) -> UInt32 {
        var h: UInt32 = 2166136261
        for v in [CGDisplayVendorNumber(id), CGDisplayModelNumber(id), CGDisplaySerialNumber(id)] {
            for shift in stride(from: 0, to: 32, by: 8) { h = (h ^ ((v >> UInt32(shift)) & 0xFF)) &* 16777619 }
        }
        return h == 0 ? 1 : h
    }

    private func waitForOnline(_ id: CGDirectDisplayID, attemptsLeft: Int, _ done: @escaping (Bool) -> Void) {
        if CGDisplayCopyDisplayMode(id) != nil { done(true); return }
        if attemptsLeft <= 0 { done(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.waitForOnline(id, attemptsLeft: attemptsLeft - 1, done)
        }
    }

    private func mirror() -> String? {
        guard let vd = virtualDisplay else { return "The virtual display is gone." }
        // Make sure the virtual display runs its HiDPI mode (session only — never persisted).
        let opts = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        if let modes = CGDisplayCopyAllDisplayModes(vd.displayID, opts) as? [CGDisplayMode],
           let hi = modes.first(where: { $0.width == width && $0.height == height && $0.pixelWidth == width * 2 }) {
            DisplayManager.shared.apply(hi, to: vd.displayID, permanently: false)
        }
        // Keep the physical display's position, then mirror it onto the virtual display.
        savedOrigin = CGDisplayBounds(physicalID).origin
        var cfg: CGDisplayConfigRef? = nil
        guard CGBeginDisplayConfiguration(&cfg) == .success, let c = cfg else { return "Could not start a display configuration." }
        CGConfigureDisplayOrigin(c, vd.displayID, Int32(savedOrigin.x), Int32(savedOrigin.y))
        CGConfigureDisplayMirrorOfDisplay(c, physicalID, vd.displayID)
        guard CGCompleteDisplayConfiguration(c, .forSession) == .success else { return "macOS rejected the mirroring configuration." }
        mirrored = true
        return nil
    }

    func stop() {
        guard virtualDisplay != nil else { return }
        // Only undo what was actually done, and only if the physical display is still there.
        if mirrored && CGDisplayIsOnline(physicalID) != 0 {
            // The user may have rearranged displays during the session: use the position as it is now.
            savedOrigin = CGDisplayBounds(physicalID).origin
            var cfg: CGDisplayConfigRef? = nil
            if CGBeginDisplayConfiguration(&cfg) == .success, let c = cfg {
                CGConfigureDisplayMirrorOfDisplay(c, physicalID, kCGNullDirectDisplay)
                CGCompleteDisplayConfiguration(c, .forSession)
            }
            var cfg2: CGDisplayConfigRef? = nil
            if CGBeginDisplayConfiguration(&cfg2) == .success, let c = cfg2 {
                CGConfigureDisplayOrigin(c, physicalID, Int32(savedOrigin.x), Int32(savedOrigin.y))
                CGCompleteDisplayConfiguration(c, .forSession)
            }
        }
        mirrored = false
        virtualDisplay = nil   // releasing the object destroys the virtual display
    }

    deinit { stop() }
}
