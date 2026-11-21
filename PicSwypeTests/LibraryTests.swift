import AVFoundation
import CryptoKit
import XCTest
import UIKit
import Photos
import ImageIO
@testable import PicSwype

private final class RepeatingImmichBatch: URLProtocol {
    static let preview = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { _ in }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!
        let isSearch = url.path.hasSuffix("/search/random")
        let batch = #"[$A,$A,$B,$A,$B]"#
            .replacingOccurrences(of: "$A", with: #"{"id":"first","type":"IMAGE"}"#)
            .replacingOccurrences(of: "$B", with: #"{"id":"second","type":"IMAGE"}"#)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
            headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        var payload = isSearch ? Data(batch.utf8) : Self.preview
        if url.path.hasSuffix("/search/metadata") {
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while case let n = stream.read(&buffer, maxLength: buffer.count), n > 0 { body.append(buffer, count: n) }
            }
            let page = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["page"] as? Int ?? 1
            payload = Data((page == 1
                ? #"{"assets":{"items":[{"id":"first","type":"IMAGE"},{"id":"second","type":"IMAGE"}],"nextPage":"2"}}"#
                : #"{"assets":{"items":[{"id":"third","type":"IMAGE"}],"nextPage":null}}"#).utf8)
        }
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor final class LibraryTests: XCTestCase {
    func testImmichRepeatedBatchesAfterKeepUndoQueueAndRestart() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RepeatingImmichBatch.self]
        let model = Library(.immich, session: URLSession(configuration: config))
        model.server = "https://" + UUID().uuidString + ".example"
        defer {
            _ = DeletionQueue.shared.removeUnstarted(id: "second", library: model)
            for suffix in [".seen", ".marked", ".kept", ".trashed"] {
                UserDefaults.standard.removeObject(forKey: model.progressKey + suffix)
            }
            SeenStore.remove(model.progressKey)
        }
        await model.reload()
        XCTAssertEqual(model.assets.map(\.id), ["first", "second"])
        await model.act(delete: false)
        await model.goBack()
        XCTAssertEqual(model.assets.first?.id, "first")
        XCTAssertEqual(model.kept, 0)
        await model.act(delete: false)
        await model.act(delete: true)
        XCTAssertEqual(model.marked, ["second"])
        // Random batches only repeat reviewed items; the paged sweep still finds the last one.
        await model.reload()
        XCTAssertNil(model.error)
        XCTAssertEqual(model.assets.map(\.id), ["third"])
        await model.act(delete: false)
        XCTAssertNil(model.error)
        XCTAssertNil(model.picture)
        XCTAssertTrue(model.assets.isEmpty)
        await model.reload(reset: true)
        XCTAssertEqual(model.assets.map(\.id), ["first"])
    }

    func testAuthorizedApplePhotoPreviewAndMarkUndo() async throws {
        #if targetEnvironment(simulator)
        try XCTSkipUnless(PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized,
                          "Grant the test simulator Photos access and add a sample image.")
        let keys = ["seen", "marked", "kept", "trashed"].map { "PicSwype.apple." + $0 }
        let defaults = UserDefaults.standard
        let original = keys.map { defaults.object(forKey: $0) }
        let reviewed = SeenStore.load("PicSwype.apple")
        defer {
            for (key, value) in zip(keys, original) { defaults.set(value, forKey: key) }
            SeenStore.write(reviewed, "PicSwype.apple")
        }
        keys.forEach { defaults.removeObject(forKey: $0) }
        SeenStore.remove("PicSwype.apple")
        let model = Library(.apple)
        await model.connect()
        XCTAssertTrue(model.connected)
        let id = try XCTUnwrap(model.assets.first?.id)
        XCTAssertNotNil(model.picture)
        await model.act(delete: true)
        XCTAssertEqual(model.marked, [id])
        XCTAssertEqual(PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).count, 1)
        await model.goBack()
        XCTAssertEqual(model.assets.first?.id, id)
        XCTAssertTrue(model.marked.isEmpty)
        #endif
    }

    func testSeenStoreAppendsRewritesAndMigrates() throws {
        let key = "test.seen." + UUID().uuidString
        defer { SeenStore.remove(key); UserDefaults.standard.removeObject(forKey: key + ".seen") }
        UserDefaults.standard.set(["a", "line\nbreak"], forKey: key + ".seen")
        XCTAssertEqual(SeenStore.load(key), ["a", "line\nbreak"])
        XCTAssertNil(UserDefaults.standard.stringArray(forKey: key + ".seen"))
        SeenStore.append("b", key)
        XCTAssertEqual(SeenStore.load(key), ["a", "line\nbreak", "b"])
        SeenStore.write(["b"], key)
        XCTAssertEqual(SeenStore.load(key), ["b"])
    }

    func testUnreadablePhotoIsSkippedNotMarkedReviewed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not an image".utf8).write(to: root.appendingPathComponent("broken.jpg"))
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        try XCTUnwrap(photo.pngData()).write(to: root.appendingPathComponent("good.png"))
        let model = Library(.synology)
        model.folder = NASFolder(root)
        defer {
            for suffix in [".marked", ".kept", ".trashed"] { UserDefaults.standard.removeObject(forKey: model.progressKey + suffix) }
            SeenStore.remove(model.progressKey)
        }
        for _ in 0..<4 {
            await model.connect()
            XCTAssertNil(model.error)
            XCTAssertEqual(model.assets.first?.originalFileName, "good.png")
            XCTAssertNotNil(model.picture)
        }
        XCTAssertTrue(SeenStore.load(model.progressKey).isEmpty)
    }

    func testExifCaptureDateParsing() {
        let exif: [CFString: Any] = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:06 07:08:09",
                                                                      kCGImagePropertyExifOffsetTimeOriginal: "-05:00"] as [CFString: Any]]
        let exact = LinkedPhoto.takenDate(exif)
        XCTAssertEqual(exact?.0, Date(timeIntervalSince1970: 1_714_997_289))
        XCTAssertEqual(exact?.1, true)
        let loose = LinkedPhoto.takenDate([kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:06 07:08:09"] as [CFString: Any]])
        XCTAssertEqual(loose?.0, Date(timeIntervalSince1970: 1_714_979_289))
        XCTAssertEqual(loose?.1, false)
    }

    func testFolderMoviePlaybackQueueUndoAndExactFingerprint() async throws {
        let original = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ReviewClip", withExtension: "mp4"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("renamed.mp4")
        try FileManager.default.copyItem(at: original, to: file)
        let model = Library(.synology)
        model.folder = NASFolder(root)
        await model.connect()
        let video = try XCTUnwrap(model.assets.first)
        XCTAssertTrue(video.isVideo)
        XCTAssertNotNil(model.picture)
        let playable = try await AVURLAsset(url: file).load(.isPlayable)
        XCTAssertTrue(playable)
        await model.act(delete: true)
        let entry = try XCTUnwrap(DeletionQueue.shared.entries.first { $0.origin.id == video.id })
        XCTAssertEqual(entry.isVideo, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        await model.goBack()
        XCTAssertTrue(model.assets.first?.isVideo == true)
        XCTAssertTrue(model.marked.isEmpty)
        let movie = try DownloadedMovie(download: file, filename: "renamed.mp4")
        let hash = try await movie.fingerprint()
        XCTAssertTrue(hash.isVideo)
        XCTAssertEqual(hash.digest, Data(SHA256.hash(data: try Data(contentsOf: original))))
    }

    func testFolderReviewAndUndoLeaveOriginalsIntact() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24)).image { _ in UIColor.red.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 32, height: 24)) }
        for name in ["a.png", "b.png"] { try XCTUnwrap(image.pngData()).write(to: root.appendingPathComponent(name)) }
        let model = Library(.synology)
        model.folder = NASFolder(root)
        await model.connect()
        XCTAssertTrue(model.connected)
        XCTAssertNotNil(model.picture)
        let first = try XCTUnwrap(model.assets.first?.id)
        await model.act(delete: true)
        XCTAssertEqual(model.marked, [first])
        XCTAssertEqual(model.trashed, 0)
        await model.goBack()
        XCTAssertTrue(model.marked.isEmpty)
        XCTAssertEqual(model.assets.first?.id, first)
        await model.act(delete: false)
        XCTAssertEqual(model.kept, 1)
        await model.act(delete: true)
        let reopened = Library(.synology)
        reopened.folder = NASFolder(root)
        await reopened.connect()
        XCTAssertEqual(reopened.marked, model.marked)
        XCTAssertEqual(reopened.kept, 1)
        XCTAssertTrue(reopened.assets.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 2)
        let queued = try XCTUnwrap(reopened.marked.first)
        let added = root.appendingPathComponent("new.png")
        try XCTUnwrap(image.pngData()).write(to: added)
        await reopened.connect()
        XCTAssertEqual(reopened.assets.map(\.id), [added.path])
        await reopened.act(delete: false)
        await reopened.reload(reset: true)
        XCTAssertEqual(Set(reopened.assets.map(\.id)), [first, added.path])
        XCTAssertEqual(reopened.marked, [queued])
        reopened.unmark(queued)
        await reopened.reload()
        XCTAssertNotNil(reopened.picture)
    }
}
