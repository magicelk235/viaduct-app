import Foundation

/// Free Apple accounts sign extensions with a provisioning profile that lapses
/// after ~7 days, after which Safari drops the extension. This re-runs the
/// conversion from the archived source for any installed extension nearing that
/// window, re-signing it fresh — so the user never has to reconvert by hand.
///
/// ponytail: rebuild-from-source via the same CLI path. No separate re-sign codepath
/// to maintain; a free-account profile can only be re-minted by an Xcode build anyway.
@MainActor
final class ExtensionRenewer {
    /// Renew when a build is within this much of its 7-day expiry.
    private static let renewWindow: TimeInterval = 2 * 24 * 3600   // 2 days early

    private let history: ConversionHistory
    private let runner = CLIRunner.shared
    private var running = false

    init(history: ConversionHistory) { self.history = history }

    /// Durable copy of converted sources, so renew survives the user moving the
    /// original file or macOS purging the Caches-dir store download.
    static var archiveDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Viaduct/sources", isDirectory: true)
    }

    /// Copy `path` into the archive, keyed by app name. Returns the archived path
    /// (or nil on failure — caller then keeps the original path).
    static func archiveSource(_ path: String, appName: String) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path), !appName.isEmpty else { return nil }
        do {
            try fm.createDirectory(at: archiveDir, withIntermediateDirectories: true)
            let ext = URL(fileURLWithPath: path).pathExtension
            // ponytail: one slot per app name; re-convert overwrites it. Dirs (unpacked)
            // and archives both handled by copyItem.
            let dest = archiveDir.appendingPathComponent(appName)
                .appendingPathExtension(ext.isEmpty ? "src" : ext)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: URL(fileURLWithPath: path), to: dest)
            return dest.path
        } catch { return nil }
    }

    /// Records whose signature is at/near expiry and whose source still exists.
    private func dueForRenewal() -> [ConversionRecord] {
        let cutoff = Date().addingTimeInterval(Self.renewWindow)
        return history.records.filter { rec in
            rec.expiresAt <= cutoff
            && FileManager.default.fileExists(atPath: rec.sourcePath)
        }
    }

    /// Renew everything that's due, one at a time (CLIRunner is single-flight).
    /// Silent: no UI phase, best-effort. Called on launch + daily.
    func renewIfNeeded() {
        guard !running, !runner.isRunning else { return }
        let due = dueForRenewal()
        guard !due.isEmpty else { return }
        running = true
        Task { @MainActor in
            defer { running = false }
            for rec in due { await renew(rec) }
        }
    }

    private func renew(_ rec: ConversionRecord) async {
        var opts = ConvertOptions()
        opts.inputPath = rec.sourcePath
        opts.appName = rec.resolvedAppName
        opts.install = true
        opts.signing = .autoTeam   // re-mint the Apple-issued dev signature
        opts.force = true          // never block a renew on advisory issues

        let code: Int32 = await withCheckedContinuation { cont in
            do {
                try runner.run(args: opts.conversionArgs(), onLine: { _ in }) { c in
                    cont.resume(returning: c)
                }
            } catch {
                cont.resume(returning: -1)
            }
        }
        if code == 0 { history.markRenewed(id: rec.id, installedPath: rec.installedPath) }
    }
}
