import Foundation
import UIKit
import ImageIO
import ZIPFoundation

/// Personal Space access through the same DSM Photos APIs used by Fotera.
@MainActor final class SynologyPhotos {
    let address: String
    let username: String
    var identity: String { "PicSwype.dsm." + address + "/" + username }
    let base: URL
    private let session: URLSession
    private var routes: [String: APIInfo] = [:]
    private(set) var sid = ""
    private var challenge: LoginChallenge?
    private var items: [String: Item] = [:]

    struct Item: Decodable {
        let id: Int
        let filesize: Int?
        let filename: String
        let type: String
        let additional: Additional?
        struct Additional: Decodable {
            let thumbnail: Thumb?
            struct Thumb: Decodable { let cache_key: String; let unit_id: Int? }
        }
    }

    init(address: String, username: String, configuration: URLSessionConfiguration = .ephemeral) async throws {
        self.address = address
        self.username = username
        if let id = ConnectionAddress.quickConnectID(address) {
            base = try await QuickConnectResolver.resolve(id)
        } else {
            base = try DSMAddress.normalize(address)
        }
        session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
        let data = try await post("query.cgi", ["api":"SYNO.API.Info", "version":"1", "method":"query", "query":"SYNO.API.Auth,SYNO.Foto.Browse.Item,SYNO.Foto.Thumbnail,SYNO.Foto.Setting.Admin,SYNO.Foto.Download"])
        routes = try decode(data, as: [String: APIInfo].self)
    }

    private func post(_ path: String, _ fields: [String: String]) async throws -> Data {
        guard !path.contains(".."), !path.contains(":"), !path.hasPrefix("/") else { throw ConnectionError.invalidResponse }
        var req = URLRequest(url: base.appendingPathComponent("webapi").appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        req.httpBody = Data(fields.map { key, value in
            key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ConnectionError.invalidResponse }
        guard http.statusCode == 200 else { throw ConnectionError.http(http.statusCode) }
        return data
    }

    private func decode<T: Decodable>(_ data: Data, as: T.Type) throws -> T {
        let value = try JSONDecoder().decode(Envelope<T>.self, from: data)
        guard value.success else { throw ConnectionError.server(value.error?.code ?? -1) }
        guard let payload = value.data else { throw ConnectionError.invalidResponse }
        return payload
    }

    func login(password: String, otp: String) async throws {
        struct Login: Decodable { let sid: String }
        guard let route = routes["SYNO.API.Auth"], let version = [7,6].first(where: { (route.minVersion...route.maxVersion).contains($0) }) else { throw ConnectionError.unavailable }
        var fields = ["api":"SYNO.API.Auth", "version":String(version), "method":"login", "account":username,
                      "passwd":challenge?.continuation(username: username, password: password, otp: otp) ?? password,
                      "session":"webui", "format":"sid", "app_name":"SYNO.Foto.AppInstance", "launchApp":"SYNO.Foto.Sharing.AppInstance",
                      "photos_action":"external_login", "client":"browser", "logintype":"local", "device_name":"PicSwype iOS"]
        if !otp.isEmpty { fields["otp_code"] = otp }
        let data = try await post(route.path, fields)
        let result = try JSONDecoder().decode(Envelope<Login>.self, from: data)
        guard result.success, let id = result.data?.sid, !id.isEmpty else {
            let code = result.error?.code ?? -1
            if code == 403, let token = result.error?.errors?.token {
                challenge = LoginChallenge(username: username, password: password, token: token, created: Date())
            } else if code != 404 { challenge = nil }
            throw AuthError(code: code)
        }
        challenge = nil
        sid = id
    }

    func resume(_ token: String) { sid = token }

    private func call(_ api: String, _ version: Int, _ method: String, _ fields: [String: String]) async throws -> Data {
        guard let route = routes[api], route.minVersion <= version, route.maxVersion >= version else { throw ConnectionError.unavailable }
        var params = fields
        params["api"] = api; params["version"] = String(version); params["method"] = method; params["_sid"] = sid
        return try await post(route.path, params)
    }

    func images() async throws -> [Asset] {
        struct Page: Decodable { let list: [Item] }
        var offset = 0
        var found: [String: Item] = [:]
        let limit = 500
        var previousLast: Int?
        while true {
            let data = try await call("SYNO.Foto.Browse.Item", 2, "list", ["offset":String(offset), "limit":String(limit),
                "sort_by":"takentime", "sort_direction":"desc", "additional":"[\"thumbnail\"]"])
            let page = try decode(data, as: Page.self).list
            guard !page.isEmpty else { break }
            guard page.last?.id != previousLast else { throw ConnectionError.invalidResponse }
            previousLast = page.last?.id
            for item in page where item.type != "video" && !(item.type == "live" && ["mov","mp4","m4v"].contains((item.filename as NSString).pathExtension.lowercased())) && item.additional?.thumbnail != nil {
                found[String(item.id)] = item
            }
            offset += page.count
        }
        items = found
        return found.map { Asset(id: $0.key, type: "IMAGE", originalFileName: $0.value.filename) }.shuffled()
    }

    func possibleCopies(byteCount: Int, filename: String?, includeUnknownSizes: Bool = false) -> [String] {
        items.values.filter { $0.type == "photo" && ($0.filesize == byteCount || ($0.filesize == nil && (includeUnknownSizes || $0.filename == filename))) }
            .sorted { ($0.filename == filename ? 0 : 1, $0.id) < ($1.filename == filename ? 0 : 1, $1.id) }
            .map { String($0.id) }
    }

    func original(_ id: String) async throws -> Data {
        guard let item = items[id], isStill(id) else { throw Failure(message: "Linking is available for still photos.") }
        var fields = ["item_id": "[\(item.id)]", "force_download": "true"]
        let version = routes["SYNO.Foto.Download"]?.maxVersion ?? 1
        if version >= 2 { fields["download_type"] = "source" }
        if let thumb = item.additional?.thumbnail { fields["cache_key"] = thumb.cache_key }
        let data = try await call("SYNO.Foto.Download", min(version, 2), "download", fields)
        return try await Self.stillOriginal(data, filename: item.filename)
    }

    nonisolated static func stillOriginal(_ data: Data, filename: String) async throws -> Data {
        if let reply = try? JSONDecoder().decode(Envelope<EmptyPayload>.self, from: data), !reply.success {
            throw ConnectionError.server(reply.error?.code ?? -1)
        }
        var image = data
        if data.starts(with: [0x50, 0x4b, 0x03, 0x04]) {
            let archive = try Archive(data: data, accessMode: .read)
            let stills = archive.filter { entry in
                let path = entry.path as NSString
                return entry.type == .file && !path.lastPathComponent.hasPrefix(".") &&
                    !entry.path.hasPrefix("__MACOSX/") &&
                    ["heic", "heif", "jpg", "jpeg", "png", "tif", "tiff", "dng"].contains(path.pathExtension.lowercased())
            }
            guard stills.count == 1, let still = stills.first, still.uncompressedSize <= 128 * 1024 * 1024 else {
                throw Failure(message: "Synology’s download for " + filename + " did not contain one identifiable original photo within the size limit.")
            }
            image = Data()
            let crc = try archive.extract(still) { chunk in
                try Task.checkCancellation()
                guard image.count + chunk.count <= still.uncompressedSize else { throw ConnectionError.invalidResponse }
                image.append(chunk)
            }
            guard crc == still.checksum, image.count == still.uncompressedSize else {
                throw Failure(message: "The Synology download for " + filename + " was incomplete.")
            }
        }
        guard let source = CGImageSourceCreateWithData(image as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw Failure(message: "Synology returned an unreadable original for " + filename + ".")
        }
        return image
    }

    func trash(_ id: String) async throws {
        guard let item = items[id] else { throw ConnectionError.invalidResponse }
        struct Settings: Decodable { let enable_personal_dsm_recycle_bin: Bool? }
        let setting = try await call("SYNO.Foto.Setting.Admin", 1, "get", [:])
        guard try decode(setting, as: Settings.self).enable_personal_dsm_recycle_bin == true else {
            throw Failure(message: "Enable the Personal Space recycle bin on your NAS to use Trash.")
        }
        let data = try await call("SYNO.Foto.Browse.Item", 1, "delete", ["id": "[\(item.id)]"])
        let response = try JSONDecoder().decode(Envelope<EmptyPayload>.self, from: data)
        guard response.success else { throw ConnectionError.server(response.error?.code ?? -1) }
        items.removeValue(forKey: id)
    }

    func isStill(_ id: String) -> Bool {
        guard let item = items[id] else { return false }
        return item.type == "photo" || (item.type == "live" && ["heic", "heif", "jpg", "jpeg"].contains((item.filename as NSString).pathExtension.lowercased()))
    }

    func name(_ id: String) -> String { items[id]?.filename ?? id }

    func preview(_ id: String) async throws -> UIImage {
        guard let item = items[id], let thumb = item.additional?.thumbnail else { throw ConnectionError.invalidResponse }
        let data = try await call("SYNO.Foto.Thumbnail", 1, "get", ["id":String(thumb.unit_id ?? item.id),"type":"unit","cache_key":thumb.cache_key,"size":"xl"])
        if let image = UIImage(data: data) { return image }
        _ = try decode(data, as: EmptyPayload.self)
        throw ConnectionError.invalidResponse
    }
}
