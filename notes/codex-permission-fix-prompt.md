# Implement: move mic permission to the host app; extension consumes the grant

Implement the changes below in the existing repo. Branch `imessage-steel-thread` — commit there, do NOT push, do NOT touch `main`, do NOT create PRs. Read files before editing. Keep the existing `os_log` Logger markers.

## Why
On a physical device, tapping Record in the iMessage extension makes the sheet vanish with no mic prompt, and Settings shows no Microphone toggle for the app. Root cause (per a code tribunal): an iMessage extension trying to present the FIRST microphone TCC prompt is unreliable and gets torn down at the presentation boundary, and the **host app has no mic usage string and never requests permission**, so no grant is ever established. Fix: request mic permission from the HOST APP onboarding; the extension only READS the permission state and records if already granted — it must NEVER present the prompt.

## Changes

### 1) `App/Info.plist` — add the mic usage string (top-level key)
```xml
<key>NSMicrophoneUsageDescription</key>
<string>voiceMixer needs the microphone to record the voice clip you want to convert in Messages.</string>
```
Validate with `plutil -lint App/Info.plist` after editing.

### 2) `App/voiceMixerApp.swift` — host-app mic permission onboarding
The host app is a SwiftUI onboarding screen and CANNOT import the extension's `AudioRecorder`, so add self-contained permission code here. `import AVFoundation`.
- Add a small observable piece of state for mic permission status (undetermined / granted / denied), read on appear via `AVAudioApplication.shared.recordPermission` (iOS 17+) or `AVAudioSession.sharedInstance().recordPermission` (older).
- Add an **"Enable Microphone"** button shown when undetermined; tapping it calls `AVAudioApplication.requestRecordPermission(completionHandler:)` on iOS 17+, else `AVAudioSession.sharedInstance().requestRecordPermission(_:)`. Update the displayed state on the main actor in the completion.
- When granted, show a clear confirmation (e.g. a checkmark row "Microphone enabled"). When denied, show a short line telling the user to enable it in Settings.
- Replace the current footer line "That's it — no setup needed here." since there now IS a one-time setup step. KEEP THE UI SIMPLE AND MINIMAL — match the existing clean style (the user explicitly wants simple, no complex flows). A single status row + one button is enough; integrate it tastefully near the steps or just above the footer.

### 3) `MessagesExtension/MessagesViewController.swift` — extension never prompts
- In `beginRecording()`, REMOVE the `AudioRecorder.requestMicPermission` call. Change the `.undetermined` case to behave like `.denied`: set `statusLabel.text` to something like "Open the voiceMix app to enable microphone access" and do NOT start recording, do NOT prompt. Only `.granted` proceeds to `startRecordingFlow()`. Keep the `os_log` lines (log the state).
- De-duplicate the expanded-presentation requests: REMOVE `requestExpandedPresentation(reason: "recordTapped")` (line ~120) and `requestExpandedPresentation(reason: "startRecordingFlow")` (line ~155) and the `viewWillAppear` one. Keep a SINGLE expansion request in `willBecomeActive(with:)`. (Rationale: requesting `.expanded` repeatedly around the record/permission path compounds the presentation-teardown risk.)

### 4) Keep `MessagesExtension/Info.plist`'s `NSMicrophoneUsageDescription` as-is (do NOT remove it).

## Constraints
- Do NOT modify `ConvertService.swift`, `MockConvertService.swift`, `Config.swift`, `WaveformVideoRenderer.swift`, or `project.pbxproj` (no new files).
- `AudioRecorder.swift`: you may leave its permission helpers as-is (still fine for reading state). The key change is the CONTROLLER no longer calling the request.
- Follow existing code style; keep host UI minimal.

## Verify
`xcodebuild build -project voiceMixer.xcodeproj -scheme voiceMixer -sdk iphonesimulator -destination 'id=D0A72092-9179-4C06-B7C6-BB7F12165302' CODE_SIGNING_ALLOWED=NO`
AND the extension scheme too:
`xcodebuild build -project voiceMixer.xcodeproj -scheme voiceMixerMessages -sdk iphonesimulator -destination 'id=D0A72092-9179-4C06-B7C6-BB7F12165302' CODE_SIGNING_ALLOWED=NO`
If your sandbox blocks xcodebuild/CoreSimulator, SAY SO in your report — it will be build-verified afterward. Either way, write code that compiles.

## Commit
One commit: `fix: request mic permission in host app; extension consumes the grant`. Do NOT push.

## Report (concise)
- What changed in each file.
- Whether you could build-verify (or sandbox blocked it).
- Commit hash + `git show --stat HEAD`.
- Confirm the extension no longer calls `requestRecordPermission` and only ONE `requestExpandedPresentation` remains.
