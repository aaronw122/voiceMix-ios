# Can a third-party iMessage extension make native inline-playable voice audio?

Direct answer: **No for `insertAttachment` and no for the native Apple voice-message bubble.** A third-party iMessage extension can insert an audio file, or it can send an `MSMessage` whose layout visually represents audio, but public Messages.framework does not expose the private/native audio-message bubble that Apple's own Messages recorder creates.

For `activeConversation?.insertAttachment(localMP3URL, withAlternateFilename: "voiceMix.mp3")`, the maximum expected result is an ordinary file/media attachment. On current iOS, the behavior observed in the prompt, "voiceMix.mp3 - Audio Recording - 25 KB", is the important signal: that is a document/file attachment chip, not a Messages audio-message transcript item. Tapping that chip opens Messages' attachment preview / Quick Look-style viewer or player surface when the format is previewable; it does **not** become the in-transcript voice-message waveform bubble with inline scrubber/playback.

Certainty: high for the API boundary and native voice-bubble impossibility; medium-high for exact tap UI wording because Apple does not document the current Messages app chrome for every audio container/codec.

## Sources used

- Apple `MSConversation.insertAttachment(_:withAlternateFilename:)`: the API inserts a local "media attachment" into the current context; `withAlternateFilename` is used as the attachment filename, not as a rendering override. https://developer.apple.com/documentation/messages/msconversation/insertattachment%28_%3Awithalternatefilename%3Acompletionhandler%3A%29
- Apple `MSMessageTemplateLayout.mediaFileURL`: the media file is "used to represent the message in the transcript"; for audio files, Messages shows a graphical waveform representation. https://developer.apple.com/documentation/messages/msmessagetemplatelayout/mediafileurl
- Apple `MSConversation.selectedMessage`: selecting one of your extension's messages launches/activates the extension and sets `selectedMessage`. https://developer.apple.com/documentation/messages/msconversation/selectedmessage
- Apple `MSMessage.url`: the app message payload is app data encoded in an HTTP/HTTPS/data URL, delivered to the recipient's extension, not a general "send a native audio message" payload. https://developer.apple.com/documentation/messages/msmessage/url
- Apple `MSMessageLiveLayout.alternateLayout`: live layouts require iOS 11+ and the recipient having the iMessage app installed; otherwise the alternate template layout is shown. https://developer.apple.com/documentation/messages/msmessagelivelayout/alternatelayout
- Apple `MSMessagesAppPresentationStyle.transcript`: there is a transcript presentation style for live extension UI, but it is extension UI, not the native voice-message type. https://developer.apple.com/documentation/messages/msmessagesapppresentationstyle
- Apple `MSMessagesAppPresentationContext.media`: in the media context, non-image attachments and `MSMessage` insertion are unavailable; this reinforces that Messages extension contexts are constrained by public API, not arbitrary transcript item creation. https://developer.apple.com/documentation/messages/msmessagesapppresentationcontext/media

## 1. What happens when `insertAttachment` sends audio?

`insertAttachment` sends an attachment. It does not send an `MSMessage` with a layout, and it does not create Apple's audio-message object.

The documented knobs are:

- `URL`: a local file URL for the media file.
- `withAlternateFilename`: a filename to display/use for the attachment. Apple describes this as making the filename more readable or describing it better.

There is no documented parameter for:

- "render as voice message"
- "show inline transcript scrubber"
- "use native audio-message bubble"
- UTI/content-type override
- message style override

Current practical behavior:

- `.mp3` inserted this way appears as a file/audio attachment chip, as you observed.
- Tapping it opens an attachment preview/player surface when Messages/Quick Look can preview that file. It is not the same in-place transcript control as a native Messages voice note.
- The file may be playable after tapping, but that is attachment preview playback, not inline transcript playback.

File type:

- `.mp3`, `.m4a`/AAC, `.caf`, `.amr`, etc. can change whether the system recognizes/previews/plays the file well.
- The container/codec can change the label, icon, previewability, or whether a Quick Look-style player appears.
- It does **not** change the object class Messages creates. It remains an attachment inserted through `insertAttachment`.

UTI / filename:

- `withAlternateFilename: "voiceMix.m4a"` may cause Messages to infer a different extension from the displayed filename.
- That can affect file naming/type inference.
- It is not a supported way to request the native voice-message UI.

Conclusion: **No, `insertAttachment` audio does not play inline in the native voice-message bubble. It opens the attachment preview/player path.**

## 2. Is there any public API for the native voice-message bubble?

No. There is no public Messages.framework API that lets a third-party iMessage extension create the Apple voice-message transcript item.

Public composition APIs available to an `MSMessagesAppViewController` are along these lines:

- insert text
- insert stickers
- insert attachments
- insert/send `MSMessage`

`MSMessage` exposes:

- `layout`, which controls transcript appearance through `MSMessageLayout` subclasses.
- `url`, which carries app-specific state to the receiving extension.
- session/update behavior through `MSSession`.

None of these expose Apple's internal audio-message model: no waveform samples, no duration/scrubber contract, no expiration/read behavior matching audio messages, no "audio message" enum, no private transcript renderer hook.

Apple has other public APIs that mention audio message attachments in other domains, such as SiriKit's `INSendMessageAttachment.attachmentWithAudioMessageFile`, but that is not an `MSConversation`/iMessage extension API for manufacturing Apple's own Messages voice bubble. It does not change what a third-party iMessage extension can insert into the Messages transcript.

Conclusion: **The native Apple voice-message bubble is private/unavailable to third-party iMessage extensions.**

## 3. Alternative approaches

### `MSMessage` + `MSMessageTemplateLayout`

`MSMessageTemplateLayout.mediaFileURL` can represent media in the transcript. Apple currently documents that audio media displays as a graphical waveform representation.

Important limitation: that waveform is a layout representation for an app message. The documented interaction model for app messages is selection: when the user selects one of your extension's messages, the system activates your extension and provides the selected message via `selectedMessage`.

So `MSMessageTemplateLayout` can give a more "audio-looking" transcript bubble than a raw attachment chip, but it is not the native Messages voice-message player. Do not assume the template layout itself gives you a tappable in-transcript scrubber/play button equivalent to Apple's mic-button messages. If playback is needed, your extension should handle playback after the app message is selected/opened.

### `MSMessageLiveLayout`

This is the one meaningful caveat. `MSMessageLiveLayout` can present live extension UI in the transcript on supported devices when the recipient has the iMessage app installed; Apple documents that unsupported devices, macOS, SMS, older iOS, and recipients without the app fall back to the alternate template layout.

In principle, this can be used to build a custom mini-player UI in the transcript. That would still be:

- your extension UI
- available only when live layout is supported and the app is installed
- not Apple's native voice-message bubble
- not a universal attachment UX for recipients who do not have the app

If your product can require both parties to have the app installed, this is the closest route to "play without leaving the thread." If the requirement is "send anyone a converted voice clip they can play in Messages," this is not a reliable replacement for a normal attachment.

Certainty: medium. The live-layout capability is public, but actual audio-session/playback behavior inside the transcript should be tested on device and across iOS versions before relying on it.

### UTI / extension tricks

There is no supported trick where naming the file `.caf`, `.amr`, `.m4a`, or providing a voice-memo-looking UTI makes Messages grant the native voice-message renderer.

Reasons:

- `insertAttachment` has no UTI parameter.
- `withAlternateFilename` is documented as an attachment filename.
- The native audio-message bubble is not documented as file-extension-driven public behavior.
- The observed `.mp3` behavior already shows Messages is treating the input as an attachment, not reclassifying it as a voice message.

Changing file type may improve preview playback compatibility. It should not be treated as a path to native inline voice messages.

### iMessage extension vs host app share sheet

A host app sharing the same file through the iOS share sheet to Messages also sends a file/media attachment. It may differ slightly in staging UI, filename, metadata, or preview thumbnail generation, but it does not gain the native iMessage voice-message bubble either.

The native voice-message UI is produced by Apple's Messages recorder path, not by arbitrary apps handing Messages an audio file.

## 4. What do shipping voice/TTS/voice-changer iMessage apps do?

The common public-API patterns are:

- Send a normal audio attachment. Best case: recipient taps the attachment and Messages presents a preview/player.
- Send an `MSMessage` with a branded/template layout, often showing a static waveform/image/title, and open the iMessage extension on tap for playback.
- Encode audio into a short video/MP4-style asset when a more media-like bubble or visible play affordance is preferred. This can be more tap-friendly than an audio document chip, but it is semantically a video/media attachment, not an Apple voice message.
- For app-to-app experiences, use `MSMessageLiveLayout` or an opened extension to provide a custom player when the recipient has the app installed.

Best they achieve for recipients without app-specific live UI: **tap-to-open preview/player**, not native in-thread voice-message playback.

Certainty: medium. This is inferred from public API constraints and observed ecosystem patterns, not from an exhaustive 2026 App Store survey.

## 5. Bottom line for VoiceMix

Maximum universally achievable UX from a third-party iMessage extension:

1. Generate a broadly supported audio file, preferably `.m4a` AAC for Apple-platform compatibility.
2. Insert it with `insertAttachment(_:withAlternateFilename:)`.
3. Accept that Messages will send it as an attachment chip/card.
4. Recipient taps it to play in Messages' attachment preview/player surface.

Best possible nicer UX, with tradeoffs:

- Use `MSMessageTemplateLayout.mediaFileURL` or a generated waveform image to make a branded app-message bubble that looks intentional. On tap, open the extension and play there. This requires the recipient's device/app support for your iMessage app experience.
- Consider a short `.mp4` wrapper with a simple waveform/cover frame plus audio if product testing shows Messages presents it with a clearer play affordance than audio attachments. This is a pragmatic media-attachment hack, not a native voice-message solution.
- Explore `MSMessageLiveLayout` only if requiring the iMessage app on the recipient side is acceptable. It may allow a custom transcript mini-player, but it is not universal and should be validated on real devices.

Exactly impossible through public API:

- Creating Apple's native voice-message bubble.
- Getting the same waveform + inline scrubber + tap-to-play-in-place behavior as the built-in Messages microphone recorder for arbitrary third-party audio.
- Forcing `insertAttachment` to render as a voice message by changing `.mp3` to `.m4a`, `.caf`, `.amr`, or by changing `withAlternateFilename`.
- Making a share-sheet audio file become a native Messages voice note.

Recommendation: **ship the attachment path as the baseline**, using `.m4a` AAC instead of `.mp3` if compatibility is better in testing, and design the UI/copy around "send an audio clip" rather than promising "send a native voice message." If a more polished Messages-native feel is worth requiring app installation, prototype `MSMessageLiveLayout` with a custom compact player and test it on real devices before committing product direction.
