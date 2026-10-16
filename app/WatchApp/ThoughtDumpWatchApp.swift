import SwiftUI

@main
struct ThoughtDumpWatchApp: App {
    @State private var link = WatchLink.shared

    init() {
        WatchLink.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                WatchHome()
            }
            .environment(link)
        }
    }
}

/// One big button to dictate, then the latest dumps and how their thoughts are getting on.
struct WatchHome: View {
    @Environment(WatchLink.self) private var link

    var body: some View {
        List {
            Section {
                TextFieldLink(prompt: Text("What's on your mind?")) {
                    VStack(spacing: 4) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 28, weight: .bold))
                        Text("Thought dump").font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                } onSubmit: { text in
                    link.send(text)
                }
                .listRowBackground(RoundedRectangle(cornerRadius: 22).fill(Color.indigo.gradient))
                if let sent = link.lastSent, Date().timeIntervalSince(sent) < 120 {
                    Label("Sent to your iPhone", systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
            }
            Section("Recent") {
                if link.dumps.isEmpty {
                    Text("Your dumps appear here once your iPhone has sent one.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(link.dumps) { dump in
                    NavigationLink {
                        WatchDumpView(dump: dump)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Image(systemName: dump.phase.symbol).foregroundStyle(dump.phase.color)
                                Text(dump.created, format: .relative(presentation: .named))
                                    .font(.footnote.weight(.semibold))
                            }
                            Text(dump.thoughts.isEmpty ? dump.phase.label : "\(dump.thoughts.count) thoughts · \(handled(dump)) handled")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Thought Dump")
    }

    private func handled(_ dump: WatchDump) -> Int {
        dump.thoughts.filter { [.completed, .drafted, .onTodo, .forYou, .skipped, .stopped].contains($0.status) }.count
    }
}

struct WatchDumpView: View {
    var dump: WatchDump

    var body: some View {
        List(dump.thoughts) { thought in
            HStack(spacing: 8) {
                Image(systemName: thought.route.symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(thought.route.color, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(thought.title).font(.footnote).lineLimit(2)
                    Label(thought.status == .pending ? thought.route.label : thought.status.label, systemImage: thought.status.symbol)
                        .font(.caption2)
                        .foregroundStyle(thought.status.color)
                }
            }
        }
        .navigationTitle(dump.phase.label)
    }
}
