import SwiftUI

/// First run: connect to the Mac that does the work.
struct PairView: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var link = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "text.bubble.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.indigo.gradient)
                        Text("Say what's on your mind. Your Mac finds the separate thoughts, does the work it can, drafts what involves other people, and puts the rest on your list.")
                            .font(.callout)
                    }
                    .padding(.vertical, 6)
                }
                Section {
                    TextField("my-mac.tailnet.ts.net:8783", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("Connect") {
                        Task { await model.pair(address: normalised(address)) }
                    }
                    .disabled(address.isEmpty || model.connection == .checking)
                } header: {
                    Text("On your tailnet")
                } footer: {
                    Text("The Mac recognises your Tailscale login and hands this app its key.")
                }
                Section {
                    TextField("thoughtdump://pair?…", text: $link, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Use this link") {
                        if let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) { model.open(url) }
                    }
                    .disabled(link.isEmpty)
                } header: {
                    Text("Or with a link")
                } footer: {
                    Text("Run `dump pair` on the Mac and open the link it prints on this device.")
                }
                if model.connection == .checking {
                    Section { HStack { ProgressView(); Text("Connecting…") } }
                }
                if let error = model.lastError {
                    Section { Text(error).foregroundStyle(.red).font(.callout) }
                }
            }
            .navigationTitle("Connect your Mac")
        }
    }

    private func normalised(_ text: String) -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: trimmed.contains("://") ? trimmed : "https://" + trimmed) ?? URL(string: "https://invalid")!
    }
}
