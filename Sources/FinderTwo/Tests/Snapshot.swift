import AppKit

/// Off-screen visual capture for headless verification.
///
/// Headless runs (`FT_HEADLESS_TESTING=1`) park windows thousands of points off
/// every display, but AppKit still lays them out and the WindowServer still
/// composites them — so we can grab a pixel-exact PNG of any of our own windows
/// with `CGWindowListCreateImage` without anything ever appearing on screen and
/// without Screen-Recording permission.
///
/// Two entry points:
///
///   • `FT_SNAPSHOT_DIR=<dir>` — while `smoketest.sh` runs, the TestRunner
///     calls `Snapshot.take(win, "name")` at interesting states and PNGs land
///     in <dir>. Unset ⇒ no-op, so the normal test run is unaffected.
///
///   • `FT_SNAPSHOT=<dir> [FT_SNAPSHOT_PATH=<folder>] [FT_SNAPSHOT_THEMES=a,b]`
///     — standalone: open a real browser window at <folder> (default: cwd),
///     capture it under each theme, capture the Settings window, exit. This is
///     what `./snapshot.sh` drives. Use it to eyeball any UI change without a
///     second monitor.
@MainActor
enum Snapshot {
    static var dir: URL? {
        guard let p = ProcessInfo.processInfo.environment["FT_SNAPSHOT_DIR"], !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p)
    }

    /// Capture `win` to `<FT_SNAPSHOT_DIR>/<name>.png`. No-op when unset.
    @discardableResult
    static func take(_ win: NSWindow?, _ name: String) -> URL? {
        guard let dir, let win else { return nil }
        return write(win, to: dir.appendingPathComponent("\(name).png"))
    }

    /// Unconditional capture to an explicit file.
    @discardableResult
    static func write(_ win: NSWindow, to url: URL) -> URL? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        win.contentView?.layoutSubtreeIfNeeded()
        win.displayIfNeeded()
        // Let one turn of the run loop go by so CA commits the latest layer tree
        // before the WindowServer is asked for the pixels.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
        guard let rep = grab(win),
              let data = rep.representation(using: .png, properties: [:]) else {
            NSLog("Snapshot: could not capture window \(win.title) for \(url.lastPathComponent)")
            return nil
        }
        do { try data.write(to: url) } catch { NSLog("Snapshot: write failed \(error)"); return nil }
        print("  📸 \(url.path)")
        return url
    }

    private static func grab(_ win: NSWindow) -> NSBitmapImageRep? {
        if win.windowNumber > 0,
           let cg = CGWindowListCreateImage(.null, [.optionIncludingWindow],
                                            CGWindowID(win.windowNumber), [.bestResolution, .boundsIgnoreFraming]) {
            return NSBitmapImageRep(cgImage: cg)
        }
        // Fallback (window not yet registered with the server): cacheDisplay.
        guard let v = win.contentView, v.bounds.width > 1, v.bounds.height > 1,
              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        return rep
    }

    // MARK: - standalone mode

    static func runStandalone(outDir: String, appDelegate: AppDelegate) {
        let env = ProcessInfo.processInfo.environment
        let out = URL(fileURLWithPath: outDir)
        let path = env["FT_SNAPSHOT_PATH"] ?? FileManager.default.currentDirectoryPath
        let themes = (env["FT_SNAPSHOT_THEMES"] ?? "rascal-light,rascal-dark")
            .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let size = NSSize(width: Double(env["FT_SNAPSHOT_W"] ?? "") ?? 1200,
                          height: Double(env["FT_SNAPSHOT_H"] ?? "") ?? 800)

        let wc = BrowserWindowController(rootURL: URL(fileURLWithPath: path))
        guard let win = wc.window else { print("Snapshot: no window"); exit(2) }
        win.setContentSize(size)
        park(win)
        spin(1.5)   // directory load + first layout

        let originalTheme = ThemeManager.shared.current.id
        for id in themes {
            if ThemeManager.shared.available.contains(where: { $0.id == id }) {
                ThemeManager.shared.setTheme(id: id)
                spin(0.4)
                write(win, to: out.appendingPathComponent("browser-\(id).png"))
            } else {
                print("Snapshot: unknown theme '\(id)' — have \(ThemeManager.shared.available.map(\.id))")
            }
        }
        ThemeManager.shared.setTheme(id: originalTheme)

        // Settings window: build it directly (SettingsController.show() would
        // center it on-screen and activate the app).
        let settings = SettingsController()
        if let sw = settings.window {
            park(sw)
            for section in SettingsController.Section.allCases {
                settings.select(section)
                spin(0.3)
                write(sw, to: out.appendingPathComponent("settings-\(section.rawValue).png"))
            }
            sw.orderOut(nil)
        }
        win.orderOut(nil)
        exit(0)
    }

    private static func park(_ w: NSWindow) {
        w.setFrameOrigin(NSPoint(x: -60000, y: -60000))
        w.makeKeyAndOrderFront(nil)
        w.setFrameOrigin(NSPoint(x: -60000, y: -60000))
    }
    private static func spin(_ s: TimeInterval) { RunLoop.current.run(until: Date(timeIntervalSinceNow: s)) }
}
