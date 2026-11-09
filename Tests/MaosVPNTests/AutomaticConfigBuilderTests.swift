import XCTest
@testable import MaosVPNCore

final class AutomaticConfigBuilderTests: XCTestCase {
    private func profile(_ host: String, id: UUID = UUID()) -> VPNProfile {
        VPNProfile(id: id, name: host, kind: .vless, server: host, port: 443,
                   credential: "01234567-89ab-cdef-0123-456789abcdef",
                   parameters: ["security": "tls"])
    }

    func testAutomaticConfigHasDistinctOutboundsAndTransparentSwitching() throws {
        let config = try AutomaticConfigBuilder.makeConfig(for: [profile("one.example.com"), profile("two.example.com")])
        let outbounds = try XCTUnwrap(config["outbounds"] as? [[String: Any]])
        XCTAssertEqual(outbounds.count, 4)
        XCTAssertEqual(outbounds[0]["tag"] as? String, "proxy-0")
        XCTAssertEqual(outbounds[1]["tag"] as? String, "proxy-1")
        let auto = try XCTUnwrap(outbounds[2] as? [String: Any])
        XCTAssertEqual(auto["type"] as? String, "urltest")
        XCTAssertEqual(auto["outbounds"] as? [String], ["proxy-0", "proxy-1"])
        XCTAssertEqual(auto["interrupt_exist_connections"] as? Bool, false)
        let route = try XCTUnwrap(config["route"] as? [String: Any])
        XCTAssertEqual(route["final"] as? String, "auto")
        let dns = try XCTUnwrap(config["dns"] as? [String: Any])
        XCTAssertEqual((dns["rules"] as? [[String: Any]])?.count, 2)
    }

    func testNoProfilesFails() {
        XCTAssertThrowsError(try AutomaticConfigBuilder.makeConfig(for: []))
    }

    func testInvalidNodeDoesNotPreventValidNodesFromWorking() throws {
        let invalid = VPNProfile(name: "invalid", kind: .vless, server: "", port: 0, credential: "")
        let config = try AutomaticConfigBuilder.makeConfig(for: [profile("one.example.com"), invalid])
        let outbounds = try XCTUnwrap(config["outbounds"] as? [[String: Any]])
        XCTAssertEqual((outbounds[1]["outbounds"] as? [String])?.count, 1)
    }
}
