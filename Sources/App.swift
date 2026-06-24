import SwiftUI
import AppKit

/// Turns on macOS native window tabbing so Cmd+T / the tab bar work. SwiftUI
/// leaves `allowsAutomaticWindowTabbing` off by default, which disables Cmd+T.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
    }
}

@main
struct ViaductApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var vm = ConverterViewModel()
    @StateObject private var license = LicenseManager.shared
    @AppStorage("appMode") private var modeRaw = AppMode.user.rawValue

    private var mode: Binding<AppMode> {
        Binding(get: { AppMode(rawValue: modeRaw) ?? .user },
                set: { modeRaw = $0.rawValue })
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch license.state {
                case .licensed:
                    RootView(vm: vm, mode: mode)
                case .unknown, .checking:
                    LaunchGateView()
                case .unlicensed:
                    ActivationView(license: license)
                }
            }
            .onAppear { license.bootstrap(); vm.onLaunch() }
            // Brand teal as the app-wide accent for in-app SwiftUI controls.
            .tint(Theme.Colors.primary)
            // Follow the system appearance (light OR dark). Chrome is neutral and
            // adaptive; the brand teal accent reads on both — the Apple model.
            .onOpenURL { url in
                handleOpenURL(url)
            }
        }
        .windowResizability(.contentMinSize)
        .commands {

            CommandGroup(after: .toolbar) {
                Picker("Mode", selection: mode) {
                    ForEach(AppMode.allCases) { Text($0.label).tag($0) }
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView(mode: mode, vm: vm)
        }
    }

    private func handleOpenURL(_ url: URL) {
        guard url.scheme == "viaduct" else { return }
        if url.host == "install" {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let items = components?.queryItems
            if let id = items?.first(where: { $0.name == "id" })?.value {
                // The store URL is /detail/NAME/ID — pass NAME so the app isn't named
                // after the random-looking ID when the manifest name is an __MSG_ i18n key.
                let name = items?.first(where: { $0.name == "name" })?.value
                downloadAndConvert(extensionId: id, displayName: name)
            }
        }
    }

    private func downloadAndConvert(extensionId: String, displayName: String? = nil) {
        Task {
            // The old `prod=chromecrx&prodversion=99` endpoint now 404s. This form
            // (prodversion=120 + installsource=ondemand) still returns a real CRX.
            let crxUrlStr = "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=120.0.0.0&acceptformat=crx2,crx3&x=id%3D\(extensionId)%26installsource%3Dondemand%26uc"
            guard let url = URL(string: crxUrlStr) else { return }
            do {
                let (tempURL, response) = try await URLSession.shared.download(from: url)
                // A failed lookup follows the redirect to a 404 HTML page, so status
                // alone isn't enough — confirm the magic bytes are a real CRX ("Cr24").
                let okStatus = (response as? HTTPURLResponse).map { $0.statusCode == 200 } ?? true
                let isCRX = (try? FileHandle(forReadingFrom: tempURL))
                    .map { fh in defer { try? fh.close() }; return fh.readData(ofLength: 4) == Data("Cr24".utf8) } ?? false
                guard okStatus, isCRX else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    await MainActor.run {
                        modeRaw = AppMode.user.rawValue
                        vm.failureSummary = "Couldn't download that extension from the Chrome Web Store (status \(status)). It may be unlisted or removed."
                        vm.phase = .failed
                    }
                    return
                }

                let docsDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                let finalURL = docsDir.appendingPathComponent("\(extensionId).crx")
                if FileManager.default.fileExists(atPath: finalURL.path) {
                    try FileManager.default.removeItem(at: finalURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: finalURL)

                await MainActor.run {
                    modeRaw = AppMode.user.rawValue
                    vm.resetUserFlow()
                    vm.selectInput(path: finalURL.path)
                    // Store name beats the manifest's __MSG_ key / the .crx filename.
                    if let displayName, !displayName.isEmpty {
                        vm.options.appName = displayName
                    }
                    vm.userConvert()
                }
            } catch {
                await MainActor.run {
                    modeRaw = AppMode.user.rawValue
                    vm.failureSummary = "Failed to download extension: \(error.localizedDescription)"
                    vm.phase = .failed
                }
            }
        }
    }
}

/// Brief splash while we validate a stored license on launch.
struct LaunchGateView: View {
    var body: some View {
        ZStack {
            Theme.Colors.canvas.ignoresSafeArea()
            ProgressView().controlSize(.large)
        }
        .frame(minWidth: 540, minHeight: 600)
    }
}

/// Routes between the simple User surface and the full Developer surface.
struct RootView: View {
    @ObservedObject var vm: ConverterViewModel
    @Binding var mode: AppMode

    var body: some View {
        Group {
            switch mode {
            case .user:
                UserModeView(vm: vm, mode: $mode)
            case .developer:
                ContentView(vm: vm, mode: $mode)
                    .frame(minWidth: 820, minHeight: 640)
            }
        }
        .onAppear { vm.checkForUpdates() }
    }
}
