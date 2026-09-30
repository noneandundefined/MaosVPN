import AppKit
import MaosVPNCore

final class MainViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
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
    private let importButton = NSButton(title: L10n.text(.load), target: nil, action: nil)
    private let connectButton = NSButton(title: L10n.text(.connect), target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: L10n.text(.disconnected))
    private let statusDot = NSView()
    private let selectedNameLabel = NSTextField(labelWithString: L10n.text(.addSubscription))
    private let selectedDetailsLabel = NSTextField(labelWithString: L10n.text(.serversWillAppear))
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let countLabel = NSTextField(labelWithString: "0 \(L10n.text(.serverMany))")
    private let progress = NSProgressIndicator()
    private var subscriptionRequestInProgress = false

    override func loadView() {
        view = makeRootView()
        buildInterface()
    }

    private func makeRootView() -> NSView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 920, height: 620))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.965, alpha: 1).cgColor
        return root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        subscriptionField.stringValue = defaults.string(forKey: "subscriptionURL") ?? ""
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
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.white.cgColor
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
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.94, alpha: 1).cgColor

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

        let scroll = NSScrollView()
        scroll.documentView = serverTable
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        [heading, countLabel, scroll].forEach { container.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
            heading.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
            countLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            countLabel.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
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
        stack.spacing = 22
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
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 40),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 42),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -42),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -28),
            messageLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return container
    }

    private func makeSubscriptionCard() -> NSView {
        let card = makeCard()
        let label = NSTextField(labelWithString: L10n.text(.subscriptionURL))
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        subscriptionField.placeholderString = "https://example.com/sub/..."
        subscriptionField.font = NSFont.systemFont(ofSize: 13)
        subscriptionField.delegate = self

        importButton.target = self
        importButton.action = #selector(importSubscription)
        importButton.title = L10n.text(.load)
        importButton.bezelStyle = .rounded
        importButton.keyEquivalent = "\r"
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false

        [label, subscriptionField, importButton, progress].forEach { card.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 108),
            label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            label.topAnchor.constraint(equalTo: card.topAnchor, constant: 17),
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
            card.heightAnchor.constraint(equalToConstant: 190),
            selectedNameLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            selectedNameLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            selectedDetailsLabel.leadingAnchor.constraint(equalTo: selectedNameLabel.leadingAnchor),
            selectedDetailsLabel.topAnchor.constraint(equalTo: selectedNameLabel.bottomAnchor, constant: 5),
            connectButton.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            connectButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
            connectButton.topAnchor.constraint(equalTo: selectedDetailsLabel.bottomAnchor, constant: 22),
            connectButton.heightAnchor.constraint(equalToConstant: 42),
            hint.leadingAnchor.constraint(equalTo: connectButton.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: connectButton.trailingAnchor),
            hint.topAnchor.constraint(equalTo: connectButton.bottomAnchor, constant: 10)
        ])
        return card
    }

    private func makeCard() -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.cgColor
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor(calibratedWhite: 0.86, alpha: 1).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalToConstant: 510).isActive = true
        return card
    }

    @objc private func importSubscription() {
        let raw = subscriptionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https", url.host != nil else {
            showError(MaosVPNError.invalidSubscriptionURL)
            return
        }
        defaults.set(raw, forKey: "subscriptionURL")
        setImporting(true)
        messageLabel.stringValue = L10n.text(.loadingSubscription)
        subscriptionService.load(from: url) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.setImporting(false)
                switch result {
                case .success(let profiles):
                    self.profiles = profiles
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
        subscriptionField.stringValue = defaults.string(forKey: "subscriptionURL") ?? ""
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
            connectButton.isEnabled = hasProfile && !subscriptionRequestInProgress
            serverTable.isEnabled = !subscriptionRequestInProgress
            importButton.isEnabled = !subscriptionRequestInProgress
            subscriptionField.isEnabled = !subscriptionRequestInProgress
        case .connecting:
            statusLabel.stringValue = L10n.text(.connecting)
            statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            connectButton.title = L10n.text(.connecting)
            connectButton.isEnabled = false
            serverTable.isEnabled = false
            importButton.isEnabled = false
            subscriptionField.isEnabled = false
        case .connected:
            statusLabel.stringValue = L10n.text(.connected)
            statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            connectButton.title = L10n.text(.disconnect)
            connectButton.layer?.backgroundColor = NSColor.systemRed.cgColor
            connectButton.isEnabled = true
            serverTable.isEnabled = false
            importButton.isEnabled = false
            subscriptionField.isEnabled = false
        case .disconnecting:
            statusLabel.stringValue = L10n.text(.disconnecting)
            statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            connectButton.title = L10n.text(.disconnecting)
            connectButton.isEnabled = false
            importButton.isEnabled = false
            subscriptionField.isEnabled = false
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
        selectedDetailsLabel.stringValue = "\(profile.kind.title)  •  \(profile.server):\(profile.port)"
        connectButton.isEnabled = vpnController.state == .disconnected || vpnController.state == .connected
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
            [title, detail].forEach { cell.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
            NSLayoutConstraint.activate([
                title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 10),
                detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3)
            ])
        }
        (cell.viewWithTag(1) as? NSTextField)?.stringValue = profile.name
        (cell.viewWithTag(2) as? NSTextField)?.stringValue = "\(profile.kind.title)  •  \(profile.server):\(profile.port)"
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
            progress.startAnimation(nil)
        } else {
            progress.stopAnimation(nil)
            updateState(vpnController.state)
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
