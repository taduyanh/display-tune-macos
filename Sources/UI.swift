import Cocoa
import ServiceManagement

/// A label + slider + percentage readout that can live inside an NSMenu.
final class SliderRow: NSView {
    private let slider = NSSlider()
    private let valueLabel = NSTextField(labelWithString: "")
    var onChange: ((Double) -> Void)?

    init(title: String, min: Double, max: Double, value: Double, enabled: Bool = true) {
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 46))
        autoresizingMask = [.width]

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.textColor = enabled ? .labelColor : .disabledControlTextColor
        titleLabel.frame = NSRect(x: 16, y: 25, width: 250, height: 16)
        addSubview(titleLabel)

        slider.minValue = min; slider.maxValue = max; slider.doubleValue = value
        slider.isContinuous = true; slider.isEnabled = enabled
        slider.target = self; slider.action = #selector(changed)
        slider.frame = NSRect(x: 16, y: 4, width: 200, height: 20)
        slider.autoresizingMask = [.width]
        addSubview(slider)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.alignment = .right
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.frame = NSRect(x: 222, y: 6, width: 48, height: 14)
        valueLabel.autoresizingMask = [.minXMargin]
        addSubview(valueLabel)
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    func setValue(_ v: Double) { slider.doubleValue = v; update() }
    /// Always a percentage of the slider's maximum, whatever raw range the monitor reports (100, 255, ...).
    private func update() { valueLabel.stringValue = "\(Int((slider.doubleValue / slider.maxValue * 100).rounded()))%" }
    @objc private func changed() { update(); onChange?(slider.doubleValue) }
}

private final class ModeChoice: NSObject {
    let displayID: CGDirectDisplayID; let mode: CGDisplayMode
    init(_ d: CGDirectDisplayID, _ m: CGDisplayMode) { displayID = d; mode = m }
}
private final class FlexChoice: NSObject {
    let displayID: CGDirectDisplayID; let w: Int; let h: Int
    init(_ d: CGDirectDisplayID, _ w: Int, _ h: Int) { displayID = d; self.w = w; self.h = h }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    let menu = NSMenu()
    private var brightnessRows: [String: SliderRow] = [:]
    private var refreshWork: DispatchWorkItem?
    private var wakePending = false
    private let manager = DisplayManager.shared
    private var loginItemEnabled = false
    private var loginItemCheckedAt = Date.distantPast

    private var showAllModes: Bool {
        get { UserDefaults.standard.bool(forKey: "showAllModes") }
        set { UserDefaults.standard.set(newValue, forKey: "showAllModes") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let icon = NSImage(systemSymbolName: "display", accessibilityDescription: "DisplayTune")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        menu.delegate = self
        statusItem.menu = menu
        manager.refresh()
        scheduleRefresh(afterWake: false)     // restores saved Extra HiDPI sessions / arrangement for displays already attached
        BrightnessKeys.shared.start()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemDidWake),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        for id in Array(manager.flexible.keys) { manager.stopFlexible(id) }
    }

    /// Display configuration changed / woke from sleep: re-enumerate (debounced) and re-apply software dimming.
    @objc private func screensChanged() { scheduleRefresh(afterWake: false) }
    @objc private func systemDidWake() { scheduleRefresh(afterWake: true) }

    private func scheduleRefresh(afterWake: Bool) {
        refreshWork?.cancel()
        wakePending = wakePending || afterWake
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.manager.refresh()
            // Re-create saved Extra HiDPI sessions first, then put the screens back where the user arranged them.
            self.manager.restoreFlexibleSessions {
                let wake = self.wakePending; self.wakePending = false
                self.manager.settleLayout(afterWake: wake)
            }
        }
        refreshWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: w)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild(menu) }

    func menuWillOpen(_ menu: NSMenu) {
        // Re-read the monitors (they may have been adjusted with their own buttons). Also re-probes displays
        // whose DDC previously failed, so enabling DDC/CI in the monitor's OSD is picked up on the next open.
        for d in manager.displays where d.ddc != nil {
            d.readHardwareBrightness { [weak self, weak d] ok in
                guard ok, let d, let v = d.hardwareBrightness else { return }
                self?.brightnessRows[d.key]?.setValue(Double(v))
            }
        }
    }

    /// Rebuilds the menu from the cached display list (no registry walk here — `refresh()` does that on display changes).
    func rebuild(_ menu: NSMenu) {
        autoreleasepool {
            menu.removeAllItems()
            brightnessRows.removeAll()

            if manager.displays.isEmpty {
                let item = NSMenuItem(title: "No external display found", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            for d in manager.displays { addSection(for: d, catalog: ModeCatalog(d.id), to: menu) }

            if menu.items.last?.isSeparatorItem != true { menu.addItem(.separator()) }
            let all = NSMenuItem(title: "Show all resolutions", action: #selector(toggleShowAll), keyEquivalent: "")
            all.target = self; all.state = showAllModes ? .on : .off
            menu.addItem(all)

            let keys = BrightnessKeys.shared
            if keys.enabled && !keys.isActive {
                let allow = NSMenuItem(title: "Brightness keys: allow Accessibility access…", action: #selector(allowAccessibility), keyEquivalent: "")
                allow.target = self; allow.state = .mixed
                menu.addItem(allow)
                let off = NSMenuItem(title: "Turn off brightness keys", action: #selector(toggleKeys), keyEquivalent: "")
                off.target = self
                menu.addItem(off)
            } else {
                let k = NSMenuItem(title: "Brightness keys (F1 / F2)", action: #selector(toggleKeys), keyEquivalent: "")
                k.target = self; k.state = keys.isActive ? .on : .off
                menu.addItem(k)
            }
            let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
            login.target = self; login.state = launchAtLoginEnabled ? .on : .off
            menu.addItem(login)
            let reset = NSMenuItem(title: "Reset software dimming", action: #selector(resetDimming), keyEquivalent: "")
            reset.target = self
            menu.addItem(reset)
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Quit DisplayTune", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        }
    }

    private func addSection(for d: ManagedDisplay, catalog liveCat: ModeCatalog, to menu: NSMenu) {
        menu.addItem(NSMenuItem.sectionHeader(title: d.name))
        let flex = manager.flexible[d.id]
        // While a flexible session mirrors the panel, the live catalog describes the virtual display: use the panel's own.
        let cat = (flex != nil ? manager.baseCatalog[d.id] : nil) ?? liveCat

        // Current mode line
        let modeText: String
        if let f = flex { modeText = "\(f.width) × \(f.height) HiDPI (flexible, renders \(f.width * 2) × \(f.height * 2))" }
        else if let m = liveCat.current { modeText = ModeOption(mode: m).title }
        else { modeText = "—" }
        let info = NSMenuItem(title: modeText, action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)

        // Hardware brightness (DDC) — only when the monitor has actually answered over DDC
        let bItem = NSMenuItem()
        if d.supportsDDC {
            let row = SliderRow(title: "Brightness", min: 0, max: Double(d.hardwareMax),
                                value: Double(d.hardwareBrightness ?? d.hardwareMax / 2))
            row.onChange = { v in d.setHardwareBrightness(Int(v.rounded())) }
            brightnessRows[d.key] = row
            bItem.view = row
        } else {
            bItem.view = SliderRow(title: "Brightness (DDC not available)", min: 0, max: 100, value: 0, enabled: false)
        }
        menu.addItem(bItem)

        // Software dimming
        let dimItem = NSMenuItem()
        let dimRow = SliderRow(title: "Software dim", min: 20, max: 100, value: d.softwareDim * 100)
        dimRow.onChange = { v in d.setSoftwareDim(v / 100) }
        dimItem.view = dimRow
        menu.addItem(dimItem)

        // High Resolution (HiDPI) toggle: same "looks like" size, 2x (HiDPI) <-> 1:1
        let hiItem = NSMenuItem(title: "High Resolution (HiDPI)", action: #selector(selectMode(_:)), keyEquivalent: "")
        hiItem.target = self
        if flex != nil {
            // Flexible HiDPI is a HiDPI session: toggling it off returns to the panel's normal mode.
            hiItem.state = .on
            hiItem.action = #selector(disableFlexible(_:))
            hiItem.representedObject = NSNumber(value: d.id)
        } else if let cur = cat.current, let other = cat.counterpart() {
            hiItem.state = cur.pixelWidth > cur.width ? .on : .off
            hiItem.representedObject = ModeChoice(d.id, other.mode)
        } else {
            hiItem.state = .off
            hiItem.action = nil          // no counterpart mode
            hiItem.isEnabled = false
        }
        menu.addItem(hiItem)

        // Resolution submenu
        let resItem = NSMenuItem(title: "Resolution", action: nil, keyEquivalent: "")
        let resMenu = NSMenu()
        for opt in cat.options(showAll: showAllModes) {
            let mi = NSMenuItem(title: opt.title, action: #selector(selectMode(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = ModeChoice(d.id, opt.mode)
            if flex == nil, let c = cat.current, opt.matches(c) { mi.state = .on }
            resMenu.addItem(mi)
        }
        resItem.submenu = resMenu
        menu.addItem(resItem)

        // Refresh rate submenu (only when the current resolution offers several)
        let rates = flex == nil ? cat.refreshOptions() : []
        if rates.count > 1 {
            let rItem = NSMenuItem(title: "Refresh rate", action: nil, keyEquivalent: "")
            let rMenu = NSMenu()
            for opt in rates {
                let mi = NSMenuItem(title: "\(Int(opt.mode.refreshRate.rounded())) Hz", action: #selector(selectMode(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = ModeChoice(d.id, opt.mode)
                if let c = cat.current, opt.matches(c) { mi.state = .on }
                rMenu.addItem(mi)
            }
            rItem.submenu = rMenu
            menu.addItem(rItem)
        }

        // Flexible HiDPI submenu
        let candidates = cat.flexibleCandidates()
        if !candidates.isEmpty || flex != nil {
            let fItem = NSMenuItem(title: "Extra HiDPI sizes (experimental)", action: nil, keyEquivalent: "")
            let fMenu = NSMenu()
            for c in candidates {
                let mi = NSMenuItem(title: "\(c.w) × \(c.h)  HiDPI", action: #selector(selectFlexible(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = FlexChoice(d.id, c.w, c.h)
                if let f = flex, f.width == c.w, f.height == c.h { mi.state = .on }
                fMenu.addItem(mi)
            }
            if flex != nil {
                fMenu.addItem(.separator())
                let off = NSMenuItem(title: "Turn off (back to normal)", action: #selector(disableFlexible(_:)), keyEquivalent: "")
                off.target = self
                off.representedObject = NSNumber(value: d.id)
                fMenu.addItem(off)
            }
            fItem.submenu = fMenu
            menu.addItem(fItem)
        }
        menu.addItem(.separator())
    }

    // MARK: Actions

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? ModeChoice else { return }
        manager.setSavedFlexible(nil, for: key(of: c.displayID))
        if manager.flexible[c.displayID] != nil {
            // Leave the flexible session first (un-mirror, drop the virtual display), then apply the panel mode.
            manager.stopFlexible(c.displayID)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.applyChoice(c) }
            return
        }
        applyChoice(c)
    }

    private func applyChoice(_ c: ModeChoice) {
        guard showAllModes else {
            if !manager.apply(c.mode, to: c.displayID) { alert("Could not change the resolution.") }
            return
        }
        // The extended list can contain modes the panel cannot show: try it for this session first and
        // only keep it (permanently) when confirmed, like System Settings does.
        let previous = CGDisplayCopyDisplayMode(c.displayID)
        guard manager.apply(c.mode, to: c.displayID, permanently: false) else { alert("Could not change the resolution."); return }
        if confirmKeep(seconds: 10, text: ModeOption(mode: c.mode).title) {
            manager.apply(c.mode, to: c.displayID)
        } else if let previous {
            manager.apply(previous, to: c.displayID)
        }
    }

    @objc private func selectFlexible(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? FlexChoice,
              let d = manager.displays.first(where: { $0.id == c.displayID }) else { return }
        let base = manager.baseCatalog[c.displayID] ?? ModeCatalog(c.displayID)   // before mirroring changes what CG reports
        manager.setSavedFlexible(nil, for: d.key)     // saved again only once the user confirms
        let layoutBefore = manager.captureLayout()    // macOS repositions screens when the virtual display appears
        manager.stopFlexible(c.displayID)
        let session = FlexibleHiDPI(physicalID: c.displayID, name: d.name, width: c.w, height: c.h)
        manager.flexible[c.displayID] = session
        manager.baseCatalog[c.displayID] = base
        session.start { [weak self] error in
            guard let self else { return }
            if let error {
                self.manager.stopFlexible(c.displayID)
                self.alert("Flexible HiDPI failed: \(error)")
                return
            }
            self.manager.restoreLayout(layoutBefore)
            // Like System Settings: revert automatically unless the user confirms.
            if self.confirmKeep(seconds: 15, text: "\(c.w) × \(c.h) HiDPI") {
                self.manager.setSavedFlexible((c.w, c.h), for: d.key)   // re-created automatically after a replug
            } else {
                self.manager.stopFlexible(c.displayID)
            }
        }
    }

    @objc private func disableFlexible(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? NSNumber else { return }
        manager.setSavedFlexible(nil, for: key(of: n.uint32Value))
        manager.stopFlexible(n.uint32Value)
    }

    @objc private func toggleShowAll() { showAllModes.toggle() }

    @objc private func toggleKeys() {
        let keys = BrightnessKeys.shared
        if keys.enabled { keys.enabled = false; keys.stop() } else { keys.enabled = true; keys.start() }
    }

    @objc private func allowAccessibility() {
        BrightnessKeys.shared.requestAccessibility()
        BrightnessKeys.openAccessibilitySettings()
        BrightnessKeys.shared.start()   // keeps polling until the permission is granted
    }

    @objc private func resetDimming() {
        for d in manager.displays { d.setSoftwareDim(1.0) }
        CGDisplayRestoreColorSyncSettings()
    }

    /// `SMAppService.status` talks to a system service over XPC and leaks a connection per call, so it is cached
    /// (re-read at most once a minute, in case it was changed in System Settings).
    private var launchAtLoginEnabled: Bool {
        if Date().timeIntervalSince(loginItemCheckedAt) > 60 { refreshLoginItemState() }
        return loginItemEnabled
    }

    private func refreshLoginItemState() {
        loginItemEnabled = SMAppService.mainApp.status == .enabled
        loginItemCheckedAt = Date()
    }

    @objc private func toggleLogin() {
        do {
            if loginItemEnabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { alert("Launch at Login: \(error.localizedDescription)") }
        refreshLoginItemState()
    }

    // MARK: Helpers

    private func key(of id: CGDirectDisplayID) -> String { manager.displays.first { $0.id == id }?.key ?? "" }

    private func alert(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = "DisplayTune"; a.informativeText = text; a.runModal()
    }

    /// Modal "Keep / Revert" prompt that reverts on its own when the timer runs out.
    private func confirmKeep(seconds: Int, text: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Keep \(text)?"
        a.addButton(withTitle: "Keep")
        a.addButton(withTitle: "Revert")
        var remaining = seconds
        a.informativeText = "Reverting automatically in \(remaining) s if you do nothing."
        let timer = Timer(timeInterval: 1, repeats: true) { t in
            remaining -= 1
            a.informativeText = "Reverting automatically in \(remaining) s if you do nothing."
            if remaining <= 0 { t.invalidate(); NSApp.abortModal() }
        }
        RunLoop.main.add(timer, forMode: .common)
        let r = a.runModal()
        timer.invalidate()
        return r == .alertFirstButtonReturn
    }
}
