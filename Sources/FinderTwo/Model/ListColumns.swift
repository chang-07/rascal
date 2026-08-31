import AppKit

/// The set of columns the list view (`FileListController`) can show, plus the
/// persistence for which ones the user has chosen. "Commands are data" in spirit:
/// the column set is a single enum the table, the header context menu, and the
/// cell renderer all read from, so adding a column is one case here.
///
/// `name` is mandatory (it carries the icon + inline rename) and always visible;
/// the rest are user-toggleable from the column-header right-click menu. Width
/// and order are persisted by NSTableView's own column autosave; visibility is
/// persisted here (autosave alone doesn't round-trip a column the user has never
/// revealed in a given install).
enum ListColumn: String, CaseIterable {
    case name
    case modified       // kMDItemContentModificationDate (FileItem.modified)
    case created        // kMDItemContentCreationDate (FileItem.created)
    case size
    case kind
    case tags           // Finder color tags (kMDItemUserTags) — via Tags.swift
    case comments       // Spotlight kMDItemFinderComment
    case dateAdded      // Spotlight kMDItemDateAdded

    /// Stable column identifier used by NSTableColumn (kept equal to rawValue so
    /// existing autosaved widths/order for "name"/"modified"/"size"/"kind" survive
    /// the upgrade).
    var id: String { rawValue }

    var title: String {
        switch self {
        case .name:      return "Name"
        case .modified:  return "Date Modified"
        case .created:   return "Date Created"
        case .size:      return "Size"
        case .kind:      return "Kind"
        case .tags:      return "Tags"
        case .comments:  return "Comments"
        case .dateAdded: return "Date Added"
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .name:      return 340
        case .modified:  return 170
        case .created:   return 170
        case .size:      return 90
        case .kind:      return 130
        case .tags:      return 120
        case .comments:  return 200
        case .dateAdded: return 170
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .name:      return 120
        case .size:      return 60
        case .kind:      return 70
        case .tags:      return 60
        case .comments:  return 80
        default:         return 110
        }
    }

    /// The sort key a header click on this column applies, or nil for columns we
    /// don't sort by (tags / comments have no FileItem-backed ordering).
    var sortKey: SortKey? {
        switch self {
        case .name:      return .name
        case .modified:  return .dateModified
        case .created:   return .dateCreated
        case .size:      return .size
        case .kind:      return .kind
        case .tags, .comments, .dateAdded: return nil
        }
    }

    var alignment: NSTextAlignment { self == .size ? .right : .left }

    /// Mandatory columns can't be hidden (only Name, today).
    var isMandatory: Bool { self == .name }

    /// Columns shown when the user has never customized the set — matches the
    /// historical fixed layout (Name / Date Modified / Size / Kind).
    static let defaultVisible: [ListColumn] = [.name, .modified, .size, .kind]

    /// Whether a Spotlight `MDItem` lookup is needed to render this column (vs.
    /// data already on the `FileItem`). Drives the off-main fetch in the list.
    var needsSpotlight: Bool {
        switch self {
        case .comments, .dateAdded: return true
        default: return false
        }
    }
}

/// Persisted set of visible list columns (global, like Finder's "View Options"
/// "use as default"). Stored under the `FinderTwo.*` UserDefaults namespace as a
/// list of column ids. Order/width are handled by NSTableView column autosave.
enum ListColumnPrefs {
    // Headless tests use a separate key so the suite never clobbers a real user's
    // chosen columns (mirrors FolderViewPrefs).
    private static let storeKey: String =
        ProcessInfo.processInfo.environment["FT_HEADLESS_TESTING"] == "1"
            ? "FinderTwo.listColumns.test"
            : "FinderTwo.listColumns.v1"

    private static let d = UserDefaults.standard

    /// The columns the user wants visible, in canonical `ListColumn.allCases`
    /// order. Always contains the mandatory columns; falls back to the default
    /// set when nothing has been saved yet. Unknown/stale ids are dropped.
    static var visible: [ListColumn] {
        get {
            guard let ids = d.array(forKey: storeKey) as? [String] else {
                return ListColumn.defaultVisible   // never customized
            }
            let chosen = Set(ids.compactMap { ListColumn(rawValue: $0) })
            // A stored value that resolves to NO known column is corrupt — fall
            // back to defaults rather than blanking the list down to just Name.
            // (The setter always writes Name, so a legitimate "everything off"
            // still resolves to at least one known column and is honored.)
            guard !chosen.isEmpty else { return ListColumn.defaultVisible }
            return ListColumn.allCases.filter { chosen.contains($0) || $0.isMandatory }
        }
        set {
            // Canonicalize: dedupe, force mandatory columns on, keep enum order.
            let chosen = Set(newValue)
            let ids = ListColumn.allCases
                .filter { chosen.contains($0) || $0.isMandatory }
                .map { $0.rawValue }
            d.set(ids, forKey: storeKey)
        }
    }

    static func isVisible(_ col: ListColumn) -> Bool {
        col.isMandatory || visible.contains(col)
    }

    /// Toggle a column on/off (mandatory columns can't be turned off). Returns
    /// the resulting visibility so callers can update menu state without a reread.
    @discardableResult
    static func toggle(_ col: ListColumn) -> Bool {
        guard !col.isMandatory else { return true }
        var set = Set(visible)
        if set.contains(col) { set.remove(col) } else { set.insert(col) }
        visible = Array(set)
        return set.contains(col)
    }

    /// Forget the saved column set (used by a reset affordance + tests).
    static func reset() { d.removeObject(forKey: storeKey) }
}
