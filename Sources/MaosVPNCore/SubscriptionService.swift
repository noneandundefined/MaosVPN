import Foundation

public final class SubscriptionService {
    static let hardwareIDDefaultsKey = "subscriptionHardwareID"

    private let session: URLSession
    private let hardwareID: String

    public init(
        session: URLSession = .shared,
        hardwareID: String? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.session = session
        self.hardwareID = hardwareID ?? Self.persistentHardwareID(in: defaults)
    }

    public func load(from url: URL, completion: @escaping (Result<[VPNProfile], Error>) -> Void) {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        var request = Self.makeRequest(
            for: url,
            hardwareID: hardwareID,
            osVersion: "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        )
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                completion(.failure(MaosVPNError.malformedProfile(AppLanguage.text(
                    russian: "сервер подписки вернул HTTP \(http.statusCode)",
                    english: "the subscription server returned HTTP \(http.statusCode)"
                ))))
                return
            }
            if let http = response as? HTTPURLResponse,
               http.value(forHTTPHeaderField: "x-hwid-not-supported")?.lowercased() == "true" {
                completion(.failure(MaosVPNError.subscriptionAccessRejected))
                return
            }
            guard let data = data, !data.isEmpty else {
                completion(.failure(MaosVPNError.emptySubscription))
                return
            }
            guard data.count <= 10 * 1024 * 1024 else {
                completion(.failure(MaosVPNError.malformedProfile(AppLanguage.text(
                    russian: "ответ подписки превышает 10 МБ",
                    english: "the subscription response exceeds 10 MB"
                ))))
                return
            }
            do {
                completion(.success(try ShareLinkParser.parseSubscription(data)))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    static func persistentHardwareID(in defaults: UserDefaults) -> String {
        if let existing = defaults.string(forKey: hardwareIDDefaultsKey),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return existing
        }

        let identifier = UUID().uuidString.lowercased()
        defaults.set(identifier, forKey: hardwareIDDefaultsKey)
        return identifier
    }

    static func makeRequest(
        for url: URL,
        hardwareID: String,
        osVersion: String,
        deviceModel: String = "Mac"
    ) -> URLRequest {
        var request = URLRequest(url: url)

        // Happ-compatible panels use these headers to choose the subscription
        // format and, when enabled, account for a device without returning a
        // fake 0.0.0.0:1 update profile.
        request.setValue("Happ/4.3.0", forHTTPHeaderField: "User-Agent")
        request.setValue(hardwareID, forHTTPHeaderField: "X-Hwid")
        request.setValue("macOS", forHTTPHeaderField: "X-Device-Os")
        request.setValue(osVersion, forHTTPHeaderField: "X-Ver-Os")
        request.setValue(deviceModel, forHTTPHeaderField: "X-Device-Model")

        return request
    }
}

enum ShareLinkParser {
    static func parseSubscription(_ data: Data) throws -> [VPNProfile] {
        guard var text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw MaosVPNError.emptySubscription
        }

        if !text.contains("://"), let decoded = decodeBase64(text), let decodedText = String(data: decoded, encoding: .utf8) {
            text = decodedText
        }

        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        var profiles: [VPNProfile] = []
        for line in lines {
            if let profile = try? parse(line) {
                profiles.append(profile)
            }
        }

        guard !profiles.isEmpty else {
            throw MaosVPNError.unsupportedSubscription
        }
        guard !profiles.allSatisfy({ isProviderPlaceholder($0) }) else {
            throw MaosVPNError.subscriptionAccessRejected
        }
        return profiles
    }

    private static func isProviderPlaceholder(_ profile: VPNProfile) -> Bool {
        let normalizedName = profile.name.lowercased()
        let updateMessage = normalizedName.contains("обновите приложение")
            || normalizedName.contains("update app")
            || normalizedName.contains("update the app")
        let unroutableAddress = profile.server == "0.0.0.0" || profile.server == "::"
        return updateMessage || (unroutableAddress && profile.port == 1)
    }

    static func parse(_ link: String) throws -> VPNProfile {
        if link.lowercased().hasPrefix("vmess://") {
            return try parseVMess(link)
        }
        guard let components = URLComponents(string: link),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              let port = components.port, (1...65535).contains(port) else {
            throw MaosVPNError.malformedProfile(AppLanguage.text(
                russian: "не удалось прочитать адрес или порт",
                english: "could not read the server address or port"
            ))
        }

        let query = dictionary(from: components.queryItems ?? [])
        let rawName = components.fragment?.removingPercentEncoding
        let name = (rawName?.isEmpty == false ? rawName! : "\(host):\(port)")

        switch scheme {
        case "vless":
            guard let uuid = components.user?.removingPercentEncoding, !uuid.isEmpty else {
                throw MaosVPNError.malformedProfile(AppLanguage.text(
                    russian: "в VLESS отсутствует UUID",
                    english: "VLESS UUID is missing"
                ))
            }
            return VPNProfile(name: name, kind: .vless, server: host, port: port, credential: uuid, parameters: query)
        case "trojan":
            guard let password = components.user?.removingPercentEncoding, !password.isEmpty else {
                throw MaosVPNError.malformedProfile(AppLanguage.text(
                    russian: "в Trojan отсутствует пароль",
                    english: "Trojan password is missing"
                ))
            }
            return VPNProfile(name: name, kind: .trojan, server: host, port: port, credential: password, parameters: query)
        case "ss":
            return try parseShadowsocks(components: components, host: host, port: port, name: name, query: query)
        default:
            throw MaosVPNError.malformedProfile(AppLanguage.text(
                russian: "протокол \(scheme) пока не поддерживается",
                english: "the \(scheme) protocol is not supported yet"
            ))
        }
    }

    private static func parseVMess(_ link: String) throws -> VPNProfile {
        let encoded = String(link.dropFirst("vmess://".count))
        guard let data = decodeBase64(encoded),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let server = object["add"] as? String,
              let credential = object["id"] as? String else {
            throw MaosVPNError.malformedProfile(AppLanguage.text(
                russian: "VMess JSON повреждён",
                english: "VMess JSON is malformed"
            ))
        }
        let port: Int
        if let value = object["port"] as? Int {
            port = value
        } else if let value = object["port"] as? String, let parsed = Int(value) {
            port = parsed
        } else {
            throw MaosVPNError.malformedProfile(AppLanguage.text(
                russian: "в VMess отсутствует порт",
                english: "VMess port is missing"
            ))
        }

        var parameters: [String: String] = [:]
        for key in ["net", "type", "host", "path", "tls", "sni", "alpn", "scy", "aid", "fp"] {
            if let string = object[key] as? String { parameters[key] = string }
            if let number = object[key] as? NSNumber { parameters[key] = number.stringValue }
        }
        let name = (object["ps"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "\(server):\(port)"
        return VPNProfile(name: name, kind: .vmess, server: server, port: port, credential: credential, parameters: parameters)
    }

    private static func parseShadowsocks(
        components: URLComponents,
        host: String,
        port: Int,
        name: String,
        query: [String: String]
    ) throws -> VPNProfile {
        guard let rawUser = components.user?.removingPercentEncoding else {
            throw MaosVPNError.malformedProfile(AppLanguage.text(
                russian: "в Shadowsocks отсутствуют учётные данные",
                english: "Shadowsocks credentials are missing"
            ))
        }

        let credentials: String
        if rawUser.contains(":") {
            credentials = rawUser
        } else if let decoded = decodeBase64(rawUser), let value = String(data: decoded, encoding: .utf8) {
            credentials = value
        } else {
            throw MaosVPNError.malformedProfile(AppLanguage.text(
                russian: "Shadowsocks credentials повреждены",
                english: "Shadowsocks credentials are malformed"
            ))
        }
        let parts = credentials.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw MaosVPNError.malformedProfile(AppLanguage.text(
                russian: "в Shadowsocks отсутствует метод шифрования",
                english: "Shadowsocks encryption method is missing"
            ))
        }
        var parameters = query
        parameters["method"] = parts[0]
        return VPNProfile(name: name, kind: .shadowsocks, server: host, port: port, credential: parts[1], parameters: parameters)
    }

    private static func dictionary(from items: [URLQueryItem]) -> [String: String] {
        var result: [String: String] = [:]
        for item in items {
            result[item.name] = item.value ?? ""
        }
        return result
    }

    private static func decodeBase64(_ source: String) -> Data? {
        var normalized = source
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: normalized, options: .ignoreUnknownCharacters)
    }
}
