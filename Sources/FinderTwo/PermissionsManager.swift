import AppKit
import Security

/// Centralizes FinderTwo's "ask once, remember forever, reach everything"
/// permission model.
///
/// The *persistence* half of that promise depends on a STABLE code signature
/// (see `setup-signing.sh`). macOS keys every privacy grant to the app's
/// signing identity (its Designated Requirement); ad-hoc signing mints a new
/// identity each build, so macOS forgets the grant and re-asks every launch.
/// With a stable identity the grant sticks across rebuilds and reinstalls.
///
/// The *reach everything* half is Full Disk Access: a single System Settings
/// toggle that lets the app read every file with no per-folder prompts. We
/// can't grant it programmatically (only the user can, in System Settings), but
/// we can deep-link there, detect when it's on, and never nag more than once.
enum PermissionsManager {

    // Bump the suffix to re-show onboarding after a change that warrants it.
    private static let onboardedKey = "FinderTwo.permissions.onboarded.v1"

    /// Whether the one-time onboarding has already run. Once true we never
    /// auto-present again — the user asked to be bothered at most once.
    static var hasOnboarded: Bool {
        get { UserDefaults.standard.bool(forKey: onboardedKey) }
        set { UserDefaults.standard.set(newValue, forKey: onboardedKey) }
    }

    /// True when the app already has Full Disk Access.
    ///
    /// Probe a path that is readable ONLY with FDA — the TCC database itself —
    /// by actually attempting to open it. `access()`/`isReadableFile` only
    /// check POSIX bits and would lie here, so we open a file handle: TCC
    /// denies the `open()` with EPERM, which surfaces as a nil handle. This
    /// never triggers a prompt (FDA is grant-only, never promptable).
    /// CACHED: the file list reads this per row (tag colors, icons) on every
    /// reload and scroll, and the raw probe is 3 syscalls (open/read/close of
    /// TCC.db). The result only changes when the user toggles FDA in System
    /// Settings, so we memoize it and re-probe on app activation (AppDelegate).
    private static let fdaLock = NSLock()
    private static var fdaCache: Bool?

    static var hasFullDiskAccess: Bool {
        fdaLock.lock(); defer { fdaLock.unlock() }
        if let cached = fdaCache { return cached }
        let value = probeFullDiskAccess()
        fdaCache = value
        return value
    }

    /// Drop the cached FDA result so the next read re-probes — call when the
    /// grant may have changed (e.g. the user returned from System Settings).
    static func invalidateFullDiskAccessCache() {
        fdaLock.lock(); fdaCache = nil; fdaLock.unlock()
    }

    private static func probeFullDiskAccess() -> Bool {
        let tcc = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        guard FileManager.default.fileExists(atPath: tcc) else { return false }
        guard let fh = FileHandle(forReadingAtPath: tcc) else { return false }
        defer { try? fh.close() }
        return ((try? fh.read(upToCount: 1)) != nil)
    }

    /// Deep-link straight to System Settings ▸ Privacy & Security ▸ Full Disk Access.
    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Should the one-time onboarding be shown right now? No if we've already
    /// onboarded, or if FDA is already on (there's nothing left to ask for).
    static var shouldPresentOnboarding: Bool {
        !hasOnboarded && !hasFullDiskAccess
    }

    /// True when this build is ad-hoc signed — meaning grants will NOT persist
    /// across rebuilds until `setup-signing.sh` is run. Inspects the running
    /// code's own signing flags (the `adhoc` bit) via the Security framework.
    static var isAdHocSigned: Bool {
        var codeRef: SecCode?
        guard SecCodeCopySelf([], &codeRef) == errSecSuccess, let code = codeRef else { return false }
        var staticRef: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticRef) == errSecSuccess, let scode = staticRef else { return false }
        var infoRef: CFDictionary?
        guard SecCodeCopySigningInformation(scode, [], &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any],
              let flags = info[kSecCodeInfoFlags as String] as? UInt32 else { return false }
        let kSecCodeSignatureAdhoc: UInt32 = 0x2
        return (flags & kSecCodeSignatureAdhoc) != 0
    }

    /// Present the one-time onboarding window if warranted. Safe to call on
    /// every launch — it self-suppresses. Returns the controller if it was
    /// shown (handy for tests); nil if skipped.
    @discardableResult
    static func presentOnboardingIfNeeded() -> PermissionsOnboardingController? {
        // FDA already on → silently record completion, show nothing.
        if hasFullDiskAccess {
            hasOnboarded = true
            return nil
        }
        guard !hasOnboarded else { return nil }
        let controller = PermissionsOnboardingController()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        hasOnboarded = true   // shown once; never auto-nag again
        return controller
    }

    /// Returns true if the path is in a standard TCC-protected folder
    /// (e.g. Desktop, Documents, Downloads, etc.) or removable volume.
    static func isProtectedPath(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        let protectedSubdirs = ["Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures"]
        for sub in protectedSubdirs {
            let prefix = (home as NSString).appendingPathComponent(sub)
            if path == prefix || path.hasPrefix(prefix + "/") {
                return true
            }
        }
        if path.hasPrefix("/Volumes/") { return true }
        return false
    }
}
