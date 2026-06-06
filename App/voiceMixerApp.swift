import SwiftUI
import AVFoundation

@main
struct VoiceMixerApp: App {
    var body: some Scene {
        WindowGroup {
            OnboardingView()
        }
    }
}

struct OnboardingView: View {
    @State private var micPermission = MicPermissionStatus.current

    private let steps: [OnboardingStep] = [
        OnboardingStep(
            symbol: "message.fill",
            title: "Open Messages",
            detail: "Head to the Messages app and open a conversation with a friend."
        ),
        OnboardingStep(
            symbol: "plus.circle.fill",
            title: "Tap the Apps button",
            detail: "Next to the text field, tap the Apps (+) icon to open the iMessage app drawer."
        ),
        OnboardingStep(
            symbol: "square.grid.2x2.fill",
            title: "Find voiceMix",
            detail: "Scroll through the apps and tap voiceMix to open it."
        ),
        OnboardingStep(
            symbol: "person.wave.2.fill",
            title: "Pick a voice",
            detail: "Choose who you want to sound like — a wise old man, a movie narrator, anyone."
        ),
        OnboardingStep(
            symbol: "mic.fill",
            title: "Record & send",
            detail: "Record your message in your own voice, then Send it — it arrives transformed into the chat."
        ),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                VStack(spacing: 12) {
                    Image(systemName: "waveform")
                        .font(.system(size: 56, weight: .semibold))
                        .foregroundStyle(.tint)
                    Text("voiceMix")
                        .font(.largeTitle.bold())
                    Text("Transform your voice into someone else's — right inside Messages.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 48)

                VStack(alignment: .leading, spacing: 24) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        OnboardingRow(number: index + 1, step: step)
                    }
                }
                .padding(.horizontal, 28)

                MicrophonePermissionRow(
                    status: micPermission,
                    enableAction: requestMicrophonePermission
                )
                .padding(.horizontal, 28)

                Text("Once microphone is enabled, record and send from Messages.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 40)
            }
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            micPermission = MicPermissionStatus.current
            requestMicrophonePermissionIfNeeded()
        }
    }

    private func requestMicrophonePermissionIfNeeded() {
        guard MicPermissionStatus.current == .undetermined else { return }
        requestMicrophonePermission()
    }

    private func requestMicrophonePermission() {
        let updateStatus: (Bool) -> Void = { _ in
            Task { @MainActor in
                micPermission = MicPermissionStatus.current
            }
        }

        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: updateStatus)
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission(updateStatus)
        }
    }
}

private struct OnboardingStep {
    let symbol: String
    let title: String
    let detail: String
}

private struct OnboardingRow: View {
    let number: Int
    let step: OnboardingStep

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle()
                    .fill(.tint)
                    .frame(width: 36, height: 36)
                Text("\(number)")
                    .font(.headline)
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: step.symbol)
                        .foregroundStyle(.tint)
                    Text(step.title)
                        .font(.headline)
                }
                Text(step.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private enum MicPermissionStatus {
    case undetermined
    case granted
    case denied

    static var current: MicPermissionStatus {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return .granted
            case .denied: return .denied
            case .undetermined: return .undetermined
            @unknown default: return .undetermined
            }
        } else {
            switch AVAudioSession.sharedInstance().recordPermission {
            case .granted: return .granted
            case .denied: return .denied
            case .undetermined: return .undetermined
            @unknown default: return .undetermined
            }
        }
    }

    var symbol: String {
        switch self {
        case .undetermined: return "mic.fill"
        case .granted: return "checkmark.circle.fill"
        case .denied: return "exclamationmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .undetermined: return .accentColor
        case .granted: return .green
        case .denied: return .orange
        }
    }

    var message: String {
        switch self {
        case .undetermined:
            return "Enable microphone access before recording in Messages."
        case .granted:
            return "Microphone enabled"
        case .denied:
            return "Enable microphone access in Settings to record."
        }
    }
}

private struct MicrophonePermissionRow: View {
    let status: MicPermissionStatus
    let enableAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: status.symbol)
                    .font(.title3)
                    .foregroundStyle(status.tint)
                    .frame(width: 28)

                Text(status.message)
                    .font(.subheadline)
                    .foregroundStyle(status == .granted ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if status == .undetermined {
                Button("Enable Microphone", action: enableAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
