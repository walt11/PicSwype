import AVKit
import CryptoKit
import Photos
import SwiftUI
import UniformTypeIdentifiers
import ZIPFoundation

/// Owns a downloaded original for the lifetime of playback or verification.
final class DownloadedMovie {
    let url: URL

    init(download: URL, filename: String, unpack: Bool = false) throws {
        let ext = (filename as NSString).pathExtension
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext.isEmpty ? "mov" : ext)
        if unpack {
            let handle = try FileHandle(forReadingFrom: download)
            defer { try? handle.close() }
            if try handle.read(upToCount: 4) == Data([0x50, 0x4b, 0x03, 0x04]) {
                let archive = try Archive(url: download, accessMode: .read)
                let entries = archive.filter { $0.type == .file && !$0.path.hasPrefix("__MACOSX/") }
                guard entries.count == 1, let movie = entries.first,
                      (movie.path as NSString).lastPathComponent == filename else {
                    throw Failure(message: "Synology did not return the requested video.")
                }
                do {
                    let crc = try archive.extract(movie, to: url)
                    guard crc == movie.checksum else { throw Failure(message: "Incomplete video download.") }
                } catch { try? FileManager.default.removeItem(at: url); throw error }
                return
            }
        }
        try FileManager.default.moveItem(at: download, to: url)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func fingerprint() async throws -> LinkedPhoto.Fingerprint {
        let video = AVURLAsset(url: url)
        guard let track = try await video.loadTracks(withMediaType: .video).first else {
            throw Failure(message: "The library returned an unreadable video.")
        }
        let size = try await track.load(.naturalSize)
        let taken = try? await video.load(.creationDate)?.load(.dateValue)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha = SHA256(), search = Insecure.SHA1(), count = 0
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            sha.update(data: chunk)
            search.update(data: chunk)
            count += chunk.count
        }
        guard count > 0 else { throw Failure(message: "The library returned an empty video.") }
        return .init(digest: Data(sha.finalize()), searchChecksum: Data(search.finalize()).base64EncodedString(),
                     count: count, dimensions: .init(Int(size.width), Int(size.height)), isVideo: true, taken: taken)
    }
}

struct VideoReview: View {
    let asset: Asset
    let library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var download: DownloadedMovie?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Group {
                if let failure { ContentUnavailableView("Video unavailable", systemImage: "video.slash", description: Text(failure)) }
                else if let player { VideoPlayer(player: player) }
                else { ProgressView("Loading video…") }
            }
            .navigationTitle("Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task {
            do {
                let item: AVPlayerItem
                if library.source == .apple {
                    guard let photo = PHAsset.fetchAssets(withLocalIdentifiers: [asset.id], options: nil).firstObject else {
                        throw Failure(message: "This video is no longer accessible.")
                    }
                    let options = PHVideoRequestOptions()
                    options.isNetworkAccessAllowed = true
                    item = try await withCheckedThrowingContinuation { continuation in
                        PHImageManager.default().requestPlayerItem(forVideo: photo, options: options) { item, info in
                            if let item { continuation.resume(returning: item) }
                            else { continuation.resume(throwing: info?[PHImageErrorKey] as? Error ?? Failure(message: "Photos could not load the video.")) }
                        }
                    }
                } else if let url = library.immichPlaybackURL(asset.id) {
                    // Immich serves playback with range requests, so the player can start before the whole file arrives.
                    item = AVPlayerItem(asset: AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["x-api-key": library.key]]))
                } else if library.folder != nil {
                    item = AVPlayerItem(url: URL(fileURLWithPath: asset.id))
                } else {
                    let file = try await library.downloadVideo(asset.id, filename: asset.originalFileName)
                    try Task.checkCancellation()
                    download = file
                    item = AVPlayerItem(url: file.url)
                }
                guard try await item.asset.load(.isPlayable) else { throw Failure(message: "This video format cannot be played on this device.") }
                try Task.checkCancellation()
                player = AVPlayer(playerItem: item)
                player?.play()
            } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
        .onDisappear { player?.pause(); player = nil; download = nil }
    }
}
