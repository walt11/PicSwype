import XCTest
import UIKit
import Photos
@testable import PicSwype

private final class LinkFixture: URLProtocol {
    static let id = "006EE3F7-5EF4-424C-8F98-F66209F76C1A"
    static var video = false
    static let poster = UIGraphicsImageRenderer(size: CGSize(width: 5, height: 5)).pngData { context in
        UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 5, height: 5))
    }
    static var original = poster
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buf = [UInt8](repeating: 0, count: 4096)
            while true { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; body.append(contentsOf: buf.prefix(n)) }
        }
        let fields = URLComponents(string: "?" + String(decoding: body, as: UTF8.self))?.queryItems ?? []
        func value(_ key: String) -> String? { fields.first { $0.name == key }?.value }
        let type = Self.video ? "VIDEO" : "IMAGE"
        var data: Data
        if url.path.hasSuffix("/random") {
            data = Data(#"[{"id":"\#(Self.id)","type":"\#(type)"}]"#.utf8)
        } else if url.path.hasSuffix("/thumbnail") || value("api") == "SYNO.Foto.Thumbnail" {
            data = Self.video ? Self.poster : Self.original
        } else if url.path.hasSuffix("/original") {
            data = Self.original
        } else if url.path.hasSuffix("/metadata") {
            if url.host == "heic-test.example" {
                let search = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
                let items = search?["originalFileName"] as? String == "IMG_0500.HEIC"
                    ? #"[{"id":"\#(Self.id)","type":"IMAGE","livePhotoVideoId":"paired-video"}]"# : "[]"
                data = Data(#"{"assets":{"items":\#(items)}}"#.utf8)
            } else {
                data = Data(#"{"assets":{"items":[{"id":"\#(Self.id)","type":"\#(type)"}]}}"#.utf8)
            }
        } else if url.path.hasSuffix("query.cgi") {
            data = Data(#"{"success":true,"data":{"SYNO.Foto.Browse.Item":{"path":"entry.cgi","minVersion":1,"maxVersion":2},"SYNO.Foto.Thumbnail":{"path":"entry.cgi","minVersion":1,"maxVersion":1},"SYNO.Foto.Download":{"path":"entry.cgi","minVersion":1,"maxVersion":1}}}"#.utf8)
        } else if value("method") == "list" {
            let name = Self.video ? "ReviewClip.mp4" : "NAS.png"
            let nasType = Self.video ? "video" : "photo"
            let items = value("offset") == "0" ? #"[{"id":7,"filename":"\#(name)","filesize":\#(Self.original.count),"type":"\#(nasType)","additional":{"thumbnail":{"cache_key":"a"}}}]"# : "[]"
            data = Data(#"{"success":true,"data":{"list":\#(items)}}"#.utf8)
        } else if value("method") == "download" {
            data = Self.original
            if url.host == "changed.example" { data.append(0) }
        } else { data = Data() }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:nil)!, cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self, didLoad:data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor final class LinkedTests: XCTestCase {
    #if targetEnvironment(simulator)
    func testOpenMatchIndexTracksAddedAndRemovedPhoto() async throws {
        try XCTSkipUnless(PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized)
        let assets = PHAsset.fetchAssets(with: .image, options: nil)
        let asset = try XCTUnwrap((0..<assets.count).map(assets.object(at:)).first {
            let resources = PHAssetResource.assetResources(for: $0)
            return resources.count == 1 && resources.first?.type == .photo
        })
        let id = asset.localIdentifier
        let original = try await AppleOriginal.fingerprint(id)
        let hash = try XCTUnwrap(original)
        let index = AppleMatchIndex()
        let initial = try await index.matches(hash)
        XCTAssertTrue(initial.contains(id))
        await index.update(removed: [asset], changed: [], inserted: [])
        let removed = try await index.matches(hash)
        XCTAssertFalse(removed.contains(id))
        await index.prepare()
        let reopened = try await index.matches(hash)
        XCTAssertFalse(reopened.contains(id))
        await index.update(removed: [], changed: [], inserted: [asset])
        let restored = try await index.matches(hash)
        XCTAssertTrue(restored.contains(id))
    }
    #endif

    func testLinkChoicesMatchFromEachSelectedLibrary() async throws {
        try await verifyLinkChoices(video: false)
    }

    func testVideoLinkChoicesMatchFromEachSelectedLibrary() async throws {
        try await verifyLinkChoices(video: true)
    }

    private func verifyLinkChoices(video: Bool) async throws {
        #if targetEnvironment(simulator)
        try XCTSkipUnless(PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized)
        if video && PHAsset.fetchAssets(with: .video, options: nil).count == 0 {
            let clip = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ReviewClip", withExtension: "mp4"))
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: clip)
            }
        }
        let assets = PHAsset.fetchAssets(with: video ? .video : .image, options: nil)
        let photo = try XCTUnwrap((0..<assets.count).map(assets.object(at:)).first {
            let resources = PHAssetResource.assetResources(for: $0)
            return resources.count == 1 && resources.first?.type == (video ? .video : .photo)
        })
        let localID = photo.localIdentifier
        let resource = try XCTUnwrap(PHAssetResource.assetResources(for: photo).first)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: nil)
        let previousOriginal = LinkFixture.original
        LinkFixture.original = try Data(contentsOf: file)
        LinkFixture.video = video
        defer { LinkFixture.original = previousOriginal; LinkFixture.video = false }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LinkFixture.self]
        let immich = Library(.immich, session: URLSession(configuration: configuration), saveImmichKey: { _ in })
        let priorServer = UserDefaults.standard.object(forKey: "server")
        defer {
            UserDefaults.standard.set(priorServer, forKey: "server")
        }
        immich.server = "https://link-test.example"
        immich.key = "fixture"
        await immich.connect()
        let remote = try await SynologyPhotos(address: "https://nas.example", username: "test", configuration: configuration)
        remote.resume("fixture")
        let nas = Library(.synology, remote: remote)
        await nas.connect()
        XCTAssertEqual(immich.assets.first?.isVideo, video)
        XCTAssertEqual(nas.assets.first?.isVideo, video)
        let apple = Library(.apple)
        await apple.connect()

        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for choice in LibraryLink.allCases {
            let models = [immich, nas, apple].map { choice.sources.contains($0.source) ? $0 : Library($0.source) }
            let saved = try XCTUnwrap(choice.identity(immich: models[0], nas: models[1]), "\(choice): \(immich.error ?? "") \(nas.error ?? "")")
            XCTAssertEqual(LibraryLink(saved: saved), choice)
            let ids = [PhotoSource.immich: LinkFixture.id, .synology: "7", .apple: localID]
            let queue = DeletionQueue(defaults: defaults)
            queue.configureMatching(libraries: models, linkedPair: saved)
            for model in models where choice.sources.contains(model.source) {
                let id = try XCTUnwrap(ids[model.source])
                queue.add(Asset(id: id, type: video ? "VIDEO" : "IMAGE", originalFileName: video ? "ReviewClip.mp4" : "NAS.png"), from: model)
            }
            for _ in 0..<1000 where queue.working { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(queue.working)
            XCTAssertTrue(queue.matchFailures.isEmpty, "\(queue.matchFailures)")
            XCTAssertEqual(queue.entries.count, choice.sources.count)
            for entry in queue.entries {
                let found = try XCTUnwrap(entry.found)
                XCTAssertEqual(Set(found.map(\.source)), Set(choice.sources.map(\.rawValue)))
                for source in choice.sources {
                    XCTAssertTrue(found.contains { $0.source == source.rawValue && $0.id == ids[source] })
                }
            }
            defaults.removePersistentDomain(forName: suite)
        }
        #endif
    }

    func testSynologyPackagedHEICMatchesTheOriginalStill() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "LivePair", withExtension: "zip"))
        let bytes = try await SynologyPhotos.stillOriginal(Data(contentsOf: url), filename: "IMG_0123.HEIC")
        let fingerprint = try await LinkedPhoto.fingerprint(bytes)
        XCTAssertEqual(fingerprint.digest.base64EncodedString(), "kHfkehCssUth55pfIYUvAtp/yhDYznZDUs7eMjPoqoE=")
    }

    func testFilenameFallbackRequiresMatchingOriginalAndRecognizesMotion() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LinkFixture.self]
        let immich = Library(.immich, session: URLSession(configuration: config))
        immich.server = "https://heic-test.example"
        let queue = DeletionQueue()
        let hash = try await LinkedPhoto.fingerprint(LinkFixture.original)
        let matches = try await queue.immichCopies(hash, filename: "IMG_0500.HEIC", client: immich)
        XCTAssertEqual(matches.map(\.id), [LinkFixture.id])
        XCTAssertNotNil(matches.first?.livePhotoVideoId)
        let other = try await LinkedPhoto.fingerprint(LinkFixture.original + Data([0]))
        let different = try await queue.immichCopies(other, filename: "IMG_0500.HEIC", client: immich)
        XCTAssertTrue(different.isEmpty)
    }
}
