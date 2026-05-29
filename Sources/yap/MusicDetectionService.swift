import AVFoundation
import Foundation
import OSLog
import SoundAnalysis

// MARK: - MusicDetectionService

nonisolated enum MusicDetectionService {

    private static let logger = Logger(subsystem: "com.yap", category: "MusicDetection")

    // MARK: - Types

    /// Inclusive-start, exclusive-end time range in seconds.
    struct TimeRange: Sendable, Equatable {
        let start: TimeInterval
        let end: TimeInterval
        var duration: TimeInterval { end - start }

        func overlaps(with other: TimeRange) -> Bool {
            start < other.end && other.start < end
        }
    }

    // MARK: - Detection

    /// Detect music / singing ranges in `audioURL`. Returns merged ranges
    /// (adjacent hits within ~0.5 s are coalesced). Returns an empty array on
    /// failure — music detection is best-effort and must not block transcription.
    static func detectMusicRanges(
        in audioURL: URL,
        minimumConfidence: Double = 0.6
    ) async -> [TimeRange] {
        guard !Task.isCancelled else { return [] }

        let observer = ClassificationObserver(minimumConfidence: minimumConfidence)
        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            let analyzer = try SNAudioFileAnalyzer(url: audioURL)
            try analyzer.add(request, withObserver: observer)
            await analyzer.analyze()
        } catch {
            logger.warning("Music detection failed (continuing without): \(error.localizedDescription)")
            return []
        }
        let ranges = await observer.finish()
        logger.info("Detected \(ranges.count) music range(s)")
        return ranges
    }

    // MARK: - Injection

    /// Merge music range markers into a formatted transcription string.
    /// TXT output is returned unchanged (no timestamps to anchor markers).
    static func injectMusicMarkers(
        into output: String,
        format: OutputFormat,
        ranges: [TimeRange]
    ) -> String {
        guard !ranges.isEmpty else { return output }
        switch format {
        case .txt:
            return output
        case .srt:
            return injectIntoSRT(output, ranges: ranges)
        case .vtt:
            return injectIntoVTT(output, ranges: ranges)
        case .json:
            return injectIntoJSON(output, ranges: ranges)
        }
    }

    // MARK: - SRT

    private struct TimedEntry {
        var start: TimeInterval
        var end: TimeInterval
        var text: String
    }

    private static func overlaps(_ entry: TimedEntry, with range: TimeRange) -> Bool {
        entry.start < range.end && range.start < entry.end
    }

    private static func injectIntoSRT(_ srt: String, ranges: [TimeRange]) -> String {
        // Drop speech segments that fall inside a music range — they contain ASR
        // garbage on music — then replace them with the [Music] marker.
        let speech = parseSRTEntries(srt).filter { e in
            !ranges.contains { overlaps(e, with: $0) }
        }
        let music = ranges.map { TimedEntry(start: $0.start, end: $0.end, text: "[Music]") }
        let entries = (speech + music).sorted { $0.start < $1.start }
        return entries.enumerated().map { i, e in
            "\(i + 1)\n\(srtTime(e.start)) --> \(srtTime(e.end))\n\(e.text)"
        }.joined(separator: "\n\n")
    }

    private static func parseSRTEntries(_ srt: String) -> [TimedEntry] {
        srt.components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .compactMap { block in
                let lines = block.components(separatedBy: "\n")
                guard lines.count >= 3 else { return nil }
                let timeParts = lines[1].components(separatedBy: " --> ")
                guard timeParts.count == 2,
                      let start = parseSRTTime(timeParts[0].trimmingCharacters(in: .whitespaces)),
                      let end = parseSRTTime(timeParts[1].trimmingCharacters(in: .whitespaces))
                else { return nil }
                return TimedEntry(start: start, end: end, text: lines[2...].joined(separator: "\n"))
            }
    }

    private static func parseSRTTime(_ s: String) -> TimeInterval? {
        let parts = s.components(separatedBy: ",")
        guard parts.count == 2, let ms = Double(parts[1]) else { return nil }
        let hms = parts[0].components(separatedBy: ":")
        guard hms.count == 3,
              let h = Double(hms[0]), let m = Double(hms[1]), let sec = Double(hms[2])
        else { return nil }
        return h * 3600 + m * 60 + sec + ms / 1000
    }

    private static func srtTime(_ t: TimeInterval) -> String {
        let ms = Int(t.truncatingRemainder(dividingBy: 1) * 1000)
        let s = Int(t) % 60
        let m = (Int(t) / 60) % 60
        let h = Int(t) / 3600
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    // MARK: - VTT

    private static func injectIntoVTT(_ vtt: String, ranges: [TimeRange]) -> String {
        let speech = parseVTTEntries(vtt).filter { e in
            !ranges.contains { overlaps(e, with: $0) }
        }
        let music = ranges.map { TimedEntry(start: $0.start, end: $0.end, text: "[Music]") }
        let entries = (speech + music).sorted { $0.start < $1.start }
        let cues = entries.enumerated().map { i, e in
            "\(i + 1)\n\(vttTime(e.start)) --> \(vttTime(e.end))\n\(e.text)"
        }.joined(separator: "\n\n")
        // Preserve everything before the first cue block as the header
        let blocks = vtt.components(separatedBy: "\n\n")
        let headerBlocks = blocks.prefix(while: { !$0.contains(" --> ") })
        let header = headerBlocks.isEmpty ? "WEBVTT" : headerBlocks.joined(separator: "\n\n")
        return header + "\n\n" + cues
    }

    private static func parseVTTEntries(_ vtt: String) -> [TimedEntry] {
        vtt.components(separatedBy: "\n\n")
            .filter { $0.contains(" --> ") }
            .compactMap { block in
                let lines = block.components(separatedBy: "\n")
                guard let tsIdx = lines.firstIndex(where: { $0.contains(" --> ") }) else { return nil }
                let timeParts = lines[tsIdx].components(separatedBy: " --> ")
                guard timeParts.count == 2,
                      let start = parseVTTTime(timeParts[0].trimmingCharacters(in: .whitespaces)),
                      let end = parseVTTTime(timeParts[1].trimmingCharacters(in: .whitespaces))
                else { return nil }
                let text = lines[(tsIdx + 1)...].joined(separator: "\n")
                return TimedEntry(start: start, end: end, text: text)
            }
    }

    private static func parseVTTTime(_ s: String) -> TimeInterval? {
        // Strip optional cue settings (anything after a space following the timestamp)
        let token = s.components(separatedBy: " ").first ?? s
        let parts = token.components(separatedBy: ".")
        guard parts.count == 2, let ms = Double(parts[1]) else { return nil }
        let hms = parts[0].components(separatedBy: ":")
        // VTT allows HH:MM:SS.mmm or MM:SS.mmm (hours optional when < 1 h)
        switch hms.count {
        case 3:
            guard let h = Double(hms[0]), let m = Double(hms[1]), let sec = Double(hms[2]) else { return nil }
            return h * 3600 + m * 60 + sec + ms / 1000
        case 2:
            guard let m = Double(hms[0]), let sec = Double(hms[1]) else { return nil }
            return m * 60 + sec + ms / 1000
        default:
            return nil
        }
    }

    private static func vttTime(_ t: TimeInterval) -> String {
        let ms = Int(t.truncatingRemainder(dividingBy: 1) * 1000)
        let s = Int(t) % 60
        let m = (Int(t) / 60) % 60
        let h = Int(t) / 3600
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }

    // MARK: - JSON

    private static func injectIntoJSON(_ json: String, ranges: [TimeRange]) -> String {
        guard let data = json.data(using: .utf8),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var segments = root["segments"] as? [[String: Any]]
        else { return json }

        // Remove speech segments that overlap a music range, then inject [Music] entries.
        // JSONSerialization deserializes all numerics as NSNumber so `as? Double` works
        // regardless of whether the original value was Double or Decimal.
        segments = segments.filter { seg in
            let start = (seg["start"] as? Double) ?? ((seg["start"] as? NSNumber)?.doubleValue ?? 0)
            let end   = (seg["end"]   as? Double) ?? ((seg["end"]   as? NSNumber)?.doubleValue ?? 0)
            let e = TimedEntry(start: start, end: end, text: "")
            return !ranges.contains { overlaps(e, with: $0) }
        }
        for range in ranges {
            segments.append(["end": range.end, "start": range.start, "text": "[Music]"])
        }
        segments.sort {
            let a = ($0["start"] as? Double) ?? (($0["start"] as? NSNumber)?.doubleValue ?? 0)
            let b = ($1["start"] as? Double) ?? (($1["start"] as? NSNumber)?.doubleValue ?? 0)
            return a < b
        }
        segments = segments.enumerated().map { i, seg in
            var s = seg
            s["id"] = i + 1
            return s
        }
        root["segments"] = segments

        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: out, encoding: .utf8)
        else { return json }
        return str
    }

    // MARK: - Merging

    /// Coalesces adjacent ranges (gap ≤ 0.5 s) to avoid micro music markers.
    static func merge(_ ranges: [TimeRange]) -> [TimeRange] {
        let sorted = ranges.sorted { $0.start < $1.start }
        guard var current = sorted.first else { return [] }
        var merged: [TimeRange] = []
        for range in sorted.dropFirst() {
            if range.start <= current.end + 0.5 {
                current = TimeRange(start: current.start, end: max(current.end, range.end))
            } else {
                merged.append(current)
                current = range
            }
        }
        merged.append(current)
        return merged
    }
}

// MARK: - SoundAnalysis observer

/// Bridges `SNResultsObserving` callbacks to async/await and accumulates hits.
///
/// SoundAnalysis serializes all callbacks on its own private queue. The caller
/// must `await analyze()` before calling `finish()` — that ordering is the only
/// contract needed for safe access to the internal state.
private nonisolated final class ClassificationObserver: NSObject, SNResultsObserving, @unchecked Sendable {
    private let minimumConfidence: Double
    private var hits: [MusicDetectionService.TimeRange] = []
    private var continuation: CheckedContinuation<[MusicDetectionService.TimeRange], Never>?
    private var finalResult: [MusicDetectionService.TimeRange]?

    init(minimumConfidence: Double) {
        self.minimumConfidence = minimumConfidence
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        guard let match = result.classifications.first(where: isMusicMatch(_:)) else { return }
        _ = match
        let range = MusicDetectionService.TimeRange(
            start: result.timeRange.start.seconds,
            end: result.timeRange.end.seconds
        )
        hits.append(range)
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        complete()
    }

    func requestDidComplete(_ request: SNRequest) {
        complete()
    }

    func finish() async -> [MusicDetectionService.TimeRange] {
        await withCheckedContinuation { cc in
            if let finalResult {
                cc.resume(returning: finalResult)
            } else {
                self.continuation = cc
            }
        }
    }

    private func isMusicMatch(_ classification: SNClassification) -> Bool {
        let label = classification.identifier.lowercased()
        return (label.contains("music") || label.contains("singing"))
            && classification.confidence >= minimumConfidence
    }

    private func complete() {
        guard finalResult == nil else { return }
        let merged = MusicDetectionService.merge(hits)
        finalResult = merged
        continuation?.resume(returning: merged)
        continuation = nil
    }
}
