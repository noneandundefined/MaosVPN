import AppKit
import MaosVPNCore

final class MainViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
    fileprivate enum LatencyState: Equatable {
        case testing
        case reachable(Int)
        case unavailable
    }

    let vpnController = VPNController()
    private let subscriptionService = SubscriptionService()
    private let defaults = UserDefaults.standard
    private let libraryKey = "subscriptionLibraryV2"
    private let autoConnectKey = "autoConnectOnLaunch"
    private let invisibleModeKey = "invisibleMode"
    private let selectedProfileKey = "selectedProfileID"

    private var subscriptions: [SubscriptionEntry] = []
    private var libraryWasLoaded = false
    private var subscriptionRequestInProgress = false
    private var suppressSelectionSave = false
    private var didApplyLaunchPreferences = false

    private let outlineView = NSOutlineView()
    private weak var serverScroll: NSScrollView?
    private let searchField = NSSearchField()
    private let languagePopup = NSPopUpButton()
    private let addSubscriptionButton = NSButton()
    private let autoSwitch = NSSwitch()
    private let invisibleSwitch = NSSwitch()
    private let statusLabel = NSTextField(labelWithString: L10n.text(.disconnected))
    private let connectionSubtitleLabel = NSTextField(labelWithString: "")
    private let selectedFlagLabel = NSTextField(labelWithString: "")
    private let selectedNameLabel = NSTextField(labelWithString: L10n.text(.addSubscription))
    private let selectedDetailsLabel = NSTextField(labelWithString: L10n.text(.serversWillAppear))
    private let protocolValueLabel = NSTextField(labelWithString: "—")
    private let selectedLatencyLabel = NSTextField(labelWithString: "—")
    private let selectedDot = DotView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let connectButton = PowerButton(title: "", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let onboardingURLField = NSTextField()
    private let onboardingAddButton = NSButton()
    private var pingMenuItem: NSMenuItem?
    private var fastestMenuItem: NSMenuItem?

    private var latencyByProfileID: [UUID: LatencyState] = [:]
    private var latencyTestID = UUID()
    private var latencyTestInProgress = false
    private var selectFastestWhenFinished = false
    private let latencyOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "app.maosvpn.latency"
        queue.maxConcurrentOperationCount = 3
        queue.qualityOfService = .utility
        return queue
    }()

    private weak var starredNode: ProfileNode?
    private var connectedSince: Date?
    private var connectionTimer: Timer?
    private var searchQuery = ""

    private var selectedNode: ProfileNode? {
        let row = outlineView.selectedRow
        return row >= 0 ? outlineView.item(atRow: row) as? ProfileNode : nil
    }

    private var selectedProfile: VPNProfile? { selectedNode?.profile }
    private var allNodes: [ProfileNode] { subscriptions.flatMap(\.profileNodes) }
    private var allProfiles: [VPNProfile] { subscriptions.flatMap(\.profiles) }
    private var isShowingOnboarding: Bool { subscriptions.isEmpty }
    private var visibleSubscriptions: [SubscriptionEntry] {
        guard !searchQuery.isEmpty else { return subscriptions }
        return subscriptions.filter { !$0.filteredNodes(matching: searchQuery).isEmpty }
    }

    override func loadView() {
        if !libraryWasLoaded {
            restoreLibrary()
            libraryWasLoaded = true
        }
        view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 460))
        buildCurrentInterface()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureControllerCallbacks()
        updateState(vpnController.isConnected ? .connected : .disconnected)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !didApplyLaunchPreferences else { return }
        didApplyLaunchPreferences = true
        let profile = selectedProfile
        let shouldConnect = !isShowingOnboarding
            && defaults.bool(forKey: autoConnectKey)
            && vpnController.state == .disconnected
            && profile != nil
        if shouldConnect, let profile = profile {
            vpnController.connect(profile: profile) { [weak self] error in
                if let error = error { self?.showError(error) }
                self?.applyInvisibleMode()
            }
        } else {
            applyInvisibleMode()
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard let scroll = serverScroll, let column = outlineView.tableColumns.first else { return }
        let width = scroll.contentSize.width
        if width > 1, abs(column.width - width) > 0.5 {
            column.width = width
        }
    }

    deinit {
        connectionTimer?.invalidate()
        latencyOperationQueue.cancelAllOperations()
    }

    private func buildCurrentInterface() {
        serverScroll = nil
        view.subviews.forEach { $0.removeFromSuperview() }
        if isShowingOnboarding {
            buildOnboardingInterface()
        } else {
            buildMainInterface()
        }
    }

    private func buildOnboardingInterface() {
        configureLanguagePopup()
        let brandIcon = NSImageView()
        brandIcon.image = NSApp.applicationIconImage
        brandIcon.imageScaling = .scaleProportionallyUpOrDown
        let title = NSTextField(labelWithString: AppLanguage.text(
            russian: "Добавьте первую подписку",
            english: "Add your first subscription"
        ))
        title.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        title.alignment = .center
        let subtitle = NSTextField(wrappingLabelWithString: AppLanguage.text(
            russian: "Вставьте ссылку — серверы сохранятся локально, а сама ссылка больше не будет показана в приложении.",
            english: "Paste a URL. Servers will be stored locally and the URL will no longer be shown in the app."
        ))
        subtitle.font = NSFont.systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        onboardingURLField.placeholderString = "https://example.com/sub/..."
        onboardingURLField.delegate = self
        onboardingAddButton.title = AppLanguage.text(russian: "Добавить подписку", english: "Add subscription")
        onboardingAddButton.bezelStyle = .rounded
        onboardingAddButton.target = self
        onboardingAddButton.action = #selector(importInitialSubscription)
        onboardingAddButton.keyEquivalent = "\r"
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        messageLabel.font = NSFont.systemFont(ofSize: 12)
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 3
        messageLabel.preferredMaxLayoutWidth = 420
        [languagePopup, brandIcon, title, subtitle, onboardingURLField, onboardingAddButton, progress, messageLabel].forEach {
            view.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            languagePopup.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            languagePopup.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            brandIcon.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            brandIcon.bottomAnchor.constraint(equalTo: title.topAnchor, constant: -10),
            brandIcon.widthAnchor.constraint(equalToConstant: 64),
            brandIcon.heightAnchor.constraint(equalToConstant: 64),
            title.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -70),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            subtitle.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            subtitle.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            onboardingURLField.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 16),
            onboardingURLField.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            onboardingURLField.widthAnchor.constraint(equalToConstant: 360),
            onboardingAddButton.topAnchor.constraint(equalTo: onboardingURLField.bottomAnchor, constant: 12),
            onboardingAddButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            progress.leadingAnchor.constraint(equalTo: onboardingAddButton.trailingAnchor, constant: 8),
            progress.centerYAnchor.constraint(equalTo: onboardingAddButton.centerYAnchor),
            messageLabel.topAnchor.constraint(equalTo: onboardingAddButton.bottomAnchor, constant: 10),
            messageLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        ])
    }

    private func buildMainInterface() {
        let header = makeHeader()
        let sidebar = makeSidebar()
        let content = makeMainContent()
        let columnLine = NSBox()
        columnLine.boxType = .separator
        [header, sidebar, content, columnLine].forEach {
            view.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 36),
            sidebar.topAnchor.constraint(equalTo: header.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 248),
            columnLine.topAnchor.constraint(equalTo: header.bottomAnchor),
            columnLine.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            columnLine.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            columnLine.widthAnchor.constraint(equalToConstant: 1),
            content.topAnchor.constraint(equalTo: header.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: columnLine.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        suppressSelectionSave = true
        outlineView.reloadData()
        visibleSubscriptions.forEach { outlineView.expandItem($0) }
        suppressSelectionSave = false
        restoreSelection()
        updateState(vpnController.state)
    }

    private func makeHeader() -> NSView {
        let container = NSView()
        let brandIcon = NSImageView()
        brandIcon.image = NSApp.applicationIconImage
        brandIcon.imageScaling = .scaleProportionallyUpOrDown
        searchField.placeholderString = AppLanguage.text(russian: "Поиск стран или городов...", english: "Search countries or cities...")
        searchField.stringValue = searchQuery
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.sendsSearchStringImmediately = true
        searchField.controlSize = .small
        configureLanguagePopup()
        addSubscriptionButton.title = AppLanguage.text(russian: "Добавить подписку", english: "Add subscription")
        addSubscriptionButton.bezelStyle = .rounded
        addSubscriptionButton.controlSize = .small
        addSubscriptionButton.target = self
        addSubscriptionButton.action = #selector(showAddSubscriptionDialog)
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        let divider = NSBox()
        divider.boxType = .separator
        [brandIcon, searchField, progress, languagePopup, addSubscriptionButton, divider].forEach {
            container.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            brandIcon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            brandIcon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            brandIcon.widthAnchor.constraint(equalToConstant: 24),
            brandIcon.heightAnchor.constraint(equalToConstant: 24),
            searchField.leadingAnchor.constraint(equalTo: brandIcon.trailingAnchor, constant: 6),
            searchField.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 180),
            progress.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 6),
            progress.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            languagePopup.trailingAnchor.constraint(equalTo: addSubscriptionButton.leadingAnchor, constant: -8),
            languagePopup.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            languagePopup.widthAnchor.constraint(equalToConstant: 110),
            addSubscriptionButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            addSubscriptionButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1)
        ])
        return container
    }

    private func configureLanguagePopup() {
        languagePopup.removeAllItems()
        languagePopup.addItems(withTitles: ["Русский", "English"])
        languagePopup.selectItem(at: AppLanguage.current == .russian ? 0 : 1)
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged(_:))
        languagePopup.controlSize = .small
    }

    private func makeSidebar() -> NSView {
        let container = NSView()
        let column: NSTableColumn
        if let existing = outlineView.tableColumns.first {
            column = existing
        } else {
            column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("server"))
            outlineView.addTableColumn(column)
            outlineView.outlineTableColumn = column
        }
        column.resizingMask = .autoresizingMask
        outlineView.headerView = nil
        outlineView.selectionHighlightStyle = .regular
        outlineView.indentationPerLevel = 12
        outlineView.focusRingType = .none
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.menu = makeServerMenu()
        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        serverScroll = scroll
        container.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func makeServerMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        let ping = menu.addItem(withTitle: L10n.text(.testPing), action: #selector(testPing), keyEquivalent: "")
        ping.target = self
        let fastest = menu.addItem(withTitle: L10n.text(.autoSelect), action: #selector(autoSelectFastest), keyEquivalent: "")
        fastest.target = self
        pingMenuItem = ping
        fastestMenuItem = fastest
        return menu
    }

    private func makeMainContent() -> NSView {
        let container = NSView()
        let toggles = makeToggleRow()
        let topLine = NSBox()
        topLine.boxType = .separator

        selectedFlagLabel.font = NSFont.systemFont(ofSize: 18)
        selectedFlagLabel.alignment = .center
        selectedNameLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        selectedNameLabel.lineBreakMode = .byTruncatingTail
        selectedNameLabel.maximumNumberOfLines = 1
        selectedDetailsLabel.font = NSFont.systemFont(ofSize: 11)
        selectedDetailsLabel.textColor = .secondaryLabelColor
        selectedDetailsLabel.lineBreakMode = .byTruncatingTail
        selectedDetailsLabel.maximumNumberOfLines = 1
        selectedLatencyLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        selectedLatencyLabel.textColor = .secondaryLabelColor
        selectedLatencyLabel.alignment = .right
        protocolValueLabel.font = NSFont.systemFont(ofSize: 13)
        let protocolCaption = NSTextField(labelWithString: AppLanguage.text(russian: "Протокол", english: "Protocol"))
        protocolCaption.font = NSFont.systemFont(ofSize: 11)
        protocolCaption.textColor = .secondaryLabelColor

        connectButton.target = self
        connectButton.action = #selector(toggleConnection)
        statusLabel.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        statusLabel.alignment = .center
        connectionSubtitleLabel.font = NSFont.systemFont(ofSize: 12)
        connectionSubtitleLabel.textColor = .secondaryLabelColor
        connectionSubtitleLabel.alignment = .center
        messageLabel.font = NSFont.systemFont(ofSize: 11)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 2
        messageLabel.preferredMaxLayoutWidth = 360

        [connectButton, statusLabel, connectionSubtitleLabel, messageLabel, topLine, selectedFlagLabel, selectedNameLabel, selectedDetailsLabel, selectedDot, selectedLatencyLabel, protocolCaption, protocolValueLabel, toggles].forEach {
            container.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        let messageGap = messageLabel.bottomAnchor.constraint(lessThanOrEqualTo: selectedFlagLabel.topAnchor, constant: -8)
        messageGap.priority = .defaultHigh
        NSLayoutConstraint.activate([
            connectButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            connectButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            connectButton.widthAnchor.constraint(equalToConstant: 200),
            connectButton.heightAnchor.constraint(equalToConstant: 200),
            statusLabel.topAnchor.constraint(equalTo: connectButton.bottomAnchor, constant: 2),
            messageGap,
            statusLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            connectionSubtitleLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 2),
            connectionSubtitleLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            messageLabel.topAnchor.constraint(equalTo: connectionSubtitleLabel.bottomAnchor, constant: 4),
            messageLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            messageLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            toggles.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            toggles.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            toggles.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            toggles.heightAnchor.constraint(equalToConstant: 36),
            protocolCaption.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            protocolCaption.bottomAnchor.constraint(equalTo: toggles.topAnchor, constant: -10),
            protocolValueLabel.leadingAnchor.constraint(equalTo: protocolCaption.trailingAnchor, constant: 8),
            protocolValueLabel.centerYAnchor.constraint(equalTo: protocolCaption.centerYAnchor),
            protocolValueLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            topLine.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            topLine.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            topLine.bottomAnchor.constraint(equalTo: protocolCaption.topAnchor, constant: -8),
            topLine.heightAnchor.constraint(equalToConstant: 1),
            selectedFlagLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            selectedFlagLabel.bottomAnchor.constraint(equalTo: topLine.topAnchor, constant: -8),
            selectedFlagLabel.widthAnchor.constraint(equalToConstant: 28),
            selectedNameLabel.leadingAnchor.constraint(equalTo: selectedFlagLabel.trailingAnchor, constant: 8),
            selectedNameLabel.bottomAnchor.constraint(equalTo: selectedFlagLabel.centerYAnchor, constant: -1),
            selectedNameLabel.trailingAnchor.constraint(lessThanOrEqualTo: selectedDot.leadingAnchor, constant: -8),
            selectedDetailsLabel.leadingAnchor.constraint(equalTo: selectedNameLabel.leadingAnchor),
            selectedDetailsLabel.topAnchor.constraint(equalTo: selectedNameLabel.bottomAnchor, constant: 1),
            selectedDetailsLabel.trailingAnchor.constraint(lessThanOrEqualTo: selectedDot.leadingAnchor, constant: -8),
            selectedDot.trailingAnchor.constraint(equalTo: selectedLatencyLabel.leadingAnchor, constant: -5),
            selectedDot.centerYAnchor.constraint(equalTo: selectedFlagLabel.centerYAnchor),
            selectedDot.widthAnchor.constraint(equalToConstant: 7),
            selectedDot.heightAnchor.constraint(equalToConstant: 7),
            selectedLatencyLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            selectedLatencyLabel.centerYAnchor.constraint(equalTo: selectedFlagLabel.centerYAnchor)
        ])
        return container
    }

    private func makeToggleRow() -> NSView {
        let row = NSView()
        autoSwitch.state = defaults.bool(forKey: autoConnectKey) ? .on : .off
        autoSwitch.target = self
        autoSwitch.action = #selector(autoConnectChanged(_:))
        invisibleSwitch.state = defaults.bool(forKey: invisibleModeKey) ? .on : .off
        invisibleSwitch.target = self
        invisibleSwitch.action = #selector(invisibleModeChanged(_:))
        let left = switchColumn(
            title: AppLanguage.text(russian: "Автоподключение", english: "Auto-connect"),
            toggle: autoSwitch
        )
        let right = switchColumn(
            title: AppLanguage.text(russian: "Скрыть в Dock", english: "Hide from Dock"),
            toggle: invisibleSwitch
        )
        [left, right].forEach {
            row.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            left.topAnchor.constraint(equalTo: row.topAnchor),
            left.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 12),
            right.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            right.topAnchor.constraint(equalTo: row.topAnchor),
            right.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            right.widthAnchor.constraint(equalTo: left.widthAnchor)
        ])
        return row
    }

    private func switchColumn(title: String, toggle: NSSwitch) -> NSView {
        let column = NSView()
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 12)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        [titleLabel, toggle].forEach {
            column.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            toggle.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            toggle.centerYAnchor.constraint(equalTo: column.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: toggle.trailingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: column.centerYAnchor)
        ])
        return column
    }

    private func applySearch(_ raw: String) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != searchQuery else { return }
        let previous = selectedNode
        searchQuery = query
        suppressSelectionSave = true
        outlineView.reloadData()
        visibleSubscriptions.forEach { outlineView.expandItem($0) }
        suppressSelectionSave = false
        if let previous = previous, outlineView.row(forItem: previous) >= 0 {
            select(node: previous)
        } else if let first = visibleSubscriptions.first?.filteredNodes(matching: searchQuery).first {
            select(node: first)
        } else {
            outlineView.deselectAll(nil)
            updateSelection()
        }
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        applySearch(sender.stringValue)
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        setLanguage(sender.indexOfSelectedItem == 0 ? .russian : .english)
    }

    @objc private func autoConnectChanged(_ sender: NSSwitch) {
        defaults.set(sender.state == .on, forKey: autoConnectKey)
    }

    @objc private func invisibleModeChanged(_ sender: NSSwitch) {
        defaults.set(sender.state == .on, forKey: invisibleModeKey)
        applyInvisibleMode()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === onboardingURLField, commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        importInitialSubscription()
        return true
    }

    @objc private func importInitialSubscription() {
        guard !subscriptionRequestInProgress else { return }
        let raw = onboardingURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = validHTTPSURL(raw) else {
            showError(MaosVPNError.invalidSubscriptionURL)
            return
        }
        loadRemoteSubscription(name: url.host ?? "Main", source: raw)
    }

    @objc private func showAddSubscriptionDialog() {
        guard vpnController.state == .disconnected, !subscriptionRequestInProgress else { return }
        let accessory = AddSubscriptionAccessoryView()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = AppLanguage.text(russian: "Добавить конфигурацию", english: "Add configuration")
        alert.informativeText = AppLanguage.text(
            russian: "Добавьте ссылку подписки или готовую конфигурацию sing-box JSON.",
            english: "Add a subscription URL or a ready sing-box JSON configuration."
        )
        alert.accessoryView = accessory
        alert.addButton(withTitle: AppLanguage.text(russian: "Добавить", english: "Add"))
        alert.addButton(withTitle: AppLanguage.text(russian: "Отмена", english: "Cancel"))
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self = self else { return }
            let name = accessory.nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName = name.isEmpty
                ? AppLanguage.text(russian: "Подписка \(self.subscriptions.count + 1)", english: "Subscription \(self.subscriptions.count + 1)")
                : name
            switch accessory.sourceKind {
            case .remote:
                guard self.validHTTPSURL(accessory.source) != nil else {
                    self.showError(MaosVPNError.invalidSubscriptionURL)
                    return
                }
                self.loadRemoteSubscription(name: resolvedName, source: accessory.source)
            case .json:
                self.loadJSONSubscription(name: resolvedName, source: accessory.source)
            }
        }
    }

    private func loadRemoteSubscription(name: String, source: String) {
        guard let url = validHTTPSURL(source) else {
            showError(MaosVPNError.invalidSubscriptionURL)
            return
        }
        setSubscriptionBusy(true)
        showStatus(L10n.text(.loadingSubscription))
        subscriptionService.load(from: url) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.setSubscriptionBusy(false)
                switch result {
                case .success(let profiles):
                    self.finishAddingSubscription(name: name, kind: .remote, source: source, profiles: profiles)
                case .failure(let error): self.showError(error)
                }
            }
        }
    }

    private func loadJSONSubscription(name: String, source: String) {
        guard !source.isEmpty else { showError(MaosVPNError.emptySubscription); return }
        setSubscriptionBusy(true)
        showStatus(L10n.text(.loadingSubscription))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try SubscriptionService.parseConfiguration(source) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.setSubscriptionBusy(false)
                switch result {
                case .success(let profiles):
                    self.finishAddingSubscription(name: name, kind: .json, source: source, profiles: profiles)
                case .failure(let error): self.showError(error)
                }
            }
        }
    }

    private func finishAddingSubscription(name: String, kind: SubscriptionSourceKind, source: String, profiles: [VPNProfile]) {
        let entry = SubscriptionEntry(name: name, sourceKind: kind, source: source, profiles: profiles)
        subscriptions.append(entry)
        persistLibrary()
        latencyByProfileID.removeAll()
        buildCurrentInterface()
        if let first = entry.profileNodes.first { select(node: first) }
        showStatus("\(L10n.text(.subscriptionUpdated)) \(profiles.count).")
    }

    @objc private func toggleConnection() {
        if vpnController.isConnected {
            disconnectSelectedServer()
        } else {
            connectSelectedServer()
        }
    }

    func profileForMenu() -> VPNProfile? {
        selectedProfile
    }

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        view.window?.makeKeyAndOrderFront(nil)
    }

    func connectSelectedServer() {
        guard vpnController.state == .disconnected else { return }
        guard let profile = selectedProfile else {
            showMainWindow()
            return
        }
        vpnController.connect(profile: profile) { [weak self] error in
            if let error = error { self?.showError(error) }
        }
    }

    func disconnectSelectedServer() {
        guard vpnController.state == .connected || vpnController.isConnected else { return }
        vpnController.disconnect { [weak self] error in
            if let error = error { self?.showError(error) }
        }
    }

    private func setLanguage(_ language: AppLanguage) {
        guard language != AppLanguage.current else { return }
        AppLanguage.current = language
        ServerPlaceParser.clearCache()
        NotificationCenter.default.post(name: .maosVPNLanguageDidChange, object: nil)
        buildCurrentInterface()
        showStatus(L10n.text(.languageChanged))
    }

    private func configureControllerCallbacks() {
        vpnController.onStateChange = { [weak self] state in self?.updateState(state) }
        vpnController.onLog = { [weak self] text in self?.showStatus(text) }
    }

    private func updateState(_ state: VPNController.State) {
        guard !isShowingOnboarding else { return }
        switch state {
        case .disconnected:
            stopConnectionTimer(reset: true)
            statusLabel.stringValue = L10n.text(.disconnected)
            connectionSubtitleLabel.stringValue = AppLanguage.text(
                russian: "Нажмите, чтобы подключиться к серверу",
                english: "Tap to connect to a VPN server"
            )
            connectButton.connectionStyle = .idle
            connectButton.isEnabled = selectedProfile != nil && !subscriptionRequestInProgress && !latencyTestInProgress
            outlineView.isEnabled = !subscriptionRequestInProgress
            searchField.isEnabled = !subscriptionRequestInProgress
            addSubscriptionButton.isEnabled = !subscriptionRequestInProgress
        case .connecting:
            statusLabel.stringValue = L10n.text(.connecting)
            connectionSubtitleLabel.stringValue = AppLanguage.text(
                russian: "Создаём защищённое соединение…",
                english: "Creating a secure connection…"
            )
            connectButton.connectionStyle = .working
            connectButton.isEnabled = false
            setMainControlsEnabled(false)
        case .connected:
            if connectedSince == nil { connectedSince = Date() }
            startConnectionTimer()
            statusLabel.stringValue = AppLanguage.text(russian: "Подключено", english: "Connected")
            connectionSubtitleLabel.stringValue = connectedSubtitle()
            connectButton.connectionStyle = .connected
            connectButton.isEnabled = true
            setMainControlsEnabled(false)
        case .disconnecting:
            statusLabel.stringValue = L10n.text(.disconnecting)
            connectionSubtitleLabel.stringValue = AppLanguage.text(
                russian: "Завершаем соединение…",
                english: "Closing the connection…"
            )
            connectButton.connectionStyle = .working
            connectButton.isEnabled = false
            setMainControlsEnabled(false)
        }
        connectButton.alphaValue = (selectedProfile == nil && state == .disconnected) ? 0.5 : 1
        updateLatencyMenu()
    }

    private func setMainControlsEnabled(_ enabled: Bool) {
        outlineView.isEnabled = enabled
        searchField.isEnabled = enabled
        addSubscriptionButton.isEnabled = enabled
    }

    private func applyInvisibleMode() {
        let hide = defaults.bool(forKey: invisibleModeKey)
        let policy: NSApplication.ActivationPolicy = hide ? .accessory : .regular
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        NSApp.activate(ignoringOtherApps: true)
        view.window?.makeKeyAndOrderFront(nil)
    }

    private func connectedSubtitle() -> String {
        let base = AppLanguage.text(russian: "Весь трафик защищён", english: "All traffic is protected")
        return "\(base)  ·  \(connectionDurationText())"
    }

    private func startConnectionTimer() {
        guard connectionTimer == nil else { return }
        connectionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.vpnController.noteProcessIfExited() { return }
            guard self.vpnController.state == .connected else { return }
            self.connectionSubtitleLabel.stringValue = self.connectedSubtitle()
        }
    }

    private func stopConnectionTimer(reset: Bool) {
        connectionTimer?.invalidate()
        connectionTimer = nil
        if reset { connectedSince = nil }
    }

    private func connectionDurationText() -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(connectedSince ?? Date())))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }

    private func updateSelection() {
        guard let profile = selectedProfile else {
            selectedFlagLabel.stringValue = ""
            selectedNameLabel.stringValue = L10n.text(.addSubscription)
            selectedDetailsLabel.stringValue = L10n.text(.serversWillAppear)
            selectedLatencyLabel.stringValue = "—"
            selectedDot.color = .tertiaryLabelColor
            protocolValueLabel.stringValue = "—"
            connectButton.isEnabled = false
            connectButton.alphaValue = 0.5
            return
        }
        let place = ServerPlaceParser.parse(profile.name)
        let city = place.city.isEmpty ? profile.server : place.city
        selectedFlagLabel.stringValue = place.flag
        selectedNameLabel.stringValue = place.title
        selectedDetailsLabel.stringValue = "\(city) · \(profile.kind.title)"
        protocolValueLabel.stringValue = protocolLabel(profile)
        if let latency = latencyByProfileID[profile.id] {
            selectedLatencyLabel.stringValue = latencyText(latency)
            selectedDot.color = latencyDotColor(latency)
        } else {
            selectedLatencyLabel.stringValue = "—"
            selectedDot.color = .tertiaryLabelColor
        }
        let idle = vpnController.state == .disconnected || vpnController.state == .connected
        connectButton.isEnabled = idle && !latencyTestInProgress
        connectButton.alphaValue = 1
    }

    private func protocolLabel(_ profile: VPNProfile) -> String {
        let network = (profile.parameters["type"] ?? profile.parameters["net"] ?? (profile.kind == .hysteria2 ? "udp" : "tcp")).uppercased()
        return "\(profile.kind.title) (\(network))"
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? visibleSubscriptions.count : ((item as? SubscriptionEntry)?.filteredNodes(matching: searchQuery).count ?? 0)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let subscription = item as? SubscriptionEntry { return subscription.filteredNodes(matching: searchQuery)[index] }
        return visibleSubscriptions[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is SubscriptionEntry }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is ProfileNode }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { item is SubscriptionEntry ? 26 : 40 }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let subscription = item as? SubscriptionEntry {
            let identifier = NSUserInterfaceItemIdentifier("SubscriptionCell")
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? GroupCell) ?? GroupCell(identifier: identifier)
            let nodes = subscription.filteredNodes(matching: searchQuery)
            cell.update(name: subscription.name, count: nodes.count)
            return cell
        }
        guard let node = item as? ProfileNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ProfileCell")
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? ProfileCell) ?? ProfileCell(identifier: identifier)
        cell.update(profile: node.profile, latency: latencyByProfileID[node.profile.id], selected: node === selectedNode)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        if !suppressSelectionSave, let id = selectedProfile?.id.uuidString {
            defaults.set(id, forKey: selectedProfileKey)
        }
        let previous = starredNode
        let current = selectedNode
        starredNode = current
        refreshRow(previous)
        refreshRow(current)
        updateSelection()
    }

    private func refreshRow(_ node: ProfileNode?) {
        guard let node = node else { return }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        outlineView.rowView(atRow: row, makeIfNecessary: false)?.needsDisplay = true
        guard let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ProfileCell else { return }
        cell.update(profile: node.profile, latency: latencyByProfileID[node.profile.id], selected: node === selectedNode)
    }

    private func restoreSelection() {
        let nodes = visibleSubscriptions.flatMap { $0.filteredNodes(matching: searchQuery) }
        if let saved = defaults.string(forKey: selectedProfileKey),
           let node = nodes.first(where: { $0.profile.id.uuidString == saved }) {
            select(node: node)
            return
        }
        if let first = nodes.first {
            select(node: first)
        } else {
            updateSelection()
        }
    }

    private func select(node: ProfileNode) {
        if let subscription = subscriptions.first(where: { $0.id == node.subscriptionID }) { outlineView.expandItem(subscription) }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    @objc private func testPing() { startLatencyTest(selectFastest: false) }
    @objc private func autoSelectFastest() { startLatencyTest(selectFastest: true) }

    func menuNeedsUpdate(_ menu: NSMenu) { updateLatencyMenu() }

    private func startLatencyTest(selectFastest: Bool) {
        let snapshot = allNodes
        guard !snapshot.isEmpty, !latencyTestInProgress, vpnController.state == .disconnected else { return }
        latencyTestInProgress = true
        selectFastestWhenFinished = selectFastest
        latencyTestID = UUID()
        let testID = latencyTestID
        snapshot.forEach { latencyByProfileID[$0.profile.id] = .testing }
        let previous = selectedNode
        suppressSelectionSave = true
        outlineView.reloadData()
        visibleSubscriptions.forEach { outlineView.expandItem($0) }
        suppressSelectionSave = false
        if let previous = previous, outlineView.row(forItem: previous) >= 0 {
            select(node: previous)
        }
        updateSelection()
        updateState(vpnController.state)
        showStatus(L10n.text(.testingPing))
        let group = DispatchGroup()
        for node in snapshot {
            group.enter()
            latencyOperationQueue.addOperation { [weak self] in
                let milliseconds = self?.measureLatency(to: node.profile.server)
                DispatchQueue.main.async {
                    defer { group.leave() }
                    guard let self = self, self.latencyTestID == testID else { return }
                    self.latencyByProfileID[node.profile.id] = milliseconds.map(LatencyState.reachable) ?? .unavailable
                    if self.outlineView.row(forItem: node) >= 0 {
                        self.outlineView.reloadItem(node)
                    }
                    if self.selectedNode === node { self.updateSelection() }
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self = self, self.latencyTestID == testID else { return }
            self.latencyTestInProgress = false
            self.updateState(self.vpnController.state)
            if self.selectFastestWhenFinished { self.selectFastestProfile() }
            else { self.showStatus(L10n.text(.pingFinished)) }
            self.selectFastestWhenFinished = false
        }
    }

    private func measureLatency(to host: String) -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ping")
        process.arguments = ["-n", "-c", "1", "-W", "1000", host]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .utility
        let started = DispatchTime.now().uptimeNanoseconds
        do { try process.run(); process.waitUntilExit() } catch { return nil }
        guard process.terminationStatus == 0 else { return nil }
        return max(1, Int((Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000).rounded()))
    }

    private func selectFastestProfile() {
        let fastest = allNodes.compactMap { node -> (ProfileNode, Int)? in
            guard case .reachable(let milliseconds)? = latencyByProfileID[node.profile.id] else { return nil }
            return (node, milliseconds)
        }.min { $0.1 < $1.1 }
        guard let result = fastest else {
            showStatus(L10n.text(.pingUnavailable), color: .systemRed)
            return
        }
        select(node: result.0)
        showStatus("\(L10n.text(.fastestSelected)) \(result.0.profile.name) — \(result.1) ms.")
    }

    private func updateLatencyMenu() {
        let enabled = !allNodes.isEmpty && !latencyTestInProgress && !subscriptionRequestInProgress && vpnController.state == .disconnected
        pingMenuItem?.isEnabled = enabled
        fastestMenuItem?.isEnabled = enabled
    }

    private func latencyText(_ latency: LatencyState) -> String {
        switch latency {
        case .testing: return "…"
        case .reachable(let milliseconds): return "\(milliseconds) ms"
        case .unavailable: return "—"
        }
    }

    private func latencyDotColor(_ latency: LatencyState) -> NSColor {
        switch latency {
        case .testing, .unavailable: return .tertiaryLabelColor
        case .reachable: return .systemGreen
        }
    }

    private func setSubscriptionBusy(_ busy: Bool) {
        subscriptionRequestInProgress = busy
        if busy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        if isShowingOnboarding {
            onboardingURLField.isEnabled = !busy
            onboardingAddButton.isEnabled = !busy
        } else {
            updateState(vpnController.state)
        }
    }

    private func validHTTPSURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    private func persistLibrary() {
        if let data = try? JSONEncoder().encode(subscriptions) { defaults.set(data, forKey: libraryKey) }
    }

    private func restoreLibrary() {
        if let data = defaults.data(forKey: libraryKey),
           let saved = try? JSONDecoder().decode([SubscriptionEntry].self, from: data) {
            subscriptions = saved.filter { !$0.profiles.isEmpty }
            return
        }
        guard let oldData = defaults.data(forKey: "profiles"),
              let oldProfiles = try? JSONDecoder().decode([VPNProfile].self, from: oldData) else { return }
        let filtered = oldProfiles.filter { !($0.port == 1 && ($0.server == "0.0.0.0" || $0.server == "::")) }
        guard !filtered.isEmpty else { return }
        subscriptions = [SubscriptionEntry(
            name: AppLanguage.text(russian: "Основная подписка", english: "Main subscription"),
            sourceKind: .remote,
            source: defaults.string(forKey: "subscriptionURL") ?? "",
            profiles: filtered
        )]
        persistLibrary()
        defaults.removeObject(forKey: "profiles")
        defaults.removeObject(forKey: "subscriptionURL")
    }

    private func showStatus(_ text: String, color: NSColor = .secondaryLabelColor) {
        messageLabel.textColor = color
        messageLabel.stringValue = text
    }

    private func showError(_ error: Error) {
        showStatus(error.localizedDescription, color: .systemRed)
        NSSound.beep()
        guard view.window?.isVisible != true else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = AppLanguage.text(russian: "Не удалось изменить VPN", english: "Could not change the VPN")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L10n.text(.okay))
        alert.runModal()
    }
}

private extension SubscriptionEntry {
    func filteredNodes(matching rawQuery: String) -> [ProfileNode] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return profileNodes }
        if name.localizedCaseInsensitiveContains(query) { return profileNodes }
        return profileNodes.filter { node in
            let profile = node.profile
            if profile.name.localizedCaseInsensitiveContains(query)
                || profile.server.localizedCaseInsensitiveContains(query)
                || profile.kind.title.localizedCaseInsensitiveContains(query) {
                return true
            }
            let place = ServerPlaceParser.parse(profile.name)
            return place.title.localizedCaseInsensitiveContains(query) || place.city.localizedCaseInsensitiveContains(query)
        }
    }
}

private final class DotView: NSView {
    var color: NSColor = .tertiaryLabelColor { didSet { needsDisplay = true } }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
    }
}

private final class GroupCell: NSTableCellView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        nameLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        countLabel.font = NSFont.systemFont(ofSize: 12)
        countLabel.textColor = .secondaryLabelColor
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        [nameLabel, countLabel].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -8),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { return nil }

    func update(name: String, count: Int) {
        nameLabel.stringValue = name
        countLabel.stringValue = "\(count)"
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    private func applyColors() {
        let selected = backgroundStyle == .emphasized
        nameLabel.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        countLabel.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }
}

private final class ProfileCell: NSTableCellView {
    private let flagLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let cityLabel = NSTextField(labelWithString: "")
    private let latencyLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        flagLabel.font = NSFont.systemFont(ofSize: 16)
        flagLabel.alignment = .center
        titleLabel.font = NSFont.systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        cityLabel.font = NSFont.systemFont(ofSize: 11)
        cityLabel.textColor = .secondaryLabelColor
        cityLabel.lineBreakMode = .byTruncatingTail
        cityLabel.maximumNumberOfLines = 1
        latencyLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        latencyLabel.textColor = .secondaryLabelColor
        latencyLabel.alignment = .right
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cityLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        latencyLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        [flagLabel, titleLabel, cityLabel, latencyLabel].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            flagLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            flagLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            flagLabel.widthAnchor.constraint(equalToConstant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: flagLabel.trailingAnchor, constant: 6),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: latencyLabel.leadingAnchor, constant: -8),
            cityLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            cityLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor),
            cityLabel.trailingAnchor.constraint(lessThanOrEqualTo: latencyLabel.leadingAnchor, constant: -8),
            latencyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            latencyLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { return nil }

    func update(profile: VPNProfile, latency: MainViewController.LatencyState?, selected: Bool) {
        let place = ServerPlaceParser.parse(profile.name)
        flagLabel.stringValue = place.flag
        titleLabel.stringValue = place.title
        cityLabel.stringValue = place.city.isEmpty ? profile.server : place.city
        if let latency = latency {
            latencyLabel.stringValue = latencyText(latency)
        } else {
            latencyLabel.stringValue = "\u{2014}"
        }
        _ = selected
        applyColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    private func applyColors() {
        let emphasized = backgroundStyle == .emphasized
        let primary: NSColor = emphasized ? .alternateSelectedControlTextColor : .labelColor
        let secondary: NSColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        titleLabel.textColor = primary
        cityLabel.textColor = secondary
        latencyLabel.textColor = secondary
    }

    private func latencyText(_ latency: MainViewController.LatencyState) -> String {
        switch latency {
        case .testing: return "\u{2026}"
        case .reachable(let milliseconds): return "\(milliseconds) ms"
        case .unavailable: return "\u{2014}"
        }
    }
}

private enum PowerConnectionStyle {
    case idle
    case working
    case connected
}

private final class PowerButton: NSButton {
    var connectionStyle: PowerConnectionStyle = .idle { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        focusRingType = .none
    }

    required init?(coder: NSCoder) { return nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let dx = local.x - bounds.midX
        let dy = local.y - bounds.midY
        guard dx * dx + dy * dy <= 56 * 56 else { return nil }
        return self
    }

    override func draw(_ dirtyRect: NSRect) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let rings: [(CGFloat, CGFloat, CGFloat)] = connectionStyle == .connected
            ? [(70, 16, 0.30), (84, 14, 0.14), (94, 8, 0.07)]
            : [(70, 16, 0.18), (84, 14, 0.09), (94, 8, 0.045)]
        for (radius, width, alpha) in rings {
            Design.accent.withAlphaComponent(alpha).setStroke()
            let rect = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            let ring = NSBezierPath(ovalIn: rect)
            ring.lineWidth = width
            ring.stroke()
        }

        let radius: CGFloat = 56
        let disk = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let fill: NSColor
        switch connectionStyle {
        case .connected: fill = Design.accent
        case .working: fill = NSColor(calibratedRed: 0.90, green: 0.94, blue: 1, alpha: 1)
        case .idle: fill = Design.surface
        }
        fill.setFill()
        NSBezierPath(ovalIn: disk).fill()
        if connectionStyle != .connected {
            Design.accent.withAlphaComponent(0.16).setStroke()
            let rim = NSBezierPath(ovalIn: disk.insetBy(dx: 0.8, dy: 0.8))
            rim.lineWidth = 1.2
            rim.stroke()
        }

        let icon = connectionStyle == .connected ? NSColor.white : Design.accent
        icon.setStroke()
        let iconCenter = NSPoint(x: center.x, y: center.y - 1)
        let arc = NSBezierPath()
        arc.appendArc(withCenter: iconCenter, radius: 16, startAngle: 125, endAngle: 55, clockwise: false)
        arc.lineWidth = 3.3
        arc.lineCapStyle = .round
        arc.stroke()
        let stem = NSBezierPath()
        stem.move(to: NSPoint(x: iconCenter.x, y: iconCenter.y + 4))
        stem.line(to: NSPoint(x: iconCenter.x, y: iconCenter.y + 20))
        stem.lineWidth = 3.3
        stem.lineCapStyle = .round
        stem.stroke()
    }
}
