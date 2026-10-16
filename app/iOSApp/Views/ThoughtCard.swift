import SwiftUI

/// One thought: how it's handled (changeable before work starts), live status, and what came back.
struct ThoughtCard: View {
    var thought: Thought
    var dump: Dump
    var highlighted = false
    @Environment(AppModel.self) private var model
    @State private var showOutput = false
    @State private var copied = false

    private let budget: TimeInterval = 45 * 60

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: thought.route.symbol)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(thought.route.color.gradient, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(thought.title).font(.headline)
                    HStack(spacing: 5) {
                        Chip(text: thought.workspace)
                        Chip(text: thought.kind)
                        if let engine = thought.engine, engine != "fake" { Chip(text: engine == "codex" ? "Codex" : "Claude") }
                        if let cost = thought.costUsd { Chip(text: cost.formatted(.currency(code: "USD").precision(.fractionLength(2)))) }
                    }
                }
                Spacer(minLength: 0)
                control
            }
            status
            if let context = thought.context, !context.isEmpty {
                ContextStrip(items: context)
            }
            Text("“\(thought.quote)”")
                .font(.callout.italic())
                .foregroundStyle(.secondary)
                .lineLimit(showOutput ? nil : 2)
            if let error = thought.error, !error.isEmpty, thought.bucket == .problem || thought.status == .forYou {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            result
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(highlighted ? thought.route.color : .clear, lineWidth: 2)
        }
        .animation(.snappy, value: thought)
    }

    /// Before work starts: choose the route. While it waits or runs: stop it.
    @ViewBuilder
    private var control: some View {
        if dump.phase == .planned || (dump.phase == .working && thought.status == .pending) {
            Menu {
                ForEach(Route.allCases, id: \.self) { route in
                    Button {
                        Task { await model.setRoute(route, for: thought, in: dump) }
                    } label: {
                        Label(route.menuLabel + (route == thought.defaultRoute ? " (suggested)" : ""), systemImage: route.symbol)
                    }
                }
            } label: {
                Label(thought.route.label, systemImage: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(thought.route.color.opacity(0.15), in: Capsule())
                    .foregroundStyle(thought.route.color)
            }
        } else if thought.status == .running {
            Button(role: .destructive) {
                Task { await model.stop(thought, in: dump) }
            } label: {
                Label("Stop", systemImage: "stop.fill").font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var status: some View {
        if thought.status == .running, let started = thought.started {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let elapsed = timeline.date.timeIntervalSince(started)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label("Working", systemImage: "gearshape.2.fill")
                            .symbolEffect(.rotate, isActive: true)
                        Spacer()
                        Text(Duration.seconds(elapsed).formatted(.time(pattern: .minuteSecond)))
                            .monospacedDigit()
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.blue)
                    ProgressView(value: min(elapsed, budget), total: budget)
                        .tint(.blue)
                }
            }
        } else {
            HStack(spacing: 5) {
                Image(systemName: thought.status.symbol)
                Text(statusText)
                if let seconds = thought.elapsedSeconds, thought.route != .todo, thought.bucket == .settled || thought.bucket == .problem {
                    Text("· \(Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .narrow)))")
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(thought.status.color)
        }
    }

    private var statusText: String {
        if thought.status == .pending {
            return dump.phase == .planned ? "Will be: \(thought.route.menuLabel.lowercased())" : "Queued"
        }
        if thought.status == .forYou && thought.todoId == nil { return "For you (not on a list)" }
        return thought.status.label
    }

    @ViewBuilder
    private var result: some View {
        let output = thought.output ?? ""
        if !output.isEmpty || !(thought.files ?? []).isEmpty {
            DisclosureGroup(isExpanded: $showOutput) {
                VStack(alignment: .leading, spacing: 10) {
                    if !output.isEmpty {
                        Text(markdown(output))
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if thought.route == .draft && !output.isEmpty {
                        HStack {
                            Button {
                                UIPasteboard.general.string = output
                                copied = true
                            } label: {
                                Label(copied ? "Copied" : "Copy draft", systemImage: copied ? "checkmark" : "doc.on.doc")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.purple)
                            ShareLink(item: output) { Label("Share", systemImage: "square.and.arrow.up") }
                                .buttonStyle(.bordered)
                        }
                    }
                    ForEach(thought.files ?? [], id: \.self) { path in
                        NavigationLink {
                            FileView(dumpID: dump.id, taskID: thought.id, path: path)
                        } label: {
                            Label(path, systemImage: "doc.text").font(.callout)
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                Text(thought.route == .draft ? "Draft" : "What came back")
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// A file a worker made, as text.
struct FileView: View {
    var dumpID: String
    var taskID: String
    var path: String
    @Environment(AppModel.self) private var model
    @State private var text: String?
    @State private var problem: String?

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text ?? problem ?? "Loading…")
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .padding()
        }
        .navigationTitle(path)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let text { ShareLink(item: text) }
        }
        .task {
            do {
                text = try await model.api?.file(dumpID, task: taskID, path: path)
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// The people and organisations a thought names, as your own records describe them. Tap one for the detail.
struct ContextStrip: View {
    var items: [ContextItem]
    @State private var open: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                if item.found {
                    Button {
                        withAnimation(.snappy) { open = open == item.id ? nil : item.id }
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: item.symbol).foregroundStyle(.teal).font(.title3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title ?? item.name).font(.subheadline.weight(.semibold))
                                if let summary = item.summary, !summary.isEmpty {
                                    Text(summary).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: open == item.id ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(10)
                        .background(Color.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows what your records say")
                    if open == item.id, let text = item.text, !text.isEmpty {
                        Text(text)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.horizontal, 10)
                    }
                } else {
                    Label("\(item.name): \(item.reason ?? "not in your records")", systemImage: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
