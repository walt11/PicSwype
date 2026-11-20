import SwiftUI
import Photos
import CryptoKit

struct QueueTarget: Hashable, Codable {
    let source: String
    let scope: String
    let id: String
}

struct DeletionEntry: Identifiable, Codable {
    let id: UUID
    let origin: QueueTarget
    let name: String
    let live: Bool
    let fileDate: Date?
    var progressKey: String?
    var found: Set<QueueTarget>?
    var excluded: Set<QueueTarget>?
    var preparedFor: String?
    var remaining: Set<QueueTarget>?
    var digest: Data?
    var uncheckedMotion: Set<QueueTarget>?
    var matchVersion: Int?

    func needsMatching(_ pair: String) -> Bool {
        remaining == nil && (found == nil || preparedFor != pair || (!pair.isEmpty && matchVersion != 2))
    }
}

@MainActor final class DeletionQueue: ObservableObject {
    static let shared = DeletionQueue()
    private let defaults: UserDefaults
    private let key = "PicSwype.deletionQueue.v1"
    @Published private(set) var entries: [DeletionEntry] {
        didSet {
            if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: key) }
            if entries.count < oldValue.count {
                let removed = Set(oldValue.map(\.id)).subtracting(entries.map(\.id))
                for id in removed {
                    matchFailures.removeValue(forKey: id)
                    try? FileManager.default.removeItem(at: thumbnailURL(id))
                }
            }
        }
    }
    @Published private(set) var working = false
    @Published private(set) var deleting = false
    @Published private(set) var status = ""
    @Published var error: String?

    private var libraries: [Library] = []
    private var matchingPair = ""
    private var revision = 0
    private var worker: Task<Void, Never>?
    @Published private(set) var matchFailures: [UUID: String] = [:]

    func configureMatching(libraries: [Library], linkedPair: String) {
        self.libraries = libraries
        matchingPair = linkedPair
        revision += 1
        retryMatching()
    }

    func retryMatching() {
        matchFailures.removeAll()
        scheduleMatching()
    }

    private var nextPending: DeletionEntry? {
        entries.first {
            $0.needsMatching(matchingPair) && matchFailures[$0.id] == nil
        }
    }

    private func scheduleMatching() {
        guard worker == nil, !libraries.isEmpty, !deleting, nextPending != nil else { return }
        working = true
        worker = Task(priority: .utility) {
            defer { worker = nil; working = false; status = "" }
            while let entry = nextPending {
                let version = revision
                do {
                    try await prepare(entry, libraries: libraries, linkedPair: matchingPair, version: version)
                } catch {
                    if version == revision, entries.contains(where: { $0.id == entry.id }) {
                        matchFailures[entry.id] = error.localizedDescription
                    }
                }
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([DeletionEntry].self, from: $0) } ?? []
    }

    private func thumbnailURL(_ id: UUID) -> URL {
        URL.cachesDirectory.appending(path: "QueueThumbnails/").appending(path: id.uuidString + ".jpg")
    }

    private func cacheThumbnail(_ image: UIImage, id: UUID) -> UIImage? {
        let size = CGSize(width: 160, height: 160)
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = max(size.width / image.size.width, size.height / image.size.height)
        let width = image.size.width * scale
        let height = image.size.height * scale
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height))
        }
        let url = thumbnailURL(id)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? small.jpegData(compressionQuality: 0.82)?.write(to: url, options: .atomic)
        return small
    }

    func thumbnail(_ entry: DeletionEntry, libraries: [Library]) async -> UIImage? {
        if let cached = UIImage(contentsOfFile: thumbnailURL(entry.id).path) { return cached }
        let targets = [entry.origin] + Array(entry.remaining ?? entry.found ?? [])
        for target in Set(targets) {
            guard !Task.isCancelled else { return nil }
            if let model = try? library(for: target, in: libraries),
               let image = try? await model.preview(for: target.id), !Task.isCancelled,
               entries.contains(where: { $0.id == entry.id }) {
                return cacheThumbnail(image, id: entry.id)
            }
        }
        return nil
    }

    func add(_ asset: Asset, from library: Library, preview: UIImage? = nil) {
        let origin = QueueTarget(source: library.source.rawValue, scope: library.queueScope, id: asset.id)
        guard !entries.contains(where: { $0.origin == origin }) else { return }
        let date = library.folder == nil ? nil : (try? URL(fileURLWithPath: asset.id).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let filename = asset.originalFileName ?? (library.source == .apple ? AppleOriginal.name(asset.id) : nil)
        let id = UUID()
        if let preview { _ = cacheThumbnail(preview, id: id) }
        entries.append(.init(id: id, origin: origin, name: filename ?? "Photo", live: asset.livePhotoVideoId != nil, fileDate: date, progressKey: library.progressKey))
        scheduleMatching()
    }

    func importPending(_ receipt: LinkedPhoto, nas: Library) {
        let target = QueueTarget(source: nas.source.rawValue, scope: nas.queueScope, id: receipt.nasID)
        guard !entries.contains(where: { $0.origin == target }) else { return }
        entries.append(.init(id: UUID(), origin: target, name: nas.remote?.name(target.id) ?? "Synology photo",
                             live: false, fileDate: nil, found: [target], preparedFor: receipt.pair,
                             remaining: [target], digest: receipt.digest))
    }

    func removeUnstarted(id: String, library: Library) -> Bool {
        guard !deleting, let i = entries.firstIndex(where: { $0.origin.id == id && $0.origin.scope == library.queueScope && $0.remaining == nil }) else { return false }
        entries.remove(at: i)
        return true
    }

    private func library(for target: QueueTarget, in libraries: [Library]) throws -> Library {
        guard let model = libraries.first(where: { $0.source.rawValue == target.source && $0.queueScope == target.scope }),
              model.connected, model.source != .immich || (model.authenticatedImmich?.server == model.server && model.authenticatedImmich?.key == model.key)
        else { throw Failure(message: "Reconnect the original " + target.source + " library, then try again.") }
        return model
    }

    private func finish(_ target: QueueTarget, in model: Library, libraries: [Library]) async {
        for entry in entries where entry.remaining == [target] && entry.excluded?.contains(entry.origin) == true {
            let origin = libraries.first { $0.source.rawValue == entry.origin.source && $0.queueScope == entry.origin.scope }
            origin?.unmark(entry.origin.id)
        }
        entries = entries.compactMap { entry in
            var entry = entry
            guard var left = entry.remaining, left.remove(target) != nil else { return entry }
            entry.remaining = left
            return left.isEmpty ? nil : entry
        }
        await model.recordLinkedTrash(target.id)
    }

    private func prepare(_ entry: DeletionEntry, libraries: [Library], linkedPair: String, version: Int) async throws {
        guard let immich = libraries.first(where: { $0.source == .immich }),
              let nas = libraries.first(where: { $0.source == .synology }),
              let apple = libraries.first(where: { $0.source == .apple }) else {
            throw Failure(message: "Photo libraries are unavailable.")
        }
        let linked = !linkedPair.isEmpty
        status = "Checking " + entry.name + "…"
        if linked && LinkedPhoto.identity(immich: immich, nas: nas) != linkedPair {
            throw Failure(message: "Reconnect the linked Immich and Synology accounts to check all copies.")
        }
        if linked || entry.origin.source == PhotoSource.apple.rawValue {
            if !apple.connected { await apple.connect() }
            guard apple.connected else { throw Failure(message: "Allow Apple Photos access and try again.") }
        }
        var digest: Data?
        var motion: Set<QueueTarget> = []
        let model = try library(for: entry.origin, in: libraries)
        var targets: Set<QueueTarget> = [entry.origin]
        if linked && !entry.live {
            let hash = try await original(entry.origin, in: model)
            if let hash, let remote = nas.remote {
                digest = hash.digest
                if model.source != .immich {
                    for asset in try await immichCopies(hash, filename: entry.name, client: immich) {
                        let target = QueueTarget(source: PhotoSource.immich.rawValue, scope: immich.queueScope, id: asset.id)
                        targets.insert(target)
                        if asset.livePhotoVideoId != nil { motion.insert(target) }
                    }
                }
                if model.source != .synology || model.folder != nil {
                    for id in remote.possibleCopies(byteCount: hash.count, filename: entry.name, includeUnknownSizes: true) {
                        let candidate = try await LinkedPhoto.fingerprint(remote.original(id))
                        if candidate.digest == hash.digest { targets.insert(.init(source: PhotoSource.synology.rawValue, scope: nas.queueScope, id: id)) }
                    }
                }
            }
        }
        if let digest {
            let matches = try await AppleOriginal.matches([digest])
            for id in matches[digest, default: []] {
                targets.insert(.init(source: PhotoSource.apple.rawValue, scope: apple.queueScope, id: id))
            }
        }
        guard revision == version, let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let exclusions = Set(entries.flatMap { $0.excluded ?? [] })
        var updated = entries[index]
        updated.found = targets
        updated.uncheckedMotion = motion
        updated.matchVersion = 2
        updated.excluded = targets.intersection(exclusions).union(motion.subtracting(entry.uncheckedMotion ?? []))
        updated.preparedFor = linkedPair
        updated.digest = digest
        entries[index] = updated
    }

    func setSelected(_ selected: Bool, source: String, entryID: UUID) {
        guard !deleting, let i = entries.firstIndex(where: { $0.id == entryID }), let found = entries[i].found,
              entries[i].remaining == nil else { return }
        let targets = found.filter { $0.source == source }
        for j in entries.indices where entries[j].remaining == nil {
            let shared = targets.intersection(entries[j].found ?? [])
            guard !shared.isEmpty else { continue }
            var excluded = entries[j].excluded ?? []
            if selected { excluded.subtract(shared) } else { excluded.formUnion(shared) }
            entries[j].excluded = excluded
        }
    }

    func deleteAll(libraries: [Library], linkedPair: String) async {
        guard !working, !entries.isEmpty, !libraries.contains(where: { $0.busy }),
              entries.allSatisfy({ !$0.needsMatching(linkedPair) }) else { return }
        working = true
        deleting = true
        defer {
            working = false
            deleting = false
            status = ""
            scheduleMatching()
        }
        let initial = entries
        var completed = Set<QueueTarget>()
        do {
            guard let apple = libraries.first(where: { $0.source == .apple }) else { return }
            for i in entries.indices where entries[i].remaining == nil {
                let selected = (entries[i].found ?? []).subtracting(entries[i].excluded ?? [])
                if !selected.isEmpty { entries[i].remaining = selected }
            }
            let targets = Set(entries.flatMap { $0.remaining ?? [] })
            // Resolve all accounts and recheck every matched target before any mutation.
            for target in targets {
                let model = try library(for: target, in: libraries)
                let expected = Set(entries.filter { $0.remaining?.contains(target) == true }.compactMap(\.digest))
                if !expected.isEmpty {
                    guard expected.count == 1, let actual = try await original(target, in: model), expected.contains(actual.digest) else {
                        throw Failure(message: "A queued original changed. Remove that entry and review it again.")
                    }
                }
            }
            let local = targets.filter { $0.source == PhotoSource.apple.rawValue }
            if !local.isEmpty {
                status = "Deleting from Apple Photos…"
                try await AppleLibrary.delete(Set(local.map(\.id)))
                for target in local { completed.insert(target); await finish(target, in: apple, libraries: libraries) }
            }
            for target in targets where target.source != PhotoSource.apple.rawValue {
                let model = try library(for: target, in: libraries)
                status = "Moving photo to trash in " + target.source + "…"
                if model.source == .immich { try await model.trashImmich(target.id) }
                else if let remote = model.remote { try await remote.trash(target.id) }
                else if let folder = model.folder {
                    guard let entry = entries.first(where: { $0.origin == target }), let date = entry.fileDate else { throw Failure(message: "Requeue this file to verify its identity.") }
                    try folder.trash(target.id, date: date)
                } else { throw Failure(message: "Reconnect the NAS.") }
                completed.insert(target)
                await finish(target, in: model, libraries: libraries)
            }
        } catch {
            // Keep choices editable when a request failed before this entry lost any copies.
            for i in entries.indices {
                if let old = initial.first(where: { $0.id == entries[i].id }), old.remaining == nil,
                   (old.found ?? []).isDisjoint(with: completed) { entries[i].remaining = nil }
            }
            self.error = error.localizedDescription
        }
    }

    func keep(_ row: DeletionEntry, libraries: [Library]) {
        guard !deleting, let entry = entries.first(where: { $0.id == row.id }) else { return }
        let protected = entry.remaining ?? (entry.found ?? [entry.origin])
        let originSurvives = protected.contains(entry.origin) || entry.excluded?.contains(entry.origin) == true
        if originSurvives {
            let model = libraries.first { $0.queueScope == entry.origin.scope && $0.source.rawValue == entry.origin.source }
            if let model, model.connected {
                guard !model.busy else { return }
                model.keepQueued(entry.origin.id)
            } else if let key = entry.progressKey ?? model?.progressKey {
                Library.keepOffline(entry.origin.id, progressKey: key)
            } else {
                error = "Reconnect the original library to keep this photo."
                return
            }
        }
        for i in entries.indices where entries[i].id != entry.id {
            entries[i].excluded = (entries[i].excluded ?? []).union(protected)
            entries[i].remaining?.subtract(protected)
        }
        entries.removeAll { $0.id == entry.id || $0.remaining?.isEmpty == true }
    }

    private func original(_ target: QueueTarget, in model: Library) async throws -> LinkedPhoto.Fingerprint? {
        switch model.source {
        case .immich: return try await LinkedPhoto.immichOriginal(target.id, model)
        case .apple: return try await AppleOriginal.fingerprint(target.id)
        case .synology:
            guard let remote = model.remote, remote.isStill(target.id) else { return nil }
            return try await LinkedPhoto.fingerprint(remote.original(target.id))
        }
    }

    func immichCopies(_ hash: LinkedPhoto.Fingerprint, filename: String, client: Library) async throws -> [Asset] {
        struct Search: Decodable {
            struct Page: Decodable { let items: [Asset]; let nextPage: String? }
            let assets: Page
        }
        var verified: [Asset] = []
        var checked = Set<String>()
        for filter in [["checksum": hash.searchChecksum], ["originalFileName": filename]] {
            var page = 1
            while true {
                var body: [String: Any] = filter
                body["page"] = page
                body["size"] = 100
                let data = try await client.request("search/metadata", method: "POST", body: body)
                let hits = try JSONDecoder().decode(Search.self, from: data).assets
                for asset in hits.items where asset.type == "IMAGE" && asset.isTrashed != true && checked.insert(asset.id).inserted {
                    if try await LinkedPhoto.immichOriginal(asset.id, client).digest == hash.digest {
                        verified.append(asset)
                    }
                }
                guard let next = hits.nextPage else { break }
                guard let n = Int(next), n > page else { throw Failure(message: "Unexpected Immich search response.") }
                page = n
            }
            if !verified.isEmpty { break }
        }
        return verified
    }

}

enum AppleOriginal {
    static func name(_ id: String) -> String? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject.flatMap { PHAssetResource.assetResources(for: $0).first?.originalFilename }
    }
    static func fingerprint(_ id: String) async throws -> LinkedPhoto.Fingerprint? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { throw Failure(message: "An Apple photo is no longer accessible.") }
        let resources = PHAssetResource.assetResources(for: asset)
        guard resources.count == 1, let resource = resources.first, resource.type == .photo else { return nil }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        return try await withCheckedThrowingContinuation { continuation in
            var sha = SHA256(), search = Insecure.SHA1(), count = 0
            PHAssetResourceManager.default().requestData(for: resource, options: options) { chunk in
                sha.update(data: chunk); search.update(data: chunk); count += chunk.count
            } completionHandler: { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: LinkedPhoto.Fingerprint(digest: Data(sha.finalize()), searchChecksum: Data(search.finalize()).base64EncodedString(), count: count)) }
            }
        }
    }
    private struct CachedOriginal {
        let modified: Date
        let digest: Data?
    }
    @MainActor private static var cache: [String: CachedOriginal] = [:]
    @MainActor static func matches(_ wanted: Set<Data>) async throws -> [Data: [String]] {
        var result: [Data: [String]] = [:]
        let assets = PHAsset.fetchAssets(with: .image, options: nil)
        for i in 0..<assets.count {
            try Task.checkCancellation()
            let asset = assets.object(at: i)
            let id = asset.localIdentifier
            let digest: Data?
            if let cached = cache[id], cached.modified == asset.modificationDate {
                digest = cached.digest
            } else {
                digest = try await fingerprint(id)?.digest
                if let modified = asset.modificationDate { cache[id] = CachedOriginal(modified: modified, digest: digest) }
            }
            if let digest, wanted.contains(digest) { result[digest, default: []].append(id) }
        }
        return result
    }
}

struct DeletionQueueView: View {
    @ObservedObject var queue: DeletionQueue
    let libraries: [Library]
    let linkedPair: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if queue.entries.isEmpty { ContentUnavailableView("Queue is empty", systemImage: "tray") }
                else {
                    Section {
                        ForEach(queue.entries) { entry in
                            QueuePhotoRow(entry: entry, queue: queue, libraries: libraries, linkedPair: linkedPair)
                                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 12))
                            .swipeActions { Button("Keep") { queue.keep(entry, libraries: libraries) }.tint(.green).disabled(queue.deleting) }
                        }
                    } footer: {
                        Text(linkedPair.isEmpty ? "Library linking is off. Choose “Link all three libraries” in settings to check for copies." : "Choose the libraries to delete from. Live Photo matches with unverified motion start unselected.")
                    }
                }
            }
            .listStyle(.plain)
            .safeAreaInset(edge: .bottom) {
                if !queue.entries.isEmpty {
                    Group {
                    if queue.working { ProgressView(queue.status) }
                    else if queue.entries.contains(where: { $0.needsMatching(linkedPair) }) {
                        if queue.entries.contains(where: { queue.matchFailures[$0.id] != nil }) {
                            Button("Retry matching") { queue.retryMatching() }
                        } else { ProgressView("Waiting to check photos…") }
                    } else { Button("Delete All", role: .destructive) { Task { await queue.deleteAll(libraries: libraries, linkedPair: linkedPair) } }.disabled(!queue.entries.contains { !($0.remaining ?? ($0.found ?? []).subtracting($0.excluded ?? [])).isEmpty }) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.bar)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle("Deletion queue")
            .toolbar { Button("Done") { dismiss() }.disabled(queue.deleting) }
            .interactiveDismissDisabled(queue.deleting)
            .alert("Deletion queue", isPresented: Binding(get: {queue.error != nil}, set: { if !$0 { queue.error = nil } })) { Button("OK") {} } message: { Text(queue.error ?? "") }
        }
    }
}

private struct QueuePhotoRow: View {
    let entry: DeletionEntry
    @ObservedObject var queue: DeletionQueue
    let libraries: [Library]
    let linkedPair: String
    @State private var image: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else { Image(systemName: "photo").foregroundStyle(.secondary) }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                if let remaining = entry.remaining {
                    Text("Pending: " + Set(remaining.map(\.source)).sorted().joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                } else if let found = entry.found, !entry.needsMatching(linkedPair) {
                    if entry.uncheckedMotion?.isEmpty == false {
                        Text("Immich still matches · motion unverified").font(.caption2).foregroundStyle(.secondary)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 4) { choices(found) }
                        VStack(alignment: .leading, spacing: 0) { choices(found) }
                    }
                } else {
                    Text(queue.matchFailures[entry.id] ?? "Checking libraries…").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button {
                queue.keep(entry, libraries: libraries)
            } label: {
                Text(entry.remaining == nil ? "Keep" : "Keep remaining")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Color.green.opacity(0.14), in: Capsule())
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .fixedSize()
            .buttonStyle(.plain)
            .foregroundStyle(.green)
            .accessibilityHint("Remove this photo from the deletion queue")
            .disabled(queue.deleting)
        }
        .task(id: entry.id) { image = await queue.thumbnail(entry, libraries: libraries) }
    }

    @ViewBuilder private func choices(_ found: Set<QueueTarget>) -> some View {
        ForEach(Set(found.map(\.source)).sorted(), id: \.self) { source in
            let selected = found.contains { $0.source == source && entry.excluded?.contains($0) != true }
            Button {
                queue.setSelected(!selected, source: source, entryID: entry.id)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    Text(source == "Apple Photos" ? "Apple" : source == "Synology Photos" ? "Synology" : source)
                }
                .font(.caption.weight(.medium))
                .fixedSize()
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08), in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .accessibilityLabel(source)
            .accessibilityValue(selected ? "Selected" : "Not selected")
            .disabled(queue.deleting)
        }
    }
}
