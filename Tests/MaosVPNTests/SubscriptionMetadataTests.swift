import Foundation
import XCTest
@testable import MaosVPNCore

final class SubscriptionMetadataTests: XCTestCase {
    private let sampleURL = URL(string: "https://example.com/sub/secret-token")!

    func testHeadersIncludeExpiryTrafficAndProviderLinks() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: sampleURL, statusCode: 200, httpVersion: "HTTP/2",
            headerFields: [
                "Subscription-Userinfo": "upload=1024; download=2048; total=10240; expire=1790951622",
                "Profile-Web-Page-Url": "https://example.com/account",
                "Support-Url": "https://t.me/support",
                "Profile-Title": "My VPN"
            ]
        ))
        let metadata = try XCTUnwrap(SubscriptionMetadata.parse(response: response, body: Data()))
        XCTAssertEqual(metadata.usedBytes, 3072)
        XCTAssertEqual(metadata.totalBytes, 10240)
        XCTAssertEqual(metadata.expiresAt?.timeIntervalSince1970, 1790951622)
        XCTAssertEqual(metadata.websiteURL?.absoluteString, "https://example.com/account")
        XCTAssertEqual(metadata.supportURL?.absoluteString, "https://t.me/support")
        XCTAssertEqual(metadata.title, "My VPN")
    }

    func testBodyCommentHeadersAndHeaderOverride() throws {
        let body = Data("""
        #profile-title: From body
        #subscription-userinfo: upload=9; download=8; total=0; expire=0
        #support-url: https://t.me/hello
        vless://123e4567-e89b-12d3-a456-426614174000@example.com:443#Node
        """.utf8)
        let response = try XCTUnwrap(HTTPURLResponse(url: sampleURL, statusCode: 200,
            httpVersion: nil, headerFields: ["profile-title": "From header"]))
        let metadata = try XCTUnwrap(SubscriptionMetadata.parse(response: response, body: body))
        XCTAssertEqual(metadata.title, "From header")
        XCTAssertEqual(metadata.usedBytes, 17)
        XCTAssertNil(metadata.expiresAt)
        XCTAssertEqual(metadata.supportURL?.host, "t.me")
    }

    func testIgnoreMissingInvalidOrInsecureMetadata() {
        let body = Data("""
        #subscription-userinfo: upload=-2; download=nope; expire=invalid
        #profile-web-page-url: javascript:alert(1)
        #support-url: http://example.com
        vless://abc@example.com:443
        """.utf8)
        XCTAssertNil(SubscriptionMetadata.parse(response: nil, body: body))
    }

    func testCodableMetadataRoundTrip() throws {
        let response = try XCTUnwrap(HTTPURLResponse(url: sampleURL, statusCode: 200,
            httpVersion: nil, headerFields: ["subscription-userinfo": "expire=1790951622"]))
        let metadata = try XCTUnwrap(SubscriptionMetadata.parse(response: response, body: Data()))
        let decoded = try JSONDecoder().decode(SubscriptionMetadata.self, from: JSONEncoder().encode(metadata))
        XCTAssertEqual(decoded, metadata)
    }

    func testBase64CommentMetadata() throws {
        let body = """
        #profile-title: Base64 VPN
        #subscription-userinfo: expire=1790951622
        vless://test
        """
        let metadata = try XCTUnwrap(SubscriptionMetadata.parse(response: nil,
            body: Data(Data(body.utf8).base64EncodedString().utf8)))
        XCTAssertEqual(metadata.title, "Base64 VPN")
        XCTAssertNotNil(metadata.expiresAt)
    }
}
