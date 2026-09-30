import XCTest
@testable import MaosVPNCore

final class ShareLinkParserTests: XCTestCase {
    func testLocalizedErrorsFollowSelectedLanguage() {
        let original = AppLanguage.current
        defer { AppLanguage.current = original }

        AppLanguage.current = .english
        XCTAssertEqual(MaosVPNError.invalidSubscriptionURL.errorDescription, "Enter a valid HTTPS subscription URL.")

        AppLanguage.current = .russian
        XCTAssertEqual(MaosVPNError.invalidSubscriptionURL.errorDescription, "Введите корректную ссылку подписки HTTPS.")
    }

    func testParsesBase64VLESSSubscription() throws {
        let source = "vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?encryption=none&type=ws&security=tls&sni=example.com&path=%2Fvpn#Test%20Server\n"
        let encoded = Data(source.utf8).base64EncodedData()
        let profiles = try ShareLinkParser.parseSubscription(encoded)

        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].name, "Test Server")
        XCTAssertEqual(profiles[0].kind, .vless)
        XCTAssertEqual(profiles[0].server, "example.com")
        XCTAssertEqual(profiles[0].port, 443)
        XCTAssertEqual(profiles[0].parameters["type"], "ws")
    }

    func testSubscriptionRequestUsesStableHappDeviceHeaders() {
        let suiteName = "MaosVPNTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstHardwareID = SubscriptionService.persistentHardwareID(in: defaults)
        let secondHardwareID = SubscriptionService.persistentHardwareID(in: defaults)
        XCTAssertEqual(firstHardwareID, secondHardwareID)
        XCTAssertNotNil(UUID(uuidString: firstHardwareID))

        let request = SubscriptionService.makeRequest(
            for: URL(string: "https://example.com/sub/test")!,
            hardwareID: firstHardwareID,
            osVersion: "10.15.7"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Happ/4.3.0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hwid"), firstHardwareID)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Os"), "macOS")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Ver-Os"), "10.15.7")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Model"), "Mac")
    }

    func testRejectsProviderUpdatePlaceholder() {
        let placeholder = "vless://00000000-0000-0000-0000-000000000000@0.0.0.0:1?encryption=none&type=tcp&security=none#%F0%9F%9A%A7%20Update%20the%20app%20%F0%9F%9A%A7"
        let encoded = Data(placeholder.utf8).base64EncodedData()

        XCTAssertThrowsError(try ShareLinkParser.parseSubscription(encoded)) { error in
            guard let vpnError = error as? MaosVPNError,
                  case .subscriptionAccessRejected = vpnError else {
                return XCTFail("Expected subscriptionAccessRejected, got \(error)")
            }
        }
    }

    func testParsesTrojan() throws {
        let profile = try ShareLinkParser.parse("trojan://secret@example.org:443?security=tls&sni=example.org#Europe")
        XCTAssertEqual(profile.kind, .trojan)
        XCTAssertEqual(profile.credential, "secret")
        XCTAssertEqual(profile.name, "Europe")
    }

    func testParsesPlainVLESSTCPProfile() throws {
        let profile = try ShareLinkParser.parse("vless://123e4567-e89b-12d3-a456-426614174000@example.net:1?encryption=none&type=tcp&security=none#Direct")
        XCTAssertEqual(profile.kind, .vless)
        XCTAssertEqual(profile.port, 1)
        XCTAssertEqual(profile.parameters["security"], "none")

        let config = try SingBoxConfigBuilder.makeConfig(for: profile)
        let data = try JSONSerialization.data(withJSONObject: config)
        let text = String(data: data, encoding: .utf8)!
        XCTAssertFalse(text.contains("\"tls\""))
        XCTAssertFalse(text.contains("\"transport\""))
    }

    func testConfigDoesNotContainSubscriptionURL() throws {
        let profile = VPNProfile(
            name: "Test",
            kind: .vless,
            server: "127.0.0.1",
            port: 443,
            credential: "123e4567-e89b-12d3-a456-426614174000",
            parameters: ["type": "tcp", "security": "none"]
        )
        let config = try SingBoxConfigBuilder.makeConfig(for: profile)
        let data = try JSONSerialization.data(withJSONObject: config)
        let text = String(data: data, encoding: .utf8)!
        XCTAssertFalse(text.contains("subscription"))
        XCTAssertTrue(text.contains("tun"))
    }
}
