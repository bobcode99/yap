import ArgumentParser
import Foundation
import Hummingbird
import Logging
import OpenAPIHummingbird
import Semaphore
import Speech

// MARK: - JobStore

actor JobStore: Sendable {
    enum Status {
        case queued
        case running(progress: Double)
        case done(transcript: String, format: String)
        case failed(String)
        case cancelled
    }

    enum CancelResult { case cancelled, notFound, alreadyTerminal }

    private var jobs: [String: Status] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var names: [String: String] = [:]

    func create(_ id: String, name: String? = nil) {
        jobs[id] = .queued
        if let name { names[id] = name }
    }

    func getName(_ id: String) -> String? { names[id] }

    /// Update status. Ignored if the job is already cancelled (prevents a late
    /// background update from overwriting the canonical cancelled state).
    func update(_ id: String, status: Status) {
        guard let current = jobs[id] else { return }
        if case .cancelled = current { return }
        jobs[id] = status
    }

    func get(_ id: String) -> Status? { jobs[id] }

    func register(_ id: String, task: Task<Void, Never>) { tasks[id] = task }
    func removeTask(_ id: String) { tasks[id] = nil }

    func cancel(_ id: String) -> CancelResult {
        guard let status = jobs[id] else { return .notFound }
        switch status {
        case .queued, .running:
            tasks[id]?.cancel()
            tasks[id] = nil
            jobs[id] = .cancelled
            return .cancelled
        case .done, .failed, .cancelled:
            return .alreadyTerminal
        }
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

    @Option(name: .long, help: "Log level: trace, debug, info, notice, warning, error, critical. (default: info)")
    var logLevel: String = "info"

    mutating func run() async throws {
        let log: Logger = {
            var l = Logger(label: "yap.serve")
            l.logLevel = Logger.Level(rawValue: logLevel) ?? .info
            return l
        }()

        let store = JobStore()
        let semaphore = AsyncSemaphore(value: maxConcurrent)
        let key = apiKey

        let router = Router()

        // Middleware — captures X-API-Key for all routes
        router.add(middleware: APIKeyMiddleware())

        // Manual routes not covered by the generated spec
        router.get("/openapi.yaml") { _, _ -> Response in
            let yamlURL = Bundle.module.url(forResource: "openapi", withExtension: "yaml")
            let content = yamlURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? openAPISpecFallback
            return Response(
                status: .ok,
                headers: [.contentType: "text/yaml; charset=utf-8"],
                body: .init(byteBuffer: .init(string: content))
            )
        }

        router.get("/docs") { _, _ -> Response in
            let html = swaggerUIHTML(specURL: "/openapi.yaml", title: "yap API")
            return Response(
                status: .ok,
                headers: [.contentType: "text/html; charset=utf-8"],
                body: .init(byteBuffer: .init(string: html))
            )
        }

        // Register all OpenAPI-generated route handlers
        let api = YapAPI(store: store, semaphore: semaphore, apiKey: key, log: log)
        try api.registerHandlers(on: router)

        let app = Application(
            router: router,
            configuration: .init(address: .hostname(host, port: port))
        )
        log.info("Server listening", metadata: ["host": "\(host)", "port": "\(port)", "max-concurrent": "\(maxConcurrent)"])
        try await app.runService()
    }
}

// MARK: - OpenAPI spec fallback (used if Bundle.module resource lookup fails)
private let openAPISpecFallback = "# openapi.yaml not found in bundle — rebuild the project"

// MARK: - Swagger UI

private func swaggerUIHTML(specURL: String, title: String) -> String {
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8"/>
      <meta name="viewport" content="width=device-width, initial-scale=1"/>
      <title>\(title)</title>
      <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@5/swagger-ui.css"/>
    </head>
    <body>
      <div id="swagger-ui"></div>
      <script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
      <script>
        SwaggerUIBundle({
          url: "\(specURL)",
          dom_id: "#swagger-ui",
          presets: [SwaggerUIBundle.presets.apis, SwaggerUIBundle.SwaggerUIStandalonePreset],
          layout: "BaseLayout",
          deepLinking: true,
          tryItOutEnabled: true,
        })
      </script>
    </body>
    </html>
    """
}
