import AppKit

/// The portable, on-disk representation of a theme: every color is a hex
/// string so a theme is just a small JSON file users can write, share, and
/// drop into the Themes folder. `Theme` is built from a spec at load time.
struct ThemeSpec: Codable, Equatable {
    var id: String
    var name: String
    var appearance: String              // "light" | "dark" | "automatic"
    var background: String
    var sidebarBackground: String
    var toolbarBackground: String
    var pathBarBackground: String
    var rowAlternate: String
    var labelPrimary: String
    var labelSecondary: String
    var labelTertiary: String
    var accent: String
    var selectionBackground: String
    var baseFontPointSize: Double = 13
    var rowHeight: Double = 22
    var monospaced: Bool = false
}

extension ThemeSpec {
    /// Forgiving decoder: the cosmetic extras (font size / row height /
    /// monospaced) may be omitted from a user's JSON and fall back to defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? "automatic"
        background = try c.decode(String.self, forKey: .background)
        sidebarBackground = try c.decode(String.self, forKey: .sidebarBackground)
        toolbarBackground = try c.decode(String.self, forKey: .toolbarBackground)
        pathBarBackground = try c.decode(String.self, forKey: .pathBarBackground)
        rowAlternate = try c.decode(String.self, forKey: .rowAlternate)
        labelPrimary = try c.decode(String.self, forKey: .labelPrimary)
        labelSecondary = try c.decode(String.self, forKey: .labelSecondary)
        labelTertiary = try c.decode(String.self, forKey: .labelTertiary)
        accent = try c.decode(String.self, forKey: .accent)
        selectionBackground = try c.decode(String.self, forKey: .selectionBackground)
        baseFontPointSize = try c.decodeIfPresent(Double.self, forKey: .baseFontPointSize) ?? 13
        rowHeight = try c.decodeIfPresent(Double.self, forKey: .rowHeight) ?? 22
        monospaced = try c.decodeIfPresent(Bool.self, forKey: .monospaced) ?? false
    }
}

extension NSColor {
    /// Parse "#RRGGBB" or "#RRGGBBAA" (the leading # is optional). sRGB.
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: UInt64
        if s.count == 6 {
            r = (v >> 16) & 0xff; g = (v >> 8) & 0xff; b = v & 0xff; a = 255
        } else {
            r = (v >> 24) & 0xff; g = (v >> 16) & 0xff; b = (v >> 8) & 0xff; a = v & 0xff
        }
        self.init(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                  blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }

    /// "#RRGGBB" / "#RRGGBBAA" (alpha only when not fully opaque).
    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        let a = Int((c.alphaComponent * 255).rounded())
        return a == 255 ? String(format: "#%02X%02X%02X", r, g, b)
                        : String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }
}

extension Theme {
    /// Build a Theme from a spec; unparseable colors fall back to magenta so a
    /// typo is obvious rather than silently wrong.
    init(spec: ThemeSpec) {
        func c(_ s: String) -> NSColor { NSColor(hex: s) ?? .magenta }
        self.init(
            id: spec.id,
            name: spec.name,
            appearance: Theme.Appearance(rawValue: spec.appearance) ?? .automatic,
            background: c(spec.background),
            sidebarBackground: c(spec.sidebarBackground),
            toolbarBackground: c(spec.toolbarBackground),
            pathBarBackground: c(spec.pathBarBackground),
            rowAlternate: c(spec.rowAlternate),
            labelPrimary: c(spec.labelPrimary),
            labelSecondary: c(spec.labelSecondary),
            labelTertiary: c(spec.labelTertiary),
            accent: c(spec.accent),
            selectionBackground: c(spec.selectionBackground),
            baseFontPointSize: CGFloat(spec.baseFontPointSize),
            rowHeight: CGFloat(spec.rowHeight),
            monospaced: spec.monospaced
        )
    }

    /// Serialize this theme back to a spec (for export / a future editor).
    var spec: ThemeSpec {
        ThemeSpec(
            id: id, name: name, appearance: appearance.rawValue,
            background: background.hexString,
            sidebarBackground: sidebarBackground.hexString,
            toolbarBackground: toolbarBackground.hexString,
            pathBarBackground: pathBarBackground.hexString,
            rowAlternate: rowAlternate.hexString,
            labelPrimary: labelPrimary.hexString,
            labelSecondary: labelSecondary.hexString,
            labelTertiary: labelTertiary.hexString,
            accent: accent.hexString,
            selectionBackground: selectionBackground.hexString,
            baseFontPointSize: Double(baseFontPointSize),
            rowHeight: Double(rowHeight),
            monospaced: monospaced
        )
    }
}
