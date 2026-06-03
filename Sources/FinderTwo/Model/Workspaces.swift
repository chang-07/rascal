import AppKit

/// A named saved state of a window: its tabs + pane layout. Distinct from
/// `session` (auto-restored on quit) — workspaces are user-named and explicit.
struct Workspace: Codable {
    let name: String
    /// One entry per pane. Each is [[urls: [String], active: Int]]-shaped JSON
    /// matching what BrowserWindowController.sessionSnapshot() returns.
    let snapshotJSON: Data
    let savedAt: Date
}

enum WorkspaceStore {
    private static let key = "FinderTwo.workspaces.v1"

    /// Decode element-by-element so one corrupt/incompatible entry can't wipe
    /// EVERY saved workspace (the next save would otherwise persist from an empty base).
    private struct LossyWorkspace: Decodable {
        let value: Workspace?
        init(from decoder: Decoder) throws { value = try? Workspace(from: decoder) }
    }
    static func all() -> [Workspace] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        let arr = ((try? JSONDecoder().decode([LossyWorkspace].self, from: data)) ?? []).compactMap { $0.value }
        return arr.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func save(name: String, snapshot: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot) else { return }
        var list = all().filter { $0.name != name }
        list.append(Workspace(name: name, snapshotJSON: data, savedAt: Date()))
        if let enc = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(enc, forKey: key)
        }
    }

    static func delete(name: String) {
        let list = all().filter { $0.name != name }
        if let enc = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(enc, forKey: key)
        }
    }

    static func snapshot(forName name: String) -> [String: Any]? {
        guard let ws = all().first(where: { $0.name == name }),
              let obj = try? JSONSerialization.jsonObject(with: ws.snapshotJSON) as? [String: Any] else {
            return nil
        }
        return obj
    }
}

enum WorkspaceController {
    static func promptSave(in wc: BrowserWindowController) {
        guard let win = wc.window else { return }
        let alert = NSAlert()
        alert.messageText = "Save Workspace"
        alert.informativeText = "Give this window a name. Reopening the workspace restores its tabs and pane layout."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
        field.placeholderString = "e.g. Project Atlas"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: win) { resp in
            guard resp == .alertFirstButtonReturn,
                  !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            WorkspaceStore.save(name: field.stringValue, snapshot: wc.sessionSnapshot())
        }
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
    }

    static func promptOpen(in wc: BrowserWindowController) {
        guard let win = wc.window else { return }
        let workspaces = WorkspaceStore.all()
        guard !workspaces.isEmpty else {
            NSSound.beep()
            let a = NSAlert()
            a.messageText = "No saved workspaces"
            a.informativeText = "Use File → Save Workspace… to capture this window."
            a.beginSheetModal(for: win, completionHandler: { _ in })
            return
        }
        let menu = NSMenu(title: "Workspaces")
        for ws in workspaces {
            let item = NSMenuItem(title: ws.name, action: #selector(WorkspaceMenuTarget.activate(_:)), keyEquivalent: "")
            item.representedObject = WorkspaceMenuTarget.Payload(name: ws.name, wc: wc)
            item.target = WorkspaceMenuTarget.shared
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem.separator())
        let delete = NSMenuItem(title: "Delete a Workspace…", action: #selector(WorkspaceMenuTarget.promptDelete(_:)), keyEquivalent: "")
        delete.representedObject = WorkspaceMenuTarget.Payload(name: "", wc: wc)
        delete.target = WorkspaceMenuTarget.shared
        menu.addItem(delete)
        // Pop near the toolbar
        if let view = wc.window?.contentView {
            let p = NSPoint(x: 20, y: view.bounds.height - 20)
            menu.popUp(positioning: nil, at: p, in: view)
        }
    }
}

final class WorkspaceMenuTarget: NSObject {
    static let shared = WorkspaceMenuTarget()
    struct Payload { let name: String; let wc: BrowserWindowController }

    @objc func activate(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? Payload,
              let snap = WorkspaceStore.snapshot(forName: p.name) else { return }
        p.wc.restoreFromSnapshot(snap)
    }

    @objc func promptDelete(_ sender: NSMenuItem) {
        let workspaces = WorkspaceStore.all()
        guard !workspaces.isEmpty else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete a Workspace"
        alert.informativeText = "Select the workspace you want to permanently delete."
        let popUp = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
        for ws in workspaces {
            popUp.addItem(withTitle: ws.name)
        }
        alert.accessoryView = popUp
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard let p = sender.representedObject as? Payload, let win = p.wc.window else { return }
        alert.beginSheetModal(for: win) { resp in
            guard resp == .alertFirstButtonReturn,
                  let selectedName = popUp.selectedItem?.title else { return }
            WorkspaceStore.delete(name: selectedName)
        }
    }
}
