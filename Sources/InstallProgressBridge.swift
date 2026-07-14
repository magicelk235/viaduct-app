import AppKit

/// Answers progress polls from the Safari extension so the Chrome Web Store
/// page can render the install bar itself — the app window never comes forward.
///
/// The .appex is sandboxed and lives only for the duration of one
/// `beginRequest`, so it can't read our files or hold a connection. Instead it
/// posts a request notification per poll and we reply with a JSON snapshot on
/// the distributed notification center (unsandboxed sender may attach the
/// `object` string; the sandboxed appex may receive it).
///
/// SECURITY: DistributedNotificationCenter is a system-wide, unauthenticated
/// bus — any local process can post `requestNote` and read the `stateNote`
/// reply. There is no way to authenticate the appex over it, so the snapshot
/// (see `ViaductApp.progressSnapshot`) MUST carry only non-sensitive progress
/// state: no filesystem paths, no license/trial specifics, no secrets.
final class InstallProgressBridge {
    static let shared = InstallProgressBridge()

    static let requestNote = Notification.Name("com.magicelk235.viaduct.progress.request")
    static let stateNote = Notification.Name("com.magicelk235.viaduct.progress.state")

    /// True while the CRX is downloading from the store (before the CLI runs,
    /// while `vm.phase` is still `.idle`).
    var downloading = false

    /// Set by the app at launch; returns the JSON-serializable state dict.
    /// Runs on the main actor (the observer hops there before calling).
    var snapshot: () -> [String: Any] = { ["state": "idle"] }

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        DistributedNotificationCenter.default().addObserver(
            forName: Self.requestNote, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.reply() }
        }
    }

    @MainActor
    private func reply() {
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot()),
              let json = String(data: data, encoding: .utf8) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            Self.stateNote, object: json, userInfo: nil, deliverImmediately: true)
    }
}
