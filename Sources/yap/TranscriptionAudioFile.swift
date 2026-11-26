import AVFoundation

// MARK: - TranscriptionAudioFile

/// An audio file prepared for `SpeechAnalyzer`.
///
/// `SpeechAnalyzer` can fail reading MP3s directly: files that report one more
/// packet than they decode end with `eofErr`, and long, well-formed MP3s (e.g. a
/// 101-minute 48 kHz CBR podcast) fail near the end with `nilError`. No cheap
/// probe catches the second case, so every MP3 is first normalized to M4A.
// ponytail: export adds ~25% of transcription time on long MP3s (24s for
// 101 min). Retry-on-failure instead if MP3 latency matters.
struct TranscriptionAudioFile {
    let audioFile: AVAudioFile

    private let temporaryURL: URL?

    static func prepare(_ url: URL) async throws -> Self {
        let audioFile = try AVAudioFile(forReading: url)
        guard audioFile.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEGLayer3 else {
            return Self(audioFile: audioFile, temporaryURL: nil)
        }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appending(path: "yap-\(UUID().uuidString)")
            .appendingPathExtension("m4a")

        do {
            let asset = AVURLAsset(url: url)
            guard let exportSession = AVAssetExportSession(
                asset: asset,
                presetName: AVAssetExportPresetAppleM4A
            ) else {
                throw TranscriptionError.audioConversionFailed
            }

            try await exportSession.export(to: temporaryURL, as: .m4a)
            return Self(
                audioFile: try AVAudioFile(forReading: temporaryURL),
                temporaryURL: temporaryURL
            )
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    func removeTemporaryFile() {
        guard let temporaryURL else { return }
        try? FileManager.default.removeItem(at: temporaryURL)
    }
}
