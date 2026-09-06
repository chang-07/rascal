import Foundation

/// User-controlled sidebar structure beyond Favorites: section order plus
/// custom folders pinned into Locations and the expandable Folders tree.
enum SidebarLayout {
    static let didChange = Notification.Name("FinderTwo.sidebarLayoutDidChange")

    static let defaultSectionOrder = [
        "Favorites", "Locations", "Smart Folders", "Tags", "Folders",
    ]

    private static let sectionOrderKey = "FinderTwo.sidebarSectionOrder.v1"
    private static let locationPathsKey = "FinderTwo.sidebarLocationPaths.v1"
    private static let locationOrderKey = "FinderTwo.sidebarLocationOrder.v1"
    private static let folderRootPathsKey = "FinderTwo.sidebarFolderRootPaths.v1"
    private static let folderRootOrderKey = "FinderTwo.sidebarFolderRootOrder.v1"

    static func orderedSectionTitles(available: [String]) -> [String] {
        let availableSet = Set(available)
        let saved = UserDefaults.standard.stringArray(forKey: sectionOrderKey) ?? defaultSectionOrder
        var result = saved.filter { availableSet.contains($0) }
        for title in available where !result.contains(title) { result.append(title) }
        return result
    }

    static func moveSection(_ title: String, toVisibleIndex rawIndex: Int,
                            among visibleTitles: [String]) {
        guard visibleTitles.contains(title) else { return }
        var full = UserDefaults.standard.stringArray(forKey: sectionOrderKey) ?? defaultSectionOrder
        for known in defaultSectionOrder where !full.contains(known) { full.append(known) }
        full.removeAll { $0 == title }

        let remainingVisible = visibleTitles.filter { $0 != title }
        let sourceIndex = visibleTitles.firstIndex(of: title) ?? 0
        var destination = max(0, min(rawIndex, visibleTitles.count))
        if sourceIndex < destination { destination -= 1 }
        destination = max(0, min(destination, remainingVisible.count))

        if destination < remainingVisible.count,
           let anchor = full.firstIndex(of: remainingVisible[destination]) {
            full.insert(title, at: anchor)
        } else if let lastVisible = remainingVisible.last,
                  let anchor = full.firstIndex(of: lastVisible) {
            full.insert(title, at: anchor + 1)
        } else {
            full.append(title)
        }
        UserDefaults.standard.set(full, forKey: sectionOrderKey)
        notify()
    }

    static func customLocations() -> [URL] { urls(forKey: locationPathsKey) }
    static func orderedLocations(defaults: [URL]) -> [URL] {
        orderedURLs(defaults: defaults, custom: customLocations(), orderKey: locationOrderKey)
    }
    static func insertLocations(_ urls: [URL], at index: Int, among current: [URL]) {
        insertURLs(urls, at: index, among: current,
                   customKey: locationPathsKey, orderKey: locationOrderKey)
    }
    static func removeLocation(_ url: URL) {
        removeCustomURL(url, customKey: locationPathsKey, orderKey: locationOrderKey)
    }
    static func isCustomLocation(_ url: URL) -> Bool {
        customLocations().contains { path($0) == path(url) }
    }

    static func customFolderRoots() -> [URL] { urls(forKey: folderRootPathsKey) }
    static func orderedFolderRoots(defaults: [URL]) -> [URL] {
        orderedURLs(defaults: defaults, custom: customFolderRoots(), orderKey: folderRootOrderKey)
    }
    static func insertFolderRoots(_ urls: [URL], at index: Int, among current: [URL]) {
        insertURLs(urls, at: index, among: current,
                   customKey: folderRootPathsKey, orderKey: folderRootOrderKey)
    }
    static func removeFolderRoot(_ url: URL) {
        removeCustomURL(url, customKey: folderRootPathsKey, orderKey: folderRootOrderKey)
    }
    static func isCustomFolderRoot(_ url: URL) -> Bool {
        customFolderRoots().contains { path($0) == path(url) }
    }

    private static func orderedURLs(defaults: [URL], custom: [URL], orderKey: String) -> [URL] {
        var byPath: [String: URL] = [:]
        var base: [String] = []
        for url in defaults + custom {
            let p = path(url)
            if byPath[p] == nil { byPath[p] = url; base.append(p) }
        }
        let available = Set(base)
        var result = (UserDefaults.standard.stringArray(forKey: orderKey) ?? [])
            .filter { available.contains($0) }
        for p in base where !result.contains(p) { result.append(p) }
        return result.compactMap { byPath[$0] }
    }

    private static func insertURLs(_ urls: [URL], at rawIndex: Int, among current: [URL],
                                   customKey: String, orderKey: String) {
        var moving: [String] = []
        for url in urls {
            let p = path(url)
            if !moving.contains(p) { moving.append(p) }
        }
        guard !moving.isEmpty else { return }

        let currentPaths = current.map(path)
        let movingSet = Set(moving)
        var remaining = currentPaths.filter { !movingSet.contains($0) }
        let boundary = max(0, min(rawIndex, currentPaths.count))
        let removedBefore = currentPaths.prefix(boundary).filter { movingSet.contains($0) }.count
        let destination = max(0, min(boundary - removedBefore, remaining.count))
        remaining.insert(contentsOf: moving, at: destination)

        var custom = UserDefaults.standard.stringArray(forKey: customKey) ?? []
        let existing = Set(currentPaths)
        for p in moving where !existing.contains(p) && !custom.contains(p) { custom.append(p) }
        UserDefaults.standard.set(custom, forKey: customKey)
        UserDefaults.standard.set(remaining, forKey: orderKey)
        notify()
    }

    private static func removeCustomURL(_ url: URL, customKey: String, orderKey: String) {
        let p = path(url)
        let custom = (UserDefaults.standard.stringArray(forKey: customKey) ?? []).filter { $0 != p }
        let order = (UserDefaults.standard.stringArray(forKey: orderKey) ?? []).filter { $0 != p }
        UserDefaults.standard.set(custom, forKey: customKey)
        UserDefaults.standard.set(order, forKey: orderKey)
        notify()
    }

    private static func urls(forKey key: String) -> [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
    }
    private static func path(_ url: URL) -> String { url.standardizedFileURL.path }
    private static func notify() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
