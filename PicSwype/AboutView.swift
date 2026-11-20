import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Copyright © 2026 John Walter")
                    Link("Privacy policy", destination: URL(string: "https://github.com/walt11/PicSwype/blob/main/docs/index.md")!)
                }
                Section("Licenses") {
                    notice("PicSwype", resource: "LICENSE", extension: nil)
                    notice("ZIPFoundation", resource: "ZIPFoundation-LICENSE", extension: "txt")
                }
            }
            .navigationTitle("About PicSwype")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func notice(_ title: String, resource: String, extension ext: String?) -> some View {
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
