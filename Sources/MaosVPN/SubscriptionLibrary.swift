import AppKit
import MaosVPNCore

enum SubscriptionSourceKind: String, Codable {
    case remote
    case json
}

final class SubscriptionEntry: NSObject, Codable {
    let id: UUID
    var name: String
    let sourceKind: SubscriptionSourceKind
    let source: String
    var profiles: [VPNProfile]
    private(set) var profileNodes: [ProfileNode] = []

    init(
        id: UUID = UUID(),
        name: String,
        sourceKind: SubscriptionSourceKind,
        source: String,
        profiles: [VPNProfile]
    ) {
        self.id = id
        self.name = name
        self.sourceKind = sourceKind
        self.source = source
        self.profiles = profiles
        super.init()
        rebuildNodes()
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, sourceKind, source, profiles
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        sourceKind = try container.decode(SubscriptionSourceKind.self, forKey: .sourceKind)
        source = try container.decode(String.self, forKey: .source)
        profiles = try container.decode([VPNProfile].self, forKey: .profiles)
        super.init()
        rebuildNodes()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(sourceKind, forKey: .sourceKind)
        try container.encode(source, forKey: .source)
        try container.encode(profiles, forKey: .profiles)
    }

    func replaceProfiles(_ profiles: [VPNProfile]) {
        self.profiles = profiles
        rebuildNodes()
    }

    private func rebuildNodes() {
        profileNodes = profiles.map { ProfileNode(subscriptionID: id, profile: $0) }
    }
}

final class ProfileNode: NSObject {
    let subscriptionID: UUID
    let profile: VPNProfile

    init(subscriptionID: UUID, profile: VPNProfile) {
        self.subscriptionID = subscriptionID
        self.profile = profile
    }
}

final class AddSubscriptionAccessoryView: NSView {
    let typePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let nameField = NSTextField()
    let urlField = NSTextField()
    let jsonTextView = NSTextView()
    private let inputLabel = NSTextField(labelWithString: "")
    private let jsonScroll = NSScrollView()

    var sourceKind: SubscriptionSourceKind {
        typePopup.indexOfSelectedItem == 1 ? .json : .remote
    }

    var source: String {
        switch sourceKind {
        case .remote:
            return urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        case .json:
            return jsonTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 235))

        let typeLabel = NSTextField(labelWithString: AppLanguage.text(russian: "Тип", english: "Type"))
        let nameLabel = NSTextField(labelWithString: AppLanguage.text(russian: "Имя подписки", english: "Subscription name"))
        inputLabel.stringValue = AppLanguage.text(russian: "URL подписки", english: "Subscription URL")

        typePopup.addItems(withTitles: [
            AppLanguage.text(russian: "Подписка", english: "Subscription"),
            "JSON"
        ])
        typePopup.target = self
        typePopup.action = #selector(typeDidChange)

        nameField.placeholderString = AppLanguage.text(russian: "Например, Основная", english: "For example, Main")
        urlField.placeholderString = "https://example.com/sub/..."

        jsonScroll.documentView = jsonTextView
        jsonScroll.hasVerticalScroller = true
        jsonScroll.borderType = .bezelBorder
        jsonTextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        jsonTextView.isRichText = false
        jsonTextView.isAutomaticQuoteSubstitutionEnabled = false
        jsonTextView.isAutomaticDashSubstitutionEnabled = false
        jsonScroll.isHidden = true

        [typeLabel, typePopup, nameLabel, nameField, inputLabel, urlField, jsonScroll].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            typeLabel.topAnchor.constraint(equalTo: topAnchor),
            typeLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            typePopup.topAnchor.constraint(equalTo: typeLabel.bottomAnchor, constant: 5),
            typePopup.leadingAnchor.constraint(equalTo: leadingAnchor),
            typePopup.trailingAnchor.constraint(equalTo: trailingAnchor),
            typePopup.heightAnchor.constraint(equalToConstant: 28),

            nameLabel.topAnchor.constraint(equalTo: typePopup.bottomAnchor, constant: 12),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameField.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 5),
            nameField.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameField.trailingAnchor.constraint(equalTo: trailingAnchor),
            nameField.heightAnchor.constraint(equalToConstant: 28),

            inputLabel.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 12),
            inputLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            urlField.topAnchor.constraint(equalTo: inputLabel.bottomAnchor, constant: 5),
            urlField.leadingAnchor.constraint(equalTo: leadingAnchor),
            urlField.trailingAnchor.constraint(equalTo: trailingAnchor),
            urlField.heightAnchor.constraint(equalToConstant: 28),
            jsonScroll.topAnchor.constraint(equalTo: inputLabel.bottomAnchor, constant: 5),
            jsonScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            jsonScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            jsonScroll.heightAnchor.constraint(equalToConstant: 72)
        ])
    }

    required init?(coder: NSCoder) { return nil }

    @objc private func typeDidChange() {
        let isJSON = sourceKind == .json
        urlField.isHidden = isJSON
        jsonScroll.isHidden = !isJSON
        inputLabel.stringValue = isJSON
            ? AppLanguage.text(russian: "Конфигурация JSON", english: "JSON configuration")
            : AppLanguage.text(russian: "URL подписки", english: "Subscription URL")
        window?.makeFirstResponder(isJSON ? jsonTextView : urlField)
    }
}
