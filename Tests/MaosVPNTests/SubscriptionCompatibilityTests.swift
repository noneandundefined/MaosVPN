import Foundation
import XCTest
@testable import MaosVPNCore

final class SubscriptionCompatibilityTests: XCTestCase {
    private let id = "123e4567-e89b-12d3-a456-426614174000"

    func testHysteriaV1ShareLinkBuildsRequiredFields() throws {
        let link = "hysteria://secret@hy.example.com:443?upmbps=25&downmbps=100&obfs=mask&sni=cdn.example.com&insecure=1#Hysteria"
        let profile = try ShareLinkParser.parse(link)
        XCTAssertEqual(profile.kind, .hysteria)
        let config = try SingBoxConfigBuilder.makeConfig(for: profile)
        let outbound = try XCTUnwrap((config["outbounds"] as? [[String: Any]])?.first)
        XCTAssertEqual(outbound["type"] as? String, "hysteria")
        XCTAssertEqual(outbound["up_mbps"] as? Int, 25)
        XCTAssertEqual(outbound["down_mbps"] as? Int, 100)
        XCTAssertEqual(outbound["auth_str"] as? String, "secret")
        XCTAssertEqual(outbound["obfs"] as? String, "mask")
        let tls = try XCTUnwrap(outbound["tls"] as? [String: Any])
        XCTAssertEqual(tls["server_name"] as? String, "cdn.example.com")
        XCTAssertEqual(tls["insecure"] as? Bool, true)
    }

    func testHysteriaV1JSONUsesOriginalSpecificFields() throws {
        let json = """
        {"outbounds":[
            {"type":"hysteria","tag":"HY1","server":"hy.example.com",
             "server_port":8443,"auth_str":"secret","up":"100 Mbps",
             "down":"200 Mbps","obfs":"mask","tls":{"enabled":true,"server_name":"sni.example.com"}}
        ]}
        """
        let profile = try XCTUnwrap(ShareLinkParser.parseSubscription(Data(json.utf8)).first)
        XCTAssertEqual(profile.kind, .hysteria)
        let outbound = try XCTUnwrap((SingBoxConfigBuilder.makeConfig(for: profile)["outbounds"] as? [[String: Any]])?.first)
        XCTAssertEqual(outbound["up"] as? String, "100 Mbps")
        XCTAssertEqual(outbound["down"] as? String, "200 Mbps")
        XCTAssertEqual(outbound["auth_str"] as? String, "secret")
    }

    func testJSONDetoursAndSpecialFieldsPreserved() throws {
        let json = """
        {"outbounds":[
            {"type":"socks","tag":"relay","server":"relay.example.com","server_port":1080},
            {"type":"vless","tag":"protected","server":"exit.example.com","server_port":443,
             "uuid":"123e4567-e89b-12d3-a456-426614174000","detour":"relay",
             "transport":{"type":"ws","path":"/special","max_early_data":2048},
             "tls":{"enabled":true,"server_name":"cdn.example.com","utls":{"enabled":true,"fingerprint":"chrome"}}}
        ]}
        """
        let parsed = try ShareLinkParser.parseDetailed(Data(json.utf8))
        XCTAssertEqual(parsed.profiles.count, 1)
        XCTAssertEqual(parsed.received, 2)
        XCTAssertEqual(parsed.skipped.count, 1) // relay is an implementation-only outbound
        let config = try SingBoxConfigBuilder.makeConfig(for: try XCTUnwrap(parsed.profiles.first))
        let outbounds = try XCTUnwrap(config["outbounds"] as? [[String: Any]])
        XCTAssertEqual(outbounds.count, 3)
        XCTAssertEqual(outbounds[0]["tag"] as? String, "proxy-hop-0")
        XCTAssertEqual(outbounds[1]["tag"] as? String, "proxy")
        XCTAssertEqual(outbounds[1]["detour"] as? String, "proxy-hop-0")
        let transport = try XCTUnwrap(outbounds[1]["transport"] as? [String: Any])
        XCTAssertEqual(transport["max_early_data"] as? Int, 2048)
        let tls = try XCTUnwrap(outbounds[1]["tls"] as? [String: Any])
        XCTAssertEqual((tls["utls"] as? [String: Any])?["fingerprint"] as? String, "chrome")

        let auto = try AutomaticConfigBuilder.makeConfig(for: parsed.profiles)
        let autoOutbounds = try XCTUnwrap(auto["outbounds"] as? [[String: Any]])
        XCTAssertEqual(autoOutbounds[0]["tag"] as? String, "proxy-0-hop-0")
        XCTAssertEqual(autoOutbounds[1]["detour"] as? String, "proxy-0-hop-0")
        XCTAssertEqual((autoOutbounds[2]["outbounds"] as? [String]), ["proxy-0"])
    }

    func testJSONUnresolvedChainAndUnsupportedTypeAreReported() throws {
        let json = """
        {"outbounds":[
            {"type":"vless","tag":"working","server":"working.example.com","server_port":443,
             "uuid":"123e4567-e89b-12d3-a456-426614174000"},
            {"type":"vless","tag":"broken-chain","server":"broken.example.com","server_port":443,
             "uuid":"123e4567-e89b-12d3-a456-426614174000","detour":"missing"},
            {"type":"tuic","tag":"future-protocol","server":"future.example.com","server_port":443}
        ]}
        """
        let result = try ShareLinkParser.parseDetailed(Data(json.utf8))
        XCTAssertEqual(result.received, 3)
        XCTAssertEqual(result.profiles.count, 1)
        XCTAssertEqual(result.skipped.count, 2)
        XCTAssertEqual(Set(result.skipped.map(\.title)), ["broken-chain", "future-protocol"])
        XCTAssertTrue(result.skipped.contains { $0.reason.lowercased().contains("chain") || $0.reason.lowercased().contains("detour") || $0.reason.contains("найден") })
        XCTAssertTrue(result.skipped.contains { $0.reason.lowercased().contains("protocol") || $0.reason.contains("протокол") })
    }

    func testAutomaticGraphRetagsTwoIndependentProxyChains() throws {
        let json = """
        {"outbounds":[
            {"type":"socks","tag":"hop","server":"hop.example.com","server_port":1080},
            {"type":"vless","tag":"one","server":"one.example.com","server_port":443,
             "uuid":"123e4567-e89b-12d3-a456-426614174000","detour":"hop"},
            {"type":"vless","tag":"two","server":"two.example.com","server_port":443,
             "uuid":"123e4567-e89b-12d3-a456-426614174000","detour":"hop"}
        ]}
        """
        let parsed = try ShareLinkParser.parseDetailed(Data(json.utf8))
        XCTAssertEqual(parsed.profiles.count, 2)
        let result = try AutomaticConfigBuilder.makeConfig(for: parsed.profiles)
        let outbounds = try XCTUnwrap(result["outbounds"] as? [[String: Any]])
        XCTAssertEqual(Set(outbounds.compactMap { $0["tag"] as? String }).count, outbounds.count)
        XCTAssertEqual(outbounds[1]["detour"] as? String, "proxy-0-hop-0")
        XCTAssertEqual(outbounds[3]["detour"] as? String, "proxy-1-hop-0")
        XCTAssertEqual((outbounds[4]["outbounds"] as? [String]), ["proxy-0", "proxy-1"])
    }

    func testPlainTextSkippingNeverContainsRawCredentials() throws {
        let text = """
        vless://123e4567-e89b-12d3-a456-426614174000@valid.example.com:443#Valid
        unsupported://private-password@host.example.com:443#Secret
        hysteria://key@hy.example.com:8443?upmbps=25&downmbps=90#HY1
        """
        let parsed = try ShareLinkParser.parseDetailed(Data(text.utf8))
        XCTAssertEqual(parsed.received, 3)
        XCTAssertEqual(parsed.profiles.count, 2)
        XCTAssertEqual(parsed.skipped.count, 1)
        XCTAssertFalse(parsed.skipped[0].reason.contains("private-password"))
    }
}

private final class MockSubscriptionURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "subscription.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let agent = request.value(forHTTPHeaderField: "User-Agent") ?? ""
        MockSubscriptionURLProtocol.lock.lock()
        MockSubscriptionURLProtocol.requests.append(request)
        MockSubscriptionURLProtocol.lock.unlock()

        let vless1 = "vless://123e4567-e89b-12d3-a456-426614174000@one.example.com:443#One"
        let vless2 = "vless://123e4567-e89b-12d3-a456-426614174000@two.example.com:443#Two"
        let hysteria = "hysteria://secret@hy.example.com:443?upmbps=30&downmbps=100#HY1"
        let body: String
        let status: Int
        switch agent {
        case "Karing": body = vless1; status = 200
        case "Happ/3.3.6": body = [vless1,vless2,hysteria].joined(separator: "\n"); status = 200
        case "sing-box/1.13.14": body = "invalid-data"; status = 200
        default: body = vless1; status = 200
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["subscription-userinfo": "upload=5; download=10; total=100"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class MultiUserAgentSubscriptionTests: XCTestCase {
    func testChoosesLargestCompatibleResponseAndRetainsHWID() throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockSubscriptionURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        MockSubscriptionURLProtocol.lock.lock()
        MockSubscriptionURLProtocol.requests = []
        MockSubscriptionURLProtocol.lock.unlock()

        let expectation = expectation(description: "Import from all User-Agents")
        let service = SubscriptionService(session: session, hardwareID: "stable-device")
        service.loadWithMetadata(from: URL(string: "https://subscription.test/safe-path")!) { result in
            switch result {
            case .failure(let error): XCTFail("Unexpected error: \(error)")
            case .success(let value):
                XCTAssertEqual(value.profiles.count, 3)
                XCTAssertEqual(value.diagnostics?.userAgent, "Happ/3.3.6")
                XCTAssertEqual(value.diagnostics?.imported, 3)
                XCTAssertEqual(value.metadata?.usedBytes, 15)
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 15)
        MockSubscriptionURLProtocol.lock.lock()
        let requests = MockSubscriptionURLProtocol.requests
        MockSubscriptionURLProtocol.lock.unlock()
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(Set(requests.compactMap { $0.value(forHTTPHeaderField: "User-Agent") }),
                       Set(["Karing","Happ/3.3.6","sing-box/1.13.14","v2rayNG/2.2.6"]))
        XCTAssertTrue(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "X-Hwid") == "stable-device"
        })
    }
}
