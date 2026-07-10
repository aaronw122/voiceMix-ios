import CoreGraphics
import Foundation

/// Shared geometry + color model for the waveform, consumed by BOTH the SwiftUI
/// `Canvas` preview (`NeonWaveformView`) and the Core Graphics mp4 renderer
/// (`WaveformVideoRenderer`). Keeping the layout math and colors in one place
/// means the in-app preview and the baked video can never visually drift.
///
/// All rects use a **top-left origin** (like SwiftUI's `Canvas`). The mp4
/// renderer flips its raw pixel-buffer context to match before drawing.

/// A color as raw RGBA components (0...1). Both `UIColor` (Core Graphics) and
/// SwiftUI `Color` rebuild from the same numbers, so the HSB→RGB conversion
/// happens exactly once (here) and cannot drift between backends.
public struct WaveformRGBA: Equatable {
    public let red: CGFloat
    public let green: CGFloat
    public let blue: CGFloat
    public let alpha: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Single-source HSB→RGB so played-bar rainbow colors are byte-identical in
    /// both renderers. `hue`, `saturation`, `brightness`, `alpha` are all 0...1.
    /// Device-RGB `CGColor` for Core Graphics fills (matches the renderer's
    /// pixel-buffer context color space).
    public var cgColor: CGColor {
        CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(),
                components: [red, green, blue, alpha]) ?? CGColor(gray: 0, alpha: alpha)
    }

    public init(hue: CGFloat, saturation: CGFloat, brightness: CGFloat, alpha: CGFloat) {
        guard saturation > 0 else {
            self.init(red: brightness, green: brightness, blue: brightness, alpha: alpha)
            return
        }
        let h6 = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let sector = floor(h6)
        let f = h6 - sector
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * f)
        let t = brightness * (1 - saturation * (1 - f))
        let (r, g, b): (CGFloat, CGFloat, CGFloat)
        switch Int(sector) % 6 {
        case 0: (r, g, b) = (brightness, t, p)
        case 1: (r, g, b) = (q, brightness, p)
        case 2: (r, g, b) = (p, brightness, t)
        case 3: (r, g, b) = (p, q, brightness)
        case 4: (r, g, b) = (t, p, brightness)
        default: (r, g, b) = (brightness, p, q)
        }
        self.init(red: r, green: g, blue: b, alpha: alpha)
    }
}

/// Parameterizes the played (rainbow) vs. unplayed (faded) treatment plus the
/// playhead. `faded` is an **opaque, pre-composited** color so unplayed bars
/// look identical over the renderer's dark gradient and the preview background.
public struct WaveformPalette {
    /// Opaque faded color for unplayed / resting bars.
    public let faded: WaveformRGBA
    /// Bright leading-edge playhead color.
    public let playhead: WaveformRGBA

    public init(faded: WaveformRGBA, playhead: WaveformRGBA) {
        self.faded = faded
        self.playhead = playhead
    }

    /// The rainbow hue for a played bar at normalized position `t` (0...1) —
    /// the same formula the app has always used.
    public func played(t: CGFloat) -> WaveformRGBA {
        let hueDegrees = (140 + t * 280).truncatingRemainder(dividingBy: 360)
        return WaveformRGBA(hue: hueDegrees / 360, saturation: 1, brightness: 0.62, alpha: 1)
    }

    /// Mid-gray unplayed bars: the baked video can't adapt to light/dark, so
    /// pick one opaque tone that reads over both white and black transcript
    /// backgrounds (pure white vanished in light-mode Messages).
    public static let standard = WaveformPalette(
        faded: WaveformRGBA(red: 0.52, green: 0.52, blue: 0.52, alpha: 1),
        playhead: WaveformRGBA(red: 0.52, green: 0.52, blue: 0.52, alpha: 0.92)
    )
}

/// One bar's resolved geometry + color (top-left origin coordinate space).
public struct WaveformBar {
    public let rect: CGRect
    public let color: WaveformRGBA
    public let isPlayed: Bool
}

/// A fully resolved waveform for a single progress value: the bars plus the
/// leading playhead x (nil when nothing is played yet).
public struct WaveformFrame {
    public let bars: [WaveformBar]
    public let playheadX: CGFloat?
    public let playhead: WaveformRGBA
    public let cornerRadius: CGFloat
}

public enum WaveformLayout {
    public static let barCount = 54

    /// Resolve the waveform for `progress` (0...1) at `size`. `bars` are the
    /// normalized amplitudes (0...1); missing entries fall back to a stable
    /// synthetic shape so the layout is never blank.
    public static func frame(bars: [Double],
                             progress: Double,
                             size: CGSize,
                             palette: WaveformPalette = .standard) -> WaveformFrame {
        let count = barCount
        let gap = size.width / CGFloat(count)
        let barWidth = max(2.5, gap * 0.42)
        let midY = size.height / 2
        let maxHalfHeight = size.height * 0.48
        let cornerRadius = min(barWidth / 2, 6)
        let clampedProgress = min(max(progress, 0), 1)

        var resolved: [WaveformBar] = []
        resolved.reserveCapacity(count)
        for index in 0..<count {
            let t = CGFloat(index) / CGFloat(count)
            let amplitude = index < bars.count ? CGFloat(bars[index]) : fallbackBar(index)
            let height = max(3, amplitude * maxHalfHeight)
            let rect = CGRect(x: CGFloat(index) * gap + (gap - barWidth) / 2,
                              y: midY - height,
                              width: barWidth,
                              height: height * 2)
            // Strict `<` so at progress 0 no bar is lit (fully faded at rest).
            let isPlayed = Double(t) < clampedProgress
            let color = isPlayed ? palette.played(t: t) : palette.faded
            resolved.append(WaveformBar(rect: rect, color: color, isPlayed: isPlayed))
        }

        let playheadX: CGFloat? = clampedProgress > 0 ? CGFloat(clampedProgress) * size.width : nil
        return WaveformFrame(bars: resolved,
                             playheadX: playheadX,
                             playhead: palette.playhead,
                             cornerRadius: cornerRadius)
    }

    /// Stable synthetic amplitude when no sampled bar exists at `index`.
    public static func fallbackBar(_ index: Int) -> CGFloat {
        0.2 + 0.6 * abs(sin(Double(index) * 0.7) * cos(Double(index) * 0.31))
    }
}
