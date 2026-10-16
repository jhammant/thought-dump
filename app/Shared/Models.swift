import Foundation

/// One thought dump as the Mac reports it: the note, the thoughts found in it, and how each
/// is being handled. Mirrors `snapshot()` in thought_dump.py (snake_case on the wire).
struct Dump: Codable, Identifiable, Hashable {
    var id: String
    var createdAt: String
    var phase: Phase
    var startAt: String?
    var error: String
    var pageUrl: String
    var counts: [String: Int]
    var routes: [String: Int]
    var text: String
    var tasks: [Thought]
    var client: Client?

    struct Client: Codable, Hashable {
        var device: String?
        var recordedAt: String?
        var durationSeconds: Double?
    }

    var created: Date { Dump.date(createdAt) ?? .distantPast }
    var startDate: Date? { startAt.flatMap(Dump.date) }
    var isActive: Bool { phase != .done && phase != .failed }

    /// How many thoughts sit in each of the four buckets the app draws.
    var buckets: [Bucket: Int] {
        var result: [Bucket: Int] = [:]
        for thought in tasks { result[thought.bucket, default: 0] += 1 }
        return result
    }

    static func date(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

enum Phase: String, Codable, Hashable {
    case splitting, failed, planned, working, done, unknown

    init(from decoder: Decoder) throws {
        self = Phase(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

/// One thing found in the note.
struct Thought: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var quote: String
    var kind: String
    var workspace: String
    var outward: Bool
    var needsYou: Bool
    var route: Route
    var defaultRoute: Route
    var status: Status
    var engine: String?
    var startedAt: String?
    var finishedAt: String?
    var elapsedSeconds: Double?
    var costUsd: Double?
    var error: String?
    var todoId: String?
    var output: String?
    var files: [String]?

    var started: Date? { startedAt.flatMap(Dump.date) }

    var bucket: Bucket {
        switch status {
        case .failed, .timedOut, .blocked, .interrupted: return .problem
        case .completed, .drafted, .onTodo, .forYou, .skipped, .stopped: return .settled
        case .running: return .working
        default: return .waiting
        }
    }
}

enum Route: String, Codable, Hashable, CaseIterable {
    case run, draft, todo, skip
}

enum Status: String, Codable, Hashable {
    case pending, running, completed, drafted, skipped, stopped, failed, blocked, interrupted, unknown
    case onTodo = "on_todo"
    case forYou = "for_jon"
    case timedOut = "timed_out"

    init(from decoder: Decoder) throws {
        self = Status(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

enum Bucket: String, CaseIterable, Hashable {
    case waiting, working, settled, problem
}

/// The small summary the iPhone keeps the Watch up to date with.
struct WatchDump: Codable, Identifiable, Hashable {
    var id: String
    var created: Date
    var phase: Phase
    var preview: String
    var thoughts: [WatchThought]

    struct WatchThought: Codable, Hashable, Identifiable {
        var id: String
        var title: String
        var route: Route
        var status: Status
    }

    init(_ dump: Dump) {
        id = dump.id
        created = dump.created
        phase = dump.phase
        preview = String(dump.text.prefix(120))
        thoughts = dump.tasks.map { WatchThought(id: $0.id, title: $0.title, route: $0.route, status: $0.status) }
    }
}

extension JSONDecoder {
    static var api: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
