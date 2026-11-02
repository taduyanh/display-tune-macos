import Cocoa

/// Command line access to the same features, handy for scripts / Shortcuts / testing:
///   DisplayTune --cli list
///   DisplayTune --cli brightness <index> [0-100]
///   DisplayTune --cli mode <index> <WxH> [hidpi|lodpi] [hz]
///   DisplayTune --cli keystep <index> up|down [fine] [hold]
///   DisplayTune --cli menu | osd-preview <file.png> [level]
/// Exit status: 0 = ok, 1 = the operation failed, 2 = bad usage.
enum CLI {
    static func run(_ args: [String]) -> Int32 {
        NSApplication.shared.setActivationPolicy(.accessory)
        let m = DisplayManager.shared
        m.refresh(applyingDim: false)   // a short-lived process must not touch gamma: it would reset the running app's dimming on exit
        guard let cmd = args.first else { return usage() }

        func display(_ arg: String?) -> ManagedDisplay? {
            guard let arg, let n = Int(arg), m.displays.indices.contains(n) else { printError("invalid display index (see: list)"); return nil }
            return m.displays[n]
        }

        switch cmd {
        case "list":
            print("DDC supported by this Mac: \(DDC.isSupported)")
            for (i, d) in m.displays.enumerated() {
                let cat = ModeCatalog(d.id)
                print("[\(i)] \(d.name)  id=\(d.id)  key=\(d.key)")
                if d.ddc == nil { print("    brightness (DDC): not available") }
                else if readBrightness(d) { print("    brightness (DDC): \(d.hardwareBrightness ?? 0) / \(d.hardwareMax)") }
                else { print("    brightness (DDC): monitor does not answer (enable DDC/CI in its OSD?)") }
                print("    software dim: \(Int(d.softwareDim * 100))%")
                if let c = cat.current { print("    current: \(ModeOption(mode: c).title)  (pixels \(c.pixelWidth) × \(c.pixelHeight))") }
                if let n = cat.native { print("    native panel: \(n.w) × \(n.h)") }
                print("    modes:")
                for o in cat.options(showAll: false) { print("      \(o.title)") }
                print("    refresh rates at current resolution: " + cat.refreshOptions().map { "\(Int($0.mode.refreshRate.rounded()))Hz" }.joined(separator: ", "))
                let f = cat.flexibleCandidates()
                if !f.isEmpty { print("    extra HiDPI (flexible, experimental): " + f.map { "\($0.w)x\($0.h)" }.joined(separator: ", ")) }
            }
            return 0

        case "brightness":
            guard let d = display(args.dropFirst().first) else { return 2 }
            guard d.ddc != nil, readBrightness(d) else { return fail("DDC not available / not answering for \(d.name)") }
            guard args.count >= 3 else { print(d.hardwareBrightness ?? 0); return 0 }
            guard let v = Int(args[2].trimmingCharacters(in: CharacterSet(charactersIn: "% "))) else {
                return fail("invalid brightness value '\(args[2])' (expected a number)", code: 2)
            }
            let target = max(0, min(d.hardwareMax, v))
            d.setHardwareBrightness(target)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))   // let the queued DDC write go out
            print("set brightness to \(target)")
            return 0

        case "mode":
            guard args.count >= 3, let d = display(args[1]) else { return usage() }
            let parts = args[2].lowercased().split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2 else { return usage() }
            let rest = args.dropFirst(3).map { $0.lowercased() }
            let wantHiDPI: Bool? = rest.contains("hidpi") ? true : (rest.contains("lodpi") ? false : nil)
            let hz = rest.compactMap { Double($0) }.first
            var matches = ModeCatalog(d.id).options(showAll: true).filter { $0.mode.width == parts[0] && $0.mode.height == parts[1] }
            if let h = wantHiDPI { matches = matches.filter { $0.isHiDPI == h } }
            if let hz { matches = matches.filter { abs($0.mode.refreshRate - hz) < 0.5 } }
            guard let pick = matches.sorted(by: { $0.mode.refreshRate > $1.mode.refreshRate }).first else { return fail("no matching mode") }
            guard m.apply(pick.mode, to: d.id) else { return fail("failed to apply: \(pick.title)") }
            print("applied: \(pick.title)")
            return 0

        case "keystep":   // simulate one brightness-key press on a display
            guard args.count >= 3, args[2] == "up" || args[2] == "down", let d = display(args[1]) else { return usage() }
            let screen = NSScreen.screens.first { $0.displayID == d.id }
            BrightnessKeys.shared.step(display: d, screen: screen, up: args[2] == "up", fine: args.contains("fine"))
            RunLoop.main.run(until: Date().addingTimeInterval(args.contains("hold") ? 3.0 : 0.8))
            print("brightness now: \(d.hardwareBrightness.map(String.init) ?? "n/a") (software dim \(Int(d.softwareDim * 100))%)")
            return 0

        case "osd-preview":   // offscreen render of the on-screen indicator
            guard args.count >= 2 else { return usage() }
            let level = args.count >= 3 ? (Double(args[2]) ?? 0.5) : 0.5
            guard let data = BrightnessOSD.shared.previewPNG(level: level) else { return fail("render failed") }
            do { try data.write(to: URL(fileURLWithPath: args[1])) } catch { return fail("could not write \(args[1]): \(error.localizedDescription)") }
            print("wrote \(args[1])")
            return 0

        case "bench":   // bench [n]: rebuild the menu n times (what opening the menu does) and report time + memory
            let n = args.count >= 2 ? (Int(args[1]) ?? 100) : 100
            let delegate = AppDelegate()
            func footprintMB() -> Double {
                var info = task_vm_info_data_t()
                var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
                let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
                return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1048576 : -1
            }
            let start = footprintMB(), t0 = Date()
            for _ in 0..<n { delegate.rebuild(delegate.menu); RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }   // like the real app: the run loop turns between menu opens
            let ms = Date().timeIntervalSince(t0) * 1000
            print(String(format: "%d menu rebuilds: %.0f ms total (%.1f ms each), footprint %.1f -> %.1f MB", n, ms, ms / Double(n), start, footprintMB()))
            return 0

        case "menu":   // build the status-bar menu and print its structure (no UI shown)
            let delegate = AppDelegate()
            delegate.rebuild(delegate.menu)
            func dump(_ menu: NSMenu, _ indent: String) {
                for item in menu.items {
                    if item.isSeparatorItem { print("\(indent)────"); continue }
                    let kind = item.view != nil ? "[slider] " : (item.isSectionHeader ? "[header] " : "")
                    print("\(indent)\(item.state == .on ? "✓ " : "")\(kind)\(item.title)\(item.isEnabled ? "" : "  (disabled)")")
                    if let sub = item.submenu { dump(sub, indent + "    ") }
                }
            }
            dump(delegate.menu, "")
            return 0

        default: return usage()
        }
    }

    /// Reads the brightness synchronously (pumping the run loop, since results are delivered on the main queue).
    private static func readBrightness(_ d: ManagedDisplay) -> Bool {
        var result: Bool?
        d.readHardwareBrightness { result = $0 }
        let deadline = Date().addingTimeInterval(5)
        while result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return result ?? false
    }

    private static func printError(_ s: String) { FileHandle.standardError.write(Data("error: \(s)\n".utf8)) }
    private static func fail(_ s: String, code: Int32 = 1) -> Int32 { printError(s); return code }

    private static func usage() -> Int32 {
        print("""
        Usage: DisplayTune --cli <command>
          list
          brightness <display#> [0-100]
          mode <display#> <WxH> [hidpi|lodpi] [hz]
          keystep <display#> up|down [fine] [hold]
          menu
          bench [n]
          osd-preview <file.png> [level 0-1]
        """)
        return 2
    }
}
