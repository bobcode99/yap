import ArgumentParser
import Foundation
import Speech

/// Print supported BCP-47 locales, one per line. Used by yap-server's
/// AppleSpeechBackend probe to surface the real per-OS list on /backends.
struct Locales: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List locales supported by on-device speech transcription."
    )

    @MainActor func run() async throws {
        let supported = await SpeechTranscriber.supportedLocales
        for l in supported.map({ $0.identifier(.bcp47) }).sorted() {
            print(l)
        }
    }
}
