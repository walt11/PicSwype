import XCTest
import UIKit
@testable import PicSwype

private final class LinkFixture: URLProtocol {
    static let id = "006EE3F7-5EF4-424C-8F98-F66209F76C1A"
    static let original = UIGraphicsImageRenderer(size: CGSize(width: 5, height: 5)).pngData { context in
        UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 5, height: 5))
    }
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
        var data: Data
        if url.path.hasSuffix("/original") {
            data = Self.original
        } else if url.path.hasSuffix("/metadata") {
            if url.host == "heic-test.example" {
                let search = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
                let items = search?["originalFileName"] as? String == "IMG_0500.HEIC"
                    ? #"[{"id":"\#(Self.id)","type":"IMAGE","livePhotoVideoId":"paired-video"}]"# : "[]"
                data = Data(#"{"assets":{"items":\#(items)}}"#.utf8)
            } else {
                data = Data(#"{"assets":{"items":[{"id":"\#(Self.id)","type":"IMAGE"}]}}"#.utf8)
            }
        } else if url.path.hasSuffix("query.cgi") {
            data = Data(#"{"success":true,"data":{"SYNO.Foto.Browse.Item":{"path":"entry.cgi","minVersion":1,"maxVersion":2},"SYNO.Foto.Download":{"path":"entry.cgi","minVersion":1,"maxVersion":1}}}"#.utf8)
        } else if value("method") == "list" {
            let items = value("offset") == "0" ? #"[{"id":7,"filename":"NAS.png","filesize":\#(Self.original.count),"type":"photo","additional":{"thumbnail":{"cache_key":"a"}}}]"# : "[]"
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

    func testExactBytesRequiredInBothDirections() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LinkFixture.self]
        let immich = Library(.immich, session: URLSession(configuration: config))
        immich.server = "https://immich.example"
        for changed in [false, true] {
            let remote = try await SynologyPhotos(address: changed ? "https://changed.example" : "https://nas.example", username: "test", configuration: config)
            remote.resume("fixture")
            let nasAssets = try await remote.images()
            let asset = Asset(id: LinkFixture.id, type: "IMAGE", originalFileName: changed ? "NAS.png" : "renamed.png")
            let fromImmich = try await LinkedPhoto.find(asset: asset, source: .immich, pair: "pair", immich: immich, nas: remote)
            let fromNAS = try await LinkedPhoto.find(asset: XCTUnwrap(nasAssets.first), source: .synology, pair: "pair", immich: immich, nas: remote)
            XCTAssertEqual(fromImmich, fromNAS)
            XCTAssertEqual(fromImmich != nil, !changed)
            if let match = fromImmich {
                try await match.verifyImmich(immich)
                try await match.verifyNAS(remote)
                let receipt = try JSONDecoder().decode(LinkedPhoto.self, from: JSONEncoder().encode(match))
                XCTAssertEqual(receipt, match)
                let altered = try await SynologyPhotos(address: "https://changed.example", username: "test", configuration: config)
                altered.resume("fixture"); _ = try await altered.images()
                do { try await receipt.verifyNAS(altered); XCTFail("Retry must refuse a modified original") } catch is Failure {}
            }
        }
    }
}
