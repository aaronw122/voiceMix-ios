# Investigation: can a third-party iMessage extension produce inline-playable / native voice-message audio?

Think hard. Use your knowledge of the iOS Messages framework (MSMessagesAppViewController, MSConversation, MSMessage, MSMessageTemplateLayout, MSSticker). Be precise and cite the specific API behavior. Do not hand-wave.

## Context
We built an iMessage app extension (`MessagesExtension`, target `voiceMixerMessages`). It records a clip, runs a (mocked) "convert", gets a local `.mp3`, and inserts it into the compose field via:

```swift
activeConversation?.insertAttachment(localMP3URL, withAlternateFilename: "voiceMix.mp3")
```

On a real device this produces a **file-attachment chip** ("voiceMix.mp3 — Audio Recording · 25 KB"), NOT the native iOS voice-message bubble (waveform + inline scrubber + tap-to-play-in-place that Apple's built-in mic button produces).

## The questions (answer each explicitly)
1. When an audio file inserted via `insertAttachment` is sent, and the recipient (or sender) taps it, does it play **inline / in place within the transcript**, or does it open a separate QuickLook / preview / player sheet? Be specific about current iOS behavior. Does the file type matter (`.mp3` vs `.m4a`/AAC vs `.caf` vs `.amr`)? Does the UTI / `withAlternateFilename` extension change whether it gets an inline play affordance?
2. Is there ANY public API by which a third-party iMessage extension can produce the **native voice-message bubble** (the waveform audio-message type Apple's own recorder creates)? If not, state definitively that it is private/unavailable and why.
3. Alternative approaches to get as close as possible to inline playback from an extension:
   - `MSMessage` + `MSMessageTemplateLayout`: can it embed playable audio, or only a static image + caption that opens the extension on tap? Can the tap play audio without leaving the thread?
   - Any trick with sending the audio as a specific UTI / file extension so Messages treats it as a voice memo (e.g., audio/amr, audio/x-caf) and grants inline playback?
   - Does sending via `insertAttachment` differ from the host app sharing the same file via the share sheet, in terms of the resulting bubble?
4. How do real shipping apps (e.g., voice-changer / TTS iMessage apps) present audio in Messages today? What's the best they achieve?
5. Bottom line: for our product (drop a converted voice clip into a thread that the recipient can play), what is the MAXIMUM achievable UX from a third-party iMessage extension, and what exactly is impossible?

## Output
Write your findings to `notes/codex-output-inline-audio.md`. Structure: a direct yes/no to "can it play inline" up top, then per-question detail, then a final "max achievable UX" recommendation. Flag any claim you're uncertain about vs. certain about.
