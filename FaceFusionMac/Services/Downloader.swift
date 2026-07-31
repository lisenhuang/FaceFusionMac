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

import Foundation

actor Downloader {

    /// Resume payloads from cancelled downloads, keyed by the model id.
    private var resumeData: [String: Data] = [:]
    private var activeTasks: [String: URLSessionDownloadTask] = [:]

    func hasResumeData(for key: String) -> Bool { resumeData[key] != nil }

    func discardResumeData(for key: String) { resumeData[key] = nil }

    /// Downloads `url` to a caller-owned location.
    /// - Parameter onProgress: called with (bytesWritten, totalBytes); total is
    ///   -1 when the server does not advertise a length.
    func download(key: String,
                  from url: URL,
                  to destination: URL,
                  onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let delegate = DownloadDelegate(onProgress: onProgress)
        let session = URLSession(configuration: .default,
                                 delegate: delegate,
                                 delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let temporaryURL: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation

                let task: URLSessionDownloadTask
                if let data = resumeData[key] {
                    task = session.downloadTask(withResumeData: data)
                } else {
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 60
                    task = session.downloadTask(with: request)
                }
                Task { await self.register(task, for: key) }
                task.resume()
            }
        } onCancel: {
            Task { await self.cancelActive(key: key) }
        }

        // The delegate has already relocated the file out of URLSession's
        // scratch space, so this move is ours to make.
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporaryURL, to: destination)
        resumeData[key] = nil
        activeTasks[key] = nil
    }

    private func register(_ task: URLSessionDownloadTask, for key: String) {
        activeTasks[key] = task
    }

    private func cancelActive(key: String) {
        guard let task = activeTasks[key] else { return }
        task.cancel { data in
            Task { await self.store(resumeData: data, for: key) }
        }
        activeTasks[key] = nil
    }

    private func store(resumeData data: Data?, for key: String) {
        resumeData[key] = data
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
