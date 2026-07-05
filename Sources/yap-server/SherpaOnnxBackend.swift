import Foundation

/// Spawns sherpa-onnx-offline with a SenseVoice model. The binary emits one
/// line of JSON per input file (text + per-token timestamps); we parse it and
/// render to the requested format ourselves since sherpa-onnx only outputs JSON.
struct SherpaOnnxBackend: TranscriptionBackend {
    let id = "sherpa-onnx"
    let locales = ["auto", "zh", "en", "ja", "ko", "yue"]
    let binary: URL
    let senseVoiceModel: String
    let tokens: String

    static func probe(binary: String, senseVoiceModel: String?, tokens: String?) -> SherpaOnnxBackend? {
        guard let senseVoiceModel, !senseVoiceModel.isEmpty,
              let tokens, !tokens.isEmpty,
              FileManager.default.fileExists(atPath: senseVoiceModel),
              FileManager.default.fileExists(atPath: tokens),
              let url = Executable.resolve(binary)
        else { return nil }
        return SherpaOnnxBackend(binary: url, senseVoiceModel: senseVoiceModel, tokens: tokens)
    }

    func transcribe(file: URL, options: TranscriptionOptions) async throws -> String {
        // sherpa-onnx-offline only reads WAV. Convert via ffmpeg to 16kHz mono.
        let wav = try await convertToWav(file)
        defer { try? FileManager.default.removeItem(at: wav) }
        let args = [
            "--sense-voice-model=\(senseVoiceModel)",
            "--tokens=\(tokens)",
            "--sense-voice-language=\(supportedLanguage(options.languageCode))",
            "--sense-voice-use-itn=true",
            wav.path,
        ]
        let result = try await ProcessRunner.run(binary, args, onProgress: options.onProgress)
        guard result.exitCode == 0 else {
            throw BackendError.executionFailed(command: "sherpa-onnx-offline", detail: errorDetail(result))
        }
        let stdout = String(decoding: result.stdout, as: UTF8.self)
        guard let parsed = parseResult(from: stdout) else {
            throw BackendError.executionFailed(
                command: "sherpa-onnx-offline",
                detail: "Could not parse JSON output. stdout: \(stdout.prefix(500))"
            )
        }
        return render(parsed, options: options)
    }

    // MARK: - Parsing

    private struct Parsed {
        let text: String
        let totalDuration: TimeInterval
        let lang: String?
    }

    /// Scan stdout for the first line that starts with `{` — sherpa-onnx
    /// interleaves filenames and stats around the JSON line we care about.
    private func parseResult(from stdout: String) -> Parsed? {
        for line in stdout.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"),
                  let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let text = (obj["text"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let timestamps = obj["timestamps"] as? [Double] ?? []
            let durations = obj["durations"] as? [Double] ?? []
            let end: TimeInterval = timestamps.last.map { $0 + (durations.last ?? 0) } ?? 0
            return Parsed(text: text, totalDuration: end, lang: obj["lang"] as? String)
        }
        return nil
    }

    // MARK: - Rendering

    private func render(_ p: Parsed, options: TranscriptionOptions) -> String {
        switch options.format {
        case "srt": return renderSRT(p, maxLength: options.maxLength)
        case "vtt": return renderVTT(p, maxLength: options.maxLength)
        case "json": return renderJSON(p)
        default: return p.text
        }
    }

    private struct Segment {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
    }

    /// SenseVoice gives us full text + per-token timestamps but no segment
    /// boundaries. Split text on sentence punctuation (long sentences split
    /// further at word boundaries to honor maxLength), then distribute the
    /// total duration proportionally by character count.
    private func chunk(_ text: String, maxLength: Int, total: TimeInterval) -> [Segment] {
        let enders: Set<Character> = [".", "!", "?", "。", "！", "？"]
        var sentences: [String] = []
        var buf = ""
        for ch in text {
            buf.append(ch)
            if enders.contains(ch) {
                let t = buf.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { sentences.append(t) }
                buf = ""
            }
        }
        let tail = buf.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }

        var pieces: [String] = []
        for s in sentences {
            if s.count <= maxLength { pieces.append(s); continue }
            var cur = ""
            for word in s.split(separator: " ") {
                if cur.isEmpty {
                    cur = String(word)
                } else if cur.count + 1 + word.count <= maxLength {
                    cur += " " + word
                } else {
                    pieces.append(cur)
                    cur = String(word)
                }
            }
            if !cur.isEmpty { pieces.append(cur) }
        }

        guard !pieces.isEmpty else { return [] }
        let totalChars = max(pieces.map(\.count).reduce(0, +), 1)
        var cursor: TimeInterval = 0
        return pieces.map { piece in
            let slice = total * Double(piece.count) / Double(totalChars)
            let start = cursor
            cursor += slice
            return Segment(start: start, end: cursor, text: piece)
        }
    }

    private func renderSRT(_ p: Parsed, maxLength: Int) -> String {
        chunk(p.text, maxLength: maxLength, total: p.totalDuration)
            .enumerated()
            .map { i, s in "\(i + 1)\n\(srtTime(s.start)) --> \(srtTime(s.end))\n\(s.text)" }
            .joined(separator: "\n\n")
    }

    private func renderVTT(_ p: Parsed, maxLength: Int) -> String {
        let cues = chunk(p.text, maxLength: maxLength, total: p.totalDuration)
            .enumerated()
            .map { i, s in "\(i + 1)\n\(vttTime(s.start)) --> \(vttTime(s.end))\n\(s.text)" }
            .joined(separator: "\n\n")
        return "WEBVTT\n\n" + cues
    }

    private func renderJSON(_ p: Parsed) -> String {
        let obj: [String: Any] = [
            "text": p.text,
            "duration": p.totalDuration,
            "lang": p.lang ?? "",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    // MARK: - Helpers

    private func convertToWav(_ input: URL) async throws -> URL {
        guard let ffmpeg = Executable.resolve("ffmpeg") else {
            throw BackendError.binaryNotFound("ffmpeg")
        }
        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        let args = ["-y", "-i", input.path, "-ar", "16000", "-ac", "1", "-f", "wav", wav.path]
        let result = try await ProcessRunner.run(ffmpeg, args)
        guard result.exitCode == 0 else {
            throw BackendError.executionFailed(command: "ffmpeg", detail: errorDetail(result))
        }
        return wav
    }

    private func supportedLanguage(_ code: String) -> String {
        let supported: Set<String> = ["auto", "zh", "en", "ja", "ko", "yue"]
        return supported.contains(code) ? code : "auto"
    }

    private func srtTime(_ t: TimeInterval) -> String {
        let ms = Int((t - floor(t)) * 1000)
        let s = Int(t) % 60
        let m = (Int(t) / 60) % 60
        let h = Int(t) / 3600
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    private func vttTime(_ t: TimeInterval) -> String {
        let ms = Int((t - floor(t)) * 1000)
        let s = Int(t) % 60
        let m = (Int(t) / 60) % 60
        let h = Int(t) / 3600
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }
}
