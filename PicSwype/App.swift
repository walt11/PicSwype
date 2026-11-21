import SwiftUI
import Photos
import Security
import UniformTypeIdentifiers

struct Asset: Codable, Identifiable {
    let id: String
    let type: String
    var isTrashed: Bool?
    var originalFileName: String?
    var localDateTime: String?
    var livePhotoVideoId: String?
    var isVideo: Bool { type == "VIDEO" }
}
struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
enum Secret {
    // Keep the original Keychain service so existing installations retain their API key.
    static let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"PicSwype",kSecAttrAccount as String:"apiKey"]
    static func read(service: String = "PicSwype") -> String {
        var q = query
        q[kSecAttrService as String] = service
        q[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    static func save(_ value: String, service: String = "PicSwype") throws {
        var q = query
        q[kSecAttrService as String] = service
        let data = Data(value.utf8)
        let updated = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw Failure(message: "Could not update saved credentials.") }
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(q as CFDictionary,nil) == errSecSuccess else { throw Failure(message: "Could not save credentials.") }
    }
}
@MainActor final class Library: ObservableObject {
    let source: PhotoSource
    var folder: NASFolder?
    private(set) var remote: SynologyPhotos?
    private var pendingRemote: SynologyPhotos?
    struct SavedNAS: Codable { let address: String; let username: String; let sid: String }
    static let nasService = "PicSwype.SynologySession"
    var savedNAS: SavedNAS? {
        try? JSONDecoder().decode(SavedNAS.self, from: Data(Secret.read(service: Self.nasService).utf8))
    }
    func signInNAS(address: String, username: String, password: String, otp: String, saved: SavedNAS? = nil) async {
        guard !busy else { return }
        busy = true
        do {
            let client: SynologyPhotos
            if let pendingRemote, pendingRemote.address == address, pendingRemote.username == username {
                client = pendingRemote
            } else {
                client = try await SynologyPhotos(address: address, username: username)
                pendingRemote = client
            }
            if let saved { client.resume(saved.sid) }
            else { try await client.login(password: password, otp: otp) }
            let record = SavedNAS(address: address, username: username, sid: client.sid)
            try Secret.save(String(decoding: JSONEncoder().encode(record), as: UTF8.self), service: Self.nasService)
            pendingRemote = nil
            remote = client
            folder = nil
            UserDefaults.standard.set(true, forKey: "PicSwype.directNAS")
            busy = false
            await connect()
        } catch { self.error = error.localizedDescription; busy = false }
    }
    func selectFolder(_ url: URL) {
        remote = nil
        pendingRemote = nil
        folder = NASFolder(url)
        UserDefaults.standard.set(false, forKey: "PicSwype.directNAS")
    }
    @Published private(set) var marked: Set<String> = []
    private var catalogue: [Asset] = []
    var progressKey: String {
        switch source {
        case .immich: return server
        case .apple: return "PicSwype.apple"
        case .synology: if let remote { return remote.identity }; return "PicSwype.nas." + (folder?.root.path ?? "")
        }
    }
    private(set) var authenticatedImmich: (server: String, key: String)?
    var isConfigured: Bool {
        switch source {
        case .apple: return true
        case .immich: return connected || (!(UserDefaults.standard.string(forKey: "server") ?? "").isEmpty && !Secret.read().isEmpty)
        case .synology:
            if UserDefaults.standard.bool(forKey: "PicSwype.directNAS") { return savedNAS != nil }
            return folder != nil || UserDefaults.standard.data(forKey: "PicSwype.NASFolder") != nil
        }
    }

    private let httpSession: URLSession
    private let saveImmichKey: (String) throws -> Void
    init(_ source: PhotoSource, session: URLSession = .shared, remote: SynologyPhotos? = nil,
         saveImmichKey: @escaping (String) throws -> Void = { try Secret.save($0) }) {
        self.saveImmichKey = saveImmichKey
        self.remote = remote
        self.source = source
        self.httpSession = session
    }

    @Published var server = UserDefaults.standard.string(forKey:"server") ?? ""
    @Published var key = Secret.read()
    @Published var assets: [Asset] = []
    @Published var picture: UIImage?
    @Published var busy = false
    @Published var error: String?
    @Published var connected = false
    @Published var kept = 0
    @Published var trashed = 0
    private var seen = Set<String>()
    private var nextBatch: Task<Void, Never>?
    private var previews: [String: Task<UIImage, Error>] = [:]
    @Published private(set) var readyPreviews: [String: UIImage] = [:]
    var nextPhotoID: String? { assets.dropFirst().first?.id }

    private var scope: String { source == .immich ? "progress." + server + "." + key : progressKey }
    private struct LastReview {
        let asset: Asset
        let image: UIImage
        let trashed: Bool
        let scope: String
    }
    @Published private var lastReview: LastReview?
    @Published private(set) var previousDecisionWasTrash: Bool?
    var queueScope: String {
        if source == .immich {
            return LinkedPhoto.accountDigest([server, key])
        }
        return progressKey
    }
    var canGoBack: Bool { lastReview?.scope == scope }

    func request(_ path: String, method: String = "GET", body: [String:Any]? = nil) async throws -> Data {
        guard let url = URL(string:server + "/api/" + path), ["http","https"].contains(url.scheme ?? ""), url.host != nil else { throw Failure(message:"Enter a valid http or https server address.") }
        var r = URLRequest(url:url); r.httpMethod = method; r.setValue(key,forHTTPHeaderField:"x-api-key"); r.timeoutInterval = 30
        if let body { r.httpBody = try JSONSerialization.data(withJSONObject:body); r.setValue("application/json",forHTTPHeaderField:"Content-Type") }
        let (data,response) = try await Self.load { try await httpSession.data(for:r) }
        guard let http = response as? HTTPURLResponse else { throw Failure(message: "Invalid server response.") }
        guard (200...299).contains(http.statusCode) else {
            throw Failure(message: "The server returned HTTP \(http.statusCode) for \(method) /api/\(path).")
        }
        if http.mimeType == "text/html" {
            throw Failure(message: "The server returned a web page. Check the server URL and whether your proxy requires browser sign-in.")
        }
        return data
    }
    func downloadVideo(_ id: String, filename: String?) async throws -> DownloadedMovie {
        if let remote { return try await remote.downloadVideo(id) }
        guard source == .immich, UUID(uuidString: id) != nil,
              let url = URL(string: server + "/api/assets/" + id + "/original") else {
            throw Failure(message: "Invalid video identifier.")
        }
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        let (file, response) = try await Self.load { try await httpSession.download(for: request) }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              http.mimeType != "text/html" else { throw Failure(message: "Immich could not download the video.") }
        return try DownloadedMovie(download: file, filename: filename ?? response.suggestedFilename ?? "video.mov")
    }

    /// Plain-HTTP servers are only allowed on the local network; explain the block instead of showing a raw URL error.
    nonisolated static func load<T>(_ operation: () async throws -> T) async throws -> T {
        do { return try await operation() }
        catch let error as URLError where error.code == .appTransportSecurityRequiresSecureConnection {
            throw Failure(message: "Use an https address for servers outside your local network.")
        }
    }

    /// Streams with the API key header instead of downloading the whole original before playback.
    func immichPlaybackURL(_ id: String) -> URL? {
        guard source == .immich, UUID(uuidString: id) != nil else { return nil }
        return URL(string: server + "/api/assets/" + id + "/video/playback")
    }

    private var sweepPage = 1
    /// Random batches rarely surface the last unreviewed items, so walk the library in pages once they run dry.
    private func sweepImmich() async throws {
        struct Search: Decodable {
            struct Page: Decodable { let items: [Asset]; let nextPage: String? }
            let assets: Page
        }
        for _ in 0..<20 where assets.isEmpty {
            let data = try await request("search/metadata", method: "POST", body: ["page": sweepPage, "size": 250])
            let page = try JSONDecoder().decode(Search.self, from: data).assets
            appendUnreviewed(page.items)
            if let next = page.nextPage.flatMap(Int.init), next > sweepPage { sweepPage = next }
            else { sweepPage = 1; break }
        }
    }

    private func randomPhotos(size: Int) async throws -> [Asset] {
        if source != .immich {
            let amount = min(size, catalogue.count)
            let batch = Array(catalogue.suffix(amount))
            catalogue.removeLast(amount)
            return batch
        }
        let data = try await request("search/random", method: "POST", body: ["size": size])
        return try JSONDecoder().decode([Asset].self, from: data)
    }
    func restoreConnection(requestPhotosAccess: Bool = false) async {
        guard !connected, !busy else { return }
        switch source {
        case .apple:
            let access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if requestPhotosAccess || access == .authorized || access == .limited { await connect() }
        case .immich:
            if !server.isEmpty && !key.isEmpty { await connect() }
        case .synology:
            if UserDefaults.standard.bool(forKey: "PicSwype.directNAS") {
                if let saved = savedNAS {
                    await signInNAS(address: saved.address, username: saved.username, password: "", otp: "", saved: saved)
                }
            } else if let bookmark = UserDefaults.standard.data(forKey: "PicSwype.NASFolder") {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
                    selectFolder(url)
                    await connect()
                }
            }
        }
    }

    func connect() async {
        guard !busy else { return }
        lastReview = nil
        previousDecisionWasTrash = nil
        clearQueue()
        busy = true; defer { busy = false }
        do {
            connected = false
            assets = []
            picture = nil
            switch source {
            case .apple:
                try await AppleLibrary.authorize()
                catalogue = await AppleLibrary.images()
            case .synology:
                if let remote { catalogue = try await remote.images() }
                else if let folder { catalogue = try await folder.images() }
                else { throw Failure(message: "Connect to Synology Photos first.") }
            case .immich:
                server = server.trimmingCharacters(in:.whitespacesAndNewlines)
                while server.hasSuffix("/") { server.removeLast() }
                if server.hasSuffix("/api") { server = String(server.dropLast(4)) }
                key = key.trimmingCharacters(in:.whitespacesAndNewlines)
                guard !key.isEmpty else { throw Failure(message:"Enter your Immich API key.") }
                _ = try await randomPhotos(size: 1)
                authenticatedImmich = (server, key)
                try saveImmichKey(key); UserDefaults.standard.set(server,forKey:"server")
            }
            // Progress is scoped to the server; credentials stay in Keychain.
            seen = SeenStore.load(progressKey)
            kept = UserDefaults.standard.integer(forKey:progressKey + ".kept")
            trashed = UserDefaults.standard.integer(forKey:progressKey + ".trashed")
            marked = Set(UserDefaults.standard.stringArray(forKey: progressKey + ".marked") ?? [])
            if source != .immich {
                for asset in catalogue where marked.contains(asset.id) { DeletionQueue.shared.add(asset, from: self) }
                catalogue.removeAll { seen.contains($0.id) || marked.contains($0.id) }
                saveCounts()
            }
            connected = true
            try await refill()
        } catch { self.error = error.localizedDescription }
    }
    private func clearQueue() {
        nextBatch?.cancel()
        nextBatch = nil
        for preview in previews.values { preview.cancel() }
        previews.removeAll()
        readyPreviews.removeAll()
    }

    private func appendUnreviewed(_ batch: [Asset]) {
        var ids = seen.union(marked).union(assets.map(\.id))
        assets.append(contentsOf: batch.filter {
            ($0.type == "IMAGE" || $0.isVideo) && $0.isTrashed != true && ids.insert($0.id).inserted
        })
    }

    func preview(for id: String) async throws -> UIImage {
        if let cached = readyPreviews[id] { return cached }
        switch source {
        case .apple: return try await AppleLibrary.preview(id)
        case .synology:
            if let remote { return try await remote.preview(id) }
            if let folder { return try await folder.preview(id) }
            throw Failure(message: "Connect to Synology Photos first.")
        case .immich:
            let data = try await request("assets/\(id)/thumbnail?size=preview")
            guard let image = UIImage(data: data) else { throw Failure(message: "This photo could not be displayed.") }
            return image
        }
    }

    private func queuePreviews() {
        for asset in assets.prefix(4) where previews[asset.id] == nil {
            previews[asset.id] = Task {
                let image: UIImage
                do { image = try await preview(for: asset.id) }
                catch {
                    guard asset.isVideo, let poster = UIImage(systemName: "film", withConfiguration: UIImage.SymbolConfiguration(pointSize: 96)) else { throw error }
                    image = poster
                }
                try Task.checkCancellation()
                readyPreviews[asset.id] = image
                return image
            }
        }
    }

    func refill() async throws {
        picture = nil
        var failures = 0
        while true {
            if assets.isEmpty {
                await nextBatch?.value
                for _ in 0..<5 where assets.isEmpty {
                    let batch = try await randomPhotos(size: 100)
                    appendUnreviewed(batch)
                    if batch.isEmpty { break }
                }
                if assets.isEmpty, source == .immich { try await sweepImmich() }
            }
            guard let asset = assets.first else { return }
            queuePreviews()
            if assets.count <= 10, nextBatch == nil {
                nextBatch = Task {
                    let batch = try? await randomPhotos(size: 100)
                    guard !Task.isCancelled else { return }
                    if let batch {
                        appendUnreviewed(batch)
                        queuePreviews()
                    }
                    nextBatch = nil
                }
            }
            do {
                picture = try await previews[asset.id]?.value
                return
            } catch {
                previews.removeValue(forKey: asset.id)
                failures += 1
                guard failures < 3, assets.first?.id == asset.id else { throw error }
                // Move past an item that won't load without marking it reviewed; it comes back on a later pass.
                assets.removeFirst()
                readyPreviews.removeValue(forKey: asset.id)
                if source != .immich { catalogue.insert(asset, at: 0) }
            }
        }
    }
    func act(delete: Bool) async {
        guard !busy, let image = picture, let asset = assets.first else { return }
        busy = true; defer { busy = false }
        do {
            if delete {
                DeletionQueue.shared.add(asset, from: self, preview: image)
                marked.insert(asset.id)
            } else { kept += 1 }
            previousDecisionWasTrash = nil
            lastReview = LastReview(asset: asset, image: image, trashed: delete, scope: scope)
            seen.insert(asset.id); assets.removeFirst()
            SeenStore.append(asset.id, progressKey)
            previews.removeValue(forKey: asset.id)
            readyPreviews.removeValue(forKey: asset.id)
            saveCounts()
            try await refill()
        } catch { self.error = error.localizedDescription }
    }
    func trashImmich(_ id: String) async throws {
                let data = try await request("assets",method:"DELETE",body:["ids":[id],"force":false])
                if let results = try? JSONSerialization.jsonObject(with:data) as? [[String:Any]], results.contains(where: { ($0["status"] as? String) == "FAILED" }) { throw Failure(message:"Immich could not trash this photo.") }
    }

    func recordLinkedTrash(_ id: String) async {
        let wasCurrent = assets.first?.id == id
        if seen.insert(id).inserted { SeenStore.append(id, progressKey) }
        marked.remove(id)
        catalogue.removeAll { $0.id == id }
        assets.removeAll { $0.id == id }
        previews.removeValue(forKey: id)?.cancel()
        readyPreviews.removeValue(forKey: id)
        lastReview = nil
        previousDecisionWasTrash = nil
        trashed += 1
        saveCounts()
        if wasCurrent {
            do { try await refill() } catch { self.error = error.localizedDescription }
        }
    }

    private func saveCounts() {
        UserDefaults.standard.set(Array(marked), forKey: progressKey + ".marked")
        UserDefaults.standard.set(kept, forKey: progressKey + ".kept")
        UserDefaults.standard.set(trashed, forKey: progressKey + ".trashed")
    }

    func goBack() async {
        guard !busy, let review = lastReview, review.scope == scope else { return }
        busy = true
        defer { busy = false }
        if review.trashed {
            guard DeletionQueue.shared.removeUnstarted(id: review.asset.id, library: self) else { return }
            marked.remove(review.asset.id)
        } else {
            kept -= 1
        }
        assets.insert(review.asset, at: 0)
        picture = review.image
        previousDecisionWasTrash = review.trashed
        if seen.remove(review.asset.id) != nil { SeenStore.write(seen, progressKey) }
        lastReview = nil
        saveCounts()
    }

    func keepQueued(_ id: String) {
        marked.remove(id)
        if seen.insert(id).inserted { SeenStore.append(id, progressKey) }
        kept += 1
        if lastReview?.asset.id == id { lastReview = nil }
        saveCounts()
    }

    static func keepOffline(_ id: String, progressKey: String) {
        let defaults = UserDefaults.standard
        var marked = Set(defaults.stringArray(forKey: progressKey + ".marked") ?? [])
        marked.remove(id)
        defaults.set(Array(marked), forKey: progressKey + ".marked")
        if !SeenStore.load(progressKey).contains(id) { SeenStore.append(id, progressKey) }
        defaults.set(defaults.integer(forKey: progressKey + ".kept") + 1, forKey: progressKey + ".kept")
    }

    func unmark(_ id: String, isVideo: Bool = false) {
        guard !busy, marked.remove(id) != nil else { return }
        _ = DeletionQueue.shared.removeUnstarted(id: id, library: self)
        if seen.remove(id) != nil { SeenStore.write(seen, progressKey) }
        if lastReview?.asset.id == id { lastReview = nil }
        catalogue.append(Asset(id: id, type: isVideo ? "VIDEO" : "IMAGE", originalFileName: source == .synology ? (remote?.name(id) ?? URL(fileURLWithPath: id).lastPathComponent) : nil))
        saveCounts()
    }

    func reload(reset: Bool = false) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        if reset { lastReview = nil; previousDecisionWasTrash = nil; clearQueue(); seen = []; assets = []; sweepPage = 1; SeenStore.remove(progressKey) }
        if reset && source != .immich {
            busy = false
            await connect()
            return
        }
        do { try await refill() } catch { self.error = error.localizedDescription }
    }
}
@main struct PicSwypeApp: App { var body: some Scene { WindowGroup { ContentView() } } }
struct ContentView: View {
    @StateObject private var immich = Library(.immich)
    @StateObject private var apple = Library(.apple)
    @StateObject private var nas = Library(.synology)
    @AppStorage("PicSwype.linkedPair") private var linkedPair = ""
    @AppStorage("PicSwype.source") private var source = PhotoSource.apple
    var body: some View {
        let active = source == .immich ? immich : (source == .apple ? apple : nas)
        ReviewView(library: active, immich: immich, nas: nas, apple: apple, source: $source).id(source)
            .onChange(of: [linkedPair] + [immich, nas, apple].map { $0.connected ? $0.queueScope : "" }, initial: true) {
                DeletionQueue.shared.configureMatching(libraries: [immich, nas, apple], linkedPair: linkedPair)
            }
            .task(id: apple.connected && LibraryLink(saved: linkedPair)?.sources.contains(.apple) == true, priority: .utility) {
                if apple.connected, LibraryLink(saved: linkedPair)?.sources.contains(.apple) == true {
                    await AppleMatchIndex.shared.prepare()
                }
            }
            .task { await apple.restoreConnection(requestPhotosAccess: source == .apple) }
            .task { await immich.restoreConnection() }
            .task { await nas.restoreConnection() }
    }
}

struct ReviewView: View {
    @ObservedObject var library: Library
    @ObservedObject var immich: Library
    @ObservedObject var nas: Library
    @ObservedObject var apple: Library
    @ObservedObject private var deletionQueue = DeletionQueue.shared
    @State private var showQueue = false
    @Binding var source: PhotoSource
    @AppStorage("PicSwype.linkedPair") private var linkedPair = ""
    @AppStorage("PicSwype.pendingLinkedTrash") private var pendingData = Data()
    private var pair: String? { LinkedPhoto.identity(immich: immich, nas: nas) }
    private var reviewSources: [PhotoSource] {
        [apple, immich, nas].filter(\.connected).map(\.source)
    }

    private var canSwitchLibrary: Bool { reviewSources.contains { $0 != source } }

    @ViewBuilder private var sourceMenu: some View {
        if canSwitchLibrary {
            Menu {
                ForEach(reviewSources, id: \.self) { option in
                    Button { source = option } label: {
                        if source == option { Label(option.rawValue, systemImage: "checkmark") }
                        else { Text(option.rawValue) }
                    }
                }
            } label: { titleLabel }
            .accessibilityLabel("Library, " + source.rawValue)
        } else { titleLabel }
    }

    private var titleLabel: some View {
            HStack(spacing: 7) {
                Image(decorative: "ToolbarIcon")
                    .resizable()
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                VStack(spacing: 0) {
                    Text("PicSwype").font(.system(size: 25, weight: .bold))
                    HStack(spacing: 4) {
                        Text(source.rawValue)
                        if canSwitchLibrary { Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)) }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .frame(minHeight: 44)
            .contentShape(Rectangle())

    }

    @State private var offset: CGFloat = 0
    @State private var transitioning = false
    @State private var outgoingPhoto: UIImage?
    @State private var incomingID: String?
    @State private var cardOpacity = 1.0
    @State private var reviewWidth: CGFloat = 400
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settings = false
    @State private var zoom = false
    @Environment(\.openURL) private var openURL

    private var openPhotoTitle: String {
        switch source {
        case .apple: return library.assets.first?.isVideo == true ? "Video Details" : "Photo Details"
        case .synology: return "Open Synology Photos library"
        case .immich: return "Open in Immich"
        }
    }

    private var photoDestination: (url: URL, fallback: URL?)? {
        guard let asset = library.assets.first else { return nil }
        var link = URLComponents()
        var fallback: URL?
        switch source {
        case .immich:
            guard let server = URL(string: library.server) else { return nil }
            link.scheme = "immich"
            link.host = "asset"
            link.queryItems = [URLQueryItem(name: "id", value: asset.id)]
            fallback = server.appendingPathComponent("photos").appendingPathComponent(asset.id)
        case .apple:
            return nil // iOS can’t open Photos at a specific asset; ApplePhotoInfoButton shows details instead.
        case .synology:
            guard let base = library.remote?.base,
                  let portal = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
            link = portal
            link.queryItems = [URLQueryItem(name: "launchApp", value: "SYNO.Foto.AppInstance")]
        }
        guard let url = link.url else { return nil }
        return (url, fallback)
    }

    @ViewBuilder private var openPhotoButton: some View {
        if library.picture != nil, source == .apple, let asset = library.assets.first {
            ApplePhotoInfoButton(id: asset.id, title: openPhotoTitle)
                .disabled(library.busy)
        } else if library.picture != nil, library.assets.first != nil, source != .synology || library.remote != nil {
            Button {
                guard let destination = photoDestination else { return }
                openURL(destination.url) { opened in
                    guard !opened else { return }
                    if let fallback = destination.fallback {
                        openURL(fallback) { if !$0 { library.error = "Couldn’t open " + source.rawValue + "." } }
                    } else {
                        library.error = "Couldn’t open " + source.rawValue + "."
                    }
                }
            } label: {
                Label(openPhotoTitle, systemImage: "arrow.up.forward.app")
            }
            .disabled(library.busy)
        }
    }

    private func finishReview(delete: Bool) {
        guard !transitioning, !library.busy, library.picture != nil else { return }
        outgoingPhoto = library.picture
        incomingID = library.nextPhotoID
        transitioning = true
        withAnimation(.easeIn(duration: reduceMotion ? 0.09 : 0.15), completionCriteria: .removed) {
            if !reduceMotion { offset = (delete ? -1 : 1) * (reviewWidth + 80) }
            cardOpacity = 0
        } completion: {
            Task { @MainActor in
                await library.act(delete: delete)
                offset = 0
                cardOpacity = 1
                outgoingPhoto = nil
                incomingID = nil
                transitioning = false
            }
        }
    }

    private func fittedPhoto(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 24))
    }

    private func photoCard<Photo: View>(underneath: Bool, @ViewBuilder photo: () -> Photo) -> some View {
        VStack(spacing: 6) {
            Text(library.assets.first?.originalFileName ?? (library.assets.first?.isVideo == true ? "Video" : "Photo"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(underneath ? 0 : 1)
            photo()
            if source != .synology || library.remote != nil {
                Label(openPhotoTitle, systemImage: source == .apple ? "info.circle" : "arrow.up.forward.app")
                    .hidden()
                    .overlay {
                        if !underneath { openPhotoButton.disabled(transitioning) }
                    }
                    .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var settingsButton: some View {
        Button { settings = true } label: { Label("Settings", systemImage: "gearshape") }
    }

    private var setup: some View {
        VStack(spacing: 12) {
            if library.busy { ProgressView() }
            else {
                Image(systemName: "photo.on.rectangle").font(.largeTitle)
                Text(source.rawValue).font(.title2.bold())
                if source == .apple {
                    Button("Allow Photos access") { Task { await apple.connect() } }
                    Link("Open iOS Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                } else { Button("Manage connection") { settings = true } }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { sourceMenu }
            ToolbarItem(placement: .topBarTrailing) { settingsButton }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !library.connected { setup }
                else {
                    VStack(spacing: 12) {
                        HStack { Label("\(library.kept) kept",systemImage:"checkmark.circle.fill").foregroundStyle(.green); Spacer(); Text("\(library.trashed) trashed").foregroundStyle(.secondary); Spacer(); Button { showQueue = true } label: { Label("\(deletionQueue.entries.count) queued", systemImage:"tray.full").foregroundStyle(.pink) } }.font(.subheadline.monospacedDigit())
                        ZStack {
                            if let image = outgoingPhoto ?? library.picture {
                                if transitioning || offset != 0 {
                                    let id = transitioning ? incomingID : library.nextPhotoID
                                    let next = id.flatMap { library.readyPreviews[$0] }
                                    photoCard(underneath: true) {
                                        fittedPhoto(next ?? image)
                                            .blur(radius: next == nil ? 16 : 0)
                                    }
                                    .accessibilityHidden(true)
                                    .allowsHitTesting(false)
                                }
                                photoCard(underneath: false) {
                                    fittedPhoto(image)
                                    .overlay { if library.assets.first?.isVideo == true { Image(systemName: "play.circle.fill").font(.system(size: 52)).foregroundStyle(.white).shadow(radius: 4).allowsHitTesting(false) } }
                                    .accessibilityLabel(library.assets.first?.isVideo == true ? "Play video" : "View photo")
                                    .onTapGesture { if !transitioning { zoom = true } }
                                    .overlay(alignment: offset >= 0 ? .topLeading : .topTrailing) {
                                        Label(offset >= 0 ? "Keep" : "Queue",
                                              systemImage: offset >= 0 ? "checkmark" : "trash.fill")
                                            .font(.headline.bold())
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 14).padding(.vertical, 8)
                                            .background(offset >= 0 ? Color.green.opacity(0.95) : Color.pink.opacity(0.95), in: Capsule())
                                            .padding(12)
                                            .opacity(min(1, max(0, (abs(offset) - 8) / 62)))
                                            .accessibilityHidden(true)
                                            .allowsHitTesting(false)
                                    }
                                    .rotationEffect(.degrees(reduceMotion ? 0 : max(-12, min(12, Double(offset / 24)))))
                                    .offset(x: reduceMotion ? 0 : offset)
                                    .opacity(cardOpacity)
                                    .gesture(DragGesture(coordinateSpace: .global).onChanged { value in
                                        if !transitioning && !library.busy { offset = value.translation.width }
                                    }.onEnded { value in
                                        guard !transitioning else { return }
                                        let x = value.translation.width
                                        if abs(x) > 100 {
                                            finishReview(delete: x < 0)
                                        } else {
                                            withAnimation(reduceMotion ? .linear(duration: 0.10) : .spring(duration: 0.24, bounce: 0.12)) {
                                                offset = 0
                                            }
                                        }
                                    })

                                }
                            } else if library.busy { ProgressView("Loading preview…") }
                            else if !library.assets.isEmpty {
                                ContentUnavailableView {
                                    Label("Couldn’t load this item", systemImage: "exclamationmark.triangle")
                                } description: {
                                    Text("Check your connection, then try again.")
                                } actions: {
                                    Button("Try Again") { Task { await library.reload() } }
                                }
                            }
                            else { ContentUnavailableView("No new photos or videos",systemImage:"photo.stack",description:Text(source == .immich ? "Checking again automatically." : "Refresh the library to check for more photos and videos.")) }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        if let wasTrashed = library.previousDecisionWasTrash {
                            Label(wasTrashed ? "Previously queued" : "Previously kept",
                                  systemImage: wasTrashed ? "trash" : "checkmark.circle")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(wasTrashed ? Color.pink : Color.green)
                        }
                        HStack(spacing: 18) {
                            Button { finishReview(delete: true) } label: {
                                Label("Queue", systemImage:"tray.and.arrow.down").frame(maxWidth: .infinity, minHeight: 38)
                            }.tint(.pink)
                            Button { finishReview(delete: false) } label: {
                                Label("Keep", systemImage: "checkmark").frame(maxWidth: .infinity, minHeight: 38)
                            }.tint(.green)
                        }
                        .font(.headline)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(transitioning || library.busy || library.picture == nil)
                    }.task {
                        while !Task.isCancelled {
                            do { try await Task.sleep(for: .seconds(30)) } catch { return }
                            if source == .immich && !settings && !library.busy && library.picture == nil && library.error == nil {
                                await library.reload()
                            }
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { reviewWidth = $0 }
                    .padding(.horizontal)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
                    .navigationTitle("PicSwype")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            sourceMenu.disabled(library.busy || transitioning)
                        }
                        ToolbarItem(placement: .topBarLeading) {
                            Button { Task { await library.goBack() } } label: {
                                Label("Back", systemImage: "arrow.uturn.backward")
                            }
                            .accessibilityLabel("Undo last review")
                            .disabled(transitioning || library.busy || !library.canGoBack)
                        }
                        ToolbarItem(placement: .topBarTrailing) { settingsButton.disabled(transitioning) }
                    }
                }
            }
        }
        .task(id: pair) {
            if let old = try? JSONDecoder().decode(LinkedPhoto.self, from: pendingData), old.pair == pair {
                deletionQueue.importPending(old, nas: nas)
                pendingData = Data()
            }
        }
        .sheet(isPresented: $showQueue) {
            DeletionQueueView(queue: deletionQueue, libraries: [immich, nas, apple], linkedPair: linkedPair)
        }
        .sheet(isPresented: $settings) {
            LibrarySettings(apple: apple, immich: immich, nas: nas, linkedPair: $linkedPair,
                            pendingReceipt: !pendingData.isEmpty, active: library)
        }
        .sheet(isPresented:$zoom) { if let asset = library.assets.first, asset.isVideo { VideoReview(asset: asset, library: library) } else if let image = library.picture { NavigationStack { ScrollView([.horizontal,.vertical]) { Image(uiImage:image) }.toolbar { ToolbarItem(placement: .topBarLeading) { openPhotoButton }; ToolbarItem(placement: .confirmationAction) { Button("Done") { zoom = false } } } } } }
        .alert("Unable to complete request",isPresented:Binding(get:{library.error != nil},set:{if !$0 {library.error = nil}})) { Button("OK") {library.error = nil} } message: { Text(library.error ?? "") }
    }
}
