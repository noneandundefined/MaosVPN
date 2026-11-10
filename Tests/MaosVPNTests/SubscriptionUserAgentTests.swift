import Foundation
import XCTest
@testable import MaosVPNCore

private final class SubscriptionMockProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, [String: String], Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (status, headers, body) = handler(request)
        guard let response = HTTPURLResponse(url: url, statusCode: status,
                                             httpVersion: "HTTP/1.1", headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class SubscriptionUserAgentTests: XCTestCase {
    private let subscriptionURL = URL(string: "https://example.com/sub/private-token")!
    private let uuid = "123e4567-e89b-12d3-a456-426614174000"

    override func tearDown() {
        SubscriptionMockProtocol.handler = nil
        super.tearDown()
    }

    private func service() -> SubscriptionService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubscriptionMockProtocol.self]
        return SubscriptionService(
            session: URLSession(configuration: configuration),
            hardwareID: "fixed-hwid"
        )
    }

    private func links(_ names: [String]) -> Data {
        Data(names.map { host in
            "vless://\(uuid)@\(host):443?encryption=none&security=tls#\(host)"
        }.joined(separator: "\n").utf8)
    }

    private func json(_ names: [String]) -> Data {
        let nodes: [[String: Any]] = names.map { host in
            ["type": "vless", "tag": host, "server": host,
             "server_port": 443, "uuid": uuid]
        }
        return (try? JSONSerialization.data(withJSONObject: ["outbounds": nodes])) ?? Data()
    }

    func testChoosesLargestCompatibleResponseAndKeepsHardwareIdentity() {
        let lock = NSLock()
        var requests: [String] = []
        var hwids: [String] = []
        SubscriptionMockProtocol.handler = { [self] request in
            let agent = request.value(forHTTPHeaderField: "User-Agent") ?? ""
            lock.lock()
            requests.append(agent)
            hwids.append(request.value(forHTTPHeaderField: "X-Hwid") ?? "")
            lock.unlock()
            switch agent {
            case "Karing":
                return (200, [:], json(["one.example.com", "two.example.com"]))
            case "Happ/3.3.6":
                let text = String(data: links(["one.example.com", "two.example.com", "three.example.com"]),
                                  encoding: .utf8)! + "\nhysteria://unsupported.example"
                return (200, ["Profile-Title": "Happ response"], Data(text.utf8))
            case "v2rayNG/2.2.6":
                return (200, [:], links(["one.example.com"]))
            default:
                return (200, [:], json(["one.example.com", "two.example.com"]))
            }
        }

        let completed = expectation(description: "Choose the largest compatible result")
        service().loadWithMetadata(from: subscriptionURL) { result in
            defer { completed.fulfill() }
            guard case .success(let response) = result else {
                XCTFail("Expected a valid response: \(result)")
                return
            }
            XCTAssertEqual(response.profiles.count, 3)
            XCTAssertEqual(response.userAgent, "Happ/3.3.6")
            XCTAssertEqual(response.metadata?.title, "Happ response")
            XCTAssertEqual(response.comparisons.map { $0.compatibleCount }, [2, 3, 1, 2])
        }
        wait(for: [completed], timeout: 10)
        lock.lock()
        let actualRequests = requests
        let actualHWIDs = hwids
        lock.unlock()
        XCTAssertEqual(actualRequests, SubscriptionService.candidateUserAgents)
        XCTAssertEqual(actualHWIDs, Array(repeating: "fixed-hwid", count: 4))
    }

    func testRateLimitStopsFurtherRequestsWithoutDiscardingSuccess() {
        let lock = NSLock()
        var agents: [String] = []
        SubscriptionMockProtocol.handler = { [self] request in
            let agent = request.value(forHTTPHeaderField: "User-Agent") ?? ""
            lock.lock()
            agents.append(agent)
            lock.unlock()
            if agent == "Karing" {
                return (200, [:], links(["first.example.com"]))
            }
            return (429, [:], Data())
        }
        let done = expectation(description: "Respect rate limiting")
        service().loadWithMetadata(from: subscriptionURL) { result in
            defer { done.fulfill() }
            guard case .success(let response) = result else { XCTFail("Expected fallback"); return }
            XCTAssertEqual(response.userAgent, "Karing")
            XCTAssertEqual(response.profiles.count, 1)
        }
        wait(for: [done], timeout: 10)
        lock.lock()
        let actual = agents
        lock.unlock()
        XCTAssertEqual(actual, ["Karing", "Happ/3.3.6"])
    }

    func testDeviceRejectionStopsWithoutTryingAlternativeIdentity() {
        let lock = NSLock()
        var attempts = 0
        SubscriptionMockProtocol.handler = { request in
            lock.lock()
            attempts += 1
            lock.unlock()
            return (200, ["X-Hwid-Not-Supported": "true"], Data("vless://fake".utf8))
        }
        let done = expectation(description: "Do not bypass rejected device")
        service().loadWithMetadata(from: subscriptionURL) { result in
            if case .success = result { XCTFail("Access rejection should not succeed") }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        lock.lock()
        let count = attempts
        lock.unlock()
        XCTAssertEqual(count, 1)
    }

    func testFakeDeviceLimitProfileStopsWithoutTryingOtherClients() {
        let lock = NSLock()
        var attempts = 0
        SubscriptionMockProtocol.handler = { request in
            lock.lock()
            attempts += 1
            lock.unlock()
            return (200, [:], Data(
                "vless://123e4567-e89b-12d3-a456-426614174000@0.0.0.0:1#Update%20App".utf8
            ))
        }
        let done = expectation(description: "No bypass of placeholder-based device limits")
        service().loadWithMetadata(from: subscriptionURL) { result in
            if case .success = result { XCTFail("Expected device rejection") }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        lock.lock()
        let count = attempts
        lock.unlock()
        XCTAssertEqual(count, 1)
    }

    func testMalformedClientResponseFallsBackToSupportedFormat() {
        SubscriptionMockProtocol.handler = { [self] request in
            let agent = request.value(forHTTPHeaderField: "User-Agent") ?? ""
            return agent == "Happ/3.3.6"
                ? (200, [:], links(["valid.example.com"]))
                : (200, [:], Data("<html>Unsupported format</html>".utf8))
        }
        let done = expectation(description: "Skip unusable client formats")
        service().loadWithMetadata(from: subscriptionURL) { result in
            if case .success(let response) = result {
                XCTAssertEqual(response.userAgent, "Happ/3.3.6")
                XCTAssertEqual(response.profiles.count, 1)
            } else { XCTFail("Expected valid Happ fallback") }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
    }
}
