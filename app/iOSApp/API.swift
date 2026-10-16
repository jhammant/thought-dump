import Foundation

/// The Mac's Thought Dump API (server.py). Every call but `pair` carries the bearer token.
struct API {
    var base: URL
    var token: String?

    struct Failure: LocalizedError {
        var status: Int
        var message: String
        var errorDescription: String? { message }
    }

    struct NewNote: Encodable {
        var text: String
        var clientId: String
        var recordedAt: String
        var durationSeconds: Double?
        var device: String
    }

    struct PlanChange: Encodable {
        var startNow: Bool?
        var routes: [String: String]?
        var stop: [String]?
    }

    func pair() async throws -> String {
        struct Reply: Decodable { var token: String }
        return try await call("GET", "pair", authorised: false, as: Reply.self).token
    }

    func health() async throws {
        struct Reply: Decodable { var ok: Bool }
        _ = try await call("GET", "health", as: Reply.self)
    }

    func dumps() async throws -> [Dump] {
        struct Reply: Decodable { var dumps: [Dump] }
        return try await call("GET", "dumps", as: Reply.self).dumps
    }

    func dump(_ id: String) async throws -> Dump {
        try await call("GET", "dumps/\(id)", as: Dump.self)
    }

    func create(_ note: NewNote) async throws -> Dump {
        try await call("POST", "dumps", body: note, as: Dump.self)
    }

    func plan(_ id: String, _ change: PlanChange) async throws -> Dump {
        try await call("POST", "dumps/\(id)/plan", body: change, as: Dump.self)
    }

    func retry(_ id: String) async throws -> Dump {
        struct Empty: Encodable {}
        return try await call("POST", "dumps/\(id)/retry", body: Empty(), as: Dump.self)
    }

    func file(_ id: String, task: String, path: String) async throws -> String {
        let escaped = path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        let (data, _) = try await send("GET", "dumps/\(id)/files/\(task)/\(escaped)", body: nil, authorised: true)
        return String(decoding: data, as: UTF8.self)
    }

    private func call<Reply: Decodable>(_ method: String, _ path: String, body: Encodable? = nil,
                                        authorised: Bool = true, as type: Reply.Type) async throws -> Reply {
        let encoded: Data?
        if let body {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoded = try encoder.encode(body)
        } else {
            encoded = nil
        }
        let (data, _) = try await send(method, path, body: encoded, authorised: authorised)
        return try JSONDecoder.api.decode(Reply.self, from: data)
    }

    private func send(_ method: String, _ path: String, body: Data?, authorised: Bool) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: "api/" + path, relativeTo: base.appendingPathComponent("/")) else {
            throw Failure(status: 0, message: "Bad server address")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authorised, let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure(status: 0, message: "No response") }
        guard (200..<300).contains(http.statusCode) else {
            struct ErrorReply: Decodable { var error: String }
            let message = (try? JSONDecoder().decode(ErrorReply.self, from: data))?.error ?? "Error \(http.statusCode)"
            throw Failure(status: http.statusCode, message: message)
        }
        return (data, http)
    }
}
