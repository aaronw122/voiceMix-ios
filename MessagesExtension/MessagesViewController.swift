import UIKit
import SwiftUI
import Messages
import os
import VoiceMixCore

final class MessagesViewController: MSMessagesAppViewController {

    private let log = Logger(subsystem: "com.aaron.voiceMixer", category: "flow")
    private let viewModel = VoiceTransformViewModel(
        service: Config.useMock ? MockConvertService() : LiveConvertService()
    )
    private var hostingController: UIHostingController<VoiceTransformView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        #if DEBUG
        // Assert the live switch actually took: a green mock can hide the fact
        // that we never flipped to the real backend.
        log.info("CONFIG: useMock=\(Config.useMock) baseURL=\(Config.baseURL.absoluteString)")
        // Non-blocking catalog drift check against GET /voices.
        VoiceCatalogPreflight.run()
        #endif

        viewModel.onDismiss = { [weak self] in
            self?.requestPresentationStyle(.compact)
        }
        viewModel.onInsert = { [weak self] url, completion in
            guard let self, let conversation = self.activeConversation else {
                completion(MessagesExtensionError.noActiveConversation)
                return
            }

            conversation.insertAttachment(url, withAlternateFilename: "voiceMix.mp4") { error in
                completion(error)
            }
        }

        let root = VoiceTransformView(model: viewModel)
        let hosting = UIHostingController(rootView: root)
        // Compact iMessage trays sit ABOVE the keyboard, but UIHostingController bridges
        // ALL safe-area regions to SwiftUI by default — including a phantom .keyboard
        // region. That shrinks the height it offers SwiftUI, so the fixed-height content
        // falls back to its 286pt minimum (nav bar clipped off the top, black below)
        // instead of filling the 301pt tray. Bridge only the container's safe area.
        if #available(iOS 16.4, *) {
            hosting.safeAreaRegions = .container
        }
        hosting.view.backgroundColor = .clear
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hosting.didMove(toParent: self)
        hostingController = hosting
    }

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        // Intentionally do NOT auto-expand: the extension opens at the default
        // compact height (short tray above the keyboard). The user can expand
        // manually via the grab handle if they want more room.
    }

    override func didBecomeActive(with conversation: MSConversation) {
        super.didBecomeActive(with: conversation)
        viewModel.handleDidBecomeActive()
    }

    override func didResignActive(with conversation: MSConversation) {
        super.didResignActive(with: conversation)
        viewModel.handleResignActivePreservingConversion()
    }

    override func willTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.willTransition(to: presentationStyle)
        if presentationStyle == .compact {
            viewModel.handlePresentationCollapse()
        }
    }
}

private enum MessagesExtensionError: LocalizedError {
    case noActiveConversation

    var errorDescription: String? {
        switch self {
        case .noActiveConversation:
            return "No active Messages conversation"
        }
    }
}
