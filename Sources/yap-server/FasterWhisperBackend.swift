import Foundation

/// Spawns the bundled faster-whisper Python wrapper, which renders the
/// requested format directly to stdout.
struct FasterWhisperBackend: TranscriptionBackend {
    let id = "faster-whisper"
    let locales = WhisperLocales.all
    let python: URL
    let script: URL
    let model: String
    let device: String
    let computeType: String

    static func probe(
        python: String,
        model: String?,
        device: String,
        computeType: String
    ) -> FasterWhisperBackend? {
        guard let model, !model.isEmpty else { return nil }
        guard let pythonURL = Executable.resolve(python) else { return nil }
        guard let script = Bundle.module.url(forResource: "faster_whisper_transcribe", withExtension: "py") else { return nil }
        return FasterWhisperBackend(
            python: pythonURL,
            script: script,
            model: model,
            device: device,
            computeType: computeType
        )
    }

    func transcribe(file: URL, options: TranscriptionOptions) async throws -> String {
        var args = [
            script.path,
            "--audio-path", file.path,
            "--model", model,
            "--device", device,
            "--compute-type", computeType,
            "--max-length", String(options.maxLength),
            "--format", options.format,
        ]
        if options.languageCode != "auto" { args += ["--language", options.languageCode] }
        if options.wordTimestamps { args.append("--word-timestamps") }

        let result = try await ProcessRunner.run(python, args, onProgress: options.onProgress)
        guard result.exitCode == 0 else {
            throw BackendError.executionFailed(command: "faster-whisper", detail: errorDetail(result))
        }
        return String(decoding: result.stdout, as: UTF8.self)
    }
}
