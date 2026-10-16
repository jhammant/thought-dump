import Foundation
import Observation
import SwiftUI

/// Everything the screens show: the paired Mac, the dumps it reports, notes still waiting to be
/// sent (the outbox survives a sleeping Mac, no signal, or a relaunch), and the actions on a plan.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    struct PendingNote: Codable, Identifiable, Hashable {
        var id: String          // the client_id: the Mac treats a retry as the same dump
        var text: String
        var recordedAt: String
        var durationSeconds: Double?
        var device: String
        var lastError: String?
    }

    enum Connection: Equatable {
        case unpaired, checking, connected, offline(String)
    }

    var serverURL: URL? {
        didSet { UserDefaults.standard.set(serverURL?.absoluteString, forKey: "serverURL") }
    }
    var connection: Connection = .unpaired
    var dumps: [Dump] = []
    var details: [String: Dump] = [:]
    var outbox: [PendingNote] = [] {
        didSet { saveOutbox() }
    }
    var selection: String?
    var recordRequested = false
    var lastError: String?

    private var token: String? {
        didSet { Keychain.write(token, "token") }
    }

    private init() {
        serverURL = UserDefaults.standard.string(forKey: "serverURL").flatMap(URL.init(string:))
        token = Keychain.read("token")
        outbox = loadOutbox()
        connection = serverURL != nil && token != nil ? .checking : .unpaired
        if let address = ProcessInfo.processInfo.environment["THOUGHT_DUMP_URL"],
           let secret = ProcessInfo.processInfo.environment["THOUGHT_DUMP_TOKEN"] {   // simulator runs
            serverURL = URL(string: address)
            token = secret
            connection = .checking
            selection = ProcessInfo.processInfo.environment["THOUGHT_DUMP_SELECT"]
        }
    }

    var api: API? {
        guard let serverURL, let token else { return nil }
        return API(base: serverURL, token: token)
    }

    var isPaired: Bool { api != nil }

    // MARK: Pairing

    /// `thoughtdump://pair?url=…&token=…` (from `dump pair`), `thoughtdump://record`, or
    /// `thoughtdump://dump/<id>` to open one dump.
    func open(_ url: URL) {
        guard url.scheme == "thoughtdump" else { return }
        if url.host == "record" {
            recordRequested = true
            return
        }
        if url.host == "dump", let id = url.pathComponents.dropFirst().first {
            selection = id
            return
        }
        guard url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let address = items.first(where: { $0.name == "url" })?.value.flatMap(URL.init(string:)),
              let secret = items.first(where: { $0.name == "token" })?.value else { return }
        Task { await pair(address: address, token: secret) }
    }

    /// With only an address: a Mac on your tailnet hands the token to your own Tailscale login.
    func pair(address: URL, token secret: String? = nil) async {
        connection = .checking
        do {
            let found: String
            if let secret {
                found = secret
            } else {
                found = try await API(base: address, token: nil).pair()
            }
            try await API(base: address, token: found).health()
            serverURL = address
            token = found
            connection = .connected
            await refresh()
        } catch {
            connection = isPaired ? .offline(error.localizedDescription) : .unpaired
            lastError = error.localizedDescription
        }
    }

    func unpair() {
        token = nil
        serverURL = nil
        dumps = []
        details = [:]
        connection = .unpaired
    }

    // MARK: Notes

    /// Keep it first, send it second: a note is never lost to a failed request.
    @discardableResult
    func submit(text: String, durationSeconds: Double?, device: String, clientID: String = UUID().uuidString) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if !outbox.contains(where: { $0.id == clientID }) {
            outbox.append(PendingNote(id: clientID, text: trimmed,
                                      recordedAt: ISO8601DateFormatter().string(from: Date()),
                                      durationSeconds: durationSeconds, device: device))
        }
        selection = "pending:\(clientID)"
        Task { await flushOutbox() }
        return clientID
    }

    func flushOutbox() async {
        guard let api else { return }
        for note in outbox {
            do {
                let dump = try await api.create(API.NewNote(text: note.text, clientId: note.id, recordedAt: note.recordedAt,
                                                            durationSeconds: note.durationSeconds, device: note.device))
                outbox.removeAll { $0.id == note.id }
                details[dump.id] = dump
                upsert(dump)
                if selection == "pending:\(note.id)" { selection = dump.id }
                connection = .connected
            } catch {
                if let index = outbox.firstIndex(where: { $0.id == note.id }) {
                    outbox[index].lastError = error.localizedDescription
                }
                connection = .offline(error.localizedDescription)
                return
            }
        }
    }

    func discard(_ note: PendingNote) {
        outbox.removeAll { $0.id == note.id }
    }

    // MARK: Reading

    func refresh() async {
        guard let api else { return }
        do {
            dumps = try await api.dumps()
            connection = .connected
            PhoneLink.shared.push(dumps)
            if !outbox.isEmpty { await flushOutbox() }
        } catch {
            connection = .offline(error.localizedDescription)
        }
    }

    @discardableResult
    func refresh(_ id: String) async -> Dump? {
        guard let api else { return nil }
        do {
            let dump = try await api.dump(id)
            details[id] = dump
            upsert(dump)
            connection = .connected
            return dump
        } catch {
            connection = .offline(error.localizedDescription)
            return details[id]
        }
    }

    private func upsert(_ dump: Dump) {
        if let index = dumps.firstIndex(where: { $0.id == dump.id }) {
            dumps[index] = dump
        } else {
            dumps.insert(dump, at: 0)
        }
        PhoneLink.shared.push(dumps)
    }

    // MARK: The plan

    func setRoute(_ route: Route, for thought: Thought, in dump: Dump) async {
        await change(dump.id, API.PlanChange(routes: [thought.id: route.rawValue]))
    }

    func stop(_ thought: Thought, in dump: Dump) async {
        await change(dump.id, API.PlanChange(stop: [thought.id]))
    }

    func startNow(_ dump: Dump) async {
        await change(dump.id, API.PlanChange(startNow: true))
    }

    func retry(_ dump: Dump) async {
        guard let api else { return }
        do {
            let updated = try await api.retry(dump.id)
            details[dump.id] = updated
            upsert(updated)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func change(_ id: String, _ change: API.PlanChange) async {
        guard let api else { return }
        do {
            let updated = try await api.plan(id, change)
            withAnimation(.snappy) {
                details[id] = updated
                upsert(updated)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Outbox on disk

    private var outboxURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("outbox.json")
    }

    private func loadOutbox() -> [PendingNote] {
        guard let data = try? Data(contentsOf: outboxURL) else { return [] }
        return (try? JSONDecoder().decode([PendingNote].self, from: data)) ?? []
    }

    private func saveOutbox() {
        guard let data = try? JSONEncoder().encode(outbox) else { return }
        try? data.write(to: outboxURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
