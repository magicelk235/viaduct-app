# Extension Auto-Update from Chrome Web Store — Design

**Date:** 2026-07-15
**Status:** Approved, ready for implementation plan

## Problem

Viaduct converts Chrome extensions to Safari and installs them. Once installed,
the converted extension is frozen at whatever version was converted. When the
upstream extension ships a new version on the Chrome Web Store (bug fixes,
security patches, features), the user's Safari copy stays stale. They'd have to
manually reconvert to get the update.

Goal: for store-flow installs, detect a newer upstream version and rebuild +
reinstall automatically — keeping the Safari copy current without user action.

## Why this is cheap: it piggybacks on auto-renew

The `ExtensionRenewer` already does the hard 90%:

- `ChromeStore.downloadCRX(id:)` — pulls the latest `.crx` from the Chrome Web
  Store by `storeId` (already used by the store-install flow and renew fallback).
- Rebuild + re-sign + reinstall via the CLI, `signing: .autoTeam`, `force: true`.
- Runs on launch + on a daily timer.
- Failure notification via `UNUserNotificationCenter`.
- `ConversionHistory` persists each install with its `storeId`.

Auto-update is **auto-renew with a version comparison added**, plus its own
Pro-gated, default-off toggle.

## What's missing

1. **No version on the record.** `ConversionRecord` has no `version` field, so
   there's nothing to compare a freshly downloaded manifest against.
2. **No update trigger.** Renew only fires when a build nears its 7-day
   signature expiry. Auto-update must also fire when the upstream version
   changed, independent of expiry.

## Decisions (from brainstorming)

| Decision | Choice |
|---|---|
| Control | A single Settings toggle, **default OFF** |
| Toggle OFF | **Zero extra CWS traffic** — no version polling, no badges. Behavior identical to today. |
| Toggle ON | **Silent auto-apply** — new version rebuilds + reinstalls on the daily tick, like auto-renew. No click, no prompt. |
| Gating | **Pro-only**, mirroring auto-renew (`autoRenew` is licensed-only). |

## Non-goals (YAGNI)

- **Non-store installs** (local `.zip`/`.crx`/folder). No upstream to poll —
  the archived source *is* the latest the user has. Auto-update only touches
  records with a `storeId`.
- **Notify-only mode / update badges.** Silent only. A second sub-toggle can be
  added later if wanted.
- **A lighter version-only CWS endpoint.** None exists reliably; we download the
  `.crx` and read its manifest version. Same request auto-renew already makes.
- **Changelog / release notes surfacing.** Out of scope.

## Design

### 1. Record the version (`ConversionHistory.swift`)

Add to `ConversionRecord`:

```swift
/// Upstream extension version (manifest "version") at conversion time.
/// Auto-update compares the latest CWS manifest against this to decide whether
/// to rebuild. Optional so old records still decode.
var version: String?
```

Thread it through `add(...)` (new optional param, default `nil`) and add a
setter used after a successful update:

```swift
func markUpdated(id: ConversionRecord.ID, version: String, installedPath: String?) {
    // stamps version + lastSigned (an update is also a fresh sign) + clears fail flag
}
```

### 2. Capture the version at conversion (`ExtensionInfo.swift` + `ConverterViewModel.swift`)

`ExtensionInspector` already extracts and parses `manifest.json`. Add one field
to `ExtensionInfo`:

```swift
var version: String?   // manifest["version"] as? String
```

In `recordConversion()`, pass `extInfo?.version` into `history.add(...)`.

### 3. Version check in the renewer (`ExtensionRenewer.swift`)

The renewer's `renew(...)` already downloads the `.crx` for store installs when
the source is missing. Generalize so an **update pass** can:

1. For each store record (`storeId != nil`), when auto-update is enabled:
   download the latest `.crx`, read its manifest `version`.
2. If that version `!=` the record's stored `version` → treat as due: rebuild
   from the fresh source, then `markUpdated(...)` with the new version.
3. If unchanged → do nothing (leave the archived source and record alone).

Add an `updateIfNeeded()` entry point parallel to `renewIfNeeded()`:

- Guarded by a new `autoUpdateEnabled` flag on the VM (`autoUpdate &&
  isLicensed`).
- Reuses the existing single-flight (`running`, `runner.isRunning`) guard so an
  update and a renew never run concurrently.
- Silent, best-effort, same failure notification path.

**Version comparison:** exact string inequality (`latest != stored`), not
semver-less. Chrome versions are monotonic on the store; if the string differs,
it's a new upload we should adopt. (Avoids the edge case where a publisher's
version scheme doesn't parse as semver.)

**ponytail:** reuse `renew(rec)`'s rebuild tail verbatim — one rebuild codepath.
The only new logic is "download crx → read manifest version → compare".

### 4. Wiring (`ConverterViewModel.swift`)

- New stored flag: `@AppStorage("autoUpdate") var autoUpdate = false`.
- New gate: `var autoUpdateEnabled: Bool { autoUpdate && LicenseManager.shared.isLicensed }`.
- In `startAutoRenew()` (already the daily-timer owner), after
  `renewer.renewIfNeeded()`, call `renewer.updateIfNeeded()` when
  `autoUpdateEnabled`. The daily timer body does the same. **When
  `autoUpdate` is off, `updateIfNeeded()` is never called → no CWS traffic.**

The login-item / relaunch-at-login logic already exists for auto-renew and
covers auto-update for free (same daily timer).

### 5. Settings UI (`SettingsView.swift`)

In `signingCard` (already the auto-renew card, already Pro-gated), add a second
toggle below auto-renew:

```swift
Toggle("Auto-update extensions from the Chrome Web Store",
       isOn: licensed ? $vm.autoUpdate : .constant(false))
    .toggleStyle(.glass)
    .disabled(!licensed)
    .onChange(of: vm.autoUpdate) { _ in vm.startAutoRenew() }
```

Caption: "When an extension you installed from the Chrome Web Store ships a new
version, Viaduct rebuilds and reinstalls it automatically. Off by default;
store-page installs only." Optionally show the tracked `version` in each history
row.

## Data flow

```
daily tick / launch  (only if autoUpdateEnabled)
      │
      ▼
updateIfNeeded()  →  for each record with storeId:
      │                 downloadCRX(storeId) → read manifest version
      │                 version != record.version ?
      │                        │yes                 │no
      │                        ▼                    ▼
      │                 rebuild via CLI          skip
      │                 (reuse renew tail)
      │                        ▼
      │                 markUpdated(version, installedPath)
      ▼
(failure → markRenewFailed + notify, same as renew)
```

## Risks

- **CWS ToS / rate-limiting (primary risk, not code).** Downloading `.crx` from
  `clients2.google.com/service/update2/crx` violates Chrome Web Store ToS and the
  endpoint can be rate-limited or blocked. Viaduct already hits it for
  store-installs and renew, so this adds no *new* legal surface — but daily
  polling of every store extension sustains automated traffic. **Mitigated by
  default-off:** no polling happens unless the user opts in. Consider a modest
  cap / spacing if a user has many store installs (out of scope for v1;
  `ponytail:` note it in code).
- **Bad upstream version lands silently.** Silent auto-apply means a broken new
  upstream version reinstalls without a prompt. Acceptable: it mirrors how Chrome
  itself auto-updates extensions, and the user opted in. Failure (not
  regression) is still surfaced via notification.
- **Version-string quirks.** Handled by exact-inequality compare, not semver.

## Testing

- `ConversionRecord` with old JSON (no `version`) still decodes → `version ==
  nil`, treated as "unknown", first update pass adopts current CWS version.
- `updateIfNeeded()` with autoUpdate off → makes zero network calls (assert no
  `downloadCRX`).
- Version unchanged → no rebuild. Version changed → exactly one rebuild +
  `markUpdated`.
- Non-store record (`storeId == nil`) → skipped by the update pass.
- Free (unlicensed) → `autoUpdateEnabled == false` → skipped even if the flag is
  flipped in defaults.

## Effort

~40–60 lines net across 5 existing files. No new dependencies, no new network
codepath (reuses `ChromeStore.downloadCRX`), no new CLI path (reuses the
`.autoTeam` rebuild). One new struct field, one new flag, one new toggle.
