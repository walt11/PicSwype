import XCTest
@testable import PicSwype

@MainActor final class DeletionQueueTests: XCTestCase {
    func testMatchingRunsOnAddAndResumesPersistedEntriesWithoutOpeningQueue() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let nas = Library(.synology)
        nas.connected = true
        let libraries = [nas, Library(.apple), Library(.immich)]
        let saved = DeletionQueue(defaults: defaults)
        saved.add(Asset(id: "persisted", type: "IMAGE"), from: nas)
        let queue = DeletionQueue(defaults: defaults)
        queue.configureMatching(libraries: libraries, linkedPair: "")
        queue.add(Asset(id: "new", type: "IMAGE"), from: nas)
        for _ in 0..<100 where queue.working {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(queue.working)
        XCTAssertTrue(queue.matchFailures.isEmpty)
        let restored = DeletionQueue(defaults: defaults)
        XCTAssertEqual(restored.entries.count, 2)
        for row in restored.entries {
            XCTAssertEqual(row.found, [row.origin])
            XCTAssertNil(row.remaining)
        }
    }

    func testKeepRemovesRowOnceAndPersistsTheDecision() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = Library(.synology)
        model.folder = NASFolder(FileManager.default.temporaryDirectory.appendingPathComponent(suite))
        defer {
            for suffix in [".marked", ".seen", ".kept", ".trashed"] {
                UserDefaults.standard.removeObject(forKey: model.progressKey + suffix)
            }
        }
        model.connected = true
        let queue = DeletionQueue(defaults: defaults)
        queue.add(Asset(id: "keep-me", type: "IMAGE"), from: model)
        let row = try XCTUnwrap(queue.entries.first)
        queue.keep(row, libraries: [model])
        queue.keep(row, libraries: [model])
        XCTAssertTrue(DeletionQueue(defaults: defaults).entries.isEmpty)
        XCTAssertEqual(model.kept, 1)
        XCTAssertEqual(model.trashed, 0)
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: model.progressKey + ".seen"), ["keep-me"])
    }

    func testQueuedThumbnailAvailableAfterReopeningWithoutLibrary() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = Library(.immich)
        let asset = Asset(id: "thumbnail-fixture", type: "IMAGE", originalFileName: "test.jpg")
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        let queue = DeletionQueue(defaults: defaults)
        queue.add(asset, from: model, preview: photo)
        let reopened = DeletionQueue(defaults: defaults)
        let entry = try XCTUnwrap(reopened.entries.first)
        let thumbnail = await reopened.thumbnail(entry, libraries: [])
        XCTAssertNotNil(thumbnail)
        XCTAssertLessThanOrEqual(try XCTUnwrap(thumbnail).size.width, 160)
        XCTAssertTrue(reopened.removeUnstarted(id: asset.id, library: model))
        let removed = await reopened.thumbnail(entry, libraries: [])
        XCTAssertNil(removed)
    }

    func testOnlySelectedDestinationIsTrashedAndChoicesPersist() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DSMFixture.self]
        let remote = try await SynologyPhotos(address: "https://queue-test.example", username: suite, configuration: configuration)
        remote.resume("fixture")
        let nas = Library(.synology, remote: remote)
        await nas.connect()
        let nasCopy = QueueTarget(source: nas.source.rawValue, scope: nas.queueScope, id: "1")
        let apple = Library(.apple)
        let appleCopy = QueueTarget(source: apple.source.rawValue, scope: apple.queueScope, id: "simulated-device-copy")
        let all: Set<QueueTarget> = [nasCopy, appleCopy]
        let entry = DeletionEntry(id: UUID(), origin: nasCopy, name: "sample.jpg", live: false,
                                  fileDate: nil,
                                  found: all, preparedFor: "test-pair", matchVersion: 2)
        defaults.set(try JSONEncoder().encode([entry]), forKey: "PicSwype.deletionQueue.v1")
        let queue = DeletionQueue(defaults: defaults)
        XCTAssertEqual(all.subtracting(queue.entries[0].excluded ?? []), all)
        queue.setSelected(false, source: apple.source.rawValue, entryID: entry.id)
        let reopened = DeletionQueue(defaults: defaults)
        XCTAssertEqual(reopened.entries[0].excluded, [appleCopy])
        XCTAssertEqual(nas.trashed, 0)
        await reopened.deleteAll(libraries: [nas, apple, Library(.immich)], linkedPair: "test-pair")
        XCTAssertNil(reopened.error)
        XCTAssertTrue(reopened.entries.isEmpty)
        XCTAssertEqual(nas.trashed, 1)
        XCTAssertEqual(apple.trashed, 0)
    }
}
