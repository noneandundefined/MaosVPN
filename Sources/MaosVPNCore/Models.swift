import Foundation

public enum AppLanguage: String, Codable, Equatable {
    case russian = "ru"
    case english = "en"

    public static let defaultsKey = "appLanguage"

    public static var current: AppLanguage {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let language = AppLanguage(rawValue: raw) else {
                let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
                return preferred.hasPrefix("ru") ? .russian : .english
            }
            return language
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    public static func text(russian: String, english: String) -> String {
        return current == .russian ? russian : english
    }
}

public enum VPNProtocolKind: String, Codable, Equatable {
    case vless
    case vmess
    case trojan
    case shadowsocks

    public var title: String {
        switch self {
        case .vless: return "VLESS"
        case .vmess: return "VMess"
        case .trojan: return "Trojan"
        case .shadowsocks: return "Shadowsocks"
        }
    }
}

public struct VPNProfile: Codable, Equatable {
    public let id: UUID
    public let name: String
    public let kind: VPNProtocolKind
    public let server: String
    public let port: Int
    public let credential: String
    public let parameters: [String: String]

    public init(
        id: UUID = UUID(),
        name: String,
        kind: VPNProtocolKind,
        server: String,
        port: Int,
        credential: String,
        parameters: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.server = server
        self.port = port
        self.credential = credential
        self.parameters = parameters
    }
}

public enum MaosVPNError: LocalizedError {
    case invalidSubscriptionURL
    case emptySubscription
    case unsupportedSubscription
    case subscriptionAccessRejected
    case malformedProfile(String)
    case missingCore
    case invalidConfiguration(String)
    case privilegeHelper(String)
    case processDidNotStart(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSubscriptionURL:
            return AppLanguage.text(
                russian: "Введите корректную ссылку подписки HTTPS.",
                english: "Enter a valid HTTPS subscription URL."
            )
        case .emptySubscription:
            return AppLanguage.text(
                russian: "Подписка не содержит серверов.",
                english: "The subscription does not contain any servers."
            )
        case .unsupportedSubscription:
            return AppLanguage.text(
                russian: "В подписке нет поддерживаемых серверов (VLESS, VMess, Trojan или Shadowsocks).",
                english: "The subscription contains no supported servers (VLESS, VMess, Trojan, or Shadowsocks)."
            )
        case .subscriptionAccessRejected:
            return AppLanguage.text(
                russian: "Сервер подписки отклонил это устройство. Проверьте лимит устройств у провайдера и загрузите подписку снова.",
                english: "The subscription server rejected this device. Check your provider's device limit and load the subscription again."
            )
        case .malformedProfile(let reason):
            return AppLanguage.text(
                russian: "Некорректный профиль: \(reason)",
                english: "Invalid profile: \(reason)"
            )
        case .missingCore:
            return AppLanguage.text(
                russian: "В приложении отсутствует VPN-движок sing-box. Скачайте полную сборку из GitHub Releases.",
                english: "The sing-box VPN engine is missing. Download the complete build from GitHub Releases."
            )
        case .invalidConfiguration(let details):
            return AppLanguage.text(
                russian: "VPN-движок отклонил конфигурацию.\n\(details)",
                english: "The VPN engine rejected the configuration.\n\(details)"
            )
        case .privilegeHelper(let details):
            return AppLanguage.text(
                russian: "macOS не дала права для управления VPN.\n\(details)",
                english: "macOS did not grant permission to manage the VPN.\n\(details)"
            )
        case .processDidNotStart(let details):
            return AppLanguage.text(
                russian: "VPN не запустился.\n\(details)",
                english: "The VPN failed to start.\n\(details)"
            )
        }
    }
}
