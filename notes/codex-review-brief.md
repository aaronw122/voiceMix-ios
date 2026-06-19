# Tribunal Review: VoiceMixCore Swift package extraction

You are running a **tribunal-style review** (Investigator → Devil's Advocate → Judge) on an
uncommitted refactor in this repository. You have full repo access; run any read-only commands
you need (`git diff`, `git status`, `cat`, `xcodebuild`, `swiftc -typecheck`, etc.). Do NOT modify
any source files — this is review only.

## Context: what was done and why

The app is an iMessage extension. SwiftUI Previews do **not** work in app-extension targets, so to
get a fast UI-iteration loop the SwiftUI/UI layer was extracted into a **local Swift package**
named `VoiceMixCore` (at repo root `VoiceMixCore/`). The iMessage extension target now contains only
`MessagesExtension/MessagesViewController.swift` (the `Messages`-framework host) and depends on the
package, mounting `VoiceTransformView` via `UIHostingController`.

Nine files were moved (via `git mv`) from `MessagesExtension/` into
`VoiceMixCore/Sources/VoiceMixCore/`:
VoiceTransformView, VoiceCatalog, ConvertService, MockConvertService, LiveConvertService,
AudioRecorder, WaveformVideoRenderer, Config, VoiceCatalogPreflight.
`sample.mp3` stayed as an extension resource.

The project file `voiceMixer.xcodeproj/project.pbxproj` was **hand-edited** (no xcodeproj gem
available) to: remove the moved files from the extension's build phases / groups / file refs; add an
`XCLocalSwiftPackageReference`, an `XCSwiftPackageProductDependency`, a `packageReferences` entry, a
`packageProductDependencies` entry, and a new `PBXFrameworksBuildPhase` linking the product.

A minimal `public` surface was added (only what `MessagesViewController` touches): `Config`,
`ConvertService`, `ConvertResponse`, `VoiceEngine`, `MockConvertService`, `LiveConvertService`,
`AudioRecorder`, `VoiceTransformViewModel`, `VoiceTransformView`, `VoiceCatalogPreflight`.
`VoicePersona`, `ConvertServiceError`, `WaveformVideoRenderer` were intentionally kept internal.

`xcodebuild ... -sdk iphonesimulator build` currently reports BUILD SUCCEEDED for the whole project.

## What to scrutinize (be skeptical and specific)

1. **pbxproj correctness.** Is the hand-edited project file structurally valid and complete? Are the
   package reference / product dependency / frameworks phase wired correctly for the EXTENSION target
   (not the app)? Will this link & embed correctly for a real **device** build and archive, not just
   simulator? Any dangling UUIDs, orphaned references, or missing back-references?
2. **Access control.** Is the public surface correct and minimal? Anything that should be public but
   isn't (or vice-versa)? Any `public` API leaking an internal type?
3. **Runtime `Bundle.main` behavior.** `Config.baseURL` reads `Bundle.main` Info.plist key
   `API_BASE_URL`; `MockConvertService` loads `sample.mp3` via `Bundle.main`. Now that this code is in
   a statically-linked package compiled into the extension, confirm `Bundle.main` still resolves to the
   **extension** bundle at runtime (so API_BASE_URL and sample.mp3 still work). Flag any case where it
   would break (device vs sim, release vs debug).
4. **Functional regressions** vs. before the move — anything behaviorally different.
5. **Package hygiene** — Package.swift platform/deployment (iOS 16) matching the app target, swift-tools
   version, `.gitignore`, the `#Preview` placement.
6. **DEBUG-only code** (`VoiceCatalogPreflight`, Mock's `expectedEngine`) — does the `#if DEBUG`
   gating still hold across the module boundary?

## Process

- **Investigator:** dig through the diff and files, build an evidence-based list of findings (cite
  file:line). Assign each a severity (Critical / High / Medium / Low).
- **Devil's Advocate:** challenge each finding — is it real, overstated, or a false positive? Concede
  freely when the investigator is wrong.
- **Judge:** for each disputed point render UPHELD / OVERTURNED / MODIFIED, then give a final verdict:
  is this refactor safe to commit as-is? What MUST be fixed first vs. nice-to-have?

## Output

Write your verdict to `notes/codex-tribunal-review.md`. Lead with a one-line verdict and a
severity-ranked list of actionable findings (each with file:line + concrete fix). Keep it tight and
evidence-based — no filler. Do not edit any other files.
