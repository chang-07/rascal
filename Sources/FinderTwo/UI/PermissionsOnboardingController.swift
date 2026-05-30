import AppKit

/// Revamped interactive onboarding window. Walks the user through granting Full Disk Access
/// with clean cross-fade transitions, live permission detection, and custom animations.
final class PermissionsOnboardingController: NSWindowController, ThemeObserving {

    enum State {
        case welcome
        case waiting
        case success
    }

    private let card = NSView()
    private var currentState: State = .welcome
    private var pollTimer: Timer?

    // MARK: - Welcome View Elements
    private let welcomeView = NSView()
    private let iconView = NSImageView()
    private let eyebrow = NSTextField(labelWithString: "ONE-TIME SETUP")
    private let titleLabel = NSTextField(labelWithString: "Give Rascal full access")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let bulletStack = NSStackView()
    private let warningLabel = NSTextField(wrappingLabelWithString: "")
    private let grantButton = NSButton(title: "Open System Settings", target: nil, action: nil)
    private let laterButton = NSButton(title: "Maybe Later", target: nil, action: nil)

    // MARK: - Waiting View Elements
    private let waitingView = NSView()
    private let spinner = NSProgressIndicator()
    private let waitingTitleLabel = NSTextField(labelWithString: "Awaiting Permission...")
    private let waitingBodyLabel = NSTextField(wrappingLabelWithString: "")
    private let guideCard = NSView()
    private let checkButton = NSButton(title: "Check Again", target: nil, action: nil)
    private let backButton = NSButton(title: "Back", target: nil, action: nil)

    // MARK: - Success View Elements
    private let successView = NSView()
    private let checkmarkView = NSImageView()
    private let successTitleLabel = NSTextField(labelWithString: "Access Granted!")
    private let successBodyLabel = NSTextField(wrappingLabelWithString: "")
    private let finishButton = NSButton(title: "Start Browsing", target: nil, action: nil)

    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.center()
        self.init(window: w)
        buildUI()
        subscribeToTheme(self)
        transition(to: .welcome, animated: false)
    }

    deinit {
        stopPolling()
        NotificationCenter.default.removeObserver(self)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        content.addSubview(card)

        // card fills content
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: content.topAnchor),
            card.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        // Add Welcome, Waiting, and Success views to the card
        for v in [welcomeView, waitingView, successView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: card.topAnchor),
                v.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                v.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            ])
        }

        setupWelcomeView()
        setupWaitingView()
        setupSuccessView()
    }

    // MARK: - Welcome Screen Layout
    private func setupWelcomeView() {
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        eyebrow.font = .systemFont(ofSize: 11, weight: .heavy)
        eyebrow.alignment = .center

        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.alignment = .center

        bodyLabel.stringValue = "Rascal is a file manager — it works best when it can see all your files. Grant Full Disk Access once and macOS will remember it. No per-folder pop-ups, ever again."
        bodyLabel.font = .systemFont(ofSize: 13)
        bodyLabel.alignment = .center
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false

        bulletStack.orientation = .vertical
        bulletStack.alignment = .leading
        bulletStack.spacing = 8
        bulletStack.translatesAutoresizingMaskIntoConstraints = false
        for (symbol, text) in [
            ("externaldrive", "Browse external & network drives"),
            ("folder", "Open Desktop, Documents & Downloads instantly"),
            ("lock.open", "Skip the repeated permission prompts"),
        ] {
            bulletStack.addArrangedSubview(makeBullet(symbol: symbol, text: text))
        }

        warningLabel.font = .systemFont(ofSize: 11)
        warningLabel.alignment = .center
        warningLabel.translatesAutoresizingMaskIntoConstraints = false
        warningLabel.isHidden = !PermissionsManager.isAdHocSigned
        warningLabel.stringValue = "⚠︎ This build is ad-hoc signed, so grants won't persist across rebuilds. Run ./setup-signing.sh once to fix that."

        grantButton.target = self
        grantButton.action = #selector(grant)
        grantButton.bezelStyle = .rounded
        grantButton.keyEquivalent = "\r"          // default button → accent-tinted
        grantButton.translatesAutoresizingMaskIntoConstraints = false

        laterButton.target = self
        laterButton.action = #selector(later)
        laterButton.bezelStyle = .rounded
        laterButton.keyEquivalent = "\u{1b}"       // Esc
        laterButton.translatesAutoresizingMaskIntoConstraints = false

        let welcomeButtons = NSStackView(views: [laterButton, grantButton])
        welcomeButtons.orientation = .horizontal
        welcomeButtons.spacing = 12
        welcomeButtons.translatesAutoresizingMaskIntoConstraints = false

        for v in [iconView, eyebrow, titleLabel, bodyLabel, bulletStack, warningLabel, welcomeButtons] {
            v.translatesAutoresizingMaskIntoConstraints = false
            welcomeView.addSubview(v)
        }

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: welcomeView.topAnchor, constant: 28),
            iconView.centerXAnchor.constraint(equalTo: welcomeView.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 72),
            iconView.heightAnchor.constraint(equalToConstant: 72),

            eyebrow.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 12),
            eyebrow.centerXAnchor.constraint(equalTo: welcomeView.centerXAnchor),

            titleLabel.topAnchor.constraint(equalTo: eyebrow.bottomAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: welcomeView.leadingAnchor, constant: 32),
            titleLabel.trailingAnchor.constraint(equalTo: welcomeView.trailingAnchor, constant: -32),

            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            bodyLabel.leadingAnchor.constraint(equalTo: welcomeView.leadingAnchor, constant: 36),
            bodyLabel.trailingAnchor.constraint(equalTo: welcomeView.trailingAnchor, constant: -36),

            bulletStack.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 18),
            bulletStack.centerXAnchor.constraint(equalTo: welcomeView.centerXAnchor),

            warningLabel.topAnchor.constraint(equalTo: bulletStack.bottomAnchor, constant: 16),
            warningLabel.leadingAnchor.constraint(equalTo: welcomeView.leadingAnchor, constant: 32),
            warningLabel.trailingAnchor.constraint(equalTo: welcomeView.trailingAnchor, constant: -32),

            welcomeButtons.bottomAnchor.constraint(equalTo: welcomeView.bottomAnchor, constant: -24),
            welcomeButtons.centerXAnchor.constraint(equalTo: welcomeView.centerXAnchor),
        ])
    }

    // MARK: - Waiting Screen Layout
    private func setupWaitingView() {
        spinner.style = .spinning
        spinner.isIndeterminate = true
        spinner.controlSize = .large
        spinner.translatesAutoresizingMaskIntoConstraints = false

        waitingTitleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        waitingTitleLabel.alignment = .center

        waitingBodyLabel.stringValue = "We opened System Settings for you. Please locate Rascal in the Full Disk Access list and turn it ON. We will automatically detect when it's enabled."
        waitingBodyLabel.font = .systemFont(ofSize: 13)
        waitingBodyLabel.alignment = .center
        waitingBodyLabel.translatesAutoresizingMaskIntoConstraints = false

        guideCard.translatesAutoresizingMaskIntoConstraints = false
        guideCard.wantsLayer = true
        guideCard.layer?.cornerRadius = 12
        guideCard.layer?.borderWidth = 1

        let guideStack = NSStackView()
        guideStack.orientation = .vertical
        guideStack.alignment = .leading
        guideStack.spacing = 8
        guideStack.translatesAutoresizingMaskIntoConstraints = false

        for (num, text) in [
            ("1", "System Settings is open"),
            ("2", "Find Rascal in the list (click + if missing)"),
            ("3", "Toggle the switch next to Rascal to ON"),
        ] {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 10
            row.alignment = .centerY

            let circle = NSTextField(labelWithString: num)
            circle.font = .systemFont(ofSize: 10, weight: .bold)
            circle.textColor = .white
            circle.alignment = .center
            circle.translatesAutoresizingMaskIntoConstraints = false
            circle.wantsLayer = true
            circle.layer?.masksToBounds = true
            circle.layer?.cornerRadius = 9
            circle.widthAnchor.constraint(equalToConstant: 18).isActive = true
            circle.heightAnchor.constraint(equalToConstant: 18).isActive = true

            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 12)
            label.tag = 0xB118

            row.addArrangedSubview(circle)
            row.addArrangedSubview(label)
            guideStack.addArrangedSubview(row)
        }

        guideCard.addSubview(guideStack)
        NSLayoutConstraint.activate([
            guideStack.centerXAnchor.constraint(equalTo: guideCard.centerXAnchor),
            guideStack.centerYAnchor.constraint(equalTo: guideCard.centerYAnchor),
        ])

        checkButton.target = self
        checkButton.action = #selector(checkAgain)
        checkButton.bezelStyle = .rounded
        checkButton.keyEquivalent = "\r"
        checkButton.translatesAutoresizingMaskIntoConstraints = false

        backButton.target = self
        backButton.action = #selector(back)
        backButton.bezelStyle = .rounded
        backButton.keyEquivalent = "\u{1b}"
        backButton.translatesAutoresizingMaskIntoConstraints = false

        let waitingButtons = NSStackView(views: [backButton, checkButton])
        waitingButtons.orientation = .horizontal
        waitingButtons.spacing = 12
        waitingButtons.translatesAutoresizingMaskIntoConstraints = false

        for v in [spinner, waitingTitleLabel, waitingBodyLabel, guideCard, waitingButtons] {
            v.translatesAutoresizingMaskIntoConstraints = false
            waitingView.addSubview(v)
        }

        NSLayoutConstraint.activate([
            spinner.topAnchor.constraint(equalTo: waitingView.topAnchor, constant: 36),
            spinner.centerXAnchor.constraint(equalTo: waitingView.centerXAnchor),

            waitingTitleLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 16),
            waitingTitleLabel.centerXAnchor.constraint(equalTo: waitingView.centerXAnchor),

            waitingBodyLabel.topAnchor.constraint(equalTo: waitingTitleLabel.bottomAnchor, constant: 10),
            waitingBodyLabel.leadingAnchor.constraint(equalTo: waitingView.leadingAnchor, constant: 36),
            waitingBodyLabel.trailingAnchor.constraint(equalTo: waitingView.trailingAnchor, constant: -36),

            guideCard.topAnchor.constraint(equalTo: waitingBodyLabel.bottomAnchor, constant: 18),
            guideCard.centerXAnchor.constraint(equalTo: waitingView.centerXAnchor),
            guideCard.widthAnchor.constraint(equalToConstant: 340),
            guideCard.heightAnchor.constraint(equalToConstant: 96),

            waitingButtons.bottomAnchor.constraint(equalTo: waitingView.bottomAnchor, constant: -24),
            waitingButtons.centerXAnchor.constraint(equalTo: waitingView.centerXAnchor),
        ])
    }

    // MARK: - Success Screen Layout
    private func setupSuccessView() {
        checkmarkView.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        checkmarkView.imageScaling = .scaleProportionallyUpOrDown
        checkmarkView.contentTintColor = .systemGreen
        checkmarkView.translatesAutoresizingMaskIntoConstraints = false

        successTitleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        successTitleLabel.alignment = .center

        successBodyLabel.stringValue = "Full Disk Access is active. Rascal is now ready to manage your files with maximum performance and zero prompts."
        successBodyLabel.font = .systemFont(ofSize: 13)
        successBodyLabel.alignment = .center
        successBodyLabel.translatesAutoresizingMaskIntoConstraints = false

        finishButton.target = self
        finishButton.action = #selector(finish)
        finishButton.bezelStyle = .rounded
        finishButton.keyEquivalent = "\r"
        finishButton.translatesAutoresizingMaskIntoConstraints = false

        for v in [checkmarkView, successTitleLabel, successBodyLabel, finishButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            successView.addSubview(v)
        }

        NSLayoutConstraint.activate([
            checkmarkView.topAnchor.constraint(equalTo: successView.topAnchor, constant: 60),
            checkmarkView.centerXAnchor.constraint(equalTo: successView.centerXAnchor),
            checkmarkView.widthAnchor.constraint(equalToConstant: 80),
            checkmarkView.heightAnchor.constraint(equalToConstant: 80),

            successTitleLabel.topAnchor.constraint(equalTo: checkmarkView.bottomAnchor, constant: 20),
            successTitleLabel.centerXAnchor.constraint(equalTo: successView.centerXAnchor),

            successBodyLabel.topAnchor.constraint(equalTo: successTitleLabel.bottomAnchor, constant: 12),
            successBodyLabel.leadingAnchor.constraint(equalTo: successView.leadingAnchor, constant: 36),
            successBodyLabel.trailingAnchor.constraint(equalTo: successView.trailingAnchor, constant: -36),

            finishButton.bottomAnchor.constraint(equalTo: successView.bottomAnchor, constant: -40),
            finishButton.centerXAnchor.constraint(equalTo: successView.centerXAnchor),
        ])
    }

    private func makeBullet(symbol: String, text: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        let img = NSImageView()
        img.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        img.translatesAutoresizingMaskIntoConstraints = false
        img.widthAnchor.constraint(equalToConstant: 18).isActive = true
        img.contentTintColor = ThemeManager.shared.effectiveAccent
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.tag = 0xB117   // marker so applyTheme can recolor bullet labels
        row.addArrangedSubview(img)
        row.addArrangedSubview(label)
        return row
    }

    // MARK: - State Transitions
    private func transition(to state: State, animated: Bool = true) {
        let oldView: NSView
        let newView: NSView

        switch currentState {
        case .welcome: oldView = welcomeView
        case .waiting: oldView = waitingView
        case .success: oldView = successView
        }

        switch state {
        case .welcome: newView = welcomeView
        case .waiting: newView = waitingView
        case .success: newView = successView
        }

        currentState = state

        if oldView === newView {
            welcomeView.isHidden = (state != .welcome)
            waitingView.isHidden = (state != .waiting)
            successView.isHidden = (state != .success)
            newView.alphaValue = 1.0
            return
        }

        newView.alphaValue = 0.0
        newView.isHidden = false

        if state == .waiting {
            spinner.startAnimation(nil)
            startPolling()
        } else {
            stopPolling()
            spinner.stopAnimation(nil)
        }

        if state == .success {
            playSuccessAnimation()
        }

        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.35
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                oldView.animator().alphaValue = 0.0
                newView.animator().alphaValue = 1.0
            }, completionHandler: {
                if self.currentState != state { return }
                oldView.isHidden = true
            })
        } else {
            oldView.alphaValue = 0.0
            oldView.isHidden = true
            newView.alphaValue = 1.0
        }
    }

    // MARK: - Celebration Animation
    private func playSuccessAnimation() {
        checkmarkView.wantsLayer = true
        checkmarkView.layer?.transform = CATransform3DMakeScale(0.01, 0.01, 1.0)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = 0.01
            spring.toValue = 1.0
            spring.damping = 12
            spring.stiffness = 180
            spring.duration = spring.settlingDuration

            self.checkmarkView.layer?.transform = CATransform3DIdentity
            self.checkmarkView.layer?.add(spring, forKey: "springScale")
        }
    }

    // MARK: - Shake Card Feedback
    private func shakeGuideCard() {
        let animation = CABasicAnimation(keyPath: "position")
        animation.duration = 0.06
        animation.repeatCount = 3
        animation.autoreverses = true

        let currentPos = guideCard.frame.origin
        animation.fromValue = NSValue(point: NSPoint(x: currentPos.x - 5, y: currentPos.y))
        animation.toValue = NSValue(point: NSPoint(x: currentPos.x + 5, y: currentPos.y))

        guideCard.wantsLayer = true
        guideCard.layer?.add(animation, forKey: "shake")
    }

    // MARK: - Polling Logic
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            guard let self else { return }
            if PermissionsManager.hasFullDiskAccess {
                self.transition(to: .success)
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Actions
    @objc private func grant() {
        PermissionsManager.openFullDiskAccessSettings()
        transition(to: .waiting)
    }

    @objc private func later() {
        stopPolling()
        close()
    }

    @objc private func back() {
        transition(to: .welcome)
    }

    @objc private func checkAgain() {
        if PermissionsManager.hasFullDiskAccess {
            transition(to: .success)
        } else {
            shakeGuideCard()
        }
    }

    @objc private func finish() {
        stopPolling()
        close()
    }

    // MARK: - Theme Management
    @objc func applyTheme() {
        let t = ThemeManager.shared.current
        let isSystem = t.id == "system"

        let bg = isSystem ? NSColor.windowBackgroundColor : t.background
        card.layer?.backgroundColor = bg.cgColor

        // Welcome theme
        eyebrow.textColor = ThemeManager.shared.effectiveAccent
        titleLabel.textColor = isSystem ? .labelColor : t.labelPrimary
        bodyLabel.textColor = isSystem ? .secondaryLabelColor : t.labelSecondary
        warningLabel.textColor = .systemOrange
        for row in bulletStack.arrangedSubviews {
            for sub in (row as? NSStackView)?.arrangedSubviews ?? [] {
                if let iv = sub as? NSImageView { iv.contentTintColor = ThemeManager.shared.effectiveAccent }
                if let tf = sub as? NSTextField, tf.tag == 0xB117 {
                    tf.textColor = isSystem ? .labelColor : t.labelPrimary
                }
            }
        }

        // Waiting theme
        waitingTitleLabel.textColor = isSystem ? .labelColor : t.labelPrimary
        waitingBodyLabel.textColor = isSystem ? .secondaryLabelColor : t.labelSecondary
        guideCard.layer?.backgroundColor = (isSystem ? NSColor.controlBackgroundColor : t.pathBarBackground).cgColor
        guideCard.layer?.borderColor = (isSystem ? NSColor.separatorColor : t.rowAlternate).cgColor

        if let guideStack = guideCard.subviews.first as? NSStackView {
            for row in guideStack.arrangedSubviews {
                for sub in (row as? NSStackView)?.arrangedSubviews ?? [] {
                    if let tf = sub as? NSTextField {
                        if tf.tag == 0xB118 {
                            tf.textColor = isSystem ? .labelColor : t.labelPrimary
                        } else {
                            tf.layer?.backgroundColor = ThemeManager.shared.effectiveAccent.cgColor
                        }
                    }
                }
            }
        }

        // Success theme
        successTitleLabel.textColor = isSystem ? .labelColor : t.labelPrimary
        successBodyLabel.textColor = isSystem ? .secondaryLabelColor : t.labelSecondary
    }

    // MARK: - Test hooks
    var testTitle: String { titleLabel.stringValue }
    var testShowsAdHocWarning: Bool { !warningLabel.isHidden }
    var testBulletCount: Int { bulletStack.arrangedSubviews.count }

    var testCurrentState: String {
        switch currentState {
        case .welcome: return "welcome"
        case .waiting: return "waiting"
        case .success: return "success"
        }
    }
    func testTransitionToWaiting() { transition(to: .waiting, animated: false) }
    func testTransitionToSuccess() { transition(to: .success, animated: false) }
}
