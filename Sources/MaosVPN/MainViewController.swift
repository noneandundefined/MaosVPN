import AppKit
import MaosVPNCore

final class MainViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private enum LatencyState: Equatable {
        case testing
        case reachable(Int)
        case unavailable
    }

    let vpnController = VPNController()
    private let subscriptionService = SubscriptionService()
    private let defaults = UserDefaults.standard

    private var profiles: [VPNProfile] = []
    private var selectedProfile: VPNProfile? {
        let row = serverTable.selectedRow
        return row >= 0 && row < profiles.count ? profiles[row] : nil
    }

    private let serverTable = NSTableView()
    private let subscriptionField = NSTextField()
    private let subscriptionLabel = NSTextField(labelWithString: L10n.text(.subscriptionURL))
    private let importButton = NSButton(title: L10n.text(.load), target: nil, action: nil)
    private let pingButton = NSButton(title: L10n.text(.testPing), target: nil, action: nil)
    private let autoSelectButton = NSButton(title: L10n.text(.autoSelect), target: nil, action: nil)
    private let connectButton = NSButton(title: L10n.text(.connect), target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: L10n.text(.disconnected))
    private let statusDot = NSView()
    private let selectedNameLabel = NSTextField(labelWithString: L10n.text(.addSubscription))
    private let selectedDetailsLabel = NSTextField(labelWithString: L10n.text(.serversWillAppear))
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let countLabel = NSTextField(labelWithString: "0 \(L10n.text(.serverMany))")
    private let progress = NSProgressIndicator()
    private var subscriptionRequestInProgress = false
    private var latencyByProfileID: [UUID: LatencyState] = [:]
    private var latencyTestID = UUID()
    private var latencyTestInProgress = false
    private var selectFastestWhenFinished = false
    private let latencyQueue = DispatchQueue(label: "app.maosvpn.latency", qos: .userInitiated, attributes: .concurrent)

    override func loadView() {
        view = makeRootView()
        buildInterface()
    }

    private func makeRootView() -> NSView {
        return ThemedBackgroundView(
            frame: NSRect(x: 0, y: 0, width: 920, height: 620),
            color: .windowBackgroundColor
        )
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The URL remains persisted for refreshes but is never shown again.
        subscriptionField.stringValue = ""
        restoreProfiles()
        configureControllerCallbacks()
        updateState(vpnController.isConnected ? .connected : .disconnected)
    }

    private func buildInterface() {
        let header = makeHeader()
        let sidebar = makeSidebar()
        let content = makeContent()

        [header, sidebar, content].forEach { view.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 74),

            sidebar.topAnchor.constraint(equalTo: header.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 280),

            content.topAnchor.constraint(equalTo: header.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func makeHeader() -> NSView {
        let container = ThemedBackgroundView(color: .windowBackgroundColor)
        let divider = NSBox()
        divider.boxType = .separator

        let icon = NSTextField(labelWithString: "◆")
        icon.font = NSFont.systemFont(ofSize: 25, weight: .bold)
        icon.textColor = accent
        let title = NSTextField(labelWithString: "Maos VPN")
        title.font = NSFont.systemFont(ofSize: 21, weight: .semibold)
        let subtitle = NSTextField(labelWithString: L10n.text(.macOSVersion))
        subtitle.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        subtitle.textColor = .secondaryLabelColor

        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 5
        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)

        let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        languagePopup.addItems(withTitles: ["Русский", "English"])
        languagePopup.selectItem(at: AppLanguage.current == .russian ? 0 : 1)
        languagePopup.target = self
        languagePopup.action = #selector(changeLanguage(_:))
        languagePopup.controlSize = .small

        [icon, title, subtitle, statusDot, statusLabel, languagePopup, divider].forEach {
            container.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            icon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 17),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            statusDot.widthAnchor.constraint(equalToConstant: 10),
            statusDot.heightAnchor.constraint(equalToConstant: 10),
            statusDot.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            statusDot.trailingAnchor.constraint(equalTo: statusLabel.leadingAnchor, constant: -8),
            statusLabel.trailingAnchor.constraint(equalTo: languagePopup.leadingAnchor, constant: -18),
            statusLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            languagePopup.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            languagePopup.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            languagePopup.widthAnchor.constraint(equalToConstant: 92),
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

        let column: NSTableColumn
        if let existing = serverTable.tableColumns.first {
            column = existing
        } else {
            column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("server"))
            serverTable.addTableColumn(column)
        }
        column.title = L10n.text(.serverColumn)
        column.width = 250
        serverTable.headerView = nil
        serverTable.rowHeight = 56
        serverTable.backgroundColor = .clear
        serverTable.selectionHighlightStyle = .regular
        serverTable.dataSource = self
        serverTable.delegate = self

        pingButton.target = self
        pingButton.action = #selector(testPing)
        pingButton.title = L10n.text(.testPing)
        pingButton.bezelStyle = .rounded
        pingButton.controlSize = .small

        autoSelectButton.target = self
        autoSelectButton.action = #selector(autoSelectFastest)
        autoSelectButton.title = L10n.text(.autoSelect)
        autoSelectButton.bezelStyle = .rounded
        autoSelectButton.controlSize = .small

        let scroll = NSScrollView()
        scroll.documentView = serverTable
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        [heading, countLabel, pingButton, autoSelectButton, scroll].forEach { container.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
            heading.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
            countLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            countLabel.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            pingButton.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
            pingButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            pingButton.widthAnchor.constraint(equalToConstant: 78),
            autoSelectButton.leadingAnchor.constraint(equalTo: pingButton.trailingAnchor, constant: 8),
            autoSelectButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            autoSelectButton.centerYAnchor.constraint(equalTo: pingButton.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: pingButton.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])
        return container
    }

    private func makeContent() -> NSView {
        let container = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.distribution = .fill

        let title = NSTextField(labelWithString: L10n.text(.yourVPN))
        title.font = NSFont.systemFont(ofSize: 30, weight: .bold)
        let subtitle = NSTextField(labelWithString: L10n.text(.intro))
        subtitle.font = NSFont.systemFont(ofSize: 14)
        subtitle.textColor = .secondaryLabelColor
        stack.addArrangedSubview(title)
        stack.setCustomSpacing(4, after: title)
        stack.addArrangedSubview(subtitle)
        stack.addArrangedSubview(makeSubscriptionCard())
        stack.addArrangedSubview(makeConnectionCard())

        messageLabel.textColor = .secondaryLabelColor
        messageLabel.font = NSFont.systemFont(ofSize: 12)
        messageLabel.maximumNumberOfLines = 3
        stack.addArrangedSubview(messageLabel)

        container.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 30),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 42),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -42),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -20),
            messageLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return container
    }

    private func makeSubscriptionCard() -> NSView {
        let card = makeCard()
        let hasSavedURL = defaults.string(forKey: "subscriptionURL") != nil
        subscriptionLabel.stringValue = hasSavedURL ? L10n.text(.subscriptionSaved) : L10n.text(.subscriptionURL)
        subscriptionLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        subscriptionField.placeholderString = hasSavedURL ? L10n.text(.subscriptionPlaceholder) : "https://example.com/sub/..."
        subscriptionField.font = NSFont.systemFont(ofSize: 13)
        subscriptionField.delegate = self

        importButton.target = self
        importButton.action = #selector(importSubscription)
        importButton.title = hasSavedURL ? L10n.text(.refresh) : L10n.text(.load)
        importButton.bezelStyle = .rounded
        importButton.keyEquivalent = "\r"
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false

        [subscriptionLabel, subscriptionField, importButton, progress].forEach { card.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 108),
            subscriptionLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            subscriptionLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 17),
            subscriptionField.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            subscriptionField.trailingAnchor.constraint(equalTo: importButton.leadingAnchor, constant: -10),
            subscriptionField.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
            subscriptionField.heightAnchor.constraint(equalToConstant: 28),
            importButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            importButton.centerYAnchor.constraint(equalTo: subscriptionField.centerYAnchor),
            importButton.widthAnchor.constraint(equalToConstant: 92),
            progress.trailingAnchor.constraint(equalTo: importButton.leadingAnchor, constant: -8),
            progress.centerYAnchor.constraint(equalTo: importButton.centerYAnchor)
        ])
        return card
    }

    private func makeConnectionCard() -> NSView {
        let card = makeCard()
        selectedNameLabel.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        selectedDetailsLabel.font = NSFont.systemFont(ofSize: 12)
        selectedDetailsLabel.textColor = .secondaryLabelColor

        connectButton.target = self
        connectButton.action = #selector(toggleConnection)
        connectButton.bezelStyle = .rounded
        connectButton.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        connectButton.contentTintColor = .white
        connectButton.wantsLayer = true
        connectButton.layer?.backgroundColor = accent.cgColor
        connectButton.layer?.cornerRadius = 8
        connectButton.isBordered = false
        connectButton.isEnabled = false

        let hint = NSTextField(wrappingLabelWithString: L10n.text(.adminHint))
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        [selectedNameLabel, selectedDetailsLabel, connectButton, hint].forEach { card.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 208),
            selectedNameLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            selectedNameLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            selectedDetailsLabel.leadingAnchor.constraint(equalTo: selectedNameLabel.leadingAnchor),
            selectedDetailsLabel.topAnchor.constraint(equalTo: selectedNameLabel.bottomAnchor, constant: 5),
            connectButton.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            connectButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
            connectButton.topAnchor.constraint(equalTo: selectedDetailsLabel.bottomAnchor, constant: 22),
            connectButton.heightAnchor.constraint(equalToConstant: 58),
            hint.leadingAnchor.constraint(equalTo: connectButton.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: connectButton.trailingAnchor),
            hint.topAnchor.constraint(equalTo: connectButton.bottomAnchor, constant: 10)
        ])
        return card
    }

    private func makeCard() -> NSView {
        let card = ThemedCardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalToConstant: 510).isActive = true
        return card
    }

    @objc private func importSubscription() {
        let entered = subscriptionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = entered.isEmpty ? (defaults.string(forKey: "subscriptionURL") ?? "") : entered
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https", url.host != nil else {
            showError(MaosVPNError.invalidSubscriptionURL)
            return
        }
        setImporting(true)
        messageLabel.stringValue = L10n.text(.loadingSubscription)
        subscriptionService.load(from: url) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.setImporting(false)
                switch result {
                case .success(let profiles):
                    self.defaults.set(raw, forKey: "subscriptionURL")
                    self.subscriptionField.stringValue = ""
                    self.subscriptionField.placeholderString = L10n.text(.subscriptionPlaceholder)
                    self.subscriptionLabel.stringValue = L10n.text(.subscriptionSaved)
                    self.importButton.title = L10n.text(.refresh)
                    self.profiles = profiles
                    self.latencyByProfileID.removeAll()
                    self.persistProfiles()
                    self.serverTable.reloadData()
                    self.countLabel.stringValue = self.serverCountText(profiles.count)
                    if !profiles.isEmpty { self.serverTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
                    self.updateSelection()
                    self.messageLabel.textColor = .secondaryLabelColor
                    self.messageLabel.stringValue = "\(L10n.text(.subscriptionUpdated)) \(profiles.count)."
                case .failure(let error):
                    self.showError(error)
                }
            }
        }
    }

    @objc private func testPing() {
        startLatencyTest(selectFastest: false)
    }

    @objc private func autoSelectFastest() {
        startLatencyTest(selectFastest: true)
    }

    @objc private func toggleConnection() {
        messageLabel.textColor = .secondaryLabelColor
        if vpnController.isConnected {
            vpnController.disconnect { [weak self] error in
                if let error = error { self?.showError(error) }
            }
        } else {
            guard let profile = selectedProfile else { return }
            vpnController.connect(profile: profile) { [weak self] error in
                if let error = error { self?.showError(error) }
            }
        }
    }

    @objc private func changeLanguage(_ sender: NSPopUpButton) {
        let language: AppLanguage = sender.indexOfSelectedItem == 1 ? .english : .russian
        guard language != AppLanguage.current else { return }
        AppLanguage.current = language
        NotificationCenter.default.post(name: .maosVPNLanguageDidChange, object: nil)
        rebuildLocalizedInterface()
    }

    private func rebuildLocalizedInterface() {
        let selectedRow = serverTable.selectedRow
        view = makeRootView()
        buildInterface()
        subscriptionField.stringValue = ""
        serverTable.reloadData()
        countLabel.stringValue = serverCountText(profiles.count)
        if selectedRow >= 0 && selectedRow < profiles.count {
            serverTable.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
        } else if !profiles.isEmpty {
            serverTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateSelection()
        updateState(vpnController.state)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.stringValue = L10n.text(.languageChanged)
    }

    private func configureControllerCallbacks() {
        vpnController.onStateChange = { [weak self] state in self?.updateState(state) }
        vpnController.onLog = { [weak self] text in self?.messageLabel.stringValue = text }
    }

    private func updateState(_ state: VPNController.State) {
        let hasProfile = selectedProfile != nil
        switch state {
        case .disconnected:
            statusLabel.stringValue = L10n.text(.disconnected)
            statusDot.layer?.backgroundColor = NSColor.systemGray.cgColor
            connectButton.title = L10n.text(.connect)
            connectButton.layer?.backgroundColor = accent.cgColor
            connectButton.isEnabled = hasProfile && !subscriptionRequestInProgress && !latencyTestInProgress
            serverTable.isEnabled = !subscriptionRequestInProgress
            importButton.isEnabled = !subscriptionRequestInProgress
            subscriptionField.isEnabled = !subscriptionRequestInProgress
            updateLatencyButtons()
        case .connecting:
            statusLabel.stringValue = L10n.text(.connecting)
            statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            connectButton.title = L10n.text(.connecting)
            connectButton.isEnabled = false
            serverTable.isEnabled = false
            importButton.isEnabled = false
            subscriptionField.isEnabled = false
            pingButton.isEnabled = false
            autoSelectButton.isEnabled = false
        case .connected:
            statusLabel.stringValue = L10n.text(.connected)
            statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            connectButton.title = L10n.text(.disconnect)
            connectButton.layer?.backgroundColor = NSColor.systemRed.cgColor
            connectButton.isEnabled = true
            serverTable.isEnabled = false
            importButton.isEnabled = false
            subscriptionField.isEnabled = false
            pingButton.isEnabled = false
            autoSelectButton.isEnabled = false
        case .disconnecting:
            statusLabel.stringValue = L10n.text(.disconnecting)
            statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            connectButton.title = L10n.text(.disconnecting)
            connectButton.isEnabled = false
            importButton.isEnabled = false
            subscriptionField.isEnabled = false
            pingButton.isEnabled = false
            autoSelectButton.isEnabled = false
        }
    }

    private func updateSelection() {
        guard let profile = selectedProfile else {
            selectedNameLabel.stringValue = L10n.text(.addSubscription)
            selectedDetailsLabel.stringValue = L10n.text(.serversWillAppear)
            connectButton.isEnabled = false
            return
        }
        selectedNameLabel.stringValue = profile.name
        var details = "\(profile.kind.title)  •  \(profile.server):\(profile.port)"
        if let latency = latencyByProfileID[profile.id] {
            details += "  •  \(latencyText(latency))"
        }
        selectedDetailsLabel.stringValue = details
        connectButton.isEnabled = (vpnController.state == .disconnected || vpnController.state == .connected) && !latencyTestInProgress
    }

    func numberOfRows(in tableView: NSTableView) -> Int { profiles.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let profile = profiles[row]
        let identifier = NSUserInterfaceItemIdentifier("ServerCell")
        let cell: NSTableCellView
        if let reusable = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reusable
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let title = NSTextField(labelWithString: "")
            title.tag = 1
            title.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            let detail = NSTextField(labelWithString: "")
            detail.tag = 2
            detail.font = NSFont.systemFont(ofSize: 10)
            detail.textColor = .secondaryLabelColor
            let latency = NSTextField(labelWithString: "")
            latency.tag = 3
            latency.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            latency.textColor = .secondaryLabelColor
            latency.alignment = .right
            [title, detail, latency].forEach { cell.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
            NSLayoutConstraint.activate([
                title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                title.trailingAnchor.constraint(equalTo: latency.leadingAnchor, constant: -8),
                title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 10),
                detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                detail.trailingAnchor.constraint(lessThanOrEqualTo: latency.leadingAnchor, constant: -8),
                detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
                latency.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                latency.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                latency.widthAnchor.constraint(equalToConstant: 64)
            ])
        }
        (cell.viewWithTag(1) as? NSTextField)?.stringValue = profile.name
        (cell.viewWithTag(2) as? NSTextField)?.stringValue = "\(profile.kind.title)  •  \(profile.server):\(profile.port)"
        let latencyLabel = cell.viewWithTag(3) as? NSTextField
        if let latency = latencyByProfileID[profile.id] {
            latencyLabel?.stringValue = latencyText(latency)
            latencyLabel?.textColor = latencyColor(latency)
        } else {
            latencyLabel?.stringValue = "—"
            latencyLabel?.textColor = .tertiaryLabelColor
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }

    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: "profiles") }
    }

    private func restoreProfiles() {
        guard let data = defaults.data(forKey: "profiles"),
              let saved = try? JSONDecoder().decode([VPNProfile].self, from: data) else { return }
        // Remove the fake update profile returned by some HWID-enabled panels
        // to older clients so it cannot remain selected after an app upgrade.
        profiles = saved.filter { profile in
            !(profile.port == 1 && (profile.server == "0.0.0.0" || profile.server == "::"))
        }
        if profiles.count != saved.count { persistProfiles() }
        serverTable.reloadData()
        countLabel.stringValue = serverCountText(profiles.count)
        if !profiles.isEmpty { serverTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        updateSelection()
    }

    private func setImporting(_ importing: Bool) {
        subscriptionRequestInProgress = importing
        if importing {
            importButton.isEnabled = false
            subscriptionField.isEnabled = false
            connectButton.isEnabled = false
            serverTable.isEnabled = false
            pingButton.isEnabled = false
            autoSelectButton.isEnabled = false
            progress.startAnimation(nil)
        } else {
            progress.stopAnimation(nil)
            updateState(vpnController.state)
        }
    }

    private func startLatencyTest(selectFastest: Bool) {
        guard !profiles.isEmpty,
              !latencyTestInProgress,
              vpnController.state == .disconnected else { return }

        latencyTestInProgress = true
        selectFastestWhenFinished = selectFastest
        latencyTestID = UUID()
        let testID = latencyTestID
        let snapshot = profiles
        snapshot.forEach { latencyByProfileID[$0.id] = .testing }
        serverTable.reloadData()
        updateSelection()
        updateLatencyButtons()
        connectButton.isEnabled = false
        importButton.isEnabled = false
        subscriptionField.isEnabled = false
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.stringValue = L10n.text(.testingPing)

        let group = DispatchGroup()
        for profile in snapshot {
            group.enter()
            latencyQueue.async { [weak self] in
                let milliseconds = self?.measureLatency(to: profile.server)
                DispatchQueue.main.async {
                    defer { group.leave() }
                    guard let self = self, self.latencyTestID == testID else { return }
                    self.latencyByProfileID[profile.id] = milliseconds.map(LatencyState.reachable) ?? .unavailable
                    if let row = self.profiles.firstIndex(where: { $0.id == profile.id }) {
                        self.serverTable.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
                        if row == self.serverTable.selectedRow { self.updateSelection() }
                    }
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self, self.latencyTestID == testID else { return }
            self.latencyTestInProgress = false
            self.updateState(self.vpnController.state)
            if self.selectFastestWhenFinished {
                self.selectFastestProfile()
            } else {
                self.messageLabel.stringValue = L10n.text(.pingFinished)
            }
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
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        return max(1, Int((Double(elapsed) / 1_000_000).rounded()))
    }

    private func selectFastestProfile() {
        let fastest = profiles.enumerated().compactMap { index, profile -> (Int, Int)? in
            guard case .reachable(let milliseconds)? = latencyByProfileID[profile.id] else { return nil }
            return (index, milliseconds)
        }.min { $0.1 < $1.1 }

        guard let result = fastest else {
            messageLabel.textColor = .systemOrange
            messageLabel.stringValue = L10n.text(.pingUnavailable)
            return
        }
        serverTable.selectRowIndexes(IndexSet(integer: result.0), byExtendingSelection: false)
        serverTable.scrollRowToVisible(result.0)
        updateSelection()
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.stringValue = "\(L10n.text(.fastestSelected)) \(profiles[result.0].name) — \(result.1) ms."
    }

    private func updateLatencyButtons() {
        let enabled = !profiles.isEmpty && !latencyTestInProgress && !subscriptionRequestInProgress && vpnController.state == .disconnected
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

    private func showError(_ error: Error) {
        messageLabel.textColor = .systemRed
        messageLabel.stringValue = error.localizedDescription
        NSSound.beep()
    }

    private func serverCountText(_ count: Int) -> String {
        if AppLanguage.current == .english {
            return "\(count) \(count == 1 ? "server" : "servers")"
        }
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
        self.fillColor = color
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { return nil }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        if #available(macOS 11.0, *) {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = fillColor.cgColor
            }
        } else {
            let previousAppearance = NSAppearance.current
            NSAppearance.current = effectiveAppearance
            layer?.backgroundColor = fillColor.cgColor
            NSAppearance.current = previousAppearance
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private final class ThemedCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
