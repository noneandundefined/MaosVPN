import Foundation

/// Import report stores *only* protocol names and short server titles, never
/// credentials, raw subscription URLs, or the original configuration body.
public struct SkippedSubscriptionServer: Codable, Equatable {
    public let title: String
    public let type: String
    public let reason: String

    public init(title: String, type: String, reason: String) {
        self.title = String(title.prefix(80))
        self.type = String(type.prefix(32))
        self.reason = String(reason.prefix(200))
    }
}

public struct SubscriptionImportDiagnostics: Codable, Equatable {
    public let received: Int
    public let imported: Int
    public let skipped: [SkippedSubscriptionServer]
    public let userAgent: String

    public init(received: Int, imported: Int,
                skipped: [SkippedSubscriptionServer], userAgent: String) {
        self.received = received
        self.imported = imported
        self.skipped = skipped
        self.userAgent = userAgent
    }

    public var skippedCount: Int { max(0, received - imported) }

    public var summary: String {
        AppLanguage.text(
            russian: "Получено \(received), импортировано \(imported), пропущено \(skippedCount) (\(userAgent)).",
            english: "Received \(received), imported \(imported), skipped \(skippedCount) (\(userAgent))."
        )
    }
}
