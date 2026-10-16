import SwiftUI

/// Every thought dump, newest first, each with a bar of how its thoughts are getting on.
struct DumpListView: View {
    @Environment(AppModel.self) private var model
    var onRecord: () -> Void

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            if !model.outbox.isEmpty {
                Section("Not sent yet") {
                    ForEach(model.outbox) { note in
                        HStack {
                            Image(systemName: "paperplane").foregroundStyle(.orange)
                            Text(note.text).lineLimit(2).font(.callout)
                        }
                        .tag("pending:\(note.id)")
                    }
                }
            }
            Section {
                ForEach(model.dumps) { dump in
                    DumpRow(dump: dump).tag(dump.id)
                }
            } header: {
                connection
            }
        }
        .navigationTitle("Thought Dump")
        .overlay {
            if model.dumps.isEmpty && model.outbox.isEmpty {
                ContentUnavailableView("No thought dumps yet", systemImage: "text.bubble",
                                       description: Text("Tap the microphone and say what's on your mind."))
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: onRecord) {
                Label("New thought dump", systemImage: "mic.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding()
            .background(.bar)
        }
        .toolbar {
            Menu {
                if let url = model.serverURL { Text(url.host() ?? url.absoluteString) }
                Button("Unpair this Mac", role: .destructive) { model.unpair() }
            } label: {
                Image(systemName: "desktopcomputer")
            }
        }
        .refreshable { await model.refresh() }
        .task {
            while !Task.isCancelled {
                await model.refresh()
                let busy = model.dumps.contains { $0.isActive } || !model.outbox.isEmpty
                try? await Task.sleep(for: .seconds(busy ? 3 : 20))
            }
        }
    }

    @ViewBuilder
    private var connection: some View {
        switch model.connection {
        case .connected: Label("Connected to your Mac", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .checking: Label("Connecting…", systemImage: "arrow.triangle.2.circlepath")
        case .offline: Label("Mac not reachable: notes wait here", systemImage: "wifi.exclamationmark").foregroundStyle(.orange)
        case .unpaired: Label("Not paired", systemImage: "link")
        }
    }
}

struct DumpRow: View {
    var dump: Dump

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: dump.phase.symbol)
                    .foregroundStyle(dump.phase.color)
                    .symbolEffect(.pulse, isActive: dump.isActive)
                Text(dump.created, format: .relative(presentation: .named))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(dump.tasks.isEmpty ? dump.phase.label : "\(dump.tasks.count) thoughts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(preview)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if !dump.tasks.isEmpty {
                BucketBar(dump: dump)
            }
        }
        .padding(.vertical, 4)
    }

    private var preview: String {
        let titles = dump.tasks.prefix(3).map(\.title)
        return titles.isEmpty ? dump.text : titles.joined(separator: " · ")
    }
}
