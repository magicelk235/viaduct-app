// Standalone self-check for RenewalPolicy's scheduling decisions.
// Run: swift dmg/renewal-policy-selfcheck.swift
//
// The pure functions are duplicated here (not imported) because the app has no
// test target and these are dependency-free date math. If Sources/RenewalPolicy.swift
// changes, mirror the change here. Kept as a loose script per this repo's
// convention (see the other dmg/*.swift tools).
import Foundation

enum RenewalPolicy {
    static let signatureLifetime: TimeInterval = 7 * 24 * 3600
    static let renewWindow: TimeInterval = 2 * 24 * 3600
    static let weeklyGap: TimeInterval = 7 * 24 * 3600

    static func versionChanged(stored: String?, latest: String) -> Bool {
        stored != latest
    }
    static func dueForUpdateCheck(lastCheck: Date?, now: Date,
                                  gap: TimeInterval = weeklyGap) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= gap
    }
    static func dueForRenewal(expiresAt: Date, lastBuild: Date, now: Date,
                              window: TimeInterval = renewWindow,
                              minGap: TimeInterval = weeklyGap) -> Bool {
        let nearExpiry = expiresAt <= now.addingTimeInterval(window)
        let rebuiltThisWeek = now.timeIntervalSince(lastBuild) < minGap
        return nearExpiry && !rebuiltThisWeek
    }
}

let now = Date()
let day: TimeInterval = 24 * 3600

// versionChanged
assert(RenewalPolicy.versionChanged(stored: "1.2.0", latest: "1.3.0") == true)
assert(RenewalPolicy.versionChanged(stored: "1.2.0", latest: "1.2.0") == false)
assert(RenewalPolicy.versionChanged(stored: nil, latest: "1.0.0") == true,
       "nil stored → unknown → treat as changed")

// dueForUpdateCheck (weekly gate)
assert(RenewalPolicy.dueForUpdateCheck(lastCheck: nil, now: now) == true,
       "never checked → due")
assert(RenewalPolicy.dueForUpdateCheck(lastCheck: now.addingTimeInterval(-3 * day), now: now) == false,
       "checked 3 days ago → not due (weekly)")
assert(RenewalPolicy.dueForUpdateCheck(lastCheck: now.addingTimeInterval(-8 * day), now: now) == true,
       "checked 8 days ago → due")

// dueForRenewal (near expiry AND not rebuilt this week / once-a-week cap)
assert(RenewalPolicy.dueForRenewal(expiresAt: now.addingTimeInterval(1 * day),
                                   lastBuild: now.addingTimeInterval(-8 * day), now: now) == true,
       "near expiry, not rebuilt this week → due")
assert(RenewalPolicy.dueForRenewal(expiresAt: now.addingTimeInterval(5 * day),
                                   lastBuild: now.addingTimeInterval(-8 * day), now: now) == false,
       "not near expiry → not due")
assert(RenewalPolicy.dueForRenewal(expiresAt: now.addingTimeInterval(1 * day),
                                   lastBuild: now.addingTimeInterval(-2 * day), now: now) == false,
       "rebuilt 2 days ago → once-a-week cap skips it")

print("RenewalPolicy self-check: all assertions passed ✓")
