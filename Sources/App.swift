import SwiftUI
import AppKit
import ServiceManagement

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
                // Freemium: the app is usable without a license (2 free
                // conversions). Only block on the brief launch license check;
                // the paywall is presented in-flow when the free quota runs out.
                switch license.state {
                case .unknown, .checking:
                    LaunchGateView()
                case .licensed, .unlicensed:
                    RootView(vm: vm, mode: mode)
                }
            }
            .onAppear { license.bootstrap(); vm.onLaunch() }
            // Paywall: shown when an unlicensed user hits the free-quota wall.
            // Dismisses itself once activation flips the license to .licensed.
            .sheet(isPresented: $vm.showPaywall) {
                ActivationView(license: license) { vm.showPaywall = false }
                    .onChange(of: license.state) { newState in
                        if newState == .licensed { vm.showPaywall = false }
                    }
            }
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

        // Keeps the process alive after the window closes, so the daily auto-renew
        // timer keeps firing — the whole point of "auto" renew. Only shown to Pro
        // users with auto-renew on; free users get no menu-bar clutter.
        MenuBarExtra("Viaduct", systemImage: "arrow.triangle.2.circlepath",
                     isInserted: menuBarVisible) {
            RenewMenu(vm: vm)
        }

        Settings {
            SettingsView(mode: mode, vm: vm)
        }
    }

    /// Show the menu-bar item only when auto-renew is actually active.
    private var menuBarVisible: Binding<Bool> {
        Binding(get: { license.isLicensed && vm.autoRenew }, set: { _ in })
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

/// The menu-bar dropdown: renew status at a glance + quick actions. Lives here so
/// the app stays resident (and the daily renew timer keeps firing) after the
/// window is closed.
struct RenewMenu: View {
    @ObservedObject var vm: ConverterViewModel
    @ObservedObject private var history: ConversionHistory

    init(vm: ConverterViewModel) {
        self.vm = vm
        _history = ObservedObject(wrappedValue: vm.history)
    }

    var body: some View {
        // Surface the worst state: any failed renew first, else the soonest expiry.
        if let failed = history.records.first(where: { $0.lastRenewFailed == true }) {
            Text("⚠︎ \(failed.resolvedAppName) renew failed")
        } else if let next = history.records.min(by: { $0.expiresAt < $1.expiresAt }) {
            Text("Next renew: \(next.resolvedAppName) \(next.expiresAt.formatted(.relative(presentation: .named)))")
        } else {
            Text("No extensions to renew")
        }

        Divider()

        Button("Renew Now") { vm.renewNow() }
            .disabled(vm.isRunning)
        Button("Open Viaduct") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        Divider()
        Button("Quit Viaduct") { NSApp.terminate(nil) }
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
