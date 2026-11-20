import XCTest
import UIKit
@testable import PicSwype

final class DSMFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let input = request.httpBodyStream {
            input.open(); defer { input.close() }
            var bytes = [UInt8](repeating: 0, count: 2048)
            while true {
                let n = input.read(&bytes, maxLength: bytes.count)
                if n <= 0 { break }
                body.append(contentsOf: bytes.prefix(n))
            }
        }
        let fields = URLComponents(string: "?" + String(decoding: body, as: UTF8.self))?.queryItems ?? []
        func field(_ name: String) -> String? { fields.first { $0.name == name }?.value }
        var data: Data
        switch field("api") {
        case "SYNO.API.Info":
            data = Data(#"{"success":true,"data":{"SYNO.Foto.Setting.Admin":{"path":"entry.cgi","minVersion":1,"maxVersion":1},"SYNO.API.Auth":{"path":"auth.cgi","minVersion":3,"maxVersion":7},"SYNO.Foto.Browse.Item":{"path":"entry.cgi","minVersion":1,"maxVersion":7},"SYNO.Foto.Thumbnail":{"path":"entry.cgi","minVersion":1,"maxVersion":1}}}"#.utf8)
        case "SYNO.API.Auth":
            let ok = field("passwd") == "challenge" && field("otp_code") == "123456"
            data = Data((ok ? #"{"success":true,"data":{"sid":"fixture"}}"# : #"{"success":false,"error":{"code":403,"errors":{"token":"challenge"}}}"#).utf8)
        case "SYNO.Foto.Setting.Admin":
            data = Data((request.url?.host == "disabled.example" ? #"{"success":true,"data":{"enable_personal_dsm_recycle_bin":false}}"# : #"{"success":true,"data":{"enable_personal_dsm_recycle_bin":true}}"#).utf8)
        case "SYNO.Foto.Browse.Item" where field("method") == "delete":
            XCTAssertNotEqual(request.url?.host, "disabled.example")
            XCTAssertEqual(field("id"), "[1]")
            data = Data(#"{"success":true}"#.utf8)
        case "SYNO.Foto.Browse.Item" where field("_sid") == "fixture":
            data = Data((field("offset") == "0" ? #"{"success":true,"data":{"list":[{"id":1,"filename":"Sample.jpg","type":"photo","additional":{"thumbnail":{"cache_key":"sample","unit_id":42}}}]}}"# : #"{"success":true,"data":{"list":[]}}"#).utf8)
        case "SYNO.Foto.Thumbnail" where field("_sid") == "fixture" && field("id") == "42":
            data = UIGraphicsImageRenderer(size: CGSize(width: 2,height: 2)).pngData { _ in }
        default: data = Data(#"{"success":false,"error":{"code":105}}"#.utf8)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor final class SynologyTests: XCTestCase {
    func testDirectPersonalSpaceWithTwoStepSignIn() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DSMFixture.self]
        let client = try await SynologyPhotos(address: "https://nas.example", username: "tester", configuration: config)
        do { try await client.login(password: "fixture password", otp: ""); XCTFail("Expected a challenge") }
        catch AuthError.otpRequired {}
        try await client.login(password: "fixture password", otp: "123456")
        let assets = try await client.images()
        XCTAssertEqual(assets.map(\.originalFileName), ["Sample.jpg"])
        let preview = try await client.preview("1")
        XCTAssertGreaterThan(preview.size.width, 0)
        try await client.trash("1")
        let disabled = try await SynologyPhotos(address: "https://disabled.example", username: "tester", configuration: config)
        disabled.resume("fixture")
        _ = try await disabled.images()
        do { try await disabled.trash("1"); XCTFail("Should refuse without a recycle bin") }
        catch is Failure { }

    }
    func testConnectionAddressForms() throws {
        XCTAssertEqual(ConnectionAddress.quickConnectID("https://quickconnect.to/My-Nas"), "my-nas")
        XCTAssertEqual(ConnectionAddress.quickConnectID("My-Nas"), "my-nas")
        XCTAssertThrowsError(try DSMAddress.normalize("http://nas.example"))
        XCTAssertEqual(try DSMAddress.normalize("http://192.168.1.2:5000/").port, 5000)
    }
}
