import Foundation

/// Locates node + the bundled/updated viaduct CLI and runs it,
/// streaming combined stdout/stderr line-by-line.
final class CLIRunner {
    static let shared = CLIRunner()

    private var process: Process?

    var isRunning: Bool { process?.isRunning ?? false }

    // MARK: - Paths

    /// Where autoupdate writes the freshly-built CLI.
    static var supportCLIDir: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Viaduct", isDirectory: true)
            .appendingPathComponent("cli", isDirectory: true)
        return base
    }

    /// dist shipped inside the .app bundle.
    static var bundledCLIDir: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("cli", isDirectory: true)
    }

    /// Resolve cli.js, preferring the updated copy in Application Support.
    static func resolveCLIScript() -> URL? {
        let updated = supportCLIDir.appendingPathComponent("dist/cli.js")
        if FileManager.default.fileExists(atPath: updated.path) { return updated }
        if let bundled = bundledCLIDir?.appendingPathComponent("dist/cli.js"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return nil
    }

    /// The self-contained node shipped inside the .app (Resources/bin/node).
    /// Present in release builds; absent only if a dev build skipped fetch-node.sh.
    static var bundledNode: URL? {
        guard let url = Bundle.main.resourceURL?
            .appendingPathComponent("bin/node", isDirectory: false) else { return nil }
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Find a usable node binary. Prefers the node bundled inside the app so the
    /// user needs nothing installed; falls back to a system node only if the
    /// bundled one is missing (e.g. an unfetched dev build).
    static func resolveNode() -> URL? {
        if let bundled = bundledNode { return bundled }
        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        // Fall back to `which node` via a login shell (picks up nvm/fnm).
        if let path = whichViaShell("node") { return URL(fileURLWithPath: path) }
        return nil
    }

    static func resolveNpm() -> URL? {
        let candidates = ["/opt/homebrew/bin/npm", "/usr/local/bin/npm", "/usr/bin/npm"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        if let path = whichViaShell("npm") { return URL(fileURLWithPath: path) }
        return nil
    }

    // MARK: - Xcode availability

    /// Whether the build/sign pipeline can run. The hard requirement is a FULL
    /// Xcode install: `safari-web-extension-packager` and the `xcodebuild` signing
    /// of an App-Sandbox .appex ship only with Xcode, not the Command Line Tools.
    /// Apple gives us no lighter path — so we detect it and tell the user plainly
    /// rather than letting the conversion die deep inside xcodebuild.
    static func xcodeReady() -> Bool {
        // `xcrun --find` resolves against the active developer dir. With only CLT
        // selected (or no Xcode at all), the packager is not found → not ready.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["--find", "safari-web-extension-packager"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    static func whichViaShell(_ tool: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v \(tool)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? nil : out
    }

    // MARK: - Run

    enum RunError: LocalizedError {
        case nodeNotFound
        case cliNotFound
        case alreadyRunning

        var errorDescription: String? {
            switch self {
            case .nodeNotFound:
                return "Node.js not found. Install Node 18+ (e.g. `brew install node`)."
            case .cliNotFound:
                return "Bundled CLI not found. Try “Update CLI”."
            case .alreadyRunning:
                return "A task is already running."
            }
        }
    }

    /// Run the CLI with the given args. `onLine` fires on the main queue per output line.
    /// `onExit` fires on the main queue with the exit code.
    func run(args: [String],
             onLine: @escaping (String) -> Void,
             onExit: @escaping (Int32) -> Void) throws {
        guard !isRunning else { throw RunError.alreadyRunning }
        guard let node = Self.resolveNode() else { throw RunError.nodeNotFound }
        guard let cli = Self.resolveCLIScript() else { throw RunError.cliNotFound }

        let p = Process()
        p.executableURL = node
        p.arguments = [cli.path] + args
        // Run from the CLI dir so relative template paths resolve.
        p.currentDirectoryURL = cli.deletingLastPathComponent().deletingLastPathComponent()

        // Ensure node/xcrun tooling is on PATH for child Xcode invocations.
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = extra + ":" + (env["PATH"] ?? "")
        p.environment = env

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        let handle = pipe.fileHandleForReading
        var buffer = Data()
        handle.readabilityHandler = { fh in
            let chunk = fh.availableData
            if chunk.isEmpty { return }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                let line = String(data: lineData, encoding: .utf8) ?? ""
                DispatchQueue.main.async { onLine(line) }
            }
        }

        p.terminationHandler = { proc in
            handle.readabilityHandler = nil
            // Flush any trailing partial line.
            if !buffer.isEmpty {
                let line = String(data: buffer, encoding: .utf8) ?? ""
                DispatchQueue.main.async { onLine(line) }
            }
            DispatchQueue.main.async {
                self.process = nil
                onExit(proc.terminationStatus)
            }
        }

        self.process = p
        try p.run()
    }

    func cancel() {
        process?.terminate()
    }
}
