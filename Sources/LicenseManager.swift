import Foundation
import Combine

/// Gates the app behind a Gumroad license key.
///
/// Flow: user pastes a key → `activate` calls Gumroad's license verify
/// endpoint. On success we store the key in the Keychain. Every launch we
/// re-verify, but a previously-verified key keeps working offline via the
/// cached timestamp so a flaky network never locks a paying user out.
///
/// Gumroad license API: https://docs.gumroad.com/#verify-a-license
/// POST https://api.gumroad.com/v2/licenses/verify
///   product_id=<id>&license_key=<key>&increment_uses_count=false
/// Returns: { success, uses, purchase:{ refunded, disputed, chargebacked, ... } }
@MainActor
final class LicenseManager: ObservableObject {
    static let shared = LicenseManager()

    // MARK: - Config (fill in from your Gumroad product)

    /// Gumroad product ID — stable even if you rename the product URL slug.
    /// From the product's Settings/Advanced page.
    private let productID = "-7WMe9QfKNdzB5rmGZjMdw=="

    /// Optional hard cap on activations per key. Gumroad increments `uses` each
    /// verify; we only bump it on first activation. 0 = unlimited.
    private let maxActivations = 0

    // MARK: - Published state

    enum State: Equatable {
        case unknown          // still checking on launch
        case unlicensed       // no key, show activation
        case licensed         // good to go
        case checking         // network call in flight
    }

    @Published private(set) var state: State = .unknown
    @Published var lastError: String?

    // MARK: - Keychain-backed storage

    private let keyService = "com.viaduct.app.license"
    private let keyAccountKey = "license-key"

    private var storedKey: String? {
        get { Keychain.read(service: keyService, account: keyAccountKey) }
        set { Keychain.write(service: keyService, account: keyAccountKey, value: newValue) }
    }

    /// Last time a server verification succeeded — used for the offline grace window.
    private var lastValidEpoch: Double {
        get { UserDefaults.standard.double(forKey: "license-last-valid") }
        set { UserDefaults.standard.set(newValue, forKey: "license-last-valid") }
    }

    /// How long a cached-valid license keeps working with no network.
    private let offlineGraceDays: Double = 14

    private let verifyURL = URL(string: "https://api.gumroad.com/v2/licenses/verify")!

    var isLicensed: Bool { state == .licensed }

    // MARK: - Free tier (freemium)

    /// How many conversions an unlicensed user gets before the hard lock.
    let freeQuota = 2

    /// Monotonic count of conversions an unlicensed user has spent. Soft
    /// (UserDefaults) — a prefs wipe resets it, but that only buys 2 more free
    /// signed conversions before the wall returns. ponytail: soft counter, move
    /// to StoreKit/server only if free-tier abuse proves material.
    private(set) var freeConversionsUsed: Int {
        get { UserDefaults.standard.integer(forKey: "freeConversionsUsed") }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: "freeConversionsUsed")
        }
    }

    /// Free conversions left before the paywall (0 once exhausted).
    var freeConversionsRemaining: Int { max(0, freeQuota - freeConversionsUsed) }

    /// The gate `userConvert()` checks: licensed users always pass; unlicensed
    /// users pass until they've spent their free quota.
    var canConvert: Bool { isLicensed || freeConversionsRemaining > 0 }

    /// Spend one free conversion. No-op for licensed users (unlimited).
    func recordFreeConversion() {
        guard !isLicensed else { return }
        freeConversionsUsed += 1
    }

    // MARK: - Launch check

    /// Decide initial state. If we have a stored key, re-verify online;
    /// fall back to the offline grace window when the network is down.
    func bootstrap() {
        guard let key = storedKey, !key.isEmpty else {
            state = .unlicensed
            return
        }
        state = .checking
        Task {
            do {
                // Don't bump the uses counter on a routine launch re-check.
                try await verify(key: key, incrementUses: false)
                lastValidEpoch = Date().timeIntervalSince1970
                state = .licensed
            } catch let e as LicenseError where e.serverSaidNo {
                // Server reached us and rejected it (refunded/disputed/invalid).
                clear()
                state = .unlicensed
                lastError = e.message
            } catch {
                // Network failure — honor the offline grace window.
                if withinOfflineGrace() {
                    state = .licensed
                } else {
                    state = .unlicensed
                    lastError = "Couldn't verify your license and the offline grace period expired. Reconnect and try again."
                }
            }
        }
    }

    private func withinOfflineGrace() -> Bool {
        guard lastValidEpoch > 0 else { return false }
        let age = Date().timeIntervalSince1970 - lastValidEpoch
        return age < offlineGraceDays * 86_400
    }

    // MARK: - Activate (first-run key entry)

    func activate(key rawKey: String) {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { lastError = "Enter a license key."; return }
        lastError = nil
        state = .checking
        Task {
            do {
                // First activation: bump the uses counter so we can enforce a cap.
                try await verify(key: key, incrementUses: maxActivations > 0)
                storedKey = key
                lastValidEpoch = Date().timeIntervalSince1970
                state = .licensed
            } catch let e as LicenseError {
                lastError = e.message
                state = .unlicensed
            } catch {
                lastError = "Activation failed: \(error.localizedDescription)"
                state = .unlicensed
            }
        }
    }

    func clear() {
        storedKey = nil
        lastValidEpoch = 0
    }

    /// Gumroad has no server-side deactivation; this just forgets the key locally
    /// so the user can enter a different one (e.g. moving machines).
    func deactivateAndClear() {
        clear()
        state = .unlicensed
    }

    // MARK: - Networking

    struct LicenseError: Error {
        let message: String
        /// True when the server explicitly rejected the key (vs a network failure).
        /// Drives whether bootstrap clears the stored key or applies offline grace.
        var serverSaidNo = false
    }

    /// POST /verify. Throws `LicenseError(serverSaidNo: true)` when Gumroad
    /// rejects the key, plain `LicenseError` / transport error otherwise.
    private func verify(key: String, incrementUses: Bool) async throws {
        let body = "product_id=\(enc(productID))"
            + "&license_key=\(enc(key))"
            + "&increment_uses_count=\(incrementUses ? "true" : "false")"

        var req = URLRequest(url: verifyURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = body.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        guard let http = resp as? HTTPURLResponse else {
            throw LicenseError(message: "No response from license server.")
        }

        let success = (json["success"] as? Bool) ?? false
        // Gumroad returns 404 + {success:false, message:"..."} for an unknown key.
        if !success {
            let msg = (json["message"] as? String) ?? "Invalid license key."
            throw LicenseError(message: msg, serverSaidNo: http.statusCode != 0 && http.statusCode < 500)
        }

        // Refunded / disputed / chargebacked purchases must lose access.
        if let purchase = json["purchase"] as? [String: Any] {
            for flag in ["refunded", "disputed", "chargebacked"] where (purchase[flag] as? Bool) == true {
                throw LicenseError(message: "This purchase was \(flag); the license is no longer valid.",
                                   serverSaidNo: true)
            }
            // Subscription products: reject if cancelled/ended.
            if let ended = purchase["subscription_ended_at"] as? String, !ended.isEmpty {
                throw LicenseError(message: "This subscription has ended.", serverSaidNo: true)
            }
        }

        // Optional activation cap.
        if maxActivations > 0, let uses = json["uses"] as? Int, uses > maxActivations {
            throw LicenseError(message: "This key has been activated on too many machines.",
                               serverSaidNo: true)
        }
    }

    private func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
}

// MARK: - Keychain (tiny generic-password wrapper)

enum Keychain {
    static func read(service: String, account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(service: String, account: String, value: String?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }
}
