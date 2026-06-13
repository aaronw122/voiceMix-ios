Summary:
- App/Info.plist: added the host app NSMicrophoneUsageDescription string.
- App/voiceMixerApp.swift: added AVFoundation-based microphone permission onboarding with an Enable Microphone button for undetermined state, a granted confirmation row, and a denied Settings hint.
- MessagesExtension/MessagesViewController.swift: removed extension-side mic permission prompting; undetermined and denied now tell the user to open the voiceMix app. Removed repeated expansion requests so only willBecomeActive calls requestExpandedPresentation.

Verification:
- plutil -lint App/Info.plist: passed.
- Requested simulator builds for voiceMixer and voiceMixerMessages: blocked before compile because CoreSimulator is unavailable in the sandbox and the specified device id D0A72092-9179-4C06-B7C6-BB7F12165302 is not visible.
- Additional generic simulator/device xcodebuild attempts: blocked by CoreSimulator/Interface Builder/asset catalog runtime access.
- Direct Swift typecheck passed for App/voiceMixerApp.swift.
- Direct Swift typecheck passed for all MessagesExtension Swift files. Existing deprecation warnings remain in WaveformVideoRenderer.swift.

Commit:
- Commit was blocked: git could not create .git/index.lock because the sandbox denies writes inside .git.
- Requested commit message not created here: fix: request mic permission in host app; extension consumes the grant

Pending diff stat:
```text
 App/Info.plist                                 |   2 +
 App/voiceMixerApp.swift                        | 106 ++++++++++++++++++++++++-
 MessagesExtension/MessagesViewController.swift |  28 +------
 3 files changed, 111 insertions(+), 25 deletions(-)
```

Invariant checks:
- MessagesExtension/MessagesViewController.swift no longer calls AudioRecorder.requestMicPermission or requestRecordPermission.
- Only one requestExpandedPresentation call remains in the controller, in willBecomeActive(with:).
