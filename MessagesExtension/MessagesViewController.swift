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

        // Unconditional boot marker (default level) — confirms THIS build is the one running.
        log.notice("BOOT: MessagesViewController viewDidLoad")

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
        logGeometry("willBecomeActive")
        // Intentionally do NOT auto-expand: the extension opens at the default
        // compact height (short tray above the keyboard). The user can expand
        // manually via the grab handle if they want more room.
    }

    override func didBecomeActive(with conversation: MSConversation) {
        super.didBecomeActive(with: conversation)
        logGeometry("didBecomeActive")
        viewModel.handleDidBecomeActive()
    }

    override func didResignActive(with conversation: MSConversation) {
        super.didResignActive(with: conversation)
        viewModel.handleResignActivePreservingConversion()
    }

    override func willTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.willTransition(to: presentationStyle)
        logGeometry("willTransition:\(presentationStyle == .expanded ? "expanded" : presentationStyle == .compact ? "compact" : "transcript")")
        if presentationStyle == .compact {
            viewModel.handlePresentationCollapse()
        }
    }

    override func didTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.didTransition(to: presentationStyle)
        logGeometry("didTransition:\(presentationStyle == .expanded ? "expanded" : presentationStyle == .compact ? "compact" : "transcript")")
        // The hosting view can freeze the transient full-height layout it first saw;
        // force it to re-read the settled compact bounds.
        forceHostRelayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        logGeometry("viewDidLayoutSubviews")
    }

    private func forceHostRelayout() {
        guard let host = hostingController?.view else { return }
        host.setNeedsLayout()
        host.layoutIfNeeded()
    }

    private func logGeometry(_ label: String) {
        let styleString = presentationStyle == .expanded ? "expanded" : presentationStyle == .compact ? "compact" : "transcript"
        let bounds = String(describing: view.bounds)
        let safeAreaInsets = String(describing: view.safeAreaInsets)
        let hostFrame = String(describing: hostingController?.view.frame)
        // .notice = default level: always streamed/persisted, no "Include Info Messages" needed.
        log.notice("GEO[\(label, privacy: .public)] style=\(styleString, privacy: .public) bounds=\(bounds, privacy: .public) safeArea=\(safeAreaInsets, privacy: .public) hostFrame=\(hostFrame, privacy: .public)")
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
