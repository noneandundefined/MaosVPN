import Foundation

/// sing-box urltest checks complete proxy routes and switches the selected
/// outbound for new connections without restarting the TUN interface.
public enum AutomaticConfigBuilder {
    public static func makeConfig(for profiles: [VPNProfile]) throws -> [String: Any] {
        guard !profiles.isEmpty else { throw MaosVPNError.emptySubscription }
        guard let first = profiles.first(where: {
            (try? SingBoxConfigBuilder.makeOutbounds(for: $0, primaryTag: "proxy")) != nil
        }) else { throw MaosVPNError.unsupportedSubscription }
        var config = try SingBoxConfigBuilder.makeConfig(for: first)

        var outbounds: [[String: Any]] = []
        var tags: [String] = []
        var domains = Set<String>()
        for (index, profile) in profiles.enumerated() {
            let tag = "proxy-\(index)"
            guard let chain = try? SingBoxConfigBuilder.makeOutbounds(for: profile, primaryTag: tag) else {
                continue
            }
            outbounds.append(contentsOf: chain)
            tags.append(tag)
            domains.formUnion(ProviderOutboundGraph.domains(in: chain))
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
