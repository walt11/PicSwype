import CryptoKit
import Foundation
import ImageIO

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

    struct Fingerprint {
        let digest: Data
        let searchChecksum: String
        let count: Int
    }

    static func fingerprint(_ bytes: Data) async throws -> Fingerprint {
        try Task.checkCancellation()
        guard !bytes.isEmpty, let image = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceGetCount(image) > 0 else { throw Failure(message: "Could not verify the original image.") }
        return Fingerprint(digest: Data(SHA256.hash(data: bytes)),
            searchChecksum: Data(Insecure.SHA1.hash(data: bytes)).base64EncodedString(), count: bytes.count)
    }

    @MainActor func verifyNAS(_ client: SynologyPhotos) async throws {
        let original = try await Self.fingerprint(client.original(nasID))
        guard original.digest == digest else { throw Failure(message: "The Synology photo changed. Review it again.") }
    }

    @MainActor func verifyImmich(_ client: Library) async throws {
        let original = try await Self.immichOriginal(immichID, client)
        guard original.digest == digest else { throw Failure(message: "The Immich photo changed. Review it again.") }
    }

    @MainActor static func immichOriginal(_ id: String, _ client: Library) async throws -> Fingerprint {
        guard UUID(uuidString: id) != nil else { throw Failure(message: "Invalid photo identifier.") }
        let data = try await client.request("assets/\(id)/original")
        do { return try await fingerprint(data) }
        catch is Failure { throw Failure(message: "Immich returned an unreadable original for the matching candidate.") }
    }

    @MainActor static func find(asset: Asset, source: PhotoSource, pair: String, immich: Library, nas: SynologyPhotos) async throws -> Self? {
        guard asset.type == "IMAGE", asset.livePhotoVideoId == nil else { return nil }
        if source == .immich {
            let current = try await immichOriginal(asset.id, immich)
            var result: Self?
            for id in nas.possibleCopies(byteCount: current.count, filename: asset.originalFileName) {
                try Task.checkCancellation()
                let candidate = try await fingerprint(nas.original(id))
                if candidate.digest == current.digest {
                    guard result == nil else { return nil }
                    result = Self(pair: pair, immichID: asset.id, nasID: id, digest: current.digest)
                }
            }
            return result
        }
        struct Results: Decodable {
            let assets: Page
            struct Page: Decodable { let items: [Asset]; let nextPage: String? }
        }
        let current = try await fingerprint(nas.original(asset.id))
        let data = try await immich.request("search/metadata", method: "POST", body: ["checksum": current.searchChecksum, "size": 2])
        let page = try JSONDecoder().decode(Results.self, from: data).assets
        guard page.nextPage == nil, page.items.count == 1, let other = page.items.first,
              other.type == "IMAGE", other.isTrashed != true, other.livePhotoVideoId == nil else { return nil }
        let candidate = try await immichOriginal(other.id, immich)
        guard candidate.digest == current.digest else { return nil }
        return Self(pair: pair, immichID: other.id, nasID: asset.id, digest: current.digest)
    }
}
