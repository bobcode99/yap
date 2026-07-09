import ArgumentParser
import Foundation
import Speech

/// Print supported and installed BCP-47 locales as one JSON line. "supported"
/// may require an on-demand asset download before first use; "installed" can
/// transcribe right now. Used by yap-server's AppleSpeechBackend probe to
/// surface the real per-OS lists on /backends.
struct Locales: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List locales supported and installed for on-device speech transcription."
    )

    @MainActor func run() async throws {
        let supported = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }.sorted()
        let installed = await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }.sorted()
        let obj: [String: Any] = ["supported": supported, "installed": installed]
        let data = try JSONSerialization.data(withJSONObject: obj)
        print(String(decoding: data, as: UTF8.self))
    }
}
