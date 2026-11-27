import SwiftUI

struct AboutView: View {
    static let copyright = "Copyright © 2026 John Walter (walt11)"

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(Self.copyright)
                    Link("Privacy policy", destination: URL(string: "https://walt11.github.io/PicSwype/privacy/")!)
                    Link("Support", destination: URL(string: "https://walt11.github.io/PicSwype/support/")!)
                }
                Section("Licenses") {
                    LicenseLink(title: "PicSwype", resource: "LICENSE")
                    LicenseLink(title: "ZIPFoundation", resource: "ZIPFoundation-LICENSE", ext: "txt")
                }
            }
            .navigationTitle("About PicSwype")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

struct LicenseLink: View {
    let title: String
    let resource: String
    var ext: String? = nil

    var body: some View {
        NavigationLink(title) {
            ScrollView {
                if let url = Bundle.main.url(forResource: resource, withExtension: ext),
                   let text = try? String(contentsOf: url, encoding: .utf8) {
                    Text(verbatim: text).textSelection(.enabled).padding()
                } else {
                    Text("The license could not be loaded.").padding()
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
