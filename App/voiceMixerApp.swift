import SwiftUI

@main
struct VoiceMixerApp: App {
    var body: some Scene {
        WindowGroup {
            OnboardingView()
        }
    }
}

struct OnboardingView: View {
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

                Text("That's it — no setup needed here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 40)
            }
            .frame(maxWidth: .infinity)
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
