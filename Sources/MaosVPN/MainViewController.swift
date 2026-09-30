import AppKit
import MaosVPNCore

final class MainViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private enum LatencyState: Equatable {
        case testing
        case reachable(Int)
        case unavailable
    }

    let vpnController = VPNController()
    private let subscriptionService = SubscriptionService()
    private let defaults = UserDefaults.standard
    private let libraryKey = "subscriptionLibraryV2"

    private var subscriptions: [SubscriptionEntry] = []
    private var libraryWasLoaded = false
    private var subscriptionRequestInProgress = false

    private let outlineView = NSOutlineView()
    private let searchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: L10n.text(.disconnected))
    private let statusDot = NSView()
    private let connectionSubtitleLabel = NSTextField(labelWithString: "")
    private let selectedNameLabel = NSTextField(labelWithString: L10n.text(.addSubscription))
    private let selectedDetailsLabel = NSTextField(labelWithString: L10n.text(.serversWillAppear))
    private let protocolValueLabel = NSTextField(labelWithString: "—")
    private let selectedLatencyLabel = NSTextField(labelWithString: "—")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let connectButton = PowerButton(title: "", target: nil, action: nil)
    private let addSubscriptionButton = NSButton(title: "", target: nil, action: nil)
    private let pingButton = NSButton(title: L10n.text(.testPing), target: nil, action: nil)
    private let autoSelectButton = NSButton(title: L10n.text(.autoSelect), target: nil, action: nil)
    private let progress = NSProgressIndicator()

    private let onboardingURLField = NSTextField()
    private let onboardingAddButton = NSButton(title: "", target: nil, action: nil)

    private var latencyByProfileID: [UUID: LatencyState] = [:]
    private var latencyTestID = UUID()
    private var latencyTestInProgress = false
    private var selectFastestWhenFinished = false
    private let latencyQueue = DispatchQueue(label: "app.maosvpn.latency", qos: .userInitiated, attributes: .concurrent)

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
        view = makeRootView()
        buildCurrentInterface()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureControllerCallbacks()
        updateState(vpnController.isConnected ? .connected : .disconnected)
    }

    deinit { connectionTimer?.invalidate() }

    private func makeRootView() -> NSView {
        ThemedBackgroundView(
            frame: NSRect(x: 0, y: 0, width: 1040, height: 680),
            color: .windowBackgroundColor
        )
    }

    private func buildCurrentInterface() {
        view.subviews.forEach { $0.removeFromSuperview() }
        if isShowingOnboarding {
            buildOnboardingInterface()
        } else {
            buildMainInterface()
        }
    }

    private func buildOnboardingInterface() {
        let languagePopup = makeLanguagePopup()
        let icon = NSTextField(labelWithString: "◆")
        icon.font = NSFont.systemFont(ofSize: 34, weight: .bold)
        icon.textColor = accent
        let appName = NSTextField(labelWithString: "Maos VPN")
        appName.font = NSFont.systemFont(ofSize: 25, weight: .semibold)

        let title = NSTextField(labelWithString: AppLanguage.text(
            russian: "Добавьте первую подписку",
            english: "Add your first subscription"
        ))
        title.font = NSFont.systemFont(ofSize: 30, weight: .bold)
        title.alignment = .center
        let subtitle = NSTextField(wrappingLabelWithString: AppLanguage.text(
            russian: "Вставьте ссылку — серверы сохранятся локально, а сама ссылка больше не будет показана в приложении.",
            english: "Paste a URL. Servers will be stored locally and the URL will no longer be shown in the app."
        ))
        subtitle.font = NSFont.systemFont(ofSize: 14)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center

        onboardingURLField.placeholderString = "https://example.com/sub/..."
        onboardingURLField.font = NSFont.systemFont(ofSize: 14)
        onboardingURLField.stringValue = ""
        onboardingAddButton.title = AppLanguage.text(russian: "Добавить подписку", english: "Add subscription")
        onboardingAddButton.target = self
        onboardingAddButton.action = #selector(importInitialSubscription)
        onboardingAddButton.bezelStyle = .rounded
        onboardingAddButton.keyEquivalent = "\r"
        onboardingAddButton.font = NSFont.systemFont(ofSize: 14, weight: .semibold)

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        messageLabel.font = NSFont.systemFont(ofSize: 12)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 3

        let card = ThemedCardView()
        [title, subtitle, onboardingURLField, onboardingAddButton, progress, messageLabel].forEach {
            card.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        [languagePopup, icon, appName, card].forEach {
            view.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            languagePopup.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            languagePopup.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            languagePopup.widthAnchor.constraint(equalToConstant: 96),
            icon.centerXAnchor.constraint(equalTo: view.centerXAnchor, constant: -74),
            icon.bottomAnchor.constraint(equalTo: card.topAnchor, constant: -24),
            appName.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            appName.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 28),
            card.widthAnchor.constraint(equalToConstant: 590),
            card.heightAnchor.constraint(equalToConstant: 290),
            title.topAnchor.constraint(equalTo: card.topAnchor, constant: 34),
            title.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 34),
            title.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -34),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            subtitle.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 54),
            subtitle.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -54),
            onboardingURLField.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 24),
            onboardingURLField.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 42),
            onboardingURLField.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -42),
            onboardingURLField.heightAnchor.constraint(equalToConstant: 30),
            onboardingAddButton.topAnchor.constraint(equalTo: onboardingURLField.bottomAnchor, constant: 18),
            onboardingAddButton.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            onboardingAddButton.widthAnchor.constraint(equalToConstant: 190),
            onboardingAddButton.heightAnchor.constraint(equalToConstant: 38),
            progress.leadingAnchor.constraint(equalTo: onboardingAddButton.trailingAnchor, constant: 12),
            progress.centerYAnchor.constraint(equalTo: onboardingAddButton.centerYAnchor),
            messageLabel.topAnchor.constraint(equalTo: onboardingAddButton.bottomAnchor, constant: 12),
            messageLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 36),
            messageLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -36)
        ])
    }

    private func buildMainInterface() {
        let header = makeHeader()
        let sidebar = makeSidebar()
        let content = makeMainContent()
        [header, sidebar, content].forEach {
            view.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 78),
            sidebar.topAnchor.constraint(equalTo: header.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 340),
            content.topAnchor.constraint(equalTo: header.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        outlineView.reloadData()
        subscriptions.forEach { outlineView.expandItem($0) }
        selectFirstProfileIfNeeded()
        updateSelection()
        updateState(vpnController.state)
    }

    private func makeHeader() -> NSView {
        let container = ThemedBackgroundView(color: .windowBackgroundColor)
        let divider = NSBox()
        divider.boxType = .separator
        let verticalDivider = NSBox()
        verticalDivider.boxType = .separator
        searchField.placeholderString = AppLanguage.text(russian: "Поиск серверов…", english: "Search servers…")
        searchField.font = NSFont.systemFont(ofSize: 14)
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(filterServers(_:))
        searchField.stringValue = searchQuery
        let languagePopup = makeLanguagePopup()
        addSubscriptionButton.title = AppLanguage.text(russian: "＋  Добавить подписку", english: "＋  Add subscription")
        addSubscriptionButton.target = self
        addSubscriptionButton.action = #selector(showAddSubscriptionDialog)
        addSubscriptionButton.isBordered = false
        addSubscriptionButton.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        addSubscriptionButton.wantsLayer = true
        addSubscriptionButton.layer?.cornerRadius = 10
        addSubscriptionButton.layer?.backgroundColor = accent.cgColor
        addSubscriptionButton.contentTintColor = .white
        addSubscriptionButton.attributedTitle = NSAttributedString(
            string: addSubscriptionButton.title,
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white]
        )
        [searchField, languagePopup, addSubscriptionButton, verticalDivider, divider].forEach {
            container.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
            searchField.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 296),
            searchField.heightAnchor.constraint(equalToConstant: 36),
            verticalDivider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 339),
            verticalDivider.topAnchor.constraint(equalTo: container.topAnchor),
            verticalDivider.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            addSubscriptionButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            addSubscriptionButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            addSubscriptionButton.widthAnchor.constraint(equalToConstant: 174),
            addSubscriptionButton.heightAnchor.constraint(equalToConstant: 42),
            languagePopup.trailingAnchor.constraint(equalTo: addSubscriptionButton.leadingAnchor, constant: -12),
            languagePopup.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            languagePopup.widthAnchor.constraint(equalToConstant: 106),
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func makeSidebar() -> NSView {
        let container = ThemedBackgroundView(color: .controlBackgroundColor)
        let heading = NSTextField(labelWithString: L10n.text(.serversHeading))
        heading.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        countLabel.font = NSFont.systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.stringValue = serverCountText(allProfiles.count)
        pingButton.title = L10n.text(.testPing)
        pingButton.target = self
        pingButton.action = #selector(testPing)
        pingButton.bezelStyle = .rounded
        pingButton.controlSize = .small
        autoSelectButton.title = L10n.text(.autoSelect)
        autoSelectButton.target = self
        autoSelectButton.action = #selector(autoSelectFastest)
        autoSelectButton.bezelStyle = .rounded
        autoSelectButton.controlSize = .small

        let column: NSTableColumn
        if let existing = outlineView.tableColumns.first {
            column = existing
        } else {
            column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("server"))
            outlineView.addTableColumn(column)
            outlineView.outlineTableColumn = column
        }
        column.width = 320
        outlineView.headerView = nil
        outlineView.backgroundColor = .clear
        outlineView.selectionHighlightStyle = .regular
        outlineView.indentationPerLevel = 14
        outlineView.dataSource = self
        outlineView.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        [heading, countLabel, pingButton, autoSelectButton, scroll].forEach {
            container.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: container.topAnchor, constant: 19),
            heading.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            countLabel.leadingAnchor.constraint(equalTo: heading.trailingAnchor, constant: 10),
            countLabel.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            pingButton.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 15),
            pingButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            pingButton.widthAnchor.constraint(equalToConstant: 92),
            autoSelectButton.leadingAnchor.constraint(equalTo: pingButton.trailingAnchor, constant: 8),
            autoSelectButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            autoSelectButton.centerYAnchor.constraint(equalTo: pingButton.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: pingButton.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10)
        ])
        return container
    }

    private func makeMainContent() -> NSView {
        let container = ThemedBackgroundView(color: .windowBackgroundColor)
        let map = WorldMapDotsView()
        let halo = ConnectionHaloView()
        let serverCard = ThemedCardView()
        let protocolCard = ThemedCardView()

        selectedNameLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        selectedNameLabel.lineBreakMode = .byTruncatingTail
        selectedDetailsLabel.font = NSFont.systemFont(ofSize: 12)
        selectedDetailsLabel.textColor = .secondaryLabelColor
        selectedDetailsLabel.lineBreakMode = .byTruncatingTail
        selectedLatencyLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        selectedLatencyLabel.textColor = .systemGreen
        selectedLatencyLabel.alignment = .right
        protocolValueLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        let serverIcon = InfoIconView(symbol: "◎")
        let protocolIcon = InfoIconView(symbol: "⌘")
        let protocolCaption = NSTextField(labelWithString: AppLanguage.text(russian: "Протокол", english: "Protocol"))
        protocolCaption.font = NSFont.systemFont(ofSize: 11)
        protocolCaption.textColor = .secondaryLabelColor
        let serverChevron = NSTextField(labelWithString: "›")
        serverChevron.font = NSFont.systemFont(ofSize: 27, weight: .light)
        serverChevron.textColor = .tertiaryLabelColor
        let protocolChevron = NSTextField(labelWithString: "›")
        protocolChevron.font = NSFont.systemFont(ofSize: 27, weight: .light)
        protocolChevron.textColor = .tertiaryLabelColor
        [serverIcon, selectedNameLabel, selectedDetailsLabel, selectedLatencyLabel, serverChevron].forEach {
            serverCard.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false
        }
        [protocolIcon, protocolCaption, protocolValueLabel, protocolChevron].forEach {
            protocolCard.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false
        }
        connectButton.target = self
        connectButton.action = #selector(toggleConnection)
        connectButton.isBordered = false
        connectButton.wantsLayer = true
        connectButton.accentColor = accent
        statusLabel.font = NSFont.systemFont(ofSize: 27, weight: .bold)
        statusLabel.alignment = .center
        connectionSubtitleLabel.stringValue = AppLanguage.text(russian: "Нажмите, чтобы подключиться к VPN", english: "Tap to connect to a VPN server")
        connectionSubtitleLabel.font = NSFont.systemFont(ofSize: 13)
        connectionSubtitleLabel.textColor = .secondaryLabelColor
        connectionSubtitleLabel.alignment = .center
        let hint = NSTextField(wrappingLabelWithString: L10n.text(.adminHint))
        hint.font = NSFont.systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        messageLabel.font = NSFont.systemFont(ofSize: 12)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 3
        [map, halo, connectButton, statusLabel, connectionSubtitleLabel, serverCard, protocolCard, hint, messageLabel].forEach {
            container.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            map.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            map.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            map.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            map.heightAnchor.constraint(equalToConstant: 330),
            halo.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            halo.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            halo.widthAnchor.constraint(equalToConstant: 245),
            halo.heightAnchor.constraint(equalToConstant: 245),
            connectButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            connectButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 50),
            connectButton.widthAnchor.constraint(equalToConstant: 160),
            connectButton.heightAnchor.constraint(equalToConstant: 160),
            statusLabel.topAnchor.constraint(equalTo: halo.bottomAnchor, constant: -4),
            statusLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            connectionSubtitleLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            connectionSubtitleLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            serverCard.topAnchor.constraint(equalTo: connectionSubtitleLabel.bottomAnchor, constant: 18),
            serverCard.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            serverCard.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),
            serverCard.heightAnchor.constraint(equalToConstant: 64),
            protocolCard.topAnchor.constraint(equalTo: serverCard.bottomAnchor, constant: 12),
            protocolCard.leadingAnchor.constraint(equalTo: serverCard.leadingAnchor),
            protocolCard.trailingAnchor.constraint(equalTo: serverCard.trailingAnchor),
            protocolCard.heightAnchor.constraint(equalToConstant: 64),
            serverIcon.leadingAnchor.constraint(equalTo: serverCard.leadingAnchor, constant: 16),
            serverIcon.centerYAnchor.constraint(equalTo: serverCard.centerYAnchor),
            serverIcon.widthAnchor.constraint(equalToConstant: 40),
            serverIcon.heightAnchor.constraint(equalToConstant: 40),
            selectedNameLabel.leadingAnchor.constraint(equalTo: serverIcon.trailingAnchor, constant: 13),
            selectedNameLabel.topAnchor.constraint(equalTo: serverCard.topAnchor, constant: 13),
            selectedNameLabel.trailingAnchor.constraint(lessThanOrEqualTo: selectedLatencyLabel.leadingAnchor, constant: -10),
            selectedDetailsLabel.leadingAnchor.constraint(equalTo: selectedNameLabel.leadingAnchor),
            selectedDetailsLabel.topAnchor.constraint(equalTo: selectedNameLabel.bottomAnchor, constant: 3),
            selectedDetailsLabel.trailingAnchor.constraint(lessThanOrEqualTo: selectedLatencyLabel.leadingAnchor, constant: -10),
            selectedLatencyLabel.trailingAnchor.constraint(equalTo: serverChevron.leadingAnchor, constant: -8),
            selectedLatencyLabel.centerYAnchor.constraint(equalTo: serverCard.centerYAnchor),
            selectedLatencyLabel.widthAnchor.constraint(equalToConstant: 76),
            serverChevron.trailingAnchor.constraint(equalTo: serverCard.trailingAnchor, constant: -14),
            serverChevron.centerYAnchor.constraint(equalTo: serverCard.centerYAnchor),
            protocolIcon.leadingAnchor.constraint(equalTo: protocolCard.leadingAnchor, constant: 16),
            protocolIcon.centerYAnchor.constraint(equalTo: protocolCard.centerYAnchor),
            protocolIcon.widthAnchor.constraint(equalToConstant: 40),
            protocolIcon.heightAnchor.constraint(equalToConstant: 40),
            protocolCaption.leadingAnchor.constraint(equalTo: protocolIcon.trailingAnchor, constant: 13),
            protocolCaption.topAnchor.constraint(equalTo: protocolCard.topAnchor, constant: 12),
            protocolValueLabel.leadingAnchor.constraint(equalTo: protocolCaption.leadingAnchor),
            protocolValueLabel.topAnchor.constraint(equalTo: protocolCaption.bottomAnchor, constant: 2),
            protocolChevron.trailingAnchor.constraint(equalTo: protocolCard.trailingAnchor, constant: -14),
            protocolChevron.centerYAnchor.constraint(equalTo: protocolCard.centerYAnchor),
            hint.topAnchor.constraint(equalTo: protocolCard.bottomAnchor, constant: 14),
            hint.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 42),
            hint.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -42),
            messageLabel.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 8),
            messageLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 42),
            messageLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -42),
            messageLabel.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -10)
        ])
        return container
    }

    private func makeLanguagePopup() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: ["Русский", "English"])
        popup.selectItem(at: AppLanguage.current == .russian ? 0 : 1)
        popup.target = self
        popup.action = #selector(changeLanguage(_:))
        popup.controlSize = .small
        return popup
    }

    @objc private func filterServers(_ sender: NSSearchField) {
        searchQuery = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        outlineView.deselectAll(nil)
        outlineView.reloadData()
        visibleSubscriptions.forEach { outlineView.expandItem($0) }
        countLabel.stringValue = serverCountText(visibleSubscriptions.reduce(0) { $0 + $1.filteredNodes(matching: searchQuery).count })
        if let first = visibleSubscriptions.first?.filteredNodes(matching: searchQuery).first { select(node: first) }
        updateSelection()
    }

    @objc private func importInitialSubscription() {
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
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.stringValue = L10n.text(.loadingSubscription)
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
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.stringValue = L10n.text(.loadingSubscription)
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
        outlineView.expandItem(entry)
        if let first = entry.profileNodes.first { select(node: first) }
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.stringValue = "\(L10n.text(.subscriptionUpdated)) \(profiles.count)."
    }

    @objc private func toggleConnection() {
        messageLabel.textColor = .secondaryLabelColor
        if vpnController.isConnected {
            vpnController.disconnect { [weak self] error in if let error = error { self?.showError(error) } }
        } else if let profile = selectedProfile {
            vpnController.connect(profile: profile) { [weak self] error in if let error = error { self?.showError(error) } }
        }
    }

    @objc private func changeLanguage(_ sender: NSPopUpButton) {
        let language: AppLanguage = sender.indexOfSelectedItem == 1 ? .english : .russian
        guard language != AppLanguage.current else { return }
        AppLanguage.current = language
        NotificationCenter.default.post(name: .maosVPNLanguageDidChange, object: nil)
        buildCurrentInterface()
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.stringValue = L10n.text(.languageChanged)
    }

    private func configureControllerCallbacks() {
        vpnController.onStateChange = { [weak self] state in self?.updateState(state) }
        vpnController.onLog = { [weak self] text in self?.messageLabel.stringValue = text }
    }

    private func updateState(_ state: VPNController.State) {
        guard !isShowingOnboarding else {
            onboardingAddButton.isEnabled = !subscriptionRequestInProgress
            onboardingURLField.isEnabled = !subscriptionRequestInProgress
            return
        }
        switch state {
        case .disconnected:
            stopConnectionTimer(reset: true)
            statusLabel.stringValue = L10n.text(.disconnected)
            connectionSubtitleLabel.stringValue = AppLanguage.text(russian: "Нажмите, чтобы подключиться к VPN", english: "Tap to connect to a VPN server")
            statusDot.layer?.backgroundColor = NSColor.systemGray.cgColor
            connectButton.connectionStyle = .idle
            connectButton.isEnabled = selectedProfile != nil && !subscriptionRequestInProgress && !latencyTestInProgress
            outlineView.isEnabled = !subscriptionRequestInProgress
            addSubscriptionButton.isEnabled = !subscriptionRequestInProgress
            updateLatencyButtons()
        case .connecting:
            statusLabel.stringValue = L10n.text(.connecting)
            connectionSubtitleLabel.stringValue = AppLanguage.text(russian: "Создаём защищённое соединение…", english: "Creating a secure connection…")
            statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            connectButton.connectionStyle = .working
            connectButton.isEnabled = false
            setMainControlsEnabled(false)
        case .connected:
            if connectedSince == nil { connectedSince = Date() }
            startConnectionTimer()
            statusLabel.stringValue = L10n.text(.connected)
            connectionSubtitleLabel.stringValue = AppLanguage.text(russian: "Весь трафик защищён", english: "All traffic is protected")
            statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            connectButton.connectionStyle = .connected
            connectButton.isEnabled = true
            setMainControlsEnabled(false)
        case .disconnecting:
            statusLabel.stringValue = L10n.text(.disconnecting)
            connectionSubtitleLabel.stringValue = AppLanguage.text(russian: "Завершаем соединение…", english: "Closing the connection…")
            statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            connectButton.connectionStyle = .working
            connectButton.isEnabled = false
            setMainControlsEnabled(false)
        }
        updateConnectButtonTitle(for: state)
    }

    private func setMainControlsEnabled(_ enabled: Bool) {
        outlineView.isEnabled = enabled
        addSubscriptionButton.isEnabled = enabled
        pingButton.isEnabled = enabled
        autoSelectButton.isEnabled = enabled
    }

    private func updateConnectButtonTitle(for state: VPNController.State) {
        let label: String
        let duration: String?
        switch state {
        case .disconnected: label = L10n.text(.connect); duration = nil
        case .connecting: label = L10n.text(.connecting); duration = nil
        case .connected: label = L10n.text(.connected); duration = connectionDurationText()
        case .disconnecting: label = L10n.text(.disconnecting); duration = nil
        }
        let fullText = duration == nil ? "⏻\n\(label)" : "⏻\n\(duration!)"
        let attributed = NSMutableAttributedString(string: fullText)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 4
        attributed.addAttributes([
            .foregroundColor: state == .connected ? NSColor.white : accent,
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
            .paragraphStyle: paragraph
        ], range: NSRange(location: 0, length: (fullText as NSString).length))
        attributed.addAttribute(.font, value: NSFont.systemFont(ofSize: 34, weight: .light), range: NSRange(location: 0, length: 1))
        if let duration = duration, let range = fullText.range(of: duration) {
            attributed.addAttribute(.font, value: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium), range: NSRange(range, in: fullText))
        }
        connectButton.attributedTitle = attributed
        connectButton.alphaValue = connectButton.isEnabled ? 1 : 0.65
    }

    private func startConnectionTimer() {
        guard connectionTimer == nil else { return }
        connectionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.updateConnectButtonTitle(for: self.vpnController.state)
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
            selectedNameLabel.stringValue = L10n.text(.addSubscription)
            selectedDetailsLabel.stringValue = L10n.text(.serversWillAppear)
            selectedLatencyLabel.stringValue = "—"
            protocolValueLabel.stringValue = "—"
            connectButton.isEnabled = false
            updateConnectButtonTitle(for: vpnController.state)
            return
        }
        selectedNameLabel.stringValue = profile.name
        selectedDetailsLabel.stringValue = "\(profile.server):\(profile.port)"
        protocolValueLabel.stringValue = profile.kind.title
        if let latency = latencyByProfileID[profile.id] {
            selectedLatencyLabel.stringValue = "●  \(latencyText(latency))"
            selectedLatencyLabel.textColor = latencyColor(latency)
        } else {
            selectedLatencyLabel.stringValue = "●  —"
            selectedLatencyLabel.textColor = .tertiaryLabelColor
        }
        connectButton.isEnabled = (vpnController.state == .disconnected || vpnController.state == .connected) && !latencyTestInProgress
        updateConnectButtonTitle(for: vpnController.state)
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
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { item is SubscriptionEntry ? 42 : 56 }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let subscription = item as? SubscriptionEntry {
            let identifier = NSUserInterfaceItemIdentifier("SubscriptionCell")
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? makeSubscriptionCell(identifier)
            (cell.viewWithTag(1) as? NSTextField)?.stringValue = subscription.name
            (cell.viewWithTag(2) as? NSTextField)?.stringValue = "\(subscription.filteredNodes(matching: searchQuery).count)"
            (cell.viewWithTag(3) as? NSTextField)?.stringValue = subscription.sourceKind == .json ? "{ }" : "●"
            return cell
        }
        guard let node = item as? ProfileNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ProfileCell")
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? makeProfileCell(identifier)
        let profile = node.profile
        (cell.viewWithTag(1) as? NSTextField)?.stringValue = profile.name
        (cell.viewWithTag(2) as? NSTextField)?.stringValue = "\(profile.kind.title)  •  \(profile.server):\(profile.port)"
        let latencyLabel = cell.viewWithTag(3) as? NSTextField
        if let latency = latencyByProfileID[profile.id] {
            latencyLabel?.stringValue = latencyText(latency)
            latencyLabel?.textColor = latencyColor(latency)
            (cell.viewWithTag(4) as? NSTextField)?.textColor = latencyColor(latency)
        } else {
            latencyLabel?.stringValue = "—"
            latencyLabel?.textColor = .tertiaryLabelColor
            (cell.viewWithTag(4) as? NSTextField)?.textColor = .tertiaryLabelColor
        }
        return cell
    }

    private func makeSubscriptionCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let icon = NSTextField(labelWithString: "")
        icon.tag = 3
        icon.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        icon.textColor = accent
        let title = NSTextField(labelWithString: "")
        title.tag = 1
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let count = NSTextField(labelWithString: "")
        count.tag = 2
        count.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        count.textColor = .secondaryLabelColor
        [icon, title, count].forEach { cell.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: count.leadingAnchor, constant: -8),
            count.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            count.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func makeProfileCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let title = NSTextField(labelWithString: "")
        title.tag = 1
        title.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: "")
        detail.tag = 2
        detail.font = NSFont.systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let latency = NSTextField(labelWithString: "")
        latency.tag = 3
        latency.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        latency.alignment = .right
        let latencyDot = NSTextField(labelWithString: "●")
        latencyDot.tag = 4
        latencyDot.font = NSFont.systemFont(ofSize: 8)
        let favorite = NSTextField(labelWithString: "☆")
        favorite.tag = 5
        favorite.font = NSFont.systemFont(ofSize: 21, weight: .light)
        favorite.textColor = .secondaryLabelColor
        [title, detail, latencyDot, latency, favorite].forEach { cell.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            title.trailingAnchor.constraint(equalTo: latencyDot.leadingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 10),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: latencyDot.leadingAnchor, constant: -8),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            latencyDot.trailingAnchor.constraint(equalTo: latency.leadingAnchor, constant: -5),
            latencyDot.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            latency.trailingAnchor.constraint(equalTo: favorite.leadingAnchor, constant: -8),
            latency.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            latency.widthAnchor.constraint(equalToConstant: 52),
            favorite.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
            favorite.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            favorite.widthAnchor.constraint(equalToConstant: 22)
        ])
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        RoundedServerRowView()
    }

    func outlineViewSelectionDidChange(_ notification: Notification) { updateSelection() }

    private func selectFirstProfileIfNeeded() {
        guard selectedNode == nil, let first = allNodes.first else { return }
        select(node: first)
    }

    private func select(node: ProfileNode) {
        if let subscription = subscriptions.first(where: { $0.id == node.subscriptionID }) { outlineView.expandItem(subscription) }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        updateSelection()
    }

    @objc private func testPing() { startLatencyTest(selectFastest: false) }
    @objc private func autoSelectFastest() { startLatencyTest(selectFastest: true) }

    private func startLatencyTest(selectFastest: Bool) {
        let snapshot = allNodes
        guard !snapshot.isEmpty, !latencyTestInProgress, vpnController.state == .disconnected else { return }
        latencyTestInProgress = true
        selectFastestWhenFinished = selectFastest
        latencyTestID = UUID()
        let testID = latencyTestID
        snapshot.forEach { latencyByProfileID[$0.profile.id] = .testing }
        outlineView.reloadData()
        subscriptions.forEach { outlineView.expandItem($0) }
        updateSelection()
        updateState(vpnController.state)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.stringValue = L10n.text(.testingPing)
        let group = DispatchGroup()
        for node in snapshot {
            group.enter()
            latencyQueue.async { [weak self] in
                let milliseconds = self?.measureLatency(to: node.profile.server)
                DispatchQueue.main.async {
                    defer { group.leave() }
                    guard let self = self, self.latencyTestID == testID else { return }
                    self.latencyByProfileID[node.profile.id] = milliseconds.map(LatencyState.reachable) ?? .unavailable
                    self.outlineView.reloadItem(node)
                    if self.selectedNode === node { self.updateSelection() }
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self = self, self.latencyTestID == testID else { return }
            self.latencyTestInProgress = false
            self.updateState(self.vpnController.state)
            if self.selectFastestWhenFinished { self.selectFastestProfile() }
            else { self.messageLabel.stringValue = L10n.text(.pingFinished) }
            self.selectFastestWhenFinished = false
        }
    }

    private func measureLatency(to host: String) -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ping")
        process.arguments = ["-n", "-c", "1", "-W", "1000", host]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
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
            messageLabel.textColor = .systemOrange
            messageLabel.stringValue = L10n.text(.pingUnavailable)
            return
        }
        select(node: result.0)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.stringValue = "\(L10n.text(.fastestSelected)) \(result.0.profile.name) — \(result.1) ms."
    }

    private func updateLatencyButtons() {
        let enabled = !allNodes.isEmpty && !latencyTestInProgress && !subscriptionRequestInProgress && vpnController.state == .disconnected
        pingButton.isEnabled = enabled
        autoSelectButton.isEnabled = enabled
    }

    private func latencyText(_ latency: LatencyState) -> String {
        switch latency {
        case .testing: return "…"
        case .reachable(let milliseconds): return "\(milliseconds) ms"
        case .unavailable: return "—"
        }
    }

    private func latencyColor(_ latency: LatencyState) -> NSColor {
        switch latency {
        case .testing, .unavailable: return .tertiaryLabelColor
        case .reachable(let milliseconds):
            if milliseconds < 100 { return .systemGreen }
            if milliseconds < 250 { return .systemOrange }
            return .systemRed
        }
    }

    private func setSubscriptionBusy(_ busy: Bool) {
        subscriptionRequestInProgress = busy
        if busy {
            progress.startAnimation(nil)
        } else {
            progress.stopAnimation(nil)
        }
        if isShowingOnboarding {
            onboardingAddButton.isEnabled = !busy
            onboardingURLField.isEnabled = !busy
        } else { updateState(vpnController.state) }
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

    private func showError(_ error: Error) {
        messageLabel.textColor = .systemRed
        messageLabel.stringValue = error.localizedDescription
        NSSound.beep()
    }

    private func serverCountText(_ count: Int) -> String {
        if AppLanguage.current == .english { return "\(count) \(count == 1 ? "server" : "servers")" }
        let mod10 = count % 10
        let mod100 = count % 100
        if mod10 == 1 && mod100 != 11 { return "\(count) \(L10n.text(.serverSingular))" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "\(count) \(L10n.text(.serverFew))" }
        return "\(count) \(L10n.text(.serverMany))"
    }

    private var accent: NSColor { NSColor(calibratedRed: 0.12, green: 0.48, blue: 0.92, alpha: 1) }
}

private final class ThemedBackgroundView: NSView {
    private let fillColor: NSColor
    init(frame: NSRect = .zero, color: NSColor) {
        fillColor = color
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { return nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        if #available(macOS 11.0, *) {
            effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = fillColor.cgColor }
        } else {
            let previousAppearance = NSAppearance.current
            NSAppearance.current = effectiveAppearance
            layer?.backgroundColor = fillColor.cgColor
            NSAppearance.current = previousAppearance
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

private final class ThemedCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
    }
    required init?(coder: NSCoder) { return nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        if #available(macOS 11.0, *) {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
                layer?.borderColor = NSColor.separatorColor.cgColor
            }
        } else {
            let previousAppearance = NSAppearance.current
            NSAppearance.current = effectiveAppearance
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
            NSAppearance.current = previousAppearance
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

private extension SubscriptionEntry {
    func filteredNodes(matching rawQuery: String) -> [ProfileNode] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return profileNodes }
        if name.localizedCaseInsensitiveContains(query) { return profileNodes }
        return profileNodes.filter {
            $0.profile.name.localizedCaseInsensitiveContains(query) ||
            $0.profile.server.localizedCaseInsensitiveContains(query) ||
            $0.profile.kind.title.localizedCaseInsensitiveContains(query)
        }
    }
}

private enum PowerConnectionStyle {
    case idle
    case working
    case connected
}

private final class PowerButton: NSButton {
    var accentColor: NSColor = .systemBlue { didSet { needsDisplay = true } }
    var connectionStyle: PowerConnectionStyle = .idle { didSet { needsDisplay = true } }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = bounds.width / 2
        layer?.borderWidth = 1
        layer?.shadowOffset = .zero
        layer?.shadowRadius = connectionStyle == .connected ? 20 : 17
        layer?.shadowOpacity = connectionStyle == .working ? 0.25 : 0.42
        applyAppearance {
            let fill: NSColor
            switch connectionStyle {
            case .connected: fill = accentColor
            case .working: fill = accentColor.withAlphaComponent(0.10)
            case .idle: fill = NSColor.controlBackgroundColor
            }
            layer?.backgroundColor = fill.cgColor
            layer?.borderColor = accentColor.withAlphaComponent(0.40).cgColor
            layer?.shadowColor = accentColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func applyAppearance(_ work: () -> Void) {
        if #available(macOS 11.0, *) {
            effectiveAppearance.performAsCurrentDrawingAppearance(work)
        } else {
            let previousAppearance = NSAppearance.current
            NSAppearance.current = effectiveAppearance
            work()
            NSAppearance.current = previousAppearance
        }
    }
}

private final class ConnectionHaloView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let accent = NSColor(calibratedRed: 0.12, green: 0.48, blue: 0.92, alpha: 1)
        for inset in stride(from: CGFloat(4), through: 44, by: 20) {
            let ring = bounds.insetBy(dx: inset, dy: inset)
            accent.withAlphaComponent(inset == 44 ? 0.20 : 0.09).setStroke()
            let path = NSBezierPath(ovalIn: ring)
            path.lineWidth = 1
            path.stroke()
        }
    }
}

private final class WorldMapDotsView: NSView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = NSColor.systemBlue.withAlphaComponent(isDark ? 0.10 : 0.075)
        color.setFill()
        let width = bounds.width
        let height = bounds.height
        guard width > 0, height > 0 else { return }
        let continents: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (0.19, 0.67, 0.18, 0.20), (0.31, 0.31, 0.09, 0.24),
            (0.48, 0.69, 0.08, 0.09), (0.52, 0.45, 0.10, 0.20),
            (0.68, 0.66, 0.24, 0.19), (0.82, 0.30, 0.10, 0.08)
        ]
        var y: CGFloat = 7
        while y < height - 7 {
            var x: CGFloat = 7
            while x < width - 7 {
                let nx = x / width
                let ny = y / height
                let inside = continents.contains { continent in
                    let dx = (nx - continent.0) / continent.2
                    let dy = (ny - continent.1) / continent.3
                    return dx * dx + dy * dy <= 1
                }
                if inside { NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 3.2, height: 3.2)).fill() }
                x += 9
            }
            y += 9
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private final class InfoIconView: NSView {
    private let symbol: String

    init(symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { return nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let accent = NSColor(calibratedRed: 0.12, green: 0.48, blue: 0.92, alpha: 1)
        accent.withAlphaComponent(0.11).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 21, weight: .medium),
            .foregroundColor: accent
        ]
        let size = symbol.size(withAttributes: attributes)
        symbol.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}

private final class RoundedServerRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let selectedRect = bounds.insetBy(dx: 3, dy: 2)
        NSColor.systemBlue.withAlphaComponent(0.13).setFill()
        NSBezierPath(roundedRect: selectedRect, xRadius: 9, yRadius: 9).fill()
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: NSRect(x: selectedRect.minX, y: selectedRect.minY + 5, width: 3, height: selectedRect.height - 10), xRadius: 1.5, yRadius: 1.5).fill()
    }
}
