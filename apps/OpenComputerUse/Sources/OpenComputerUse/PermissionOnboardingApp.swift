import AppKit
import ApplicationServices
import OpenComputerUseKit
import QuartzCore
import UniformTypeIdentifiers

@MainActor
enum PermissionOnboardingApp {
    private static var presentedWindowController: PermissionWindowController?

    static func launch() {
        guard !PermissionDiagnostics.current().allGranted else {
            return
        }

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.applicationIconImage = Branding.makeAppIconImage(size: 256)

        let delegate = PermissionOnboardingAppDelegate()
        application.delegate = delegate
        application.run()
    }

    static func present(terminateOnCompletion: Bool = true) {
        guard !PermissionDiagnostics.current().allGranted else {
            return
        }

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.applicationIconImage = Branding.makeAppIconImage(size: 256)

        let controller = PermissionWindowController(terminateOnCompletion: terminateOnCompletion)
        presentedWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class PermissionOnboardingAppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: PermissionWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = PermissionWindowController()
        windowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@MainActor
final class PermissionWindowController: NSWindowController {
    private let contentController = PermissionContentController()
    private lazy var accessoryPanelController = PermissionAccessoryPanelController { [weak self] in
        self?.handleAccessoryPanelBack()
    }
    private let terminateOnCompletion: Bool

    init(terminateOnCompletion: Bool = true) {
        self.terminateOnCompletion = terminateOnCompletion

        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: PermissionOnboardingLayout.windowWidth,
                height: PermissionOnboardingLayout.windowHeight
            ),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = PermissionSupport.currentBundleDisplayName()
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)

        contentViewController = contentController
        contentController.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

@MainActor
extension PermissionWindowController: PermissionContentControllerDelegate {
    func permissionContentController(
        _ controller: PermissionContentController,
        didRequestPermission permission: SystemPermissionKind,
        sourceFrameInScreen: CGRect?
    ) {
        if permission == .accessibility {
            PermissionSupport.requestAccessibilityPrompt()
        }

        PermissionSupport.openSystemSettings(for: permission)
        accessoryPanelController.show(for: permission, sourceFrameInScreen: sourceFrameInScreen)
        contentController.setActiveGuidance(permission)
    }

    func permissionContentControllerDidResolveGuidance(_ controller: PermissionContentController) {
        accessoryPanelController.hide()
    }

    func permissionContentControllerDidCompleteAllPermissions(_ controller: PermissionContentController) {
        accessoryPanelController.hide()
        close()
        if terminateOnCompletion {
            NSApp.terminate(nil)
        }
    }

    private func handleAccessoryPanelBack() {
        accessoryPanelController.hide()
        contentController.setActiveGuidance(nil)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }


}

@MainActor
protocol PermissionContentControllerDelegate: AnyObject {
    func permissionContentController(
        _ controller: PermissionContentController,
        didRequestPermission permission: SystemPermissionKind,
        sourceFrameInScreen: CGRect?
    )
    func permissionContentControllerDidResolveGuidance(_ controller: PermissionContentController)
    func permissionContentControllerDidCompleteAllPermissions(_ controller: PermissionContentController)
}

private enum PermissionOnboardingLayout {
    static let windowWidth: CGFloat = 596
    static let windowHeight: CGFloat = 440
    static let outerHorizontalInset: CGFloat = 32
    static let outerTopInset: CGFloat = 24
    static let outerBottomInset: CGFloat = 32
    static let headerIconSize: CGFloat = 72
    static let cardWidth: CGFloat = windowWidth - 2 * outerHorizontalInset
    static let cardHeight: CGFloat = 76
    static let cardCornerRadius: CGFloat = 16
    static let cardHorizontalInset: CGFloat = 20
    static let cardVerticalInset: CGFloat = 12
    static let cardIconSize: CGFloat = 38
    static let actionButtonWidth: CGFloat = 112
    static let actionButtonHeight: CGFloat = 36
}

@MainActor
final class PermissionContentController: NSViewController {
    weak var delegate: PermissionContentControllerDelegate?

    private let backgroundView = PermissionBackgroundView()
    private let stackView = NSStackView()
    private let iconView = AppGlyphView()
    private let titleLabel = NSTextField(labelWithString: "Set up \(PermissionSupport.currentBundleDisplayName())")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "Allow macOS permissions so \(PermissionSupport.currentBundleDisplayName()) can work in your apps when you ask.")
    private let cardsContainer = NSStackView()
    private let completionLabel = NSTextField(labelWithString: "All required permissions are enabled.")
    private let refreshTimerInterval: TimeInterval = 0.25

    private var activeGuidance: SystemPermissionKind?
    private var refreshTimer: Timer?
    private var diagnostics = PermissionDiagnostics.current()
    private var hasReportedCompletion = false
    private var renderedState: [CardState] = []

    private enum CardState {
        case granted, guidance, pending
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
        refreshUI()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshTimerInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshState()
            }
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        refreshTimer?.invalidate()
    }

    func setActiveGuidance(_ permission: SystemPermissionKind?) {
        activeGuidance = permission
        refreshUI()
    }

    private func refreshState() {
        let updated = PermissionDiagnostics.current()
        let previousGuidance = activeGuidance
        let wasAllGranted = diagnostics.allGranted
        diagnostics = updated

        if let activeGuidance, updated.isGranted(activeGuidance) {
            self.activeGuidance = nil
        }

        refreshUI()

        if previousGuidance != nil, activeGuidance == nil {
            delegate?.permissionContentControllerDidResolveGuidance(self)
        }

        if updated.allGranted, !wasAllGranted, !hasReportedCompletion {
            hasReportedCompletion = true
            delegate?.permissionContentControllerDidCompleteAllPermissions(self)
        }
    }

    private func configureUI() {
        view.wantsLayer = true

        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backgroundView)

        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 12
        stackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stackView)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 30, weight: .bold)
        titleLabel.textColor = NSColor.labelColor
        titleLabel.maximumNumberOfLines = 1
        subtitleLabel.font = NSFont.systemFont(ofSize: 15, weight: .regular)
        subtitleLabel.textColor = NSColor.secondaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.maximumNumberOfLines = 2

        cardsContainer.orientation = .vertical
        cardsContainer.alignment = .centerX
        cardsContainer.spacing = 8
        cardsContainer.translatesAutoresizingMaskIntoConstraints = false

        completionLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        completionLabel.textColor = NSColor(calibratedRed: 0.16, green: 0.50, blue: 0.23, alpha: 1)
        completionLabel.isHidden = true

        stackView.addArrangedSubview(iconView)
        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(subtitleLabel)
        stackView.addArrangedSubview(cardsContainer)
        stackView.addArrangedSubview(completionLabel)
        stackView.setCustomSpacing(10, after: iconView)
        stackView.setCustomSpacing(8, after: titleLabel)
        stackView.setCustomSpacing(20, after: subtitleLabel)
        stackView.setCustomSpacing(14, after: cardsContainer)

        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: view.topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: PermissionOnboardingLayout.outerHorizontalInset),
            stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -PermissionOnboardingLayout.outerHorizontalInset),
            stackView.topAnchor.constraint(equalTo: view.topAnchor, constant: PermissionOnboardingLayout.outerTopInset),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -PermissionOnboardingLayout.outerBottomInset),

            iconView.widthAnchor.constraint(equalToConstant: PermissionOnboardingLayout.headerIconSize),
            iconView.heightAnchor.constraint(equalToConstant: PermissionOnboardingLayout.headerIconSize),
            cardsContainer.widthAnchor.constraint(equalToConstant: PermissionOnboardingLayout.cardWidth),
        ])
    }

    private func refreshUI() {
        let orderedPermissions = SystemPermissionKind.allCases
        let states: [CardState] = orderedPermissions.map { permission in
            if diagnostics.isGranted(permission) { return .granted }
            if activeGuidance == permission { return .guidance }
            return .pending
        }
        guard states != renderedState else { return }
        renderedState = states

        cardsContainer.arrangedSubviews.forEach { subview in
            cardsContainer.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        for (permission, state) in zip(orderedPermissions, states) {
            if state == .guidance {
                let placeholder = GuidancePlaceholderView()
                cardsContainer.addArrangedSubview(placeholder)
                placeholder.widthAnchor.constraint(equalToConstant: PermissionOnboardingLayout.cardWidth).isActive = true
                continue
            }

            let card = PermissionCardView(permission: permission, diagnostics: diagnostics)
            card.onAllow = { [weak self] requestedPermission, sourceFrameInScreen in
                guard let self else {
                    return
                }

                self.delegate?.permissionContentController(
                    self,
                    didRequestPermission: requestedPermission,
                    sourceFrameInScreen: sourceFrameInScreen
                )
            }
            cardsContainer.addArrangedSubview(card)
            card.widthAnchor.constraint(equalToConstant: PermissionOnboardingLayout.cardWidth).isActive = true
        }

        completionLabel.isHidden = !diagnostics.allGranted
    }


}

@MainActor
final class PermissionCardView: NSView {
    var onAllow: ((SystemPermissionKind, CGRect?) -> Void)?

    private let permission: SystemPermissionKind
    private let diagnostics: PermissionDiagnostics
    private weak var actionButton: PrimaryActionButton?

    init(permission: SystemPermissionKind, diagnostics: PermissionDiagnostics) {
        self.permission = permission
        self.diagnostics = diagnostics
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func configure() {
        wantsLayer = true
        layer?.cornerRadius = PermissionOnboardingLayout.cardCornerRadius
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.24).cgColor

        let content = NSStackView()
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 16
        content.translatesAutoresizingMaskIntoConstraints = false

        let iconBackground = NSView()
        iconBackground.translatesAutoresizingMaskIntoConstraints = false
        iconBackground.wantsLayer = true
        iconBackground.layer?.cornerRadius = 10
        iconBackground.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentTintColor = .secondaryLabelColor
        icon.image = NSImage(systemSymbolName: permission.symbolName, accessibilityDescription: permission.title)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        iconBackground.addSubview(icon)

        let labels = NSStackView()
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2

        let title = NSTextField(labelWithString: permission == .accessibility ? "Accessibility" : "Screen Recording")
        title.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        title.textColor = NSColor.labelColor

        let purpose = permission == .accessibility
            ? "Click and type in macOS apps."
            : "See what’s on screen through screenshots."
        let subtitle = NSTextField(labelWithString: purpose)
        subtitle.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        subtitle.textColor = NSColor.secondaryLabelColor

        labels.addArrangedSubview(title)
        labels.addArrangedSubview(subtitle)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false

        content.addArrangedSubview(iconBackground)
        content.addArrangedSubview(labels)
        content.addArrangedSubview(spacer)

        if diagnostics.isGranted(permission) {
            let done = StatusChipView(text: "Done", foreground: NSColor(calibratedRed: 0.16, green: 0.50, blue: 0.23, alpha: 1), background: NSColor(calibratedRed: 0.93, green: 0.98, blue: 0.94, alpha: 1))
            content.addArrangedSubview(done)
        } else {
            let button = PrimaryActionButton(title: "Open Settings", target: self, action: #selector(handleAllow))
            actionButton = button
            content.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: PermissionOnboardingLayout.actionButtonWidth).isActive = true
            button.heightAnchor.constraint(equalToConstant: PermissionOnboardingLayout.actionButtonHeight).isActive = true
        }

        addSubview(content)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: PermissionOnboardingLayout.cardHeight),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PermissionOnboardingLayout.cardHorizontalInset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PermissionOnboardingLayout.cardHorizontalInset),
            content.topAnchor.constraint(equalTo: topAnchor, constant: PermissionOnboardingLayout.cardVerticalInset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -PermissionOnboardingLayout.cardVerticalInset),

            iconBackground.widthAnchor.constraint(equalToConstant: PermissionOnboardingLayout.cardIconSize),
            iconBackground.heightAnchor.constraint(equalToConstant: PermissionOnboardingLayout.cardIconSize),
            icon.centerXAnchor.constraint(equalTo: iconBackground.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBackground.centerYAnchor),
            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 12),
        ])
    }

    @objc
    private func handleAllow() {
        onAllow?(permission, actionButtonScreenFrame())
    }

    private func actionButtonScreenFrame() -> CGRect? {
        guard let actionButton, let window = actionButton.window else {
            return nil
        }

        let frameInWindow = actionButton.convert(actionButton.bounds, to: nil)
        return window.convertToScreen(frameInWindow)
    }
}

@MainActor
final class GuidancePlaceholderView: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = PermissionOnboardingLayout.cardCornerRadius
        layer?.backgroundColor = NSColor(calibratedWhite: 0.98, alpha: 0.6).cgColor

        let label = NSTextField(labelWithString: "Finish in System Settings")
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.textColor = NSColor.secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: PermissionOnboardingLayout.cardHeight),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let borderRect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(
            roundedRect: borderRect,
            xRadius: PermissionOnboardingLayout.cardCornerRadius,
            yRadius: PermissionOnboardingLayout.cardCornerRadius
        )
        path.setLineDash([6, 6], count: 2, phase: 0)
        path.lineWidth = 1.5
        NSColor(calibratedWhite: 0.82, alpha: 1).setStroke()
        path.stroke()
    }
}

@MainActor
final class PermissionAccessoryPanelController {
    private let onBack: () -> Void
    private let windowContextProvider: () -> SystemSettingsWindowContext?
    private let animationTimeProvider: () -> CFTimeInterval
    private let trackingInterval: TimeInterval = 0.15
    private let launchAnimationDuration: TimeInterval = 0.72
    private let launchAnimationResponse = 0.72
    private let launchAnimationDampingFraction = 1.0
    private let launchInitialAlpha: CGFloat = 0.9
    private var panel: NSPanel?
    private var currentPermission: SystemPermissionKind?
    private var workspaceObserver: NSObjectProtocol?
    private var globalDragMonitor: Any?
    private var localDragMonitor: Any?
    private var orderedWindowNumber: Int?
    private var trackingTimer: Timer?
    private var pendingSourceFrameInScreen: CGRect?
    private var didPresentCurrentPanel = false
    private var launchDisplayLink: CADisplayLink?
    private var launchStartTime: CFTimeInterval = 0
    private var launchFromFrame = NSRect.zero
    private var launchToFrame = NSRect.zero
    private var isAnimatingLaunch = false
    private var launchSettleGeneration = 0

    private enum Layout {
        static let panelWidth: CGFloat = 530
        static let panelHeight: CGFloat = 124
        static let screenHorizontalInset: CGFloat = 16
        static let screenBottomInset: CGFloat = 12
        static let windowBottomOverlap: CGFloat = 6
        static let contentLeadingInset: CGFloat = 26
        static let contentTrailingInset: CGFloat = 28
        static let sidebarWidthRatio: CGFloat = 0.29
        static let sidebarWidthMin: CGFloat = 214
        static let sidebarWidthMax: CGFloat = 272
    }

    struct SystemSettingsWindowContext {
        let bounds: CGRect
        let windowNumber: Int
        let permissionListFrame: CGRect?

        init(bounds: CGRect, windowNumber: Int, permissionListFrame: CGRect? = nil) {
            self.bounds = bounds
            self.windowNumber = windowNumber
            self.permissionListFrame = permissionListFrame
        }
    }

    init(
        onBack: @escaping () -> Void,
        windowContextProvider: (() -> SystemSettingsWindowContext?)? = nil,
        animationTimeProvider: @escaping () -> CFTimeInterval = CACurrentMediaTime
    ) {
        self.onBack = onBack
        let reader = PermissionSettingsWindowReader()
        self.windowContextProvider = windowContextProvider ?? { reader.context() }
        self.animationTimeProvider = animationTimeProvider
    }

    func show(for permission: SystemPermissionKind, sourceFrameInScreen: CGRect?) {
        currentPermission = permission
        pendingSourceFrameInScreen = sourceFrameInScreen
        didPresentCurrentPanel = false

        let panel = panel ?? makePanel()
        self.panel = panel

        if let contentView = panel.contentView as? PermissionAccessoryPanelView {
            contentView.configure(permission: permission)
        }

        installObserversIfNeeded()
        startTrackingTimer()
        updatePanelVisibility()
    }

    func hide() {
        stopLaunchAnimation()
        stopTrackingTimer()
        removeObservers()
        panel?.orderOut(nil)
        panel?.alphaValue = 1
        currentPermission = nil
        orderedWindowNumber = nil
        pendingSourceFrameInScreen = nil
        didPresentCurrentPanel = false
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Layout.panelWidth, height: Layout.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.contentView = PermissionAccessoryPanelView(onBack: onBack)
        return panel
    }

    private func installObserversIfNeeded() {
        if workspaceObserver == nil {
            workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updatePanelVisibility()
                    self?.refreshPosition()
                }
            }
        }

        if globalDragMonitor == nil {
            globalDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshPosition()
                }
            }
        }

        if localDragMonitor == nil {
            localDragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.refreshPosition()
                }
                return event
            }
        }
    }

    private func removeObservers() {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }

        if let globalDragMonitor {
            NSEvent.removeMonitor(globalDragMonitor)
            self.globalDragMonitor = nil
        }

        if let localDragMonitor {
            NSEvent.removeMonitor(localDragMonitor)
            self.localDragMonitor = nil
        }
    }

    private func startTrackingTimer() {
        stopTrackingTimer()
        let timer = Timer(timeInterval: trackingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        timer.tolerance = 0.03
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
    }

    private func stopTrackingTimer() {
        trackingTimer?.invalidate()
        trackingTimer = nil
    }

    func refresh() {
        updatePanelVisibility()
        refreshPosition()
    }

    private func refreshPosition() {
        guard let panel, currentPermission != nil, panel.isVisible,
              let windowContext = windowContextProvider() else {
            return
        }

        position(panel: panel, windowContext: windowContext)
    }

    private func updatePanelVisibility() {
        guard let panel, currentPermission != nil else {
            return
        }

        guard let windowContext = windowContextProvider() else {
            stopLaunchAnimation()
            panel.orderOut(nil)
            return
        }

        let panelWasVisible = panel.isVisible

        if didPresentCurrentPanel == false {
            presentPanel(
                panel: panel,
                from: pendingSourceFrameInScreen,
                relativeTo: windowContext
            )
            didPresentCurrentPanel = true
        } else {
            let previousOrderedWindowNumber = orderedWindowNumber
            orderedWindowNumber = windowContext.windowNumber
            position(panel: panel, windowContext: windowContext)
            if !isAnimatingLaunch {
                panel.alphaValue = 1
            }
            if previousOrderedWindowNumber != windowContext.windowNumber || panelWasVisible == false {
                panel.order(.above, relativeTo: windowContext.windowNumber)
            }
        }

    }

    private func position(panel: NSPanel, windowContext: SystemSettingsWindowContext) {
        guard let origin = preferredPanelOrigin(
            for: panelSize(for: windowContext),
            windowContext: windowContext
        ) else {
            return
        }

        if isAnimatingLaunch {
            launchToFrame = NSRect(origin: origin, size: panelSize(for: windowContext))
            return
        }

        // A hidden panel may retain an interrupted animation's smaller frame.
        let targetFrame = NSRect(origin: origin, size: panelSize(for: windowContext))
        if panel.frame != targetFrame {
            panel.setFrame(targetFrame, display: true)
        }
    }

    private func presentPanel(
        panel: NSPanel,
        from sourceFrameInScreen: CGRect?,
        relativeTo windowContext: SystemSettingsWindowContext
    ) {
        guard let targetOrigin = preferredPanelOrigin(
            for: panelSize(for: windowContext),
            windowContext: windowContext
        ) else {
            return
        }

        let targetFrame = NSRect(origin: targetOrigin, size: panelSize(for: windowContext))
        orderedWindowNumber = windowContext.windowNumber

        guard let sourceFrameInScreen, sourceFrameInScreen.isEmpty == false else {
            stopLaunchAnimation()
            panel.alphaValue = 1
            panel.setFrame(targetFrame, display: false)
            panel.order(.above, relativeTo: windowContext.windowNumber)
            return
        }

        stopLaunchAnimation()
        isAnimatingLaunch = true
        launchFromFrame = sourceFrameInScreen
        launchToFrame = targetFrame
        launchStartTime = animationTimeProvider()
        launchSettleGeneration += 1

        panel.alphaValue = launchInitialAlpha
        panel.setFrame(sourceFrameInScreen, display: false)
        panel.order(.above, relativeTo: windowContext.windowNumber)
        stepLaunchAnimation()

        let displayLink = panel.displayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
        displayLink.add(to: .main, forMode: .common)
        launchDisplayLink = displayLink
        scheduleLaunchSettlePasses(for: launchSettleGeneration)
    }

    @objc
    private func displayLinkDidFire(_ displayLink: CADisplayLink) {
        stepLaunchAnimation()
    }

    func stepLaunchAnimation() {
        guard let panel else {
            stopLaunchAnimation()
            return
        }

        let elapsed = max(0, animationTimeProvider() - launchStartTime)
        if elapsed >= launchAnimationDuration {
            isAnimatingLaunch = false
            stopLaunchAnimation()
            panel.alphaValue = 1
            updateLaunchTargetFrameIfNeeded()
            panel.setFrame(launchToFrame, display: true)
            if let orderedWindowNumber {
                panel.order(.above, relativeTo: orderedWindowNumber)
            }
            return
        }

        let progress = springProgress(at: elapsed)
        panel.alphaValue = launchInitialAlpha + ((1 - launchInitialAlpha) * progress)
        panel.setFrame(curvedFrame(from: launchFromFrame, to: launchToFrame, progress: progress), display: true)
        if let orderedWindowNumber {
            panel.order(.above, relativeTo: orderedWindowNumber)
        }
    }

    private func stopLaunchAnimation() {
        isAnimatingLaunch = false
        launchDisplayLink?.invalidate()
        launchDisplayLink = nil
    }

    private func updateLaunchTargetFrameIfNeeded() {
        guard
            let windowContext = windowContextProvider(),
            let origin = preferredPanelOrigin(for: panelSize(for: windowContext), windowContext: windowContext)
        else {
            return
        }

        orderedWindowNumber = windowContext.windowNumber
        launchToFrame = NSRect(origin: origin, size: panelSize(for: windowContext))
    }

    private func scheduleLaunchSettlePasses(for generation: Int) {
        let delays: [TimeInterval] = [0.18, 0.42, 0.84, 1.2]

        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.currentPermission != nil, self.launchSettleGeneration == generation else {
                        return
                    }
                    self.updatePanelVisibility()
                    self.refreshPosition()
                }
            }
        }
    }

    private func springProgress(at elapsed: TimeInterval) -> CGFloat {
        let omega = (2 * Double.pi) / launchAnimationResponse
        let t = max(0, elapsed)
        let progress: Double

        if abs(launchAnimationDampingFraction - 1) < 0.0001 {
            progress = 1 - exp(-omega * t) * (1 + (omega * t))
        } else {
            progress = min(1, t / launchAnimationDuration)
        }

        return min(max(progress, 0), 1)
    }

    private func curvedFrame(from: NSRect, to: NSRect, progress: CGFloat) -> NSRect {
        let size = NSSize(
            width: from.size.width + ((to.size.width - from.size.width) * progress),
            height: from.size.height + ((to.size.height - from.size.height) * progress)
        )

        let startCenter = CGPoint(x: from.midX, y: from.midY)
        let endCenter = CGPoint(x: to.midX, y: to.midY)
        let midPoint = CGPoint(
            x: (startCenter.x + endCenter.x) * 0.5,
            y: max(startCenter.y, endCenter.y)
        )
        let distance = hypot(endCenter.x - startCenter.x, endCenter.y - startCenter.y)
        let lift = min(140, max(44, distance * 0.18))
        let controlPoint = CGPoint(x: midPoint.x, y: midPoint.y + lift)
        let inverse = 1 - progress
        let center = CGPoint(
            x: (inverse * inverse * startCenter.x) + (2 * inverse * progress * controlPoint.x) + (progress * progress * endCenter.x),
            y: (inverse * inverse * startCenter.y) + (2 * inverse * progress * controlPoint.y) + (progress * progress * endCenter.y)
        )

        return NSRect(
            x: center.x - (size.width * 0.5),
            y: center.y - (size.height * 0.5),
            width: size.width,
            height: size.height
        )
    }

    private func panelSize(for context: SystemSettingsWindowContext) -> CGSize {
        CGSize(width: min(Layout.panelWidth, context.permissionListFrame?.width ?? Layout.panelWidth), height: Layout.panelHeight)
    }

    private func preferredPanelOrigin(
        for panelSize: CGSize,
        windowContext: SystemSettingsWindowContext
    ) -> CGPoint? {
        let referenceRect = windowContext.permissionListFrame ?? windowContext.bounds
        let visibleFrame = targetVisibleScreenFrame(for: referenceRect) ?? windowContext.bounds
        let trackRect = windowContext.permissionListFrame ?? systemSettingsContentTrackRect(in: windowContext.bounds)
        let x = clamp(
            trackRect.midX - (panelSize.width / 2),
            lower: visibleFrame.minX + Layout.screenHorizontalInset,
            upper: visibleFrame.maxX - panelSize.width - Layout.screenHorizontalInset
        )
        let edgeOffset = windowContext.permissionListFrame == nil ? Layout.windowBottomOverlap : -8
        let desiredY = referenceRect.minY - panelSize.height + edgeOffset
        let y = max(
            visibleFrame.minY + Layout.screenBottomInset,
            desiredY
        )
        return CGPoint(x: x, y: y)
    }

    private func systemSettingsContentTrackRect(in windowBounds: CGRect) -> CGRect {
        // Fallback when Accessibility cannot provide the list controls.
        let sidebarWidth = clamp(
            windowBounds.width * Layout.sidebarWidthRatio,
            lower: Layout.sidebarWidthMin,
            upper: Layout.sidebarWidthMax
        )
        let contentMinX = min(
            windowBounds.maxX - Layout.contentTrailingInset - 1,
            windowBounds.minX + sidebarWidth + Layout.contentLeadingInset
        )
        let contentMaxX = max(contentMinX + 1, windowBounds.maxX - Layout.contentTrailingInset)
        return CGRect(
            x: contentMinX,
            y: windowBounds.minY,
            width: contentMaxX - contentMinX,
            height: windowBounds.height
        )
    }

    private func targetVisibleScreenFrame(for rect: CGRect) -> CGRect? {
        NSScreen.screens.filter { $0.visibleFrame.intersects(rect) }.max {
            let left = $0.visibleFrame.intersection(rect)
            let right = $1.visibleFrame.intersection(rect)
            return left.width * left.height < right.width * right.height
        }?.visibleFrame
    }

    private func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard lower <= upper else {
            return lower
        }

        return min(max(value, lower), upper)
    }
}

@MainActor
final class PermissionAccessoryPanelView: NSView {
    private let onBack: () -> Void
    private let instructionLabel = NSTextField(labelWithString: "")
    private let manualLabel = NSTextField(wrappingLabelWithString: "")
    private let dragTileView = DraggableAppTileView()

    init(onBack: @escaping () -> Void) {
        self.onBack = onBack
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
    }

    private func setup() {
        let materialView = NSVisualEffectView()
        materialView.translatesAutoresizingMaskIntoConstraints = false
        materialView.material = .popover
        materialView.blendingMode = .behindWindow
        materialView.state = .active
        materialView.wantsLayer = true
        materialView.layer?.cornerRadius = 20
        materialView.layer?.masksToBounds = true
        materialView.layer?.borderWidth = 0.5
        materialView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.18).cgColor
        addSubview(materialView)

        let backButton = AccessoryBackButton(target: self, action: #selector(handleBack))
        materialView.addSubview(backButton)

        let arrow = NSImageView()
        arrow.translatesAutoresizingMaskIntoConstraints = false
        arrow.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)
        arrow.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        arrow.contentTintColor = Branding.permissionAccent
        arrow.setAccessibilityElement(false)

        instructionLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        instructionLabel.textColor = .labelColor
        instructionLabel.translatesAutoresizingMaskIntoConstraints = false
        instructionLabel.lineBreakMode = .byTruncatingTail
        instructionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        manualLabel.font = NSFont.systemFont(ofSize: 11)
        manualLabel.textColor = .secondaryLabelColor
        manualLabel.translatesAutoresizingMaskIntoConstraints = false
        manualLabel.maximumNumberOfLines = 2
        manualLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        dragTileView.translatesAutoresizingMaskIntoConstraints = false
        materialView.addSubview(arrow)
        materialView.addSubview(instructionLabel)
        materialView.addSubview(dragTileView)
        materialView.addSubview(manualLabel)

        NSLayoutConstraint.activate([
            materialView.leadingAnchor.constraint(equalTo: leadingAnchor),
            materialView.trailingAnchor.constraint(equalTo: trailingAnchor),
            materialView.topAnchor.constraint(equalTo: topAnchor),
            materialView.bottomAnchor.constraint(equalTo: bottomAnchor),

            backButton.leadingAnchor.constraint(equalTo: materialView.leadingAnchor, constant: 12),
            backButton.centerYAnchor.constraint(equalTo: dragTileView.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 30),
            backButton.heightAnchor.constraint(equalToConstant: 30),

            arrow.leadingAnchor.constraint(equalTo: dragTileView.leadingAnchor),
            arrow.centerYAnchor.constraint(equalTo: instructionLabel.centerYAnchor),
            arrow.widthAnchor.constraint(equalToConstant: 15),
            arrow.heightAnchor.constraint(equalToConstant: 15),

            instructionLabel.leadingAnchor.constraint(equalTo: arrow.trailingAnchor, constant: 7),
            instructionLabel.topAnchor.constraint(equalTo: materialView.topAnchor, constant: 13),
            instructionLabel.trailingAnchor.constraint(equalTo: materialView.trailingAnchor, constant: -14),

            dragTileView.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 6),
            dragTileView.trailingAnchor.constraint(equalTo: materialView.trailingAnchor, constant: -14),
            dragTileView.topAnchor.constraint(equalTo: instructionLabel.bottomAnchor, constant: 7),
            dragTileView.heightAnchor.constraint(equalToConstant: 42),

            manualLabel.leadingAnchor.constraint(equalTo: dragTileView.leadingAnchor),
            manualLabel.trailingAnchor.constraint(equalTo: dragTileView.trailingAnchor),
            manualLabel.topAnchor.constraint(equalTo: dragTileView.bottomAnchor, constant: 6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(permission: SystemPermissionKind) {
        let pane = permission == .accessibility ? "Accessibility" : "Screen & System Audio Recording"
        let app = PermissionSupport.currentBundleDisplayName()
        instructionLabel.stringValue = "Drag \(app) into \(pane)"
        manualLabel.stringValue = permission == .accessibility
            ? "Already on? Remove the old entry with −, then add the app again with +."
            : "You can also add the app with +. If prompted, choose Quit & Reopen."
    }

    @objc
    private func handleBack() {
        onBack()
    }
}

@MainActor
final class DraggableAppTileView: NSView, NSDraggingSource {
    private let title = PermissionSupport.currentBundleDisplayName()
    private let icon = Branding.makeAppIconImage(size: 96)
    private var pointerInside = false
    private var hoverTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
        setAccessibilityHelp("Drag this app to the list in System Settings, or use the plus button there.")
        toolTip = "Drag \(title) into System Settings"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        needsDisplay = true
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.openHand.set()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        let tile = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        (pointerInside ? Branding.permissionAccent.withAlphaComponent(0.14) : NSColor.controlBackgroundColor).setFill()
        tile.fill()
        (pointerInside ? Branding.permissionAccent : NSColor.separatorColor).setStroke()
        tile.stroke()

        icon.draw(in: CGRect(x: 8, y: 5, width: 32, height: 32))

        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ]
        title.draw(in: CGRect(x: 46, y: 11, width: max(0, bounds.width - 82), height: 20), withAttributes: attributes)

        let grip = NSBezierPath()
        for x in [bounds.width - 24, bounds.width - 19] {
            for y in [15.0, 20.0, 25.0] {
                grip.appendOval(in: CGRect(x: x, y: y, width: 2.5, height: 2.5))
            }
        }
        (pointerInside ? Branding.permissionAccent : NSColor.secondaryLabelColor).setFill()
        grip.fill()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let bundleURL = PermissionSupport.currentAppBundleURL() else {
            NSSound.beep()
            return
        }

        let draggingItem = NSDraggingItem(pasteboardWriter: bundleURL as NSURL)
        draggingItem.setDraggingFrame(bounds, contents: snapshotImage() ?? icon)
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        pointerInside = false
        needsDisplay = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    private func snapshotImage() -> NSImage? {
        guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: bitmap)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmap)
        return image
    }
}

@MainActor
enum Branding {
    static var permissionAccent: NSColor {
        PermissionSupport.currentBundleDisplayName() == PermissionSupport.developmentBundleDisplayName
            ? .systemRed : .controlAccentColor
    }

    static func makeAppIconImage(size: CGFloat) -> NSImage {
        let dimensions = NSSize(width: size, height: size)
        guard let bundleURL = PermissionSupport.currentAppBundleURL() else {
            let image = NSWorkspace.shared.icon(for: .applicationBundle)
            image.size = dimensions
            return image
        }

        // Use the same artwork as the selected app bundle, including the GODSPEED variant.
        let image: NSImage
        if let bundle = Bundle(url: bundleURL),
           let iconFile = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
           let resourceURL = bundle.resourceURL {
            let filename = iconFile.hasSuffix(".icns") ? iconFile : iconFile + ".icns"
            image = NSImage(contentsOf: resourceURL.appendingPathComponent(filename))
                ?? NSWorkspace.shared.icon(forFile: bundleURL.path)
        } else {
            image = NSWorkspace.shared.icon(forFile: bundleURL.path)
        }
        image.size = dimensions
        return image
    }
}

@MainActor
final class PermissionBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(rect: dirtyRect).fill()
    }
}

@MainActor
final class AppGlyphView: NSImageView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        image = Branding.makeAppIconImage(size: PermissionOnboardingLayout.headerIconSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

@MainActor
final class StatusChipView: NSView {
    init(text: String, foreground: NSColor, background: NSColor) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.backgroundColor = background.cgColor

        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        label.textColor = foreground
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let check = NSImageView()
        check.translatesAutoresizingMaskIntoConstraints = false
        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: text)
        check.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        check.contentTintColor = foreground
        addSubview(check)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            check.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

@MainActor
final class PrimaryActionButton: NSButton {
    override var isHighlighted: Bool {
        didSet {
            updateAppearance()
        }
    }

    init(title: String, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        self.title = title
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        isBordered = false
        focusRingType = .default
        setButtonType(.momentaryPushIn)
        updateAttributedTitle()
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = 9
    }

    private func updateAttributedTitle() {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraphStyle,
            ]
        )
    }

    private func updateAppearance() {
        let accent = Branding.permissionAccent
        layer?.backgroundColor = (isHighlighted ? accent.blended(withFraction: 0.16, of: .black) ?? accent : accent).cgColor
        alphaValue = isEnabled ? 1 : 0.45
    }
}

@MainActor
final class AccessoryBackButton: NSButton {
    override var isHighlighted: Bool {
        didSet {
            alphaValue = isHighlighted ? 0.66 : 1
        }
    }

    init(target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        focusRingType = .default
        image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        setAccessibilityLabel("Back to permissions")
        toolTip = "Back to permissions"
        contentTintColor = NSColor.labelColor.withAlphaComponent(0.72)
        if let cell = cell as? NSButtonCell {
            cell.imagePosition = .imageOnly
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
