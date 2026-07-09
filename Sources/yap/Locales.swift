import ArgumentParser
import Foundation
import Speech

/// Print installed BCP-47 locales, one per line — the ones that can
/// transcribe right now without triggering an asset download. Used by
/// yap-server's AppleSpeechBackend probe to surface the real per-OS list on
/// /backends.
struct Locales: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List locales installed for on-device speech transcription."
    )

    @MainActor func run() async throws {
        let installed = await SpeechTranscriber.installedLocales
        for l in installed.map({ $0.identifier(.bcp47) }).sorted() {
            print(l)
        }
    }
}
