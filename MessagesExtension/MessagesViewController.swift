import UIKit
import SwiftUI
import Messages
import os

final class MessagesViewController: MSMessagesAppViewController {

    private let log = Logger(subsystem: "com.aaron.voiceMixer", category: "flow")
    private let viewModel = VoiceTransformViewModel(
        service: Config.useMock ? MockConvertService() : LiveConvertService()
    )
    private var hostingController: UIHostingController<VoiceTransformView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

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
        requestExpandedPresentation(reason: "willBecomeActive")
    }

    override func didResignActive(with conversation: MSConversation) {
        super.didResignActive(with: conversation)
        viewModel.cancel()
    }

    override func willTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.willTransition(to: presentationStyle)
        if presentationStyle == .compact {
            viewModel.goBack()
        }
    }

    private func requestExpandedPresentation(reason: String) {
        guard presentationStyle != .expanded else { return }
        log.info("REC: requestPresentationStyle(.expanded) reason=\(reason)")
        requestPresentationStyle(.expanded)
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
