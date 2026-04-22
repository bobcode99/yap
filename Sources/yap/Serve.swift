import ArgumentParser
import Foundation
import Hummingbird
import Logging
import Semaphore
import Speech

private let logger = Logger(label: "yap.serve")

// MARK: - JobStore

actor JobStore: Sendable {
    enum Status {
        case queued
        case running
        case done(transcript: String, format: String)
        case failed(String)
    }

    private var jobs: [String: Status] = [:]

    func create(_ id: String) {
        jobs[id] = .queued
    }

    func update(_ id: String, status: Status) {
        jobs[id] = status
    }

    func get(_ id: String) -> Status? {
        jobs[id]
    }
}

// MARK: - Serve

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start an HTTP server for speech transcription."
    )

    @Option(help: "Host to bind to.")
    var host: String = "127.0.0.1"

    @Option(help: "Port to listen on.")
    var port: Int = 8080

    @Option(name: .long, help: "If set, require X-API-Key header on all non-health requests.")
    var apiKey: String?

    @Option(name: .long, help: "Maximum number of concurrent transcription jobs (default: 2).")
    var maxConcurrent: Int = 2

    mutating func run() async throws {
        let store = JobStore()
        let key = apiKey
        let semaphore = AsyncSemaphore(value: maxConcurrent)

        let router = Router()

        router.get("/health") { _, _ -> Response in
            jsonResponse(status: .ok, body: #"{"status":"ok"}"#)
        }

        router.get("/locales") { _, _ -> Response in
            let supported = await SpeechTranscriber.supportedLocales
            let installed = await SpeechTranscriber.installedLocales
            let installedIDs = Set(installed.map { $0.identifier(.bcp47) })

            let items = supported
                .sorted { $0.identifier(.bcp47) < $1.identifier(.bcp47) }
                .map { locale -> String in
                    let id = locale.identifier(.bcp47)
                    let name = locale.localizedString(forIdentifier: id) ?? id
                    let isInstalled = installedIDs.contains(id)
                    return #"{"id":"\#(jsonEscape(id))","name":"\#(jsonEscape(name))","installed":\#(isInstalled)}"#
                }

            let body = #"{"locales":[\#(items.joined(separator: ","))]}"#
            logger.info("Locales requested", metadata: ["count": "\(supported.count)", "installed": "\(installedIDs.count)"])
            return jsonResponse(status: .ok, body: body)
        }

        router.post("/transcriptions") { request, _ -> Response in
            if let k = key {
                guard request.headers[.init("X-API-Key")!] == k else {
                    return jsonResponse(status: .unauthorized, body: #"{"error":"Invalid API key"}"#)
                }
            }

            let contentType = request.headers[.contentType] ?? ""
            let isJSON = contentType.hasPrefix("application/json")

            let tmpFile: URL
            var options = TranscriptionEngine.Options()
            options.outputFormat = .srt

            if isJSON {
                let buffer = try await request.body.collect(upTo: 10 * 1024 * 1024)
                let data = Data(buffer.readableBytesView)

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let urlString = json["url"] as? String,
                      let sourceURL = URL(string: urlString)
                else {
                    return jsonResponse(status: .badRequest, body: #"{"error":"Missing or invalid required field: url"}"#)
                }

                applyJSONOptions(json: json, into: &options)

                logger.info(
                    "Received transcription request",
                    metadata: [
                        "mode": "url",
                        "url": "\(urlString)",
                        "format": "\(options.outputFormat.rawValue)",
                        "locale": "\(options.locale.identifier(.bcp47))",
                    ]
                )

                let ext = sourceURL.pathExtension.isEmpty ? "mp3" : sourceURL.pathExtension
                do {
                    logger.info("Downloading audio", metadata: ["url": "\(sourceURL)"])
                    let (downloadedURL, _) = try await URLSession.shared.download(from: sourceURL)
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(ext)
                    try FileManager.default.moveItem(at: downloadedURL, to: dest)
                    tmpFile = dest
                    logger.info("Download complete", metadata: ["file": "\(dest.lastPathComponent)"])
                } catch {
                    logger.error("Download failed", metadata: ["url": "\(sourceURL)", "error": "\(error.localizedDescription)"])
                    return jsonResponse(status: .badRequest, body: #"{"error":"Failed to download audio: \#(jsonEscape(error.localizedDescription))"}"#)
                }
            } else {
                let ext = extensionForContentType(contentType)
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(ext)
                let buffer = try await request.body.collect(upTo: 100 * 1024 * 1024)
                try Data(buffer.readableBytesView).write(to: dest)
                tmpFile = dest

                applyQueryOptions(queryString: request.uri.query, into: &options)

                logger.info(
                    "Received transcription request",
                    metadata: [
                        "mode": "upload",
                        "content-type": "\(contentType)",
                        "format": "\(options.outputFormat.rawValue)",
                        "locale": "\(options.locale.identifier(.bcp47))",
                    ]
                )
            }

            let jobID = UUID().uuidString
            await store.create(jobID)
            logger.info("Job queued", metadata: ["job": "\(jobID)"])

            Task.detached {
                await semaphore.wait()
                defer { semaphore.signal() }
                logger.info("Transcription started", metadata: ["job": "\(jobID)"])
                await store.update(jobID, status: .running)
                defer {
                    try? FileManager.default.removeItem(at: tmpFile)
                    logger.debug("Temp file removed", metadata: ["job": "\(jobID)", "file": "\(tmpFile.lastPathComponent)"])
                }
                do {
                    let transcript = try await TranscriptionEngine.transcribe(file: tmpFile, options: options)
                    await store.update(jobID, status: .done(transcript: transcript, format: options.outputFormat.rawValue))
                    logger.info("Transcription complete", metadata: ["job": "\(jobID)", "format": "\(options.outputFormat.rawValue)"])
                } catch {
                    await store.update(jobID, status: .failed(error.localizedDescription))
                    logger.error("Transcription failed", metadata: ["job": "\(jobID)", "error": "\(error.localizedDescription)"])
                }
            }

            return jsonResponse(status: .accepted, body: #"{"id":"\#(jobID)","status":"queued"}"#)
        }

        router.get("/transcriptions/{id}") { request, context -> Response in
            if let k = key {
                guard request.headers[.init("X-API-Key")!] == k else {
                    return jsonResponse(status: .unauthorized, body: #"{"error":"Invalid API key"}"#)
                }
            }

            let id = context.parameters.get("id") ?? ""
            guard let status = await store.get(id) else {
                return jsonResponse(status: .notFound, body: #"{"error":"Job not found"}"#)
            }

            switch status {
            case .queued:
                return jsonResponse(status: .ok, body: #"{"id":"\#(id)","status":"queued"}"#)
            case .running:
                return jsonResponse(status: .ok, body: #"{"id":"\#(id)","status":"running"}"#)
            case let .done(transcript, format):
                let escaped = jsonEscape(transcript)
                return jsonResponse(status: .ok, body: #"{"id":"\#(id)","status":"done","format":"\#(format)","transcript":"\#(escaped)"}"#)
            case let .failed(message):
                let escaped = jsonEscape(message)
                return jsonResponse(status: .ok, body: #"{"id":"\#(id)","status":"failed","error":"\#(escaped)"}"#)
            }
        }

        let app = Application(
            router: router,
            configuration: .init(address: .hostname(host, port: port))
        )
        logger.info("Server listening", metadata: ["host": "\(host)", "port": "\(port)", "max-concurrent": "\(maxConcurrent)"])
        try await app.runService()
    }
}

// MARK: - Helpers

private func jsonResponse(status: HTTPResponse.Status, body: String) -> Response {
    Response(
        status: status,
        headers: [.contentType: "application/json"],
        body: .init(byteBuffer: .init(string: body))
    )
}

private func applyJSONOptions(json: [String: Any], into options: inout TranscriptionEngine.Options) {
    if let locale = json["locale"] as? String {
        options.locale = Locale(identifier: locale)
    }
    if let format = json["format"] as? String {
        options.outputFormat = outputFormat(from: format)
    }
    if let censor = json["censor"] as? Bool {
        options.censor = censor
    }
    if let maxLength = json["max_length"] as? Int {
        options.maxLength = maxLength
    }
    if let wordTimestamps = json["word_timestamps"] as? Bool {
        options.wordTimestamps = wordTimestamps
    }
}

private func applyQueryOptions(queryString: String?, into options: inout TranscriptionEngine.Options) {
    guard let queryString, !queryString.isEmpty else { return }
    var comps = URLComponents()
    comps.query = queryString
    let items = comps.queryItems ?? []
    func value(for name: String) -> String? { items.first(where: { $0.name == name })?.value }
    if let locale = value(for: "locale") {
        options.locale = Locale(identifier: locale)
    }
    if let format = value(for: "format") {
        options.outputFormat = outputFormat(from: format)
    }
    if let censor = value(for: "censor") {
        options.censor = censor == "true"
    }
    if let maxLength = value(for: "max_length"), let n = Int(maxLength) {
        options.maxLength = n
    }
    if let wt = value(for: "word_timestamps") {
        options.wordTimestamps = wt == "true"
    }
}

private func outputFormat(from string: String) -> OutputFormat {
    switch string {
    case "srt": .srt
    case "vtt": .vtt
    case "json": .json
    default: .txt
    }
}

private func extensionForContentType(_ contentType: String) -> String {
    let base = contentType.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) ?? ""
    switch base {
    case "audio/mpeg": return "mp3"
    case "audio/wav", "audio/x-wav": return "wav"
    case "audio/mp4", "video/mp4": return "mp4"
    case "audio/ogg": return "ogg"
    case "audio/flac": return "flac"
    default: return "mp3"
    }
}

private func jsonEscape(_ string: String) -> String {
    string
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
}
