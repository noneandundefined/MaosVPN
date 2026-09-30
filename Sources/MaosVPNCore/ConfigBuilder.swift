import Foundation

public enum SingBoxConfigBuilder {
    public static func makeConfig(for profile: VPNProfile) throws -> [String: Any] {
        guard !profile.server.isEmpty, (1...65535).contains(profile.port) else {
            throw MaosVPNError.malformedProfile(AppLanguage.text(
                russian: "пустой адрес или неверный порт",
                english: "empty address or invalid port"
            ))
        }

        let proxy = try makeOutbound(for: profile)
        let isIPAddress = IPv4Address(profile.server) || profile.server.contains(":")

        var dnsRules: [[String: Any]] = []
        if !isIPAddress {
            dnsRules.append([
                "domain": [profile.server],
                "action": "route",
                "server": "dns-direct"
            ])
        }

        return [
            "log": [
                "level": "info",
                "timestamp": true
            ],
            "dns": [
                "servers": [
                    ["type": "local", "tag": "dns-direct"],
                    ["type": "https", "tag": "dns-remote", "server": "1.1.1.1", "detour": "proxy"]
                ],
                "rules": dnsRules,
                "final": "dns-remote",
                "strategy": "prefer_ipv4"
            ],
            "inbounds": [[
                "type": "tun",
                "tag": "tun-in",
                "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
                "mtu": 9000,
                "auto_route": true,
                "strict_route": true,
                "stack": "system"
            ]],
            "outbounds": [
                proxy,
                ["type": "direct", "tag": "direct"]
            ],
            "route": [
                "auto_detect_interface": true,
                "default_domain_resolver": "dns-direct",
                "rules": [
                    ["inbound": "tun-in", "action": "sniff"],
                    ["protocol": "dns", "action": "hijack-dns"]
                ],
                "final": "proxy"
            ]
        ]
    }

    private static func makeOutbound(for profile: VPNProfile) throws -> [String: Any] {
        var outbound: [String: Any] = [
            "type": profile.kind.rawValue,
            "tag": "proxy",
            "server": profile.server,
            "server_port": profile.port
        ]

        switch profile.kind {
        case .vless:
            outbound["uuid"] = profile.credential
            if let flow = nonEmpty(profile.parameters["flow"]) { outbound["flow"] = flow }
        case .vmess:
            outbound["uuid"] = profile.credential
            outbound["security"] = nonEmpty(profile.parameters["scy"]) ?? "auto"
            outbound["alter_id"] = Int(profile.parameters["aid"] ?? "0") ?? 0
        case .trojan:
            outbound["password"] = profile.credential
        case .shadowsocks:
            guard let method = nonEmpty(profile.parameters["method"]) else {
                throw MaosVPNError.malformedProfile(AppLanguage.text(
                    russian: "не указан метод Shadowsocks",
                    english: "Shadowsocks encryption method is missing"
                ))
            }
            outbound["method"] = method
            outbound["password"] = profile.credential
        case .hysteria2:
            outbound["password"] = profile.credential
            if let upMbps = Int(profile.parameters["up_mbps"] ?? ""), upMbps > 0 {
                outbound["up_mbps"] = upMbps
            }
            if let downMbps = Int(profile.parameters["down_mbps"] ?? ""), downMbps > 0 {
                outbound["down_mbps"] = downMbps
            }
            if let obfsType = nonEmpty(profile.parameters["obfs"]),
               let obfsPassword = nonEmpty(profile.parameters["obfs-password"] ?? profile.parameters["obfs_password"]) {
                outbound["obfs"] = ["type": obfsType, "password": obfsPassword]
            }
        }

        if profile.kind != .hysteria2 {
            let network = (profile.parameters["type"] ?? profile.parameters["net"] ?? "tcp").lowercased()
            if let transport = makeTransport(network: network, parameters: profile.parameters) {
                outbound["transport"] = transport
            }
        }

        let defaultSecurity = (profile.kind == .trojan || profile.kind == .hysteria2) ? "tls" : "none"
        let security = (profile.parameters["security"] ?? profile.parameters["tls"] ?? defaultSecurity).lowercased()
        if security == "tls" || security == "reality" {
            var tls: [String: Any] = ["enabled": true]
            if let serverName = nonEmpty(profile.parameters["sni"] ?? profile.parameters["peer"]) {
                tls["server_name"] = serverName
            }
            if truthy(profile.parameters["allowInsecure"] ?? profile.parameters["insecure"]) { tls["insecure"] = true }
            if let alpn = nonEmpty(profile.parameters["alpn"]) {
                tls["alpn"] = alpn.split(separator: ",").map(String.init)
            }
            if let fingerprint = nonEmpty(profile.parameters["fp"]) {
                tls["utls"] = ["enabled": true, "fingerprint": fingerprint]
            }
            if security == "reality" {
                guard let publicKey = nonEmpty(profile.parameters["pbk"]) else {
                    throw MaosVPNError.malformedProfile(AppLanguage.text(
                        russian: "в Reality отсутствует public key",
                        english: "Reality public key is missing"
                    ))
                }
                var reality: [String: Any] = ["enabled": true, "public_key": publicKey]
                if let shortID = nonEmpty(profile.parameters["sid"]) { reality["short_id"] = shortID }
                tls["reality"] = reality
            }
            outbound["tls"] = tls
        }

        if let packetEncoding = nonEmpty(profile.parameters["packetEncoding"]) {
            outbound["packet_encoding"] = packetEncoding
        }
        return outbound
    }

    private static func makeTransport(network: String, parameters: [String: String]) -> [String: Any]? {
        switch network {
        case "tcp":
            guard parameters["headerType"]?.lowercased() == "http" else { return nil }
            var transport: [String: Any] = ["type": "http"]
            if let path = nonEmpty(parameters["path"]) { transport["path"] = path }
            if let host = nonEmpty(parameters["host"]) {
                transport["host"] = host.split(separator: ",").map(String.init)
            }
            return transport
        case "http", "h2":
            var transport: [String: Any] = ["type": "http"]
            if let path = nonEmpty(parameters["path"]) { transport["path"] = path }
            if let host = nonEmpty(parameters["host"]) {
                transport["host"] = host.split(separator: ",").map(String.init)
            }
            return transport
        case "ws", "websocket":
            var transport: [String: Any] = ["type": "ws"]
            if let path = nonEmpty(parameters["path"]) { transport["path"] = path }
            if let host = nonEmpty(parameters["host"]) { transport["headers"] = ["Host": host] }
            if let earlyData = Int(parameters["ed"] ?? ""), earlyData > 0 {
                transport["max_early_data"] = earlyData
                transport["early_data_header_name"] = nonEmpty(parameters["eh"]) ?? "Sec-WebSocket-Protocol"
            }
            return transport
        case "grpc":
            var transport: [String: Any] = ["type": "grpc"]
            if let service = nonEmpty(parameters["serviceName"] ?? parameters["path"]) {
                transport["service_name"] = service
            }
            return transport
        case "httpupgrade":
            var transport: [String: Any] = ["type": "httpupgrade"]
            if let path = nonEmpty(parameters["path"]) { transport["path"] = path }
            if let host = nonEmpty(parameters["host"]) { transport["host"] = host }
            return transport
        case "quic":
            return ["type": "quic"]
        default:
            return nil
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value, !value.isEmpty else { return nil }
        return value
    }

    private static func truthy(_ value: String?) -> Bool {
        guard let value = value?.lowercased() else { return false }
        return value == "1" || value == "true" || value == "yes"
    }

    private static func IPv4Address(_ value: String) -> Bool {
        let parts = value.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { part in
            guard let number = Int(part) else { return false }
            return (0...255).contains(number)
        }
    }
}
