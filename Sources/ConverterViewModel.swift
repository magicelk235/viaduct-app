import SwiftUI
import AppKit
import ServiceManagement

@MainActor
final class ConverterViewModel: ObservableObject {
    @Published var options = ConvertOptions()
    @Published var logLines: [String] = []
    @Published var isRunning = false
    @Published var statusMessage = "Ready."
    @Published var lastExitCode: Int32? = nil

    @Published var updateChecking = false
    @Published var updateAvailable = false
    @Published var installedVersion: String = "unknown"

    // User-mode flow
    @Published var phase: ConvertPhase = .idle
    @Published var installedAppPath: String? = nil
    @Published var failureSummary: String? = nil
    @Published var extInfo: ExtensionInfo? = nil
    @Published var inspecting = false
    /// Highest real track phase reached this run — survives the flip to `.failed`
    /// so the failure card can name the step that broke.
    @Published var lastReachedTrackPhase: ConvertPhase? = nil

    /// Set when an unlicensed user hits the free-quota wall; drives the paywall sheet.
    @Published var showPaywall = false

    /// Set when a conversion needs full Xcode but it isn't installed/selected.
    /// Drives the honest "install Xcode" card instead of a silent build failure.
    @Published var needsXcode = false

    /// Chrome Web Store id of the install in flight (store flow only). Stamped
    /// onto the history record so auto-renew can re-download the source by id.
    var pendingStoreId: String?

    let history = ConversionHistory()

    /// Auto re-sign installed extensions before the free-account 7-day signature
    /// lapses. On by default — it's the thing that keeps extensions from vanishing.
    /// Pro-only: unlicensed users can't keep extensions alive past the ~7-day
    /// Apple free-signing window, which is the upgrade lever.
    @AppStorage("autoRenew") var autoRenew = true

    /// Whether auto-renew is actually allowed to run — the stored toggle AND a
    /// valid license. Gating here (not just the toggle UI) means a free user
    /// can't keep renewing by flipping the persisted flag some other way.
    var autoRenewEnabled: Bool { autoRenew && LicenseManager.shared.isLicensed }

    private let runner = CLIRunner.shared
    private let updater = CLIUpdater.shared
    private lazy var renewer = ExtensionRenewer(history: history)
    private var renewTimer: Timer?

    init() {
        installedVersion = updater.installedVersion ?? "unknown"
    }

    /// Launch hook: auto-update the CLI and start auto-renew. Idempotent.
    func onLaunch() {
        // Auto-update the CLI on launch (self-installs if a newer version exists).
        checkForUpdates()
        // Forget extensions the user deleted from Finder, regardless of renew state.
        history.pruneDeleted()
        startAutoRenew()
    }

    /// Kick off auto-renew at launch and re-check daily. Idempotent.
    func startAutoRenew() {
        // Relaunch at login so the daily renew timer survives reboots — auto-renew
        // is worthless if the app isn't running when the 7-day window closes.
        syncLoginItem()
        guard autoRenewEnabled else { return }
        renewer.renewIfNeeded()
        guard renewTimer == nil else { return }
        renewTimer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.autoRenewEnabled, !self.isRunning else { return }
                self.renewer.renewIfNeeded()
            }
        }
    }

    /// Manual renew trigger from the menu bar. Same due-check as the timer.
    /// Pro-only: re-signing before expiry is a paid feature (matches the
    /// Settings auto-renew toggle, which is also licensed-only). Guard here so
    /// no caller can trigger a renew on the free tier.
    func renewNow() {
        guard LicenseManager.shared.isLicensed else { showPaywall = true; return }
        guard autoRenewEnabled, !isRunning else { return }
        renewer.renewIfNeeded()
    }

    /// Register/unregister the app as a login item to match `autoRenewEnabled`.
    /// ponytail: SMAppService.mainApp — no separate helper bundle/plist to maintain.
    func syncLoginItem() {
        do {
            if autoRenewEnabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            appendLog("⚠︎ Login-item update failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Logging

    @discardableResult
    func appendLog(_ line: String) -> String {
        let clean = stripANSI(line)
        logLines.append(clean)
        if logLines.count > 5000 { logLines.removeFirst(logLines.count - 5000) }
        return clean
    }

    func clearLog() { logLines.removeAll() }

    // MARK: - Run actions

    func runConversion() {
        let args = options.conversionArgs()
        // A real build/sign needs full Xcode; --no-build / --temp-load do not.
        let needsBuild = !args.contains("--no-build") && !args.contains("--temp-load")
        if needsBuild, !CLIRunner.xcodeReady() {
            needsXcode = true
            statusMessage = "Full Xcode required for build/sign."
            appendLog("\u{2717} " + Self.xcodeMissingMessage)
            appendLog("  Tip: use --temp-load or --no-build to convert without Xcode.")
            return
        }
        runCLI(args: args, label: "Conversion")
    }
    func runAnalyze()    { runCLI(args: options.analyzeArgs(),   label: "Analysis") }
    func runDoctor()     { runCLI(args: ConvertOptions.doctorArgs(), label: "Toolchain check") }

    // MARK: - User-mode one-tap convert

    /// Convert + auto-install + register, forcing the simplest safe option set.
    /// Drives `phase` for the animated UI instead of exposing the raw log.
    func userConvert() {
        guard !isRunning else { return }
        guard !options.inputPath.isEmpty,
              FileManager.default.fileExists(atPath: options.inputPath) else {
            failureSummary = "Pick an extension first."
            phase = .failed
            return
        }
        // Freemium gate is enforced in runCLI (the choke point all conversion
        // paths funnel through, including Developer mode), so it can't be
        // bypassed by switching modes.

        // Force the user-friendly path: build, install to Applications, register with Safari.
        options.noBuild = false
        options.tempLoad = false
        options.install = true
        // Auto-detect the Apple identity (free or paid). A team-signed extension
        // survives Safari quitting, and lets auto-renew re-sign before expiry.
        // The CLI falls back to ad-hoc on its own if no team is found.
        options.signing = .autoTeam
        if options.appName.isEmpty {
            options.appName = URL(fileURLWithPath: options.inputPath)
                .deletingPathExtension().lastPathComponent
        }

        // Full Xcode is required to package + sign the extension (Apple ships the
        // Safari packager only with Xcode). Detect it up front and explain, rather
        // than letting the run die deep inside xcodebuild with a cryptic log.
        guard CLIRunner.xcodeReady() else {
            needsXcode = true
            failureSummary = Self.xcodeMissingMessage
            phase = .failed
            Feedback.failure()
            return
        }

        installedAppPath = nil
        failureSummary = nil
        lastReachedTrackPhase = nil
        phase = .extracting
        runCLI(args: options.conversionArgs(), label: "Conversion", userMode: true)
    }

    /// Save the just-finished conversion to history.
    private func recordConversion() {
        // Manifest name unless it's an unresolved __MSG_ i18n key; then the store
        // display name (appName), then the filename — which for store installs is
        // the random-looking extension id, so it's the last resort.
        let name = extInfo?.name.hasPrefix("__MSG_") == false
            ? extInfo!.name
            : (!options.appName.isEmpty
                ? options.appName
                : URL(fileURLWithPath: options.inputPath).deletingPathExtension().lastPathComponent)
        // Stash a durable copy of the source so auto-renew can rebuild later even if
        // the user moves/deletes the original (or the cached store .crx is purged).
        let archived = ExtensionRenewer.archiveSource(options.inputPath, appName: options.appName)
        history.add(name: name, sourcePath: archived ?? options.inputPath,
                    appName: options.appName,
                    installedPath: installedAppPath, iconData: extInfo?.icon?.pngData(),
                    storeId: pendingStoreId)
        pendingStoreId = nil
        // Count this against the free quota (no-op once licensed).
        LicenseManager.shared.recordFreeConversion()
    }

    /// The honest, actionable message shown when full Xcode is missing. Stated
    /// plainly: this is an Apple requirement we cannot bundle away.
    static let xcodeMissingMessage =
        "Converting to a Safari extension needs Apple\u{2019}s full Xcode, which only Apple can provide \u{2014} it isn\u{2019}t something the app can bundle. Install it (free, from the App Store), open it once to finish setup, then try again."

    /// Open Xcode's App Store page so the user can install it in one click.
    func openXcodeInstall() {
        // Apple\u{2019}s Xcode App Store product page.
        if let url = URL(string: "macappstore://apps.apple.com/app/xcode/id497799835") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Reveal a previously-installed extension app in Finder (used by history).
    func reveal(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Re-run a past conversion: reload its source and kick off the one-tap flow.
    /// Skips silently if the source file is gone (e.g. moved/deleted since).
    func reconvert(_ record: ConversionRecord) {
        guard FileManager.default.fileExists(atPath: record.sourcePath) else {
            failureSummary = "Original extension no longer exists at \(record.sourcePath)."
            phase = .failed
            return
        }
        resetUserFlow()
        selectInput(path: record.sourcePath)
        userConvert()
    }

    /// Put the whole log on the pasteboard (used by the failure card).
    func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logLines.joined(separator: "\n"), forType: .string)
    }

    func resetUserFlow() {
        phase = .idle
        installedAppPath = nil
        failureSummary = nil
        lastExitCode = nil
        extInfo = nil
        needsXcode = false
        options.inputPath = ""
        options.appName = ""
    }

    private func runCLI(args: [String], label: String, userMode: Bool = false) {
        if let err = preflight(args: args) {
            statusMessage = err
            appendLog("✗ \(err)")
            if userMode { failureSummary = err; phase = .failed }
            return
        }
        // Freemium gate at the choke point: every conversion path lands here,
        // so an unlicensed user can't bypass the quota via Developer mode.
        // Analyze/doctor runs aren't conversions and stay free.
        if label == "Conversion", !LicenseManager.shared.canConvert {
            showPaywall = true
            statusMessage = "Free conversions used. Activate a license to continue."
            appendLog("✗ Free conversion limit reached.")
            if userMode { phase = .idle }
            return
        }
        isRunning = true
        lastExitCode = nil
        statusMessage = "\(label) running…"
        appendLog("$ viaduct \(args.joined(separator: " "))")
        do {
            try runner.run(args: args, onLine: { [weak self] line in
                guard let self else { return }
                let clean = self.appendLog(line)
                if userMode { self.advancePhase(from: clean) }
            }, onExit: { [weak self] code in
                guard let self else { return }
                self.isRunning = false
                self.lastExitCode = code
                self.statusMessage = code == 0
                    ? "\(label) finished."
                    : "\(label) failed (exit \(code))."
                self.appendLog(code == 0 ? "✓ Done." : "✗ Exit \(code).")
                if code == 0, label == "Conversion" { self.recordConversion() }
                if userMode { self.finishUserPhase(code: code) }
            })
        } catch {
            isRunning = false
            statusMessage = error.localizedDescription
            appendLog("✗ \(error.localizedDescription)")
            if userMode { failureSummary = error.localizedDescription; phase = .failed }
        }
    }

    /// Move `phase` forward (never backward) based on a CLI line; capture install path.
    private func advancePhase(from line: String) {
        if let installed = installedPath(from: line) { installedAppPath = installed }
        if let next = ConvertPhase.detect(from: line), next.rawValue > phase.rawValue {
            phase = next
            if ConvertPhase.track.contains(next) { lastReachedTrackPhase = next }
            Feedback.step()
        }
    }

    private func finishUserPhase(code: Int32) {
        if code == 0 {
            // CLI is done, but let the bar race the last stretch to 100% first.
            // `completeFinishing()` (fired by the progress bar at 100%) flips to
            // .done and opens the freshly-converted extension app.
            phase = .finishing
        } else {
            failureSummary = "The converter exited with code \(code). Open Developer mode to see why."
            phase = .failed
            Feedback.failure()
        }
    }

    /// Called by the progress bar once it reaches 100% during `.finishing`.
    /// Marks the flow done. The user opens the converted extension manually via
    /// the "Open extension" button — we no longer launch it automatically.
    func completeFinishing() {
        guard phase == .finishing else { return }
        phase = .done
        Feedback.success()
    }

    /// Launch the freshly-built Safari Web Extension host app so its enable
    /// sheet appears. Falls back to revealing it in Finder if launch fails.
    func openConvertedApp() {
        guard let path = installedAppPath else { return }
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.openApplication(at: url,
                                           configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if error != nil {
                DispatchQueue.main.async {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
    }

    /// Pull the installed .app path out of "Installed → /path" or "Installed: /path".
    private func installedPath(from line: String) -> String? {
        for marker in ["Installed → ", "Installed: "] {
            if let r = line.range(of: marker) {
                let p = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !p.isEmpty { return p }
            }
        }
        return nil
    }

    private func preflight(args: [String]) -> String? {
        // Doctor/analyze only need input for analyze.
        if args.contains("--analyze") || args == ConvertOptions.doctorArgs() {
            if args.contains("--analyze"), options.inputPath.isEmpty {
                return "Choose an input first."
            }
            return nil
        }
        return options.validationError()
    }

    func cancel() {
        runner.cancel()
        appendLog("⚠︎ Cancelled.")
        statusMessage = "Cancelled."
        isRunning = false
    }

    // MARK: - Update

    /// Check the registry and, if a newer CLI exists, install it immediately —
    /// no "Update Now" click. Skips if a conversion is mid-flight (don't swap the
    /// CLI out from under a running process).
    func checkForUpdates() {
        guard !updateChecking else { return }
        updateChecking = true
        Task {
            defer { updateChecking = false }
            do {
                let available = try await updater.updateAvailable()
                updateAvailable = available
                guard available else { statusMessage = "CLI is up to date."; return }
                guard !isRunning else { statusMessage = "CLI update queued (busy)."; return }
                await applyUpdate()
            } catch {
                statusMessage = "Update check failed: \(error.localizedDescription)"
            }
        }
    }

    /// Download + swap the latest CLI. Shared by auto-update and the manual button.
    private func applyUpdate() async {
        statusMessage = "Updating CLI…"
        appendLog("— Auto-updating CLI —")
        do {
            try await updater.update(rawLog: { [weak self] line in self?.appendLog(line) })
            installedVersion = updater.installedVersion ?? "unknown"
            updateAvailable = false
            statusMessage = "CLI updated to \(installedVersion)."
        } catch {
            statusMessage = "Update failed: \(error.localizedDescription)"
            appendLog("✗ \(error.localizedDescription)")
        }
    }

    func updateCLI() {
        Task { await applyUpdate() }
    }

    // MARK: - File pickers

    /// Set the input path, derive a default app name, and inspect for name + icon.
    func selectInput(path: String) {
        options.inputPath = path
        if options.appName.isEmpty {
            options.appName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
        extInfo = nil
        inspecting = true
        ExtensionInspector.inspect(path: path) { [weak self] info in
            guard let self else { return }
            self.inspecting = false
            self.extInfo = info
            // Prefer the manifest name for the app if the user hasn't typed one.
            if let n = info?.name, !n.hasPrefix("__MSG_"), self.options.appName.isEmpty {
                self.options.appName = n
            }
        }
    }

    func pickInput() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a .zip, .crx, or unpacked extension folder."
        if panel.runModal() == .OK, let url = panel.url {
            selectInput(path: url.path)
        }
    }

    func pickOutputDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Choose an output directory."
        if panel.runModal() == .OK, let url = panel.url {
            options.outputDir = url.path
        }
    }

    func pickInstallDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Choose an install directory."
        if panel.runModal() == .OK, let url = panel.url {
            options.installDir = url.path
        }
    }

    // MARK: - Helpers

    private func stripANSI(_ s: String) -> String {
        // Remove CSI escape sequences the CLI emits for color.
        guard s.contains("\u{1B}[") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "\u{1B}",
               let next = s.index(i, offsetBy: 1, limitedBy: s.endIndex),
               next < s.endIndex, s[next] == "[" {
                var j = s.index(after: next)
                while j < s.endIndex, !("@"..."~").contains(s[j]) {
                    j = s.index(after: j)
                }
                if j < s.endIndex { j = s.index(after: j) }
                i = j
            } else {
                out.append(s[i])
                i = s.index(after: i)
            }
        }
        return out
    }
}
