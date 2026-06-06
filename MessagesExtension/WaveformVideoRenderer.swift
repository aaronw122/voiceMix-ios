import Foundation
import AVFoundation
import UIKit

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

    enum RenderError: Error {
        case noAudioTrack
        case writerSetupFailed
        case pixelBufferFailed
        case exportFailed(String)
    }

    private let frameSize = CGSize(width: 600, height: 600)
    /// The frame is static, so a low fps keeps the video tiny.
    private let fps: Int32 = 6

    /// Wrap `audioURL` in an `.mp4` with a static branded cover and return the
    /// new file URL (durable, uniquely named, in caches).
    func makeVideo(fromAudio audioURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: audioURL)
        let duration = try await loadDuration(asset)

        let cover = makeCoverImage()
        return try await renderVideo(audioURL: audioURL,
                                     asset: asset,
                                     duration: duration,
                                     cover: cover)
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

    /// Build a clean, branded square cover: dark background, centered mic glyph,
    /// and the "voiceMix" wordmark. Subclasses of this concern (the waveform)
    /// override the center by passing a custom drawing block.
    func makeCoverImage(centerDraw: ((CGContext, CGRect) -> Void)? = nil) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: frameSize)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            let bounds = CGRect(origin: .zero, size: frameSize)

            // Dark neutral background.
            UIColor(white: 0.07, alpha: 1.0).setFill()
            cg.fill(bounds)

            // Subtle rounded inner frame.
            let inset = bounds.insetBy(dx: 40, dy: 40)
            let framePath = UIBezierPath(roundedRect: inset, cornerRadius: 28)
            UIColor(white: 0.16, alpha: 1.0).setStroke()
            framePath.lineWidth = 3
            framePath.stroke()

            let accent = UIColor(red: 0.40, green: 0.78, blue: 1.0, alpha: 1.0)

            if let centerDraw {
                // Custom center (e.g. waveform). Reserve the middle band.
                let centerRect = CGRect(x: inset.minX + 40,
                                        y: frameSize.height * 0.30,
                                        width: inset.width - 80,
                                        height: frameSize.height * 0.30)
                centerDraw(cg, centerRect)
            } else {
                // Default: centered mic glyph.
                let config = UIImage.SymbolConfiguration(pointSize: 200, weight: .semibold)
                if let mic = UIImage(systemName: "mic.fill", withConfiguration: config) {
                    let tinted = mic.withTintColor(accent, renderingMode: .alwaysOriginal)
                    let micSize = tinted.size
                    let micOrigin = CGPoint(x: (frameSize.width - micSize.width) / 2,
                                            y: frameSize.height * 0.30)
                    tinted.draw(at: micOrigin)
                }
            }

            // Wordmark.
            let text = "voiceMix"
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 64, weight: .bold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph,
            ]
            let textSize = (text as NSString).size(withAttributes: attrs)
            let textRect = CGRect(x: 0,
                                  y: frameSize.height * 0.70,
                                  width: frameSize.width,
                                  height: textSize.height)
            (text as NSString).draw(in: textRect, withAttributes: attrs)
        }
    }

    // MARK: - Render + mux

    private func renderVideo(audioURL: URL,
                             asset: AVURLAsset,
                             duration: CMTime,
                             cover: UIImage) async throws -> URL {
        let videoOnlyURL = uniqueTempURL(suffix: "video", ext: "mp4")
        try? FileManager.default.removeItem(at: videoOnlyURL)

        // 1. Write a video-only track holding the static cover for the duration.
        try await writeVideoTrack(cover: cover, duration: duration, to: videoOnlyURL)

        // 2. Mux video + source audio into a final mp4 (re-encoded to AAC).
        let outputURL = try await mux(videoURL: videoOnlyURL,
                                      audioURL: audioURL,
                                      duration: duration)

        try? FileManager.default.removeItem(at: videoOnlyURL)
        return outputURL
    }

    private func writeVideoTrack(cover: UIImage,
                                 duration: CMTime,
                                 to url: URL) async throws {
        guard let cgImage = cover.cgImage else { throw RenderError.pixelBufferFailed }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(frameSize.width),
            AVVideoHeightKey: Int(frameSize.height),
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
            kCVPixelBufferWidthKey as String: Int(frameSize.width),
            kCVPixelBufferHeightKey as String: Int(frameSize.height),
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                           sourcePixelBufferAttributes: attrs)

        guard writer.canAdd(input) else { throw RenderError.writerSetupFailed }
        writer.add(input)

        guard writer.startWriting() else {
            throw RenderError.exportFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        guard let buffer = pixelBuffer(from: cgImage) else {
            throw RenderError.pixelBufferFailed
        }

        // A static frame at .zero plus one at the end pins length to the audio.
        let durationSeconds = max(CMTimeGetSeconds(duration), 0.1)
        let frameCount = max(Int(durationSeconds * Double(fps)), 2)

        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let presentationTime = CMTime(value: CMTimeValue(frame),
                                          timescale: fps)
            adaptor.append(buffer, withPresentationTime: presentationTime)
        }

        input.markAsFinished()
        writer.endSession(atSourceTime: duration)
        await writer.finishWriting()

        if writer.status != .completed {
            throw RenderError.exportFailed(writer.error?.localizedDescription ?? "video write failed")
        }
    }

    private func mux(videoURL: URL,
                     audioURL: URL,
                     duration: CMTime) async throws -> URL {
        let composition = AVMutableComposition()

        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)

        let videoTracks: [AVAssetTrack]
        let audioTracks: [AVAssetTrack]
        if #available(iOS 16.0, *) {
            videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
            audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        } else {
            videoTracks = videoAsset.tracks(withMediaType: .video)
            audioTracks = audioAsset.tracks(withMediaType: .audio)
        }

        guard let sourceVideo = videoTracks.first else { throw RenderError.noAudioTrack }
        guard let sourceAudio = audioTracks.first else { throw RenderError.noAudioTrack }

        let range = CMTimeRange(start: .zero, duration: duration)

        if let compVideo = composition.addMutableTrack(withMediaType: .video,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid) {
            try compVideo.insertTimeRange(range, of: sourceVideo, at: .zero)
        }
        if let compAudio = composition.addMutableTrack(withMediaType: .audio,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid) {
            try compAudio.insertTimeRange(range, of: sourceAudio, at: .zero)
        }

        let outputURL = uniqueTempURL(suffix: "voiceMix", ext: "mp4")
        try? FileManager.default.removeItem(at: outputURL)

        // Re-encode (NOT passthrough) so mp3/m4a source audio becomes AAC in mp4.
        guard let export = AVAssetExportSession(asset: composition,
                                                presetName: AVAssetExportPresetMediumQuality) else {
            throw RenderError.exportFailed("could not create export session")
        }
        export.outputURL = outputURL
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true

        if #available(iOS 18.0, *) {
            try await export.export(to: outputURL, as: .mp4)
        } else {
            await export.export()
            if export.status != .completed {
                throw RenderError.exportFailed(export.error?.localizedDescription ?? "export failed")
            }
        }

        return outputURL
    }

    // MARK: - Pixel buffer

    private func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        let width = Int(frameSize.width)
        let height = Int(frameSize.height)

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
