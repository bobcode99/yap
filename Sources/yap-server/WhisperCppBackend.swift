import Foundation

/// Spawns whisper.cpp's `whisper-cli`, which writes a formatted output file
/// that we read back.
struct WhisperCppBackend: TranscriptionBackend {
    let id = "whisper-cpp"
    let binary: URL
    let model: String

    static func probe(binary: String, model: String?) -> WhisperCppBackend? {
        guard let model, !model.isEmpty else { return nil }
        guard let url = Executable.resolve(binary) else { return nil }
        return WhisperCppBackend(binary: url, model: model)
    }

    func transcribe(file: URL, options: TranscriptionOptions) async throws -> String {
        let outputDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let outputBase = outputDir.appendingPathComponent("transcript").path
        var args = [
            "-m", model,
            "-f", file.path,
            "-of", outputBase,
            "-np",
            "-l", options.languageCode,
            "-ml", String(options.maxLength),
        ]

        let ext: String
        switch options.format {
        case "txt": args.append("-otxt"); ext = "txt"
        case "vtt": args.append("-ovtt"); ext = "vtt"
        case "json": args.append("-oj"); ext = "json"
        default: args.append("-osrt"); ext = "srt"
        }
        if options.wordTimestamps { args.append("-ojf") }

        args.append("--print-progress")
        let result = try await ProcessRunner.run(binary, args, onProgress: options.onProgress)
        guard result.exitCode == 0 else {
            throw BackendError.executionFailed(command: "whisper-cli", detail: errorDetail(result))
        }

        let outputFile = URL(fileURLWithPath: outputBase).appendingPathExtension(ext)
        guard FileManager.default.fileExists(atPath: outputFile.path) else {
            throw BackendError.outputMissing(outputFile.path)
        }
        return try String(contentsOf: outputFile, encoding: .utf8)
    }
}
