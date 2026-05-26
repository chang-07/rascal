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

    struct LoadedPlugin {
        let manifest: PluginManifest
        let context: JSContext
        let directory: URL
    }

    private(set) var plugins: [LoadedPlugin] = []

    static var pluginsDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Application Support/FinderTwo/Plugins")
    }

    /// Load all plugins from the standard directory. Idempotent — re-running
    /// reloads from disk.
    func loadAll() {
        plugins = []
        let dir = PluginHost.pluginsDirectory
        guard let kids = try? FileManager.default.contentsOfDirectory(at: dir,
            includingPropertiesForKeys: nil) else { return }
        for k in kids where k.pathExtension == "ftplugin" {
            loadPlugin(at: k)
        }
    }

    private func loadPlugin(at dir: URL) {
        let manifestURL = dir.appendingPathComponent("manifest.json")
        let mainURL = dir.appendingPathComponent("main.js")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data),
              let scriptData = try? Data(contentsOf: mainURL),
              let script = String(data: scriptData, encoding: .utf8) else { return }
        guard let ctx = JSContext() else { return }
        installBridge(ctx, plugin: manifest)
        ctx.evaluateScript(script)
        if ctx.exception != nil {
            NSLog("FT plugin '\(manifest.id)' error: \(String(describing: ctx.exception))")
            return
        }
        plugins.append(LoadedPlugin(manifest: manifest, context: ctx, directory: dir))
        // Register declared actions
        for a in manifest.actions ?? [] {
            ActionRegistry.registerPluginAction(id: a.id, title: a.title) { [weak self] wc in
                self?.fireAction(id: a.id, wc: wc)
            }
        }
    }

    /// Build the `ft` bridge object exposed to JS.
    private func installBridge(_ ctx: JSContext, plugin: PluginManifest) {
        // Storage for action handlers — closure-keyed by action id.
        var handlers: [String: JSValue] = [:]
        let ft = JSValue(newObjectIn: ctx)
        ctx.globalObject.setValue(ft, forProperty: "ft")

        // ft.onAction("id", function(urls) { ... })
        let onAction: @convention(block) (String, JSValue) -> Void = { id, fn in
            handlers[id] = fn
        }
        ft?.setValue(onAction, forProperty: "onAction")
        ctx.evaluateScript("") // ensure ft exists

        // ft.notify("text") — shows a transient banner via system notification.
        let notify: @convention(block) (String) -> Void = { msg in
            DispatchQueue.main.async {
                let n = NSUserNotification()
                n.title = plugin.name
                n.informativeText = msg
                NSUserNotificationCenter.default.deliver(n)
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

        // ft.run(["arg", ...]) -> stdout
        let run: @convention(block) ([String]) -> String? = { args in
            guard !args.isEmpty else { return nil }
            let p = Process()
            p.launchPath = args[0]
            p.arguments = Array(args.dropFirst())
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            do { try p.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(data: data, encoding: .utf8)
        }
        ft?.setValue(run, forProperty: "run")

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

        // Store handlers reference back on the context for `fireAction`.
        ctx.virtualMachine.addManagedReference(ft, withOwner: ctx.globalObject)
        ctx.setObject(handlers, forKeyedSubscript: "__ftHandlers" as NSString)
    }

    /// Invoke a registered plugin action.
    func fireAction(id: String, wc: BrowserWindowController) {
        for p in plugins {
            guard let handlers = p.context.objectForKeyedSubscript("__ftHandlers") else { continue }
            guard let handler = handlers.objectForKeyedSubscript(id), !handler.isUndefined else { continue }
            let urls = wc.testActivePane?.selectedURLs().map { $0.path } ?? []
            handler.call(withArguments: [urls])
            return
        }
    }
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
