import Cocoa

extension NSScreen {
    /// The CGDirectDisplayID behind this screen.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

// MARK: - Modes (public CoreGraphics API only)

/// One selectable display mode.
struct ModeOption {
    let mode: CGDisplayMode
    var isHiDPI: Bool { mode.pixelWidth > mode.width }
    var title: String {
        var s = "\(mode.width) × \(mode.height)"
        if isHiDPI { s += "  HiDPI" }
        if mode.refreshRate > 0 { s += "  ·  \(Int(mode.refreshRate.rounded())) Hz" }
        return s
    }
    func matches(_ other: CGDisplayMode) -> Bool {
        mode.width == other.width && mode.height == other.height &&
        mode.pixelWidth == other.pixelWidth && mode.pixelHeight == other.pixelHeight &&
        abs(mode.refreshRate - other.refreshRate) < 0.5
    }
}

/// A single snapshot of one display's mode list. Build it once per display and query it as often as needed,
/// instead of asking CoreGraphics for the full mode list on every question.
struct ModeCatalog {
    let current: CGDisplayMode?
    let all: [CGDisplayMode]                   // usable for the desktop, incl. the 1:1 twins of HiDPI modes
    let native: (w: Int, h: Int)?              // panel size = largest non-HiDPI mode

    init(_ id: CGDirectDisplayID) {
        current = CGDisplayCopyDisplayMode(id)
        let opts = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        all = ((CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode]) ?? []).filter { $0.isUsableForDesktopGUI() }
        native = all.filter { $0.pixelWidth == $0.width }.max { $0.pixelWidth < $1.pixelWidth }.map { ($0.pixelWidth, $0.pixelHeight) }
    }

    /// Compact list by default (panel's aspect ratio, HiDPI + native modes, current refresh rate); everything with `showAll`.
    func options(showAll: Bool) -> [ModeOption] {
        var modes = all
        if !showAll, let n = native {
            let aspect = Double(n.w) / Double(n.h)
            let hz = current?.refreshRate ?? 0
            modes = modes.filter {
                abs(Double($0.width) / Double($0.height) - aspect) < 0.01 &&
                ($0.pixelWidth > $0.width || $0.pixelWidth == n.w) &&
                (hz <= 0 || abs($0.refreshRate - hz) < 0.5)
            }
        }
        var seen = Set<String>()
        var out: [ModeOption] = []
        for m in modes.sorted(by: {
            if $0.width != $1.width { return $0.width > $1.width }
            if ($0.pixelWidth > $0.width) != ($1.pixelWidth > $1.width) { return $0.pixelWidth > $0.width }
            return $0.refreshRate > $1.refreshRate
        }) where seen.insert("\(m.width)x\(m.height)-\(m.pixelWidth)-\(Int(m.refreshRate.rounded()))").inserted {
            out.append(ModeOption(mode: m))
        }
        return out
    }

    /// Same resolution as the current mode, one entry per refresh rate.
    func refreshOptions() -> [ModeOption] {
        guard let cur = current else { return [] }
        var seen = Set<Int>()
        return all.filter { $0.width == cur.width && $0.height == cur.height &&
                            $0.pixelWidth == cur.pixelWidth && $0.pixelHeight == cur.pixelHeight }
            .sorted { $0.refreshRate > $1.refreshRate }
            .filter { seen.insert(Int($0.refreshRate.rounded())).inserted }
            .map { ModeOption(mode: $0) }
    }

    /// The same "looks like" size in the opposite scaling (HiDPI <-> 1:1), nearest refresh rate.
    func counterpart() -> ModeOption? {
        guard let cur = current else { return nil }
        let curHiDPI = cur.pixelWidth > cur.width
        return all.filter { $0.width == cur.width && $0.height == cur.height && ($0.pixelWidth > $0.width) != curHiDPI }
            .min { abs($0.refreshRate - cur.refreshRate) < abs($1.refreshRate - cur.refreshRate) }
            .map { ModeOption(mode: $0) }
    }

    /// "Looks like" sizes that macOS does not offer natively as HiDPI but that make sense for this panel.
    func flexibleCandidates() -> [(w: Int, h: Int)] {
        guard let n = native else { return [] }
        let aspect = Double(n.w) / Double(n.h)
        let nativeHiDPI = Set(all.filter { $0.pixelWidth > $0.width }.map { "\($0.width)x\($0.height)" })
        var out: [(Int, Int)] = []
        for w in [1440, 1600, 1680, 1920, 2048, 2304, 2560] {
            var h = Int((Double(w) / aspect).rounded()); if h % 2 == 1 { h += 1 }
            guard w * 2 >= n.w, w * 2 <= 5120, !nativeHiDPI.contains("\(w)x\(h)") else { continue }
            out.append((w, h))
        }
        return out
    }
}

// MARK: - Display model

enum DDCStatus { case unknown, working, failed }

final class ManagedDisplay {
    var id: CGDirectDisplayID
    /// Unique per attached display (identical monitors get a "#n" suffix).
    let key: String
    var name: String
    var ddc: DDC.Endpoint?
    /// An IORegistry endpoint exists for every external display; only a successful read proves DDC/CI works.
    var ddcStatus: DDCStatus = .unknown
    var supportsDDC: Bool { ddc != nil && ddcStatus != .failed }

    /// Last known hardware (DDC) brightness, in the monitor's own units.
    private(set) var hardwareBrightness: Int?
    private(set) var hardwareMax = 100
    /// When `hardwareBrightness` was last read from / written to the monitor.
    private(set) var brightnessStamp = Date.distantPast
    /// Software dimming factor (gamma), 0.2...1.0. Applied by this process only.
    private(set) var softwareDim: Double

    private let ioQueue: DispatchQueue
    private let lock = NSLock()
    private var pendingBrightness: Int?
    private var writeSeq = 0            // bumped on every write; lets a slow read notice it is stale
    private var reading = false
    private var queuedDelta = 0

    init(id: CGDirectDisplayID, key: String, name: String) {
        self.id = id
        self.key = key
        self.name = name
        self.ioQueue = DispatchQueue(label: "displaytune.ddc.\(key)")
        self.softwareDim = UserDefaults.standard.object(forKey: "dim.\(key)") as? Double ?? 1.0
    }

    // MARK: Hardware brightness (DDC) — main-thread API, I/O happens on a private queue

    /// Reads the monitor's brightness. A read that raced with a newer write is ignored (the write wins).
    func readHardwareBrightness(_ done: @escaping (Bool) -> Void) {
        guard let ep = ddc else { done(false); return }
        let seq = writeSeq
        ioQueue.async { [weak self] in
            let r = DDC.getVCP(ep.service, code: DDC.brightnessCode)
            DispatchQueue.main.async {
                guard let self else { done(false); return }
                if let r {
                    self.ddcStatus = .working
                    self.hardwareMax = r.max
                    if self.writeSeq == seq { self.hardwareBrightness = r.current; self.brightnessStamp = Date() }
                } else {
                    self.ddcStatus = .failed
                }
                done(r != nil)
            }
        }
    }

    /// Latest value wins: while a slow DDC write is in flight, newer values replace older pending ones.
    func setHardwareBrightness(_ value: Int) {
        guard let ep = ddc else { return }
        let v = max(0, min(hardwareMax, value))
        hardwareBrightness = v
        brightnessStamp = Date()
        writeSeq += 1
        lock.lock(); pendingBrightness = v; lock.unlock()
        ioQueue.async { [weak self] in
            guard let self else { return }
            while true {
                self.lock.lock(); let next = self.pendingBrightness; self.pendingBrightness = nil; self.lock.unlock()
                guard let next else { return }
                DDC.setVCP(ep.service, code: DDC.brightnessCode, value: UInt16(next))
                usleep(30_000)
            }
        }
    }

    /// Relative change used by the brightness keys. Uses the cached value while it is fresh; otherwise reads the monitor
    /// first (it may have been changed from its own buttons). Presses that arrive during that read are merged.
    /// `completion` gets the new value, or nil when the monitor does not answer over DDC.
    func adjustHardwareBrightness(by delta: Int, completion: @escaping (Int?) -> Void) {
        if let cur = hardwareBrightness, Date().timeIntervalSince(brightnessStamp) < 3 {
            setHardwareBrightness(cur + delta)
            completion(hardwareBrightness)
            return
        }
        queuedDelta += delta
        if reading { return }
        reading = true
        readHardwareBrightness { [weak self] ok in
            guard let self else { return }
            self.reading = false
            let total = self.queuedDelta; self.queuedDelta = 0
            guard ok, let cur = self.hardwareBrightness else { completion(nil); return }
            self.setHardwareBrightness(cur + total)
            completion(self.hardwareBrightness)
        }
    }

    // MARK: Software dimming (gamma)

    func setSoftwareDim(_ factor: Double) {
        softwareDim = min(1.0, max(0.2, factor))
        UserDefaults.standard.set(softwareDim, forKey: "dim.\(key)")
        applySoftwareDim()
    }

    func applySoftwareDim() {
        let v = Float(softwareDim)
        CGSetDisplayTransferByFormula(id, 0, v, 1, 0, v, 1, 0, v, 1)
    }
}

// MARK: - Manager

final class DisplayManager {
    static let shared = DisplayManager()
    private(set) var displays: [ManagedDisplay] = []
    private var known: [String: ManagedDisplay] = [:]
    /// Active flexible-HiDPI sessions, keyed by the physical display's ID.
    var flexible: [CGDirectDisplayID: FlexibleHiDPI] = [:]
    /// The physical panel's own mode list, captured before a flexible session started. While the panel is mirrored
    /// onto the virtual display, CoreGraphics reports the virtual display's modes instead.
    var baseCatalog: [CGDirectDisplayID: ModeCatalog] = [:]

    /// Re-enumerate external displays and re-pair them with their DDC channel. Call it when the display configuration
    /// changes — it walks the IORegistry, so it is not meant to run on every menu open.
    /// `applyingDim: false` is for short-lived processes (the CLI), whose gamma changes would vanish on exit anyway
    /// and would take the running app's dimming down with them.
    func refresh(applyingDim: Bool = true) {
        autoreleasepool {
            var ids = [CGDirectDisplayID](repeating: 0, count: 16)
            var count: UInt32 = 0
            CGGetOnlineDisplayList(16, &ids, &count)
            let online = Array(ids.prefix(Int(count)))

            // A flexible session whose physical display vanished (unplug, sleep, new ID) would leave a phantom virtual screen.
            for pid in Array(flexible.keys) where !online.contains(pid) { stopFlexible(pid) }

            let virtualIDs = Set(flexible.values.map { $0.virtualID })
            var endpoints = DDC.discover()
            var seen: [String: Int] = [:]
            var result: [ManagedDisplay] = []

            for id in online {
                if CGDisplayIsBuiltin(id) != 0 { continue }
                if virtualIDs.contains(id) || CGDisplayVendorNumber(id) == FlexibleHiDPI.vendorID { continue }

                let vendor = CGDisplayVendorNumber(id), model = CGDisplayModelNumber(id)
                let base = "\(vendor)-\(model)-\(CGDisplaySerialNumber(id))"
                let n = seen[base, default: 0]; seen[base] = n + 1
                let key = n == 0 ? base : "\(base)#\(n)"      // identical monitors can share EDID vendor/model/serial

                let name = NSScreen.screens.first { $0.displayID == id }?.localizedName
                let d = known[key] ?? ManagedDisplay(id: id, key: key, name: name ?? "Display \(id)")
                d.id = id
                if let name { d.name = name }
                known[key] = d

                if let i = endpoints.firstIndex(where: { $0.vendor == Int(vendor) && $0.product == Int(model) }) {
                    if d.ddc == nil { d.ddcStatus = .unknown }
                    d.ddc = endpoints.remove(at: i)
                    if d.ddcStatus == .unknown { d.readHardwareBrightness { _ in } }   // probe once, off the main thread
                } else {
                    d.ddc = nil
                    d.ddcStatus = .unknown
                }
                if applyingDim && d.softwareDim < 1.0 { d.applySoftwareDim() }
                result.append(d)
            }
            displays = result
        }
    }

    @discardableResult
    func apply(_ mode: CGDisplayMode, to id: CGDirectDisplayID, permanently: Bool = true) -> Bool {
        var cfg: CGDisplayConfigRef? = nil
        guard CGBeginDisplayConfiguration(&cfg) == .success, let c = cfg else { return false }
        guard CGConfigureDisplayWithDisplayMode(c, id, mode, nil) == .success else {
            CGCancelDisplayConfiguration(c); return false
        }
        return CGCompleteDisplayConfiguration(c, permanently ? .permanently : .forSession) == .success
    }

    func stopFlexible(_ physicalID: CGDirectDisplayID) {
        flexible[physicalID]?.stop()
        flexible[physicalID] = nil
        baseCatalog[physicalID] = nil
    }
}
