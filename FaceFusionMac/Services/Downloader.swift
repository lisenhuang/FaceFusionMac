//
//  Downloader.swift
//  FaceFusionMac
//
//  A small async wrapper around URLSessionDownloadTask.
//
//  URLSession writes the body straight to a temp file on its own threads,
//  which is what makes a few-hundred-megabyte download cheap. Cancelling
//  produces resume data so an interrupted download picks up where it stopped
//  rather than starting over.
//
//  A model names more than one source, and this is where that is spent: each is
//  tried in turn until one of them hands over a complete file. Nothing about
//  what gets installed changes — the caller still hashes what arrives and still
//  throws it away if the digest does not match, whichever host answered.
//

import Foundation
import os

actor Downloader {

    /// A cancelled transfer's resume payload and the source it was taken from.
    ///
    /// The source is half of the rule `ModelDescriptor.downloadKey` describes.
    /// A payload is a promise about bytes already held, and it is only a true
    /// promise about the host those bytes came from; handing it to an attempt
    /// aimed at a different source is the splice the digest-named staging file
    /// exists to make impossible, so it is never done. A payload is reused for
    /// its own source and for nothing else.
    private struct ResumePoint {
        var data: Data
        var source: URL
    }

    /// A transfer in flight, and which source it is running against — needed so
    /// that the payload a cancellation produces can be filed under the right
    /// one.
    private struct ActiveTransfer {
        var task: URLSessionDownloadTask
        var source: URL
    }

    /// Resume payloads from cancelled downloads, keyed by the caller's key.
    private var resumeData: [String: ResumePoint] = [:]
    private var activeTasks: [String: ActiveTransfer] = [:]

    func hasResumeData(for key: String) -> Bool { resumeData[key] != nil }

    func discardResumeData(for key: String) { resumeData[key] = nil }

    /// Every key this downloader still has work for.
    ///
    /// That is more than the transfers someone is currently awaiting: a resume
    /// payload waiting to be picked up is a download in progress from the
    /// library's point of view. `ModelManager` asks before its sweep deletes
    /// anything, because a staging file belonging to one of these is not litter.
    func activeKeys() -> Set<String> {
        Set(activeTasks.keys).union(resumeData.keys)
    }

    /// Downloads a file to a caller-owned location, trying each source in turn.
    /// - Parameter key: identifies the transfer, and is what a resume payload
    ///   is filed under. It carries the manifest digest, so a payload from an
    ///   older generation can never be `Range`-resumed against a new URL.
    /// - Parameter sources: where the identical file can be fetched from, most
    ///   preferred first. The second and later ones are what keeps a fresh
    ///   install working after a host we do not own takes the first away.
    /// - Parameter onProgress: called with (bytesWritten, totalBytes); total is
    ///   -1 when the server does not advertise a length. A fallback restarts the
    ///   count, because the new source is genuinely starting from nothing.
    func download(key: String,
                  from sources: [URL],
                  to destination: URL,
                  onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        for source in attemptOrder(for: key, among: sources) {
            // Between attempts is the one place cancellation would otherwise
            // slip through: each attempt installs its own handler, and the gap
            // belongs to neither.
            try Task.checkCancellation()
            // Where this source sits in the manifest, so the log names which one
            // answered without naming the host it is.
            let position = (sources.firstIndex(of: source) ?? 0) + 1
            do {
                let temporaryURL = try await fetch(key: key, from: source, onProgress: onProgress)

                // The delegate has already relocated the file out of
                // URLSession's scratch space, so this move is ours to make.
                let fileManager = FileManager.default
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: temporaryURL, to: destination)
                resumeData[key] = nil
                activeTasks[key] = nil
                EngineLog.models.notice(
                    "fetched \(key, privacy: .public) from source \(position) of \(sources.count)")
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                activeTasks[key] = nil
                guard Self.deservesAnotherSource(error) else { throw error }
                // The line that says a primary has gone away. Worth a `notice`
                // even when the next source succeeds and the user sees nothing:
                // silent survival is exactly the state nobody would otherwise
                // discover.
                EngineLog.models.notice(
                    """
                    source \(position) of \(sources.count) failed for \
                    \(key, privacy: .public): \(Self.reason(for: error), privacy: .public)
                    """)
            }
        }
        throw ModelError.noSourceReachable
    }

    /// The sources to try, in the order to try them.
    ///
    /// The manifest's order is a preference; a resume payload is bytes already
    /// paid for, and only the source it came from can take them. So a source
    /// this key holds a payload for goes first, which is what keeps "cancel and
    /// come back" meaning the same thing it did when there was one URL — the
    /// alternative is starting at the manifest's first source and throwing away
    /// however much of the file the user had already fetched from the second.
    private func attemptOrder(for key: String, among sources: [URL]) -> [URL] {
        guard let held = resumeData[key]?.source,
              let position = sources.firstIndex(of: held), position > 0 else {
            return sources
        }
        var ordered = sources
        ordered.remove(at: position)
        ordered.insert(held, at: 0)
        return ordered
    }

    /// One attempt, against one source.
    private func fetch(key: String,
                       from source: URL,
                       onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        let delegate = DownloadDelegate(onProgress: onProgress)
        let session = URLSession(configuration: .default,
                                 delegate: delegate,
                                 delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation

                let task: URLSessionDownloadTask
                // Matched on the source, not just the key: see `ResumePoint`.
                // A payload from a source we have since fallen off is left
                // untouched rather than applied here — the new source starts
                // clean and pays for the bytes again, which is the cheap half of
                // the two ways this could go wrong.
                if let point = resumeData[key], point.source == source {
                    task = session.downloadTask(withResumeData: point.data)
                } else {
                    var request = URLRequest(url: source)
                    request.timeoutInterval = 60
                    task = session.downloadTask(with: request)
                }
                Task { await self.register(task, from: source, for: key) }
                task.resume()
            }
        } onCancel: {
            Task { await self.cancelActive(key: key) }
        }
    }

    /// Whether a failed attempt is one the next source might not repeat.
    ///
    /// Everything that means "this host did not hand over the file" qualifies:
    /// refused connections, DNS, timeouts, TLS, and any HTTP status outside
    /// 2xx — a 404 or a 403 is precisely the release-deleted-or-made-private
    /// case a second source exists for. Anything else is a local problem that no
    /// other host can fix, and moving on would only bury it.
    ///
    /// A digest mismatch never reaches this decision at all, by construction:
    /// verification happens in `ModelManager`, after a *complete* download has
    /// been handed back. That is on purpose — wrong bytes mean something is
    /// wrong, and quietly asking somewhere else would turn the one check that
    /// can catch a substituted file into a loop that hides it.
    private static func deservesAnotherSource(_ error: Error) -> Bool {
        if let modelError = error as? ModelError, case .transport = modelError { return true }
        guard let urlError = error as? URLError else { return false }
        return urlError.code != .cancelled
    }

    /// Why an attempt failed, in terms that name no host.
    ///
    /// `URLError` is reduced to its code rather than its message deliberately:
    /// the system writes some of those messages by quoting the server it was
    /// talking to, and where the weights come from is not something this app
    /// says out loud — in a log line or anywhere else.
    private static func reason(for error: Error) -> String {
        if let modelError = error as? ModelError, case .transport(let message) = modelError {
            return message
        }
        if let urlError = error as? URLError {
            return "URL error \(urlError.errorCode)"
        }
        return String(describing: type(of: error))
    }

    private func register(_ task: URLSessionDownloadTask, from source: URL, for key: String) {
        activeTasks[key] = ActiveTransfer(task: task, source: source)
    }

    private func cancelActive(key: String) {
        guard let transfer = activeTasks[key] else { return }
        let source = transfer.source
        transfer.task.cancel { data in
            Task { await self.store(resumeData: data, from: source, for: key) }
        }
        activeTasks[key] = nil
    }

    private func store(resumeData data: Data?, from source: URL, for key: String) {
        resumeData[key] = data.map { ResumePoint(data: $0, source: source) }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    var continuation: CheckedContinuation<URL, Error>?
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private var hasResumed = false
    private let lock = NSLock()

    init(onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    /// Guards against resuming the continuation twice, which would trap.
    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard !hasResumed else { lock.unlock(); return }
        hasResumed = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // This callback owns `location` only until it returns, so the file has
        // to be moved synchronously, right here.
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            finish(.failure(ModelError.transport("Server returned HTTP \(response.statusCode).")))
            return
        }
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: staged)
            finish(.success(staged))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error else { return }   // success already reported above
        if (error as NSError).code == NSURLErrorCancelled {
            finish(.failure(CancellationError()))
        } else {
            finish(.failure(error))
        }
    }
}
