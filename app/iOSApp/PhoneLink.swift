import Foundation
import WatchConnectivity

/// The Watch isn't on the tailnet, so it hands its notes to the iPhone, which sends them on and
/// keeps the Watch's list of dumps up to date.
final class PhoneLink: NSObject, WCSessionDelegate {
    static let shared = PhoneLink()

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func push(_ dumps: [Dump]) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isWatchAppInstalled,
              let data = try? JSONEncoder().encode(dumps.prefix(8).map(WatchDump.init)) else { return }
        try? WCSession.default.updateApplicationContext(["dumps": data])
    }

    private func receive(_ payload: [String: Any]) {
        guard let text = payload["text"] as? String, let clientID = payload["client_id"] as? String else { return }
        let duration = payload["duration"] as? Double
        Task { @MainActor in
            AppModel.shared.submit(text: text, durationSeconds: duration, device: "Apple Watch", clientID: clientID)
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        receive(message)
        replyHandler(["received": true])
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        receive(userInfo)
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.push(AppModel.shared.dumps) }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
}
