#if canImport(UIKit)
import Foundation
import AVFoundation
import VideoToolbox
import UIKit
import os

/// Presentation-layer wrapper that turns a converted audio file into a short
/// `.mp4` so Messages renders an inline media bubble (with a play button) that
/// plays in the transcript for any recipient. A third-party iMessage extension
/// cannot produce the native voice-message bubble, but video attachments DO
/// play inline — so we mux a static cover image over the audio track.
///
/// This is intentionally NOT part of `ConvertService`: conversion still returns
/// an audio file URL; this step is applied uniformly to mock and live audio
/// just before `insertAttachment`.
struct WaveformVideoRenderer {

    private let log = Logger(subsystem: "com.aaron.voiceMixer", category: "render")

    enum RenderError: Error {
        case noAudioTrack
        case noVideoTrack
        case writerSetupFailed
        case pixelBufferFailed
        case exportFailed(String)
        case writerTimedOut
        case appendFailed(String)
    }

    /// Video output dimensions and timing.
    private enum VideoSpec {
        // Wide-and-short so Messages renders a slim, voice-message-style pill
        // (the bubble takes the video's aspect ratio). Lower the height for a
        // thinner pill; keep both dimensions even for H.264.
        static let frameSize = CGSize(width: 600, height: 140)
        // Animated progress needs distinct frames; 12fps is smooth enough while
        // keeping the encode light inside the extension's memory budget.
        static let framesPerSecond: Int32 = 12
        static let minimumDurationSeconds = 0.1
        // Hard cap on rendered frames so long clips never explode the frame
        // count (and memory); above this the effective fps drops.
        static let maxFrames = 240

        // Transparent background via HEVC-with-alpha so the pill blends into the
        // message bubble instead of sitting on a dark rectangle. Alpha video
        // needs the QuickTime (.mov) container.
        static let fileType: AVFileType = .mov
        static let fileExtension = "mov"
    }

    /// What the video track shows: an animated waveform (played bars fill to
    /// rainbow behind a playhead) or, when no bars can be sampled, a static
    /// mic-glyph cover repeated for the clip.
    private enum VideoContent {
        case animated(bars: [Double])
        case staticCover(UIImage)
    }

    /// Metrics for the slim waveform pill cover.
    private enum CoverLayout {
        static let hInset: CGFloat = 36
        static let vInset: CGFloat = 30
        /// Fallback glyph size when no waveform can be sampled.
        static let micPointSize: CGFloat = 56
    }

    /// Wrap `audioURL` in an `.mp4` whose waveform advances in sync with the
    /// audio, and return the new file URL (durable, uniquely named, in caches).
    func makeVideo(fromAudio audioURL: URL, personaName: String? = nil) async throws -> URL {
        log.info("RENDER: makeVideo entry")
        do {
            let asset = AVURLAsset(url: audioURL)
            let duration = try await loadDuration(asset)
            try Task.checkCancellation()
            // Sample the waveform once here; the animated path reuses these bars
            // for every frame (no second PCM read).
            let bars = (try? await waveformBars(from: asset))?.map(Double.init) ?? []
            try Task.checkCancellation()
            let content: VideoContent = bars.isEmpty ? .staticCover(makeCoverImage())
                                                     : .animated(bars: bars)
            let url = try await renderVideo(audioURL: audioURL, duration: duration, content: content)
            log.info("RENDER: makeVideo exit")
            return url
        } catch {
            log.error("RENDER: makeVideo threw \(error.localizedDescription)")
            throw error
        }
    }

    /// Return the same normalized audio-derived bars used by the MP4 cover so
    /// the in-extension preview matches the media that gets inserted.
    func displayBars(fromAudio audioURL: URL) async -> [Double] {
        let asset = AVURLAsset(url: audioURL)
        guard let bars = try? await waveformBars(from: asset), !bars.isEmpty else { return [] }
        return bars.map(Double.init)
    }

    // MARK: - Duration

    private func loadDuration(_ asset: AVURLAsset) async throws -> CMTime {
        if #available(iOS 16.0, *) {
            return try await asset.load(.duration)
        } else {
            return asset.duration
        }
    }

    // MARK: - Cover image

    /// Build the static fallback pill cover: dark background with a centered mic
    /// glyph, used only when no waveform can be sampled.
    func makeCoverImage(centerDraw: ((CGContext, CGRect) -> Void)? = nil) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: VideoSpec.frameSize)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            let bounds = CGRect(origin: .zero, size: VideoSpec.frameSize)
            let inset = bounds.insetBy(dx: CoverLayout.hInset, dy: CoverLayout.vInset)

            drawCoverBackground(in: bounds, context: cg)
            if let centerDraw {
                centerDraw(cg, inset)
            } else {
                drawFallbackMic(in: inset, context: cg)
            }
        }
    }

    private var coverAccentColor: UIColor {
        UIColor(red: 0.40, green: 0.78, blue: 1.0, alpha: 1.0)
    }

    /// Dark sheet-compatible background.
    private func drawCoverBackground(in bounds: CGRect, context cg: CGContext) {
        let colors = [
            UIColor(hex: 0x161619).cgColor,
            UIColor(hex: 0x0C0C0E).cgColor,
        ] as CFArray
        let locations: [CGFloat] = [0, 1]
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors,
                                        locations: locations) else { return }
        cg.drawLinearGradient(gradient,
                              start: CGPoint(x: bounds.midX, y: bounds.minY),
                              end: CGPoint(x: bounds.midX, y: bounds.maxY),
                              options: [])
    }

    /// Centered mic glyph used only when no waveform can be sampled.
    private func drawFallbackMic(in rect: CGRect, context cg: CGContext) {
        let config = UIImage.SymbolConfiguration(pointSize: CoverLayout.micPointSize, weight: .semibold)
        guard let mic = UIImage(systemName: "mic.fill", withConfiguration: config) else { return }
        let tinted = mic.withTintColor(coverAccentColor, renderingMode: .alwaysOriginal)
        let origin = CGPoint(x: rect.midX - tinted.size.width / 2,
                             y: rect.midY - tinted.size.height / 2)
        tinted.draw(at: origin)
    }

    // MARK: - Waveform sampling

    private let barCount = 54

    /// Read linear PCM, average absolute amplitude into 54 buckets, normalize
    /// to 0...1. Returns nil/empty on any failure so the caller can fall back.
    private func waveformBars(from asset: AVURLAsset) async throws -> [CGFloat] {
        guard let audioTrack = try await firstAudioTrack(in: asset) else { return [] }
        let estimatedTotalSamples = try await estimatedSampleCount(for: audioTrack)
        return try readPCMAmplitudes(from: asset,
                                     track: audioTrack,
                                     estimatedTotalSamples: estimatedTotalSamples)
    }

    private func firstAudioTrack(in asset: AVURLAsset) async throws -> AVAssetTrack? {
        let tracks: [AVAssetTrack]
        if #available(iOS 16.0, *) {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } else {
            tracks = asset.tracks(withMediaType: .audio)
        }
        return tracks.first
    }

    /// 16-bit interleaved little-endian linear PCM — the simplest format to
    /// decode into `Int16` samples below.
    private var linearPCMReaderSettings: [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// Stream audio samples into a fixed number of buckets. Never retain
    /// per-sample amplitudes; iMessage extensions have a tight memory budget.
    private func readPCMAmplitudes(from asset: AVURLAsset,
                                   track: AVAssetTrack,
                                   estimatedTotalSamples: Int) throws -> [CGFloat] {
        guard let (reader, output) = try makePCMReader(for: asset, track: track) else { return [] }

        var sums = Array(repeating: CGFloat.zero, count: barCount)
        var counts = Array(repeating: 0, count: barCount)
        accumulateBuckets(from: output,
                          estimatedTotalSamples: max(estimatedTotalSamples, barCount),
                          sums: &sums,
                          counts: &counts)

        guard reader.status == .completed || reader.status == .reading else { return [] }
        return normalizeBars(averageBuckets(sums: sums, counts: counts))
    }

    private func makePCMReader(for asset: AVURLAsset,
                               track: AVAssetTrack) throws -> (AVAssetReader, AVAssetReaderTrackOutput)? {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: linearPCMReaderSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        return (reader, output)
    }

    private func accumulateBuckets(from output: AVAssetReaderTrackOutput,
                                   estimatedTotalSamples: Int,
                                   sums: inout [CGFloat],
                                   counts: inout [Int]) {
        var sampleIndex = 0
        while let sample = output.copyNextSampleBuffer() {
            autoreleasepool {
                guard let block = CMSampleBufferGetDataBuffer(sample) else {
                    CMSampleBufferInvalidate(sample)
                    return
                }
                let length = CMBlockBufferGetDataLength(block)
                var data = Data(count: length)
                data.withUnsafeMutableBytes { raw in
                    if let base = raw.baseAddress {
                        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
                    }
                }
                data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    let samples = raw.bindMemory(to: Int16.self)
                    for value in samples {
                        let bucket = min(barCount - 1, sampleIndex * barCount / estimatedTotalSamples)
                        sums[bucket] += CGFloat(abs(Int(value))) / CGFloat(Int16.max)
                        counts[bucket] += 1
                        sampleIndex += 1
                    }
                }
                CMSampleBufferInvalidate(sample)
            }
        }
    }

    private func averageBuckets(sums: [CGFloat], counts: [Int]) -> [CGFloat] {
        sums.enumerated().compactMap { index, sum -> CGFloat? in
            guard counts[index] > 0 else { return nil }
            return sum / CGFloat(counts[index])
        }
    }

    private func estimatedSampleCount(for track: AVAssetTrack) async throws -> Int {
        let timeRange: CMTimeRange
        let formatDescriptions: [CMFormatDescription]

        if #available(iOS 16.0, *) {
            timeRange = try await track.load(.timeRange)
            formatDescriptions = try await track.load(.formatDescriptions)
        } else {
            timeRange = track.timeRange
            formatDescriptions = track.formatDescriptions as! [CMFormatDescription]
        }

        let durationSeconds = max(CMTimeGetSeconds(timeRange.duration), 0)
        return max(Int(durationSeconds * sampleRate(from: formatDescriptions)), 1)
    }

    private func sampleRate(from formatDescriptions: [CMFormatDescription]) -> Double {
        let defaultRate = 44_100.0
        guard let description = formatDescriptions.first,
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            return defaultRate
        }
        return max(streamDescription.pointee.mSampleRate, 1)
    }

    /// Normalize so the loudest bar reaches full height.
    private func normalizeBars(_ bars: [CGFloat]) -> [CGFloat] {
        guard let peak = bars.max(), peak > 0 else { return [] }
        return bars.map { $0 / peak }
    }

    // MARK: - Render + mux

    private func renderVideo(audioURL: URL,
                             duration: CMTime,
                             content: VideoContent) async throws -> URL {
        let outputURL = uniqueTempURL(suffix: "voiceMix", ext: VideoSpec.fileExtension)
        try? FileManager.default.removeItem(at: outputURL)
        do {
            try await writeMovie(content: content,
                                 audioURL: audioURL,
                                 duration: duration,
                                 to: outputURL)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        return outputURL
    }

    private struct MuxPipeline {
        let writer: AVAssetWriter
        let videoInput: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let audioReader: AVAssetReader
        let audioOutput: AVAssetReaderTrackOutput
        let audioInput: AVAssetWriterInput
    }

    private func writeMovie(content: VideoContent,
                            audioURL: URL,
                            duration: CMTime,
                            to url: URL) async throws {
        log.info("RENDER: writeMovie entry")
        let pipeline = try await makeMuxPipeline(audioURL: audioURL, to: url)
        let writer = pipeline.writer

        do {
            // Both inputs must be fed concurrently — feeding the full video
            // track while the audio input sits unfed fills the video input's
            // queue and the muxer deadlocks waiting to interleave audio.
            async let video: Void = writeVideoTrack(content: content,
                                                    pipeline: pipeline,
                                                    duration: duration)
            async let audio: Void = writeAudioTrack(reader: pipeline.audioReader,
                                                    output: pipeline.audioOutput,
                                                    input: pipeline.audioInput,
                                                    writer: writer)
            try await video
            try await audio
        } catch {
            log.error("RENDER: writeMovie cancel/fail \(error.localizedDescription)")
            pipeline.audioReader.cancelReading()
            writer.cancelWriting()
            throw error
        }

        try await finalizeMux(pipeline, duration: duration)
        log.info("RENDER: writeMovie exit")
    }

    private func makeMuxPipeline(audioURL: URL, to url: URL) async throws -> MuxPipeline {
        let writer = try AVAssetWriter(outputURL: url, fileType: VideoSpec.fileType)
        let videoInput = makeVideoInput()
        let adaptor = makePixelBufferAdaptor(for: videoInput)
        let audioAsset = AVURLAsset(url: audioURL)
        guard let audioTrack = try await firstAudioTrack(in: audioAsset) else { throw RenderError.noAudioTrack }
        try Task.checkCancellation()
        let audioReader = try AVAssetReader(asset: audioAsset)
        let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: linearPCMReaderSettings)
        audioOutput.alwaysCopiesSampleData = false
        let audioInput = makeAudioInput()

        guard writer.canAdd(videoInput), writer.canAdd(audioInput), audioReader.canAdd(audioOutput) else {
            throw RenderError.writerSetupFailed
        }
        writer.add(videoInput)
        writer.add(audioInput)
        audioReader.add(audioOutput)

        guard writer.startWriting() else {
            throw RenderError.exportFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        guard audioReader.startReading() else {
            writer.cancelWriting()
            throw RenderError.exportFailed(audioReader.error?.localizedDescription ?? "audio reader failed")
        }
        writer.startSession(atSourceTime: .zero)

        return MuxPipeline(writer: writer,
                           videoInput: videoInput,
                           adaptor: adaptor,
                           audioReader: audioReader,
                           audioOutput: audioOutput,
                           audioInput: audioInput)
    }

    private func finalizeMux(_ pipeline: MuxPipeline, duration: CMTime) async throws {
        let writer = pipeline.writer
        if Task.isCancelled {
            pipeline.audioReader.cancelReading()
            writer.cancelWriting()
            throw CancellationError()
        }
        writer.endSession(atSourceTime: duration)
        await writer.finishWriting()

        if writer.status != .completed {
            throw RenderError.exportFailed(writer.error?.localizedDescription ?? "movie write failed")
        }
    }

    private func makeVideoInput() -> AVAssetWriterInput {
        var settings: [String: Any] = [
            AVVideoWidthKey: Int(VideoSpec.frameSize.width),
            AVVideoHeightKey: Int(VideoSpec.frameSize.height),
        ]
        // HEVC-with-alpha carries a real alpha channel (H.264 cannot), so the
        // transparent frames blend into the message bubble.
        settings[AVVideoCodecKey] = AVVideoCodecType.hevcWithAlpha
        settings[AVVideoCompressionPropertiesKey] = [
            kVTCompressionPropertyKey_AlphaChannelMode as String:
                kVTAlphaChannelMode_PremultipliedAlpha as String,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        return input
    }

    private func makePixelBufferAdaptor(for input: AVAssetWriterInput) -> AVAssetWriterInputPixelBufferAdaptor {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
            kCVPixelBufferWidthKey as String: Int(VideoSpec.frameSize.width),
            kCVPixelBufferHeightKey as String: Int(VideoSpec.frameSize.height),
        ]
        return AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                    sourcePixelBufferAttributes: attrs)
    }

    private func makeAudioInput() -> AVAssetWriterInput {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        return input
    }

    private func writeVideoTrack(content: VideoContent,
                                 pipeline: MuxPipeline,
                                 duration: CMTime) async throws {
        switch content {
        case .animated(let bars):
            try await writeAnimatedVideoTrack(bars: bars, pipeline: pipeline, duration: duration)
        case .staticCover(let image):
            try await writeStaticVideoTrack(image: image, pipeline: pipeline, duration: duration)
        }
    }

    /// Fallback path: one repeated cover frame for the whole clip.
    private func writeStaticVideoTrack(image: UIImage,
                                       pipeline: MuxPipeline,
                                       duration: CMTime) async throws {
        log.info("RENDER: writeStaticVideoTrack entry")
        let writer = pipeline.writer
        guard let cgImage = image.cgImage, let buffer = pixelBuffer(from: cgImage) else {
            writer.cancelWriting()
            throw RenderError.pixelBufferFailed
        }
        for presentationTime in staticFrameTimes(covering: duration) {
            try Task.checkCancellation()
            try await waitForInputReady(pipeline.videoInput, writer: writer)
            guard pipeline.adaptor.append(buffer, withPresentationTime: presentationTime) else {
                let message = writer.error?.localizedDescription ?? "video append failed"
                log.error("RENDER: video append failed \(message)")
                writer.cancelWriting()
                throw RenderError.appendFailed(message)
            }
        }
        pipeline.videoInput.markAsFinished()
        log.info("RENDER: writeStaticVideoTrack exit")
    }

    /// Animated path: a distinct frame per presentation time, each drawn with
    /// the waveform filled to that frame's progress. Each frame uses a fresh
    /// pooled buffer inside an autoreleasepool to stay within the extension's
    /// memory budget.
    private func writeAnimatedVideoTrack(bars: [Double],
                                         pipeline: MuxPipeline,
                                         duration: CMTime) async throws {
        log.info("RENDER: writeAnimatedVideoTrack entry")
        let writer = pipeline.writer
        for frame in animatedFrameTimes(covering: duration) {
            try Task.checkCancellation()
            try await waitForInputReady(pipeline.videoInput, writer: writer)
            try autoreleasepool {
                guard let buffer = newPixelBuffer(from: pipeline.adaptor) else {
                    writer.cancelWriting()
                    throw RenderError.pixelBufferFailed
                }
                drawAnimatedFrame(bars: bars, progress: frame.progress, into: buffer)
                guard pipeline.adaptor.append(buffer, withPresentationTime: frame.time) else {
                    let message = writer.error?.localizedDescription ?? "video append failed"
                    log.error("RENDER: video append failed \(message)")
                    writer.cancelWriting()
                    throw RenderError.appendFailed(message)
                }
            }
        }
        pipeline.videoInput.markAsFinished()
        log.info("RENDER: writeAnimatedVideoTrack exit")
    }

    private func writeAudioTrack(reader: AVAssetReader,
                                 output: AVAssetReaderTrackOutput,
                                 input: AVAssetWriterInput,
                                 writer: AVAssetWriter) async throws {
        log.info("RENDER: writeAudioTrack entry")
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            try await waitForInputReady(input, writer: writer)
            let appended = input.append(sample)
            CMSampleBufferInvalidate(sample)
            guard appended else {
                let message = writer.error?.localizedDescription ?? "audio append failed"
                log.error("RENDER: audio append failed \(message)")
                writer.cancelWriting()
                throw RenderError.appendFailed(message)
            }
        }
        guard reader.status == .completed || reader.status == .reading else {
            throw RenderError.exportFailed(reader.error?.localizedDescription ?? "audio read failed")
        }
        input.markAsFinished()
        log.info("RENDER: writeAudioTrack exit")
    }

    private func waitForInputReady(_ input: AVAssetWriterInput,
                                   writer: AVAssetWriter,
                                   timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            if writer.status == .failed {
                throw RenderError.exportFailed(writer.error?.localizedDescription ?? "writer failed")
            }
            if Date() >= deadline {
                log.error("RENDER: writer input timed out")
                writer.cancelWriting()
                throw RenderError.writerTimedOut
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Presentation times for the static cover frames. A frame at .zero plus
    /// frames through the end pin the video length to the audio.
    private func staticFrameTimes(covering duration: CMTime) -> [CMTime] {
        let fps = VideoSpec.framesPerSecond
        let durationSeconds = max(CMTimeGetSeconds(duration), VideoSpec.minimumDurationSeconds)
        let rawCount = max(Int(durationSeconds * Double(fps)), 2)
        guard rawCount > VideoSpec.maxFrames else {
            return (0..<rawCount).map { CMTime(value: CMTimeValue($0), timescale: fps) }
        }
        return (0..<VideoSpec.maxFrames).map { index in
            let fraction = Double(index) / Double(VideoSpec.maxFrames - 1)
            return CMTime(seconds: fraction * durationSeconds, preferredTimescale: 600)
        }
    }

    /// Presentation times + progress for the animated frames. Times span
    /// `[0, duration)` (no sample on the `endSession` boundary); the final frame
    /// is forced to progress 1.0 and held through `endSession` so the playhead
    /// lands at the far edge exactly as the audio ends. Frame count is capped so
    /// long clips can't explode memory.
    private func animatedFrameTimes(covering duration: CMTime) -> [(time: CMTime, progress: Double)] {
        let durationSeconds = max(CMTimeGetSeconds(duration), VideoSpec.minimumDurationSeconds)
        let rawCount = max(Int(durationSeconds * Double(VideoSpec.framesPerSecond)), 2)
        let frameCount = min(rawCount, VideoSpec.maxFrames)
        if rawCount > VideoSpec.maxFrames {
            log.info("RENDER: frame cap hit (\(rawCount) → \(frameCount) for \(durationSeconds)s)")
        }
        return (0..<frameCount).map { index in
            let fraction = Double(index) / Double(frameCount)
            let time = CMTime(seconds: fraction * durationSeconds, preferredTimescale: 600)
            let progress = index == frameCount - 1 ? 1.0 : fraction
            return (time, progress)
        }
    }

    /// Draw one animated waveform frame directly into a pooled pixel buffer.
    private func drawAnimatedFrame(bars: [Double], progress: Double, into buffer: CVPixelBuffer) {
        let width = Int(VideoSpec.frameSize.width)
        let height = Int(VideoSpec.frameSize.height)

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        // Premultiplied alpha so the cleared background stays transparent.
        guard let cg = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return }

        // Flip to a top-left origin so the shared (top-left) layout draws upright.
        cg.translateBy(x: 0, y: CGFloat(height))
        cg.scaleBy(x: 1, y: -1)

        // Clear to transparent, then draw only the bars/playhead. Pooled buffers
        // recycle stale pixels, so the full clear every frame is required.
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        cg.clear(bounds)

        let frame = WaveformLayout.frame(bars: bars, progress: progress, size: VideoSpec.frameSize)
        for bar in frame.bars {
            cg.addPath(CGPath(roundedRect: bar.rect,
                              cornerWidth: frame.cornerRadius,
                              cornerHeight: frame.cornerRadius,
                              transform: nil))
            cg.setFillColor(bar.color.cgColor)
            cg.fillPath()
        }
        if let playheadX = frame.playheadX {
            let rule = CGRect(x: playheadX - 1, y: 0, width: 2, height: CGFloat(height))
            cg.addPath(CGPath(roundedRect: rule, cornerWidth: 1, cornerHeight: 1, transform: nil))
            cg.setFillColor(frame.playhead.cgColor)
            cg.fillPath()
        }
    }

    /// A fresh pixel buffer from the adaptor's pool (falling back to a direct
    /// allocation if the pool is unavailable).
    private func newPixelBuffer(from adaptor: AVAssetWriterInputPixelBufferAdaptor) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        }
        if buffer == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ]
            CVPixelBufferCreate(kCFAllocatorDefault,
                                Int(VideoSpec.frameSize.width),
                                Int(VideoSpec.frameSize.height),
                                kCVPixelFormatType_32ARGB,
                                attrs as CFDictionary,
                                &buffer)
        }
        return buffer
    }

    // MARK: - Pixel buffer

    private func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        let width = Int(VideoSpec.frameSize.width)
        let height = Int(VideoSpec.frameSize.height)

        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         width, height,
                                         kCVPixelFormatType_32ARGB,
                                         attrs as CFDictionary,
                                         &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    // MARK: - Paths

    private func uniqueTempURL(suffix: String, ext: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("\(suffix)-\(UUID().uuidString).\(ext)")
    }
}
#endif
