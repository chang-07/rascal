import AppKit
import Foundation
import JavaScriptCore

/// Plugin file format (`.ftplugin/`):
///
///   manifest.json
///   main.js
///
/// Example `manifest.json`:
/// {
///   "id": "dev.example.line-count",
///   "name": "Line Count",
///   "version": "1.0",
///   "actions": [
///     { "id": "line-count.count", "title": "Count Lines" }
///   ]
/// }
///
/// Example `main.js`:
/// ```
/// ft.onAction('line-count.count', function (urls) {
///   var lines = 0;
///   urls.forEach(function (u) {
///     lines += (ft.readFile(u) || '').split('\n').length;
///   });
///   ft.notify('Lines: ' + lines);
/// });
/// ```
///
/// Plugins live in `~/Library/Application Support/FinderTwo/Plugins/*.ftplugin`.
/// Each plugin runs in its own JSContext; the host exposes a small `ft` object.
final class PluginHost {

    static let shared = PluginHost()

    struct PluginManifest: Decodable {
        let id: String
        let name: String
        let version: String?
        let actions: [PluginAction]?
    }
    struct PluginAction: Decodable {
        let id: String
        let title: String
    }

    /// Reference-type holder for a plugin's action handlers. `ft.onAction`
    /// writes into this live during script evaluation; `fireAction` reads
    /// from it later. Using a class (not a JS snapshot) means handlers
    /// registered after bridge setup are actually found.
    final class HandlerBox {
        var map: [String: JSValue] = [:]
    }

    struct LoadedPlugin {
        let manifest: PluginManifest
        let context: JSContext
        let directory: URL
        let handlers: HandlerBox
    }

    private(set) var plugins: [LoadedPlugin] = []

    /// Why a `.ftplugin` bundle failed to load on the last `loadAll()`. Surfaced
    /// in the Reload-Plugins summary so a broken plugin isn't a silent no-op.
    struct LoadFailure { let bundle: String; let reason: String }
    private(set) var failures: [LoadFailure] = []

    static var pluginsDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Application Support/FinderTwo/Plugins")
    }

    /// Load all plugins from the standard directory. Idempotent — re-running
    /// reloads from disk.
    func loadAll() {
        plugins = []
        failures = []
        let dir = PluginHost.pluginsDirectory
        guard let kids = try? FileManager.default.contentsOfDirectory(at: dir,
            includingPropertiesForKeys: nil) else { return }
        for k in kids where k.pathExtension == "ftplugin" {
            loadPlugin(at: k)
        }
    }

    /// Test hook: load a single plugin bundle from an arbitrary directory.
    func testLoad(at dir: URL) { loadPlugin(at: dir) }

    private func recordFailure(_ bundle: String, _ reason: String) {
        failures.append(LoadFailure(bundle: bundle, reason: reason))
        NSLog("FT plugin load failed [%@]: %@", bundle, reason)
    }

    private func loadPlugin(at dir: URL) {
        let bundle = dir.lastPathComponent
        let manifestURL = dir.appendingPathComponent("manifest.json")
        let mainURL = dir.appendingPathComponent("main.js")

        guard let data = try? Data(contentsOf: manifestURL) else {
            recordFailure(bundle, "missing or unreadable manifest.json"); return
        }
        let manifest: PluginManifest
        do {
            manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch {
            recordFailure(bundle, "invalid manifest.json — \(error.localizedDescription)"); return
        }
        guard let scriptData = try? Data(contentsOf: mainURL),
              let script = String(data: scriptData, encoding: .utf8) else {
            recordFailure(manifest.id, "missing or unreadable main.js"); return
        }
        guard !plugins.contains(where: { $0.manifest.id == manifest.id }) else {
            recordFailure(manifest.id, "duplicate plugin id — already loaded from another bundle"); return
        }
        guard let ctx = JSContext() else {
            recordFailure(manifest.id, "could not create a JavaScript context"); return
        }
        let handlers = HandlerBox()
        installBridge(ctx, plugin: manifest, handlers: handlers)
        ctx.evaluateScript(script)
        if let ex = ctx.exception {
            recordFailure(manifest.id, "script error — \(ex)"); return
        }
        plugins.append(LoadedPlugin(manifest: manifest, context: ctx,
                                    directory: dir, handlers: handlers))
        // Register declared actions
        for a in manifest.actions ?? [] {
            ActionRegistry.registerPluginAction(id: a.id, title: a.title) { [weak self] wc in
                self?.fireAction(id: a.id, wc: wc)
            }
        }
    }

    /// Build the `ft` bridge object exposed to JS.
    private func installBridge(_ ctx: JSContext, plugin: PluginManifest, handlers: HandlerBox) {
        let ft = JSValue(newObjectIn: ctx)
        ctx.globalObject.setValue(ft, forProperty: "ft")

        // ft.onAction("id", function(urls) { ... }) — writes into the live
        // HandlerBox so handlers registered during evaluateScript are kept.
        let onAction: @convention(block) (String, JSValue) -> Void = { [weak handlers] id, fn in
            handlers?.map[id] = fn
        }
        ft?.setValue(onAction, forProperty: "onAction")

        // ft.notify("text") — shows a transient message in the active window's
        // status bar (no notification-center permission needed; reliable on
        // modern macOS where NSUserNotification silently no-ops).
        let notify: @convention(block) (String) -> Void = { msg in
            DispatchQueue.main.async {
                if let pane = (NSApp.delegate as? AppDelegate)?.currentBrowserWC()?.testActivePane {
                    pane.flashStatus("\(plugin.name): \(msg)")
                } else {
                    NSLog("FT plugin '%@': %@", plugin.name, msg)
                }
            }
        }
        ft?.setValue(notify, forProperty: "notify")

        // ft.readFile(path) -> string
        let readFile: @convention(block) (String) -> String? = { path in
            try? String(contentsOfFile: path, encoding: .utf8)
        }
        ft?.setValue(readFile, forProperty: "readFile")

        // ft.writeFile(path, content)
        let writeFile: @convention(block) (String, String) -> Bool = { path, content in
            (try? content.data(using: .utf8)?.write(to: URL(fileURLWithPath: path))) != nil
        }
        ft?.setValue(writeFile, forProperty: "writeFile")

        // ft.run(["cmd", "arg", ...]) -> stdout. An absolute path runs directly;
        // a bare command name is resolved through PATH via /usr/bin/env, so
        // ft.run(["ls", "-la"]) works like you'd expect.
        let run: @convention(block) ([String]) -> String? = { args in
            guard let cmd = args.first, !cmd.isEmpty else { return nil }
            let p = Process()
            if cmd.hasPrefix("/") {
                p.executableURL = URL(fileURLWithPath: cmd)
                p.arguments = Array(args.dropFirst())
            } else {
                p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                p.arguments = args   // env resolves cmd against PATH
            }
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice  // unused; nullDevice avoids a full-pipe deadlock
            do { try p.run() } catch {
                NSLog("FT plugin '%@' ft.run failed: %@", plugin.name, error.localizedDescription)
                return nil
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(data: data, encoding: .utf8)
        }
        ft?.setValue(run, forProperty: "run")

        // ft.log("text") — write to the system log for debugging a plugin.
        let log: @convention(block) (String) -> Void = { msg in
            NSLog("FT plugin '%@' log: %@", plugin.name, msg)
        }
        ft?.setValue(log, forProperty: "log")

        // ft.currentURL() -> string
        let currentURL: @convention(block) () -> String? = {
            (NSApp.delegate as? AppDelegate)?.currentBrowserWC()?.testActivePane?.currentURL.path
        }
        ft?.setValue(currentURL, forProperty: "currentURL")

        // ft.selectedURLs() -> [string]
        let selectedURLs: @convention(block) () -> [String] = {
            (NSApp.delegate as? AppDelegate)?.currentBrowserWC()?
                .testActivePane?.selectedURLs().map { $0.path } ?? []
        }
        ft?.setValue(selectedURLs, forProperty: "selectedURLs")

        ctx.virtualMachine.addManagedReference(ft, withOwner: ctx.globalObject)
    }

    /// Invoke a registered plugin action by id, calling the JS handler from the
    /// owning plugin's live HandlerBox.
    func fireAction(id: String, wc: BrowserWindowController) {
        for p in plugins {
            guard let handler = p.handlers.map[id], !handler.isUndefined else { continue }
            let urls = wc.testActivePane?.selectedURLs().map { $0.path } ?? []
            p.context.exception = nil   // clear any stale exception before the call
            handler.call(withArguments: [urls])
            // A handler that throws used to fail silently. Surface it in the
            // status bar and the log, and clear it so it can't leak into the
            // next plugin call on this context.
            if let ex = p.context.exception {
                p.context.exception = nil
                NSLog("FT plugin action '%@' threw: %@", id, "\(ex)")
                wc.testActivePane?.flashStatus("\(p.manifest.name): \(ex)")
            }
            return
        }
    }

    // MARK: Example plugin

    /// Write a small, working example plugin into the Plugins folder so users
    /// have a real bundle to learn from. Returns the bundle URL, or nil if it
    /// couldn't be written. Does not overwrite an existing copy.
    @discardableResult
    static func installExample() -> URL? {
        let bundle = pluginsDirectory.appendingPathComponent("word-count.ftplugin")
        let fm = FileManager.default
        guard !fm.fileExists(atPath: bundle.path) else { return bundle }
        do {
            try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
            try exampleManifest.write(to: bundle.appendingPathComponent("manifest.json"),
                                      atomically: true, encoding: .utf8)
            try exampleScript.write(to: bundle.appendingPathComponent("main.js"),
                                    atomically: true, encoding: .utf8)
            return bundle
        } catch {
            NSLog("FT: failed to install example plugin: %@", error.localizedDescription)
            return nil
        }
    }

    private static let exampleManifest = """
    {
      "id": "dev.rascal.word-count",
      "name": "Word Count",
      "version": "1.0",
      "actions": [
        { "id": "word-count.count", "title": "Count Words in Selection" }
      ]
    }
    """

    private static let exampleScript = """
    // Word Count — a starter Rascal plugin.
    // Select one or more text files, then run "Count Words in Selection"
    // from the Command Palette (⌘⇧P).
    //
    // The `ft` bridge gives you: onAction, notify, log, readFile, writeFile,
    // run, currentURL, selectedURLs.

    ft.onAction('word-count.count', function (urls) {
      if (!urls || urls.length === 0) {
        ft.notify('Select a file first.');
        return;
      }
      var files = 0, words = 0, lines = 0;
      urls.forEach(function (path) {
        var text = ft.readFile(path);
        if (text === null) return;        // skip unreadable/binary files
        files += 1;
        lines += text.split('\\n').length;
        var trimmed = text.trim();
        if (trimmed.length) words += trimmed.split(/\\s+/).length;
      });
      ft.notify(words + ' words, ' + lines + ' lines across ' + files + ' file(s)');
    });
    """
}

extension ActionRegistry {
    /// Allow plugin actions to be added at runtime. Not part of the static
    /// `all` array; tracked in a side list, queried by `action(id:)`.
    private static var pluginActions: [Action] = []

    static func registerPluginAction(id: String, title: String,
                                     perform: @escaping (BrowserWindowController) -> Void) {
        let a = Action(id: id, title: title, category: .file, icon: nil,
                       defaultShortcut: nil, perform: perform)
        pluginActions.removeAll { $0.id == id }
        pluginActions.append(a)
    }

    /// Action lookup that also checks plugin actions.
    static func allIncludingPlugins() -> [Action] { all + pluginActions }
}
