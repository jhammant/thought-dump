import Foundation
import Observation
import WatchConnectivity

/// Hands dictated notes to the iPhone (which sends them to the Mac) and receives the latest dumps back.
@MainActor
@Observable
final class WatchLink: NSObject {
    static let shared = WatchLink()

    var dumps: [WatchDump] = []
    var sending = 0
    var lastSent: Date?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        load(WCSession.default.receivedApplicationContext)
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let payload: [String: Any] = ["text": trimmed, "client_id": UUID().uuidString]
        lastSent = Date()
        let session = WCSession.default
        if session.isReachable {
            sending += 1
            session.sendMessage(payload, replyHandler: { _ in
                Task { @MainActor in self.sending -= 1 }
            }, errorHandler: { _ in
                session.transferUserInfo(payload)   // queued: delivered when the phone is around
                Task { @MainActor in self.sending -= 1 }
            })
        } else {
            session.transferUserInfo(payload)
        }
    }

    fileprivate func load(_ context: [String: Any]) {
        guard let data = context["dumps"] as? Data,
              let decoded = try? JSONDecoder().decode([WatchDump].self, from: data) else { return }
        dumps = decoded
    }
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let data = applicationContext["dumps"] as? Data
        Task { @MainActor in self.load(["dumps": data as Any]) }
    }
}
