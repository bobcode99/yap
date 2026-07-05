import ArgumentParser
import Foundation
import Hummingbird
import Logging
import OpenAPIHummingbird
import OpenAPIRuntime
import Semaphore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Command

@main struct YapServer: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "yap-server",
        abstract: "Cross-platform HTTP transcription server with pluggable backends."
    )

    @Option(help: "Host to bind to.") var host: String = "127.0.0.1"
    @Option(help: "Port to listen on.") var port: Int = 8080
    @Option(name: .long, help: "If set, require X-API-Key header on all non-health requests.")
    var apiKey: String?
    @Option(name: .long, help: "Maximum number of concurrent transcription jobs.")
    var maxConcurrent: Int = 2
    @Option(name: .long, help: "Default backend id when a request omits one (apple-speech, whisper-cpp, faster-whisper).")
    var defaultBackend: String?

    @Option(name: .long, help: "Path to the yap CLI (apple-speech backend). Looked up on PATH by default.")
    var yapBin: String = "yap"
    @Option(name: .long, help: "Path to the whisper.cpp whisper-cli binary.")
    var whisperCliBin: String = ProcessInfo.processInfo.environment["YAP_WHISPER_CLI_BIN"] ?? "whisper-cli"
    @Option(name: .long, help: "Path to a whisper.cpp model file (required to enable the whisper-cpp backend). Falls back to $YAP_WHISPER_MODEL.")
    var whisperModel: String?

    @Option(name: .long, help: "Python executable for the bundled faster-whisper wrapper.")
    var fasterWhisperPython: String = ProcessInfo.processInfo.environment["YAP_FASTER_WHISPER_PYTHON"] ?? "python3"
    @Option(name: .long, help: "faster-whisper model name (required to enable the faster-whisper backend). Falls back to $YAP_FASTER_WHISPER_MODEL.")
    var fasterWhisperModel: String?
    @Option(name: .long, help: "faster-whisper device, e.g. auto, cpu, cuda.")
    var fasterWhisperDevice: String = "auto"
    @Option(name: .long, help: "faster-whisper compute type, e.g. default, int8, float16.")
    var fasterWhisperComputeType: String = "default"

    @Option(name: .long, help: "Path to the sherpa-onnx-offline binary.")
    var sherpaOnnxBin: String = ProcessInfo.processInfo.environment["YAP_SHERPA_ONNX_BIN"] ?? "sherpa-onnx-offline"
    @Option(name: .long, help: "Path to a SenseVoice ONNX model (required to enable the sherpa-onnx backend). Falls back to $YAP_SHERPA_ONNX_SENSE_VOICE_MODEL.")
    var sherpaOnnxSenseVoiceModel: String?
    @Option(name: .long, help: "Path to the matching tokens.txt file. Falls back to $YAP_SHERPA_ONNX_TOKENS.")
    var sherpaOnnxTokens: String?

    func run() async throws {
        let logger = Logger(label: "yap-server")
        let registry = buildRegistry(logger: logger)
        guard !registry.backends.isEmpty else {
            throw ValidationError("No transcription backend available. On macOS install `yap`; otherwise pass --whisper-model and/or --faster-whisper-model with the matching binaries on PATH.")
        }

        let store = JobStore()
        let semaphore = AsyncSemaphore(value: maxConcurrent)
        let router = Router(context: BasicRequestContext.self)
        if let key = apiKey {
            router.add(middleware: APIKeyMiddleware(apiKey: key))
        }
        let api = APIImpl(store: store, semaphore: semaphore, registry: registry, logger: logger)
        try api.registerHandlers(on: router)

        router.get("/") { _, _ -> Response in
            let page = Bundle.module.url(forResource: "index", withExtension: "html")
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                ?? "<!-- index.html not bundled -->"
            return Response(
                status: .ok,
                headers: [.contentType: "text/html; charset=utf-8"],
                body: .init(byteBuffer: .init(string: page))
            )
        }
        router.get("/openapi.yaml") { _, _ -> Response in
            let yaml = Bundle.module.url(forResource: "openapi", withExtension: "yaml")
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                ?? "# openapi.yaml not bundled"
            return Response(
                status: .ok,
                headers: [.contentType: "text/yaml; charset=utf-8"],
                body: .init(byteBuffer: .init(string: yaml))
            )
        }
        router.get("/docs") { _, _ -> Response in
            return Response(
                status: .ok,
                headers: [.contentType: "text/html; charset=utf-8"],
                body: .init(byteBuffer: .init(string: swaggerUI(specURL: "/openapi.yaml")))
            )
        }

        let app = Application(
            router: router,
            configuration: .init(address: .hostname(host, port: port))
        )
        logger.info("listening", metadata: [
            "host": "\(host)", "port": "\(port)",
            "backends": "\(registry.ids.joined(separator: ","))",
            "default": "\(registry.defaultID)",
            "max-concurrent": "\(maxConcurrent)",
        ])
        try await app.runService()
    }

    private func buildRegistry(logger: Logger) -> BackendRegistry {
        var backends: [String: any TranscriptionBackend] = [:]

        if let apple = AppleSpeechBackend.probe(yapBinary: yapBin) {
            backends[apple.id] = apple
        } else {
            logger.info("apple-speech unavailable (yap not found or non-macOS)")
        }
        let resolvedWhisperModel = whisperModel ?? ProcessInfo.processInfo.environment["YAP_WHISPER_MODEL"]
        if let whisper = WhisperCppBackend.probe(binary: whisperCliBin, model: resolvedWhisperModel) {
            backends[whisper.id] = whisper
        } else {
            logger.info("whisper-cpp unavailable (whisper-cli or --whisper-model missing)")
        }
        let resolvedFasterModel = fasterWhisperModel ?? ProcessInfo.processInfo.environment["YAP_FASTER_WHISPER_MODEL"]
        if let faster = FasterWhisperBackend.probe(
            python: fasterWhisperPython,
            model: resolvedFasterModel,
            device: fasterWhisperDevice,
            computeType: fasterWhisperComputeType
        ) {
            backends[faster.id] = faster
        } else {
            logger.info("faster-whisper unavailable (python or --faster-whisper-model missing)")
        }
        let resolvedSherpaModel = sherpaOnnxSenseVoiceModel ?? ProcessInfo.processInfo.environment["YAP_SHERPA_ONNX_SENSE_VOICE_MODEL"]
        let resolvedSherpaTokens = sherpaOnnxTokens ?? ProcessInfo.processInfo.environment["YAP_SHERPA_ONNX_TOKENS"]
        if let sherpa = SherpaOnnxBackend.probe(
            binary: sherpaOnnxBin,
            senseVoiceModel: resolvedSherpaModel,
            tokens: resolvedSherpaTokens
        ) {
            backends[sherpa.id] = sherpa
        } else {
            logger.info("sherpa-onnx unavailable (binary, --sherpa-onnx-sense-voice-model, or --sherpa-onnx-tokens missing)")
        }

        let fallbackOrder = ["apple-speech", "whisper-cpp", "faster-whisper", "sherpa-onnx"]
        let resolvedDefault = defaultBackend ?? fallbackOrder.first { backends[$0] != nil } ?? ""
        return BackendRegistry(backends: backends, defaultID: resolvedDefault)
    }
}

private func swaggerUI(specURL: String) -> String {
    """
    <!DOCTYPE html>
    <html>
    <head>
      <title>yap-server API</title>
      <meta charset="utf-8"/>
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist/swagger-ui.css">
    </head>
    <body>
    <div id="swagger-ui"></div>
    <script src="https://unpkg.com/swagger-ui-dist/swagger-ui-bundle.js"></script>
    <script>
      SwaggerUIBundle({
        url: "\(specURL)",
        dom_id: '#swagger-ui',
        presets: [SwaggerUIBundle.presets.apis, SwaggerUIBundle.SwaggerUIStandalonePreset],
        layout: "BaseLayout",
        deepLinking: true
      })
    </script>
    </body>
    </html>
    """
}
