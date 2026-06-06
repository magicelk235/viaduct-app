import Foundation

/// Keeps the chrome2safari CLI current by pulling the published npm package.
/// npm ships a prebuilt `dist/`, so updating is download + extract + atomic
/// swap into Application Support (which CLIRunner prefers) — no build step.
final class CLIUpdater {
    static let shared = CLIUpdater()

    private let pkg = "chrome2safari"

    enum UpdateError: LocalizedError {
        case registry(String)
        case download(String)
        case extract(String)
        var errorDescription: String? {
            switch self {
            case .registry(let m): return "Registry error: \(m)"
            case .download(let m): return "Download failed: \(m)"
            case .extract(let m): return "Extract failed: \(m)"
            }
        }
    }

    /// Version the bundled/installed CLI was built from (best-effort).
    var installedVersion: String? {
        let updated = CLIRunner.supportCLIDir.appendingPathComponent("version.txt")
        let bundled = CLIRunner.bundledCLIDir?.appendingPathComponent("version.txt")
        for url in [updated, bundled].compactMap({ $0 }) {
            if let s = try? String(contentsOf: url, encoding: .utf8) {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
        }
        return nil
    }

    private struct DistTags: Decodable { let latest: String }
    private struct VersionDist: Decodable { let tarball: String }
    private struct PackageDoc: Decodable {
        let distTags: DistTags
        let versions: [String: VersionRecord]
        enum CodingKeys: String, CodingKey { case distTags = "dist-tags", versions }
    }
    private struct VersionRecord: Decodable { let dist: VersionDist }

    /// Fetch the npm package document.
    private func fetchPackageDoc() async throws -> PackageDoc {
        let url = URL(string: "https://registry.npmjs.org/\(pkg)")!
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Chrome2SafariApp", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.registry("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        do { return try JSONDecoder().decode(PackageDoc.self, from: data) }
        catch { throw UpdateError.registry("bad JSON: \(error.localizedDescription)") }
    }

    /// Latest published version string.
    func latestVersion() async throws -> String {
        try await fetchPackageDoc().distTags.latest
    }

    /// True if a newer CLI is available (semver-aware).
    func updateAvailable() async throws -> Bool {
        let latest = try await latestVersion()
        guard let have = installedVersion else { return true }
        return Self.semverLess(have, latest)
    }

    /// Download + extract the latest npm tarball into Application Support. `log` streams progress.
    func update(log: @escaping (String) -> Void) async throws {
        let doc = try await fetchPackageDoc()
        let latest = doc.distTags.latest
        log("Latest published: \(latest)")
        if let have = installedVersion, !Self.semverLess(have, latest) {
            log("Already up to date (\(have)).")
            return
        }
        guard let rec = doc.versions[latest] else {
            throw UpdateError.registry("version \(latest) not in document")
        }

        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("c2s-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // 1. Download tarball.
        log("Downloading \(rec.dist.tarball)…")
        guard let tarURL = URL(string: rec.dist.tarball) else {
            throw UpdateError.download("bad tarball URL")
        }
        let (tmpFile, resp) = try await URLSession.shared.download(from: tarURL)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.download("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let tarball = work.appendingPathComponent("pkg.tgz")
        try fm.moveItem(at: tmpFile, to: tarball)

        // 2. Extract. npm tarballs unpack under a top-level `package/` dir.
        log("Extracting…")
        try runProcess("/usr/bin/tar", ["xzf", tarball.path, "-C", work.path], log: log)
        let pkgDir = work.appendingPathComponent("package")
        let builtDist = pkgDir.appendingPathComponent("dist")
        guard fm.fileExists(atPath: builtDist.appendingPathComponent("cli.js").path) else {
            throw UpdateError.extract("package/dist/cli.js missing in tarball")
        }

        // 3. Atomically swap into Application Support.
        log("Installing update…")
        let target = CLIRunner.supportCLIDir
        try fm.createDirectory(at: target.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent("cli.new", isDirectory: true)
        if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try fm.copyItem(at: builtDist, to: staging.appendingPathComponent("dist"))
        let pkgJSON = pkgDir.appendingPathComponent("package.json")
        if fm.fileExists(atPath: pkgJSON.path) {
            try fm.copyItem(at: pkgJSON, to: staging.appendingPathComponent("package.json"))
        }
        try latest.write(to: staging.appendingPathComponent("version.txt"),
                         atomically: true, encoding: .utf8)

        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.moveItem(at: staging, to: target)

        log("Updated to \(latest).")
    }

    // MARK: - Semver compare (a < b)

    static func semverLess(_ a: String, _ b: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: "-")[0]          // drop prerelease
                .split(separator: ".")
                .map { Int($0) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    // MARK: - Process helper (synchronous, streams lines)

    private func runProcess(_ launchPath: String,
                            _ args: [String],
                            cwd: URL? = nil,
                            log: @escaping (String) -> Void) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { fh in
            let d = fh.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
                let t = String(line)
                if !t.isEmpty { DispatchQueue.main.async { log(t) } }
            }
        }
        try p.run()
        p.waitUntilExit()
        handle.readabilityHandler = nil
        if p.terminationStatus != 0 {
            throw UpdateError.extract("`\(launchPath)` exited \(p.terminationStatus)")
        }
    }
}
