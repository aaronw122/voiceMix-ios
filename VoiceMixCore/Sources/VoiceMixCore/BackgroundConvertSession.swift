import Foundation
import os

/// UNVERIFIED (queued-UX item 5). Carries the in-flight convert on a background
/// `URLSession` so iOS can continue the upload/inference/download while the
/// extension is suspended and deliver completion via the session delegate on
/// resume.
///
/// ⚠️ Needs a real-device spike inside an `MSMessagesAppViewController` — the
/// async continuation bridged here does NOT survive a full suspend+relaunch
/// (that would route completion to the host app, which is out of scope). It is
/// gated behind `Config.useBackgroundConvertSession` (default OFF); when off the
/// service uses a default session and a suspend is recovered by the item-4
/// queued resubmit instead.
final class BackgroundConvertSession: NSObject {
    static let shared = BackgroundConvertSession()

    private let log = Logger(subsystem: "com.aaron.voiceMixer", category: "network")

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.aaron.voiceMixer.convert")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.timeoutIntervalForRequest = 240
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private struct Pending {
        var data = Data()
        var response: URLResponse?
        let continuation: CheckedContinuation<(Data, URLResponse), Error>
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]

    /// Upload `body` for `request` on the background session. The body is staged
    /// to a temp file because background tasks require a file, not in-memory data.
    func upload(_ request: URLRequest, from body: Data) async throws -> (Data, URLResponse) {
        let bodyFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceMix-upload-\(UUID().uuidString).tmp")
        try body.write(to: bodyFile, options: .atomic)

        return try await withCheckedThrowingContinuation { continuation in
            let task = session.uploadTask(with: request, fromFile: bodyFile)
            lock.lock()
            pending[task.taskIdentifier] = Pending(continuation: continuation)
            lock.unlock()
            task.resume()
        }
    }
}

extension BackgroundConvertSession: URLSessionDataDelegate {
    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        pending[dataTask.taskIdentifier]?.response = response
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        pending[dataTask.taskIdentifier]?.data.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let entry = pending.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let entry else { return }

        if let error {
            entry.continuation.resume(throwing: error)
        } else if let response = entry.response ?? task.response {
            entry.continuation.resume(returning: (entry.data, response))
        } else {
            entry.continuation.resume(throwing: URLError(.badServerResponse))
        }
    }
}
