# iMessage Steel Thread — Plan

**Owner:** Aaron (iMessage)
**Approach:** Build the full record → convert → inline-bubble round-trip against a **mock** `/convert`. **No backend runs anywhere for now** (not local, not remote) — the entire thread is validated **client-side only** against the mock. The network seam is isolated so swapping to german's real endpoint later is a one-line config change.

## Goal (DoD)

Tap a button in the iMessage app → record voice → "convert" → an audio bubble drops into the **compose field**; the user taps **Send** and it plays inline in the thread. (`insertAttachment` stages the clip in the compose field — it does not auto-send. That's the correct, expected iMessage behavior.) **Validated entirely client-side against the mock — zero network, no backend.** Success here means the iMessage plumbing (record, presentation, loading state, inline insert) is proven; the real endpoint is a later swap.

## The round-trip we're proving

The real shape (what we wire to later). For now, the `POST`/`GET` middle is faked by the mock — bytes never leave the device.

```
record (.m4a) ──► POST /convert (multipart: audio + voiceId) ──► {url,title,audioUrl}
              ──► GET audioUrl (MP3 bytes → temp file) ──► insertAttachment(fileURL) ──► inline bubble
                  └── (mocked: returns a bundled sample MP3 after a fake delay) ──┘
```

**What's actually validated now (client-side):** record → fake convert/loading → inline audio bubble. The two network hops are stubbed.

## The mock seam (key design decision)

One protocol so nothing downstream knows whether it's real or fake:

```swift
protocol ConvertService {
    func convert(audioURL: URL, voiceId: String) async throws -> ConvertResponse
    func fetchAudio(_ audioUrl: URL) async throws -> URL   // returns local file
}
struct ConvertResponse { let url, title, audioUrl: String }
```

- **`MockConvertService`** — `convert(...)` ignores input, sleeps ~1.5s (fake latency so the loading state is real), and returns a dummy `ConvertResponse` (placeholder `url`/`title`, and an `audioUrl` it controls). `fetchAudio(...)` ignores that dummy URL and returns a local file URL for the **bundled sample MP3** (copied to a temp/caches `.mp3`). No network at all.
- **`LiveConvertService`** — real `URLSession` multipart POST + GET. Written now, not wired until german's URL exists.
- **Swap point** — a single `Config.baseURL` + `let service: ConvertService = useMock ? Mock... : Live...`. That's the whole "swap later."

## Environment config (local vs prod — driven by Xcode build settings)

Keep the URL out of Swift. Let the **build configuration** carry it, so the right endpoint is selected by *how you build* — Debug→dev, Release→prod — with no code edits and no `#if` ladder.

**Setup (one-time):**
1. Add an `.xcconfig` per configuration (`Debug.xcconfig`, `Release.xcconfig`) and assign them to the configs in the project, **or** add a User-Defined build setting `API_BASE_URL` with separate Debug/Release values on the **MessagesExtension** target.
2. Surface it through the extension's Info.plist: add key `API_BASE_URL` = `$(API_BASE_URL)`.
3. Read once at runtime — no environment branching in code:

```swift
enum Config {
    static let baseURL = URL(string:
        Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as! String)!
    static let useMock = true   // orthogonal to environment; flip when german's endpoint is live
}
```

- **Automatic selection:** `Run` from Xcode = Debug = dev URL; `Archive` / TestFlight = Release = prod URL. The build configuration decides; Swift just reads the value.
- **`.xcconfig` `//` gotcha:** in xcconfig files `//` starts a comment, so `https://host` silently truncates to `https:`. Store the **host without scheme** (`API_BASE_HOST = dev.example.com`) and prepend `https://` in code, or use the empty-variable trick `https:/$()/host`.
- **Per-target:** the build setting + Info.plist key must live on the **MessagesExtension** target (the extension is what makes the calls), not just the host app.
- **Mock is orthogonal:** `useMock` is independent of `baseURL`, so the steel thread runs the mock today and flipping to a live dev endpoint later doesn't touch URL handling.
- **Device-vs-simulator gotcha:** a physical iPhone (and the extension) **cannot** reach your Mac's `localhost` / `127.0.0.1`. For on-device local testing point the Debug value at **ngrok** (also gives HTTPS, sidestepping the ATS exception) or your Mac's **LAN IP**. The simulator can hit `localhost` directly.

*(Quick fallback if build-settings setup is fiddly under time pressure: a `#if DEBUG` constant in `Config` works too — same auto-by-build-config behavior, just with the URL in source.)*

## Build order (each step independently verifiable in the simulator)

1. **UI scaffold** — replace the label in `MessagesViewController.swift` with: a Record/Stop button, a status label, and a Send button (hidden until a clip is ready). Hardcode `voiceId = "<stock voice>"` for the thread.
   - **DoD:** buttons render in the iMessage drawer.

2. **Expanded presentation + mic permission** — call `requestPresentationStyle(.expanded)` before recording (iMessage apps launch compact; recording UX needs room). Add `NSMicrophoneUsageDescription` to the **extension's** Info.plist.
   - **DoD:** tapping Record triggers the iOS mic prompt; granting it works.

3. **Recorder** — small `AudioRecorder` wrapping `AVAudioRecorder` → writes `.m4a` (AAC — the native iOS recording format, ~150 KB/min) to a temp file. No need to pre-match the backend's canonical format; german's server runs ffmpeg to normalize whatever we send, and the contract accepts `m4a`. Record/stop wired to the button.
   - **DoD:** can record and play back the temp file locally (sanity `AVAudioPlayer`).

4. **Add the sample asset** — drop a real `sample.mp3` into the project and **add it to the MessagesExtension target's** "Copy Bundle Resources" (an asset added to the host app only won't be in the extension's bundle). Verify `Bundle.main.url(forResource: "sample", withExtension: "mp3")` resolves from inside the extension.
   - **DoD:** the mock can load the bundled file; `Bundle.main.url(...)` is non-nil at runtime.

5. **Wire the mock service** — on tap Convert: show loading state → `service.convert(...)` → `service.fetchAudio(...)`.
   - **DoD:** loading spinner shows ~1.5s, then we hold a local MP3 file URL.

6. **Insert inline** — `activeConversation?.insertAttachment(localMP3URL, withAlternateFilename: "voiceMix.mp3")` (await its completion handler and update UI on the main actor — it's async, don't assume synchronous success).
   - **DoD:** an audio bubble appears in the **compose field**; tapping Send delivers it and it plays inline. **This is the steel thread green.**

7. **Write `LiveConvertService` (write-only, untested)** — multipart body builder (`audio` part + `voiceId` field), POST, decode JSON, GET `audioUrl` → temp/caches `.mp3` file. Leave `useMock = true`. Since no backend exists yet, this stays **unrun** until german's endpoint is up — it just needs to compile.
   - **DoD:** compiles; ready to flip when german's URL lands.

## Gotchas baked in

- **Mic perms live in the _extension's_ Info.plist**, not the host app's.
- **Compact→expanded** is mandatory before recording, or the UX is cramped/broken.
- **ATS when you swap:** if german's endpoint is plain HTTP (localhost/ngrok-http), you'll need an `NSAppTransportSecurity` exception. HTTPS via Caddy = no change. Noted now so the swap isn't a surprise.
- **`insertAttachment` needs a real on-disk file URL** of a playable type — MP3 is fine.
- No App Group needed for the steel thread (host app isn't involved).
- **No API keys on the client.** The extension only POSTs to german's backend (local or server endpoint, per `Config.baseURL`); the backend owns the ElevenLabs / Modal credentials. The client never sees provider secrets. If the backend later adds its own auth, that's a single request header added at swap time — not a stored secret.

## Implementation notes (catch while coding, not plan-blocking)

- **Audio session:** set `AVAudioSession` category to `.record` (or `.playAndRecord` if you also do the local playback sanity check) and activate it *before* starting `AVAudioRecorder` — the default session doesn't permit recording.
- **`insertAttachment` is async:** await its completion handler and update UI on the `@MainActor`; don't assume synchronous success (covered in step 6).
- **Durable file URLs:** both services return a temp/caches `.mp3` file URL — mock copies from the bundle, live writes downloaded bytes. Don't hand back a URL that gets cleaned up before insertion.
- **Physical-device pass:** the simulator is the fast loop, but do one real-device smoke test for the mic permission prompt and actual iMessage extension behavior before calling it done.

## Deliberately excluded (post-thread)

Voice picker, error/retry states, the 6 real voices, ≤1min/≤10MB validation, sizing the expanded view nicely. All hang off the green thread later.

## Swap to real backend (later, when german's URL is ready)

The real network path is untested until then. When it lands: point `Config`'s dev URL at german's dev endpoint (prod URL stays for Release), flip `useMock = false`, add an ATS exception only if it's plain HTTP — then run the first true end-to-end round-trip. The Debug/Release split (see Environment config) means dev and prod stay separated with no manual switching.
