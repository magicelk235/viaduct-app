import Foundation

/// One converted extension, persisted across launches.
struct ConversionRecord: Codable, Identifiable {
    var id = UUID()
    var name: String
    var sourcePath: String
    /// The --app-name used, so auto-renew rebuilds to the exact same .app.
    /// Optional so old records still decode; falls back to `name` when absent.
    var appName: String?
    var installedPath: String?
    var date: Date
    /// When this build's signature was last refreshed. Used by auto-renew to find
    /// builds nearing the free-account 7-day expiry. Old records fall back to `date`.
    var lastSigned: Date?
    /// Last time auto-renew tried this record, and whether it failed. Surfaced in
    /// Settings so the user sees a silent failure before Safari drops the extension.
    var lastRenewAttempt: Date?
    var lastRenewFailed: Bool?
    /// PNG of the extension's own icon, captured at conversion time. Optional
    /// so old records (and icon-less extensions) still decode.
    var iconData: Data?

    /// Effective app name for rebuilds.
    var resolvedAppName: String { appName ?? name }
    /// When this build's free-account signature is assumed to lapse (7 days).
    var expiresAt: Date { (lastSigned ?? date).addingTimeInterval(7 * 24 * 3600) }
}

/// Append-only history of converted extensions, backed by UserDefaults.
/// ponytail: UserDefaults JSON, fine for a list of conversions; move to a file/db only if it grows huge.
@MainActor
final class ConversionHistory: ObservableObject {
    @Published private(set) var records: [ConversionRecord] = []

    private let key = "conversionHistory"
    private let defaults = UserDefaults.standard

    init() { load() }

    func add(name: String, sourcePath: String, appName: String,
             installedPath: String?, iconData: Data?) {
        let now = Date()
        let record = ConversionRecord(name: name, sourcePath: sourcePath,
                                      appName: appName, installedPath: installedPath,
                                      date: now, lastSigned: now, iconData: iconData)
        // Re-converting the same app replaces its record instead of stacking duplicates.
        records.removeAll { $0.resolvedAppName == appName }
        records.insert(record, at: 0)
        if records.count > 200 { records.removeLast(records.count - 200) }
        save()
    }

    /// Stamp a record as freshly re-signed (called after a successful auto-renew).
    func markRenewed(id: ConversionRecord.ID, installedPath: String?) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        let now = Date()
        records[i].lastSigned = now
        records[i].lastRenewAttempt = now
        records[i].lastRenewFailed = false
        if let p = installedPath { records[i].installedPath = p }
        save()
    }

    /// Stamp a failed auto-renew attempt (lastSigned stays put — still on the old expiry).
    func markRenewFailed(id: ConversionRecord.ID) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].lastRenewAttempt = Date()
        records[i].lastRenewFailed = true
        save()
    }

    func clear() { records.removeAll(); save() }

    /// Drop records whose installed .app the user deleted from Finder, and clean
    /// their archived source — so auto-renew won't rebuild an app they removed.
    func pruneDeleted() {
        let fm = FileManager.default
        let gone = records.filter { rec in
            guard let p = rec.installedPath else { return false }
            return !fm.fileExists(atPath: p)
        }
        guard !gone.isEmpty else { return }
        for rec in gone { try? fm.removeItem(atPath: rec.sourcePath) }
        let goneIDs = Set(gone.map(\.id))
        records.removeAll { goneIDs.contains($0.id) }
        save()
    }

    /// Drop a record AND delete its archived source + installed .app, so auto-renew
    /// can never rebuild it (renew skips records whose source is gone). Best-effort
    /// on the file deletes — a stale .app left on disk is harmless.
    func remove(_ record: ConversionRecord) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: record.sourcePath)
        if let p = record.installedPath { try? fm.removeItem(atPath: p) }
        records.removeAll { $0.id == record.id }
        save()
    }

    private func load() {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ConversionRecord].self, from: data)
        else { return }
        records = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: key)
        }
    }
}
