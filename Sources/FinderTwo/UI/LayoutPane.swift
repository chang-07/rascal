import AppKit

/// Settings pane for user-customizable layout dimensions.
///
/// Deliberately generic: it renders one stepper row per `LayoutToken`, the same
/// way `KeyboardPane` renders one recorder row per action. Adding a dimension to
/// `LayoutToken` surfaces it here automatically — no edits to this file.
final class LayoutPane: SettingsPane {

    private var steppers: [NSStepper] = []
    private var valueLabels: [NSTextField] = []
    private let stylePopup = NSPopUpButton()

    override func build() {
        addFullWidth(sectionHeader("Path control"))
        for style in Settings.PathControlStyle.allCases {
            stylePopup.addItem(withTitle: style.title)
        }
        stylePopup.selectItem(at: Settings.PathControlStyle.allCases
            .firstIndex(of: Settings.pathControlStyle) ?? 0)
        stylePopup.target = self
        stylePopup.action = #selector(styleChanged)
        addRow("Show path as", stylePopup)

        addFullWidth(sectionHeader("Dimensions"))

        for (i, token) in LayoutToken.allCases.enumerated() {
            let stepper = NSStepper()
            stepper.minValue = Double(token.range.lowerBound)
            stepper.maxValue = Double(token.range.upperBound)
            stepper.increment = Double(token.step)
            stepper.valueWraps = false
            stepper.doubleValue = Double(LayoutMetrics.value(token))
            stepper.tag = i                        // index back into allCases
            stepper.target = self
            stepper.action = #selector(stepperChanged(_:))

            let value = NSTextField(labelWithString: "")
            value.font = NSFont.systemFont(ofSize: 12)
            value.tag = 101                        // themed as a secondary label
            value.alignment = .left

            let row = NSStackView(views: [stepper, value])
            row.orientation = .horizontal
            row.spacing = 8

            steppers.append(stepper)
            valueLabels.append(value)
            addRow(token.title, row)
        }

        let reset = NSButton(title: "Reset Layout", target: self, action: #selector(resetLayout))
        reset.bezelStyle = .rounded
        addRow("", reset)

        refresh()
    }

    /// Shows the effective value, and marks untouched tokens so it's obvious
    /// which dimensions the user has actually overridden.
    private func text(for token: LayoutToken) -> String {
        let v = Int(LayoutMetrics.value(token).rounded())
        return LayoutMetrics.isCustomized(token) ? "\(v) pt" : "\(v) pt  ·  default"
    }

    @objc private func stepperChanged(_ sender: NSStepper) {
        guard LayoutToken.allCases.indices.contains(sender.tag) else { return }
        LayoutMetrics.set(LayoutToken.allCases[sender.tag], CGFloat(sender.doubleValue))
        refresh()
    }

    @objc private func styleChanged() {
        let all = Settings.PathControlStyle.allCases
        guard all.indices.contains(stylePopup.indexOfSelectedItem) else { return }
        Settings.pathControlStyle = all[stylePopup.indexOfSelectedItem]
    }

    @objc private func resetLayout() {
        LayoutMetrics.resetAll()
        refresh()
    }

    /// Re-sync every control from the registry (after a change or a reset).
    private func refresh() {
        for (i, token) in LayoutToken.allCases.enumerated() {
            guard steppers.indices.contains(i), valueLabels.indices.contains(i) else { continue }
            steppers[i].doubleValue = Double(LayoutMetrics.value(token))
            valueLabels[i].stringValue = text(for: token)
        }
    }
}
