needs work: the renderer has a clear top-level story, but several dense AVFoundation/drawing blocks still make readers hold too much detail in their heads.

1. `MessagesExtension/WaveformVideoRenderer.swift:23-25, 76-89, 93-114, 123, 195-199, 267-268` - Magic layout/rendering values are scattered through the file, so the visual contract is hard to skim and hard to change consistently.

   Suggested refactor: collect the constants into small semantic groups near the top.

   ```swift
   private enum VideoSpec {
       static let frameSize = CGSize(width: 600, height: 600)
       static let framesPerSecond: Int32 = 6
       static let minimumDurationSeconds = 0.1
   }

   private enum CoverLayout {
       static let frameInset: CGFloat = 40
       static let cornerRadius: CGFloat = 28
       static let centerBandYRatio: CGFloat = 0.30
       static let wordmarkYRatio: CGFloat = 0.70
   }
   ```

2. `MessagesExtension/WaveformVideoRenderer.swift:29-47` - `makeVideo(fromAudio:)` is readable, but it mixes the narrative step "choose a cover" with fallback mechanics. The fallback is important behavior and deserves a named helper.

   Suggested refactor: extract cover selection so the public flow reads as three steps.

   ```swift
   func makeVideo(fromAudio audioURL: URL) async throws -> URL {
       let asset = AVURLAsset(url: audioURL)
       let duration = try await loadDuration(asset)
       let cover = await makeBestAvailableCover(for: asset)
       return try await renderVideo(audioURL: audioURL, duration: duration, cover: cover)
   }
   ```

3. `MessagesExtension/WaveformVideoRenderer.swift:65-118` - `makeCoverImage(centerDraw:)` does background, frame, optional center art, SF Symbol drawing, and wordmark typography in one closure. The names inside are mostly clear, but the function is still visually dense.

   Suggested refactor: split the drawing closure into named drawing steps: `drawCoverBackground`, `drawInnerFrame`, `drawCenterArtwork`, and `drawWordmark`. This keeps the current behavior while making the cover composition scannable.

4. `MessagesExtension/WaveformVideoRenderer.swift:127-187` - `waveformBars(from:)` operates at multiple abstraction levels: loading tracks, configuring PCM reader settings, copying `CMBlockBuffer` bytes, decoding `Int16`, bucketing, and normalizing. This is the highest cognitive-load block in the file.

   Suggested refactor: keep `waveformBars` as orchestration and extract the AVFoundation/data details.

   ```swift
   private func waveformBars(from asset: AVURLAsset) async throws -> [CGFloat] {
       guard let audioTrack = try await firstAudioTrack(in: asset) else { return [] }
       let amplitudes = try readPCMAmplitudes(from: asset, track: audioTrack)
       return normalizedBars(from: amplitudes)
   }
   ```

5. `MessagesExtension/WaveformVideoRenderer.swift:136-143` - The PCM settings dictionary is boilerplate-heavy and interrupts the sampling story.

   Suggested refactor: move it behind a named property or helper such as `linearPCMReaderSettings`. That gives readers the "what" without forcing them through AVFoundation keys unless they need the detail.

6. `MessagesExtension/WaveformVideoRenderer.swift:172-186` - Downsampling and normalization are useful standalone concepts, but they are embedded after low-level sample reading. This makes the algorithm harder to test mentally.

   Suggested refactor: extract `averageAmplitudesIntoBars(_:)` and `normalizeBars(_:)`. The body should read like: read amplitudes -> average into bars -> normalize.

7. `MessagesExtension/WaveformVideoRenderer.swift:212-215` - `renderVideo(audioURL:asset:duration:cover:)` accepts `asset` but never uses it. Even though harmless, it creates reader friction because callers must wonder why both `audioURL` and `asset` are needed.

   Suggested refactor: remove the unused `asset` parameter from `renderVideo` and the call site.

8. `MessagesExtension/WaveformVideoRenderer.swift:266-276` - The static-frame duration logic is understandable only after reading the comment and CMTime math together.

   Suggested refactor: extract `presentationTimes(for:)` or `staticFrameCount(for:)` so the loop is about appending frames, not deriving timing.

   ```swift
   for presentationTime in staticFrameTimes(covering: duration) {
       try await waitUntilReadyForMoreMediaData(input)
       adaptor.append(buffer, withPresentationTime: presentationTime)
   }
   ```

9. `MessagesExtension/WaveformVideoRenderer.swift:306` - Missing video and missing audio both throw `RenderError.noAudioTrack`, which makes the muxing narrative misleading even in a readability-only pass.

   Suggested refactor: rename to a more general case like `missingMediaTrack(String)` or add `noVideoTrack`. The error name should match the guard that throws it.

10. `MessagesExtension/MessagesViewController.swift:120-126` - The local variable `localMP3` makes the conversion flow sound format-specific, but the renderer accepts generic audio and the context says source audio may be mp3/m4a.

    Suggested refactor: rename to `localAudioURL` or `convertedAudioURL`.

    ```swift
    let convertedAudioURL = try await service.fetchAudio(audioUrl)
    let clipURL = try await WaveformVideoRenderer().makeVideo(fromAudio: convertedAudioURL)
    ```

11. `MessagesExtension/MessagesViewController.swift:116-128` - The render-to-insert preparation sequence is clear enough, but it is embedded in the broader stop/convert UI flow. As more steps get added, this method will become a mixed-altitude function.

    Suggested refactor: extract the conversion pipeline into `prepareClip(from:) async throws -> URL`, leaving `stopAndConvert` responsible for UI state only.

    ```swift
    private func prepareClip(from recordedURL: URL) async throws -> URL {
        let response = try await service.convert(audioURL: recordedURL, voiceId: voiceId)
        let audioURL = try validatedAudioURL(from: response)
        let localAudioURL = try await service.fetchAudio(audioURL)
        return try await WaveformVideoRenderer().makeVideo(fromAudio: localAudioURL)
    }
    ```

