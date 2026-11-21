import AVFoundation
import Photos
import UIKit
import ImageIO
import UniformTypeIdentifiers

enum PhotoSource: String, CaseIterable {
    case immich = "Immich", apple = "Apple Photos", synology = "Synology Photos"
}

enum AppleLibrary {
    static func authorize() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw Failure(message: "Allow photo library access for PicSwype in Settings.")
        }
    }

    static func reviewAssets() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType IN %@", [PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue])
        return PHAsset.fetchAssets(with: options)
    }

    static func images() async -> [Asset] {
        await Task.detached {
            let result = reviewAssets()
            var images: [Asset] = []
            result.enumerateObjects { photo, _, _ in
                images.append(Asset(id: photo.localIdentifier, type: photo.mediaType == .video ? "VIDEO" : "IMAGE"))
            }
            return images.shuffled()
        }.value
    }

    static func preview(_ id: String) async throws -> UIImage {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw Failure(message: "This photo is no longer accessible. Refresh the library to continue.")
        }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 1440, height: 1440),
                                                  contentMode: .aspectFit, options: options) { image, info in
                if info?[PHImageResultIsDegradedKey] as? Bool == true { return }
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: (info?[PHImageErrorKey] as? Error) ?? Failure(message: "Photos could not load the preview.")) }
            }
        }
    }

    static func delete(_ ids: Set<String>) async throws {
        let photos = PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: nil)
        guard photos.count == ids.count else { throw Failure(message: "Some marked photos are unavailable. Refresh the library and try again.") }
        try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(photos) }
    }
}

final class NASFolder {
    let root: URL
    private let scoped: Bool

    init(_ url: URL) {
        root = url
        scoped = url.startAccessingSecurityScopedResource()
    }

    deinit { if scoped { root.stopAccessingSecurityScopedResource() } }

    func images() async throws -> [Asset] {
        try await Task.detached { try self.scan() }.value
    }

    private func scan() throws -> [Asset] {
            var scanError: Error?
            guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in scanError = error; return false }) else {
                throw Failure(message: "Files could not open this folder. Reconnect to the NAS and select it again.")
            }
            var images: [Asset] = []
            for case let file as URL in walk {
                if ["#recycle", "@eaDir", "#snapshot"].contains(file.lastPathComponent) { walk.skipDescendants(); continue }
                guard let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image) || type.conforms(to: .movie),
                      try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                images.append(Asset(id: file.path, type: type.conforms(to: .movie) ? "VIDEO" : "IMAGE", originalFileName: file.lastPathComponent))
            }
            if let scanError { throw scanError }
            return images.shuffled()
    }

    func trash(_ path: String, date: Date) throws {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().standardizedFileURL.path + "/"),
              try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == date else {
            throw Failure(message: "The queued file changed. Review it again.")
        }
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    func preview(_ path: String) async throws -> UIImage {
        let file = URL(fileURLWithPath: path)
        if UTType(filenameExtension: file.pathExtension)?.conforms(to: .movie) == true {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1440, height: 1440)
            return UIImage(cgImage: try await generator.image(at: .zero).image)
        }
        return try await Task.detached {
            var coordinationError: NSError?
            var thumbnail: CGImage?
            NSFileCoordinator().coordinate(readingItemAt: URL(fileURLWithPath: path), options: [], error: &coordinationError) { url in
                if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                    thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1440
                    ] as CFDictionary)
                }
            }
            if let coordinationError { throw coordinationError }
            guard let thumbnail else { throw Failure(message: "Files could not load this NAS photo.") }
            return UIImage(cgImage: thumbnail)
        }.value
    }
}
