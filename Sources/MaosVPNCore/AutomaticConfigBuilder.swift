import Foundation

/// Builds a sing-box urltest group so the core can switch servers without
/// restarting the TUN interface or requesting administrator privileges again.
public enum AutomaticConfigBuilder {
    public static func makeConfig(for profiles: [VPNProfile]) throws -> [String: Any] {
        guard !profiles.isEmpty else { throw MaosVPNError.emptySubscription }
        guard let first = profiles.first(where: { (try? SingBoxConfigBuilder.makeConfig(for: $0)) != nil }) else {
            throw MaosVPNError.unsupportedSubscription
        }
        var config = try SingBoxConfigBuilder.makeConfig(for: first)
        var outbounds: [[String: Any]] = []
        var tags: [String] = []
        var domains = Set<String>()

        for profile in profiles {
            // A malformed individual node must not break every valid server.
            guard let candidate = try? SingBoxConfigBuilder.makeConfig(for: profile),
                  let candidateOutbounds = candidate["outbounds"] as? [[String: Any]],
                  var proxy = candidateOutbounds.first else { continue }
            let tag = "proxy-\(tags.count)"
            proxy["tag"] = tag
            outbounds.append(proxy)
            tags.append(tag)

            let parts = profile.server.split(separator: ".")
            let isIPv4 = parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
            if !isIPv4 && !profile.server.contains(":") {
                domains.insert(profile.server)
            }
        }
        guard !tags.isEmpty else { throw MaosVPNError.unsupportedSubscription }

        outbounds.append([
            "type": "urltest",
            "tag": "auto",
            "outbounds": tags,
            "url": "https://www.gstatic.com/generate_204",
            "interval": "30s",
            "idle_timeout": "30m",
            "tolerance": 100,
            "interrupt_exist_connections": false
        ])
        outbounds.append(["type": "direct", "tag": "direct"])
        config["outbounds"] = outbounds

        if var dns = config["dns"] as? [String: Any] {
            if var servers = dns["servers"] as? [[String: Any]] {
                for index in servers.indices where servers[index]["tag"] as? String == "dns-remote" {
                    servers[index]["detour"] = "auto"
                }
                dns["servers"] = servers
            }
            dns["rules"] = domains.sorted().map { domain in
                ["domain": [domain], "action": "route", "server": "dns-direct"] as [String: Any]
            }
            config["dns"] = dns
        }
        if var route = config["route"] as? [String: Any] {
            route["final"] = "auto"
            config["route"] = route
        }
        return config
    }
}
