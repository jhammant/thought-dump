import SwiftUI

/// One dump: what it found and how each thought is being handled, live.
struct DumpDetailView: View {
    var dumpID: String
    @Environment(AppModel.self) private var model
    @State private var focused: String?

    private var dump: Dump? { model.details[dumpID] ?? model.dumps.first { $0.id == dumpID } }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let dump {
                    VStack(alignment: .leading, spacing: 18) {
                        header(dump)
                        StageTrack(phase: dump.phase)
                            .padding(.vertical, 4)
                        if dump.phase == .planned, let start = dump.startDate {
                            countdown(dump, start: start)
                        }
                        if dump.phase == .failed {
                            failure(dump)
                        }
                        FlowDiagram(dump: dump) { thought in
                            withAnimation { proxy.scrollTo(thought.id, anchor: .top) }
                            focused = thought.id
                        }
                        .padding(.vertical, 4)
                        sections(dump)
                        note(dump)
                    }
                    .padding()
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                } else {
                    ProgressView().padding(.top, 80)
                }
            }
        }
        .navigationTitle(dump.map { $0.created.formatted(date: .abbreviated, time: .shortened) } ?? "Thought dump")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let link = dump?.pageUrl, let url = URL(string: link), !link.isEmpty {
                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
            }
        }
        .refreshable { await model.refresh(dumpID) }
        .task(id: dumpID) {
            // Live while anything is happening; a slow check-in once it's settled.
            while !Task.isCancelled {
                let current = await model.refresh(dumpID)
                try? await Task.sleep(for: .seconds(current?.isActive == false ? 15 : 1.5))
            }
        }
    }

    private func header(_ dump: Dump) -> some View {
        HStack(alignment: .center, spacing: 16) {
            ProgressRing(dump: dump)
                .frame(width: 86, height: 86)
            VStack(alignment: .leading, spacing: 6) {
                Label(dump.phase.label, systemImage: dump.phase.symbol)
                    .font(.headline)
                    .foregroundStyle(dump.phase.color)
                Text(summary(dump))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(Route.allCases, id: \.self) { route in
                        let count = dump.tasks.filter { $0.route == route }.count
                        if count > 0 { Chip(text: "\(count)", symbol: route.symbol, color: route.color) }
                    }
                    let known = Set(dump.tasks.flatMap(\.found).map(\.id)).count
                    if known > 0 { Chip(text: "\(known)", symbol: "person.crop.circle.badge.checkmark", color: .teal) }
                }
                if dump.contextState == "looking" {
                    Label("Looking up who's mentioned…", systemImage: "person.text.rectangle")
                        .font(.caption)
                        .foregroundStyle(.teal)
                        .symbolEffect(.pulse)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func summary(_ dump: Dump) -> String {
        switch dump.phase {
        case .splitting: return "Reading your note on the Mac…"
        case .failed: return "The note is safe; try again."
        default:
            let count = dump.tasks.count
            return "Found \(count) thought\(count == 1 ? "" : "s")"
                + (dump.client?.device.map { " · from \($0)" } ?? "")
        }
    }

    private func countdown(_ dump: Dump, start: Date) -> some View {
        HStack(spacing: 14) {
            CountdownRing(start: start)
            VStack(alignment: .leading, spacing: 3) {
                Text("Starting soon").font(.headline)
                Text("Change how any thought is handled, or skip it, before work begins.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Start now") { Task { await model.startNow(dump) } }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
        }
        .padding(12)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private func failure(_ dump: Dump) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Couldn't split this note", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)
            if !dump.error.isEmpty { Text(dump.error).font(.caption).foregroundStyle(.secondary) }
            Button("Try again") { Task { await model.retry(dump) } }
                .buttonStyle(.bordered)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func sections(_ dump: Dump) -> some View {
        let groups: [(String, String, [Thought])] = [
            ("For you", "Needs your money, accounts or a decision: on your list, not given to a worker.",
             dump.tasks.filter { $0.route == .todo }),
            ("Drafts", "Written for you to approve. Nothing is sent.", dump.tasks.filter { $0.route == .draft }),
            ("Doing it on your Mac", "Each in its own folder. Done means the worker finished, not that it's checked.",
             dump.tasks.filter { $0.route == .run }),
            ("Skipped", "", dump.tasks.filter { $0.route == .skip }),
        ]
        ForEach(groups, id: \.0) { title, note, thoughts in
            if !thoughts.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(title) · \(thoughts.count)").font(.title3.weight(.semibold))
                        if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
                    }
                    ForEach(thoughts) { thought in
                        ThoughtCard(thought: thought, dump: dump, highlighted: focused == thought.id)
                            .id(thought.id)
                    }
                }
            }
        }
    }

    private func note(_ dump: Dump) -> some View {
        DisclosureGroup("Your note") {
            Text(dump.text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }
}
