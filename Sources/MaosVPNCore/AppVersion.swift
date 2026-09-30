import Foundation

public struct AppVersion: Comparable, CustomStringConvertible {
    public let components: [Int]

    public init?(_ rawValue: String) {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("v") {
            value.removeFirst()
        }
        value = String(value.split(separator: "-", maxSplits: 1).first ?? "")

        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty else { return nil }

        var parsed: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, let number = Int(piece), number >= 0 else { return nil }
            parsed.append(number)
        }
        components = parsed
    }

    public var description: String {
        components.map(String.init).joined(separator: ".")
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}
