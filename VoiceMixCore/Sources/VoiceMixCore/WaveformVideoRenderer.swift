import Foundation
import AVFoundation
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

    /// Video output dimensions and timing. The frame is static, so a low fps
    /// keeps the video tiny.
    private enum VideoSpec {
        // Wide-and-short so Messages renders a slim, voice-message-style pill
        // (the bubble takes the video's aspect ratio). Lower the height for a
        // thinner pill; keep both dimensions even for H.264.
        static let frameSize = CGSize(width: 600, height: 140)
        static let framesPerSecond: Int32 = 6
        static let minimumDurationSeconds = 0.1
    }

    /// Metrics for the slim waveform pill cover.
    private enum CoverLayout {
        static let hInset: CGFloat = 36
        static let vInset: CGFloat = 30
        /// Fallback glyph size when no waveform can be sampled.
        static let micPointSize: CGFloat = 56
    }

    /// Wrap `audioURL` in an `.mp4` with a static branded cover and return the
    /// new file URL (durable, uniquely named, in caches).
    func makeVideo(fromAudio audioURL: URL, personaName: String? = nil) async throws -> URL {
        log.info("RENDER: makeVideo entry")
        do {
            let asset = AVURLAsset(url: audioURL)
            let duration = try await loadDuration(asset)
            try Task.checkCancellation()
            let cover = await makeBestAvailableCover(for: asset,
                                                     duration: duration,
                                                     personaName: personaName)
            try Task.checkCancellation()
            let url = try await renderVideo(audioURL: audioURL,
                                            duration: duration,
                                            cover: cover)
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

    /// Try to draw a real waveform from PCM samples; fall back to the static
    /// mic cover if sample reading fails or yields nothing (never blank).
    private func makeBestAvailableCover(for asset: AVURLAsset,
                                        duration: CMTime,
                                        personaName: String?) async -> UIImage {
        if let bars = try? await waveformBars(from: asset), !bars.isEmpty {
            return makeCoverImage(duration: duration, personaName: personaName, centerDraw: { ctx, rect in
                drawWaveform(bars: bars, in: rect, context: ctx)
            })
        }
        return makeCoverImage(duration: duration, personaName: personaName)
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

    /// Build a slim pill cover: dark background filling the frame with the
    /// rainbow waveform spanning its width. Falls back to a small centered mic
    /// glyph when no waveform can be sampled. `duration`/`personaName` are kept
    /// for call-site compatibility but no longer drawn in the slim layout.
    func makeCoverImage(duration: CMTime = .zero,
                        personaName: String? = nil,
                        centerDraw: ((CGContext, CGRect) -> Void)? = nil) -> UIImage {
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
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: linearPCMReaderSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        var sums = Array(repeating: CGFloat.zero, count: barCount)
        var counts = Array(repeating: 0, count: barCount)
        var sampleIndex = 0
        let estimatedTotalSamples = max(estimatedTotalSamples, barCount)

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

        guard reader.status == .completed || reader.status == .reading else { return [] }
        let bars = sums.enumerated().compactMap { index, sum -> CGFloat? in
            guard counts[index] > 0 else { return nil }
            return sum / CGFloat(counts[index])
        }
        return normalizeBars(bars)
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
        var sampleRate = 44_100.0
        if let description = formatDescriptions.first {
            if let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
                sampleRate = max(streamDescription.pointee.mSampleRate, 1)
            }
        }
        return max(Int(durationSeconds * sampleRate), 1)
    }

    /// Normalize so the loudest bar reaches full height.
    private func normalizeBars(_ bars: [CGFloat]) -> [CGFloat] {
        guard let peak = bars.max(), peak > 0 else { return [] }
        return bars.map { $0 / peak }
    }

    /// Draw normalized bars as a centered vertical-bar waveform in `rect`.
    private func drawWaveform(bars: [CGFloat], in rect: CGRect, context: CGContext) {
        guard !bars.isEmpty else { return }
        let spacing: CGFloat = 3
        let totalSpacing = spacing * CGFloat(bars.count - 1)
        let barWidth = max((rect.width - totalSpacing) / CGFloat(bars.count), 1)
        let midY = rect.midY
        let minBar: CGFloat = 4

        for (i, value) in bars.enumerated() {
            let t = CGFloat(i) / CGFloat(max(bars.count, 1))
            let color = Self.rainbowColor(t: t, lightness: 0.62, saturation: 1, alpha: 1)
            let x = rect.minX + CGFloat(i) * (barWidth + spacing)
            let height = max(value * rect.height, minBar)
            let barRect = CGRect(x: x, y: midY - height / 2, width: barWidth, height: height)
            let path = UIBezierPath(roundedRect: barRect, cornerRadius: barWidth / 2)
            context.saveGState()
            context.setShadow(offset: .zero, blur: 10, color: color.withAlphaComponent(0.90).cgColor)
            color.setFill()
            path.fill()
            context.restoreGState()
        }
    }

    // MARK: - Render + mux

    private func renderVideo(audioURL: URL,
                             duration: CMTime,
                             cover: UIImage) async throws -> URL {
        let outputURL = uniqueTempURL(suffix: "voiceMix", ext: "mp4")
        try? FileManager.default.removeItem(at: outputURL)
        do {
            try await writeMovie(cover: cover,
                                 audioURL: audioURL,
                                 duration: duration,
                                 to: outputURL)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        return outputURL
    }

    private func writeMovie(cover: UIImage,
                            audioURL: URL,
                            duration: CMTime,
                            to url: URL) async throws {
        log.info("RENDER: writeMovie entry")
        guard let cgImage = cover.cgImage else { throw RenderError.pixelBufferFailed }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
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

        guard let buffer = pixelBuffer(from: cgImage) else {
            writer.cancelWriting()
            throw RenderError.pixelBufferFailed
        }

        do {
            // Both inputs must be fed concurrently — feeding the full video
            // track while the audio input sits unfed fills the video input's
            // queue and the muxer deadlocks waiting to interleave audio.
            async let video: Void = writeVideoTrack(input: videoInput,
                                                    adaptor: adaptor,
                                                    buffer: buffer,
                                                    duration: duration,
                                                    writer: writer)
            async let audio: Void = writeAudioTrack(reader: audioReader,
                                                    output: audioOutput,
                                                    input: audioInput,
                                                    writer: writer)
            try await video
            try await audio
        } catch {
            log.error("RENDER: writeMovie cancel/fail \(error.localizedDescription)")
            audioReader.cancelReading()
            writer.cancelWriting()
            throw error
        }

        if Task.isCancelled {
            audioReader.cancelReading()
            writer.cancelWriting()
            throw CancellationError()
        }
        writer.endSession(atSourceTime: duration)
        await writer.finishWriting()

        if writer.status != .completed {
            throw RenderError.exportFailed(writer.error?.localizedDescription ?? "movie write failed")
        }
        log.info("RENDER: writeMovie exit")
    }

    private func makeVideoInput() -> AVAssetWriterInput {
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(VideoSpec.frameSize.width),
            AVVideoHeightKey: Int(VideoSpec.frameSize.height),
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

    private func writeVideoTrack(input: AVAssetWriterInput,
                                 adaptor: AVAssetWriterInputPixelBufferAdaptor,
                                 buffer: CVPixelBuffer,
                                 duration: CMTime,
                                 writer: AVAssetWriter) async throws {
        log.info("RENDER: writeVideoTrack entry")
        for presentationTime in staticFrameTimes(covering: duration) {
            try Task.checkCancellation()
            try await waitForInputReady(input, writer: writer)
            guard adaptor.append(buffer, withPresentationTime: presentationTime) else {
                let message = writer.error?.localizedDescription ?? "video append failed"
                log.error("RENDER: video append failed \(message)")
                writer.cancelWriting()
                throw RenderError.appendFailed(message)
            }
        }
        input.markAsFinished()
        log.info("RENDER: writeVideoTrack exit")
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
        let frameCount = max(Int(durationSeconds * Double(fps)), 2)
        return (0..<frameCount).map { CMTime(value: CMTimeValue($0), timescale: fps) }
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

    private static func rainbowColor(t: CGFloat,
                                     lightness: CGFloat,
                                     saturation: CGFloat,
                                     alpha: CGFloat) -> UIColor {
        let hueDegrees = (140 + t * 280).truncatingRemainder(dividingBy: 360)
        return UIColor(hue: hueDegrees / 360,
                       saturation: saturation,
                       brightness: lightness,
                       alpha: alpha)
    }
}
