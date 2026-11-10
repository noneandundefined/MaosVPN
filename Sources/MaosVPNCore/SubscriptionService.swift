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
        loadWithMetadata(from: url) { result in
            completion(result.map { $0.profiles })
        }
    }

    // Panels often serve sing-box JSON to Karing but share links to Happ or
    // v2rayNG. Test a small, fixed list sequentially (not in parallel) and
    // choose the largest *importable* result. Never merge unrelated formats.
    static let candidateUserAgents = [
        "Karing",
        "Happ/3.3.6",
        "v2rayNG/2.2.6",
        "sing-box/1.13.14"
    ]

    private struct Choice {
        let profiles: [VPNProfile]
        let metadata: SubscriptionMetadata?
        let userAgent: String
        let diagnostics: SubscriptionImportDiagnostics
    }

    public func loadWithMetadata(from url: URL, completion: @escaping (Result<SubscriptionResponse, Error>) -> Void) {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        probe(url: url, osVersion: osVersion, index: 0, best: nil, fallbackMetadata: nil,
              comparisons: [], firstError: nil, completion: completion)
    }

    private func finish(best: Choice?, fallbackMetadata: SubscriptionMetadata?,
                        comparisons: [SubscriptionCandidate], error: Error?,
                        completion: @escaping (Result<SubscriptionResponse, Error>) -> Void) {
        guard let chosen = best else {
            completion(.failure(error ?? MaosVPNError.unsupportedSubscription))
            return
        }
        completion(.success(SubscriptionResponse(
            profiles: chosen.profiles,
            metadata: chosen.metadata ?? fallbackMetadata,
            userAgent: chosen.userAgent,
            comparisons: comparisons,
            diagnostics: chosen.diagnostics
        )))
    }

    private func probe(url: URL, osVersion: String, index: Int, best: Choice?,
                       fallbackMetadata: SubscriptionMetadata?,
                       comparisons: [SubscriptionCandidate], firstError: Error?,
                       completion: @escaping (Result<SubscriptionResponse, Error>) -> Void) {
        guard index < Self.candidateUserAgents.count else {
            finish(best: best, fallbackMetadata: fallbackMetadata,
                   comparisons: comparisons, error: firstError, completion: completion)
            return
        }
        let userAgent = Self.candidateUserAgents[index]
        var request = Self.makeRequest(for: url, hardwareID: hardwareID,
                                       osVersion: osVersion, userAgent: userAgent)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        session.dataTask(with: request) { [self] data, response, error in
            // A transient network error likely affects every variant; stop
            // rather than hammering a struggling provider with more requests.
            if let error = error {
                self.finish(best: best, fallbackMetadata: fallbackMetadata,
                            comparisons: comparisons, error: firstError ?? error, completion: completion)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                self.finish(best: best, fallbackMetadata: fallbackMetadata,
                            comparisons: comparisons, error: firstError ?? MaosVPNError.unsupportedSubscription,
                            completion: completion)
                return
            }

            // Never try to work around provider authentication, device limits
            // or rate limiting by changing the User-Agent.
            if http.value(forHTTPHeaderField: "x-hwid-not-supported")?.lowercased() == "true" ||
                http.statusCode == 401 || http.statusCode == 403 || http.statusCode == 429 {
                let rejection: Error = http.value(forHTTPHeaderField: "x-hwid-not-supported")?.lowercased() == "true"
                    ? MaosVPNError.subscriptionAccessRejected
                    : MaosVPNError.malformedProfile(AppLanguage.text(
                        russian: "сервер подписки вернул HTTP \(http.statusCode)",
                        english: "the subscription server returned HTTP \(http.statusCode)"
                    ))
                self.finish(best: best, fallbackMetadata: fallbackMetadata,
                            comparisons: comparisons, error: firstError ?? rejection, completion: completion)
                return
            }

            var nextBest = best
            var nextMetadata = fallbackMetadata
            var nextComparisons = comparisons
            var nextError = firstError
            if (200...299).contains(http.statusCode), let data = data, !data.isEmpty,
               data.count <= 10 * 1024 * 1024 {
                do {
                    let parsed = try ShareLinkParser.parseDetailed(data)
                    // A malformed profile cannot be activated; keep an explicit
                    // diagnostic instead of pretending it is a working node.
                    var rejected = parsed.skipped
                    let compatible = parsed.profiles.filter { profile in
                        if (try? SingBoxConfigBuilder.makeConfig(for: profile)) != nil {
                            return true
                        }
                        rejected.append(SkippedSubscriptionServer(
                            title: profile.name, type: profile.kind.rawValue,
                            reason: AppLanguage.text(
                                russian: "ошибка построения конфигурации",
                                english: "cannot build sing-box config"
                            )
                        ))
                        return false
                    }
                    let diagnostics = SubscriptionImportDiagnostics(
                        received: parsed.received, imported: compatible.count,
                        skipped: rejected, userAgent: userAgent
                    )
                    let metadata = SubscriptionMetadata.parse(response: http, body: data)
                    if nextMetadata == nil { nextMetadata = metadata }
                    nextComparisons.append(SubscriptionCandidate(userAgent: userAgent,
                                                                  compatibleCount: compatible.count))
                    if !compatible.isEmpty && compatible.count > (best?.profiles.count ?? 0) {
                        nextBest = Choice(profiles: compatible, metadata: metadata,
                                          userAgent: userAgent, diagnostics: diagnostics)
                    }
                } catch {
                    // Some panels express a device limit as a fake 0.0.0.0:1
                    // update-required profile instead of an HTTP error.
                    if let rejected = error as? MaosVPNError,
                       case .subscriptionAccessRejected = rejected {
                        self.finish(best: best, fallbackMetadata: fallbackMetadata,
                                    comparisons: comparisons, error: rejected, completion: completion)
                        return
                    }
                    if nextError == nil { nextError = error }
                    nextComparisons.append(SubscriptionCandidate(userAgent: userAgent, compatibleCount: 0))
                }
            } else {
                if nextError == nil {
                    nextError = MaosVPNError.malformedProfile(AppLanguage.text(
                        russian: "сервер подписки вернул HTTP \(http.statusCode) или пустой ответ",
                        english: "the subscription server returned HTTP \(http.statusCode) or an empty response"
                    ))
                }
                nextComparisons.append(SubscriptionCandidate(userAgent: userAgent, compatibleCount: 0))
            }

            self.probe(url: url, osVersion: osVersion, index: index + 1,
                       best: nextBest, fallbackMetadata: nextMetadata,
                       comparisons: nextComparisons, firstError: nextError,
                       completion: completion)
        }.resume()
    }

    public static func parseConfiguration(_ text: String) throws -> [VPNProfile] {
        try parseConfigurationWithDiagnostics(text).profiles
    }

    public static func parseConfigurationWithDiagnostics(_ text: String) throws -> SubscriptionResponse {
        let data = Data(text.utf8)
        guard !data.isEmpty else { throw MaosVPNError.emptySubscription }
        guard data.count <= 10 * 1024 * 1024 else {
            throw MaosVPNError.malformedProfile(AppLanguage.text(
                russian: "конфигурация превышает 10 МБ",
                english: "the configuration exceeds 10 MB"
            ))
        }
        let parsed = try ShareLinkParser.parseDetailed(data)
        return SubscriptionResponse(
            profiles: parsed.profiles,
            metadata: SubscriptionMetadata.parse(response: nil, body: data),
            userAgent: AppLanguage.text(russian: "Локальный JSON", english: "Local JSON"),
            diagnostics: SubscriptionImportDiagnostics(
                received: parsed.received, imported: parsed.profiles.count,
                skipped: parsed.skipped,
                userAgent: AppLanguage.text(russian: "Локальный JSON", english: "Local JSON")
            )
        )
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
        deviceModel: String = "Mac",
        userAgent: String = "Karing"
    ) -> URLRequest {
        var request = URLRequest(url: url)

        // Karing-compatible panels return a sing-box JSON document. The
        // stable device headers prevent HWID-enabled panels from returning a
        // fake 0.0.0.0:1 update profile.
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(hardwareID, forHTTPHeaderField: "X-Hwid")
        request.setValue("macOS", forHTTPHeaderField: "X-Device-Os")
        request.setValue(osVersion, forHTTPHeaderField: "X-Ver-Os")
        request.setValue(deviceModel, forHTTPHeaderField: "X-Device-Model")

        return request
    }
}

enum ShareLinkParser {
    struct Parsed {
        let profiles: [VPNProfile]
        let received: Int
        let skipped: [SkippedSubscriptionServer]
    }

    static func parseSubscription(_ data: Data) throws -> [VPNProfile] {
        try parseDetailed(data).profiles
    }

    static func parseDetailed(_ data: Data) throws -> Parsed {
        guard var text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { throw MaosVPNError.emptySubscription }

        if !text.contains("://"), let decoded = decodeBase64(text),
           let decodedText = String(data: decoded, encoding: .utf8) {
            text = decodedText
        }

        if let parsed = parseSingBoxJSONDetailed(Data(text.utf8)) {
            return try validate(parsed)
        }

        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        var profiles: [VPNProfile] = []
        var skipped: [SkippedSubscriptionServer] = []
        for (index, line) in lines.enumerated() {
            let kind = String(line.split(separator: ":", maxSplits: 1).first ?? "unknown")
            do {
                let profile = try parse(line)
                // Detect malformed configurations *during import*, rather
                // than silently putting a non-working profile in the UI.
                _ = try SingBoxConfigBuilder.makeOutbounds(for: profile, primaryTag: "proxy")
                profiles.append(profile)
            } catch {
                skipped.append(SkippedSubscriptionServer(
                    title: "Line \(index + 1)", type: kind,
                    reason: skipReason(error)
                ))
            }
        }
        return try validate(Parsed(profiles: profiles, received: lines.count, skipped: skipped))
    }

    private static func validate(_ parsed: Parsed) throws -> Parsed {
        let placeholders = parsed.profiles.filter(isProviderPlaceholder)
        let valid = parsed.profiles.filter { !isProviderPlaceholder($0) }
        if valid.isEmpty && !placeholders.isEmpty { throw MaosVPNError.subscriptionAccessRejected }

        let reports = parsed.skipped + placeholders.map {
            SkippedSubscriptionServer(
                title: $0.name, type: $0.kind.rawValue,
                reason: AppLanguage.text(russian: "заглушка провайдера", english: "provider placeholder")
            )
        }
        guard !valid.isEmpty else {
            let reasons = reports.prefix(4).map { "\($0.type): \($0.reason)" }.joined(separator: "; ")
            throw MaosVPNError.malformedProfile(
                AppLanguage.text(
                    russian: "нет совместимых серверов из \(parsed.received). \(reasons)",
                    english: "no compatible servers among \(parsed.received). \(reasons)"
                )
            )
        }
        return Parsed(profiles: valid, received: parsed.received, skipped: reports)
    }

    private static func skipReason(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return String(text.prefix(160))
    }

    private static func parseSingBoxJSONDetailed(_ data: Data) -> Parsed? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let outbounds: [[String: Any]]
        if let document = json as? [String: Any],
           let values = document["outbounds"] as? [[String: Any]] {
            outbounds = values
        } else if let values = json as? [[String: Any]] {
            outbounds = values
        } else { return nil }

        var source: [String: [String: Any]] = [:]
        for item in outbounds {
            if let tag = item["tag"] as? String, !tag.isEmpty, source[tag] == nil {
                source[tag] = item
            }
        }

        // SOCKS/HTTP/ShadowTLS and other auxiliary outbounds referenced by
        // a chain are implemented as hops, not separate list entries.
        var referenced = Set<String>()
        for outbound in outbounds {
            if let upstream = ProviderOutboundGraph.detour(outbound) { referenced.insert(upstream) }
            if let group = outbound["outbounds"] as? [String] {
                referenced.formUnion(group)
            }
        }

        var profiles: [VPNProfile] = []
        var skipped: [SkippedSubscriptionServer] = []
        var received = 0
        for (index, item) in outbounds.enumerated() {
            let kind = (item["type"] as? String)?.lowercased() ?? "unknown"
            // These are control outbounds, not VPN endpoints for the UI.
            if ["direct", "block", "dns", "selector", "urltest"].contains(kind) { continue }
            if let tag = item["tag"] as? String,
               referenced.contains(tag),
               ProviderOutboundGraph.dependencies.contains(kind),
               !ProviderOutboundGraph.endpoints.contains(kind) {
                continue
            }
            received += 1
            let title = String((item["tag"] as? String ?? "Node \(index + 1)").prefix(80))
            guard ProviderOutboundGraph.endpoints.contains(kind) else {
                skipped.append(SkippedSubscriptionServer(
                    title: title, type: kind,
                    reason: AppLanguage.text(russian: "протокол пока не поддерживается",
                                              english: "protocol is not supported")
                ))
                continue
            }
            guard let profile = parseSingBoxOutbound(item) else {
                skipped.append(SkippedSubscriptionServer(
                    title: title, type: kind,
                    reason: AppLanguage.text(russian: "не хватает адреса, порта или данных доступа",
                                              english: "missing server, port or credentials")
                ))
                continue
            }
            do {
                // Graph construction preserves full provider TLS, transport,
                // detour and protocol-specific fields without applying
                // arbitrary provider-side TUN, DNS or routing settings.
                let encoded = try ProviderOutboundGraph.extract(root: item, from: source)
                let value = VPNProfile(
                    name: profile.name, kind: profile.kind,
                    server: profile.server, port: profile.port,
                    credential: profile.credential, parameters: profile.parameters,
                    sourceOutboundsJSON: encoded
                )
                _ = try SingBoxConfigBuilder.makeOutbounds(for: value, primaryTag: "proxy")
                profiles.append(value)
            } catch {
                skipped.append(SkippedSubscriptionServer(
                    title: title, type: kind, reason: skipReason(error)
                ))
            }
        }
        return Parsed(profiles: profiles, received: received, skipped: skipped)
    }

    private static func parseSingBoxOutbound(_ outbound: [String: Any]) -> VPNProfile? {
        guard let rawType = string("type", in: outbound)?.lowercased(),
              let server = string("server", in: outbound), !server.isEmpty else {
            return nil
        }
        let port = integer("server_port", in: outbound) ?? firstServerPort(outbound)
        guard let resolvedPort = port, (1...65535).contains(resolvedPort) else { return nil }

        let kind: VPNProtocolKind
        let credential: String
        switch rawType {
        case "vless":
            guard let uuid = string("uuid", in: outbound), !uuid.isEmpty else { return nil }
            kind = .vless
            credential = uuid
        case "vmess":
            guard let uuid = string("uuid", in: outbound), !uuid.isEmpty else { return nil }
            kind = .vmess
            credential = uuid
        case "trojan":
            guard let password = string("password", in: outbound), !password.isEmpty else { return nil }
            kind = .trojan
            credential = password
        case "shadowsocks":
            guard let password = string("password", in: outbound), !password.isEmpty,
                  let method = string("method", in: outbound), !method.isEmpty else { return nil }
            kind = .shadowsocks
            credential = password
        case "hysteria":
            guard let password = string("auth_str", in: outbound) ?? string("auth", in: outbound),
                  !password.isEmpty else { return nil }
            kind = .hysteria
            credential = password
        case "hysteria2", "hy2":
            guard let password = string("password", in: outbound), !password.isEmpty else { return nil }
            kind = .hysteria2
            credential = password
        default:
            return nil
        }

        var parameters: [String: String] = [:]
        copyString("flow", from: outbound, to: "flow", in: &parameters)
        copyString("packet_encoding", from: outbound, to: "packetEncoding", in: &parameters)
        copyScalar("up_mbps", from: outbound, to: "up_mbps", in: &parameters)
        copyScalar("down_mbps", from: outbound, to: "down_mbps", in: &parameters)
        copyString("up", from: outbound, to: "up", in: &parameters)
        copyString("down", from: outbound, to: "down", in: &parameters)
        copyString("network", from: outbound, to: "network", in: &parameters)
        if kind == .hysteria && outbound["auth_str"] == nil { parameters["authType"] = "auth" }

        if kind == .vmess {
            copyString("security", from: outbound, to: "scy", in: &parameters)
            copyScalar("alter_id", from: outbound, to: "aid", in: &parameters)
        } else if kind == .shadowsocks {
            copyString("method", from: outbound, to: "method", in: &parameters)
        }

        if let transport = outbound["transport"] as? [String: Any] {
            copyString("type", from: transport, to: "type", in: &parameters)
            copyString("path", from: transport, to: "path", in: &parameters)
            copyString("service_name", from: transport, to: "serviceName", in: &parameters)
            if let host = string("host", in: transport) {
                parameters["host"] = host
            } else if let hosts = transport["host"] as? [String], !hosts.isEmpty {
                parameters["host"] = hosts.joined(separator: ",")
            } else if let headers = transport["headers"] as? [String: Any],
                      let host = headers.first(where: { $0.key.lowercased() == "host" })?.value as? String {
                parameters["host"] = host
            }
        }

        if let tls = outbound["tls"] as? [String: Any], boolean("enabled", in: tls) != false {
            parameters["security"] = "tls"
            copyString("server_name", from: tls, to: "sni", in: &parameters)
            if boolean("insecure", in: tls) == true { parameters["allowInsecure"] = "true" }
            if let alpn = tls["alpn"] as? [String], !alpn.isEmpty {
                parameters["alpn"] = alpn.joined(separator: ",")
            }
            if let utls = tls["utls"] as? [String: Any] {
                copyString("fingerprint", from: utls, to: "fp", in: &parameters)
            }
            if let reality = tls["reality"] as? [String: Any], boolean("enabled", in: reality) != false {
                parameters["security"] = "reality"
                copyString("public_key", from: reality, to: "pbk", in: &parameters)
                copyString("short_id", from: reality, to: "sid", in: &parameters)
            }
        }

        if let obfs = outbound["obfs"] as? [String: Any] {
            copyString("type", from: obfs, to: "obfs", in: &parameters)
            copyString("password", from: obfs, to: "obfs-password", in: &parameters)
        }

        let name = string("tag", in: outbound).flatMap { $0.isEmpty ? nil : $0 } ?? "\(server):\(port)"
        return VPNProfile(
            name: name,
            kind: kind,
            server: server,
            port: resolvedPort,
            credential: credential,
            parameters: parameters
        )
    }

    private static func firstServerPort(_ value: [String: Any]) -> Int? {
        guard let ports = value["server_ports"] as? [String],
              let first = ports.first else { return nil }
        return Int(first.split(separator: ":").first ?? "")
    }

    private static func string(_ key: String, in object: [String: Any]) -> String? {
        object[key] as? String
    }

    private static func integer(_ key: String, in object: [String: Any]) -> Int? {
        if let value = object[key] as? Int { return value }
        if let value = object[key] as? NSNumber { return value.intValue }
        if let value = object[key] as? String { return Int(value) }
        return nil
    }

    private static func boolean(_ key: String, in object: [String: Any]) -> Bool? {
        if let value = object[key] as? Bool { return value }
        if let value = object[key] as? NSNumber { return value.boolValue }
        if let value = object[key] as? String {
            return ["1", "true", "yes"].contains(value.lowercased())
        }
        return nil
    }

    private static func copyString(
        _ sourceKey: String,
        from object: [String: Any],
        to targetKey: String,
        in parameters: inout [String: String]
    ) {
        if let value = string(sourceKey, in: object), !value.isEmpty {
            parameters[targetKey] = value
        }
    }

    private static func copyScalar(
        _ sourceKey: String,
        from object: [String: Any],
        to targetKey: String,
        in parameters: inout [String: String]
    ) {
        if let value = object[sourceKey] as? String {
            parameters[targetKey] = value
        } else if let value = object[sourceKey] as? NSNumber {
            parameters[targetKey] = value.stringValue
        }
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
        case "hysteria":
            let credential = components.user?.removingPercentEncoding
                ?? query["auth_str"] ?? query["auth"] ?? query["password"]
            guard let password = credential, !password.isEmpty else {
                throw MaosVPNError.malformedProfile("Hysteria v1 auth is missing")
            }
            var parameters = query
            if parameters["up_mbps"] == nil {
                parameters["up_mbps"] = query["upmbps"] ?? query["upMbps"]
            }
            if parameters["down_mbps"] == nil {
                parameters["down_mbps"] = query["downmbps"] ?? query["downMbps"]
            }
            if parameters["network"] == nil {
                parameters["network"] = query["protocol"]
            }
            if parameters["sni"] == nil { parameters["sni"] = query["peer"] }
            if parameters["obfs"] == nil { parameters["obfs"] = query["obfsParam"] }
            if components.user == nil && query["auth"] != nil {
                parameters["authType"] = "auth"
            }
            return VPNProfile(name: name, kind: .hysteria, server: host,
                              port: port, credential: password, parameters: parameters)
        case "hysteria2", "hy2":
            guard let password = components.user?.removingPercentEncoding, !password.isEmpty else {
                throw MaosVPNError.malformedProfile(AppLanguage.text(
                    russian: "в Hysteria2 отсутствует пароль",
                    english: "Hysteria2 password is missing"
                ))
            }
            return VPNProfile(name: name, kind: .hysteria2, server: host, port: port, credential: password, parameters: query)
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
