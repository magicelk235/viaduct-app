import SwiftUI
import AppKit

struct SettingsView: View {
    @Binding var mode: AppMode
    @ObservedObject var vm: ConverterViewModel
    @ObservedObject private var history: ConversionHistory

    init(mode: Binding<AppMode>, vm: ConverterViewModel) {
        _mode = mode
        self.vm = vm
        _history = ObservedObject(wrappedValue: vm.history)
    }

    var body: some View {
        ZStack {
            Theme.Colors.canvas.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    Text("Settings")
                        .font(Theme.Font.headingXL())
                        .foregroundStyle(Theme.Colors.ink)
                        .padding(.bottom, Theme.Space.xxs)

                    interfaceCard
                    cliCard
                    signingCard
                    historyCard
                }
                .padding(Theme.Space.xl)
            }
        }
        .frame(width: 460, height: 600)
    }

    // MARK: - Cards

    private var interfaceCard: some View {
        SettingsSection(title: "Interface", symbol: "macwindow") {
            PillTabPicker(options: AppMode.allCases, label: \.label, selection: $mode)
            Text(mode.blurb)
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.Colors.mute)
        }
    }

    private var cliCard: some View {
        SettingsSection(title: "Command-line tool", symbol: "terminal") {
            SettingsRow(icon: "shippingbox", title: "Installed version") {
                Text(vm.installedVersion)
                    .font(Theme.Font.mono())
                    .foregroundStyle(Theme.Colors.body)
            }
            Divider().overlay(Theme.Colors.hairlineSoft)
            HStack {
                Button("Check for Updates") { vm.checkForUpdates() }
                    .buttonStyle(.raycastTertiary)
                    .disabled(vm.updateChecking || vm.isRunning)
                if vm.updateAvailable {
                    Button("Update Now") { vm.updateCLI() }
                        .buttonStyle(.raycastPrimary)
                        .disabled(vm.isRunning)
                }
                Spacer()
                if vm.updateChecking {
                    HStack(spacing: Theme.Space.xs) {
                        ProgressView().controlSize(.small)
                        Text("Checking…")
                            .font(Theme.Font.caption())
                            .foregroundStyle(Theme.Colors.mute)
                    }
                } else if vm.updateAvailable {
                    Label("Update available", systemImage: "arrow.down.circle.fill")
                        .font(Theme.Font.caption())
                        .foregroundStyle(Theme.Colors.accentBlue)
                }
            }
        }
    }

    private var signingCard: some View {
        SettingsSection(title: "Signing", symbol: "signature") {
            Toggle("Auto-renew extensions before they expire",
                   isOn: $vm.autoRenew)
                .toggleStyle(.glass)
                .onChange(of: vm.autoRenew) { _ in vm.startAutoRenew() }
            Text("Free Apple accounts sign extensions for ~7 days. This rebuilds and re-signs your installed extensions before that lapses, so Safari never drops them. Uses the Apple identity from Xcode automatically.")
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.Colors.mute)
        }
    }

    private var historyCard: some View {
        SettingsSection(title: "Converted extensions", symbol: "clock.arrow.circlepath") {
            if !history.records.isEmpty {
                Button("Clear") { history.clear() }
                    .buttonStyle(.raycastGhost)
            }
        } content: {
            if history.records.isEmpty {
                Text("Extensions you convert will be listed here.")
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.Colors.mute)
            } else {
                ScrollView {
                    VStack(spacing: Theme.Space.xs) {
                        ForEach(history.records) { historyRow($0) }
                    }
                }
                .frame(maxHeight: 180)
            }
        }
    }

    private func historyRow(_ rec: ConversionRecord) -> some View {
        HStack(spacing: Theme.Space.md) {
            HistoryIcon(iconData: rec.iconData,
                        monogram: rec.name.first.map(String.init)?.uppercased() ?? "?")
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(rec.name)
                    .font(Theme.Font.bodyStrong())
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1).truncationMode(.middle)
                Text(rec.date.formatted(date: .abbreviated, time: .shortened))
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.Colors.mute)
            }
            Spacer()
            if let path = rec.installedPath {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.raycastGhost)
                .help("Reveal in Finder")
            }
        }
        .padding(.vertical, Theme.Space.xs)
        .padding(.horizontal, Theme.Space.sm)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
            .fill(Theme.Colors.surfaceElevated))
    }
}

// MARK: - Settings building blocks

/// A glass card with an icon + title header and an optional trailing accessory.
private struct SettingsSection<Accessory: View, Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(title: String, symbol: String,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.symbol = symbol
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        RaycastCard(glass: true) {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Colors.mute)
                        .frame(width: 18)
                    Text(title)
                        .font(Theme.Font.headingSM())
                        .foregroundStyle(Theme.Colors.ink)
                    Spacer()
                    accessory()
                }
                content()
            }
        }
    }
}

/// A labeled row: leading icon, title, trailing value.
private struct SettingsRow<Value: View>: View {
    let icon: String
    let title: String
    @ViewBuilder var value: () -> Value

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Colors.ash)
                .frame(width: 18)
            Text(title)
                .font(Theme.Font.body())
                .foregroundStyle(Theme.Colors.body)
            Spacer()
            value()
        }
    }
}
