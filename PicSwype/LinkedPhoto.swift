import CryptoKit
import Foundation
import ImageIO

enum LibraryLink: String, CaseIterable {
    case immichApple, synologyApple, immichSynology, all

    init?(saved: String) {
        guard !saved.isEmpty else { return nil }
        // Earlier releases stored the three-library account digest without a prefix.
        self = Self.allCases.first { saved.hasPrefix($0.rawValue + ":") } ?? .all
    }

    var sources: Set<PhotoSource> {
        switch self {
        case .immichApple: return [.immich, .apple]
        case .synologyApple: return [.synology, .apple]
        case .immichSynology: return [.immich, .synology]
        case .all: return [.immich, .synology, .apple]
        }
    }

    var title: String {
        switch self {
        case .immichApple: return "Immich + Apple Photos"
        case .synologyApple: return "Synology + Apple Photos"
        case .immichSynology: return "Immich + Synology"
        case .all: return "All three libraries"
        }
    }

    @MainActor func identity(immich: Library, nas: Library) -> String? {
        if sources.contains(.immich) {
            guard immich.connected, immich.authenticatedImmich?.server == immich.server,
                  immich.authenticatedImmich?.key == immich.key else { return nil }
        }
        if sources.contains(.synology) {
            guard nas.connected, nas.remote != nil else { return nil }
        }
        if self == .all { return LinkedPhoto.identity(immich: immich, nas: nas) }
        let accounts = [immich, nas].filter { sources.contains($0.source) }.map(\.queueScope)
        return rawValue + ":" + LinkedPhoto.accountDigest(accounts)
    }
}

struct LinkedPhoto: Codable, Equatable {
    let pair: String
    let immichID: String
    let nasID: String
    let digest: Data

    @MainActor static func identity(immich: Library, nas: Library) -> String? {
        guard immich.connected, nas.connected, immich.authenticatedImmich?.server == immich.server,
              immich.authenticatedImmich?.key == immich.key, let remote = nas.remote else { return nil }
        return accountDigest([immich.server, immich.key, remote.address, remote.username])
    }

    static func accountDigest(_ parts: [String]) -> String {
        guard let encoded = try? JSONEncoder().encode(parts) else { return "" }
        return Data(SHA256.hash(data: encoded)).base64EncodedString()
    }

    struct Dimensions: Hashable, Codable {
        let short: Int
        let long: Int

        init?(_ width: Int, _ height: Int) {
            guard width > 0, height > 0 else { return nil }
            short = min(width, height)
            long = max(width, height)
        }
    }

    struct Fingerprint {
        let digest: Data
        let searchChecksum: String
        let count: Int
        var dimensions: Dimensions? = nil
        var isVideo = false
        /// When the photo was taken, used only to narrow which Apple originals get hashed.
        var taken: Date? = nil
        /// True when `taken` includes its time zone; otherwise it can be off by up to a day.
        var takenIsExact = false
    }

    /// Reads EXIF DateTimeOriginal. Without OffsetTimeOriginal the wall-clock time is read as UTC and marked inexact.
    static func takenDate(_ properties: [CFString: Any]?) -> (Date, Bool)? {
        guard let exif = properties?[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        if let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
            if let date = formatter.date(from: text + offset) { return (date, true) }
        }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text).map { ($0, false) }
    }

    static func fingerprint(_ bytes: Data) async throws -> Fingerprint {
        try Task.checkCancellation()
        guard !bytes.isEmpty, let image = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceGetCount(image) > 0 else { throw Failure(message: "Could not verify the original image.") }
        let properties = CGImageSourceCopyPropertiesAtIndex(image, CGImageSourceGetPrimaryImageIndex(image), nil) as? [CFString: Any]
        let dimensions = Dimensions(properties?[kCGImagePropertyPixelWidth] as? Int ?? 0,
                                    properties?[kCGImagePropertyPixelHeight] as? Int ?? 0)
        let taken = takenDate(properties)
        return Fingerprint(digest: Data(SHA256.hash(data: bytes)),
            searchChecksum: Data(Insecure.SHA1.hash(data: bytes)).base64EncodedString(), count: bytes.count, dimensions: dimensions,
            taken: taken?.0, takenIsExact: taken?.1 ?? false)
    }

    @MainActor static func immichOriginal(_ id: String, _ client: Library) async throws -> Fingerprint {
        guard UUID(uuidString: id) != nil else { throw Failure(message: "Invalid photo identifier.") }
        let data = try await client.request("assets/\(id)/original")
        do { return try await fingerprint(data) }
        catch is Failure { throw Failure(message: "Immich returned an unreadable original for the matching candidate.") }
    }
}
