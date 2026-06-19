# Tribunal: why does tapping Record kill the iMessage extension (no mic prompt), and what's the right fix?

Run a one-shot adversarial tribunal: Investigator → Devil's Advocate → Judge, then a ruling. Read the real source first. Be concrete (file:line). Reason from iOS framework knowledge about app-extension privacy/permission constraints.

## The problem (observed on a PHYSICAL iPhone)
- The voiceMix iMessage extension UI renders fine. But tapping **Record** makes the extension **sheet just vanish** — **no microphone permission prompt ever appears**.
- In **Settings → voiceMix there is NO Microphone toggle at all** (and the user doesn't see voiceMix under a mic permission list).
- The extension is being terminated (earlier sessions showed `timed out during delayed presentation` + plugin invalidated + `SIGKILL`, no Swift backtrace, no `.ips`).

## What we've already confirmed (don't re-litigate)
- `NSMicrophoneUsageDescription` IS present and correct in the **built device** `.appex` Info.plist (verified via PlistBuddy on `Debug-iphoneos/.../voiceMixerMessages.appex/Info.plist`). So this is NOT a missing-usage-string build problem.
- We already added an EXPLICIT permission request in the extension: `AudioRecorder.micPermission` (reads state) and `AudioRecorder.requestMicPermission` (calls `AVAudioApplication.requestRecordPermission` on iOS 17+, legacy fallback, completion hopped to main). The code is clean (no force-unwraps, proper availability). See `MessagesExtension/AudioRecorder.swift`.
- Flow on Record: `recordTapped` → `requestPresentationStyle(.expanded)` → `beginRecording` → reads `micPermission`; if `.undetermined` → `requestMicPermission` (should prompt) → on grant `startRecordingFlow` activates `AVAudioSession(.playAndRecord)` and starts `AVAudioRecorder`. See `MessagesExtension/MessagesViewController.swift`.
- Recording uses `AVAudioSession.setCategory(.playAndRecord)` + `setActive(true)` inside the extension.

## The user's two hypotheses (evaluate them seriously)
1. **Request the mic permission from the HOST APP (on install / first launch / onboarding) instead of from the extension.** Does the containing app and its iMessage extension SHARE microphone (TCC) authorization? If the host app requests and is granted mic access, will the extension then see `.granted` without prompting? Is this the correct, supported pattern? (The host app is `App/voiceMixerApp.swift`, a SwiftUI onboarding screen; bundle id `com.aaron.voiceMixer`; extension `com.aaron.voiceMixer.Messages`.)
2. **"Install the whole binary, not just the iMessage app."** Is the user perhaps only deploying/running the extension, and does running the host app target change permission behavior?

## Central questions for the tribunal
- Is presenting a **microphone permission prompt from within an iMessage extension** actually supported/reliable, or is it a known platform limitation that can tear down the extension? Cite framework behavior/precedent if known. Flag certain vs uncertain.
- Why would there be **no Microphone toggle in Settings → voiceMix** AND no prompt — what does that imply about whether the request is reaching the TCC system at all?
- Does the **host app need its own `NSMicrophoneUsageDescription`** (in `App/Info.plist`) and to request permission, so the grant is established for the app and inherited by the extension? Check whether `App/Info.plist` currently has the mic usage string.
- Is there an **App Group / entitlement** or some shared-authorization requirement involved?
- Could `requestPresentationStyle(.expanded)` immediately followed by the permission request be racing/tearing down the extension regardless of where permission is requested?
- Concretely: **what is the correct architecture** to get a working mic grant for this extension? (e.g., host-app onboarding requests mic permission → extension only reads state and shows guidance if not granted; never prompt from the extension.)

## Files to read
- `MessagesExtension/MessagesViewController.swift`
- `MessagesExtension/AudioRecorder.swift`
- `MessagesExtension/Info.plist`
- `App/voiceMixerApp.swift`
- `App/Info.plist`

## Output
Write to `notes/codex-tribunal-permission-output.md`. Sections: Investigator (facts incl. whether `App/Info.plist` has the mic string), Devil's Advocate (strongest case the current extension-prompts-itself approach is fundamentally wrong / unsupported), Judge (ruling: the recommended architecture, exact code/plist/entitlement changes with file paths, and HOW TO VERIFY it works on device). Rank confidence; clearly separate certain from uncertain. Keep it tight and actionable.
