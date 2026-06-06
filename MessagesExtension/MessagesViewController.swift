import UIKit
import Messages
import AVFoundation

class MessagesViewController: MSMessagesAppViewController {

    // MARK: - Config

    /// Hardcoded for the steel thread; a voice picker is post-thread.
    private let voiceId = "stock"

    private let service: ConvertService = Config.useMock ? MockConvertService() : LiveConvertService()
    private let recorder = AudioRecorder()

    /// The local mp4 (audio muxed under a cover) ready to be inserted into the
    /// compose field — renders as an inline media bubble in the transcript.
    private var readyClipURL: URL?

    // MARK: - UI

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.text = "Tap Record to start"
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let recordButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = "Record"
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let sendButton: UIButton = {
        var config = UIButton.Configuration.borderedProminent()
        config.title = "Send"
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
        return button
    }()

    private let spinner: UIActivityIndicatorView = {
        let view = UIActivityIndicatorView(style: .medium)
        view.hidesWhenStopped = true
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        let stack = UIStackView(arrangedSubviews: [statusLabel, recordButton, spinner, sendButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])

        recordButton.addTarget(self, action: #selector(recordTapped), for: .touchUpInside)
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
    }

    // MARK: - Actions

    @objc private func recordTapped() {
        if recorder.isRecording {
            stopAndConvert()
        } else {
            beginRecording()
        }
    }

    private func beginRecording() {
        // iMessage apps launch compact; recording UX needs room.
        requestPresentationStyle(.expanded)

        readyClipURL = nil
        sendButton.isHidden = true

        do {
            try recorder.startRecording()
            recordButton.configuration?.title = "Stop"
            statusLabel.text = "Recording…"
        } catch {
            statusLabel.text = "Couldn't start recording"
        }
    }

    private func stopAndConvert() {
        guard let recordedURL = recorder.stopRecording() else {
            statusLabel.text = "Recording failed"
            recordButton.configuration?.title = "Record"
            return
        }

        recordButton.configuration?.title = "Record"
        setLoading(true, message: "Converting…")

        Task {
            do {
                let clipURL = try await prepareClip(from: recordedURL)
                await MainActor.run {
                    self.readyClipURL = clipURL
                    self.setLoading(false, message: "Ready — tap Send")
                    self.sendButton.isHidden = false
                }
            } catch {
                await MainActor.run {
                    self.setLoading(false, message: "Convert failed")
                }
            }
        }
    }

    /// Convert the recording, download the result, and wrap it in an mp4 so
    /// Messages renders an inline media bubble that plays in the transcript.
    private func prepareClip(from recordedURL: URL) async throws -> URL {
        let response = try await service.convert(audioURL: recordedURL, voiceId: voiceId)
        guard let audioUrl = URL(string: response.audioUrl) else {
            throw ConvertServiceError.invalidAudioURL
        }
        let convertedAudioURL = try await service.fetchAudio(audioUrl)
        return try await WaveformVideoRenderer().makeVideo(fromAudio: convertedAudioURL)
    }

    @objc private func sendTapped() {
        guard let clipURL = readyClipURL, let conversation = activeConversation else {
            statusLabel.text = "Nothing to send"
            return
        }

        sendButton.isEnabled = false
        statusLabel.text = "Inserting…"

        // `insertAttachment` is async — handle completion and update UI on main.
        conversation.insertAttachment(clipURL, withAlternateFilename: "voiceMix.mp4") { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.sendButton.isEnabled = true
                if let error {
                    self.statusLabel.text = "Insert failed: \(error.localizedDescription)"
                } else {
                    self.statusLabel.text = "Added to message — tap Send in Messages"
                    self.sendButton.isHidden = true
                    self.readyClipURL = nil
                }
            }
        }
    }

    // MARK: - Helpers

    private func setLoading(_ loading: Bool, message: String) {
        statusLabel.text = message
        recordButton.isEnabled = !loading
        if loading {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
    }
}
