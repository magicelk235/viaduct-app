import SwiftUI
import AppKit

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

    private let runner = CLIRunner.shared
    private let updater = CLIUpdater.shared

    init() {
        installedVersion = updater.installedVersion ?? "unknown"
    }

    // MARK: - Logging

    func appendLog(_ line: String) {
        logLines.append(stripANSI(line))
        if logLines.count > 5000 { logLines.removeFirst(logLines.count - 5000) }
    }

    func clearLog() { logLines.removeAll() }

    // MARK: - Run actions

    func runConversion() { runCLI(args: options.conversionArgs(), label: "Conversion") }
    func runAnalyze()    { runCLI(args: options.analyzeArgs(),   label: "Analysis") }
    func runDoctor()     { runCLI(args: ConvertOptions.doctorArgs(), label: "Toolchain check") }

    private func runCLI(args: [String], label: String) {
        if let err = preflight(args: args) {
            statusMessage = err
            appendLog("✗ \(err)")
            return
        }
        isRunning = true
        lastExitCode = nil
        statusMessage = "\(label) running…"
        appendLog("$ chrome2safari \(args.joined(separator: " "))")
        do {
            try runner.run(args: args, onLine: { [weak self] line in
                self?.appendLog(line)
            }, onExit: { [weak self] code in
                guard let self else { return }
                self.isRunning = false
                self.lastExitCode = code
                self.statusMessage = code == 0
                    ? "\(label) finished."
                    : "\(label) failed (exit \(code))."
                self.appendLog(code == 0 ? "✓ Done." : "✗ Exit \(code).")
            })
        } catch {
            isRunning = false
            statusMessage = error.localizedDescription
            appendLog("✗ \(error.localizedDescription)")
        }
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

    func checkForUpdates() {
        updateChecking = true
        Task {
            defer { updateChecking = false }
            do {
                updateAvailable = try await updater.updateAvailable()
                statusMessage = updateAvailable
                    ? "CLI update available."
                    : "CLI is up to date."
            } catch {
                statusMessage = "Update check failed: \(error.localizedDescription)"
            }
        }
    }

    func updateCLI() {
        isRunning = true
        statusMessage = "Updating CLI…"
        appendLog("— Updating CLI from GitHub —")
        Task {
            defer { isRunning = false }
            do {
                try await updater.update(log: { [weak self] line in
                    self?.appendLog(line)
                })
                installedVersion = updater.installedVersion ?? "unknown"
                updateAvailable = false
                statusMessage = "CLI updated."
            } catch {
                statusMessage = "Update failed: \(error.localizedDescription)"
                appendLog("✗ \(error.localizedDescription)")
            }
        }
    }

    // MARK: - File pickers

    func pickInput() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a .zip, .crx, or unpacked extension folder."
        if panel.runModal() == .OK, let url = panel.url {
            options.inputPath = url.path
            if options.appName.isEmpty {
                options.appName = url.deletingPathExtension().lastPathComponent
            }
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
