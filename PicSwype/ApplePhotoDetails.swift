import SwiftUI
import Photos
import MapKit
import UniformTypeIdentifiers

/// iOS has no supported way to open Apple Photos at a specific photo, so PicSwype shows the
/// photo's details itself and offers the original file through the share sheet.
struct ApplePhotoDetails {
    var isVideo: Bool
    var filename: String?
    var created: Date?
    var modified: Date?
    var size: CGSize
    var location: CLLocationCoordinate2D?
    var albums: [String]
    var favorite: Bool
    var hidden: Bool
    var kinds: [String]

    static func load(_ id: String) async throws -> ApplePhotoDetails {
        try await Task.detached {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
                throw Failure(message: "This photo is no longer accessible.")
            }
            var albums: [String] = []
            for type in [PHAssetCollectionType.album, .smartAlbum] {
                PHAssetCollection.fetchAssetCollectionsContaining(asset, with: type, options: nil).enumerateObjects { album, _, _ in
                    if let title = album.localizedTitle, !title.isEmpty, album.assetCollectionSubtype != .smartAlbumUserLibrary {
                        albums.append(title)
                    }
                }
            }
            var kinds: [String] = asset.mediaType == .video ? ["Video"] : []
            let subtypes = asset.mediaSubtypes
            if subtypes.contains(.photoLive) { kinds.append("Live Photo") }
            if subtypes.contains(.photoScreenshot) { kinds.append("Screenshot") }
            if subtypes.contains(.photoPanorama) { kinds.append("Panorama") }
            if subtypes.contains(.photoHDR) { kinds.append("HDR") }
            if subtypes.contains(.photoDepthEffect) { kinds.append("Portrait") }
            if asset.burstIdentifier != nil { kinds.append("Burst") }
            let resources = PHAssetResource.assetResources(for: asset)
            if resources.contains(where: { $0.type == .fullSizePhoto || $0.type == .fullSizeVideo }) { kinds.append("Edited") }
            let original = resources.first { $0.type == .photo || $0.type == .video } ?? resources.first
            return ApplePhotoDetails(
                isVideo: asset.mediaType == .video,
                filename: original?.originalFilename,
                created: asset.creationDate,
                modified: asset.modificationDate,
                size: CGSize(width: asset.pixelWidth, height: asset.pixelHeight),
                location: asset.location?.coordinate,
                albums: Array(Set(albums)).sorted(),
                favorite: asset.isFavorite,
                hidden: asset.isHidden,
                kinds: kinds)
        }.value
    }
}

/// Shares the full-quality photo (the edited version when there is one), exported on demand.
struct ApplePhotoFile: Transferable {
    let id: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .image) { SentTransferredFile(try await $0.export()) }
    }

    func export() async throws -> URL {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw Failure(message: "This photo is no longer accessible.")
        }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .fullSizePhoto || $0.type == .fullSizeVideo })
                ?? resources.first(where: { $0.type == .photo || $0.type == .video }) ?? resources.first else {
            throw Failure(message: "Photos has no file for this photo.")
        }
        // Reuse one folder and clear the previous export, so shared originals don't pile up in tmp.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SharedOriginal", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(resource.originalFilename)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: options)
        return file
    }
}

private struct AppleVideoFile: Transferable {
    let id: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .movie) { SentTransferredFile(try await ApplePhotoFile(id: $0.id).export()) }
    }
}

struct ApplePhotoInfoButton: View {
    let id: String
    let title: String
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: { Label(title, systemImage: "info.circle") }
            .sheet(isPresented: $showing) { ApplePhotoDetailsView(id: id) }
    }
}

struct ApplePhotoDetailsView: View {
    let id: String
    @State private var details: ApplePhotoDetails?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let details { form(details) }
                else if let error { ContentUnavailableView("Details Unavailable", systemImage: "photo", description: Text(error)) }
                else { ProgressView() }
            }
            .navigationTitle(details?.isVideo == true ? "Video Details" : "Photo Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if details != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        if details?.isVideo == true {
                            ShareLink(item: AppleVideoFile(id: id), preview: SharePreview(details?.filename ?? "Video"))
                        } else {
                            ShareLink(item: ApplePhotoFile(id: id), preview: SharePreview(details?.filename ?? "Photo"))
                        }
                    }
                }
            }
        }
        .task {
            do { details = try await ApplePhotoDetails.load(id) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func form(_ details: ApplePhotoDetails) -> some View {
        Form {
            Section {
                row("Filename", details.filename ?? "Unknown")
                if let created = details.created { row("Taken", created.formatted(date: .long, time: .shortened)) }
                if let modified = details.modified, modified != details.created {
                    row("Modified", modified.formatted(date: .long, time: .shortened))
                }
                row("Size", "\(Int(details.size.width)) × \(Int(details.size.height)) · " + megapixels(details.size))
                if !details.kinds.isEmpty { row("Type", details.kinds.joined(separator: ", ")) }
                if details.favorite { row("Favorite", "Yes") }
                if details.hidden { row("Hidden", "Yes") }
            }
            if !details.albums.isEmpty {
                Section("Albums") { ForEach(details.albums, id: \.self) { Text($0) } }
            }
            if let location = details.location {
                Section("Location") {
                    Map(initialPosition: .region(MKCoordinateRegion(center: location, latitudinalMeters: 1500, longitudinalMeters: 1500))) {
                        Marker("", coordinate: location)
                    }
                    .frame(height: 180)
                    .listRowInsets(EdgeInsets())
                    Text(String(format: "%.5f, %.5f", location.latitude, location.longitude))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).textSelection(.enabled) }
    }

    private func megapixels(_ size: CGSize) -> String {
        String(format: "%.1f MP", size.width * size.height / 1_000_000)
    }
}
