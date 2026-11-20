import XCTest
import UIKit
import Photos
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
        client?.urlProtocol(self, didLoad: isSearch ? Data(batch.utf8) : Self.preview)
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
        await model.reload()
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
        defer { for (key, value) in zip(keys, original) { defaults.set(value, forKey: key) } }
        keys.forEach { defaults.removeObject(forKey: $0) }
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
