import Foundation

/// Spawns the `yap` CLI, which transcribes with Apple Speech and prints the
/// formatted transcript to stdout. macOS only — the probe fails elsewhere.
struct AppleSpeechBackend: TranscriptionBackend {
    let id = "apple-speech"
    let binary: URL

    static func probe(yapBinary: String) -> AppleSpeechBackend? {
        #if os(macOS)
        guard let url = Executable.resolve(yapBinary) else { return nil }
        return AppleSpeechBackend(binary: url)
        #else
        return nil
        #endif
    }

    func transcribe(file: URL, options: TranscriptionOptions) async throws -> String {
        var args = ["transcribe", file.path, "--\(options.format)", "--max-length", String(options.maxLength)]
        if let locale = options.locale { args += ["--locale", locale] }
        if options.censor { args.append("--censor") }
        if options.wordTimestamps { args.append("--word-timestamps") }
        args.append(options.detectMusic ? "--detect-music" : "--no-detect-music")

        let result = try await ProcessRunner.run(binary, args, onProgress: options.onProgress)
        guard result.exitCode == 0 else {
            throw BackendError.executionFailed(
                command: "yap transcribe",
                detail: errorDetail(result)
            )
        }
        return String(decoding: result.stdout, as: UTF8.self)
    }
}

func errorDetail(_ result: ProcessRunner.Result) -> String {
    let stderr = String(decoding: result.stderr, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return stderr.isEmpty ? "exit code \(result.exitCode)" : stderr
}
