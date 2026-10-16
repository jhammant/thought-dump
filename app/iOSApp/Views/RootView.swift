import SwiftUI

/// History on the left (or the whole screen on iPhone), the selected dump on the right, and a
/// big button to start a new one.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var recording = false
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var model = model
        Group {
            if model.isPaired {
                NavigationSplitView(columnVisibility: $columns) {
                    DumpListView(onRecord: { recording = true })
                } detail: {
                    NavigationStack {
                        detail
                    }
                }
            } else {
                PairView()
            }
        }
        .sheet(isPresented: $recording) {
            NavigationStack {
                RecordView(startImmediately: true)
            }
            .presentationDetents([.large])
            .interactiveDismissDisabled()
        }
        .onChange(of: model.recordRequested) { _, requested in
            if requested && model.isPaired {
                recording = true
                model.recordRequested = false
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selection = model.selection {
            if selection.hasPrefix("pending:") {
                PendingView(clientID: String(selection.dropFirst("pending:".count)))
            } else {
                DumpDetailView(dumpID: selection)
            }
        } else {
            ContentUnavailableView {
                Label("Thought Dump", systemImage: "text.bubble")
            } description: {
                Text("Say what's on your mind. Your Mac splits it into thoughts and gets going on them.")
            } actions: {
                Button { recording = true } label: { Label("New thought dump", systemImage: "mic.fill") }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// A note that hasn't reached the Mac yet.
struct PendingView: View {
    var clientID: String
    @Environment(AppModel.self) private var model

    var body: some View {
        let note = model.outbox.first { $0.id == clientID }
        VStack(alignment: .leading, spacing: 16) {
            StageTrack(phase: .unknown)
            Label(note?.lastError == nil ? "Sending to your Mac…" : "Waiting for your Mac", systemImage: "paperplane")
                .font(.headline)
                .symbolEffect(.pulse)
            if let error = note?.lastError {
                Text("It's kept on this phone and goes as soon as the Mac answers. (\(error))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let note {
                Text(note.text).font(.callout).padding(12)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
                HStack {
                    Button("Try now") { Task { await model.flushOutbox() } }.buttonStyle(.borderedProminent)
                    Button("Discard", role: .destructive) { model.discard(note) }.buttonStyle(.bordered)
                }
            }
            Spacer()
        }
        .padding()
        .navigationTitle("Not sent yet")
    }
}
