import Foundation
import CryptoKit
import Darwin

/// Direct HTTP is restricted to explicitly entered local addresses. HTTPS keeps normal TLS validation.
enum ConnectionAddress {
    static func isLAN(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".local") { return true }
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            let n = UInt32(bigEndian: ipv4.s_addr)
            return n >> 24 == 10 || n >> 24 == 127 || n >> 20 == 0xac1 || n >> 16 == 0xc0a8 || n >> 16 == 0xa9fe
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            return withUnsafeBytes(of: ipv6) { bytes in
                (bytes[0] & 0xfe == 0xfc) || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) ||
                (bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1)
            }
        }
        return false
    }
    static func quickConnectID(_ input: String) -> String? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var id = input
        if input.contains("://") {
            guard let url = URL(string: input), url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.port == nil else { return nil }
            if url.scheme?.lowercased() == "quickconnect", url.path.isEmpty { id = url.host ?? "" }
            else if url.scheme?.lowercased() == "https", ["quickconnect.to", "www.quickconnect.to"].contains(url.host?.lowercased() ?? "") {
                id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            } else { return nil }
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard (2...64).contains(id.count), id.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              id.first != "-", id.last != "-" else { return nil }
        return id.lowercased()
    }
}

enum QuickConnectError: LocalizedError {
    case unavailable, invalidResponse, noSecureRoute
    var errorDescription: String? {
        switch self {
        case .unavailable: return "QuickConnect couldn’t find an online NAS for this ID. Check the ID and DSM’s QuickConnect settings."
        case .invalidResponse: return "QuickConnect returned a response PicSwype couldn’t validate. No login details were sent."
        case .noSecureRoute: return "QuickConnect found the NAS, but no verified HTTPS route was available. Check QuickConnect relay permissions, or use your LAN HTTP address."
        }
    }
}

/// Resolver requests contain only the QuickConnect ID; credentials stay in DSMClient.
/// The service protocol is not a public Synology API contract: every route is validated before use.
enum QuickConnectResolver {
    struct Reply: Decodable {
        let errno: Int
        let server: Server?
        let service: Service?
        let env: Environment?
        let smartdns: SmartDNS?
        struct Server: Decodable { let serverID: String; let ddns: String?; let fqdn: String? }
        struct Service: Decodable { let port: Int?; let ext_port: Int?; let relay_dn: String?; let relay_dualstack: String?; let relay_port: Int? }
        struct Environment: Decodable { let control_host: String?; let relay_region: String? }
        struct SmartDNS: Decodable { let host: String?; let lan: [String]?; let lanv6: [String]? }
    }
    static func serviceHost(_ host: String) -> Bool {
        let host = host.lowercased()
        return host.hasSuffix(".quickconnect.to") && !host.contains("/") && !host.contains(":") && !host.contains("@")
    }
    static func decode(_ data: Data) throws -> Reply {
        let decoder = JSONDecoder()
        if let rows = try? decoder.decode([Reply].self, from: data), let first = rows.first { return first }
        guard let reply = try? decoder.decode(Reply.self, from: data) else { throw QuickConnectError.invalidResponse }
        return reply
    }
    static func resolve(_ id: String) async throws -> URL {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 12
        let session = URLSession(configuration: config, delegate: RejectRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        func request(_ command: String, host: String) async throws -> Reply {
            guard serviceHost(host), let url = URL(string: "https://" + host + "/Serv.php") else { throw QuickConnectError.invalidResponse }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [["version": 1, "command": command, "id": "dsm_portal_https", "serverID": id, "is_gofile": false]])
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw QuickConnectError.unavailable }
            return try decode(data)
        }
        var info = try await request("get_server_info", host: "global.quickconnect.to")
        if info.errno != 0, let control = info.env?.control_host, serviceHost(control), control != "global.quickconnect.to" {
            info = try await request("get_server_info", host: control)
        }
        guard info.errno == 0, let server = info.server, !server.serverID.isEmpty else { throw QuickConnectError.unavailable }
        let expected = Insecure.MD5.hash(data: Data(server.serverID.utf8)).map { String(format: "%02x", $0) }.joined()
        var candidates: [URL] = []
        func append(_ host: String?, port: Int? = nil) {
            guard let host, !host.isEmpty, host != "NULL", !host.contains("/"), !host.contains("@"), !host.contains(":") else { return }
            if let port, !(1...65535).contains(port) { return }
            var components = URLComponents(); components.scheme = "https"; components.host = host; components.port = port
            if let url = components.url, !candidates.contains(url) { candidates.append(url) }
        }
        for host in (info.smartdns?.lan ?? []).prefix(4) { append(host, port: info.service?.port) }
        append(info.smartdns?.host, port: info.service?.port)
        append(server.fqdn, port: info.service?.ext_port.flatMap { $0 > 0 ? $0 : nil } ?? info.service?.port)
        append(server.ddns, port: info.service?.ext_port.flatMap { $0 > 0 ? $0 : nil } ?? info.service?.port)
        func verified(_ urls: [URL]) async -> URL? {
            await withTaskGroup(of: URL?.self) { group in
                for base in urls {
                    group.addTask {
                        do {
                            var components = URLComponents(url: base.appendingPathComponent("webman/pingpong.cgi"), resolvingAgainstBaseURL: false)!
                            components.queryItems = [URLQueryItem(name: "action", value: "cors"), URLQueryItem(name: "quickconnect", value: "true")]
                            var request = URLRequest(url: components.url!); request.timeoutInterval = 5
                            let (data, response) = try await session.data(for: request)
                            struct Ping: Decodable { let success: Bool; let ezid: String }
                            let ping = try JSONDecoder().decode(Ping.self, from: data)
                            guard (response as? HTTPURLResponse)?.statusCode == 200, ping.success, ping.ezid.lowercased() == expected else { return nil }
                            return base
                        } catch { return nil }
                    }
                }
                for await url in group { if let url { group.cancelAll(); return url } }
                return nil
            }
        }
        if let direct = await verified(candidates) { return direct }
        let tunnel = try await request("request_tunnel", host: info.env?.control_host ?? "global.quickconnect.to")
        guard tunnel.errno == 0 else { throw QuickConnectError.noSecureRoute }
        candidates = []
        for region in [tunnel.env?.relay_region, info.env?.relay_region].compactMap({ $0 }) {
            if region.range(of: "^[a-zA-Z0-9-]+$", options: .regularExpression) != nil { append("\(id).\(region).quickconnect.to") }
        }
        for host in [tunnel.service?.relay_dn, tunnel.service?.relay_dualstack].compactMap({ $0 }) where serviceHost(host) {
            append(host, port: tunnel.service?.relay_port)
            append(host)
        }
        guard let relay = await verified(candidates) else { throw QuickConnectError.noSecureRoute }
        return relay
    }
}

struct APIInfo: Codable {
    let path: String
    let minVersion: Int
    let maxVersion: Int
}
struct Envelope<T: Decodable>: Decodable {
    let success: Bool
    let data: T?
    let error: APIError?
}
struct APIError: Decodable {
    let code: Int
    let errors: AuthenticationDetails?
    struct AuthenticationDetails: Decodable { let token: String? }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        code = try values.decode(Int.self, forKey: .code)
        // Other APIs use arrays or unrelated objects for errors.
        errors = try? values.decode(AuthenticationDetails.self, forKey: .errors)
    }
    private enum CodingKeys: String, CodingKey { case code, errors }
}

/// An in-memory continuation from DSM's password step. Never persisted or logged.
struct LoginChallenge {
    let username: String
    let password: String
    let token: String
    let created: Date
    func continuation(username: String, password: String, otp: String, now: Date = Date()) -> String? {
        guard !otp.isEmpty, self.username == username, self.password == password,
              now.timeIntervalSince(created) >= 0, now.timeIntervalSince(created) < 300 else { return nil }
        return token
    }
}
struct EmptyPayload: Decodable {}

enum ConnectionError: LocalizedError, Equatable {
    case invalidAddress, invalidResponse, server(Int), unavailable, http(Int), quickConnect, signedOut
    var isSessionExpired: Bool {
        // 150: DSM binds a session to the IP it signed in from; switching networks or routes needs a fresh sign-in.
        if case .server(let code) = self { return [106, 107, 119, 150].contains(code) }
        return false
    }
    var errorDescription: String? {
        switch self {
        case .quickConnect: return "Enter a QuickConnect ID or https://quickconnect.to/your-id."
        case .http(let code): return "The server returned HTTP \(code). Check the DSM address and port."
        case .invalidAddress: return "Enter an HTTPS address, a local HTTP address such as http://192.168.1.20:5000, or a QuickConnect ID."
        case .invalidResponse: return "The NAS returned an unexpected response."
        case .signedOut: return "You’re signed out. Sign in again."
        case .unavailable: return "This NAS doesn’t support that operation."
        case .server(let code):
            switch code {
            case 101, 120: return "The NAS rejected the request parameters (\(code))."
            case 103: return "This Synology Photos version doesn’t support that operation."
            case 105, 160, 803: return "Your account doesn’t have permission for this (\(code))."
            case 106, 107, 119, 150: return "Your NAS session expired. Sign in again."
            case 620: return "Synology Photos doesn’t support this file type."
            case 621, 642: return "The destination folder no longer exists."
            case 801: return "Shared Space is unavailable for this account."
            default: return "The NAS returned error \(code)."
            }
        }
    }
}

enum AuthError: LocalizedError {
    case badCredentials, permissionDenied, otpRequired, otpInvalid, disabled, blocked, passwordExpired, enforce2FA, other(Int)
    init(code: Int) {
        switch code {
        case 400: self = .badCredentials
        case 401: self = .disabled
        case 402: self = .permissionDenied
        case 403: self = .otpRequired
        case 404: self = .otpInvalid
        case 406: self = .enforce2FA
        case 407: self = .blocked
        case 408, 409, 410: self = .passwordExpired
        default: self = .other(code)
        }
    }
    var errorDescription: String? {
        switch self {
        case .badCredentials: return "Incorrect username or password."
        case .permissionDenied: return "DSM denied this sign-in (402). Check that this account is allowed to use Synology Photos and that the address points to the Photos or DSM login service."
        case .otpRequired: return "Enter the code from your authenticator app."
        case .otpInvalid: return "That verification code didn’t work. Try the current code."
        case .disabled: return "This DSM account is disabled."
        case .blocked: return "Too many failed attempts. This IP address is temporarily blocked by DSM."
        case .passwordExpired: return "Your DSM password has expired. Change it in DSM, then sign in."
        case .enforce2FA: return "This account must set up 2-step verification in DSM first."
        case .other(let code): return "Sign-in failed (DSM error \(code))."
        }
    }
}

final class RejectRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}


enum DSMAddress {
    static func normalize(_ address: String) throws -> URL {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { throw ConnectionError.invalidAddress }
        if url.scheme?.lowercased() == "http", !ConnectionAddress.isLAN(host) { throw ConnectionError.invalidAddress }
        if let port = url.port, !(1...65535).contains(port) { throw ConnectionError.invalidAddress }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw ConnectionError.invalidAddress }
        components.scheme = url.scheme?.lowercased(); components.path = ""
        guard let normalized = components.url else { throw ConnectionError.invalidAddress }
        return normalized
    }
}
