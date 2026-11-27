import SwiftUI
import UniformTypeIdentifiers

struct LibrarySettings: View {
    @ObservedObject var apple: Library
    @ObservedObject var immich: Library
    @ObservedObject var nas: Library
    @Binding var linkedPair: String
    let pendingReceipt: Bool
    @ObservedObject var active: Library
    @Environment(\.dismiss) private var dismiss
    @State private var editing: PhotoSource?
    @State private var preparing = false
    @State private var failure: String?
    @State private var showAbout = false
    @State private var showQueue = false
    @State private var restart = false
    @State private var selection: Set<PhotoSource>?

    private var eligible: Set<PhotoSource> {
        var result: Set<PhotoSource> = [.apple]
        if immich.isConfigured { result.insert(.immich) }
        if nas.isConfigured && UserDefaults.standard.bool(forKey: "PicSwype.directNAS") { result.insert(.synology) }
        return result
    }

    private var selected: Set<PhotoSource> {
        selection ?? LibraryLink(saved: linkedPair)?.sources ?? eligible
    }

    private func enable(_ sources: Set<PhotoSource>) async {
        guard !preparing else { return }
        guard !pendingReceipt, let link = LibraryLink.allCases.first(where: { $0.sources == sources }) else {
            failure = "Finish any pending linked deletion and select at least two libraries."
            return
        }
        preparing = true
        defer { preparing = false }
        if sources.contains(.immich), !immich.connected { await immich.connect() }
        if sources.contains(.synology), !nas.connected, let saved = nas.savedNAS {
            await nas.signInNAS(address: saved.address, username: saved.username, password: "", otp: "", saved: saved)
        }
        if sources.contains(.apple), !apple.connected { await apple.connect() }
        guard let id = link.identity(immich: immich, nas: nas), !sources.contains(.apple) || apple.connected else {
            failure = "Open the selected connections and check their access, then try again."
            return
        }
        linkedPair = id
        selection = sources
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Connections") {
                    LabeledContent("Apple Photos", value: apple.connected ? "Connected" : "On device")
                    ForEach([PhotoSource.immich, .synology], id: \.self) { source in
                        let model = source == .immich ? immich : nas
                        Button { editing = source } label: {
                            HStack {
                                Label(model.isConfigured ? source.rawValue : "Add " + source.rawValue,
                                      systemImage: model.isConfigured ? "externaldrive" : "plus.circle")
                                Spacer()
                                if model.isConfigured {
                                    Text(model.connected ? "Connected" : "Saved").foregroundStyle(.secondary)
                                }
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    Toggle("Link libraries", isOn: Binding(get: { !linkedPair.isEmpty }, set: { on in
                        if on { Task { await enable(selected) } }
                        else { linkedPair = ""; selection = nil }
                    })).disabled(preparing || (linkedPair.isEmpty && selected.count < 2))
                    if eligible.count == 3 {
                        ForEach(PhotoSource.allCases, id: \.self) { source in
                            Button {
                                var next = selected
                                if next.contains(source) { next.remove(source) } else { next.insert(source) }
                                if linkedPair.isEmpty { selection = next }
                                else if next.count >= 2 { Task { await enable(next) } }
                            } label: {
                                Label(source.rawValue, systemImage: selected.contains(source) ? "checkmark.circle.fill" : "circle")
                            }
                            .disabled(preparing || (!linkedPair.isEmpty && selected.count == 2 && selected.contains(source)))
                        }
                    }
                    if preparing { ProgressView("Connecting libraries…") }
                } header: { Text("Photo matching") } footer: {
                    Text(eligible.count < 2 ? "Add an Immich or Synology Photos server to match queued photos across libraries." : "Queued photos are checked for copies in the linked libraries. Choose which copies to delete in the queue.")
                }
                Section("Review") {
                    Button("Deletion queue") { showQueue = true }
                    Button("Refresh " + active.source.rawValue) { Task { await active.connect() } }
                        .disabled(active.busy || !active.connected)
                    Button("Restart review") { restart = true }.disabled(active.busy || !active.connected)
                }
                Section {
                    Button("About PicSwype") { showAbout = true }
                    LicenseLink(title: "MIT License", resource: "LICENSE")
                } footer: {
                    Text(AboutView.copyright)
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(item: $editing) { source in
                ConnectionEditor(model: source == .immich ? immich : nas)
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .sheet(isPresented: $showQueue) {
            DeletionQueueView(queue: .shared, libraries: [immich, nas, apple], linkedPair: linkedPair)
        }
        .sheet(isPresented: $showAbout) { AboutView() }
        .confirmationDialog("Review previously seen photos again?", isPresented: $restart, titleVisibility: .visible) {
            Button("Restart review") { Task { await active.reload(reset: true) } }
        }
        .alert("Unable to link libraries", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") {}
        } message: { Text(failure ?? "") }
    }
}

private struct ConnectionEditor: View {
    @ObservedObject var model: Library
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var username = ""
    @State private var secret = ""
    @State private var otp = ""
    @State private var choosingFolder = false
    @State private var failure: String?

    var body: some View {
        Form {
            Section("Server") {
                TextField(model.source == .immich ? "Immich server URL" : "DSM URL or QuickConnect ID", text: $address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if model.source == .synology {
                    TextField("DSM username", text: $username).textContentType(.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                SecureField(model.source == .immich ? "API key" : "Password", text: $secret)
                if model.source == .synology {
                    TextField("Verification code (if required)", text: $otp).textContentType(.oneTimeCode)
                }
            }
            Section {
                Button("Connect") {
                    Task {
                        model.error = nil
                        if model.source == .immich {
                            model.server = address
                            model.key = secret
                            await model.connect()
                        } else {
                            await model.signInNAS(address: address.trimmingCharacters(in: .whitespacesAndNewlines),
                                                  username: username, password: secret, otp: otp)
                        }
                        finish()
                    }
                }
                .disabled(address.isEmpty || secret.isEmpty || (model.source == .synology && username.isEmpty))
                if model.busy { ProgressView("Connecting…") }
            } footer: {
                if model.source == .immich { Text("Use an Immich API key with permission to search, read originals, and move photos to trash.") }
            }
            if model.source == .synology { Button("Choose a folder in Files") { choosingFolder = true } }
            if let failure { Text(failure).foregroundStyle(.red) }
        }
        .disabled(model.busy)
        .navigationTitle(model.source.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if model.source == .immich { address = model.server; secret = model.key }
            else if let saved = model.savedNAS { address = saved.address; username = saved.username }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            do {
                let url = try result.get()
                model.selectFolder(url)
                let data = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(data, forKey: "PicSwype.NASFolder")
                model.error = nil
                Task { await model.connect(); finish() }
            } catch { failure = error.localizedDescription }
        }
    }

    private func finish() {
        if let error = model.error { failure = error; model.error = nil }
        else if model.connected { dismiss() }
    }
}
