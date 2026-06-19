## Investigator

Source facts:

- The Messages extension has `NSMicrophoneUsageDescription` at `MessagesExtension/Info.plist:23-24`.
- The containing app does **not** have `NSMicrophoneUsageDescription`; `App/Info.plist:1-36` contains bundle metadata, launch/orientation keys, and no microphone privacy key.
- The containing app never asks for microphone access. It is a SwiftUI onboarding-only app (`App/voiceMixerApp.swift:3-10`) whose final copy says "That's it — no setup needed here." (`App/voiceMixerApp.swift:64-67`).
- The extension asks to expand automatically in both `viewWillAppear` and `willBecomeActive` (`MessagesExtension/MessagesViewController.swift:87-95`), and again when Record is tapped (`MessagesExtension/MessagesViewController.swift:115-122`) and before starting recording (`MessagesExtension/MessagesViewController.swift:153-156`).
- Record flow reads the permission state (`MessagesExtension/MessagesViewController.swift:125-130`), requests permission if undetermined (`MessagesExtension/MessagesViewController.swift:138-149`), and only starts `AVAudioRecorder` after grant (`MessagesExtension/MessagesViewController.swift:144-145`, `MessagesExtension/AudioRecorder.swift:17-42`).
- Permission code uses `AVAudioApplication.shared.recordPermission` / `AVAudioApplication.requestRecordPermission` on iOS 17+ and legacy `AVAudioSession` APIs below iOS 17 (`MessagesExtension/AudioRecorder.swift:80-112`).
- Recording activates `AVAudioSession` with `.playAndRecord` inside the extension (`MessagesExtension/AudioRecorder.swift:18-21`).

Interpretation:

- The missing Settings -> voiceMix Microphone toggle means no durable microphone authorization record has been created for the app identity shown in Settings. That is consistent with the request never reaching TCC, being made under an extension identity that Settings does not expose clearly, or the extension being killed before the permission alert is presented.
- The extension usage string being present rules out the classic "missing `NSMicrophoneUsageDescription` in the appex" crash. It does not prove that prompting from this extension presentation context is reliable.
- There are no app-group entitlement files in the checked file list. That is not itself a blocker for microphone permission; App Groups share containers/keychain-style data, not TCC microphone grants.

## Devil's Advocate

Strongest case that "the extension prompts itself" is the wrong architecture:

- iMessage extensions run inside Messages' extension-host lifecycle, not as ordinary foreground apps. Permission alerts are system modal UI, and the observed failure is exactly at a presentation boundary: "timed out during delayed presentation", plugin invalidated, SIGKILL, no Swift backtrace. The code increases that risk by requesting `.expanded` from `viewWillAppear`, `willBecomeActive`, `recordTapped`, and `startRecordingFlow` (`MessagesExtension/MessagesViewController.swift:87-95`, `MessagesExtension/MessagesViewController.swift:115-122`, `MessagesExtension/MessagesViewController.swift:153-156`).
- Even if an iMessage extension can technically use microphone APIs when correctly declared, relying on the extension to present the first TCC prompt is fragile UX. The first mic request competes with Messages' compact/expanded sheet transition and extension-host presentation timing. A normal app launch is the stable place for a first-run privacy prompt.
- The containing app currently lacks the mic string (`App/Info.plist:1-36`) and never asks. If TCC attribution for this install surfaces under the containing app in Settings, the app cannot establish that grant today. That explains why Settings has no voiceMix microphone toggle even though the appex plist is correct.
- Installing/running only the extension target is not the core issue if Xcode installed the containing app plus embedded appex. But if the containing app is never launched, any host-app onboarding permission request will never happen. Running the host app target after adding a host request would materially change the permission state.

Certain vs uncertain:

- Certain: the host app currently cannot request mic permission safely because it has no `NSMicrophoneUsageDescription`.
- Certain: there is no App Group requirement for microphone authorization.
- High confidence: first prompting from the containing app is the more reliable architecture.
- Medium confidence: the extension prompt itself is what's killing the sheet. The source and symptoms fit, but Apple does not expose enough of Messages' extension-host/TCC choreography to prove causality from source alone.
- Medium confidence: a host-app grant will be observed by the extension as `.granted`. This is the architecture I would test first because iOS presents privacy controls to users at the app level, extensions are distributed inside the containing app, and it avoids extension-host prompt presentation. If testing shows TCC is keyed separately for the appex on the target OS, the fallback is still the same UX principle: do not prompt from the extension during Record; send the user to the containing app/setup path.

## Judge

Ruling: move the first microphone permission request to the containing app onboarding, and make the Messages extension a consumer of an already-established grant. The extension should read permission state, record only when already granted, and show setup guidance when undetermined/denied. Do not present the system microphone prompt from the iMessage extension's Record tap.

Recommended changes:

1. Add `NSMicrophoneUsageDescription` to `App/Info.plist`, using the same or host-app-specific copy.

   Path: `App/Info.plist`

   Add near the other top-level keys:

   ```xml
   <key>NSMicrophoneUsageDescription</key>
   <string>voiceMixer needs the microphone to record the voice clip you want to convert in Messages.</string>
   ```

2. Add a host-app permission onboarding action in `App/voiceMixerApp.swift`.

   Use the same availability split as `AudioRecorder`: `AVAudioApplication.requestRecordPermission` on iOS 17+, `AVAudioSession.sharedInstance().requestRecordPermission` below iOS 17. The onboarding should show the current state and a "Enable Microphone" button when undetermined. The current "no setup needed here" copy at `App/voiceMixerApp.swift:64-67` should be replaced.

3. Keep `NSMicrophoneUsageDescription` in `MessagesExtension/Info.plist`.

   Do not remove it. The extension still links and uses AVFoundation recording APIs, and the appex bundle should remain self-describing for privacy validation.

4. Change extension Record behavior in `MessagesExtension/MessagesViewController.swift`.

   In `beginRecording()`, remove `AudioRecorder.requestMicPermission` from the `.undetermined` branch. Treat `.undetermined` similarly to `.denied`: show "Open voiceMix to enable microphone access" or insert a lightweight setup instruction. This prevents the extension-host sheet from being responsible for the first TCC prompt.

5. Reduce presentation racing.

   Stop requesting `.expanded` in every lifecycle hook. Prefer one expansion request when the extension becomes active or when the user taps Record, then wait for the extension to actually be expanded before activating `AVAudioSession`. At minimum, remove the duplicate `requestExpandedPresentation(reason: "recordTapped")` plus `requestExpandedPresentation(reason: "startRecordingFlow")` chain (`MessagesExtension/MessagesViewController.swift:120`, `MessagesExtension/MessagesViewController.swift:155`).

6. No App Group change is required for microphone permission.

   Add App Groups only if the app and extension need shared files/preferences. It is not a mic-authorization mechanism.

How to verify on a physical iPhone:

1. Delete voiceMix from the device to clear the installed app/extension. Also check Settings -> Privacy & Security -> Microphone and remove/confirm no stale voiceMix entry.
2. Build/install the containing app target `voiceMixer` so `com.aaron.voiceMixer` and embedded `com.aaron.voiceMixer.Messages` are installed together.
3. Launch the voiceMix app from the Home Screen. Tap the new microphone enable button. Expected: iOS shows the mic permission prompt with voiceMix copy.
4. Grant permission. Expected: Settings -> voiceMix now shows a Microphone toggle, and Settings -> Privacy & Security -> Microphone includes voiceMix.
5. Open Messages, open the voiceMix iMessage extension, tap Record. Expected: no permission prompt appears, `AudioRecorder.micPermission` is `.granted`, the sheet does not vanish, and `AVAudioSession.setActive` / `AVAudioRecorder.record()` succeeds.
6. Repeat after denying permission from Settings. Expected: extension does not call `requestRecordPermission`; it stays visible and shows guidance to enable mic in the app/Settings.
7. Run a focused log stream while testing:

   ```sh
   log stream --predicate 'subsystem == "com.aaron.voiceMixer"' --info
   ```

   Expected sequence after host grant: permission state logged as granted, then startRecording success. There should be no "requesting permission" log from the extension in the final architecture.

Confidence:

- Overall ruling confidence: high.
- Highest-confidence fix: add the host app usage string and request permission in host onboarding.
- Highest-confidence cleanup: stop duplicate expansion requests around the permission/recording path.
- Remaining uncertainty: the exact TCC keying behavior for iMessage appex microphone grants can vary by OS presentation details, but the recommended architecture is still the safer product and engineering path because it removes first-run system prompt presentation from the extension-host lifecycle.
