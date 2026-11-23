import Cocoa

protocol PreBreakHUDDelegate: AnyObject {
    func didRequestPreBreakSnooze(minutes: Int)
    func didRequestPreBreakSkip()
}

final class PreBreakHUDWindow: NSPanel {
    weak var hudDelegate: PreBreakHUDDelegate?

    private static let hudSize = NSSize(width: 280, height: 92)

    private var localizer: ((String) -> String)?
    private var lastRemainingSeconds: Int = 0

    private let visualEffectView = NSVisualEffectView()
    private let iconView = NSImageView()
    private let countdownLabel = NSTextField(labelWithString: "")
    private let snooze1Button = NSButton()
    private let snooze5Button = NSButton()
    private let skipButton = NSButton()

    init() {
        let initialFrame = Self.defaultFrame()
        super.init(
            contentRect: initialFrame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        setupPanel()
        setupUI()
    }

    func setLocalizer(_ localizer: @escaping (String) -> String) {
        self.localizer = localizer
        updateTexts()
    }

    func showHUD(remainingSeconds: Int, canSnooze1Min: Bool, canSnooze5Min: Bool) {
        if !isVisible {
            setFrame(Self.defaultFrame(), display: false)
        }
        updateCountdown(remainingSeconds)
        updateSnoozeAvailability(canSnooze1Min: canSnooze1Min, canSnooze5Min: canSnooze5Min)
        if !isVisible {
            orderFrontRegardless()
        }
    }

    func updateCountdown(_ remainingSeconds: Int) {
        lastRemainingSeconds = max(0, remainingSeconds)
        let format = localizer?("preBreakCountdownFormat") ?? "Break in %ds"
        countdownLabel.stringValue = String(format: format, lastRemainingSeconds)
    }

    func updateSnoozeAvailability(canSnooze1Min: Bool, canSnooze5Min: Bool) {
        configureActionButton(snooze1Button, enabled: canSnooze1Min, isPrimary: false)
        configureActionButton(snooze5Button, enabled: canSnooze5Min, isPrimary: false)
        configureActionButton(skipButton, enabled: true, isPrimary: false)
    }

    func dismissHUD() {
        orderOut(nil)
    }

    private func setupPanel() {
        level = .floating
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
    }

    private func setupUI() {
        guard let contentView else { return }

        visualEffectView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 14
        visualEffectView.layer?.masksToBounds = true
        visualEffectView.layer?.borderWidth = 1
        visualEffectView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        contentView.addSubview(visualEffectView)

        if let symbol = NSImage(systemSymbolName: "eye", accessibilityDescription: "EyeGuard") {
            iconView.image = symbol
        }
        iconView.contentTintColor = .controlAccentColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        countdownLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        countdownLabel.textColor = .labelColor
        countdownLabel.alignment = .left
        countdownLabel.lineBreakMode = .byTruncatingTail
        countdownLabel.translatesAutoresizingMaskIntoConstraints = false

        let headerStack = NSStackView(views: [iconView, countdownLabel])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 8
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        setupActionButton(snooze1Button, title: "+1m", action: #selector(snooze1Clicked))
        setupActionButton(snooze5Button, title: "+5m", action: #selector(snooze5Clicked))
        setupActionButton(skipButton, title: "Skip", action: #selector(skipClicked))

        let buttonStack = NSStackView(views: [snooze1Button, snooze5Button, skipButton])
        buttonStack.orientation = .horizontal
        buttonStack.distribution = .fillEqually
        buttonStack.spacing = 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        visualEffectView.addSubview(headerStack)
        visualEffectView.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            visualEffectView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            visualEffectView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            visualEffectView.topAnchor.constraint(equalTo: contentView.topAnchor),
            visualEffectView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            headerStack.topAnchor.constraint(equalTo: visualEffectView.topAnchor, constant: 14),
            headerStack.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor, constant: 14),
            headerStack.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor, constant: -14),

            buttonStack.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 12),
            buttonStack.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor, constant: 14),
            buttonStack.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor, constant: -14),
            buttonStack.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor, constant: -12),
            buttonStack.heightAnchor.constraint(equalToConstant: 28)
        ])

        updateTexts()
    }

    private func setupActionButton(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureActionButton(_ button: NSButton, enabled: Bool, isPrimary: Bool) {
        button.isEnabled = enabled
        if enabled {
            button.alphaValue = 1.0
            button.contentTintColor = isPrimary ? .white : .labelColor
            button.layer?.backgroundColor = (isPrimary
                ? NSColor.controlAccentColor
                : NSColor.controlColor.withAlphaComponent(0.65)).cgColor
        } else {
            button.alphaValue = 0.45
            button.contentTintColor = .disabledControlTextColor
            button.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.25).cgColor
        }
    }

    private func updateTexts() {
        updateCountdown(lastRemainingSeconds)
        snooze1Button.title = localizer?("preBreakSnooze1") ?? "+1m"
        snooze5Button.title = localizer?("preBreakSnooze5") ?? "+5m"
        skipButton.title = localizer?("preBreakSkip") ?? "Skip"
    }

    private static func defaultFrame() -> NSRect {
        let visibleFrame = NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: visibleFrame.maxX - hudSize.width - 18,
            y: visibleFrame.maxY - hudSize.height - 14
        )
        return NSRect(origin: origin, size: hudSize)
    }

    @objc private func snooze1Clicked() {
        hudDelegate?.didRequestPreBreakSnooze(minutes: 1)
    }

    @objc private func snooze5Clicked() {
        hudDelegate?.didRequestPreBreakSnooze(minutes: 5)
    }

    @objc private func skipClicked() {
        hudDelegate?.didRequestPreBreakSkip()
    }
}
