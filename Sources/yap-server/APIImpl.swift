import Foundation
import HTTPTypes
import OpenAPIRuntime
import Logging
import Semaphore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct APIImpl: APIProtocol {
    let store: JobStore
    let semaphore: AsyncSemaphore
    let registry: BackendRegistry
    let logger: Logger

    // MARK: - GET /health

    func getHealth(_ input: Operations.getHealth.Input) async throws -> Operations.getHealth.Output {
        .ok(.init(body: .json(.init(status: "ok"))))
    }

    // MARK: - GET /backends

    func getBackends(_ input: Operations.getBackends.Input) async throws -> Operations.getBackends.Output {
        .ok(.init(body: .json(.init(backends: registry.ids, _default: registry.defaultID))))
    }

    // MARK: - POST /transcriptions

    func createTranscription(_ input: Operations.createTranscription.Input) async throws -> Operations.createTranscription.Output {
        guard let body = input.body else {
            return .badRequest(.init(body: .json(.init(error: "Request body is required"))))
        }

        let backendID: String?
        var options: TranscriptionOptions
        let name: String?
        let tmpFile: URL

        switch body {
        case let .json(req):
            guard let sourceURL = URL(string: req.url) else {
                return .badRequest(.init(body: .json(.init(error: "Invalid URL: \(req.url)"))))
            }
            backendID = req.backend
            name = req.name
            options = optionsFrom(req: req)
            do {
                tmpFile = try await download(sourceURL)
            } catch {
                return .badRequest(.init(body: .json(.init(error: "Failed to download audio: \(error.localizedDescription)"))))
            }

        case let .audio_mpeg(httpBody):
            (name, backendID, options, tmpFile) = try await uploadParams(input, body: httpBody, ext: "mp3")
        case let .audio_wav(httpBody):
            (name, backendID, options, tmpFile) = try await uploadParams(input, body: httpBody, ext: "wav")
        case let .audio_mp4(httpBody):
            (name, backendID, options, tmpFile) = try await uploadParams(input, body: httpBody, ext: "mp4")
        case let .video_mp4(httpBody):
            (name, backendID, options, tmpFile) = try await uploadParams(input, body: httpBody, ext: "mp4")
        case let .audio_ogg(httpBody):
            (name, backendID, options, tmpFile) = try await uploadParams(input, body: httpBody, ext: "ogg")
        case let .audio_flac(httpBody):
            (name, backendID, options, tmpFile) = try await uploadParams(input, body: httpBody, ext: "flac")
        }

        guard let backend = registry.backend(for: backendID) else {
            try? FileManager.default.removeItem(at: tmpFile)
            return .badRequest(.init(body: .json(.init(error: "Backend not available: \(backendID ?? registry.defaultID). Available: \(registry.ids.joined(separator: ", "))"))))
        }

        let jobID = UUID().uuidString
        await store.create(jobID, name: name, backend: backend.id)
        logger.info("job accepted", metadata: ["job": "\(jobID)", "backend": "\(backend.id)"])
        options.onProgress = { @Sendable pct in Task { await store.updateProgress(jobID, progress: pct) } }

        let task = Task.detached { [store, semaphore, logger] in
            defer { try? FileManager.default.removeItem(at: tmpFile) }
            do {
                try await semaphore.waitUnlessCancelled()
            } catch {
                await store.update(jobID, status: .cancelled)
                return
            }
            defer { semaphore.signal() }

            await store.update(jobID, status: .running)
            do {
                let transcript = try await backend.transcribe(file: tmpFile, options: options)
                try Task.checkCancellation()
                await store.update(jobID, status: .done(transcript: transcript, format: options.format))
                logger.info("job done", metadata: ["job": "\(jobID)"])
            } catch is CancellationError {
                await store.update(jobID, status: .cancelled)
            } catch {
                await store.update(jobID, status: .failed(error.localizedDescription))
                logger.error("job failed", metadata: ["job": "\(jobID)", "error": "\(error.localizedDescription)"])
            }
            await store.removeTask(jobID)
        }
        await store.register(jobID, task: task)

        return .accepted(.init(body: .json(.init(id: jobID, name: name, status: "queued", backend: backend.id))))
    }

    // MARK: - GET /transcriptions/{id}

    func getTranscription(_ input: Operations.getTranscription.Input) async throws -> Operations.getTranscription.Output {
        let id = input.path.id
        guard let job = await store.get(id) else {
            return .notFound(.init(body: .json(.init(error: "Job not found"))))
        }
        return .ok(.init(body: .json(jobState(id: id, job: job))))
    }

    // MARK: - DELETE /transcriptions/{id}

    func cancelTranscription(_ input: Operations.cancelTranscription.Input) async throws -> Operations.cancelTranscription.Output {
        let id = input.path.id
        switch await store.cancel(id) {
        case .cancelled:
            return .noContent
        case .notFound:
            return .notFound(.init(body: .json(.init(error: "Job not found"))))
        case .alreadyTerminal:
            return .conflict(.init(body: .json(.init(error: "Job is already complete and cannot be cancelled"))))
        }
    }

    // MARK: - Helpers

    private func optionsFrom(req: Components.Schemas.TranscriptionRequest) -> TranscriptionOptions {
        var o = TranscriptionOptions()
        if let f = req.format?.rawValue { o.format = f }
        o.locale = req.locale
        if let c = req.censor { o.censor = c }
        if let m = req.max_length { o.maxLength = m }
        if let w = req.word_timestamps { o.wordTimestamps = w }
        if let d = req.detect_music { o.detectMusic = d }
        return o
    }

    private func optionsFrom(query: Operations.createTranscription.Input.Query) -> TranscriptionOptions {
        var o = TranscriptionOptions()
        if let f = query.format?.rawValue { o.format = f }
        o.locale = query.locale
        if let c = query.censor { o.censor = c }
        if let m = query.max_length { o.maxLength = m }
        if let w = query.word_timestamps { o.wordTimestamps = w }
        if let d = query.detect_music { o.detectMusic = d }
        return o
    }

    private func uploadParams(
        _ input: Operations.createTranscription.Input,
        body: HTTPBody,
        ext: String
    ) async throws -> (name: String?, backendID: String?, options: TranscriptionOptions, file: URL) {
        let q = input.query
        let options = optionsFrom(query: q)
        let file = try await streamToDisk(body, ext: ext)
        return (q.name, q.backend, options, file)
    }

    private func jobState(id: String, job: JobStore.Job) -> Components.Schemas.JobState {
        switch job.status {
        case .queued:
            return .init(id: id, name: job.name, status: "queued", backend: job.backend)
        case .running:
            return .init(id: id, name: job.name, status: "running", backend: job.backend, progress: job.progress)
        case let .done(transcript, format):
            return .init(id: id, name: job.name, status: "done", backend: job.backend, format: format, transcript: transcript)
        case let .failed(message):
            return .init(id: id, name: job.name, status: "failed", backend: job.backend, error: message)
        case .cancelled:
            return .init(id: id, name: job.name, status: "cancelled", backend: job.backend)
        }
    }
}

// MARK: - I/O

private func download(_ sourceURL: URL) async throws -> URL {
    let (downloaded, _) = try await URLSession.shared.download(from: sourceURL)
    let ext = sourceURL.pathExtension.isEmpty ? "mp3" : sourceURL.pathExtension
    let dest = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    try FileManager.default.moveItem(at: downloaded, to: dest)
    return dest
}

private func streamToDisk(_ body: HTTPBody, ext: String) async throws -> URL {
    let dest = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    FileManager.default.createFile(atPath: dest.path, contents: nil)
    let handle = try FileHandle(forWritingTo: dest)
    do {
        for try await chunk in body {
            try handle.write(contentsOf: chunk)
        }
        try handle.close()
    } catch {
        try? handle.close()
        try? FileManager.default.removeItem(at: dest)
        throw error
    }
    return dest
}
