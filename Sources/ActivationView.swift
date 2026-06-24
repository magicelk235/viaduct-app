import SwiftUI

/// First-run gate. Shown until the user activates a valid Lemon Squeezy key.
struct ActivationView: View {
    @ObservedObject var license: LicenseManager
    @State private var key = ""

    private var checking: Bool { license.state == .checking }

    var body: some View {
        ZStack {
            Theme.Colors.canvas.ignoresSafeArea()

            VStack(spacing: Theme.Space.lg) {
                Image(systemName: "key.fill")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(Theme.Colors.accentBlue)
                    .padding(.bottom, Theme.Space.xs)

                Text("Activate Viaduct")
                    .font(Theme.Font.headingMD())
                    .foregroundStyle(Theme.Colors.ink)

                Text("Paste the license key from your purchase email to unlock conversions.")
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.Colors.mute)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)

                TextField("XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX", text: $key)
                    .textFieldStyle(.glass)
                    .frame(maxWidth: 360)
                    .disabled(checking)
                    .onSubmit(activate)

                if let err = license.lastError {
                    Text(err)
                        .font(Theme.Font.caption())
                        .foregroundStyle(Theme.Colors.accentRed)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }

                Button(action: activate) {
                    HStack(spacing: 6) {
                        if checking { ProgressView().controlSize(.small) }
                        Text(checking ? "Activating…" : "Activate")
                    }
                    .frame(maxWidth: 360)
                }
                .buttonStyle(.raycastPrimary)
                .disabled(checking || key.trimmingCharacters(in: .whitespaces).isEmpty)

                Link("Buy a license", destination: URL(string: "https://magicelk235.gumroad.com/l/viaduct")!)
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.Colors.accentBlue)
                    .padding(.top, Theme.Space.xs)
            }
            .padding(Theme.Space.xxl)
        }
        .frame(minWidth: 540, minHeight: 600)
    }

    private func activate() { license.activate(key: key) }
}
