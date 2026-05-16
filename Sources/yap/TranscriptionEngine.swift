import AVFoundation
import Logging
import Speech

// MARK: - TranscriptionEngine

enum TranscriptionEngine {
    struct Options: Sendable {
        var locale: Locale = .init(identifier: Locale.current.identifier)
        var censor: Bool = false
        var outputFormat: OutputFormat = .txt
        var maxLength: Int = 40
        var wordTimestamps: Bool = false
    }

    static func transcribe(
        file: URL,
        options: Options = .init(),
        onProgress: (@Sendable (Double) async -> Void)? = nil,
        log: Logger? = nil
    ) async throws -> String {
        let bcp47 = options.locale.identifier(.bcp47)

        log?.debug("phase: existence check", metadata: ["file": "\(file.path)"])
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw TranscriptionError.fileNotFound(file.path)
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        log?.info("file info", metadata: ["bytes": "\(fileSize)", "ext": "\(file.pathExtension)", "locale": "\(bcp47)"])

        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.speechTranscriberNotAvailable
        }

        log?.debug("phase: locale support check", metadata: ["locale": "\(bcp47)"])
        let supportedLocales = await SpeechTranscriber.supportedLocales
        guard supportedLocales.contains(where: { $0.identifier(.bcp47) == bcp47 }) else {
            throw TranscriptionError.unsupportedLocale(options.locale.identifier)
        }

        log?.debug("phase: reserving locale")
        for locale in await AssetInventory.reservedLocales {
            await AssetInventory.release(reservedLocale: locale)
        }
        do {
            try await AssetInventory.reserve(locale: options.locale)
        } catch {
            log?.error("phase failed: reserving locale", metadata: ["locale": "\(bcp47)", "error": "\(error)"])
            throw error
        }

        let needsTimeRange = options.outputFormat.needsAudioTimeRange || onProgress != nil
        let transcriber = SpeechTranscriber(
            locale: options.locale,
            transcriptionOptions: options.censor ? [.etiquetteReplacements] : [],
            reportingOptions: [],
            attributeOptions: needsTimeRange ? [.audioTimeRange] : []
        )
        let modules: [any SpeechModule] = [transcriber]

        log?.debug("phase: ensuring model installed", metadata: ["locale": "\(bcp47)"])
        let installedLocales = await SpeechTranscriber.installedLocales
        if !installedLocales.contains(where: { $0.identifier(.bcp47) == bcp47 }) {
            log?.info("downloading model — first-time use can take minutes", metadata: ["locale": "\(bcp47)"])
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                    try await request.downloadAndInstall()
                    log?.info("model installed", metadata: ["locale": "\(bcp47)"])
                }
            } catch {
                log?.error("phase failed: model download/install", metadata: ["locale": "\(bcp47)", "error": "\(error)"])
                throw error
            }
        } else {
            log?.debug("model already installed", metadata: ["locale": "\(bcp47)"])
        }

        log?.debug("phase: opening audio file")
        let analyzer = SpeechAnalyzer(modules: modules)
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: file)
        } catch {
            log?.error("phase failed: opening audio file", metadata: [
                "file": "\(file.path)", "ext": "\(file.pathExtension)",
                "bytes": "\(fileSize)", "error": "\(error)",
            ])
            throw TranscriptionError.audioFileUnreadable(path: file.path, reason: "\(error)")
        }
        let totalDuration = audioFile.processingFormat.sampleRate > 0
            ? Double(audioFile.length) / audioFile.processingFormat.sampleRate
            : 0
        log?.info("audio info", metadata: [
            "sample_rate": "\(audioFile.processingFormat.sampleRate)",
            "channels": "\(audioFile.processingFormat.channelCount)",
            "duration_s": "\(Int(totalDuration))",
        ])

        log?.debug("phase: starting analyzer")
        do {
            try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
        } catch {
            log?.error("phase failed: analyzer.start", metadata: ["error": "\(error)"])
            throw error
        }

        log?.debug("phase: streaming results")

        var transcript: AttributedString = ""
        var lastReportedTime: TimeInterval = 0
        var lastProgressDate = Date.distantPast
        var resultCount = 0
        var lastEndTime: TimeInterval = 0

        do {
            for try await result in transcriber.results {
                resultCount += 1
                transcript += result.text

                for run in result.text.runs {
                    if let timeRange = run.audioTimeRange {
                        lastEndTime = max(lastEndTime, timeRange.end.seconds)
                    }
                }

                if let onProgress, totalDuration > 0 {
                    let now = Date()
                    guard now.timeIntervalSince(lastProgressDate) >= 0.5 else { continue }
                    if lastEndTime > lastReportedTime {
                        lastReportedTime = lastEndTime
                        lastProgressDate = now
                        await onProgress(min(lastEndTime / totalDuration, 0.99))
                    }
                }
            }
        } catch {
            let charCount = String(transcript.characters).count
            log?.error("phase failed: streaming results", metadata: [
                "results_received": "\(resultCount)",
                "last_end_time_s": "\(Int(lastEndTime))",
                "duration_s": "\(Int(totalDuration))",
                "covered": "\(totalDuration > 0 ? Int(lastEndTime / totalDuration * 100) : 0)%",
                "transcript_chars": "\(charCount)",
                "error": "\(error)",
            ])
            // Salvage what we got. Throw a partial-result error that carries the transcript
            // so the caller can decide whether to surface it.
            if resultCount > 0 {
                throw TranscriptionError.partialResult(
                    transcript: options.outputFormat.text(for: transcript, maxLength: options.maxLength, locale: options.locale, wordTimestamps: options.wordTimestamps),
                    coveredSeconds: lastEndTime,
                    totalSeconds: totalDuration,
                    underlying: error
                )
            }
            throw error
        }

        log?.debug("phase: stream complete", metadata: [
            "results_received": "\(resultCount)",
            "last_end_time_s": "\(Int(lastEndTime))",
        ])
        return options.outputFormat.text(for: transcript, maxLength: options.maxLength, locale: options.locale, wordTimestamps: options.wordTimestamps)
    }
}

// MARK: - TranscriptionError

enum TranscriptionError: Error, LocalizedError {
    case fileNotFound(String)
    case speechTranscriberNotAvailable
    case unsupportedLocale(String)
    case audioFileUnreadable(path: String, reason: String)
    /// Speech.framework threw mid-stream after producing some results.
    /// Carries the partial transcript so callers can salvage it.
    case partialResult(transcript: String, coveredSeconds: TimeInterval, totalSeconds: TimeInterval, underlying: Error)

    // MARK: Internal

    var errorDescription: String? {
        switch self {
        case let .fileNotFound(path):
            return "File not found: \(path)"
        case .speechTranscriberNotAvailable:
            return "SpeechTranscriber is not available on this device."
        case let .unsupportedLocale(identifier):
            return "Locale \"\(identifier)\" is not supported for speech transcription."
        case let .audioFileUnreadable(path, reason):
            return "Could not open audio file at \(path): \(reason)"
        case let .partialResult(_, covered, total, underlying):
            let pct = total > 0 ? Int(covered / total * 100) : 0
            return "Speech.framework failed at \(pct)% (\(Int(covered))s/\(Int(total))s): \(underlying.localizedDescription)"
        }
    }
}
