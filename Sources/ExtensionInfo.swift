import Foundation
import AppKit

/// Name + icon pulled from a Chrome extension before conversion.
struct ExtensionInfo {
    var name: String
    var icon: NSImage?
}

extension NSImage {
    /// PNG encoding for persisting the icon in history.
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// Reads an extension's manifest (from a .zip/.crx or unpacked folder) to
/// surface its display name and best icon for the UI.
enum ExtensionInspector {

    /// Inspect a path off the main thread; result delivered on main.
    static func inspect(path: String, completion: @escaping (ExtensionInfo?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let info = inspectSync(path: path)
            DispatchQueue.main.async { completion(info) }
        }
    }

    static func inspectSync(path: String) -> ExtensionInfo? {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }

        let root: URL
        let cleanup: (() -> Void)?
        if isDir.boolValue {
            root = url
            cleanup = nil
        } else {
            // Archive (.zip / .crx): extract to a temp dir.
            guard let dir = extractArchive(url) else {
                return ExtensionInfo(name: url.deletingPathExtension().lastPathComponent, icon: nil)
            }
            root = dir
            cleanup = { try? FileManager.default.removeItem(at: dir) }
        }
        defer { cleanup?() }

        let manifestURL = manifestLocation(in: root)
        guard let manifestURL,
              let data = try? Data(contentsOf: manifestURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ExtensionInfo(name: url.deletingPathExtension().lastPathComponent, icon: nil)
        }

        let rawName = (obj["name"] as? String)?.trimmingCharacters(in: .whitespaces)
            ?? url.deletingPathExtension().lastPathComponent
        let base = manifestURL.deletingLastPathComponent()
        let fallback = url.deletingPathExtension().lastPathComponent
        let name = cleanName(rawName, base: base,
                             defaultLocale: obj["default_locale"] as? String,
                             fallback: fallback)
        let icon = loadIcon(from: obj, base: base)
        return ExtensionInfo(name: name, icon: icon)
    }

    // MARK: - Archive

    private static func extractArchive(_ archive: URL) -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("c2s-inspect-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        // -o overwrite, -qq quiet; tolerates the small crx header prefix.
        p.arguments = ["-o", "-qq", archive.path, "-d", dir.path]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return nil }
        // unzip returns 1 on warnings (e.g. crx header) but still extracts.
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return contents.isEmpty ? nil : dir
    }

    /// Find manifest.json at root or one level down (some zips nest a folder).
    private static func manifestLocation(in root: URL) -> URL? {
        let direct = root.appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        let subs = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for sub in subs {
            if (try? sub.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let nested = sub.appendingPathComponent("manifest.json")
                if FileManager.default.fileExists(atPath: nested.path) { return nested }
            }
        }
        return nil
    }

    // MARK: - Icon

    private static func loadIcon(from manifest: [String: Any], base: URL) -> NSImage? {
        var candidates: [String] = []

        if let icons = manifest["icons"] as? [String: String] {
            // Prefer the largest declared size.
            let sorted = icons.sorted { (Int($0.key) ?? 0) > (Int($1.key) ?? 0) }
            candidates += sorted.map { $0.value }
        }
        // action / browser_action default_icon (string or size map).
        for key in ["action", "browser_action"] {
            if let act = manifest[key] as? [String: Any] {
                if let s = act["default_icon"] as? String { candidates.append(s) }
                if let m = act["default_icon"] as? [String: String] {
                    candidates += m.sorted { (Int($0.key) ?? 0) > (Int($1.key) ?? 0) }.map { $0.value }
                }
            }
        }

        for rel in candidates {
            let url = base.appendingPathComponent(rel)
            if let img = NSImage(contentsOf: url), img.isValid { return img }
        }
        return nil
    }

    /// Resolve an i18n placeholder name (`__MSG_appName__`) against the extension's
    /// `_locales/<default>/messages.json`. Falls back to the file name if it can't.
    private static func cleanName(_ raw: String, base: URL,
                                  defaultLocale: String?, fallback: String) -> String {
        guard raw.hasPrefix("__MSG_"), raw.hasSuffix("__") else { return raw }
        let key = String(raw.dropFirst(6).dropLast(2))   // __MSG_KEY__ → KEY

        // Try the manifest's declared locale first, then common defaults.
        let locales = [defaultLocale, "en", "en_US"].compactMap { $0 }
        for loc in locales {
            let messages = base.appendingPathComponent("_locales/\(loc)/messages.json")
            guard let data = try? Data(contentsOf: messages),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            // messages.json maps KEY → { "message": "Display Name", ... }, case-insensitive key.
            let entry = obj.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
            if let msg = (entry as? [String: Any])?["message"] as? String,
               !msg.trimmingCharacters(in: .whitespaces).isEmpty {
                return msg.trimmingCharacters(in: .whitespaces)
            }
        }
        return fallback
    }
}
