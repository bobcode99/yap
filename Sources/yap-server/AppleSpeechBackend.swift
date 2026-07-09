import Foundation

/// Spawns the `yap` CLI, which transcribes with Apple Speech and prints the
/// formatted transcript to stdout. macOS only — the probe fails elsewhere.
struct AppleSpeechBackend: TranscriptionBackend {
    let id = "apple-speech"
    let locales: [String]
    let installedLocales: [String]
    let binary: URL

    static func probe(yapBinary: String) -> AppleSpeechBackend? {
        #if os(macOS)
        guard let url = Executable.resolve(yapBinary) else { return nil }
        let (supported, installed) = fetchLocales(url)
        return AppleSpeechBackend(locales: supported, installedLocales: installed, binary: url)
        #else
        return nil
        #endif
    }

    /// Ask `yap locales` synchronously at probe time. Failure = empty lists.
    private static func fetchLocales(_ binary: URL) -> (supported: [String], installed: [String]) {
        let p = Process()
        p.executableURL = binary
        p.arguments = ["locales"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String]]
            else { return ([], []) }
            return (obj["supported"] ?? [], obj["installed"] ?? [])
        } catch {
            return ([], [])
        }
    }

    func transcribe(file: URL, options: TranscriptionOptions) async throws -> String {
        var args = ["transcribe", file.path, "--\(options.format)", "--max-length", String(options.maxLength)]
        if let locale = options.locale { args += ["--locale", locale] }
        if options.censor { args.append("--censor") }
        if options.wordTimestamps { args.append("--word-timestamps") }
        args.append(options.detectMusic ? "--detect-music" : "--no-detect-music")
        if let sensitivity = options.musicSensitivity {
            args += ["--music-sensitivity", sensitivity]
        }

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
