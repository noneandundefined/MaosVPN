import AppKit
import MaosVPNCore

/// Details are shown in a sheet. Subscription tokens remain hidden until the
/// user explicitly reveals them, but the original URL is still copyable.
final class SubscriptionDetailsView: NSView {
    private let subscription: SubscriptionEntry
    private let sourceLabel = NSTextField(labelWithString: "")
    private let revealButton = NSButton()
    private var isSourceVisible = false

    init(subscription: SubscriptionEntry) {
        self.subscription = subscription
        super.init(frame: NSRect(x: 0, y: 0, width: 466, height: 310))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.distribution = .fill

        let info = subscription.metadata
        if let providedTitle = info?.title, providedTitle != subscription.name {
            stack.addArrangedSubview(textRow(
                AppLanguage.text(russian: "Название провайдера", english: "Provider title"), providedTitle))
        }

        let expiry: String
        if let date = info?.expiresAt {
            let formatted = DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
            expiry = date <= Date()
                ? AppLanguage.text(russian: "Истекла: ", english: "Expired: ") + formatted
                : formatted
        } else {
            expiry = AppLanguage.text(russian: "Не указан", english: "Not provided")
        }
        stack.addArrangedSubview(textRow(
            AppLanguage.text(russian: "Действует до", english: "Expires"), expiry))

        let traffic: String
        if let used = info?.usedBytes {
            let usedText = ByteCountFormatter.string(fromByteCount: used, countStyle: .binary)
            if let total = info?.totalBytes, total > 0 {
                traffic = usedText + " / " + ByteCountFormatter.string(fromByteCount: total, countStyle: .binary)
            } else if info?.totalBytes == 0 {
                traffic = usedText + AppLanguage.text(russian: " / безлимит", english: " / unlimited")
            } else {
                traffic = usedText
            }
        } else {
            traffic = AppLanguage.text(russian: "Нет данных", english: "Not provided")
        }
        stack.addArrangedSubview(textRow(
            AppLanguage.text(russian: "Трафик", english: "Traffic used"), traffic))

        let websiteButton = makeLinkButton(
            title: info?.websiteURL?.host ?? AppLanguage.text(russian: "Не указан", english: "Not provided"),
            action: #selector(openWebsite), enabled: info?.websiteURL != nil
        )
        stack.addArrangedSubview(controlRow(
            AppLanguage.text(russian: "Сайт", english: "Website"), websiteButton))

        let supportButton = makeLinkButton(
            title: info?.supportURL?.host ?? AppLanguage.text(russian: "Не указана", english: "Not provided"),
            action: #selector(openSupport), enabled: info?.supportURL != nil
        )
        stack.addArrangedSubview(controlRow(
            AppLanguage.text(russian: "Поддержка", english: "Support"), supportButton))

        if let client = subscription.selectedUserAgent {
            stack.addArrangedSubview(textRow(
                AppLanguage.text(russian: "Формат подписки", english: "Subscription format"), client
            ))
            if !subscription.comparedUserAgents.isEmpty {
                let summary = subscription.comparedUserAgents.map { item in
                    let name = item.userAgent.components(separatedBy: "/").first ?? item.userAgent
                    return "\(name): \(item.compatibleCount)"
                }.joined(separator: " · ")
                let row = textRow(
                    AppLanguage.text(russian: "Сравнение", english: "Compared"), summary
                )
                row.toolTip = summary
                stack.addArrangedSubview(row)
            }
        }

        let sourceTitle = NSTextField(labelWithString: AppLanguage.text(
            russian: "Ссылка подписки", english: "Subscription URL"
        ))
        sourceTitle.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        sourceTitle.textColor = .secondaryLabelColor
        stack.addArrangedSubview(sourceTitle)

        sourceLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        sourceLabel.lineBreakMode = .byTruncatingMiddle
        sourceLabel.maximumNumberOfLines = 1
        sourceLabel.isSelectable = true
        updateSourceLabel()
        stack.addArrangedSubview(sourceLabel)
        sourceLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 435).isActive = true

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 8
        revealButton.title = AppLanguage.text(russian: "Показать", english: "Reveal")
        revealButton.bezelStyle = .rounded
        revealButton.controlSize = .small
        revealButton.target = self
        revealButton.action = #selector(toggleSource)

        let copy = NSButton(title: AppLanguage.text(russian: "Скопировать ссылку", english: "Copy URL"),
                            target: self, action: #selector(copySource))
        copy.bezelStyle = .rounded
        copy.controlSize = .small

        let isRemote = subscription.sourceKind == .remote
        revealButton.isEnabled = isRemote
        copy.isEnabled = isRemote
        actions.addArrangedSubview(revealButton)
        actions.addArrangedSubview(copy)
        stack.addArrangedSubview(actions)

        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -5)
        ])
    }

    required init?(coder: NSCoder) { return nil }

    private func textRow(_ title: String, _ value: String) -> NSView {
        let field = NSTextField(labelWithString: value)
        field.font = NSFont.systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingTail
        return controlRow(title, field)
    }

    private func controlRow(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 122).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    private func makeLinkButton(title: String, action: Selector, enabled: Bool) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.font = NSFont.systemFont(ofSize: 12)
        button.contentTintColor = enabled ? .linkColor : .secondaryLabelColor
        button.isEnabled = enabled
        return button
    }

    private func updateSourceLabel() {
        guard subscription.sourceKind == .remote else {
            sourceLabel.stringValue = AppLanguage.text(russian: "Локальный JSON без URL", english: "Local JSON without URL")
            return
        }
        if isSourceVisible {
            sourceLabel.stringValue = subscription.source
        } else {
            let host = URL(string: subscription.source)?.host ?? "https"
            sourceLabel.stringValue = "https://" + host + "/••••••••"
        }
    }

    @objc private func toggleSource() {
        isSourceVisible.toggle()
        revealButton.title = isSourceVisible
            ? AppLanguage.text(russian: "Скрыть", english: "Hide")
            : AppLanguage.text(russian: "Показать", english: "Reveal")
        updateSourceLabel()
    }

    @objc private func copySource() {
        guard subscription.sourceKind == .remote else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(subscription.source, forType: .string)
    }

    @objc private func openWebsite() {
        guard let url = subscription.metadata?.websiteURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openSupport() {
        guard let url = subscription.metadata?.supportURL else { return }
        NSWorkspace.shared.open(url)
    }
}
