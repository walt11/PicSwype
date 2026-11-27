import Foundation
import Photos

/// Resource metadata narrows the search. Only an original-file digest can establish a match.
actor AppleMatchIndex {
    static let shared = AppleMatchIndex()

    enum Bucket: Hashable, Codable {
        case size(Int, Bool)
        case pixels(LinkedPhoto.Dimensions, Bool)
        case unknown(Bool)

        var cacheName: String {
            switch self {
            case .size(let bytes, let video): return (video ? "video-" : "") + "size-\(bytes)"
            case .pixels(let d, let video): return (video ? "video-" : "") + "pixels-\(d.short)-\(d.long)"
            case .unknown(let video): return video ? "video-unknown" : "unknown"
            }
        }
    }

    private struct Candidate {
        let id: String
        let modified: Date?
        let created: Date?
    }
    /// Bucket per asset, saved so launches only query resources for new or changed assets.
    private struct Indexed: Codable {
        let modified: Date?
        let bucket: Bucket?
    }
    private struct Cached: Codable {
        let modified: Date
        let digest: Data
    }
    private final class Observer: NSObject, PHPhotoLibraryChangeObserver {
        let changes: AsyncStream<PHChange>.Continuation
        init(_ changes: AsyncStream<PHChange>.Continuation) { self.changes = changes }
        func photoLibraryDidChange(_ change: PHChange) { changes.yield(change) }
    }
    private var observer: Observer?
    private var fetched: PHFetchResult<PHAsset>?
    private var bucketForID: [String: Bucket] = [:]
    private var generation = 0
    private var verifiedIDs: [Bucket: [Data: [String]]] = [:]
    private var buckets: [Bucket: [String: Candidate]] = [:]
    private var cache = [Bucket: [String: Cached]]()
    private let directory = URL.cachesDirectory.appending(path: "AppleOriginalDigests-v1")
    private var saved: [String: Indexed] = [:]
    private var indexFile: URL {
        let sizes: Bool
        if #available(iOS 27, *) { sizes = true } else { sizes = false }
        return directory.appending(path: sizes ? "index-sizes.plist" : "index-pixels.plist")
    }

    deinit {
        if let observer {
            PHPhotoLibrary.shared().unregisterChangeObserver(observer)
            observer.changes.finish()
        }
    }

    private func insert(_ asset: PHAsset) {
        let id = asset.localIdentifier
        let bucket: Bucket?
        if let known = saved[id], known.modified == asset.modificationDate {
            bucket = known.bucket
        } else {
            bucket = Self.bucket(for: asset)
            saved[id] = Indexed(modified: asset.modificationDate, bucket: bucket)
        }
        guard let bucket else { return }
        buckets[bucket, default: [:]][id] = Candidate(id: id, modified: asset.modificationDate, created: asset.creationDate)
        bucketForID[id] = bucket
        verifiedIDs[bucket] = nil
    }

    private static func bucket(for asset: PHAsset) -> Bucket? {
        let resources = PHAssetResource.assetResources(for: asset)
        guard resources.count == 1, let resource = resources.first, resource.type == .photo || resource.type == .video else { return nil }
        let video = resource.type == .video
        if #available(iOS 27, *), let bytes = resource.dataSize, bytes > 0 { return .size(bytes, video) }
        if let pixels = LinkedPhoto.Dimensions(resource.pixelWidth, resource.pixelHeight) { return .pixels(pixels, video) }
        return .unknown(video)
    }

    private func saveIndex() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? PropertyListEncoder().encode(saved).write(to: indexFile, options: .atomic)
    }

    private func remove(_ id: String) {
        saved[id] = nil
        guard let key = bucketForID.removeValue(forKey: id) else { return }
        buckets[key]?[id] = nil
        if buckets[key]?.isEmpty == true { buckets[key] = nil }
        verifiedIDs[key] = nil
        cache[key]?[id] = nil
    }

    private func apply(_ change: PHChange) {
        guard let fetched, let details = change.changeDetails(for: fetched) else { return }
        self.fetched = details.fetchResultAfterChanges
        if details.hasIncrementalChanges {
            update(removed: details.removedObjects, changed: details.changedObjects, inserted: details.insertedObjects)
        } else {
            generation += 1
            rebuild(details.fetchResultAfterChanges)
        }
    }

    func update(removed: [PHAsset], changed: [PHAsset], inserted: [PHAsset]) {
        guard !removed.isEmpty || !changed.isEmpty || !inserted.isEmpty else { return }
        generation += 1
        for asset in removed { remove(asset.localIdentifier) }
        for asset in changed {
            remove(asset.localIdentifier)
            insert(asset)
        }
        for asset in inserted { insert(asset) }
        saveIndex()
    }

    private func rebuild(_ assets: PHFetchResult<PHAsset>) {
        fetched = assets
        buckets.removeAll()
        bucketForID.removeAll()
        verifiedIDs.removeAll()
        cache.removeAll()
        let previous = saved
        saved = [:]
        for i in 0..<assets.count {
            autoreleasepool {
                let asset = assets.object(at: i)
                if let known = previous[asset.localIdentifier] { saved[asset.localIdentifier] = known }
                insert(asset)
            }
        }
        saveIndex()
    }

    func prepare() {
        guard fetched == nil else { return }
        let (stream, continuation) = AsyncStream<PHChange>.makeStream()
        let listener = Observer(continuation)
        PHPhotoLibrary.shared().register(listener)
        observer = listener
        Task { [weak self] in
            for await change in stream { await self?.apply(change) }
        }
        if let data = try? Data(contentsOf: indexFile) {
            saved = (try? PropertyListDecoder().decode([String: Indexed].self, from: data)) ?? [:]
        }
        rebuild(AppleLibrary.reviewAssets())
    }

    func matches(_ original: LinkedPhoto.Fingerprint) async throws -> [String] {
        prepare()
        while true {
            try Task.checkCancellation()
            let snapshot = generation
            do {
                let ids = try await lookup(original, snapshot: snapshot)
                if snapshot == generation { return ids }
            } catch where snapshot != generation {
                continue
            }
        }
    }

    private func lookup(_ original: LinkedPhoto.Fingerprint, snapshot: Int) async throws -> [String] {
        var keys: [Bucket] = [.size(original.count, original.isVideo), .unknown(original.isVideo)]
        if let dimensions = original.dimensions { keys.append(.pixels(dimensions, original.isVideo)) }
        else {
            keys += buckets.keys.filter { if case .pixels(_, let video) = $0 { return video == original.isVideo }; return false }
        }
        var matches: [String] = []
        for key in keys {
            guard var candidates = buckets[key].map({ Array($0.values) }) else { continue }
            if let verified = verifiedIDs[key] {
                matches += verified[original.digest, default: []]
                continue
            }
            // Same-size buckets are tiny. Pixel buckets can hold most of a library, so only hash
            // originals taken around the same time. A missed match leaves a copy, never deletes one.
            var complete = true
            if case .size = key {} else if let taken = original.taken {
                let window: TimeInterval = original.takenIsExact ? 5 * 60 : 15 * 60 * 60
                candidates = candidates.filter { $0.created.map { abs($0.timeIntervalSince(taken)) <= window } ?? true }
                complete = false
            }
            let file = directory.appending(path: key.cacheName)
            // Exact-size buckets are usually tiny. Avoid a cache file per photo.
            let persist = candidates.count > 1
            let known = cache[key] ?? (persist ? read(file) : [:])
            if cache[key] == nil { cache[key] = known }
            var additions: [String: Cached] = [:]
            defer {
                if generation == snapshot && !additions.isEmpty {
                    cache[key, default: [:]].merge(additions) { _, latest in latest }
                    if persist, let merged = cache[key] {
                        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try? PropertyListEncoder().encode(merged).write(to: file, options: .atomic)
                    }
                }
            }
            var byDigest: [Data: [String]] = [:]
            var pending: [Candidate] = []
            for item in candidates {
                if let saved = known[item.id], saved.modified == item.modified {
                    byDigest[saved.digest, default: []].append(item.id)
                } else { pending.append(item) }
            }
            var iterator = pending.makeIterator()
            try await withThrowingTaskGroup(of: (Candidate, Data?).self) { group in
                func enqueue(_ item: Candidate) {
                    group.addTask {
                        try Task.checkCancellation()
                        return (item, try await AppleOriginal.fingerprint(item.id)?.digest)
                    }
                }
                for _ in 0..<min(4, pending.count) {
                    if let item = iterator.next() { enqueue(item) }
                }
                while let (item, digest) = try await group.next() {
                    if let digest {
                        byDigest[digest, default: []].append(item.id)
                        if let modified = item.modified {
                            additions[item.id] = Cached(modified: modified, digest: digest)
                        }
                    }
                    if let next = iterator.next() { enqueue(next) }
                }
            }
            if generation == snapshot && complete { verifiedIDs[key] = byDigest }
            matches += byDigest[original.digest, default: []]
        }
        return matches
    }

    private func read(_ file: URL) -> [String: Cached] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? PropertyListDecoder().decode([String: Cached].self, from: data)) ?? [:]
    }
}
