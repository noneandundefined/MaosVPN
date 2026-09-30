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
    private var headerHeightConstraint: NSLayoutConstraint?
    private let searchPill = SearchPill()
    private let languagePill = LanguagePill()
    private let addSubscriptionButton = AccentPill()
    private let autoSwitch = TinySwitch()
    private let invisibleSwitch = TinySwitch()
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
    private let onboardingAddButton = AccentPill()
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
        view = FlatView(frame: NSRect(x: 0, y: 0, width: 1080, height: 740))
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
        if let window = view.window, let headerHeightConstraint = headerHeightConstraint {
            let layoutHeight = window.contentLayoutRect.height
            let bar = view.bounds.height - layoutHeight
            if layoutHeight > 100, bar > 28, bar < 80, abs(headerHeightConstraint.constant - bar) > 0.5 {
                headerHeightConstraint.constant = bar
            }
        }
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
        headerHeightConstraint = nil
        serverScroll = nil
        view.subviews.forEach { $0.removeFromSuperview() }
        if isShowingOnboarding {
            buildOnboardingInterface()
        } else {
            buildMainInterface()
        }
    }

    private func buildOnboardingInterface() {
        languagePill.title = AppLanguage.current == .russian ? "Русский" : "English"
        languagePill.onClick = { [weak self] in self?.showLanguageMenu() }

        let title = NSTextField(labelWithString: AppLanguage.text(
            russian: "Добавьте первую подписку",
            english: "Add your first subscription"
        ))
        title.font = NSFont.systemFont(ofSize: 28, weight: .bold)
        title.textColor = Design.primaryText
        title.alignment = .center
        let subtitle = NSTextField(wrappingLabelWithString: AppLanguage.text(
            russian: "Вставьте ссылку — серверы сохранятся локально, а сама ссылка больше не будет показана в приложении.",
            english: "Paste a URL. Servers will be stored locally and the URL will no longer be shown in the app."
        ))
        subtitle.font = NSFont.systemFont(ofSize: 14)
        subtitle.textColor = Design.secondaryText
        subtitle.alignment = .center

        onboardingURLField.placeholderString = "https://example.com/sub/..."
        onboardingURLField.font = NSFont.systemFont(ofSize: 14)
        onboardingURLField.textColor = Design.primaryText
        onboardingURLField.isBordered = false
        onboardingURLField.drawsBackground = false
        onboardingURLField.focusRingType = .none
        onboardingURLField.delegate = self
        let fieldChrome = FieldChrome()
        fieldChrome.addSubview(onboardingURLField)
        onboardingURLField.translatesAutoresizingMaskIntoConstraints = false

        onboardingAddButton.title = AppLanguage.text(russian: "Добавить подписку", english: "Add subscription")
        onboardingAddButton.onClick = { [weak self] in self?.importInitialSubscription() }

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        messageLabel.font = NSFont.systemFont(ofSize: 12)
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 3
        messageLabel.preferredMaxLayoutWidth = 460

        let card = SoftCard()
        [title, subtitle, fieldChrome, onboardingAddButton, progress, messageLabel].forEach {
            card.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        [languagePill, card].forEach {
            view.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            languagePill.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            languagePill.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            languagePill.widthAnchor.constraint(equalToConstant: 136),
            languagePill.heightAnchor.constraint(equalToConstant: 36),
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 20),
            card.widthAnchor.constraint(equalToConstant: 560),
            card.heightAnchor.constraint(equalToConstant: 280),
            title.topAnchor.constraint(equalTo: card.topAnchor, constant: 36),
            title.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 32),
            title.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -32),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            subtitle.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 48),
            subtitle.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -48),
            fieldChrome.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 22),
            fieldChrome.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 40),
            fieldChrome.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -40),
            fieldChrome.heightAnchor.constraint(equalToConstant: 40),
            onboardingURLField.leadingAnchor.constraint(equalTo: fieldChrome.leadingAnchor, constant: 12),
            onboardingURLField.trailingAnchor.constraint(equalTo: fieldChrome.trailingAnchor, constant: -12),
            onboardingURLField.centerYAnchor.constraint(equalTo: fieldChrome.centerYAnchor),
            onboardingAddButton.topAnchor.constraint(equalTo: fieldChrome.bottomAnchor, constant: 16),
            onboardingAddButton.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            onboardingAddButton.widthAnchor.constraint(equalToConstant: 200),
            onboardingAddButton.heightAnchor.constraint(equalToConstant: 38),
            progress.leadingAnchor.constraint(equalTo: onboardingAddButton.trailingAnchor, constant: 10),
            progress.centerYAnchor.constraint(equalTo: onboardingAddButton.centerYAnchor),
            messageLabel.topAnchor.constraint(equalTo: onboardingAddButton.bottomAnchor, constant: 10),
            messageLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 32),
            messageLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -32)
        ])
    }

    private func buildMainInterface() {
        let header = makeHeader()
        let sidebar = makeSidebar()
        let content = makeMainContent()
        let columnLine = HairlineView()
        [header, sidebar, content, columnLine].forEach {
            view.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        let headerHeight = header.heightAnchor.constraint(equalToConstant: Design.headerHeight)
        headerHeightConstraint = headerHeight
        NSLayoutConstraint.activate([
            headerHeight,
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sidebar.topAnchor.constraint(equalTo: header.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebar.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.44),
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
        searchPill.placeholder = AppLanguage.text(russian: "Поиск стран или городов...", english: "Search countries or cities...")
        searchPill.text = searchQuery
        searchPill.onChange = { [weak self] text in self?.applySearch(text) }
        languagePill.title = AppLanguage.current == .russian ? "Русский" : "English"
        languagePill.onClick = { [weak self] in self?.showLanguageMenu() }
        addSubscriptionButton.title = AppLanguage.text(russian: "Добавить подписку", english: "Add subscription")
        addSubscriptionButton.onClick = { [weak self] in self?.showAddSubscriptionDialog() }
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        let divider = HairlineView()
        [searchPill, progress, languagePill, addSubscriptionButton, divider].forEach {
            container.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            searchPill.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 86),
            searchPill.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            searchPill.heightAnchor.constraint(equalToConstant: 36),
            progress.leadingAnchor.constraint(equalTo: searchPill.trailingAnchor, constant: 8),
            progress.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            progress.widthAnchor.constraint(equalToConstant: 16),
            progress.heightAnchor.constraint(equalToConstant: 16),
            languagePill.leadingAnchor.constraint(equalTo: progress.trailingAnchor, constant: 8),
            languagePill.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            languagePill.widthAnchor.constraint(equalToConstant: 136),
            languagePill.heightAnchor.constraint(equalToConstant: 36),
            addSubscriptionButton.leadingAnchor.constraint(equalTo: languagePill.trailingAnchor, constant: 12),
            addSubscriptionButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            addSubscriptionButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            addSubscriptionButton.widthAnchor.constraint(equalToConstant: 200),
            addSubscriptionButton.heightAnchor.constraint(equalToConstant: 36),
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1)
        ])
        return container
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
        outlineView.backgroundColor = Design.background
        outlineView.selectionHighlightStyle = .none
        outlineView.indentationPerLevel = 14
        outlineView.intercellSpacing = NSSize(width: 0, height: 1)
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
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
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
        let map = WorldMapView()
        let serverCard = SoftCard()
        let protocolCard = SoftCard()
        let toggles = makeToggleRow()

        selectedFlagLabel.font = NSFont.systemFont(ofSize: 26)
        selectedFlagLabel.alignment = .center
        selectedNameLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        selectedNameLabel.textColor = Design.primaryText
        selectedNameLabel.lineBreakMode = .byTruncatingTail
        selectedNameLabel.maximumNumberOfLines = 1
        selectedDetailsLabel.font = NSFont.systemFont(ofSize: 12)
        selectedDetailsLabel.textColor = Design.secondaryText
        selectedDetailsLabel.lineBreakMode = .byTruncatingTail
        selectedDetailsLabel.maximumNumberOfLines = 1
        selectedLatencyLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        selectedLatencyLabel.textColor = Design.secondaryText
        selectedLatencyLabel.alignment = .right
        protocolValueLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        protocolValueLabel.textColor = Design.primaryText
        let protocolBadge = ProtocolBadge()
        let protocolCaption = NSTextField(labelWithString: AppLanguage.text(russian: "Протокол", english: "Protocol"))
        protocolCaption.font = NSFont.systemFont(ofSize: 11)
        protocolCaption.textColor = Design.secondaryText
        let serverChevron = chevronLabel()
        let protocolChevron = chevronLabel()

        [selectedFlagLabel, selectedNameLabel, selectedDetailsLabel, selectedDot, selectedLatencyLabel, serverChevron].forEach {
            serverCard.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        [protocolBadge, protocolCaption, protocolValueLabel, protocolChevron].forEach {
            protocolCard.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        connectButton.target = self
        connectButton.action = #selector(toggleConnection)
        statusLabel.font = NSFont.systemFont(ofSize: 24, weight: .bold)
        statusLabel.textColor = Design.primaryText
        statusLabel.alignment = .center
        connectionSubtitleLabel.font = NSFont.systemFont(ofSize: 13)
        connectionSubtitleLabel.textColor = Design.secondaryText
        connectionSubtitleLabel.alignment = .center
        messageLabel.font = NSFont.systemFont(ofSize: 12)
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 2
        messageLabel.preferredMaxLayoutWidth = 460

        [map, connectButton, statusLabel, connectionSubtitleLabel, messageLabel, serverCard, protocolCard, toggles].forEach {
            container.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            map.topAnchor.constraint(equalTo: container.topAnchor),
            map.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            map.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            map.heightAnchor.constraint(equalToConstant: 300),
            connectButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            connectButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            connectButton.widthAnchor.constraint(equalToConstant: 200),
            connectButton.heightAnchor.constraint(equalToConstant: 200),
            statusLabel.topAnchor.constraint(equalTo: connectButton.bottomAnchor, constant: 2),
            statusLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            connectionSubtitleLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            connectionSubtitleLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            messageLabel.topAnchor.constraint(equalTo: connectionSubtitleLabel.bottomAnchor, constant: 6),
            messageLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 36),
            messageLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -36),
            toggles.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            toggles.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),
            toggles.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18),
            toggles.heightAnchor.constraint(equalToConstant: 64),
            protocolCard.leadingAnchor.constraint(equalTo: toggles.leadingAnchor),
            protocolCard.trailingAnchor.constraint(equalTo: toggles.trailingAnchor),
            protocolCard.bottomAnchor.constraint(equalTo: toggles.topAnchor, constant: -14),
            protocolCard.heightAnchor.constraint(equalToConstant: 64),
            serverCard.leadingAnchor.constraint(equalTo: protocolCard.leadingAnchor),
            serverCard.trailingAnchor.constraint(equalTo: protocolCard.trailingAnchor),
            serverCard.bottomAnchor.constraint(equalTo: protocolCard.topAnchor, constant: -10),
            serverCard.heightAnchor.constraint(equalToConstant: 64),
            selectedFlagLabel.leadingAnchor.constraint(equalTo: serverCard.leadingAnchor, constant: 16),
            selectedFlagLabel.centerYAnchor.constraint(equalTo: serverCard.centerYAnchor),
            selectedFlagLabel.widthAnchor.constraint(equalToConstant: 36),
            selectedNameLabel.leadingAnchor.constraint(equalTo: selectedFlagLabel.trailingAnchor, constant: 10),
            selectedNameLabel.topAnchor.constraint(equalTo: serverCard.topAnchor, constant: 12),
            selectedNameLabel.trailingAnchor.constraint(lessThanOrEqualTo: selectedDot.leadingAnchor, constant: -8),
            selectedDetailsLabel.leadingAnchor.constraint(equalTo: selectedNameLabel.leadingAnchor),
            selectedDetailsLabel.topAnchor.constraint(equalTo: selectedNameLabel.bottomAnchor, constant: 2),
            selectedDetailsLabel.trailingAnchor.constraint(lessThanOrEqualTo: selectedDot.leadingAnchor, constant: -8),
            selectedDot.trailingAnchor.constraint(equalTo: selectedLatencyLabel.leadingAnchor, constant: -6),
            selectedDot.centerYAnchor.constraint(equalTo: serverCard.centerYAnchor),
            selectedDot.widthAnchor.constraint(equalToConstant: 7),
            selectedDot.heightAnchor.constraint(equalToConstant: 7),
            selectedLatencyLabel.trailingAnchor.constraint(equalTo: serverChevron.leadingAnchor, constant: -8),
            selectedLatencyLabel.centerYAnchor.constraint(equalTo: serverCard.centerYAnchor),
            serverChevron.trailingAnchor.constraint(equalTo: serverCard.trailingAnchor, constant: -16),
            serverChevron.centerYAnchor.constraint(equalTo: serverCard.centerYAnchor),
            protocolBadge.leadingAnchor.constraint(equalTo: protocolCard.leadingAnchor, constant: 16),
            protocolBadge.centerYAnchor.constraint(equalTo: protocolCard.centerYAnchor),
            protocolBadge.widthAnchor.constraint(equalToConstant: 36),
            protocolBadge.heightAnchor.constraint(equalToConstant: 36),
            protocolCaption.leadingAnchor.constraint(equalTo: protocolBadge.trailingAnchor, constant: 12),
            protocolCaption.topAnchor.constraint(equalTo: protocolCard.topAnchor, constant: 12),
            protocolValueLabel.leadingAnchor.constraint(equalTo: protocolCaption.leadingAnchor),
            protocolValueLabel.topAnchor.constraint(equalTo: protocolCaption.bottomAnchor, constant: 2),
            protocolValueLabel.trailingAnchor.constraint(lessThanOrEqualTo: protocolChevron.leadingAnchor, constant: -8),
            protocolChevron.trailingAnchor.constraint(equalTo: protocolCard.trailingAnchor, constant: -16),
            protocolChevron.centerYAnchor.constraint(equalTo: protocolCard.centerYAnchor)
        ])
        return container
    }

    private func makeToggleRow() -> NSView {
        let row = NSView()
        autoSwitch.isOn = defaults.bool(forKey: autoConnectKey)
        autoSwitch.onChange = { [weak self] isOn in
            guard let self = self else { return }
            self.defaults.set(isOn, forKey: self.autoConnectKey)
        }
        invisibleSwitch.isOn = defaults.bool(forKey: invisibleModeKey)
        invisibleSwitch.onChange = { [weak self] isOn in
            guard let self = self else { return }
            self.defaults.set(isOn, forKey: self.invisibleModeKey)
            self.applyInvisibleMode()
        }
        let left = toggleColumn(
            icon: Design.shield,
            title: AppLanguage.text(russian: "Автоподключение", english: "Auto-connect"),
            detail: AppLanguage.text(russian: "При запуске приложения", english: "Connect on app launch"),
            toggle: autoSwitch
        )
        let right = toggleColumn(
            icon: Design.hiddenEye,
            title: AppLanguage.text(russian: "Скрыть в Dock", english: "Hide from Dock"),
            detail: AppLanguage.text(russian: "Не показывать значок приложения", english: "Hide the application icon"),
            toggle: invisibleSwitch
        )
        let divider = HairlineView()
        [left, right, divider].forEach {
            row.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            left.topAnchor.constraint(equalTo: row.topAnchor),
            left.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor),
            right.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            right.topAnchor.constraint(equalTo: row.topAnchor),
            right.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            right.widthAnchor.constraint(equalTo: left.widthAnchor),
            divider.centerXAnchor.constraint(equalTo: row.centerXAnchor),
            divider.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 28)
        ])
        return row
    }

    private func toggleColumn(icon: NSImage, title: String, detail: String, toggle: TinySwitch) -> NSView {
        let column = NSView()
        let imageView = NSImageView()
        imageView.image = icon
        imageView.imageScaling = .scaleProportionallyDown
        imageView.contentTintColor = Design.secondaryText
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = Design.primaryText
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = NSFont.systemFont(ofSize: 11)
        detailLabel.textColor = Design.secondaryText
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1
        [imageView, titleLabel, detailLabel, toggle].forEach {
            column.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 16),
            imageView.centerYAnchor.constraint(equalTo: column.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 10),
            titleLabel.topAnchor.constraint(equalTo: column.topAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -8),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -8),
            toggle.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -8),
            toggle.centerYAnchor.constraint(equalTo: column.centerYAnchor),
            toggle.widthAnchor.constraint(equalToConstant: 42),
            toggle.heightAnchor.constraint(equalToConstant: 26)
        ])
        return column
    }

    private func chevronLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "›")
        label.font = NSFont.systemFont(ofSize: 18, weight: .light)
        label.textColor = Design.tertiaryText
        return label
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

    private func showLanguageMenu() {
        let menu = NSMenu()
        let russian = menu.addItem(withTitle: "Русский", action: #selector(pickRussian), keyEquivalent: "")
        russian.target = self
        let english = menu.addItem(withTitle: "English", action: #selector(pickEnglish), keyEquivalent: "")
        english.target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: languagePill)
    }

    @objc private func pickRussian() { setLanguage(.russian) }
    @objc private func pickEnglish() { setLanguage(.english) }

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
            vpnController.disconnect { [weak self] error in if let error = error { self?.showError(error) } }
        } else if let profile = selectedProfile {
            vpnController.connect(profile: profile) { [weak self] error in if let error = error { self?.showError(error) } }
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
            searchPill.isEnabled = !subscriptionRequestInProgress
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
        searchPill.isEnabled = enabled
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
            guard let self = self, self.vpnController.state == .connected else { return }
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
            selectedDot.color = Design.tertiaryText
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
            selectedDot.color = Design.tertiaryText
        }
        let idle = vpnController.state == .disconnected || vpnController.state == .connected
        connectButton.isEnabled = idle && !latencyTestInProgress
        connectButton.alphaValue = 1
    }

    private func protocolLabel(_ profile: VPNProfile) -> String {
        let network = (profile.parameters["type"] ?? profile.parameters["net"] ?? (profile.kind == .hysteria2 ? "udp" : "tcp")).uppercased()
        return "\(profile.kind.title) (\(network))"
    }

    private func crownImage(for name: String) -> NSImage? {
        let folded = name.lowercased()
        if folded.contains("premium") || folded.contains("премиум") || folded.contains("vip") { return Design.purpleCrown }
        if folded.contains("plus") || folded.contains("плюс") { return Design.goldCrown }
        return nil
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
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { item is SubscriptionEntry ? 38 : 52 }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let subscription = item as? SubscriptionEntry {
            let identifier = NSUserInterfaceItemIdentifier("SubscriptionCell")
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? GroupCell) ?? GroupCell(identifier: identifier)
            let nodes = subscription.filteredNodes(matching: searchQuery)
            cell.update(name: subscription.name, count: nodes.count, crown: crownImage(for: subscription.name))
            return cell
        }
        guard let node = item as? ProfileNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ProfileCell")
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? ProfileCell) ?? ProfileCell(identifier: identifier)
        cell.update(profile: node.profile, latency: latencyByProfileID[node.profile.id], selected: node === selectedNode)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("ServerRow")
        let row = (outlineView.makeView(withIdentifier: identifier, owner: self) as? ServerRowView) ?? ServerRowView()
        row.identifier = identifier
        return row
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
            showStatus(L10n.text(.pingUnavailable), color: Design.danger)
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
        case .testing, .unavailable: return Design.tertiaryText
        case .reachable: return Design.latency
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

    private func showStatus(_ text: String, color: NSColor = Design.secondaryText) {
        messageLabel.textColor = color
        messageLabel.stringValue = text
    }

    private func showError(_ error: Error) {
        showStatus(error.localizedDescription, color: Design.danger)
        NSSound.beep()
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

private final class FlatView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        Design.background.setFill()
        bounds.fill()
    }
}

private final class HairlineView: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        Design.hairline.setFill()
        bounds.fill()
    }
}

private final class SoftCard: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        Design.surface.setFill()
        let path = NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16)
        path.fill()
        Design.cardBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

private final class FieldChrome: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        Design.surface.setFill()
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        path.fill()
        Design.cardBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

private final class SearchPill: NSView, HeaderControl, NSTextFieldDelegate {
    var onChange: ((String) -> Void)?
    var isEnabled: Bool = true {
        didSet {
            field.isEnabled = isEnabled
            alphaValue = isEnabled ? 1 : 0.48
        }
    }
    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }
    var placeholder: String = "" {
        didSet { applyPlaceholder() }
    }
    private let field = NSTextField()
    private var focused = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 13)
        field.textColor = Design.primaryText
        field.delegate = self
        field.cell?.sendsActionOnEndEditing = false
        addSubview(field)
        field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            field.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { return nil }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        Design.surface.setFill()
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        path.fill()
        (focused ? Design.accent : Design.cardBorder).setStroke()
        path.lineWidth = 1
        path.stroke()
        Design.secondaryText.setStroke()
        let glass = NSBezierPath(ovalIn: NSRect(x: 13, y: bounds.midY - 5, width: 9, height: 9))
        glass.lineWidth = 1.4
        glass.stroke()
        let handle = NSBezierPath()
        handle.move(to: NSPoint(x: 20.5, y: bounds.midY - 3.2))
        handle.line(to: NSPoint(x: 24, y: bounds.midY - 6.6))
        handle.lineWidth = 1.4
        handle.lineCapStyle = .round
        handle.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(field)
    }

    func controlTextDidChange(_ obj: Notification) { onChange?(field.stringValue) }
    func controlTextDidBeginEditing(_ obj: Notification) { focused = true; needsDisplay = true }
    func controlTextDidEndEditing(_ obj: Notification) { focused = false; needsDisplay = true }

    private func applyPlaceholder() {
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: Design.secondaryText,
                .font: NSFont.systemFont(ofSize: 13)
            ]
        )
    }
}

private final class AccentPill: NSView, HeaderControl {
    var onClick: (() -> Void)?
    var isEnabled: Bool = true { didSet { alphaValue = isEnabled ? 1 : 0.45 } }
    var title: String = "" { didSet { label.stringValue = title } }
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let imageView = NSImageView()
        imageView.image = Design.whiteCrown
        imageView.imageScaling = .scaleProportionallyDown
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        let stack = NSView()
        [imageView, label, stack].forEach {
            if $0 !== stack { stack.addSubview($0) }
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            imageView.centerYAnchor.constraint(equalTo: stack.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 14),
            imageView.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: stack.centerYAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.topAnchor.constraint(equalTo: imageView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: imageView.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { return nil }

    override func draw(_ dirtyRect: NSRect) {
        Design.accent.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onClick?()
    }
}

private final class LanguagePill: NSView, HeaderControl {
    var onClick: (() -> Void)?
    var title: String = "" { didSet { label.stringValue = title } }
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let imageView = NSImageView()
        imageView.image = Design.globe
        imageView.imageScaling = .scaleProportionallyDown
        imageView.contentTintColor = Design.secondaryText
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = Design.primaryText
        let chevron = NSTextField(labelWithString: "▾")
        chevron.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        chevron.textColor = Design.secondaryText
        let stack = NSView()
        [imageView, label, chevron].forEach {
            stack.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            imageView.centerYAnchor.constraint(equalTo: stack.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 14),
            imageView.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: stack.centerYAnchor),
            chevron.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 5),
            chevron.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            chevron.centerYAnchor.constraint(equalTo: stack.centerYAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { return nil }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        Design.surface.setFill()
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        path.fill()
        Design.cardBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

private final class TinySwitch: NSView {
    var isOn = false { didSet { needsDisplay = true } }
    var onChange: ((Bool) -> Void)?

    override func mouseDown(with event: NSEvent) {
        isOn.toggle()
        onChange?(isOn)
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = bounds.insetBy(dx: 1, dy: 3)
        (isOn ? Design.accent : Design.switchOff).setFill()
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()
        let knobSize = track.height - 4
        let x = isOn ? track.maxX - knobSize - 2 : track.minX + 2
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: track.minY + 2, width: knobSize, height: knobSize)).fill()
    }
}

private final class DotView: NSView {
    var color: NSColor = Design.tertiaryText { didSet { needsDisplay = true } }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
    }
}

private final class ProtocolBadge: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        Design.accent.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        let points = [
            NSPoint(x: bounds.midX, y: bounds.midY + 7),
            NSPoint(x: bounds.midX - 7, y: bounds.midY - 5),
            NSPoint(x: bounds.midX + 7, y: bounds.midY - 5)
        ]
        let lines = NSBezierPath()
        lines.move(to: points[0])
        lines.line(to: points[1])
        lines.line(to: points[2])
        lines.line(to: points[0])
        lines.lineWidth = 1.35
        Design.accent.setStroke()
        lines.stroke()
        Design.accent.setFill()
        for point in points {
            NSBezierPath(ovalIn: NSRect(x: point.x - 3.1, y: point.y - 3.1, width: 6.2, height: 6.2)).fill()
        }
    }
}

private final class CountBadge: NSView {
    private let label = NSTextField(labelWithString: "")
    private var widthConstraint: NSLayoutConstraint!

    var text: String = "" { didSet { apply() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = Design.secondaryText
        label.alignment = .center
        widthConstraint = widthAnchor.constraint(equalToConstant: 20)
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthConstraint,
            heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { return nil }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        Design.badgeFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    private func apply() {
        label.stringValue = text
        let size = (text as NSString).size(withAttributes: [.font: label.font as Any])
        widthConstraint.constant = max(20, ceil(size.width) + 12)
        needsDisplay = true
    }
}

private final class GroupCell: NSTableCellView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let crownView = NSImageView()
    private let badge = CountBadge()
    private var crownWidth: NSLayoutConstraint!
    private var nameGap: NSLayoutConstraint!

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = Design.primaryText
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        crownView.imageScaling = .scaleProportionallyDown
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        [nameLabel, crownView, badge].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        crownWidth = crownView.widthAnchor.constraint(equalToConstant: 0)
        nameGap = crownView.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor)
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameGap,
            crownView.centerYAnchor.constraint(equalTo: centerYAnchor),
            crownWidth,
            crownView.heightAnchor.constraint(equalToConstant: 14),
            badge.leadingAnchor.constraint(equalTo: crownView.trailingAnchor, constant: 6),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) { return nil }

    func update(name: String, count: Int, crown: NSImage?) {
        nameLabel.stringValue = name
        badge.text = "\(count)"
        crownView.image = crown
        crownView.isHidden = crown == nil
        crownWidth.constant = crown == nil ? 0 : 14
        nameGap.constant = crown == nil ? 0 : 6
    }
}

private final class ProfileCell: NSTableCellView {
    private let flagLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let cityLabel = NSTextField(labelWithString: "")
    private let dot = DotView()
    private let latencyLabel = NSTextField(labelWithString: "")
    private let starLabel = NSTextField(labelWithString: "☆")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        flagLabel.font = NSFont.systemFont(ofSize: 20)
        flagLabel.alignment = .center
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = Design.primaryText
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        cityLabel.font = NSFont.systemFont(ofSize: 11)
        cityLabel.textColor = Design.secondaryText
        cityLabel.lineBreakMode = .byTruncatingTail
        cityLabel.maximumNumberOfLines = 1
        latencyLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        latencyLabel.textColor = Design.secondaryText
        latencyLabel.alignment = .right
        starLabel.font = NSFont.systemFont(ofSize: 15)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cityLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        latencyLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        [flagLabel, titleLabel, cityLabel, dot, latencyLabel, starLabel].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            flagLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            flagLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            flagLabel.widthAnchor.constraint(equalToConstant: 32),
            titleLabel.leadingAnchor.constraint(equalTo: flagLabel.trailingAnchor, constant: 8),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -8),
            cityLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            cityLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            cityLabel.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -8),
            starLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            starLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            starLabel.widthAnchor.constraint(equalToConstant: 16),
            latencyLabel.trailingAnchor.constraint(equalTo: starLabel.leadingAnchor, constant: -10),
            latencyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.trailingAnchor.constraint(equalTo: latencyLabel.leadingAnchor, constant: -6),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7)
        ])
    }

    required init?(coder: NSCoder) { return nil }

    func update(profile: VPNProfile, latency: MainViewController.LatencyState?, selected: Bool) {
        let place = ServerPlaceParser.parse(profile.name)
        flagLabel.stringValue = place.flag
        titleLabel.stringValue = place.title
        cityLabel.stringValue = place.city.isEmpty ? profile.server : place.city
        if let latency = latency {
            latencyLabel.stringValue = latencyLabelText(latency)
            dot.color = latency == .testing || latency == .unavailable ? Design.tertiaryText : Design.latency
        } else {
            latencyLabel.stringValue = "—"
            dot.color = Design.tertiaryText
        }
        starLabel.stringValue = selected ? "★" : "☆"
        starLabel.textColor = selected ? Design.accent : Design.tertiaryText
    }

    private func latencyLabelText(_ latency: MainViewController.LatencyState) -> String {
        switch latency {
        case .testing: return "…"
        case .reachable(let milliseconds): return "\(milliseconds) ms"
        case .unavailable: return "—"
        }
    }
}

private final class ServerRowView: NSTableRowView {
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Design.background.setFill()
        bounds.fill()
        guard isSelected else { return }
        Design.accent.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 2), xRadius: 10, yRadius: 10).fill()
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

private final class WorldMapView: NSView {
    private var cache: NSImage?
    private var cacheSize: NSSize = .zero

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        cache = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let size = bounds.size
        guard size.width > 20, size.height > 20 else { return }
        if cache == nil || abs(cacheSize.width - size.width) > 12 || abs(cacheSize.height - size.height) > 12 {
            cache = render(size)
            cacheSize = size
        }
        cache?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
    }

    private func render(_ size: NSSize) -> NSImage? {
        let image = NSImage(size: size)
        image.lockFocus()
        Design.mapDot.setFill()
        let continents: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (0.19, 0.67, 0.18, 0.20), (0.31, 0.31, 0.09, 0.24),
            (0.48, 0.69, 0.08, 0.09), (0.52, 0.45, 0.10, 0.20),
            (0.68, 0.66, 0.24, 0.19), (0.82, 0.30, 0.10, 0.08)
        ]
        var y: CGFloat = 8
        while y < size.height - 8 {
            var x: CGFloat = 8
            while x < size.width - 8 {
                let nx = x / size.width
                let ny = y / size.height
                let inside = continents.contains { continent in
                    let dx = (nx - continent.0) / continent.2
                    let dy = (ny - continent.1) / continent.3
                    return dx * dx + dy * dy <= 1
                }
                if inside {
                    NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 2.4, height: 2.4)).fill()
                }
                x += 12
            }
            y += 12
        }
        image.unlockFocus()
        return image
    }
}
