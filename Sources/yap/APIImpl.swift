import AVFoundation
import Foundation
import Hummingbird
import Logging
import OpenAPIRuntime
import Semaphore
import Speech

// MARK: - API Key Context

/// Passes the raw X-API-Key header value through Swift's task-local storage
/// so OpenAPI handlers can access it without touching raw Hummingbird requests.
enum APIKeyContext {
    @TaskLocal static var value: String? = nil
}

struct APIKeyMiddleware: RouterMiddleware {
    typealias Context = BasicRequestContext

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        let key = request.headers[.init("X-API-Key")!]
        return try await APIKeyContext.$value.withValue(key) {
            try await next(request, context)
        }
    }
}

// MARK: - YapAPI

struct YapAPI: APIProtocol {
    let store: JobStore
    let semaphore: AsyncSemaphore
    let apiKey: String?
    let log: Logger

    // MARK: GET /health

    func getHealth(_ input: Operations.getHealth.Input) async throws -> Operations.getHealth.Output {
        .ok(.init(body: .json(.init(status: "ok"))))
    }

    // MARK: GET /locales

    func getLocales(_ input: Operations.getLocales.Input) async throws -> Operations.getLocales.Output {
        if let key = apiKey {
            guard APIKeyContext.value == key else {
                return .unauthorized(.init(body: .json(.init(error: "Invalid API key"))))
            }
        }

        let supported = await SpeechTranscriber.supportedLocales
        let installed = await SpeechTranscriber.installedLocales
        let installedIDs = Set(installed.map { $0.identifier(.bcp47) })

        let locales = supported
            .sorted { $0.identifier(.bcp47) < $1.identifier(.bcp47) }
            .map { locale -> Components.Schemas.Locale in
                let id = locale.identifier(.bcp47)
                let name = locale.localizedString(forIdentifier: id) ?? id
                return .init(id: id, name: name, installed: installedIDs.contains(id))
            }

        log.info("Locales requested", metadata: ["count": "\(supported.count)", "installed": "\(installedIDs.count)"])
        return .ok(.init(body: .json(.init(locales: locales))))
    }

    // MARK: POST /transcriptions

    func createTranscription(_ input: Operations.createTranscription.Input) async throws -> Operations.createTranscription.Output {
        if let key = apiKey {
            guard APIKeyContext.value == key else {
                return .unauthorized(.init(body: .json(.init(error: "Invalid API key"))))
            }
        }

        var options = TranscriptionEngine.Options()
        options.outputFormat = .srt
        var jobName: String?

        let tmpFile: URL

        switch input.body {

        case .json(let req):
            guard let sourceURL = URL(string: req.url) else {
                return .badRequest(.init(body: .json(.init(error: "Invalid URL: \(req.url)"))))
            }
            applyRequestOptions(req, into: &options)
            jobName = req.name
            if let localeError = await unsupportedLocaleError(options.locale) { return localeError }
            log.info("Incoming request", metadata: ["mode": "url", "url": "\(req.url)",
                "format": "\(options.outputFormat.rawValue)", "locale": "\(options.locale.identifier(.bcp47))"])
            log.info("Downloading audio", metadata: ["url": "\(sourceURL)"])
            do {
                let (downloadedURL, _) = try await URLSession.shared.download(from: sourceURL)
                let ext = sourceURL.pathExtension.isEmpty ? "mp3" : sourceURL.pathExtension
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
                try FileManager.default.moveItem(at: downloadedURL, to: dest)
                tmpFile = dest
                log.info("Download complete", metadata: ["file": "\(dest.lastPathComponent)"])
            } catch {
                log.error("Download failed", metadata: ["url": "\(sourceURL)", "error": "\(error.localizedDescription)"])
                return .badRequest(.init(body: .json(.init(error: "Failed to download audio: \(error.localizedDescription)"))))
            }

        case .audio_mpeg(let body):
            applyQueryOptions(input.query, into: &options)
            jobName = input.query.name
            if let localeError = await unsupportedLocaleError(options.locale) { return localeError }
            log.info("Incoming request", metadata: ["mode": "upload", "content-type": "audio/mpeg",
                "format": "\(options.outputFormat.rawValue)", "locale": "\(options.locale.identifier(.bcp47))"])
            tmpFile = try await streamToDisk(body: body, ext: "mp3", log: log)

        case .audio_wav(let body):
            applyQueryOptions(input.query, into: &options)
            jobName = input.query.name
            if let localeError = await unsupportedLocaleError(options.locale) { return localeError }
            log.info("Incoming request", metadata: ["mode": "upload", "content-type": "audio/wav",
                "format": "\(options.outputFormat.rawValue)", "locale": "\(options.locale.identifier(.bcp47))"])
            tmpFile = try await streamToDisk(body: body, ext: "wav", log: log)

        case .audio_mp4(let body):
            applyQueryOptions(input.query, into: &options)
            jobName = input.query.name
            if let localeError = await unsupportedLocaleError(options.locale) { return localeError }
            log.info("Incoming request", metadata: ["mode": "upload", "content-type": "audio/mp4",
                "format": "\(options.outputFormat.rawValue)", "locale": "\(options.locale.identifier(.bcp47))"])
            tmpFile = try await streamToDisk(body: body, ext: "mp4", log: log)

        case .video_mp4(let body):
            applyQueryOptions(input.query, into: &options)
            jobName = input.query.name
            if let localeError = await unsupportedLocaleError(options.locale) { return localeError }
            log.info("Incoming request", metadata: ["mode": "upload", "content-type": "video/mp4",
                "format": "\(options.outputFormat.rawValue)", "locale": "\(options.locale.identifier(.bcp47))"])
            tmpFile = try await streamToDisk(body: body, ext: "mp4", log: log)

        case .audio_ogg(let body):
            applyQueryOptions(input.query, into: &options)
            jobName = input.query.name
            if let localeError = await unsupportedLocaleError(options.locale) { return localeError }
            log.info("Incoming request", metadata: ["mode": "upload", "content-type": "audio/ogg",
                "format": "\(options.outputFormat.rawValue)", "locale": "\(options.locale.identifier(.bcp47))"])
            tmpFile = try await streamToDisk(body: body, ext: "ogg", log: log)

        case .audio_flac(let body):
            applyQueryOptions(input.query, into: &options)
            jobName = input.query.name
            if let localeError = await unsupportedLocaleError(options.locale) { return localeError }
            log.info("Incoming request", metadata: ["mode": "upload", "content-type": "audio/flac",
                "format": "\(options.outputFormat.rawValue)", "locale": "\(options.locale.identifier(.bcp47))"])
            tmpFile = try await streamToDisk(body: body, ext: "flac", log: log)
        }

        let jobID = UUID().uuidString
        await store.create(jobID, name: jobName)

        var acceptedMeta: Logger.Metadata = ["job": "\(jobID)"]
        if let jobName { acceptedMeta["name"] = "\(jobName)" }
        log.info("Job accepted", metadata: acceptedMeta)

        let backgroundTask = Task.detached {
            defer {
                try? FileManager.default.removeItem(at: tmpFile)
                log.debug("Temp file removed", metadata: ["job": "\(jobID)", "file": "\(tmpFile.lastPathComponent)"])
            }

            var _meta: Logger.Metadata = ["job": "\(jobID)"]
            if let jobName { _meta["name"] = "\(jobName)" }
            let meta = _meta

            // Wait for a semaphore slot — throws CancellationError if cancelled while queued.
            do {
                try await semaphore.waitUnlessCancelled()
            } catch {
                await store.update(jobID, status: .cancelled)
                log.info("Job cancelled while queued", metadata: meta)
                return
            }
            defer { semaphore.signal() }

            log.info("Transcription started", metadata: meta)
            await store.update(jobID, status: .running(progress: 0))

            do {
                let transcript = try await TranscriptionEngine.transcribe(
                    file: tmpFile,
                    options: options,
                    onProgress: { progress in
                        await store.update(jobID, status: .running(progress: progress))
                        var progressMeta = meta
                        progressMeta["progress"] = "\(Int(progress * 100))%"
                        log.debug("Transcription progress", metadata: progressMeta)
                    },
                    log: log
                )
                // Guard against cancellation arriving just after transcription finishes.
                try Task.checkCancellation()
                await store.update(jobID, status: .done(transcript: transcript, format: options.outputFormat.rawValue))
                var doneMeta = meta
                doneMeta["format"] = "\(options.outputFormat.rawValue)"
                log.info("Transcription complete", metadata: doneMeta)
            } catch is CancellationError {
                await store.update(jobID, status: .cancelled)
                log.info("Transcription cancelled", metadata: meta)
            } catch let TranscriptionError.partialResult(transcript, covered, total, underlying) {
                // Speech.framework died mid-stream — keep what we have.
                try? Task.checkCancellation()
                await store.update(jobID, status: .done(transcript: transcript, format: options.outputFormat.rawValue))
                var partialMeta = meta
                partialMeta["covered_s"] = "\(Int(covered))"
                partialMeta["total_s"] = "\(Int(total))"
                partialMeta["pct"] = "\(total > 0 ? Int(covered / total * 100) : 0)%"
                partialMeta["underlying"] = "\(underlying.localizedDescription)"
                log.warning("Transcription partial — Speech.framework gave up; returning what was processed", metadata: partialMeta)
            } catch {
                let nsError = error as NSError
                let detail = "\(error.localizedDescription) [\(nsError.domain) #\(nsError.code)]"
                await store.update(jobID, status: .failed(detail))
                var errMeta = meta
                errMeta["error"] = "\(error.localizedDescription)"
                errMeta["domain"] = "\(nsError.domain)"
                errMeta["code"] = "\(nsError.code)"
                errMeta["userInfo"] = "\(nsError.userInfo)"
                errMeta["full"] = "\(error)"
                log.error("Transcription failed", metadata: errMeta)
            }

            await store.removeTask(jobID)
        }
        await store.register(jobID, task: backgroundTask)

        return .accepted(.init(body: .json(.init(id: jobID, name: jobName, status: .queued))))
    }

    // MARK: GET /transcriptions/{id}

    func getTranscription(_ input: Operations.getTranscription.Input) async throws -> Operations.getTranscription.Output {
        if let key = apiKey {
            guard APIKeyContext.value == key else {
                return .unauthorized(.init(body: .json(.init(error: "Invalid API key"))))
            }
        }

        let id = input.path.id
        guard let status = await store.get(id) else {
            return .notFound(.init(body: .json(.init(error: "Job not found"))))
        }

        let name = await store.getName(id)

        switch status {
        case .queued:
            return .ok(.init(body: .json(.init(id: id, name: name, status: .queued))))
        case .running(let progress):
            return .ok(.init(body: .json(.init(id: id, name: name, status: .running, progress: Int(progress * 100)))))
        case .done(let transcript, let format):
            let fmt = Components.Schemas.JobStatus.formatPayload(rawValue: format) ?? .txt
            return .ok(.init(body: .json(.init(id: id, name: name, status: .done, format: fmt, transcript: transcript))))
        case .failed(let message):
            return .ok(.init(body: .json(.init(id: id, name: name, status: .failed, error: message))))
        case .cancelled:
            return .ok(.init(body: .json(.init(id: id, name: name, status: .cancelled))))
        }
    }

    // MARK: DELETE /transcriptions/{id}

    func cancelTranscription(_ input: Operations.cancelTranscription.Input) async throws -> Operations.cancelTranscription.Output {
        if let key = apiKey {
            guard APIKeyContext.value == key else {
                return .unauthorized(.init(body: .json(.init(error: "Invalid API key"))))
            }
        }

        let id = input.path.id
        switch await store.cancel(id) {
        case .cancelled:
            log.info("Job cancelled by request", metadata: ["job": "\(id)"])
            return .noContent(.init())
        case .notFound:
            return .notFound(.init(body: .json(.init(error: "Job not found"))))
        case .alreadyTerminal:
            return .conflict(.init(body: .json(.init(error: "Job is already complete and cannot be cancelled"))))
        }
    }
}

// MARK: - Helpers

private func streamToDisk(body: HTTPBody, ext: String, log: Logger) async throws -> URL {
    let dest = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    FileManager.default.createFile(atPath: dest.path, contents: nil)
    let fileHandle = try FileHandle(forWritingTo: dest)
    var totalBytes = 0
    do {
        for try await chunk in body {
            totalBytes += chunk.count
            try fileHandle.write(contentsOf: chunk)
        }
        try fileHandle.close()
    } catch {
        try? fileHandle.close()
        try? FileManager.default.removeItem(at: dest)
        throw error
    }
    log.debug("Request body streamed to disk", metadata: ["bytes": "\(totalBytes)"])
    return dest
}

private func applyRequestOptions(_ req: Components.Schemas.TranscriptionRequest, into options: inout TranscriptionEngine.Options) {
    if let locale = req.locale { options.locale = Locale(identifier: locale) }
    if let format = req.format { options.outputFormat = mapFormat(format.rawValue) }
    if let censor = req.censor { options.censor = censor }
    if let maxLength = req.max_length { options.maxLength = maxLength }
    if let wt = req.word_timestamps { options.wordTimestamps = wt }
}

private func applyQueryOptions(_ query: Operations.createTranscription.Input.Query, into options: inout TranscriptionEngine.Options) {
    if let locale = query.locale { options.locale = Locale(identifier: locale) }
    if let format = query.format { options.outputFormat = mapFormat(format.rawValue) }
    if let censor = query.censor { options.censor = censor }
    if let maxLength = query.max_length { options.maxLength = maxLength }
    if let wt = query.word_timestamps { options.wordTimestamps = wt }
}

private func unsupportedLocaleError(_ locale: Locale) async -> Operations.createTranscription.Output? {
    let bcp47 = locale.identifier(.bcp47)
    let supported = await SpeechTranscriber.supportedLocales
    guard supported.contains(where: { $0.identifier(.bcp47) == bcp47 }) else {
        return .badRequest(.init(body: .json(.init(error: "Locale \"\(locale.identifier)\" is not supported for speech transcription."))))
    }
    return nil
}

private func mapFormat(_ string: String) -> OutputFormat {
    switch string {
    case "srt": .srt
    case "vtt": .vtt
    case "json": .json
    default: .txt
    }
}
