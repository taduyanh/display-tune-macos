import Cocoa
import ApplicationServices

// MARK: - On-screen indicator

private final class SegmentBar: NSView {
    var level: Double = 0 { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let n = 16, gap: CGFloat = 3
        let w = (bounds.width - gap * CGFloat(n - 1)) / CGFloat(n)
        let filled = Int((level * Double(n)).rounded())
        for i in 0..<n {
            let r = NSRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: bounds.height)
            (i < filled ? NSColor.white : NSColor.white.withAlphaComponent(0.28)).setFill()
            NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
        }
    }
}

/// Small HUD shown on the display being adjusted (like the system brightness indicator).
final class BrightnessOSD {
    static let shared = BrightnessOSD()
    private var panel: NSPanel?
    private let bar = SegmentBar()
    private var hideWork: DispatchWorkItem?
    private var fadeToken = 0           // invalidates the completion handler of a fade that a newer press overtook

    private func build() -> NSPanel {
        let size = NSSize(width: 320, height: 64)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.level = .screenSaver; p.ignoresMouseEvents = true; p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        blur.material = .hudWindow; blur.blendingMode = .behindWindow; blur.state = .active
        blur.wantsLayer = true; blur.layer?.cornerRadius = 18; blur.layer?.masksToBounds = true

        let icon = NSImageView(frame: NSRect(x: 18, y: 16, width: 32, height: 32))
        icon.image = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: nil)
        icon.contentTintColor = .white
        icon.imageScaling = .scaleProportionallyUpOrDown
        bar.frame = NSRect(x: 64, y: 26, width: 238, height: 12)
        blur.addSubview(icon); blur.addSubview(bar)
        p.contentView = blur
        return p
    }

    /// Offscreen render of the indicator (for checking the layout without screen-recording permission).
    func previewPNG(level: Double) -> Data? {
        let p = panel ?? build(); panel = p
        bar.level = level
        guard let v = p.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        let out = NSImage(size: v.bounds.size)
        out.lockFocus()
        NSColor(white: 0.25, alpha: 1).setFill(); NSRect(origin: .zero, size: v.bounds.size).fill()
        rep.draw(in: NSRect(origin: .zero, size: v.bounds.size))
        out.unlockFocus()
        return out.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
    }

    func show(level: Double, on screen: NSScreen) {
        let p = panel ?? build()
        panel = p
        bar.level = max(0, min(1, level))
        let f = screen.frame
        p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.minY + 140))
        fadeToken += 1
        let token = fadeToken
        NSAnimationContext.runAnimationGroup { $0.duration = 0; p.animator().alphaValue = 1 }   // also stops a running fade
        p.orderFrontRegardless()
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self, weak p] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; p?.animator().alphaValue = 0 },
                                                 completionHandler: { if self?.fadeToken == token { p?.orderOut(nil) } })
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: w)
    }
}

// MARK: - Brightness keys

/// Takes over the keyboard brightness keys (F1/F2) while the pointer is on an external display,
/// and drives that display over DDC (or software dimming when DDC is unavailable).
/// Needs the Accessibility permission. Keys pressed with the pointer on the built-in display are untouched.
final class BrightnessKeys {
    static let shared = BrightnessKeys()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retryTimer: Timer?
    private var prompted = false

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "brightnessKeys") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "brightnessKeys") }
    }
    var isActive: Bool { tap != nil }

    func start() {
        guard enabled else { return }
        if install() { return }
        requestAccessibility()
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if !self.enabled || self.install() { t.invalidate(); self.retryTimer = nil }
        }
    }

    func stop() {
        retryTimer?.invalidate(); retryTimer = nil
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        tap = nil; source = nil
    }

    func requestAccessibility() {
        guard !prompted else { return }
        prompted = true
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @discardableResult
    private func install() -> Bool {
        if tap != nil { return true }
        let mask = CGEventMask(1 << 14)   // NX_SYSDEFINED (media / brightness keys)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: brightnessTapCallback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let s = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), s, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t; source = s
        return true
    }

    fileprivate func reenable() { if let t = tap { CGEvent.tapEnable(tap: t, enable: true) } }

    // MARK: Handling

    /// External display under the pointer, or nil (built-in display, unknown) -> let macOS handle the key.
    func displayUnderPointer() -> (display: ManagedDisplay, screen: NSScreen)? {
        let loc = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(loc, $0.frame, false) }),
              var id = screen.displayID else { return nil }
        let mgr = DisplayManager.shared
        if let physical = mgr.flexible.first(where: { $0.value.virtualID == id })?.key { id = physical }
        guard let d = mgr.displays.first(where: { $0.id == id }) else { return nil }
        return (d, screen)
    }

    fileprivate func handle(up: Bool, isDown: Bool, flags: NSEvent.ModifierFlags) -> Bool {
        guard let target = displayUnderPointer() else { return false }
        if isDown {
            let fine = flags.contains(.shift) && flags.contains(.option)   // ⇧⌥ = quarter steps, like macOS
            step(display: target.display, screen: target.screen, up: up, fine: fine)
        }
        return true   // swallow both key-down and key-up
    }

    /// One brightness step (1/16 of the range, 1/64 with ⇧⌥). Falls back to software dimming when the
    /// monitor does not answer over DDC.
    func step(display d: ManagedDisplay, screen: NSScreen?, up: Bool, fine: Bool) {
        let sign = up ? 1 : -1
        func softwareStep() {
            d.setSoftwareDim(d.softwareDim + Double(sign) * (fine ? 0.0125 : 0.05))
            if let screen { BrightnessOSD.shared.show(level: (d.softwareDim - 0.2) / 0.8, on: screen) }
        }
        guard d.supportsDDC else { softwareStep(); return }
        let delta = sign * max(1, Int((Double(d.hardwareMax) / (fine ? 64 : 16)).rounded()))
        d.adjustHardwareBrightness(by: delta) { next in
            guard let next else { softwareStep(); return }
            if let screen { BrightnessOSD.shared.show(level: Double(next) / Double(d.hardwareMax), on: screen) }
        }
    }
}

private func brightnessTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                   refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let me = Unmanaged<BrightnessKeys>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        me.reenable()
        return Unmanaged.passUnretained(event)
    }
    guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
        return Unmanaged.passUnretained(event)
    }
    let keyCode = (ns.data1 & 0xFFFF0000) >> 16          // 2 = brightness up, 3 = brightness down
    let keyFlags = ns.data1 & 0x0000FFFF
    let isDown = ((keyFlags & 0xFF00) >> 8) == 0xA
    guard keyCode == 2 || keyCode == 3 else { return Unmanaged.passUnretained(event) }
    return me.handle(up: keyCode == 2, isDown: isDown, flags: ns.modifierFlags) ? nil : Unmanaged.passUnretained(event)
}
