import Foundation

/// A restricted outbound graph: only remote outbounds and their explicitly
/// referenced detours are retained from a provider JSON. The provider's
/// inbounds, routes, DNS settings and local listeners are never imported.
enum ProviderOutboundGraph {
    static let endpoints: Set<String> = [
        "vless", "vmess", "trojan", "shadowsocks", "hysteria", "hysteria2"
    ]
    static let dependencies: Set<String> = endpoints.union([
        "socks", "http", "shadowtls", "anytls", "tuic", "selector", "urltest"
    ])

    static func extract(root: [String: Any],
                        from dictionary: [String: [String: Any]]) throws -> String {
        guard let rootTag = root["tag"] as? String, !rootTag.isEmpty else {
            throw GraphError.missingTag
        }
        var ordered: [[String: Any]] = []
        var seen = Set<String>()
        var visiting = Set<String>()

        func visit(_ tag: String) throws {
            if tag == "direct" { return }
            if seen.contains(tag) { return }
            guard let item = dictionary[tag] else { throw GraphError.missingDependency }
            guard !visiting.contains(tag) else { throw GraphError.cyclicDetour }
            guard let kind = item["type"] as? String, dependencies.contains(kind) else {
                throw GraphError.unsupportedDependency
            }
            visiting.insert(tag)
            if let next = detour(item), !next.isEmpty { try visit(next) }
            if kind == "selector" || kind == "urltest" {
                guard let choices = item["outbounds"] as? [String], !choices.isEmpty else {
                    throw GraphError.invalidGroup
                }
                for child in choices { try visit(child) }
            }
            visiting.remove(tag)
            seen.insert(tag)
            ordered.append(item)
            guard ordered.count <= 40 else { throw GraphError.tooManyOutbounds }
        }

        try visit(rootTag)
        guard !ordered.isEmpty else { throw GraphError.missingTag }
        let data = try JSONSerialization.data(withJSONObject: ordered, options: [.sortedKeys])
        guard data.count <= 128 * 1024 else { throw GraphError.tooManyOutbounds }
        guard let result = String(data: data, encoding: .utf8) else { throw GraphError.invalidJSON }
        return result
    }

    static func detour(_ outbound: [String: Any]) -> String? {
        if let detour = outbound["detour"] as? String { return detour }
        if let dial = outbound["dial"] as? [String: Any] {
            return dial["detour"] as? String
        }
        return nil
    }

    static func resolved(_ profile: VPNProfile, primaryTag: String) throws -> [[String: Any]]? {
        guard let encoded = profile.sourceOutboundsJSON else { return nil }
        guard let data = encoded.data(using: .utf8),
              let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !array.isEmpty, array.count <= 40 else { throw GraphError.invalidJSON }

        var mapping: [String: String] = [:]
        for (i, item) in array.enumerated() {
            guard let tag = item["tag"] as? String, !tag.isEmpty,
                  let kind = item["type"] as? String, dependencies.contains(kind),
                  mapping[tag] == nil, tag != "direct" else { throw GraphError.invalidJSON }
            mapping[tag] = i == array.count - 1 ? primaryTag : "\(primaryTag)-hop-\(i)"
        }
        guard let root = array.last,
              let server = root["server"] as? String, server == profile.server,
              let rootType = root["type"] as? String,
              endpoints.contains(rootType) else { throw GraphError.invalidJSON }

        var rewritten: [[String: Any]] = []
        for raw in array {
            var node = raw
            guard let tag = raw["tag"] as? String, let replacement = mapping[tag] else {
                throw GraphError.invalidJSON
            }
            node["tag"] = replacement
            if let detour = detour(raw), !detour.isEmpty {
                guard detour == "direct" || mapping[detour] != nil else { throw GraphError.missingDependency }
                let mapped = detour == "direct" ? "direct" : mapping[detour]!
                if var dial = node["dial"] as? [String: Any], dial["detour"] != nil {
                    dial["detour"] = mapped
                    node["dial"] = dial
                }
                if node["detour"] != nil { node["detour"] = mapped }
            }
            if let group = raw["outbounds"] as? [String] {
                node["outbounds"] = try group.map { child -> String in
                    guard child == "direct" || mapping[child] != nil else { throw GraphError.missingDependency }
                    return child == "direct" ? "direct" : mapping[child]!
                }
            }
            if let defaultTag = raw["default"] as? String {
                guard defaultTag == "direct" || mapping[defaultTag] != nil else {
                    throw GraphError.missingDependency
                }
                node["default"] = defaultTag == "direct" ? "direct" : mapping[defaultTag]!
            }
            rewritten.append(node)
        }
        return rewritten
    }

    static func domains(in outbounds: [[String: Any]]) -> Set<String> {
        var result = Set<String>()
        for item in outbounds {
            guard let host = item["server"] as? String, !host.isEmpty else { continue }
            let parts = host.split(separator: ".")
            let isIPv4 = parts.count == 4 && parts.allSatisfy {
                Int($0).map { (0...255).contains($0) } ?? false
            }
            if !isIPv4 && !host.contains(":") { result.insert(host) }
        }
        return result
    }

    enum GraphError: LocalizedError {
        case missingTag, missingDependency, cyclicDetour, unsupportedDependency,
             invalidGroup, tooManyOutbounds, invalidJSON

        var errorDescription: String? {
            let ru: String
            let en: String
            switch self {
            case .missingTag: ru = "отсутствует тег узла"; en = "missing outbound tag"
            case .missingDependency: ru = "зависимый сервер не найден"; en = "missing detour"
            case .cyclicDetour: ru = "циклическая цепочка"; en = "cyclic chain"
            case .unsupportedDependency: ru = "неподдерживаемый элемент цепочки"; en = "unsupported chain element"
            case .invalidGroup: ru = "пустой selector/urltest"; en = "empty selector/urltest"
            case .tooManyOutbounds: ru = "цепочка слишком большая"; en = "chain exceeds limits"
            case .invalidJSON: ru = "некорректная цепочка JSON"; en = "invalid JSON chain"
            }
            return AppLanguage.text(russian: ru, english: en)
        }
    }
}
