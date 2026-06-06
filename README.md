# voiceMixer — iOS shell

Bare-minimum shell: a host app + an iMessage extension, both showing only the
title **voiceMixer**. Purpose is to prove the build/sign/upload pipeline tonight,
so tomorrow you just paste the real feature into `MessagesViewController.swift`.

## Prereq

- **Xcode 26.x** (required — App Store Connect uploads need the iOS 26 SDK as of
  Apr 28 2026; Xcode 16.x uploads are rejected).

## Open

```bash
cd ios
open voiceMixer.xcodeproj
```

The `.xcodeproj` is committed and edited directly in Xcode (no XcodeGen).

## Run

- Select the **voiceMixer** scheme → your iPhone (or a simulator) → Run.
- The host app shows "voiceMixer". To see the iMessage app: open Messages →
  the app drawer → voiceMixer.

## Ship to TestFlight (internal — skips Beta App Review)

1. Xcode → Signing & Capabilities → pick your Team for **both** targets.
2. App Store Connect → Apps → + → New App → bundle ID `com.aaron.voiceMixer`.
3. Xcode → Product → Archive → Distribute App → TestFlight (internal).
4. App Store Connect → TestFlight → add internal testers.

## Notes / gotchas

- **App icon:** none included. The build only warns, but an upload may need a
  1024px AppIcon. Add an asset catalog with an AppIcon in Xcode before archiving.
- **iMessage drawer icon:** the extension needs an "iMessage App Icon" set to show
  a proper icon in the drawer; without it the slot is blank but still works.
- The `voiceMixer.xcodeproj` is committed — edit it directly in Xcode. Per-user
  state (`xcuserdata`) and build output stay git-ignored.
