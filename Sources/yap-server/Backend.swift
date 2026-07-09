import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Options

struct TranscriptionOptions: Sendable {
    var format: String = "srt"        // txt, srt, vtt, json
    var locale: String?               // BCP 47, e.g. "en-US"
    var censor: Bool = false
    var maxLength: Int = 40
    var wordTimestamps: Bool = false
    var detectMusic: Bool = true
    var musicSensitivity: String? = nil  // "low", "medium", "high"; nil = backend default
    var onProgress: (@Sendable (Int) -> Void)? = nil

    /// Language code (e.g. "en") derived from the locale, or "auto".
    var languageCode: String {
        guard let locale else { return "auto" }
        return Locale(identifier: locale).language.languageCode?.identifier ?? "auto"
    }
}

// MARK: - Backend

protocol TranscriptionBackend: Sendable {
    var id: String { get }
    /// Locale codes this backend accepts, including ones that may require an
    /// on-demand asset download before first use. Empty = accepts any / OS-dependent.
    var locales: [String] { get }
    /// Subset of `locales` that can transcribe right now with no download.
    /// Defaults to `locales` for backends with no install-on-demand concept.
    var installedLocales: [String] { get }
    func transcribe(file: URL, options: TranscriptionOptions) async throws -> String
}

extension TranscriptionBackend {
    var installedLocales: [String] { locales }
}

enum BackendError: Error, LocalizedError {
    case binaryNotFound(String)
    case executionFailed(command: String, detail: String)
    case outputMissing(String)

    var errorDescription: String? {
        switch self {
        case let .binaryNotFound(name):
            "Executable not found: \(name)"
        case let .executionFailed(command, detail):
            "Command failed (\(command)): \(detail)"
        case let .outputMissing(path):
            "Expected output file not found at \(path)"
        }
    }
}

// MARK: - Registry

struct BackendRegistry: Sendable {
    let backends: [String: any TranscriptionBackend]
    let defaultID: String

    func backend(for id: String?) -> (any TranscriptionBackend)? {
        backends[id ?? defaultID]
    }

    var ids: [String] { backends.keys.sorted() }

    var locales: [String: [String]] {
        Dictionary(uniqueKeysWithValues: backends.map { ($0.key, $0.value.locales) })
    }

    var installedLocales: [String: [String]] {
        Dictionary(uniqueKeysWithValues: backends.map { ($0.key, $0.value.installedLocales) })
    }
}

/// Language codes supported by OpenAI Whisper / whisper.cpp / faster-whisper.
/// Same set for both whisper backends. `auto` = detect.
enum WhisperLocales {
    static let all: [String] = [
        "auto",
        "af", "am", "ar", "as", "az", "ba", "be", "bg", "bn", "bo", "br", "bs",
        "ca", "cs", "cy", "da", "de", "el", "en", "es", "et", "eu", "fa", "fi",
        "fo", "fr", "gl", "gu", "ha", "haw", "he", "hi", "hr", "ht", "hu", "hy",
        "id", "is", "it", "ja", "jw", "ka", "kk", "km", "kn", "ko", "la", "lb",
        "ln", "lo", "lt", "lv", "mg", "mi", "mk", "ml", "mn", "mr", "ms", "mt",
        "my", "ne", "nl", "nn", "no", "oc", "pa", "pl", "ps", "pt", "ro", "ru",
        "sa", "sd", "si", "sk", "sl", "sn", "so", "sq", "sr", "su", "sv", "sw",
        "ta", "te", "tg", "th", "tk", "tl", "tr", "tt", "uk", "ur", "uz", "vi",
        "yi", "yo", "zh",
    ]
}

// MARK: - Executable resolution

enum Executable {
    /// Resolve a binary name or path to an absolute executable URL.
    /// A value containing a path separator is checked directly; a bare name
    /// is searched on PATH.
    static func resolve(_ nameOrPath: String) -> URL? {
        if nameOrPath.contains("/") || nameOrPath.contains("\\") {
            let url = URL(fileURLWithPath: nameOrPath)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        #if os(Windows)
        let separator: Character = ";"
        #else
        let separator: Character = ":"
        #endif
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: separator) {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(nameOrPath)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

// MARK: - Process runner

enum ProcessRunner {
    struct Result: Sendable {
        let stdout: Data
        let stderr: Data
        let exitCode: Int32
    }

    /// Run an executable to completion, draining stdout/stderr concurrently so
    /// large output can't deadlock on a full pipe buffer.
    /// If `onProgress` is set, stderr is streamed line-by-line; lines matching
    /// `progress = N` or `progress=N%` call the callback with 0–100.
    static func run(
        _ executable: URL,
        _ arguments: [String],
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw BackendError.executionFailed(
                command: executable.lastPathComponent,
                detail: error.localizedDescription
            )
        }

        async let outData = readToEnd(outPipe.fileHandleForReading)
        async let errData = readErr(errPipe.fileHandleForReading, onProgress: onProgress)
        let (stdout, stderr) = await (outData, errData)

        await waitForExit(process)
        return Result(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
    }

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: handle.readDataToEndOfFile())
            }
        }
    }

    private static func readErr(_ handle: FileHandle, onProgress: (@Sendable (Int) -> Void)?) async -> Data {
        guard let cb = onProgress else { return await readToEnd(handle) }
        return await streamLines(handle) { line in
            if let m = line.firstMatch(of: /progress\s*=\s*(\d+)/),
               let pct = Int(m.1) { cb(min(max(pct, 0), 100)) }
        }
    }

    private static func streamLines(_ handle: FileHandle, onLine: @Sendable @escaping (String) -> Void) async -> Data {
        final class State: @unchecked Sendable { var all = Data(); var buf = Data() }
        let s = State()
        return await withCheckedContinuation { continuation in
            handle.readabilityHandler = { h in
                let chunk = h.availableData
                guard !chunk.isEmpty else {
                    handle.readabilityHandler = nil
                    continuation.resume(returning: s.all)
                    return
                }
                s.all.append(chunk)
                s.buf.append(chunk)
                while let i = s.buf.firstIndex(of: UInt8(ascii: "\n")) {
                    if let line = String(data: s.buf[..<i], encoding: .utf8) { onLine(line) }
                    s.buf = Data(s.buf[s.buf.index(after: i)...])
                }
            }
        }
    }

    private static func waitForExit(_ process: Process) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }
}
