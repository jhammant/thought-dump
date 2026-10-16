import Charts
import SwiftUI

/// Heard → Found → Plan → Working → Done, with the current stage lit and pulsing.
struct StageTrack: View {
    var phase: Phase

    private let stages: [(String, String)] = [
        ("Heard", "waveform"), ("Found", "sparkles"), ("Plan", "timer"), ("Working", "gearshape.2.fill"), ("Done", "checkmark"),
    ]

    private var current: Int {
        switch phase {
        case .splitting: return 1
        case .planned: return 2
        case .working: return 3
        case .done: return 4
        case .failed, .unknown: return 1
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                VStack(spacing: 4) {
                    ZStack {
                        Circle()
                            .fill(index <= current ? stageColor(index) : Color.secondary.opacity(0.15))
                            .frame(width: 30, height: 30)
                        Image(systemName: phase == .failed && index == current ? "exclamationmark" : stage.1)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(index <= current ? .white : .secondary)
                            .symbolEffect(.pulse, isActive: index == current && phase != .done && phase != .failed)
                    }
                    Text(stage.0)
                        .font(.caption2.weight(index == current ? .bold : .regular))
                        .foregroundStyle(index <= current ? .primary : .secondary)
                }
                .frame(maxWidth: .infinity)
                if index < stages.count - 1 {
                    Capsule()
                        .fill(index < current ? stageColor(index + 1) : Color.secondary.opacity(0.15))
                        .frame(height: 3)
                        .frame(maxWidth: 28)
                        .offset(y: -9)
                }
            }
        }
        .animation(.snappy, value: phase)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stage: \(phase.label)")
    }

    private func stageColor(_ index: Int) -> Color {
        if phase == .failed && index == current { return .red }
        return index == current ? phase.color : .green
    }
}

/// The note on the left, a line to every thought it found, each line in the colour of how that
/// thought is being handled. Lines flow while a thought is being worked on.
struct FlowDiagram: View {
    var dump: Dump
    var onSelect: (Thought) -> Void = { _ in }

    private let rowHeight: CGFloat = 50
    private let noteSize: CGFloat = 54

    var body: some View {
        let thoughts = dump.tasks
        let rows = max(thoughts.count, dump.phase == .splitting ? 3 : 1)
        let height = CGFloat(rows) * rowHeight
        GeometryReader { geometry in
            let nodeX = min(geometry.size.width * 0.34, 150)
            TimelineView(.animation(paused: !thoughts.contains { $0.status == .running } && dump.phase != .splitting)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        let start = CGPoint(x: noteSize / 2 + 4, y: size.height / 2)
                        for index in 0..<rows {
                            let end = CGPoint(x: nodeX, y: rowHeight * (CGFloat(index) + 0.5))
                            var path = Path()
                            path.move(to: start)
                            path.addCurve(to: end,
                                          control1: CGPoint(x: start.x + (end.x - start.x) * 0.55, y: start.y),
                                          control2: CGPoint(x: start.x + (end.x - start.x) * 0.45, y: end.y))
                            if index < thoughts.count {
                                let thought = thoughts[index]
                                let active = thought.status == .running
                                let muted = thought.route == .skip || thought.status == .skipped || thought.status == .stopped
                                context.stroke(path, with: .color(thought.route.color.opacity(muted ? 0.25 : 0.8)),
                                               style: StrokeStyle(lineWidth: active ? 3 : 2, lineCap: .round,
                                                                  dash: active ? [7, 5] : (muted ? [2, 4] : []),
                                                                  dashPhase: active ? CGFloat(-time * 24) : 0))
                            } else {
                                let shimmer = 0.15 + 0.15 * sin(time * 3 + Double(index))
                                context.stroke(path, with: .color(.teal.opacity(shimmer)),
                                               style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 5]))
                            }
                        }
                    }
                    noteNode
                        .position(x: noteSize / 2 + 4, y: height / 2)
                    ForEach(Array(thoughts.enumerated()), id: \.element.id) { index, thought in
                        Button { onSelect(thought) } label: { ThoughtNode(thought: thought) }
                            .buttonStyle(.plain)
                            .frame(width: max(0, geometry.size.width - nodeX), height: rowHeight, alignment: .leading)
                            .offset(x: nodeX - 12, y: rowHeight * CGFloat(index))
                            .transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
                    }
                    if thoughts.isEmpty && dump.phase == .splitting {
                        Text("Finding the thoughts in your note…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .offset(x: nodeX, y: height / 2 - 10)
                    }
                }
            }
        }
        .frame(height: height)
        .animation(.spring(duration: 0.5), value: thoughts.map(\.id))
    }

    private var noteNode: some View {
        ZStack {
            Circle().fill(Gradient(colors: [.indigo, .purple]))
            Image(systemName: dump.phase == .splitting ? "waveform" : "text.bubble.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.variableColor.iterative, isActive: dump.phase == .splitting)
        }
        .frame(width: noteSize, height: noteSize)
        .shadow(color: .indigo.opacity(0.35), radius: 8, y: 3)
        .accessibilityLabel("Your note")
    }
}

/// One thought in the diagram: route badge, short title, live status.
struct ThoughtNode: View {
    var thought: Thought

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(thought.route.color.opacity(thought.route == .skip ? 0.35 : 1))
                Image(systemName: thought.route.symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .symbolEffect(.rotate, isActive: thought.status == .running)
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(thought.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .strikethrough(thought.status == .skipped)
                HStack(spacing: 4) {
                    Image(systemName: thought.status.symbol)
                    Text(thought.status == .pending ? thought.route.label : thought.status.label)
                    if let match = thought.found.first {
                        Text("· \(match.title ?? match.name)")
                            .foregroundStyle(.teal)
                            .lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(thought.status.color)
            }
            Spacer(minLength: 0)
        }
        .padding(.trailing, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Handled / working / waiting / needs a look, as a ring with the handled count in the middle.
struct ProgressRing: View {
    var dump: Dump

    var body: some View {
        let buckets = dump.buckets
        let total = max(dump.tasks.count, 1)
        let handled = buckets[.settled, default: 0]
        Chart(Bucket.allCases, id: \.self) { bucket in
            SectorMark(angle: .value("Thoughts", buckets[bucket, default: 0]), innerRadius: .ratio(0.68), angularInset: 1.5)
                .foregroundStyle(bucket.color)
                .cornerRadius(3)
        }
        .chartLegend(.hidden)
        .overlay {
            VStack(spacing: 0) {
                Text("\(handled)/\(dump.tasks.count)")
                    .font(.headline.monospacedDigit())
                Text("handled").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .opacity(dump.tasks.isEmpty ? 0.3 : 1)
        .animation(.snappy, value: handled)
        .accessibilityLabel("\(handled) of \(total) thoughts handled")
    }
}

/// The 30 seconds before work starts, as a draining ring.
struct CountdownRing: View {
    var start: Date
    var total: Double = 30

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { timeline in
            let left = max(0, start.timeIntervalSince(timeline.date))
            ZStack {
                Circle().stroke(Color.orange.opacity(0.2), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: min(1, left / total))
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(left.rounded(.up)))")
                    .font(.title3.monospacedDigit().weight(.bold))
                    .contentTransition(.numericText(countsDown: true))
            }
            .animation(.linear(duration: 0.2), value: left)
        }
        .frame(width: 56, height: 56)
    }
}

/// A thin bar of a dump's thoughts, one segment per bucket: for the history list and the Watch.
struct BucketBar: View {
    var dump: Dump

    var body: some View {
        let buckets = dump.buckets
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(Bucket.allCases, id: \.self) { bucket in
                    let count = buckets[bucket, default: 0]
                    if count > 0 {
                        Capsule()
                            .fill(bucket.color)
                            .frame(width: max(4, geometry.size.width * CGFloat(count) / CGFloat(max(dump.tasks.count, 1)) - 2))
                    }
                }
            }
        }
        .frame(height: 6)
    }
}

/// Small rounded label.
struct Chip: View {
    var text: String
    var symbol: String? = nil
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .background(color.opacity(0.12), in: Capsule())
    }
}
