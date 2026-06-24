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
        records[i].lastSigned = Date()
        if let p = installedPath { records[i].installedPath = p }
        save()
    }

    func clear() { records.removeAll(); save() }

    func remove(_ record: ConversionRecord) {
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
