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
        let locales = Components.Schemas.BackendsResponse.localesPayload(
            additionalProperties: registry.locales
        )
        return .ok(.init(body: .json(.init(
            backends: registry.ids,
            _default: registry.defaultID,
            locales: locales
        ))))
    }

    // MARK: - POST /transcriptions

    func createTranscription(_ input: Operations.createTranscription.Input) async throws -> Operations.createTranscription.Output {
        guard let body = input.body else {
            return .badRequest(.init(body: .json(.init(error: "Request body is required"))))
        }

        // Phase 1: parse request without doing any I/O so we can log the full
        // request shape up front, before downloading or streaming audio.
        let backendID: String?
        var options: TranscriptionOptions
        let name: String?
        let source: String

        switch body {
        case let .json(req):
            guard URL(string: req.url) != nil else {
                return .badRequest(.init(body: .json(.init(error: "Invalid URL: \(req.url)"))))
            }
            backendID = req.backend
            name = req.name
            options = optionsFrom(req: req)
            source = "url=\(req.url)"
        case .audio_mpeg:
            (name, backendID, options) = parseUploadOptions(input)
            source = "upload=audio/mpeg"
        case .audio_wav:
            (name, backendID, options) = parseUploadOptions(input)
            source = "upload=audio/wav"
        case .audio_mp4:
            (name, backendID, options) = parseUploadOptions(input)
            source = "upload=audio/mp4"
        case .video_mp4:
            (name, backendID, options) = parseUploadOptions(input)
            source = "upload=video/mp4"
        case .audio_ogg:
            (name, backendID, options) = parseUploadOptions(input)
            source = "upload=audio/ogg"
        case .audio_flac:
            (name, backendID, options) = parseUploadOptions(input)
            source = "upload=audio/flac"
        }

        logger.info("request received", metadata: [
            "source": "\(source)",
            "backend": "\(backendID ?? registry.defaultID)",
            "name": "\(name ?? "-")",
            "format": "\(options.format)",
            "locale": "\(options.locale ?? "-")",
            "censor": "\(options.censor)",
            "max_length": "\(options.maxLength)",
            "word_timestamps": "\(options.wordTimestamps)",
            "detect_music": "\(options.detectMusic)",
            "music_sensitivity": "\(options.musicSensitivity ?? "-")",
        ])

        guard let backend = registry.backend(for: backendID) else {
            return .badRequest(.init(body: .json(.init(error: "Backend not available: \(backendID ?? registry.defaultID). Available: \(registry.ids.joined(separator: ", "))"))))
        }

        // Phase 2: materialize the audio (download or stream-to-disk).
        let tmpFile: URL
        do {
            switch body {
            case let .json(req):
                let sourceURL = URL(string: req.url)!
                logger.info("downloading audio", metadata: ["url": "\(sourceURL)"])
                tmpFile = try await download(sourceURL)
                logger.info("download complete", metadata: ["url": "\(sourceURL)"])
            case let .audio_mpeg(httpBody):
                tmpFile = try await streamToDisk(httpBody, ext: "mp3")
            case let .audio_wav(httpBody):
                tmpFile = try await streamToDisk(httpBody, ext: "wav")
            case let .audio_mp4(httpBody):
                tmpFile = try await streamToDisk(httpBody, ext: "mp4")
            case let .video_mp4(httpBody):
                tmpFile = try await streamToDisk(httpBody, ext: "mp4")
            case let .audio_ogg(httpBody):
                tmpFile = try await streamToDisk(httpBody, ext: "ogg")
            case let .audio_flac(httpBody):
                tmpFile = try await streamToDisk(httpBody, ext: "flac")
            }
        } catch {
            return .badRequest(.init(body: .json(.init(error: "Failed to read audio: \(error.localizedDescription)"))))
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
            logger.info("processing started", metadata: ["job": "\(jobID)", "backend": "\(backend.id)"])
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

    // MARK: - GET /transcriptions/{id}/events (SSE)

    func streamTranscriptionEvents(_ input: Operations.streamTranscriptionEvents.Input) async throws -> Operations.streamTranscriptionEvents.Output {
        let id = input.path.id
        guard await store.get(id) != nil else {
            return .notFound(.init(body: .json(.init(error: "Job not found"))))
        }
        let eventStream = await SSEHandler.eventStream(store: store, id: id)
        let byteSequence = AsyncStream<ArraySlice<UInt8>> { continuation in
            let task = Task {
                for await buffer in eventStream {
                    continuation.yield(ArraySlice(buffer.readableBytesView))
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
        return .ok(.init(body: .text_event_hyphen_stream(HTTPBody(byteSequence, length: .unknown))))
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
        if let s = req.music_sensitivity?.rawValue { o.musicSensitivity = s }
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
        if let s = query.music_sensitivity?.rawValue { o.musicSensitivity = s }
        return o
    }

    private func parseUploadOptions(
        _ input: Operations.createTranscription.Input
    ) -> (name: String?, backendID: String?, options: TranscriptionOptions) {
        let q = input.query
        return (q.name, q.backend, optionsFrom(query: q))
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
