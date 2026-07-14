import SwiftUI

/// Checks GitHub Releases for a newer app version — once at launch, then daily
/// (the app lives in the menu bar, so launches can be weeks apart).
/// Notify-only: surfaces a banner linking to the release page. Installing stays
/// manual (mount DMG, drag) — matches the notarized direct-download channel.
@MainActor
final class AppUpdateChecker: ObservableObject {
    static let shared = AppUpdateChecker()

    struct Release: Equatable {
        let version: String
        let url: URL
    }

    /// Set when a newer version than the running one is published.
    @Published var available: Release?

    private static let api =
        URL(string: "https://api.github.com/repos/magicelk235/viaduct-app/releases/latest")!
    private var timer: Timer?

    /// Launch hook: check now, then re-check daily. Idempotent.
    func start() {
        guard timer == nil else { return }
        Task { await check() }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in
            Task { @MainActor in await AppUpdateChecker.shared.check() }
        }
    }

    private struct LatestRelease: Decodable {
        let tagName: String
        let htmlUrl: String
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", htmlUrl = "html_url"
        }
    }

    func check() async {
        guard let current = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        else { return }
        var req = URLRequest(url: Self.api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ViaductApp", forHTTPHeaderField: "User-Agent")
        // Offline / rate-limited / bad JSON → stay quiet, try again next cycle.
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let rel = try? JSONDecoder().decode(LatestRelease.self, from: data),
              let url = URL(string: rel.htmlUrl)
        else { return }
        let latest = rel.tagName.hasPrefix("v")
            ? String(rel.tagName.dropFirst()) : rel.tagName
        available = CLIUpdater.semverLess(current, latest)
            ? Release(version: latest, url: url) : nil
    }
}
