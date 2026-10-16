import SwiftUI

/// One visual language for every screen: each route and status has a label, a symbol and a colour.
extension Route {
    var label: String {
        switch self {
        case .run: return "Doing it"
        case .draft: return "Drafting"
        case .todo: return "For you"
        case .skip: return "Skipped"
        }
    }

    var menuLabel: String {
        switch self {
        case .run: return "Do it on the Mac"
        case .draft: return "Draft it, send nothing"
        case .todo: return "Put it on my list"
        case .skip: return "Skip it"
        }
    }

    var symbol: String {
        switch self {
        case .run: return "gearshape.2.fill"
        case .draft: return "envelope.fill"
        case .todo: return "person.fill"
        case .skip: return "forward.fill"
        }
    }

    var color: Color {
        switch self {
        case .run: return .blue
        case .draft: return .purple
        case .todo: return .orange
        case .skip: return .gray
        }
    }
}

extension Status {
    var label: String {
        switch self {
        case .pending: return "Waiting"
        case .running: return "Working"
        case .completed: return "Done"
        case .drafted: return "Draft ready"
        case .onTodo: return "On your list"
        case .forYou: return "For you"
        case .skipped: return "Skipped"
        case .stopped: return "Stopped"
        case .failed: return "Failed"
        case .timedOut: return "Ran out of time"
        case .blocked: return "Blocked"
        case .interrupted: return "Interrupted"
        case .unknown: return "Unknown"
        }
    }

    var symbol: String {
        switch self {
        case .pending: return "clock"
        case .running: return "gearshape.2"
        case .completed: return "checkmark.circle.fill"
        case .drafted: return "doc.text.fill"
        case .onTodo: return "list.bullet.clipboard.fill"
        case .forYou: return "person.crop.circle.badge.exclamationmark"
        case .skipped: return "forward.circle"
        case .stopped: return "stop.circle"
        case .failed, .timedOut, .blocked, .interrupted, .unknown: return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .pending: return .secondary
        case .running: return .blue
        case .completed: return .green
        case .drafted: return .purple
        case .onTodo, .forYou: return .orange
        case .skipped, .stopped: return .gray
        case .failed, .timedOut, .blocked, .interrupted, .unknown: return .red
        }
    }
}

extension Phase {
    var label: String {
        switch self {
        case .splitting: return "Finding thoughts"
        case .failed: return "Couldn't split"
        case .planned: return "Ready to start"
        case .working: return "Working"
        case .done: return "Done"
        case .unknown: return "…"
        }
    }

    var symbol: String {
        switch self {
        case .splitting: return "sparkle.magnifyingglass"
        case .failed: return "exclamationmark.triangle.fill"
        case .planned: return "timer"
        case .working: return "gearshape.2.fill"
        case .done: return "checkmark.seal.fill"
        case .unknown: return "questionmark"
        }
    }

    var color: Color {
        switch self {
        case .splitting: return .teal
        case .failed: return .red
        case .planned: return .orange
        case .working: return .blue
        case .done: return .green
        case .unknown: return .gray
        }
    }
}

extension Bucket {
    var label: String {
        switch self {
        case .waiting: return "Waiting"
        case .working: return "Working"
        case .settled: return "Handled"
        case .problem: return "Needs a look"
        }
    }

    var color: Color {
        switch self {
        case .waiting: return .gray.opacity(0.45)
        case .working: return .blue
        case .settled: return .green
        case .problem: return .red
        }
    }
}
