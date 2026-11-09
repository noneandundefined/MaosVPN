import Foundation

/// Optional subscription information provided by compatible VPN panels.
/// None of these fields are inferred from the VPN server profiles.
public struct SubscriptionMetadata: Codable, Equatable {
    public let title: String?
    public let expiresAt: Date?
    public let uploadBytes: Int64?
    public let downloadBytes: Int64?
    public let totalBytes: Int64?
    public let websiteURL: URL?
    public let supportURL: URL?

    public var usedBytes: Int64? {
        guard uploadBytes != nil || downloadBytes != nil else { return nil }
        let upload = uploadBytes ?? 0
        let download = downloadBytes ?? 0
        let (total, overflow) = upload.addingReportingOverflow(download)
        return overflow ? Int64.max : total
    }

    public static func parse(response: HTTPURLResponse?, body: Data) -> SubscriptionMetadata? {
        var bodyFields: [String: String] = [:]
        var text = String(data: body.prefix(32_768), encoding: .utf8) ?? ""
        // Several providers publish comment metadata inside Base64 subscriptions.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://") && !trimmed.hasPrefix("{") && !trimmed.hasPrefix("["),
           let decoded = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters),
           let decodedText = String(data: decoded.prefix(32_768), encoding: .utf8) {
            text = decodedText
        }
        // Read comment directives at the beginning of the subscription.
        for line in text.components(separatedBy: .newlines).prefix(32) {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedLine.hasPrefix("#") else { break }
            let comment = String(trimmedLine.drop(while: { $0 == "#" }))
            guard let separator = comment.firstIndex(of: ":") else { continue }
            let key = comment[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = comment[comment.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { continue }
            bodyFields[key] = value
        }
        func field(_ name: String) -> String? {
            let result = response?.value(forHTTPHeaderField: name) ?? bodyFields[name]
            return result?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let userInfo = field("subscription-userinfo") ?? ""
        var values: [String: String] = [:]
        for component in userInfo.split(separator: ";") {
            let parts = component.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            values[String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] =
                String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func bytes(_ name: String) -> Int64? {
            guard let value = values[name], let number = Int64(value), number >= 0 else { return nil }
            return number
        }
        func safeURL(_ value: String?) -> URL? {
            guard let value = value, value.count < 2048,
                  let url = URL(string: value),
                  url.scheme?.lowercased() == "https", url.host != nil,
                  url.user == nil, url.password == nil else { return nil }
            return url
        }
        var title: String? = field("profile-title")
        if let value = title, value.lowercased().hasPrefix("base64:"),
           let data = Data(base64Encoded: String(value.dropFirst(7))),
           let decoded = String(data: data, encoding: .utf8) {
            title = decoded
        }
        title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if title?.isEmpty == true { title = nil }
        let expiresAt = values["expire"].flatMap { Int64($0) }
            .flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
        let metadata = SubscriptionMetadata(
            title: title,
            expiresAt: expiresAt,
            uploadBytes: bytes("upload"),
            downloadBytes: bytes("download"),
            totalBytes: bytes("total"),
            websiteURL: safeURL(field("profile-web-page-url")),
            supportURL: safeURL(field("support-url"))
        )
        guard metadata.title != nil || metadata.expiresAt != nil ||
              metadata.uploadBytes != nil || metadata.downloadBytes != nil ||
              metadata.totalBytes != nil || metadata.websiteURL != nil ||
              metadata.supportURL != nil else { return nil }
        return metadata
    }
}

public struct SubscriptionResponse {
    public let profiles: [VPNProfile]
    public let metadata: SubscriptionMetadata?

    public init(profiles: [VPNProfile], metadata: SubscriptionMetadata?) {
        self.profiles = profiles
        self.metadata = metadata
    }
}
