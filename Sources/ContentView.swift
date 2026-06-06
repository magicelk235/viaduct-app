import SwiftUI

struct ContentView: View {
    @StateObject private var vm = ConverterViewModel()

    var body: some View {
        HSplitView {
            formPane
                .frame(minWidth: 380, idealWidth: 420)
            logPane
                .frame(minWidth: 360)
        }
        .toolbar { toolbarContent }
        .onAppear { vm.checkForUpdates() }
    }

    // MARK: - Form

    private var formPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Input & Output") {
                    pathRow("Extension", text: $vm.options.inputPath, action: vm.pickInput,
                            placeholder: ".zip, .crx, or folder")
                    pathRow("Output dir", text: $vm.options.outputDir, action: vm.pickOutputDir,
                            placeholder: "default: ./<AppName>_Safari")
                    labeledField("App name", $vm.options.appName, placeholder: "extension name")
                    labeledField("Bundle ID", $vm.options.bundleId,
                                 placeholder: "com.chrome2safari.<app>")
                    HStack {
                        Text("Platforms").frame(width: 90, alignment: .leading)
                        Picker("", selection: $vm.options.platforms) {
                            ForEach(Platforms.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                }

                section("Build") {
                    Toggle("Build Xcode project (off = generate only)",
                           isOn: Binding(get: { !vm.options.noBuild },
                                         set: { vm.options.noBuild = !$0 }))
                    Toggle("CI mode (clean-copy resources, TestFlight-safe)", isOn: $vm.options.ci)
                    Toggle("Temp-load only (no Xcode, “Add Temporary Extension…”)",
                           isOn: $vm.options.tempLoad)
                    Toggle("Keep background.type:\"module\"", isOn: $vm.options.keepModule)
                    Toggle("Skip compatibility shim", isOn: $vm.options.noShim)
                    Toggle("Force (convert despite blocking errors)", isOn: $vm.options.force)
                }

                section("Signing") {
                    Picker("", selection: $vm.options.signing) {
                        ForEach(SigningMode.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)
                    if vm.options.signing == .customTeam {
                        labeledField("Team ID", $vm.options.customTeamId, placeholder: "ABCDE12345")
                    }
                }

                section("Install") {
                    Toggle("Install to Applications + register with Safari",
                           isOn: $vm.options.install)
                    if vm.options.install {
                        pathRow("Install dir", text: $vm.options.installDir,
                                action: vm.pickInstallDir, placeholder: "~/Applications")
                        Toggle("Don't quit/relaunch Safari", isOn: $vm.options.noSafariRestart)
                    }
                }

                section("Output detail") {
                    Toggle("Verbose", isOn: $vm.options.verbose)
                }
            }
            .padding(20)
        }
        .disabled(vm.isRunning)
    }

    // MARK: - Log

    private var logPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Output").font(.headline)
                Spacer()
                if let code = vm.lastExitCode {
                    Label(code == 0 ? "Success" : "Failed",
                          systemImage: code == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(code == 0 ? .green : .red)
                        .font(.caption)
                }
                Button("Clear") { vm.clearLog() }
                    .disabled(vm.logLines.isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(vm.logLines.enumerated()), id: \.offset) { idx, line in
                            Text(line.isEmpty ? " " : line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(10)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: vm.logLines.count) { _ in
                    if let last = vm.logLines.indices.last {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if vm.isRunning {
                Button(role: .cancel) { vm.cancel() } label: {
                    Label("Cancel", systemImage: "stop.fill")
                }
            } else {
                Menu {
                    Button("CLI: \(vm.installedVersion)") {}.disabled(true)
                    Divider()
                    Button("Check for CLI Updates") { vm.checkForUpdates() }
                    Button("Update CLI Now") { vm.updateCLI() }
                } label: {
                    Label(vm.updateAvailable ? "Update available" : "CLI",
                          systemImage: vm.updateAvailable
                            ? "arrow.down.circle.fill" : "shippingbox")
                }

                Button { vm.runDoctor() } label: {
                    Label("Doctor", systemImage: "stethoscope")
                }
                Button { vm.runAnalyze() } label: {
                    Label("Analyze", systemImage: "magnifyingglass")
                }
                Button { vm.runConversion() } label: {
                    Label("Convert", systemImage: "play.fill")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Builders

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }

    private func labeledField(_ label: String, _ text: Binding<String>,
                              placeholder: String) -> some View {
        HStack {
            Text(label).frame(width: 90, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func pathRow(_ label: String, text: Binding<String>,
                         action: @escaping () -> Void, placeholder: String) -> some View {
        HStack {
            Text(label).frame(width: 90, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
            Button("Choose…", action: action)
        }
    }
}
